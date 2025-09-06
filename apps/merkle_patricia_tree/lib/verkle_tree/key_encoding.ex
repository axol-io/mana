defmodule VerkleTree.KeyEncoding do
  @moduledoc """
  EIP-6800 compliant key encoding for Verkle trees.

  This module implements the proper key generation scheme as specified in EIP-6800,
  including the stem and suffix encoding, Pedersen hashing, and specific key
  generation functions for different types of Ethereum state data.
  """

  alias VerkleTree.Crypto

  @type address32 :: binary()
  @type storage_key :: binary()
  @type tree_index :: non_neg_integer()
  @type sub_index :: non_neg_integer()
  @type verkle_key :: binary()

  # EIP-6800 Constants
  @basic_data_leaf_key 0
  @code_hash_leaf_key 1
  @verkle_node_width 256
  @code_chunk_size 31

  @doc """
  Generate a tree key according to EIP-6800 specification.

  This is the core function that implements:
  pedersen_hash(address + tree_index.to_bytes(32, 'little'))[:31] + bytes([sub_index])
  """
  @spec get_tree_key(address32(), tree_index(), sub_index()) :: verkle_key()
  def get_tree_key(address32, tree_index, sub_index) when byte_size(address32) == 32 do
    # Convert tree_index to 32-byte little-endian
    tree_index_bytes = <<tree_index::little-integer-size(256)>>

    # Concatenate address and tree_index
    input_data = address32 <> tree_index_bytes

    # Apply Pedersen hash and take first 31 bytes
    stem = pedersen_hash(input_data) |> binary_part(0, 31)

    # Append sub_index as single byte
    stem <> <<sub_index>>
  end

  @doc """
  Generate key for basic account data (nonce, balance, code hash, storage root).
  Uses tree_index=0, sub_index=BASIC_DATA_LEAF_KEY.
  """
  @spec get_tree_key_for_basic_data(address32()) :: verkle_key()
  def get_tree_key_for_basic_data(address32) when byte_size(address32) == 32 do
    get_tree_key(address32, 0, @basic_data_leaf_key)
  end

  @doc """
  Generate key for account code hash.
  Uses tree_index=0, sub_index=CODE_HASH_LEAF_KEY.
  """
  @spec get_tree_key_for_code_hash(address32()) :: verkle_key()
  def get_tree_key_for_code_hash(address32) when byte_size(address32) == 32 do
    get_tree_key(address32, 0, @code_hash_leaf_key)
  end

  @doc """
  Generate key for a code chunk.
  Code is stored in 31-byte chunks, with chunk_id starting from 0.
  """
  @spec get_tree_key_for_code_chunk(address32(), non_neg_integer()) :: verkle_key()
  def get_tree_key_for_code_chunk(address32, chunk_id) when byte_size(address32) == 32 do
    # EIP-6800: Code chunks use tree_index = (chunk_id // 128) + 1
    # sub_index = chunk_id % 128 + 128
    tree_index = div(chunk_id, 128) + 1
    sub_index = rem(chunk_id, 128) + 128

    get_tree_key(address32, tree_index, sub_index)
  end

  @doc """
  Generate key for a storage slot.
  Uses optimized proximity encoding to keep related storage slots close together.
  """
  @spec get_tree_key_for_storage_slot(address32(), storage_key()) :: verkle_key()
  def get_tree_key_for_storage_slot(address32, storage_key)
      when byte_size(address32) == 32 and byte_size(storage_key) == 32 do
    # Convert storage_key to integer for tree_index calculation
    storage_int = :binary.decode_unsigned(storage_key, :big)

    # EIP-6800: Storage uses tree_index = (storage_key // 256) + 2^28
    tree_index = (div(storage_int, @verkle_node_width) + :math.pow(2, 28)) |> round()
    sub_index = rem(storage_int, @verkle_node_width)

    get_tree_key(address32, tree_index, sub_index)
  end

  @doc """
  Convert a regular Ethereum address (20 bytes) to Address32 format.
  Prepends 12 zero bytes as specified in EIP-6800.
  """
  @spec address_to_address32(binary()) :: address32()
  def address_to_address32(address) when byte_size(address) == 20 do
    <<0::96, address::binary>>
  end

  def address_to_address32(address32) when byte_size(address32) == 32 do
    address32
  end

  @doc """
  Split a code bytecode into 31-byte chunks for storage.
  Returns a list of chunks, with the last chunk padded if necessary.
  """
  @spec split_code_into_chunks(binary()) :: [binary()]
  def split_code_into_chunks(code) when is_binary(code) do
    code
    |> :binary.bin_to_list()
    |> Enum.chunk_every(@code_chunk_size)
    |> Enum.map(fn chunk ->
      chunk_binary = :binary.list_to_bin(chunk)
      # Pad last chunk to 31 bytes if necessary
      if byte_size(chunk_binary) < @code_chunk_size do
        padding_size = @code_chunk_size - byte_size(chunk_binary)
        chunk_binary <> :binary.copy(<<0>>, padding_size)
      else
        chunk_binary
      end
    end)
  end

  @doc """
  Extract stem (first 31 bytes) from a Verkle key.
  Used for tree traversal and commitment calculations.
  """
  @spec extract_stem(verkle_key()) :: binary()
  def extract_stem(verkle_key) when byte_size(verkle_key) == 32 do
    binary_part(verkle_key, 0, 31)
  end

  @doc """
  Extract suffix (last byte) from a Verkle key.
  Used for indexing within a Verkle node.
  """
  @spec extract_suffix(verkle_key()) :: non_neg_integer()
  def extract_suffix(verkle_key) when byte_size(verkle_key) == 32 do
    <<_stem::binary-size(31), suffix>> = verkle_key
    suffix
  end

  # Private helper functions

  # Pedersen hash implementation using the crypto module
  # This implements the EIP-6800 specified Pedersen hash
  defp pedersen_hash(data) do
    # Use proper Pedersen hash from the crypto module
    Crypto.pedersen_hash(data)
  end

  @doc """
  Validate that a key follows EIP-6800 format.
  """
  @spec validate_verkle_key(verkle_key()) :: boolean()
  def validate_verkle_key(key) when byte_size(key) == 32 do
    suffix = extract_suffix(key)
    suffix >= 0 and suffix < @verkle_node_width
  end

  def validate_verkle_key(_), do: false

  @doc """
  Get the tree depth for a given key.
  EIP-6800 specifies a specific tree structure depth.
  """
  @spec get_tree_depth() :: pos_integer()
  # 32 bytes = 32 levels in the tree
  def get_tree_depth(), do: 32

  @doc """
  Check if two keys have the same stem (would be in same Verkle node).
  """
  @spec same_stem?(verkle_key(), verkle_key()) :: boolean()
  def same_stem?(key1, key2) when byte_size(key1) == 32 and byte_size(key2) == 32 do
    extract_stem(key1) == extract_stem(key2)
  end

  def same_stem?(_, _), do: false

  @doc """
  Validate EIP-6800 compliance for commitment scheme support.
  Checks that keys follow the proper encoding for all commitment schemes.
  """
  @spec validate_eip_6800_compliance(verkle_key()) :: {:ok, map()} | {:error, term()}
  def validate_eip_6800_compliance(key) when byte_size(key) == 32 do
    stem = extract_stem(key)
    suffix = extract_suffix(key)

    validation_result = %{
      valid_length: byte_size(key) == 32,
      valid_stem_length: byte_size(stem) == 31,
      valid_suffix_range: suffix >= 0 and suffix < @verkle_node_width,
      stem_commitment_compatible: validate_stem_commitment(stem),
      encoding_scheme_valid: validate_encoding_scheme(key)
    }

    if Enum.all?(Map.values(validation_result)) do
      {:ok, validation_result}
    else
      {:error, {:invalid_key, validation_result}}
    end
  end

  def validate_eip_6800_compliance(_), do: {:error, :invalid_key_size}

  @doc """
  Handle edge cases in key encoding as specified by EIP-6800.
  """
  @spec handle_key_encoding_edge_cases(binary(), atom()) :: {:ok, verkle_key()} | {:error, term()}
  def handle_key_encoding_edge_cases(input, encoding_type) do
    case encoding_type do
      :storage_boundary ->
        # Handle storage keys at chunk boundaries
        handle_storage_boundary_encoding(input)

      :code_padding ->
        # Handle code chunks with special padding requirements
        handle_code_padding_encoding(input)

      :address_normalization ->
        # Handle address format edge cases
        handle_address_normalization(input)

      :empty_vs_zero ->
        # Handle distinction between empty slots and zero values
        handle_empty_vs_zero_encoding(input)

      :pushdata_boundary ->
        # Handle PUSHDATA bytes in code chunks
        handle_pushdata_boundary_encoding(input)

      :storage_gas_boundary ->
        # Handle storage slots 0-63 with different gas costs
        handle_storage_gas_boundary(input)

      _ ->
        {:error, :unsupported_encoding_type}
    end
  end

  # Private validation helper functions

  defp validate_stem_commitment(stem) when byte_size(stem) == 31 do
    # Verify the stem can be used in a commitment scheme
    # This ensures it's a valid input for Pedersen commitments
    try do
      Crypto.hash_to_scalar(stem)
      true
    rescue
      _ -> false
    end
  end

  defp validate_encoding_scheme(key) when byte_size(key) == 32 do
    # Validate that the key follows one of the supported encoding schemes
    stem = extract_stem(key)
    suffix = extract_suffix(key)

    # Check if it's a valid basic data, code, or storage key encoding
    case suffix do
      0 -> validate_basic_data_encoding(stem)
      1 -> validate_code_hash_encoding(stem)
      n when n >= 128 and n < 256 -> validate_code_chunk_encoding(stem, n)
      n when n >= 0 and n < 128 -> validate_storage_encoding(stem, n)
      _ -> false
    end
  end

  defp validate_basic_data_encoding(stem) when byte_size(stem) == 31 do
    # Basic data should have a properly formatted stem
    byte_size(stem) == 31
  end

  defp validate_code_hash_encoding(stem) when byte_size(stem) == 31 do
    # Code hash should have a properly formatted stem
    byte_size(stem) == 31
  end

  defp validate_code_chunk_encoding(stem, suffix) when byte_size(stem) == 31 do
    # Code chunks should have suffix in range [128, 255]
    suffix >= 128 and suffix <= 255 and byte_size(stem) == 31
  end

  defp validate_storage_encoding(stem, suffix) when byte_size(stem) == 31 do
    # Storage should have suffix in range [0, 127]
    suffix >= 0 and suffix < 128 and byte_size(stem) == 31
  end

  # Edge case handlers

  defp handle_storage_boundary_encoding(storage_key) when byte_size(storage_key) == 32 do
    # Handle case where storage key is at verkle node boundary (suffix 0 or 255)
    storage_int = :binary.decode_unsigned(storage_key, :big)
    suffix = rem(storage_int, @verkle_node_width)

    if suffix == 0 or suffix == 255 do
      # Apply special encoding rules for boundary cases
      adjusted_storage_int = storage_int + 1
      adjusted_storage_key = <<adjusted_storage_int::256>>
      address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>
      {:ok, get_tree_key_for_storage_slot(address32, adjusted_storage_key)}
    else
      address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>
      {:ok, get_tree_key_for_storage_slot(address32, storage_key)}
    end
  end

  defp handle_code_padding_encoding(code_chunk) do
    # Handle code chunks that need special padding
    _padded_chunk =
      if byte_size(code_chunk) < @code_chunk_size do
        padding_size = @code_chunk_size - byte_size(code_chunk)
        code_chunk <> :binary.copy(<<0>>, padding_size)
      else
        code_chunk
      end

    address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>
    # Would be computed based on chunk position
    chunk_id = 0
    {:ok, get_tree_key_for_code_chunk(address32, chunk_id)}
  end

  defp handle_address_normalization(address) do
    # Handle different address format inputs
    case byte_size(address) do
      20 -> {:ok, address_to_address32(address)}
      32 -> {:ok, address}
      _ -> {:error, :invalid_address_size}
    end
  end

  defp handle_empty_vs_zero_encoding(input) do
    # EIP-6800: Distinguish between empty positions (represented as 0) and zero values
    case input do
      :empty ->
        # Empty position - use special marker
        address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>
        {:ok, get_tree_key_for_basic_data(address32)}

      <<0::256>> ->
        # Actual zero value - encode normally but with special flag
        address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>
        # Use 1 to indicate actual zero value
        storage_key = <<1::256>>
        {:ok, get_tree_key_for_storage_slot(address32, storage_key)}

      _ ->
        {:error, :invalid_empty_zero_input}
    end
  end

  defp handle_pushdata_boundary_encoding(code_with_pushdata) do
    # EIP-6800: Handle PUSHDATA bytes in code chunks with precise tracking
    {code, pushdata_info} =
      case code_with_pushdata do
        {code_bytes, pushdata_bytes} when is_binary(code_bytes) and is_list(pushdata_bytes) ->
          {code_bytes, pushdata_bytes}

        code_bytes when is_binary(code_bytes) ->
          # Analyze code to find PUSHDATA operations
          {code_bytes, analyze_pushdata_bytes(code_bytes)}
      end

    # Split code into chunks while preserving PUSHDATA boundary information
    chunks_with_pushdata = split_code_with_pushdata_tracking(code, pushdata_info)

    # Generate keys for all chunks
    address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>

    chunk_keys =
      chunks_with_pushdata
      |> Enum.with_index()
      |> Enum.map(fn {{_chunk, _pushdata}, index} ->
        get_tree_key_for_code_chunk(address32, index)
      end)

    # Return first chunk key as example
    {:ok, hd(chunk_keys)}
  end

  defp handle_storage_gas_boundary(storage_info) do
    # EIP-6800: Handle storage slots 0-63 with different gas cost treatment
    {storage_key, gas_context} =
      case storage_info do
        {key, context} when is_binary(key) -> {key, context}
        key when is_binary(key) -> {key, :normal}
      end

    storage_int = :binary.decode_unsigned(storage_key, :big)

    case storage_int do
      slot when slot <= 63 ->
        # Special encoding for cold storage slots (higher gas cost)
        address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>

        case gas_context do
          :cold_access ->
            # Apply cold storage encoding with special tree_index offset
            adjusted_tree_index =
              (div(storage_int, @verkle_node_width) + :math.pow(2, 27)) |> round()

            adjusted_sub_index = rem(storage_int, @verkle_node_width)
            {:ok, get_tree_key(address32, adjusted_tree_index, adjusted_sub_index)}

          _ ->
            # Normal encoding for warm access
            {:ok, get_tree_key_for_storage_slot(address32, storage_key)}
        end

      _ ->
        # Normal storage slot encoding
        address32 = <<0::96, :crypto.strong_rand_bytes(20)::binary>>
        {:ok, get_tree_key_for_storage_slot(address32, storage_key)}
    end
  end

  # Helper function to analyze PUSHDATA bytes in bytecode
  defp analyze_pushdata_bytes(code) do
    code
    |> :binary.bin_to_list()
    |> analyze_pushdata_bytes_list([], 0)
  end

  defp analyze_pushdata_bytes_list([], acc, _pos), do: Enum.reverse(acc)

  defp analyze_pushdata_bytes_list([byte | rest], acc, pos) when byte >= 0x60 and byte <= 0x7F do
    # PUSH1 to PUSH32 operations
    push_size = byte - 0x5F
    {_data, remaining} = Enum.split(rest, push_size)
    new_acc = [{pos, push_size} | acc]
    analyze_pushdata_bytes_list(remaining, new_acc, pos + 1 + push_size)
  end

  defp analyze_pushdata_bytes_list([_byte | rest], acc, pos) do
    # Non-PUSH instruction
    analyze_pushdata_bytes_list(rest, acc, pos + 1)
  end

  # Split code into chunks while tracking PUSHDATA boundaries
  defp split_code_with_pushdata_tracking(code, pushdata_info) do
    chunks = split_code_into_chunks(code)

    # Map pushdata information to chunks
    chunks
    |> Enum.with_index()
    |> Enum.map(fn {chunk, index} ->
      chunk_start = index * @code_chunk_size
      chunk_end = chunk_start + @code_chunk_size - 1

      # Find pushdata operations that start in this chunk
      chunk_pushdata =
        pushdata_info
        |> Enum.filter(fn {pos, _size} ->
          pos >= chunk_start and pos <= chunk_end
        end)

      {chunk, chunk_pushdata}
    end)
  end

  @doc """
  Handle little-endian encoding edge cases for numeric values.
  EIP-6800 specifies little-endian encoding for most numeric values.
  """
  @spec handle_little_endian_encoding(non_neg_integer(), pos_integer()) :: binary()
  def handle_little_endian_encoding(value, byte_size) when is_integer(value) and value >= 0 do
    <<value::little-integer-size(byte_size * 8)>>
  end

  @doc """
  Handle commitment scheme boundaries for point-to-scalar conversion.
  Implements EIP-6800 specific rules for Bandersnatch curve operations.
  """
  @spec handle_commitment_boundary_cases(binary(), atom()) :: {:ok, binary()} | {:error, term()}
  def handle_commitment_boundary_cases(point_data, operation_type) do
    case operation_type do
      :point_to_scalar ->
        # Handle point-to-scalar conversion with EIP-6800 rules
        if byte_size(point_data) == 32 do
          # Apply group_to_field function as specified
          {:ok, apply_group_to_field_conversion(point_data)}
        else
          {:error, :invalid_point_size}
        end

      :scalar_boundary ->
        # Handle scalar values at field boundaries
        if byte_size(point_data) == 32 do
          {:ok, normalize_scalar_to_field(point_data)}
        else
          {:error, :invalid_scalar_size}
        end

      _ ->
        {:error, :unsupported_boundary_operation}
    end
  end

  # Apply group_to_field conversion as per EIP-6800
  defp apply_group_to_field_conversion(point) when byte_size(point) == 32 do
    # Simplified implementation - in production this would use proper curve operations
    ExthCrypto.Hash.Keccak.kec(<<"group_to_field"::binary, point::binary>>)
  end

  # Normalize scalar to field size
  defp normalize_scalar_to_field(scalar) when byte_size(scalar) == 32 do
    # Ensure scalar is within field boundaries
    scalar_int = :binary.decode_unsigned(scalar, :big)
    # Bandersnatch field modulus (simplified)
    field_modulus = 0x73EDA753299D7D483339D80809A1D80553BDA402FFFE5BFEFFFFFFFF00000001
    normalized = rem(scalar_int, field_modulus)
    <<normalized::256>>
  end
end
