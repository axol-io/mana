defmodule Common.StatefulService do
  @moduledoc """
  Behavior and implementation for stateful services with built-in persistence,
  recovery, and monitoring capabilities.

  This module provides:
  - Automatic state persistence
  - Crash recovery with state restoration
  - Built-in metrics and health checks
  - Rate limiting and backpressure
  - Graceful shutdown

  ## Example Usage

      defmodule MyApp.SessionManager do
        use Common.StatefulService,
          persist_interval: 30_000,
          max_queue_size: 1000
        
        @impl true
        def init_service(args) do
          {:ok, %{sessions: %{}, config: args}}
        end
        
        @impl true
        def handle_request({:create_session, user_id}, state) do
          session_id = generate_session_id()
          new_state = put_in(state.sessions[session_id], %{user_id: user_id})
          {:ok, session_id, new_state}
        end
        
        @impl true
        def handle_request({:get_session, session_id}, state) do
          case Map.fetch(state.sessions, session_id) do
            {:ok, session} -> {:ok, session, state}
            :error -> {:error, :not_found, state}
          end
        end
      end
  """

  @callback init_service(args :: keyword()) ::
              {:ok, state :: term()}
              | {:error, reason :: term()}

  @callback handle_request(request :: term(), state :: term()) ::
              {:ok, response :: term(), new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}
              | {:async, task :: term(), new_state :: term()}

  @callback handle_event(event :: term(), state :: term()) ::
              {:ok, new_state :: term()}
              | {:error, reason :: term(), new_state :: term()}

  @callback persist_state(state :: term()) ::
              {:ok, binary()}
              | {:error, reason :: term()}

  @callback restore_state(binary()) ::
              {:ok, state :: term()}
              | {:error, reason :: term()}

  @callback health_check(state :: term()) ::
              {:healthy, metadata :: map()}
              | {:degraded, reason :: term(), metadata :: map()}
              | {:unhealthy, reason :: term(), metadata :: map()}

  @optional_callbacks [
    persist_state: 1,
    restore_state: 1,
    health_check: 1,
    handle_event: 2
  ]

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use GenServer
      require Logger

      @behaviour Common.StatefulService

      # Configuration
      @persist_interval unquote(Keyword.get(opts, :persist_interval, 60_000))
      @max_queue_size unquote(Keyword.get(opts, :max_queue_size, 5_000))
      @health_check_interval unquote(Keyword.get(opts, :health_check_interval, 30_000))
      @metrics_interval unquote(Keyword.get(opts, :metrics_interval, 10_000))
      @name unquote(Keyword.get(opts, :name)) || __MODULE__

      defmodule ServiceState do
        @moduledoc false
        defstruct [
          :user_state,
          :queue_size,
          :last_persist,
          :last_health_check,
          :metrics,
          :status,
          :pending_requests
        ]
      end

      # Client API

      def start_link(args \\ []) do
        GenServer.start_link(__MODULE__, args, name: @name)
      end

      def request(server \\ @name, request, timeout \\ 5_000) do
        GenServer.call(server, {:request, request}, timeout)
      end

      def async_request(server \\ @name, request) do
        GenServer.cast(server, {:async_request, request})
      end

      def get_health(server \\ @name) do
        GenServer.call(server, :health_check)
      end

      def get_metrics(server \\ @name) do
        GenServer.call(server, :get_metrics)
      end

      def force_persist(server \\ @name) do
        GenServer.call(server, :force_persist)
      end

      # Server Implementation

      @impl GenServer
      def init(args) do
        Process.flag(:trap_exit, true)

        # Try to restore previous state
        initial_user_state =
          case restore_previous_state() do
            {:ok, state} ->
              Logger.info("#{__MODULE__} restored previous state")
              state

            _ ->
              case init_service(args) do
                {:ok, state} ->
                  state

                {:error, reason} ->
                  Logger.error("Failed to initialize service: #{inspect(reason)}")
                  raise "Service initialization failed: #{inspect(reason)}"
              end
          end

        # Schedule periodic tasks
        schedule_persist()
        schedule_health_check()
        schedule_metrics()

        service_state = %ServiceState{
          user_state: initial_user_state,
          queue_size: 0,
          last_persist: System.system_time(:second),
          last_health_check: System.system_time(:second),
          metrics: init_metrics(),
          status: :healthy,
          pending_requests: %{}
        }

        {:ok, service_state}
      end

      @impl GenServer
      def handle_call({:request, request}, from, state) do
        if state.queue_size >= @max_queue_size do
          {:reply, {:error, :overloaded}, state}
        else
          handle_service_request(request, from, state)
        end
      end

      def handle_call(:health_check, _from, state) do
        health = perform_health_check(state)
        {:reply, health, state}
      end

      def handle_call(:get_metrics, _from, state) do
        {:reply, state.metrics, state}
      end

      def handle_call(:force_persist, _from, state) do
        case persist_current_state(state) do
          :ok ->
            {:reply, :ok, %{state | last_persist: System.system_time(:second)}}

          {:error, reason} = error ->
            {:reply, error, state}
        end
      end

      @impl GenServer
      def handle_cast({:async_request, request}, state) do
        if state.queue_size >= @max_queue_size do
          Logger.warning("Dropping async request due to overload")
          {:noreply, state}
        else
          handle_async_service_request(request, state)
        end
      end

      @impl GenServer
      def handle_info(:persist, _state) do
        schedule_persist()

        case persist_current_state(state) do
          :ok ->
            {:noreply, %{state | last_persist: System.system_time(:second)}}

          {:error, reason} ->
            Logger.error("Failed to persist state: #{inspect(reason)}")
            {:noreply, state}
        end
      end

      def handle_info(:health_check, _state) do
        schedule_health_check()

        health = perform_health_check(state)

        new_status =
          case health do
            {:healthy, _} -> :healthy
            {:degraded, _, _} -> :degraded
            {:unhealthy, _, _} -> :unhealthy
          end

        {:noreply, %{state | status: new_status, last_health_check: System.system_time(:second)}}
      end

      def handle_info(:collect_metrics, _state) do
        schedule_metrics()

        new_metrics = update_metrics(state)
        emit_telemetry_metrics(new_metrics)

        {:noreply, %{state | metrics: new_metrics}}
      end

      def handle_info({ref, result}, state) when is_reference(ref) do
        # Handle async task results
        case Map.pop(state.pending_requests, ref) do
          {nil, _} ->
            {:noreply, state}

          {{from, _request}, pending} ->
            GenServer.reply(from, result)
            new_state = %{state | pending_requests: pending, queue_size: state.queue_size - 1}
            {:noreply, new_state}
        end
      end

      def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
        # Handle failed async tasks
        case Map.pop(state.pending_requests, ref) do
          {nil, _} ->
            {:noreply, state}

          {{from, _request}, pending} ->
            GenServer.reply(from, {:error, :task_failed})
            new_state = %{state | pending_requests: pending, queue_size: state.queue_size - 1}
            {:noreply, new_state}
        end
      end

      @impl GenServer
      def terminate(reason, _state) do
        Logger.info("#{__MODULE__} terminating", reason: reason)

        # Final persist attempt
        persist_current_state(state)

        # Clean up any pending requests
        Enum.each(state.pending_requests, fn {_ref, {from, _}} ->
          GenServer.reply(from, {:error, :shutting_down})
        end)

        :ok
      end

      # Private Functions

      defp handle_service_request(request, from, state) do
        start_time = System.monotonic_time()

        case handle_request(request, state.user_state) do
          {:ok, response, new_user_state} ->
            record_request_metrics(start_time, :success, state)
            new_state = %{state | user_state: new_user_state}
            {:reply, {:ok, response}, new_state}

          {:error, reason, new_user_state} ->
            record_request_metrics(start_time, :error, state)
            new_state = %{state | user_state: new_user_state}
            {:reply, {:error, reason}, new_state}

          {:async, task_fun, new_user_state} ->
            # Spawn async task
            task = Task.async(task_fun)

            new_state = %{
              state
              | user_state: new_user_state,
                pending_requests: Map.put(state.pending_requests, task.ref, {from, request}),
                queue_size: state.queue_size + 1
            }

            {:noreply, new_state}
        end
      end

      defp handle_async_service_request(request, state) do
        case handle_request(request, state.user_state) do
          {:ok, _response, new_user_state} ->
            {:noreply, %{state | user_state: new_user_state}}

          {:error, _reason, new_user_state} ->
            {:noreply, %{state | user_state: new_user_state}}

          {:async, task_fun, new_user_state} ->
            Task.start(task_fun)
            {:noreply, %{state | user_state: new_user_state}}
        end
      end

      defp persist_current_state(state) do
        if function_exported?(__MODULE__, :persist_state, 1) do
          case persist_state(state.user_state) do
            {:ok, data} ->
              path = persistence_path()
              File.write(path, data)

            error ->
              error
          end
        else
          :ok
        end
      end

      defp restore_previous_state do
        if function_exported?(__MODULE__, :restore_state, 1) do
          path = persistence_path()

          case File.read(path) do
            {:ok, data} -> restore_state(data)
            _ -> {:error, :no_persisted_state}
          end
        else
          {:error, :not_implemented}
        end
      end

      defp perform_health_check(state) do
        if function_exported?(__MODULE__, :health_check, 1) do
          health_check(state.user_state)
        else
          # Default health check
          cond do
            state.queue_size > @max_queue_size * 0.9 ->
              {:unhealthy, :queue_full, %{queue_size: state.queue_size}}

            state.queue_size > @max_queue_size * 0.7 ->
              {:degraded, :high_load, %{queue_size: state.queue_size}}

            true ->
              {:healthy, %{queue_size: state.queue_size, status: state.status}}
          end
        end
      end

      defp persistence_path do
        Path.join([
          System.tmp_dir!(),
          "#{__MODULE__ |> to_string() |> String.replace(".", "_")}.state"
        ])
      end

      defp schedule_persist do
        if @persist_interval > 0 do
          Process.send_after(self(), :persist, @persist_interval)
        end
      end

      defp schedule_health_check do
        if @health_check_interval > 0 do
          Process.send_after(self(), :health_check, @health_check_interval)
        end
      end

      defp schedule_metrics do
        if @metrics_interval > 0 do
          Process.send_after(self(), :collect_metrics, @metrics_interval)
        end
      end

      defp init_metrics do
        %{
          total_requests: 0,
          successful_requests: 0,
          failed_requests: 0,
          average_latency: 0,
          p99_latency: 0,
          queue_size: 0
        }
      end

      defp update_metrics(state) do
        Map.merge(state.metrics, %{
          queue_size: state.queue_size,
          status: state.status
        })
      end

      defp record_request_metrics(start_time, result, state) do
        latency = System.monotonic_time() - start_time

        :telemetry.execute(
          [__MODULE__, :request],
          %{latency: latency},
          %{result: result, queue_size: state.queue_size}
        )
      end

      defp emit_telemetry_metrics(metrics) do
        :telemetry.execute(
          [__MODULE__, :metrics],
          metrics,
          %{}
        )
      end

      # Allow overrides
      defoverridable init: 1,
                     handle_call: 3,
                     handle_cast: 2,
                     handle_info: 2,
                     terminate: 2
    end
  end
end
