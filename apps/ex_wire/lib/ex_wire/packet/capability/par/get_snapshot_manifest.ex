defmodule ExWire.Packet.Capability.Par.GetSnapshotManifest do
  @moduledoc """
  Request a snapshot manifest in RLP form from a peer.

  ```
  `GetSnapshotManifest` [`0x11`]
  ```
  """

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{}

  defstruct []

  @doc """
  Returns the relative message id offset for this message.
  This will help determine what its message ID is relative to other Packets in the same Capability.
  """
  @impl true
  @spec message_id_offset() :: 0x11
  def message_id_offset do
    0x11
  end

  @doc """
  Given a GetSnapshotManifest packet, serializes for transport over Eth Wire Protocol.

  ## Examples

      iex> %ExWire.Packet.Capability.Par.GetSnapshotManifest{}
      ...> |> ExWire.Packet.Capability.Par.GetSnapshotManifest.serialize()
      []
  """
  @impl true
  def serialize(_packet = %__MODULE__{}) do
    []
  end

  @doc """
  Given an RLP-encoded GetSnapshotManifest packet from Eth Wire Protocol,
  decodes into a GetSnapshotManifest struct.

  ## Examples

      iex> ExWire.Packet.Capability.Par.GetSnapshotManifest.deserialize([])
      %ExWire.Packet.Capability.Par.GetSnapshotManifest{}
  """
  @impl true
  def deserialize(rlp) do
    [] = rlp

    %__MODULE__{}
  end

  @doc """
  Handles a GetSnapshotManifest request from a peer.
  We should respond with our current snapshot manifest.

  ## Examples

      iex> %ExWire.Packet.Capability.Par.GetSnapshotManifest{}
      ...> |> ExWire.Packet.Capability.Par.GetSnapshotManifest.handle(%{peer_id: "test_peer", ip_address: "127.0.0.1"})
      {:ok, %ExWire.Packet.Capability.Par.SnapshotManifest{}}
  """
  @impl true
  def handle(_packet = %__MODULE__{}, peer_info \\ %{}) do
    require Logger

    peer_id = Map.get(peer_info, :peer_id, "unknown")
    ip_address = Map.get(peer_info, :ip_address, "unknown")

    Logger.debug("[GetSnapshotManifest] Received manifest request from peer #{peer_id}")

    # Use the SnapshotServer to handle the request
    case ExWire.Sync.SnapshotServer.handle_manifest_request(peer_id, ip_address) do
      {:ok, manifest_packet} ->
        Logger.debug("[GetSnapshotManifest] Serving manifest to peer #{peer_id}")
        {:ok, manifest_packet}

      {:error, :serving_disabled} ->
        Logger.debug(
          "[GetSnapshotManifest] Serving disabled, sending empty manifest to peer #{peer_id}"
        )

        {:ok, %ExWire.Packet.Capability.Par.SnapshotManifest{manifest: nil}}

      {:error, :rate_limited} ->
        Logger.debug("[GetSnapshotManifest] Rate limited request from peer #{peer_id}")
        {:error, :rate_limited}

      {:error, :max_peers_exceeded} ->
        Logger.debug("[GetSnapshotManifest] Max peers exceeded for peer #{peer_id}")
        {:error, :max_peers_exceeded}

      {:error, _reason} ->
        Logger.warning(
          "[GetSnapshotManifest] Failed to serve manifest to peer #{peer_id}: #{inspect(reason)}"
        )

        {:ok, %ExWire.Packet.Capability.Par.SnapshotManifest{manifest: nil}}
    end
  end
end
