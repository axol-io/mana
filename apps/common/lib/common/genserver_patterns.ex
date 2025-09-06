defmodule Common.GenServerPatterns do
  @moduledoc """
  Idiomatic GenServer patterns and behaviors for consistent implementation across the codebase.

  This module provides:
  - Standard GenServer behavior with proper state management
  - Consistent error handling and recovery
  - Built-in telemetry and monitoring
  - Proper supervision tree integration
  - Memory-efficient state management

  ## Usage

      defmodule MyServer do
        use Common.GenServerPatterns
        
        # Define your state structure
        defstate do
          field :counter, integer(), default: 0
          field :buffer, list(), default: []
          field :config, map(), required: true
        end
        
        # Implement initialization
        def init_state(args) do
          %State{
            config: Keyword.fetch!(args, :config)
          }
        end
        
        # Define handlers using pattern matching
        defcall :increment do
          state = update_in(state.counter, &(&1 + 1))
          {:reply, state.counter, state}
        end
        
        defcast {:add_to_buffer, item} do
          state = update_in(state.buffer, &[item | &1])
          {:noreply, state}
        end
      end
  """

  defmacro __using__(opts \\ []) do
    quote location: :keep do
      use GenServer
      require Logger
      import Common.GenServerPatterns

      @behaviour Common.GenServerPatterns.Behaviour

      # Configuration
      @restart_strategy unquote(Keyword.get(opts, :restart, :permanent))
      @shutdown_timeout unquote(Keyword.get(opts, :shutdown, 5_000))
      @hibernate_after unquote(Keyword.get(opts, :hibernate_after, 60_000))

      # Telemetry configuration
      @telemetry_prefix unquote(Keyword.get(opts, :telemetry_prefix)) ||
                          [
                            __MODULE__
                            |> Module.split()
                            |> Enum.map(&Macro.underscore/1)
                            |> Enum.map(&String.to_atom/1)
                          ]

      # Standard client API

      def start_link(args \\ []) do
        name = Keyword.get(args, :name, __MODULE__)
        GenServer.start_link(__MODULE__, args, name: name)
      end

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [args]},
          restart: @restart_strategy,
          shutdown: @shutdown_timeout,
          type: :worker
        }
      end

      def stop(server \\ __MODULE__, reason \\ :normal, timeout \\ 5_000) do
        GenServer.stop(server, reason, timeout)
      end

      # Standard server callbacks with telemetry

      @impl GenServer
      def init(args) do
        Process.flag(:trap_exit, true)

        # Schedule hibernation if configured
        if @hibernate_after > 0 do
          Process.send_after(self(), :check_hibernate, @hibernate_after)
        end

        # Initialize telemetry
        emit_telemetry(:init, %{}, %{args: args})

        # Call user initialization
        case init_state(args) do
          {:ok, state} ->
            emit_telemetry(:ready, %{}, %{})
            {:ok, state}

          {:ok, state, timeout} ->
            emit_telemetry(:ready, %{}, %{})
            {:ok, state, timeout}

          {:error, reason} = error ->
            emit_telemetry(:init_error, %{}, %{reason: reason})
            {:stop, reason}

          state when is_struct(state) ->
            emit_telemetry(:ready, %{}, %{})
            {:ok, state}
        end
      end

      @impl GenServer
      def terminate(reason, _state) do
        emit_telemetry(:terminate, %{}, %{reason: reason})

        # Call user cleanup if defined
        if function_exported?(__MODULE__, :cleanup_state, 2) do
          cleanup_state(reason, state)
        end

        :ok
      end

      @impl GenServer
      def handle_info(:check_hibernate, _state) do
        # Check if we should hibernate based on message queue
        if should_hibernate?() do
          emit_telemetry(:hibernate, %{}, %{})
          {:noreply, state, :hibernate}
        else
          Process.send_after(self(), :check_hibernate, @hibernate_after)
          {:noreply, state}
        end
      end

      def handle_info(msg, _state) do
        # Default handler for unmatched messages
        Logger.warning("Unhandled message in #{__MODULE__}: #{inspect(msg)}")
        {:noreply, state}
      end

      # Helper functions

      defp emit_telemetry(event, measurements, metadata) do
        :telemetry.execute(
          @telemetry_prefix ++ [event],
          measurements,
          Map.merge(metadata, %{pid: self(), module: __MODULE__})
        )
      end

      defp should_hibernate? do
        {:message_queue_len, len} = Process.info(self(), :message_queue_len)
        len == 0
      end

      # Allow overrides
      defoverridable init: 1,
                     terminate: 2,
                     handle_info: 2,
                     child_spec: 1
    end
  end

  @doc """
  Defines the state structure for the GenServer.

  ## Example

      defstate do
        field :counter, integer(), default: 0
        field :name, String.t(), required: true
        field :buffer, list(), default: []
      end
  """
  defmacro defstate(do: block) do
    quote do
      defmodule State do
        @moduledoc false
        defstruct unquote(block)

        @type t :: %__MODULE__{}
      end
    end
  end

  @doc """
  Defines a synchronous call handler with pattern matching.

  ## Examples

      defcall :get_state do
        {:reply, state, state}
      end
      
      defcall {:add, value}, %{from: from} do
        new_state = update_in(state.counter, &(&1 + value))
        {:reply, :ok, new_state}
      end
  """
  defmacro defcall(pattern, opts \\ [], do: body) do
    {function_name, pattern} = extract_function_and_pattern(pattern)
    from_var = Keyword.get(opts, :from, quote(do: _from))

    quote do
      @impl GenServer
      def handle_call(unquote(pattern), unquote(from_var), state) do
        start_time = System.monotonic_time()

        result = unquote(body)

        emit_telemetry(
          :call,
          %{duration: System.monotonic_time() - start_time},
          %{call: unquote(function_name)}
        )

        result
      end
    end
  end

  @doc """
  Defines an asynchronous cast handler with pattern matching.

  ## Examples

      defcast {:update, value} do
        new_state = %{state | value: value}
        {:noreply, new_state}
      end
  """
  defmacro defcast(pattern, do: body) do
    {function_name, pattern} = extract_function_and_pattern(pattern)

    quote do
      @impl GenServer
      def handle_cast(unquote(pattern), _state) do
        start_time = System.monotonic_time()

        result = unquote(body)

        emit_telemetry(
          :cast,
          %{duration: System.monotonic_time() - start_time},
          %{cast: unquote(function_name)}
        )

        result
      end
    end
  end

  @doc """
  Defines an info handler with pattern matching.

  ## Examples

      definfo :timeout do
        {:noreply, %{state | timed_out: true}}
      end
      
      definfo {:data, data} do
        new_state = process_data(state, data)
        {:noreply, new_state}
      end
  """
  defmacro definfo(pattern, do: body) do
    {function_name, pattern} = extract_function_and_pattern(pattern)

    quote do
      @impl GenServer
      def handle_info(unquote(pattern), _state) do
        start_time = System.monotonic_time()

        result = unquote(body)

        emit_telemetry(
          :info,
          %{duration: System.monotonic_time() - start_time},
          %{info: unquote(function_name)}
        )

        result
      end
    end
  end

  @doc """
  Defines a continuous handler that reschedules itself.

  ## Example

      defcontinue :cleanup, interval: 60_000 do
        cleaned_state = cleanup_old_entries(state)
        {:noreply, cleaned_state}
      end
  """
  defmacro defcontinue(name, opts \\ [], do: body) do
    interval = Keyword.get(opts, :interval, 5_000)
    initial_delay = Keyword.get(opts, :initial_delay, interval)

    quote do
      @impl GenServer
      def handle_info(unquote(name), _state) do
        result = unquote(body)
        Process.send_after(self(), unquote(name), unquote(interval))
        result
      end

      # Add to init to schedule first run
      def init(args) do
        Process.send_after(self(), unquote(name), unquote(initial_delay))
        super(args)
      end
    end
  end

  # Helper functions

  defp extract_function_and_pattern(pattern) when is_atom(pattern) do
    {pattern, pattern}
  end

  defp extract_function_and_pattern({function, _meta, args}) when is_atom(function) do
    pattern = {function, [], args || []}
    {function, pattern}
  end

  defp extract_function_and_pattern(pattern) do
    {:unknown, pattern}
  end

  defmodule Behaviour do
    @moduledoc """
    Behaviour that must be implemented by modules using GenServerPatterns.
    """
    @callback init_state(keyword()) ::
                {:ok, struct()}
                | {:ok, struct(), timeout()}
                | {:error, term()}
                | struct()

    @callback cleanup_state(reason :: term(), state :: struct()) :: :ok

    @optional_callbacks cleanup_state: 2
  end
end
