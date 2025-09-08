defmodule Mana.Monitoring.CircuitBreaker do
  @moduledoc """
  Circuit breaker implementation for V2 module protection.

  This module provides:
  - Three-state circuit breaker (closed, open, half-open)
  - Configurable failure thresholds and timeouts
  - Automatic state transitions
  - Comprehensive monitoring and telemetry
  - Multiple circuit breaker instances
  - Fault tolerance for V2 operations
  """

  use GenServer
  require Logger

  @default_config %{
    # Number of failures before opening
    failure_threshold: 5,
    # Number of successes to close from half-open
    success_threshold: 3,
    # How long operations can take
    timeout_ms: 60_000,
    # How long to wait before trying half-open
    reset_timeout_ms: 300_000
  }

  # Circuit breaker states
  @states [:closed, :open, :half_open]

  # Client API

  @doc """
  Starts a circuit breaker for a given name.
  """
  @spec start_link(atom(), map()) :: GenServer.on_start()
  def start_link(name, _config \\ %{}) do
    GenServer.start_link(__MODULE__, {name, config}, name: registry_name(name))
  end

  @doc """
  Calls a function through the circuit breaker.

  ## Parameters
  - breaker_name: Name of the circuit breaker
  - fun: Function to execute
  - config: Optional configuration override

  ## Returns
  - {:ok, result} if the function succeeds
  - {:error, :circuit_open} if the circuit breaker is open
  - {:error, _reason} if the function fails
  """
  @spec call(atom(), function(), map()) :: {:ok, term()} | {:error, term()}
  def call(breaker_name, fun, _config \\ %{}) when is_function(fun, 0) do
    case get_or_start_breaker(breaker_name, config) do
      {:ok, pid} ->
        GenServer.call(
          pid,
          {:call, fun},
          Map.get(config, :timeout_ms, @default_config.timeout_ms) + 5000
        )

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  @doc """
  Records a successful operation.
  """
  @spec record_success(atom()) :: :ok
  def record_success(breaker_name) do
    case get_or_start_breaker(breaker_name) do
      {:ok, pid} ->
        GenServer.cast(pid, :record_success)

      {:error, _reason} ->
        # Ignore if breaker doesn't exist
        :ok
    end
  end

  @doc """
  Records a failed operation.
  """
  @spec record_failure(atom(), term()) :: :ok
  def record_failure(breaker_name, _reason) do
    case get_or_start_breaker(breaker_name) do
      {:ok, pid} ->
        GenServer.cast(pid, {:record_failure, reason})

      {:error, _reason} ->
        # Ignore if breaker doesn't exist
        :ok
    end
  end

  @doc """
  Gets the current state of a circuit breaker.
  """
  @spec state(atom()) :: :closed | :open | :half_open | :unknown
  def state(breaker_name) do
    case get_breaker_pid(breaker_name) do
      {:ok, pid} ->
        GenServer.call(pid, :get_state)

      {:error, _reason} ->
        :unknown
    end
  end

  @doc """
  Manually opens a circuit breaker.
  """
  @spec open(atom(), term()) :: :ok
  def open(breaker_name, _reason \\ :manual) do
    case get_or_start_breaker(breaker_name) do
      {:ok, pid} ->
        GenServer.cast(pid, {:force_open, reason})

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Manually closes a circuit breaker.
  """
  @spec close(atom()) :: :ok
  def close(breaker_name) do
    case get_breaker_pid(breaker_name) do
      {:ok, pid} ->
        GenServer.cast(pid, :force_close)

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Gets statistics for a circuit breaker.
  """
  @spec stats(atom()) :: map() | nil
  def stats(breaker_name) do
    case get_breaker_pid(breaker_name) do
      {:ok, pid} ->
        GenServer.call(pid, :get_stats)

      {:error, _reason} ->
        nil
    end
  end

  @doc """
  Gets statistics for all circuit breakers.
  """
  @spec all_stats() :: map()
  def all_stats do
    Registry.select(Mana.CircuitBreakerRegistry, [{{:"$1", :"$2", :"$3"}, [], [:"$1"]}])
    |> Enum.reduce(%{}, fn {breaker_name, _pid, _value}, acc ->
      case stats(breaker_name) do
        nil -> acc
        breaker_stats -> Map.put(acc, breaker_name, breaker_stats)
      end
    end)
  end

  # GenServer Callbacks

  @impl true
  def init({name, _config}) do
    # Ensure registry exists
    ensure_registry()

    merged_config = Map.merge(@default_config, config)

    state = %{
      name: name,
      config: merged_config,
      state: :closed,
      failure_count: 0,
      success_count: 0,
      last_failure_time: nil,
      last_success_time: nil,
      state_changed_at: System.system_time(:millisecond),
      total_calls: 0,
      total_successes: 0,
      total_failures: 0,
      total_circuit_opens: 0,
      current_consecutive_failures: 0,
      current_consecutive_successes: 0
    }

    Logger.info("Circuit breaker started", %{
      name: name,
      config: merged_config
    })

    emit_telemetry(:circuit_breaker_started, state)

    {:ok, _state}
  end

  @impl true
  def handle_call({:call, fun}, _from, _state) do
    case can_execute?(state) do
      true ->
        execute_function(fun, state)

      false ->
        new_state = update_stats(_state, :rejected)

        emit_telemetry(:call_rejected, new_state)

        {:reply, {:error, :circuit_open}, new_state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, _state) do
    {:reply, state.state, state}
  end

  @impl true
  def handle_call(:get_stats, _from, _state) do
    stats = %{
      name: state.name,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count,
      total_calls: state.total_calls,
      total_successes: state.total_successes,
      total_failures: state.total_failures,
      total_circuit_opens: state.total_circuit_opens,
      success_rate: calculate_success_rate(state),
      state_duration_ms: System.system_time(:millisecond) - state.state_changed_at,
      last_failure_time: state.last_failure_time,
      last_success_time: state.last_success_time,
      config: state.config
    }

    {:reply, stats, state}
  end

  @impl true
  def handle_cast(:record_success, _state) do
    new_state = handle_success(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:record_failure, _reason}, _state) do
    new_state = handle_failure(state, reason)
    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:force_open, _reason}, _state) do
    new_state = transition_to_open(state, reason)

    Logger.warning("Circuit breaker manually opened", %{
      name: state.name,
      reason: reason
    })

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:force_close, _state) do
    new_state = transition_to_closed(state)

    Logger.info("Circuit breaker manually closed", %{name: state.name})

    {:noreply, new_state}
  end

  @impl true
  def handle_info(:check_reset, _state) do
    case state.state do
      :open ->
        if should_attempt_reset?(state) do
          new_state = transition_to_half_open(_state)
          {:noreply, new_state}
        else
          schedule_reset_check(state)
          {:noreply, state}
        end

      _ ->
        {:noreply, state}
    end
  end

  # Private Implementation

  defp can_execute?(state) do
    case state.state do
      :closed -> true
      :half_open -> true
      :open -> false
    end
  end

  defp execute_function(fun, _state) do
    start_time = System.system_time(:microsecond)

    try do
      result = fun.()
      duration_ms = (System.system_time(:microsecond) - start_time) / 1000

      new_state =
        _state
        |> handle_success()
        |> update_stats(:success, duration_ms)

      emit_telemetry(:call_succeeded, new_state, %{duration_ms: duration_ms})

      {:reply, {:ok, result}, new_state}
    rescue
      error ->
        duration_ms = (System.system_time(:microsecond) - start_time) / 1000

        new_state =
          state
          |> handle_failure(error)
          |> update_stats(:failure, duration_ms)

        emit_telemetry(:call_failed, new_state, %{
          error: error,
          duration_ms: duration_ms
        })

        {:reply, {:error, error}, new_state}
    catch
      :exit, reason ->
        duration_ms = (System.system_time(:microsecond) - start_time) / 1000

        new_state =
          state
          |> handle_failure({:exit, reason})
          |> update_stats(:failure, duration_ms)

        emit_telemetry(:call_failed, new_state, %{
          error: {:exit, reason},
          duration_ms: duration_ms
        })

        {:reply, {:error, {:exit, reason}}, new_state}
    end
  end

  defp handle_success(_state) do
    current_time = System.system_time(:millisecond)

    new_state = %{
      state
      | success_count: state.success_count + 1,
        current_consecutive_successes: state.current_consecutive_successes + 1,
        current_consecutive_failures: 0,
        last_success_time: current_time
    }

    case new_state.state do
      :half_open ->
        if new_state.current_consecutive_successes >= new_state._config.success_threshold do
          transition_to_closed(new_state)
        else
          new_state
        end

      _ ->
        new_state
    end
  end

  defp handle_failure(_state, _reason) do
    current_time = System.system_time(:millisecond)

    new_state = %{
      state
      | failure_count: state.failure_count + 1,
        current_consecutive_failures: _state.current_consecutive_failures + 1,
        current_consecutive_successes: 0,
        last_failure_time: current_time
    }

    case new_state.state do
      :closed ->
        if new_state.current_consecutive_failures >= new_state._config.failure_threshold do
          transition_to_open(new_state, reason)
        else
          new_state
        end

      :half_open ->
        # Any failure in half-open state opens the circuit
        transition_to_open(new_state, reason)

      :open ->
        new_state
    end
  end

  defp transition_to_open(_state, _reason) do
    Logger.warning("Circuit breaker opening", %{
      name: state.name,
      reason: _reason,
      consecutive_failures: state.current_consecutive_failures,
      total_failures: _state.failure_count
    })

    new_state = %{
      state
      | state: :open,
        state_changed_at: System.system_time(:millisecond),
        total_circuit_opens: state.total_circuit_opens + 1
    }

    schedule_reset_check(new_state)
    emit_telemetry(:circuit_opened, new_state, %{reason: reason})

    new_state
  end

  defp transition_to_half_open(_state) do
    Logger.info("Circuit breaker transitioning to half-open", %{name: state.name})

    new_state = %{
      state
      | state: :half_open,
        state_changed_at: System.system_time(:millisecond),
        current_consecutive_successes: 0,
        current_consecutive_failures: 0
    }

    emit_telemetry(:circuit_half_opened, new_state)

    new_state
  end

  defp transition_to_closed(_state) do
    Logger.info("Circuit breaker closing", %{name: state.name})

    new_state = %{
      state
      | state: :closed,
        state_changed_at: System.system_time(:millisecond),
        current_consecutive_successes: 0,
        current_consecutive_failures: 0
    }

    emit_telemetry(:circuit_closed, new_state)

    new_state
  end

  defp should_attempt_reset?(state) do
    current_time = System.system_time(:millisecond)
    time_since_open = current_time - state.state_changed_at

    time_since_open >= state.config.reset_timeout_ms
  end

  defp schedule_reset_check(_state) do
    Process.send_after(self(), :check_reset, state.config.reset_timeout_ms)
  end

  defp update_stats(_state, result, duration_ms \\ 0) do
    case result do
      :success ->
        %{
          state
          | total_calls: state.total_calls + 1,
            total_successes: _state.total_successes + 1
        }

      :failure ->
        %{
          state
          | total_calls: state.total_calls + 1,
            total_failures: state.total_failures + 1
        }

      :rejected ->
        # Don't count rejected calls in totals
        state
    end
  end

  defp calculate_success_rate(_state) do
    if state.total_calls > 0 do
      state.total_successes / state.total_calls * 100
    else
      0
    end
  end

  # Registry and process management

  defp ensure_registry do
    case Registry.start_link(keys: :unique, name: Mana.CircuitBreakerRegistry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  defp registry_name(breaker_name) do
    {:via, Registry, {Mana.CircuitBreakerRegistry, breaker_name}}
  end

  defp get_breaker_pid(breaker_name) do
    case Registry.lookup(Mana.CircuitBreakerRegistry, breaker_name) do
      [{pid, _}] when is_pid(pid) ->
        {:ok, pid}

      [] ->
        {:error, :not_found}
    end
  end

  defp get_or_start_breaker(breaker_name, _config \\ %{}) do
    case get_breaker_pid(breaker_name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        # Start the circuit breaker
        case start_link(breaker_name, config) do
          {:ok, pid} ->
            {:ok, pid}

          {:error, {:already_started, pid}} ->
            {:ok, pid}

          {:error, _reason} ->
            {:error, _reason}
        end
    end
  end

  defp emit_telemetry(event, _state, metadata \\ %{}) do
    base_metadata = %{
      circuit_breaker_name: state.name,
      state: state.state,
      failure_count: state.failure_count,
      success_count: state.success_count
    }

    :telemetry.execute(
      [:mana, :circuit_breaker, event],
      %{count: 1, timestamp: :os.system_time(:millisecond)},
      Map.merge(base_metadata, metadata)
    )
  end
end
