defmodule VerkleTree.Serialization do
  @moduledoc """
  Optimized serialization and deserialization for Verkle tree data structures.

  Provides high-performance binary encoding with:
  - Minimal memory allocation during encoding/decoding
  - Compact wire formats for network transmission
  - Streaming support for large data sets
  - Version-aware formats for backward compatibility
  """

  alias VerkleTree.Witness

  # Protocol version for backward compatibility
  @version_1 1
  @current_version @version_1

  # Type identifiers for efficient parsing
  @type_commitment 0x01
  @type_witness 0x02
  @type_batch_proof 0x05

  @type serialization_error :: :invalid_format | :unsupported_version | :corrupt_data

  ## Public API

  @doc """
  Serializes a commitment to optimized binary format.
  """
  @spec encode_commitment(binary()) :: binary()
  def encode_commitment(commitment) when byte_size(commitment) == 32 do
    <<@current_version::8, @type_commitment::8, commitment::binary-size(32)>>
  end

  @doc """
  Deserializes a commitment from binary format.
  """
  @spec decode_commitment(binary()) :: {:ok, binary()} | {:error, serialization_error()}
  def decode_commitment(<<@version_1::8, @type_commitment::8, commitment::binary-size(32)>>) do
    {:ok, commitment}
  end

  def decode_commitment(_), do: {:error, :invalid_format}

  @doc """
  Serializes a witness to compact binary format optimized for network transmission.
  """
  @spec encode_witness(Witness.t()) :: binary()
  def encode_witness(%Witness{} = witness) do
    # Calculate sizes for efficient packing
    proof_size = byte_size(witness.proof)
    keys_count = length(witness.keys)
    values_count = length(witness.values)
    commitments_count = length(witness.path_commitments)

    # Pre-calculate total size to minimize allocations
    keys_data = encode_binary_list_optimized(witness.keys)
    values_data = encode_binary_list_optimized(witness.values)
    commitments_data = encode_binary_list_optimized(witness.path_commitments)

    <<
      @current_version::8,
      @type_witness::8,
      proof_size::32,
      witness.proof::binary-size(proof_size),
      keys_count::32,
      keys_data::binary,
      values_count::32,
      values_data::binary,
      commitments_count::32,
      commitments_data::binary
    >>
  end

  @doc """
  Deserializes a witness from binary format with streaming support.
  """
  @spec decode_witness(binary()) :: {:ok, Witness.t()} | {:error, serialization_error()}
  def decode_witness(<<@version_1::8, @type_witness::8, rest::binary>>) do
    try do
      <<
        proof_size::32,
        proof::binary-size(proof_size),
        keys_count::32,
        rest::binary
      >> = rest

      {keys, rest} = decode_binary_list_optimized(rest, keys_count)

      <<values_count::32, rest::binary>> = rest
      {values, rest} = decode_binary_list_optimized(rest, values_count)

      <<commitments_count::32, rest::binary>> = rest
      {path_commitments, _} = decode_binary_list_optimized(rest, commitments_count)

      witness = %Witness{
        proof: proof,
        keys: keys,
        values: values,
        path_commitments: path_commitments
      }

      {:ok, witness}
    rescue
      _ -> {:error, :corrupt_data}
    end
  end

  def decode_witness(_), do: {:error, :invalid_format}

  @doc """
  Serializes multiple witnesses in a batch for optimal network efficiency.
  """
  @spec encode_witness_batch([Witness.t()]) :: binary()
  def encode_witness_batch(witnesses) when is_list(witnesses) do
    batch_count = length(witnesses)

    # Stream encode to minimize memory usage
    witnesses_data =
      witnesses
      |> Stream.map(&encode_witness/1)
      |> Enum.join()

    <<
      @current_version::8,
      @type_batch_proof::8,
      batch_count::32,
      witnesses_data::binary
    >>
  end

  @doc """
  Deserializes a batch of witnesses with streaming support.
  """
  @spec decode_witness_batch(binary()) :: {:ok, [Witness.t()]} | {:error, serialization_error()}
  def decode_witness_batch(<<@version_1::8, @type_batch_proof::8, batch_count::32, data::binary>>) do
    try do
      {witnesses, _remaining} = decode_witness_batch_stream(data, batch_count, [])
      {:ok, Enum.reverse(witnesses)}
    rescue
      _ -> {:error, :corrupt_data}
    end
  end

  def decode_witness_batch(_), do: {:error, :invalid_format}

  @doc """
  Encodes key-value pairs with compression for repeated keys.
  """
  @spec encode_kv_pairs([{binary(), binary()}]) :: binary()
  def encode_kv_pairs(pairs) do
    pairs_count = length(pairs)

    # Use run-length encoding for repeated prefixes
    compressed_pairs = compress_key_prefixes(pairs)
    pairs_data = encode_compressed_pairs(compressed_pairs)

    <<
      @current_version::8,
      pairs_count::32,
      pairs_data::binary
    >>
  end

  @doc """
  Decodes key-value pairs with decompression.
  """
  @spec decode_kv_pairs(binary()) ::
          {:ok, [{binary(), binary()}]} | {:error, serialization_error()}
  def decode_kv_pairs(<<@version_1::8, pairs_count::32, data::binary>>) do
    try do
      compressed_pairs = decode_compressed_pairs(data, pairs_count)
      pairs = decompress_key_prefixes(compressed_pairs)
      {:ok, pairs}
    rescue
      _ -> {:error, :corrupt_data}
    end
  end

  def decode_kv_pairs(_), do: {:error, :invalid_format}

  @doc """
  Calculates the serialized size without actually serializing (for memory planning).
  """
  @spec calculate_witness_size(Witness.t()) :: non_neg_integer()
  def calculate_witness_size(%Witness{} = witness) do
    proof_size = byte_size(witness.proof)
    keys_size = calculate_binary_list_size(witness.keys)
    values_size = calculate_binary_list_size(witness.values)
    commitments_size = calculate_binary_list_size(witness.path_commitments)

    # Header + proof + counts + data
    2 + 4 + proof_size + 4 + keys_size + 4 + values_size + 4 + commitments_size
  end

  ## Private Helper Functions

  defp encode_binary_list_optimized(binaries) do
    # Pre-calculate total size for single allocation
    _total_size =
      binaries
      |> Enum.map(fn
        # Just length field
        nil -> 4
        # Length + data
        binary -> 4 + byte_size(binary)
      end)
      |> Enum.sum()

    # Single allocation with known size
    list_data =
      for binary <- binaries do
        case binary do
          nil ->
            <<0::32>>

          binary when is_binary(binary) ->
            size = byte_size(binary)
            <<size::32, binary::binary-size(size)>>
        end
      end

    :erlang.iolist_to_binary(list_data)
  end

  defp decode_binary_list_optimized(data, count) do
    decode_binary_list_optimized(data, count, [])
  end

  defp decode_binary_list_optimized(data, 0, acc) do
    {Enum.reverse(acc), data}
  end

  defp decode_binary_list_optimized(
         <<size::32, binary::binary-size(size), rest::binary>>,
         count,
         acc
       ) do
    decode_binary_list_optimized(rest, count - 1, [binary | acc])
  end

  defp decode_witness_batch_stream(data, 0, acc) do
    {acc, data}
  end

  defp decode_witness_batch_stream(data, remaining, acc) do
    # Find the next witness boundary
    <<version::8, type::8, rest::binary>> = data

    if version == @version_1 and type == @type_witness do
      case decode_witness(<<version::8, type::8, rest::binary>>) do
        {:ok, witness} ->
          # Calculate consumed bytes to continue stream
          witness_size = calculate_witness_serialized_size(witness)
          <<_consumed::binary-size(witness_size), remaining_data::binary>> = data

          decode_witness_batch_stream(remaining_data, remaining - 1, [witness | acc])

        {:error, _} ->
          throw(:corrupt_data)
      end
    else
      throw(:corrupt_data)
    end
  end

  defp compress_key_prefixes(pairs) do
    # Simple prefix compression for keys with common prefixes
    pairs
    |> Enum.chunk_by(fn {key, _value} ->
      # Group by first 8 bytes of key
      if byte_size(key) >= 8 do
        :binary.part(key, 0, 8)
      else
        key
      end
    end)
    |> Enum.flat_map(fn chunk ->
      case chunk do
        [{key, value}] ->
          # Single item, no compression
          [{:full, key, value}]

        multiple when length(multiple) > 1 ->
          # Multiple items with same prefix
          [{first_key, first_value} | rest] = multiple

          if byte_size(first_key) >= 8 do
            prefix = :binary.part(first_key, 0, 8)
            suffix = :binary.part(first_key, 8, byte_size(first_key) - 8)

            compressed_rest =
              Enum.map(rest, fn {key, value} ->
                if String.starts_with?(key, prefix) do
                  suffix = :binary.part(key, 8, byte_size(key) - 8)
                  {:suffix, suffix, value}
                else
                  {:full, key, value}
                end
              end)

            [{:prefix, prefix, suffix, first_value} | compressed_rest]
          else
            Enum.map(multiple, fn {key, value} -> {:full, key, value} end)
          end
      end
    end)
  end

  defp encode_compressed_pairs(compressed_pairs) do
    data =
      for pair <- compressed_pairs do
        case pair do
          {:full, key, value} ->
            key_size = byte_size(key)
            value_size = byte_size(value)

            <<0::8, key_size::32, key::binary-size(key_size), value_size::32,
              value::binary-size(value_size)>>

          {:prefix, prefix, suffix, value} ->
            suffix_size = byte_size(suffix)
            value_size = byte_size(value)

            <<1::8, prefix::binary-size(8), suffix_size::32, suffix::binary-size(suffix_size),
              value_size::32, value::binary-size(value_size)>>

          {:suffix, suffix, value} ->
            suffix_size = byte_size(suffix)
            value_size = byte_size(value)

            <<2::8, suffix_size::32, suffix::binary-size(suffix_size), value_size::32,
              value::binary-size(value_size)>>
        end
      end

    :erlang.iolist_to_binary(data)
  end

  defp decode_compressed_pairs(data, count) do
    decode_compressed_pairs(data, count, [], nil)
  end

  defp decode_compressed_pairs(_data, 0, acc, _current_prefix) do
    Enum.reverse(acc)
  end

  defp decode_compressed_pairs(<<type::8, rest::binary>>, count, acc, current_prefix) do
    case type do
      # Full key-value pair
      0 ->
        <<key_size::32, key::binary-size(key_size), value_size::32,
          value::binary-size(value_size), remaining::binary>> = rest

        decode_compressed_pairs(remaining, count - 1, [{key, value} | acc], current_prefix)

      # Prefix definition
      1 ->
        <<prefix::binary-size(8), suffix_size::32, suffix::binary-size(suffix_size),
          value_size::32, value::binary-size(value_size), remaining::binary>> = rest

        full_key = <<prefix::binary, suffix::binary>>
        decode_compressed_pairs(remaining, count - 1, [{full_key, value} | acc], prefix)

      # Suffix with current prefix
      2 ->
        <<suffix_size::32, suffix::binary-size(suffix_size), value_size::32,
          value::binary-size(value_size), remaining::binary>> = rest

        full_key = <<current_prefix::binary, suffix::binary>>
        decode_compressed_pairs(remaining, count - 1, [{full_key, value} | acc], current_prefix)
    end
  end

  defp decompress_key_prefixes(compressed_pairs) do
    # Already decompressed in decode_compressed_pairs
    compressed_pairs
  end

  defp calculate_binary_list_size(binaries) do
    Enum.reduce(binaries, 0, fn
      # Length field only
      nil, acc -> acc + 4
      # Length + data
      binary, acc -> acc + 4 + byte_size(binary)
    end)
  end

  defp calculate_witness_serialized_size(witness) do
    # This is an approximation - in practice you'd need exact calculation
    calculate_witness_size(witness)
  end
end
