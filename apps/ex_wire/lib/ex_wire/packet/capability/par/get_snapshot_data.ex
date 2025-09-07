defmodule ExWire.Packet.Capability.Par.GetSnapshotData do
  @moduledoc """
  Request a chunk (identified by the given hash) from a peer.

  ```
  `GetSnapshotData` [`0x13`, `chunk_hash`: B_32]
  ```
  """

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{
          chunk_hash: EVM.hash()
        }

  defstruct [
    :chunk_hash
  ]

  @doc """
  Returns the relative message id offset for this message.
  This will help determine what its message ID is relative to other Packets in the same Capability.
  """
  @impl true
  @spec message_id_offset() :: 0x13
  def message_id_offset do
    0x13
  end

  @doc """
  Given a GetSnapshotData packet, serializes for transport over Eth Wire Protocol.

  ## Examples

      iex> %ExWire.Packet.Capability.Par.GetSnapshotData{chunk_hash: <<1::256>>}
      ...> |> ExWire.Packet.Capability.Par.GetSnapshotData.serialize()
      [<<1::256>>]
  """
  @impl true
  def serialize(%__MODULE__{chunk_hash: chunk_hash}) do
    [
      chunk_hash
    ]
  end

  @doc """
  Given an RLP-encoded GetSnapshotData packet from Eth Wire Protocol,
  decodes into a GetSnapshotData struct.

  ## Examples

      iex> ExWire.Packet.Capability.Par.GetSnapshotData.deserialize([<<1::256>>])
      %ExWire.Packet.Capability.Par.GetSnapshotData{chunk_hash: <<1::256>>}
  """
  @impl true
  def deserialize(rlp) do
    [chunk_hash] = rlp

    %__MODULE__{chunk_hash: chunk_hash}
  end

  @doc """
  Handles a GetSnapshotData request from a peer for a specific chunk.
  We should respond with the requested chunk data if available.

  ## Examples

      iex> %ExWire.Packet.Capability.Par.GetSnapshotData{chunk_hash: <<1::256>>}
      ...> |> ExWire.Packet.Capability.Par.GetSnapshotData.handle(%{peer_id: "test_peer", ip_address: "127.0.0.1"})
      {:ok, %ExWire.Packet.Capability.Par.SnapshotData{}}
  """
  @impl true
  def handle(_packet = %__MODULE__{chunk_hash: chunk_hash}, peer_info \\ %{}) do
    require Logger

    peer_id = Map.get(peer_info, :peer_id, "unknown")
    ip_address = Map.get(peer_info, :ip_address, "unknown")
    chunk_hash_hex = Base.encode16(chunk_hash, case: :lower)

    Logger.debug(
      "[GetSnapshotData] Received chunk request for #{chunk_hash_hex} from peer #{peer_id}"
    )

    # Use the SnapshotServer to handle the request
    case ExWire.Sync.SnapshotServer.handle_chunk_request(peer_id, ip_address, chunk_hash) do
      {:ok, snapshot_data_packet} ->
        Logger.debug("[GetSnapshotData] Serving chunk #{chunk_hash_hex} to peer #{peer_id}")
        {:ok, snapshot_data_packet}

      {:error, :serving_disabled} ->
        Logger.debug("[GetSnapshotData] Serving disabled for peer #{peer_id}")
        {:error, :serving_disabled}

      {:error, :rate_limited} ->
        Logger.debug("[GetSnapshotData] Rate limited chunk request from peer #{peer_id}")
        {:error, :rate_limited}

      {:error, :max_peers_exceeded} ->
        Logger.debug("[GetSnapshotData] Max peers exceeded for peer #{peer_id}")
        {:error, :max_peers_exceeded}

      {:error, :chunk_not_found} ->
        Logger.debug("[GetSnapshotData] Chunk #{chunk_hash_hex} not found for peer #{peer_id}")
        # Return empty response for not found chunks
        empty_response = %ExWire.Packet.Capability.Par.SnapshotData{
          hash: chunk_hash,
          chunk: nil
        }

        {:ok, empty_response}

      {:error, _reason} ->
        Logger.warning(
          "[GetSnapshotData] Failed to serve chunk #{chunk_hash_hex} to peer #{peer_id}: #{inspect(reason)}"
        )

        {:error, _reason}
    end
  end
end
