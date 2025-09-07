defmodule ExWire.Packet.Capability.Eth.V66Wrapper do
  @moduledoc """
  Wrapper for eth/66+ protocol messages that require request IDs.

  This module handles the serialization and deserialization of messages
  with request IDs as specified in EIP-2481.
  """

  alias ExWire.Packet.Capability.Eth.RequestId

  # Message types that require request IDs in eth/66+
  @request_response_messages [
    ExWire.Packet.Capability.Eth.GetBlockHeaders,
    ExWire.Packet.Capability.Eth.BlockHeaders,
    ExWire.Packet.Capability.Eth.GetBlockBodies,
    ExWire.Packet.Capability.Eth.BlockBodies,
    ExWire.Packet.Capability.Eth.GetNodeData,
    ExWire.Packet.Capability.Eth.NodeData,
    ExWire.Packet.Capability.Eth.GetReceipts,
    ExWire.Packet.Capability.Eth.Receipts
  ]

  @doc """
  Wraps a packet with a request ID if required for the given protocol version.

  For eth/66+, request-response message pairs get a request ID prepended.
  For other messages or older protocols, returns the packet unchanged.
  """
  @spec wrap_packet(struct(), integer(), integer() | nil) :: {struct() | map(), integer() | nil}
  def wrap_packet(_packet, version, request_id \\ nil)

  def wrap_packet(_packet, version, request_id) when version >= 66 do
    if requires_request_id?(packet) do
      # Generate request ID if not provided
      req_id = request_id || RequestId.generate()

      # Create wrapped packet with request ID
      wrapped = %{
        request_id: req_id,
        packet: packet
      }

      {wrapped, req_id}
    else
      # Non-request/response messages don't need request IDs
      {packet, nil}
    end
  end

  def wrap_packet(_packet, _version, _request_id) do
    # Pre-eth/66 protocols don't use request IDs
    {packet, nil}
  end

  @doc """
  Unwraps a packet that may contain a request ID.

  For eth/66+ request-response messages, extracts the request ID and inner packet.
  For other messages, returns the packet unchanged.
  """
  @spec unwrap_packet(map() | struct(), integer()) :: {struct(), integer() | nil}
  def unwrap_packet(%{request_id: request_id, packet: _packet}, version) when version >= 66 do
    {packet, request_id}
  end

  def unwrap_packet(_packet, _version) do
    {packet, nil}
  end

  @doc """
  Serializes a packet with request ID support for eth/66+.
  """
  @spec serialize(struct() | map(), integer()) :: ExRLP.t()
  def serialize(%{request_id: request_id, packet: _packet}, version) when version >= 66 do
    # Get the base serialization from the packet module
    packet_module = packet.__struct__
    base_serialization = packet_module.serialize(packet)

    # Prepend request ID
    [request_id | base_serialization]
  end

  def serialize(_packet, _version) do
    # For non-wrapped packets, use normal serialization
    packet_module = packet.__struct__
    packet_module.serialize(packet)
  end

  @doc """
  Deserializes a packet with request ID support for eth/66+.
  """
  @spec deserialize(ExRLP.t(), module(), integer()) :: struct() | map()
  def deserialize(rlp, packet_module, version) when version >= 66 do
    if requires_request_id_module?(packet_module) do
      # Extract request ID and remaining data
      [request_id | remaining] = rlp

      # Deserialize the inner packet
      packet = packet_module.deserialize(remaining)

      # Return wrapped structure
      %{
        request_id: :binary.decode_unsigned(request_id),
        packet: packet
      }
    else
      # Non-request/response messages
      packet_module.deserialize(rlp)
    end
  end

  def deserialize(rlp, packet_module, _version) do
    # Pre-eth/66 protocols
    packet_module.deserialize(rlp)
  end

  @doc """
  Checks if a packet type requires a request ID.
  """
  @spec requires_request_id?(struct()) :: boolean()
  def requires_request_id?(packet) do
    packet.__struct__ in @request_response_messages
  end

  @doc """
  Checks if a packet module requires a request ID.
  """
  @spec requires_request_id_module?(module()) :: boolean()
  def requires_request_id_module?(module) do
    module in @request_response_messages
  end

  @doc """
  Tracks a sent request for correlation with responses.
  """
  @spec track_request(integer(), any()) :: :ok
  def track_request(request_id, context) do
    # Store in ETS or process state for correlation
    :ets.insert(:eth_requests, {request_id, context, System.monotonic_time(:second)})
    :ok
  end

  @doc """
  Retrieves and removes tracked request context for a response.
  """
  @spec get_request_context(integer()) :: {:ok, any()} | {:error, :not_found}
  def get_request_context(request_id) do
    case :ets.lookup(:eth_requests, request_id) do
      [{^request_id, context, _timestamp}] ->
        :ets.delete(:eth_requests, request_id)
        {:ok, context}

      [] ->
        {:error, :not_found}
    end
  end

  @doc """
  Initializes the request tracking table.
  Should be called during application startup.
  """
  @spec init_request_tracking() :: :ok
  def init_request_tracking() do
    if :ets.info(:eth_requests) == :undefined do
      :ets.new(:eth_requests, [:set, :public, :named_table])
    end

    :ok
  end

  @doc """
  Cleans up old requests that haven't received responses.
  """
  @spec cleanup_old_requests(integer()) :: :ok
  def cleanup_old_requests(timeout_seconds \\ 60) do
    current_time = System.monotonic_time(:second)
    cutoff_time = current_time - timeout_seconds

    :ets.select_delete(:eth_requests, [
      {{:_, :_, :"$1"}, [{:<, :"$1", cutoff_time}], [true]}
    ])

    :ok
  end
end
