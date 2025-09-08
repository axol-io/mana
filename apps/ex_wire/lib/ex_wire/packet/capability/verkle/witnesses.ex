defmodule ExWire.Packet.Capability.Verkle.Witnesses do
  @moduledoc """
  Witnesses packet containing Verkle witness proofs.

  This packet delivers compact witness proofs that enable stateless verification
  of state data without requiring the full state tree.
  """

  @behaviour ExWire.Packet

  alias VerkleTree.Witness

  @type witness_data :: %{
          key: binary(),
          value: binary() | nil,
          witness: Witness.t(),
          witness_size: non_neg_integer()
        }

  @type t :: %__MODULE__{
          request_id: non_neg_integer(),
          root_commitment: binary(),
          witnesses: [witness_data()],
          total_witnesses: non_neg_integer(),
          compression_used: boolean(),
          witness_type: atom()
        }

  defstruct [
    :request_id,
    :root_commitment,
    :witnesses,
    :total_witnesses,
    compression_used: false,
    witness_type: :standard
  ]

  @doc """
  Serialize the Witnesses packet to RLP format.
  """
  @spec serialize(t()) :: iodata()
  def serialize(%__MODULE__{
        request_id: request_id,
        root_commitment: root_commitment,
        witnesses: witnesses,
        total_witnesses: total_witnesses,
        compression_used: compression_used,
        witness_type: witness_type
      }) do
    witness_type_byte = encode_witness_type(witness_type)
    compression_byte = if compression_used, do: 0x01, else: 0x00

    serialized_witnesses = Enum.map(witnesses, &serialize_witness_data/1)

    ExRLP.encode([
      request_id,
      root_commitment,
      serialized_witnesses,
      total_witnesses,
      compression_byte,
      witness_type_byte
    ])
  end

  @doc """
  Deserialize RLP data into a Witnesses packet.
  """
  @spec deserialize(iodata()) :: t()
  def deserialize(rlp_data) do
    [
      request_id,
      root_commitment,
      serialized_witnesses,
      total_witnesses,
      compression_byte,
      witness_type_byte
    ] =
      ExRLP.decode(rlp_data)

    witnesses = Enum.map(serialized_witnesses, &deserialize_witness_data/1)
    compression_used = compression_byte == 0x01
    witness_type = decode_witness_type(witness_type_byte)

    %__MODULE__{
      request_id: request_id,
      root_commitment: root_commitment,
      witnesses: witnesses,
      total_witnesses: total_witnesses,
      compression_used: compression_used,
      witness_type: witness_type
    }
  end

  @doc """
  Get the packet type identifier.
  """
  def packet_type, do: :witnesses

  @doc """
  Validate the Witnesses packet structure.
  """
  @spec validate(t()) :: {:ok, t()} | {:error, term()}
  def validate(%__MODULE__{witnesses: witnesses, total_witnesses: total} = _packet)
      when length(witnesses) != total do
    {:error, :witness_count_mismatch}
  end

  def validate(%__MODULE__{root_commitment: root} = _packet) when byte_size(root) != 32 do
    {:error, :invalid_root_commitment}
  end

  def validate(%__MODULE__{witnesses: witnesses} = _packet) do
    if Enum.all?(witnesses, &validate_witness_data/1) do
      {:ok, _packet}
    else
      {:error, :invalid_witness_data}
    end
  end

  def validate(_), do: {:error, :invalid_packet_structure}

  @doc """
  Create a witnesses response packet.
  """
  @spec create_response(non_neg_integer(), binary(), [witness_data()], keyword()) :: t()
  def create_response(request_id, root_commitment, witnesses, opts \\ []) do
    compression_used = Keyword.get(opts, :compression, false)
    witness_type = Keyword.get(opts, :witness_type, :standard)

    processed_witnesses =
      if compression_used do
        compress_witnesses(witnesses)
      else
        witnesses
      end

    %__MODULE__{
      request_id: request_id,
      root_commitment: root_commitment,
      witnesses: processed_witnesses,
      total_witnesses: length(processed_witnesses),
      compression_used: compression_used,
      witness_type: witness_type
    }
  end

  @doc """
  Extract key-value pairs from all witnesses.
  """
  @spec extract_key_value_pairs(t()) :: [{binary(), binary() | nil}]
  def extract_key_value_pairs(%__MODULE__{witnesses: witnesses}) do
    Enum.map(witnesses, fn %{key: key, value: value} -> {key, value} end)
  end

  @doc """
  Calculate total witness data size.
  """
  @spec calculate_total_size(t()) :: non_neg_integer()
  def calculate_total_size(%__MODULE__{witnesses: witnesses}) do
    Enum.reduce(witnesses, 0, fn %{witness_size: size}, acc -> acc + size end)
  end

  @doc """
  Verify all witnesses in the packet against the root commitment.
  """
  @spec verify_all_witnesses(t()) :: boolean()
  def verify_all_witnesses(%__MODULE__{witnesses: witnesses, root_commitment: root}) do
    Enum.all?(witnesses, fn %{key: key, value: value, witness: witness} ->
      VerkleTree.verify_witness(witness, root, [{key, value}])
    end)
  end

  # Private helper functions

  defp serialize_witness_data(%{key: key, value: value, witness: witness}) do
    witness_binary = Witness.serialize(witness)
    witness_size = byte_size(witness_binary)

    [key, value || <<>>, witness_binary, witness_size]
  end

  defp deserialize_witness_data([key, value_binary, witness_binary, witness_size]) do
    witness = Witness.deserialize(witness_binary)
    value = if byte_size(value_binary) == 0, do: nil, else: value_binary

    %{
      key: key,
      value: value,
      witness: witness,
      witness_size: witness_size
    }
  end

  defp validate_witness_data(%{key: key, witness: witness}) do
    byte_size(key) == 32 and is_struct(witness, Witness)
  end

  defp validate_witness_data(_), do: false

  defp compress_witnesses(witnesses) do
    # Apply witness compression algorithms
    # For now, return as-is (compression would be implemented here)
    witnesses
  end

  defp encode_witness_type(:standard), do: 0x00
  defp encode_witness_type(:healing), do: 0x01
  defp encode_witness_type(:range), do: 0x02
  defp encode_witness_type(_), do: 0x00

  defp decode_witness_type(0x00), do: :standard
  defp decode_witness_type(0x01), do: :healing
  defp decode_witness_type(0x02), do: :range
  defp decode_witness_type(_), do: :standard
end
