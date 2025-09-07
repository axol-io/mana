defmodule ExWire.LibP2P.Transport do
  @moduledoc """
  LibP2P transport layer implementation.

  Manages TCP/UDP connections and multiplexing for P2P communication.
  """

  use GenServer
  require Logger

  defstruct [
    :port,
    :socket,
    :connections,
    :listeners,
    :protocols
  ]

  # Public API

  @doc """
  Start the transport layer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Dial a peer connection.
  """
  def dial(transport, peer_info) do
    GenServer.call(transport, {:dial, peer_info})
  end

  @doc """
  Listen for incoming connections.
  """
  def listen(transport, port) do
    GenServer.call(transport, {:listen, port})
  end

  @doc """
  Close a connection.
  """
  def close(transport, conn_id) do
    GenServer.cast(transport, {:close, conn_id})
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 30303)

    state = %__MODULE__{
      port: port,
      connections: %{},
      listeners: [],
      protocols: %{}
    }

    {:ok, _state}
  end

  @impl true
  def handle_call({:dial, peer_info}, _from, _state) do
    case establish_connection(peer_info, state) do
      {:ok, conn_id} ->
        new_state = put_in(state.connections[conn_id], peer_info)
        {:reply, {:ok, conn_id}, new_state}

      {:error, _reason} ->
        Logger.warning("Failed to dial peer: #{inspect(reason)}")
        {:reply, {:error, _reason}, state}
    end
  end

  def handle_call({:listen, port}, _from, _state) do
    case :gen_tcp.listen(port, [:binary, active: false, reuseaddr: true]) do
      {:ok, socket} ->
        new_state = %{state | socket: socket, port: port}
        spawn_link(fn -> accept_loop(socket, self()) end)
        {:reply, :ok, new_state}

      {:error, _reason} ->
        {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_cast({:close, conn_id}, _state) do
    new_connections = Map.delete(state.connections, conn_id)
    {:noreply, %{state | connections: new_connections}}
  end

  @impl true
  def handle_info({:new_connection, socket}, _state) do
    conn_id = generate_conn_id()
    new_state = put_in(state.connections[conn_id], %{socket: socket, peer: nil})
    {:noreply, new_state}
  end

  def handle_info({:data, conn_id, data}, _state) do
    # Handle incoming data
    Logger.debug("Received data on connection #{conn_id}: #{byte_size(data)} bytes")
    {:noreply, state}
  end

  # Private functions

  defp establish_connection(peer_info, _state) do
    # Simplified connection establishment
    conn_id = generate_conn_id()

    case connect_to_peer(peer_info) do
      {:ok, _socket} ->
        {:ok, conn_id}

      error ->
        error
    end
  end

  defp connect_to_peer(%{address: address, port: port}) do
    :gen_tcp.connect(String.to_charlist(address), port, [:binary, active: false], 5000)
  end

  defp connect_to_peer(_), do: {:error, :invalid_peer_info}

  defp accept_loop(socket, parent) do
    case :gen_tcp.accept(socket) do
      {:ok, client_socket} ->
        send(parent, {:new_connection, client_socket})
        accept_loop(socket, parent)

      {:error, :closed} ->
        :ok

      {:error, _reason} ->
        Logger.error("Accept error: #{inspect(reason)}")
        accept_loop(socket, parent)
    end
  end

  defp generate_conn_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16()
  end
end
