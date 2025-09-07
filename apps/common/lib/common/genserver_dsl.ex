defmodule Common.GenServerDSL do
  @moduledoc """
  DSL for defining GenServers with minimal boilerplate and maximum idiomaticity.

  This module provides a declarative way to define GenServers that automatically
  handles common patterns like state management, API generation, and telemetry.

  ## Example

      defmodule MyApp.Counter do
        use Common.GenServerDSL
        
        genserver name: :counter do
          # State definition
          state counter: 0, step: 1
          
          # Automatically generates MyApp.Counter.increment/0
          call increment do
            reply state.counter + state.step
            update counter: state.counter + state.step
          end
          
          # Automatically generates MyApp.Counter.reset/0
          cast reset do
            update counter: 0
          end
          
          # Handle arbitrary messages
          info :tick do
            update counter: state.counter + 1
          end
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import Common.GenServerDSL
    end
  end

  @doc """
  Main DSL macro for defining a GenServer.
  """
  defmacro genserver(opts \\ [], do: block) do
    name = Keyword.get(opts, :name, :__MODULE__)
    restart = Keyword.get(opts, :restart, :permanent)
    shutdown = Keyword.get(opts, :shutdown, 5_000)

    quote do
      use GenServer
      require Logger

      @name unquote(name)
      @restart unquote(restart)
      @shutdown unquote(shutdown)

      # Process the DSL block
      unquote(block)

      # Standard start_link and child_spec
      def start_link(args \\ []) do
        server_name = if @name == :__MODULE__, do: __MODULE__, else: @name
        GenServer.start_link(__MODULE__, args, name: server_name)
      end

      def child_spec(args) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [args]},
          restart: @restart,
          shutdown: @shutdown,
          type: :worker
        }
      end

      # Default init if not overridden
      if !Module.defines?(__MODULE__, {:init, 1}) do
        def init(args) do
          {:ok, struct(__MODULE__.State, args)}
        end
      end

      # Stop function
      def stop(server \\ server_name(), reason \\ :normal, timeout \\ 5_000) do
        GenServer.stop(server, reason, timeout)
      end

      defp server_name do
        if @name == :__MODULE__, do: __MODULE__, else: @name
      end
    end
  end

  @doc """
  Defines the state structure for the GenServer.

  ## Example

      state counter: 0, buffer: [], config: %{}
  """
  defmacro state(fields) do
    field_specs =
      Enum.map(fields, fn {name, default} ->
        {name, [], [default]}
      end)

    quote do
      defmodule State do
        @moduledoc false
        defstruct unquote(field_specs)

        @type t :: %__MODULE__{
                unquote_splicing(
                  Enum.map(fields, fn {name, _} ->
                    {name, quote(do: any())}
                  end)
                )
              }
      end

      # Helper to access state in handlers
      defp state, do: var!(state)
    end
  end

  @doc """
  Defines a synchronous call handler with automatic API function generation.

  ## Example

      call get_value do
        reply state.value
      end
      
      call {:set_value, value} do
        reply :ok
        update value: value
      end
  """
  defmacro call(signature, do: body) do
    {function_name, pattern, params} = parse_signature(signature)

    # Generate client function
    client_function =
      quote do
        def unquote(function_name)(unquote_splicing(params), server \\ server_name()) do
          GenServer.call(server, unquote(pattern))
        end
      end

    # Generate server handler
    server_handler =
      quote do
        def handle_call(unquote(pattern), _from, state) do
          unquote(process_handler_body(body, :call))
        end
      end

    [client_function, server_handler]
  end

  @doc """
  Defines an asynchronous cast handler with automatic API function generation.

  ## Example

      cast {:add_to_buffer, item} do
        update buffer: [item | state.buffer]
      end
  """
  defmacro cast(signature, do: body) do
    {function_name, pattern, params} = parse_signature(signature)

    # Generate client function
    client_function =
      quote do
        def unquote(function_name)(unquote_splicing(params), server \\ server_name()) do
          GenServer.cast(server, unquote(pattern))
        end
      end

    # Generate server handler
    server_handler =
      quote do
        def handle_cast(unquote(pattern), _state) do
          unquote(process_handler_body(body, :cast))
        end
      end

    [client_function, server_handler]
  end

  @doc """
  Defines an info handler for handling messages.

  ## Example

      info :timeout do
        update timed_out: true
      end
  """
  defmacro info(pattern, do: body) do
    quote do
      def handle_info(unquote(pattern), _state) do
        unquote(process_handler_body(body, :info))
      end
    end
  end

  @doc """
  Reply macro for use in call handlers.
  """
  defmacro reply(value) do
    quote do
      {:reply, unquote(value), var!(state)}
    end
  end

  @doc """
  Reply with state update macro.
  """
  defmacro reply(value, updates) do
    quote do
      {:reply, unquote(value), update_state(var!(state), unquote(updates))}
    end
  end

  @doc """
  Update state macro for use in handlers.
  """
  defmacro update(updates) do
    quote do
      {:noreply, update_state(var!(state), unquote(updates))}
    end
  end

  @doc """
  No reply macro.
  """
  defmacro noreply do
    quote do
      {:noreply, var!(state)}
    end
  end

  @doc """
  Stop macro for terminating the GenServer.
  """
  defmacro stop(reason) do
    quote do
      {:stop, unquote(reason), var!(state)}
    end
  end

  @doc """
  Continue macro for handle_continue.
  """
  defmacro continue(term) do
    quote do
      {:noreply, var!(state), {:continue, unquote(term)}}
    end
  end

  # Private helper functions

  defp parse_signature(atom) when is_atom(atom) do
    {atom, atom, []}
  end

  defp parse_signature({function, _meta, nil}) when is_atom(function) do
    {function, function, []}
  end

  defp parse_signature({function, _meta, args}) when is_atom(function) do
    pattern = {function, [], args}
    params = extract_params(args)
    {function, pattern, params}
  end

  defp parse_signature(pattern) do
    {:unknown, pattern, []}
  end

  defp extract_params(args) do
    Enum.map(args, fn
      {name, _, _} when is_atom(name) -> Macro.var(name, nil)
      _ -> Macro.var(:_, nil)
    end)
  end

  defp process_handler_body(body, type) do
    # Transform the body DSL into proper GenServer return values
    case body do
      {:__block__, _, statements} ->
        process_statements(statements, type)

      single_statement ->
        process_statement(single_statement, type)
    end
  end

  defp process_statements(statements, type) do
    Enum.map(statements, &process_statement(&1, type))
    |> List.last()
  end

  defp process_statement({:reply, _, _} = stmt, :call), do: stmt
  defp process_statement({:update, _, _} = stmt, _), do: stmt
  defp process_statement({:noreply, _, _} = stmt, _), do: stmt
  defp process_statement({:stop, _, _} = stmt, _), do: stmt
  defp process_statement({:continue, _, _} = stmt, _), do: stmt
  defp process_statement(stmt, _), do: stmt
end

defmodule Common.GenServerDSL.Helpers do
  @moduledoc """
  Helper functions for GenServerDSL.
  """

  @doc """
  Updates state with the given keyword list of changes.
  """
  def update_state(state, updates) do
    Enum.reduce(updates, state, fn {key, value}, acc ->
      Map.put(acc, key, value)
    end)
  end
end
