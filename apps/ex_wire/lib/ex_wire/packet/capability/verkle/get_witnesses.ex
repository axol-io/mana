defmodule ExWire.Packet.Capability.Verkle.GetWitnesses do
  @moduledoc """
  GetWitnesses packet for requesting Verkle witnesses.

  This packet allows efficient batched witness requests for multiple keys,
  optimizing network usage by grouping related witness requests.
  """

  @behaviour ExWire.Packet

  @type t :: %__MODULE__{
          request_id: non_neg_integer(),
          root_commitment: binary(),
          keys: [binary()],
          max_witnesses: non_neg_integer(),
          witness_type: atom()
        }

  defstruct [
    :request_id,
    :root_commitment,
    :keys,
    max_witnesses: 256,
    witness_type: :standard
  ]

  @doc """
  Given a GetWitnesses packet, serialize it to RLP format.
  """
  @spec serialize(t()) :: iodata()
  def serialize(%__MODULE__{
        request_id: request_id,
        root_commitment: root_commitment,
        keys: keys,
        max_witnesses: max_witnesses,
        witness_type: witness_type
      }) do
    witness_type_byte = encode_witness_type(witness_type)

    ExRLP.encode([
      request_id,
      root_commitment,
      keys,
      max_witnesses,
      witness_type_byte
    ])
  end

  @doc """
  Given RLP data, deserialize it into a GetWitnesses packet.
  """
  @spec deserialize(iodata()) :: t()
  def deserialize(rlp_data) do
    [request_id, root_commitment, keys, max_witnesses, witness_type_byte] =
      ExRLP.decode(rlp_data)

    witness_type = decode_witness_type(witness_type_byte)

    %__MODULE__{
      request_id: request_id,
      root_commitment: root_commitment,
      keys: keys,
      max_witnesses: max_witnesses,
      witness_type: witness_type
    }
  end

  @doc """
  Get the packet type identifier.
  """
  def packet_type, do: :get_witnesses

  @doc """
  Validate the GetWitnesses packet structure.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{keys: keys} = _packet) when length(keys) > 256 do
    {:error, :too_many_keys}
  end

  def validate(%__MODULE__{root_commitment: root} = _packet) when byte_size(root) != 32 do
    {:error, :invalid_root_commitment}
  end

  def validate(%__MODULE__{keys: keys} = _packet) do
    if Enum.all?(keys, &(byte_size(&1) == 32)) do
      {:ok, _packet}
    else
      {:error, :invalid_key_format}
    end
  end

  def validate(_), do: {:error, :invalid_packet_structure}

  @doc """
  Create a batch witness request for multiple keys.
  """
  @spec create_batch_request(non_neg_integer(), binary(), [binary()], keyword()) :: t()
  def create_batch_request(request_id, root_commitment, keys, opts \\ []) do
    max_witnesses = Keyword.get(opts, :max_witnesses, 256)
    witness_type = Keyword.get(opts, :witness_type, :standard)

    %__MODULE__{
      request_id: request_id,
      root_commitment: root_commitment,
      keys: Enum.take(keys, max_witnesses),
      max_witnesses: max_witnesses,
      witness_type: witness_type
    }
  end

  @doc """
  Create a healing witness request for state recovery.
  """
  @spec create_healing_request(non_neg_integer(), binary(), [binary()]) :: t()
  def create_healing_request(request_id, root_commitment, keys) do
    %__MODULE__{
      request_id: request_id,
      root_commitment: root_commitment,
      keys: keys,
      max_witnesses: length(keys),
      witness_type: :healing
    }
  end

  # Private helper functions

  defp encode_witness_type(:standard), do: 0x00
  defp encode_witness_type(:healing), do: 0x01
  defp encode_witness_type(:range), do: 0x02
  defp encode_witness_type(_), do: 0x00

  defp decode_witness_type(0x00), do: :standard
  defp decode_witness_type(0x01), do: :healing
  defp decode_witness_type(0x02), do: :range
  defp decode_witness_type(_), do: :standard
end
