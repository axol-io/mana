defmodule ExWire.LibP2P.RPC do
  @moduledoc """
  RPC protocol handler for LibP2P.

  Manages request/response patterns and streaming for P2P communication.
  """

  use GenServer
  require Logger

  defstruct [
    :parent_pid,
    :handlers,
    :pending_requests,
    :request_timeout
  ]

  @request_timeout_ms 10_000

  # Public API

  @doc """
  Start the RPC handler.
  """
  def start_link(parent_pid) do
    GenServer.start_link(__MODULE__, parent_pid, name: __MODULE__)
  end

  @doc """
  Send an RPC request to a peer.
  """
  def request(rpc, peer_id, method, _params) do
    GenServer.call(rpc, {:request, peer_id, method, params}, @request_timeout_ms + 1000)
  end

  @doc """
  Send a one-way notification to a peer.
  """
  def notify(rpc, peer_id, method, _params) do
    GenServer.cast(rpc, {:notify, peer_id, method, params})
  end

  @doc """
  Register a handler for a specific RPC method.
  """
  def register_handler(rpc, method, handler_fun) do
    GenServer.call(rpc, {:register_handler, method, handler_fun})
  end

  @doc """
  Stream data to a peer.
  """
  def stream(rpc, peer_id, stream_id, data) do
    GenServer.cast(rpc, {:stream, peer_id, stream_id, data})
  end

  # GenServer callbacks

  @impl true
  def init(parent_pid) do
    state = %__MODULE__{
      parent_pid: parent_pid,
      handlers: %{},
      pending_requests: %{},
      request_timeout: @request_timeout_ms
    }

    # Register default handlers
    register_default_handlers(state)
  end

  @impl true
  def handle_call({:request, peer_id, method, _params}, from, _state) do
    request_id = generate_request_id()

    request_info = %{
      id: request_id,
      peer_id: peer_id,
      method: method,
      params: params,
      from: from,
      sent_at: System.system_time(:millisecond)
    }

    # Store pending request
    new_pending = Map.put(state.pending_requests, request_id, request_info)

    # Send request to peer
    send_rpc_request(peer_id, request_id, method, params, state)

    # Set timeout
    Process.send_after(self(), {:request_timeout, request_id}, state.request_timeout)

    {:noreply, %{state | pending_requests: new_pending}}
  end

  def handle_call({:register_handler, method, handler_fun}, _from, _state) do
    new_handlers = Map.put(state.handlers, method, handler_fun)
    {:reply, :ok, %{state | handlers: new_handlers}}
  end

  @impl true
  def handle_cast({:notify, peer_id, method, _params}, _state) do
    send_rpc_notification(peer_id, method, params, state)
    {:noreply, state}
  end

  def handle_cast({:stream, peer_id, stream_id, data}, _state) do
    send_stream_data(peer_id, stream_id, data, state)
    {:noreply, state}
  end

  @impl true
  def handle_info({:rpc_request, peer_id, request_id, method, _params}, _state) do
    # Handle incoming RPC request
    case Map.get(state.handlers, method) do
      nil ->
        send_rpc_error(peer_id, request_id, "Method not found", _state)

      handler ->
        # Execute handler asynchronously
        Task.start(fn ->
          case handler.(_params) do
            {:ok, result} ->
              send(self(), {:rpc_response_ready, peer_id, request_id, result})

            {:error, error} ->
              send(self(), {:rpc_error_ready, peer_id, request_id, error})
          end
        end)
    end

    {:noreply, state}
  end

  def handle_info({:rpc_response, _peer_id, request_id, result}, _state) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        Logger.warning("Received response for unknown request: #{request_id}")
        {:noreply, state}

      request_info ->
        # Reply to waiting caller
        GenServer.reply(request_info.from, {:ok, result})

        # Clean up pending request
        new_pending = Map.delete(state.pending_requests, request_id)
        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  def handle_info({:request_timeout, request_id}, _state) do
    case Map.get(state.pending_requests, request_id) do
      nil ->
        {:noreply, _state}

      request_info ->
        Logger.warning("RPC request timeout: #{request_info.method} to #{request_info.peer_id}")
        GenServer.reply(request_info.from, {:error, :timeout})

        new_pending = Map.delete(state.pending_requests, request_id)
        {:noreply, %{state | pending_requests: new_pending}}
    end
  end

  def handle_info({:rpc_response_ready, peer_id, request_id, result}, _state) do
    send_rpc_response(peer_id, request_id, result, state)
    {:noreply, state}
  end

  def handle_info({:rpc_error_ready, peer_id, request_id, error}, _state) do
    send_rpc_error(peer_id, request_id, error, state)
    {:noreply, state}
  end

  # Private functions

  defp register_default_handlers(_state) do
    %{
      state
      | handlers: %{
          "ping" => fn _params -> {:ok, "pong"} end,
          "version" => fn _params -> {:ok, "LibP2P/1.0"} end,
          "status" => fn _params -> {:ok, %{connected: true}} end
        }
    }
  end

  defp send_rpc_request(peer_id, request_id, method, _params, _state) do
    message = %{
      type: :request,
      id: request_id,
      method: method,
      params: params
    }

    if state.parent_pid do
      send(state.parent_pid, {:send_to_peer, peer_id, message})
    end
  end

  defp send_rpc_response(peer_id, request_id, result, _state) do
    message = %{
      type: :response,
      id: request_id,
      result: result
    }

    if state.parent_pid do
      send(state.parent_pid, {:send_to_peer, peer_id, message})
    end
  end

  defp send_rpc_error(peer_id, request_id, error, _state) do
    message = %{
      type: :error,
      id: request_id,
      error: error
    }

    if state.parent_pid do
      send(state.parent_pid, {:send_to_peer, peer_id, message})
    end
  end

  defp send_rpc_notification(peer_id, method, _params, _state) do
    message = %{
      type: :notification,
      method: method,
      params: params
    }

    if state.parent_pid do
      send(state.parent_pid, {:send_to_peer, peer_id, message})
    end
  end

  defp send_stream_data(peer_id, stream_id, data, _state) do
    message = %{
      type: :stream,
      stream_id: stream_id,
      data: data
    }

    if state.parent_pid do
      send(state.parent_pid, {:send_to_peer, peer_id, message})
    end
  end

  defp generate_request_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16()
  end
end
