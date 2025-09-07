defmodule ExWire.P2P do
  @moduledoc """
  High-level P2P networking interface.

  Provides simplified access to peer management and messaging.
  """

  alias ExWire.P2P.Manager
  alias ExWire.LibP2P.PeerManager

  @doc """
  Get the current peer count.
  """
  def get_peer_count do
    case Process.whereis(Manager) do
      nil ->
        {:error, :not_started}

      pid ->
        peers = GenServer.call(pid, :get_peers)
        {:ok, length(peers)}
    end
  rescue
    _ -> {:error, :unavailable}
  end

  @doc """
  Get connected peers.
  """
  def get_peers do
    case Process.whereis(PeerManager) do
      nil -> []
      pid -> GenServer.call(pid, :get_peers)
    end
  rescue
    _ -> []
  end

  @doc """
  Send a message to a peer.
  """
  def send_message(peer_id, message) do
    case Process.whereis(Manager) do
      nil -> {:error, :not_started}
      pid -> GenServer.cast(pid, {:send_message, peer_id, message})
    end
  end

  @doc """
  Broadcast a message to all peers.
  """
  def broadcast(message) do
    peers = get_peers()

    Enum.each(peers, fn peer ->
      send_message(peer.id, message)
    end)
  end
end
