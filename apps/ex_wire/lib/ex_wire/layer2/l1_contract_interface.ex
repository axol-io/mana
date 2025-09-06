defmodule ExWire.Layer2.L1ContractInterface do
  @moduledoc """
  Interface for interacting with L1 smart contracts.

  Provides ABI encoding/decoding and contract interaction utilities
  for Optimism, Arbitrum, and other L2 protocols.
  """

  require Logger
  alias ExWire.Layer2.Web3Client

  # ABI definitions for common L2 contract methods
  @optimism_portal_abi %{
    "depositTransaction" => %{
      signature: "depositTransaction(address,uint256,uint64,bool,bytes)",
      selector: "0xe9e05c42"
    },
    "proveWithdrawalTransaction" => %{
      signature:
        "proveWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes),uint256,(bytes32,bytes32,bytes32,bytes32),bytes[])",
      selector: "0x4870496f"
    },
    "finalizeWithdrawalTransaction" => %{
      signature: "finalizeWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes))",
      selector: "0x8c3152e9"
    }
  }

  @l2_output_oracle_abi %{
    "proposeL2Output" => %{
      signature: "proposeL2Output(bytes32,uint256,bytes32,uint256)",
      selector: "0x9aaab648"
    },
    "getL2Output" => %{
      signature: "getL2Output(uint256)",
      selector: "0xa25ae557"
    },
    "latestOutputIndex" => %{
      signature: "latestOutputIndex()",
      selector: "0x69f16eec"
    }
  }

  @arbitrum_bridge_abi %{
    "depositEth" => %{
      signature: "depositEth()",
      selector: "0x439370b1"
    },
    "outboundTransfer" => %{
      signature: "outboundTransfer(address,address,uint256,uint256,uint256,bytes)",
      selector: "0xd2ce7d65"
    }
  }

  @doc """
  Calls a contract method with proper ABI encoding.
  """
  @spec call_contract(String.t(), String.t(), String.t(), list()) ::
          {:ok, any()} | {:error, term()}
  def call_contract(contract_address, method_name, abi_signature, params) do
    with {:ok, encoded_data} <- encode_function_call(abi_signature, params),
         {:ok, result} <- Web3Client.call_contract(contract_address, encoded_data) do
      decode_result(result, abi_signature)
    end
  end

  @doc """
  Sends a transaction to a contract method.
  """
  @spec send_transaction(String.t(), String.t(), String.t(), list(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def send_transaction(contract_address, method_name, abi_signature, params, tx_options \\ %{}) do
    with {:ok, encoded_data} <- encode_function_call(abi_signature, params) do
      tx_params =
        Map.merge(tx_options, %{
          to: contract_address,
          data: "0x" <> Base.encode16(encoded_data, case: :lower)
        })

      Web3Client.send_transaction(tx_params)
    end
  end

  @doc """
  Submits an L2 output to the L2OutputOracle contract (Optimism).
  """
  @spec submit_l2_output(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def submit_l2_output(oracle_address, output_data) do
    params = [
      output_data.output_root,
      output_data.l2_block_number,
      output_data.l1_blockhash,
      output_data.l1_block_number
    ]

    abi = @l2_output_oracle_abi["proposeL2Output"]
    send_transaction(oracle_address, "proposeL2Output", abi.signature, params)
  end

  @doc """
  Gets the latest L2 output index from the oracle.
  """
  @spec get_latest_output_index(String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def get_latest_output_index(oracle_address) do
    abi = @l2_output_oracle_abi["latestOutputIndex"]

    with {:ok, encoded_data} <- encode_function_call(abi.signature, []),
         {:ok, result} <- Web3Client.call_contract(oracle_address, encoded_data) do
      {:ok, decode_uint256(result)}
    end
  end

  @doc """
  Initiates a deposit transaction through OptimismPortal.
  """
  @spec deposit_transaction(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def deposit_transaction(portal_address, deposit_params) do
    params = [
      deposit_params.to,
      deposit_params.value,
      deposit_params.gas_limit,
      deposit_params.is_creation || false,
      deposit_params.data || <<>>
    ]

    abi = @optimism_portal_abi["depositTransaction"]

    tx_options = %{
      value: deposit_params.mint || 0
    }

    send_transaction(portal_address, "depositTransaction", abi.signature, params, tx_options)
  end

  @doc """
  Proves a withdrawal transaction on L1.
  """
  @spec prove_withdrawal(String.t(), map(), map()) :: {:ok, String.t()} | {:error, term()}
  def prove_withdrawal(portal_address, withdrawal, proof) do
    withdrawal_tuple = [
      withdrawal.nonce,
      withdrawal.sender,
      withdrawal.target,
      withdrawal.value,
      withdrawal.gas_limit,
      withdrawal.data
    ]

    output_root_proof = [
      proof.version,
      proof.state_root,
      proof.message_passer_storage_root,
      proof.latest_block_hash
    ]

    params = [
      withdrawal_tuple,
      proof.l2_output_index,
      output_root_proof,
      proof.withdrawal_proof
    ]

    abi = @optimism_portal_abi["proveWithdrawalTransaction"]
    send_transaction(portal_address, "proveWithdrawalTransaction", abi.signature, params)
  end

  @doc """
  Finalizes a withdrawal transaction after the challenge period.
  """
  @spec finalize_withdrawal(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  def finalize_withdrawal(portal_address, withdrawal) do
    withdrawal_tuple = [
      withdrawal.nonce,
      withdrawal.sender,
      withdrawal.target,
      withdrawal.value,
      withdrawal.gas_limit,
      withdrawal.data
    ]

    params = [withdrawal_tuple]

    abi = @optimism_portal_abi["finalizeWithdrawalTransaction"]
    send_transaction(portal_address, "finalizeWithdrawalTransaction", abi.signature, params)
  end

  @doc """
  Deposits ETH to Arbitrum L2.
  """
  @spec deposit_eth_arbitrum(String.t(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, term()}
  def deposit_eth_arbitrum(bridge_address, amount) do
    abi = @arbitrum_bridge_abi["depositEth"]

    tx_options = %{
      value: amount
    }

    send_transaction(bridge_address, "depositEth", abi.signature, [], tx_options)
  end

  @doc """
  Encodes a function call with ABI encoding.
  """
  @spec encode_function_call(String.t(), list()) :: {:ok, binary()} | {:error, term()}
  def encode_function_call(signature, params) do
    # Extract function selector (first 4 bytes of keccak256 hash)
    selector = get_function_selector(signature)

    # Encode parameters
    encoded_params = encode_parameters(signature, params)

    {:ok, selector <> encoded_params}
  rescue
    error ->
      Logger.error("Failed to encode function call: #{inspect(error)}")
      {:error, :encoding_failed}
  end

  defp get_function_selector(signature) do
    signature
    |> ExthCrypto.Hash.Keccak.kec()
    |> Binary.take(4)
  end

  defp encode_parameters(signature, params) do
    # Parse parameter types from signature
    types = parse_parameter_types(signature)

    # Encode each parameter according to its type
    params
    |> Enum.zip(types)
    |> Enum.map(&encode_parameter/1)
    |> Enum.join()
  end

  defp parse_parameter_types(signature) do
    # Extract types from function signature
    # e.g., "transfer(address,uint256)" -> ["address", "uint256"]
    signature
    |> String.split("(")
    |> List.last()
    |> String.trim_trailing(")")
    |> String.split(",")
    |> Enum.map(&String.trim/1)
  end

  defp encode_parameter({value, "address"}) do
    # Encode address (20 bytes, left-padded to 32 bytes)
    value
    |> String.replace_prefix("0x", "")
    |> Base.decode16!(case: :mixed)
    |> pad_left(32)
    |> Base.encode16(case: :lower)
  end

  defp encode_parameter({value, "uint256"}) do
    # Encode uint256 (32 bytes, big-endian)
    value
    |> :binary.encode_unsigned(:big)
    |> pad_left(32)
    |> Base.encode16(case: :lower)
  end

  defp encode_parameter({value, "uint64"}) do
    # Encode uint64 as uint256
    encode_parameter({value, "uint256"})
  end

  defp encode_parameter({value, "bool"}) do
    # Encode boolean as uint256 (0 or 1)
    bool_value = if value, do: 1, else: 0
    encode_parameter({bool_value, "uint256"})
  end

  defp encode_parameter({value, "bytes32"}) do
    # Encode bytes32 (32 bytes)
    value
    |> String.replace_prefix("0x", "")
    |> Base.decode16!(case: :mixed)
    |> pad_right(32)
    |> Base.encode16(case: :lower)
  end

  defp encode_parameter({value, "bytes"}) do
    # Encode dynamic bytes
    # Offset (32 bytes) + Length (32 bytes) + Data (padded to 32 bytes)
    data = if is_binary(value), do: value, else: <<>>
    length = byte_size(data)
    padded_data = pad_to_32_bytes(data)

    offset = encode_parameter({32, "uint256"})
    encoded_length = encode_parameter({length, "uint256"})

    offset <> encoded_length <> Base.encode16(padded_data, case: :lower)
  end

  defp encode_parameter({values, type}) when is_binary(type) do
    if String.ends_with?(type, "[]") do
      # Encode dynamic array
      base_type = String.trim_trailing(type, "[]")
      length = length(values)

      # Encode array length
      encoded_length = encode_parameter({length, "uint256"})

      # Encode array elements
    encoded_elements =
      values
      |> Enum.map(fn v -> encode_parameter({v, base_type}) end)
      |> Enum.join()

    encoded_length <> encoded_elements
    else
      if String.starts_with?(type, "(") do
        # Encode tuple
        encode_tuple(values, type)
      else
        # Default case - treat as single value
        encode_parameter_value(values, type)
      end
    end
  end

  defp encode_parameter({value, type}) do
    # Default: try to encode as specific type
    encode_parameter_value(value, type)
  end

  defp encode_parameter_value(value, "uint256") when is_integer(value) do
    value
    |> Integer.to_string(16)
    |> String.pad_leading(64, "0")
    |> String.downcase()
  end

  defp encode_parameter_value(value, "address") when is_binary(value) do
    value
    |> String.trim_leading("0x")
    |> String.pad_leading(64, "0")
    |> String.downcase()
  end

  defp encode_parameter_value(value, "bool") when is_boolean(value) do
    if value do
      String.duplicate("0", 63) <> "1"
    else
      String.duplicate("0", 64)
    end
  end

  defp encode_parameter_value(value, "bytes32") when is_binary(value) do
    value
    |> String.trim_leading("0x")
    |> String.pad_trailing(64, "0")
    |> String.downcase()
  end

  defp encode_parameter_value(value, "bytes") when is_binary(value) do
    # For dynamic bytes, encode length + data
    data = if String.starts_with?(value, "0x"), do: String.slice(value, 2..-1), else: value
    byte_length = div(String.length(data), 2)
    
    # Encode length
    encoded_length = encode_parameter_value(byte_length, "uint256")
    
    # Pad data to 32-byte boundary
    padded_data = String.pad_trailing(data, ceil(String.length(data) / 64) * 64, "0")
    
    encoded_length <> padded_data
  end

  defp encode_parameter_value(value, _type) do
    # Default fallback
    encode_parameter_value(value, "bytes")
  end

  defp encode_tuple(values, type_signature) do
    # Parse tuple types
    inner_types =
      type_signature
      |> String.trim_leading("(")
      |> String.trim_trailing(")")
      |> String.split(",")
      |> Enum.map(&String.trim/1)

    # Encode each tuple element
    values
    |> Enum.zip(inner_types)
    |> Enum.map(&encode_parameter/1)
    |> Enum.join()
  end

  @doc """
  Encodes a tuple for ABI encoding.
  """
  @spec encode_tuple(list()) :: {:ok, binary()} | {:error, term()}
  def encode_tuple(values) do
    try do
      # Encode each tuple element as uint256, address, etc.
      encoded = 
        values
        |> Enum.map(&encode_tuple_element/1)
        |> Enum.join()
        |> Base.decode16!(case: :mixed)
      
      {:ok, encoded}
    rescue
      error ->
        {:error, :encoding_failed}
    end
  end

  defp encode_tuple_element(value) when is_integer(value) do
    encode_parameter_value(value, "uint256")
  end

  defp encode_tuple_element(value) when is_binary(value) do
    if String.starts_with?(value, "0x") do
      encode_parameter_value(value, "address")
    else
      encode_parameter_value(value, "bytes")
    end
  end

  defp encode_tuple_element(value) when is_boolean(value) do
    encode_parameter_value(value, "bool")
  end

  @doc """
  Decodes a result from ABI-encoded data.
  """
  @spec decode_result(binary(), String.t()) :: {:ok, any()} | {:error, term()}
  def decode_result(data, signature) do
    # Parse return type from signature
    return_type = parse_return_type(signature)

    case return_type do
      "uint256" -> {:ok, decode_uint256(data)}
      "bool" -> {:ok, decode_bool(data)}
      "address" -> {:ok, decode_address(data)}
      "bytes32" -> {:ok, decode_bytes32(data)}
      _ -> {:ok, data}
    end
  rescue
    error ->
      Logger.error("Failed to decode result: #{inspect(error)}")
      {:error, :decoding_failed}
  end

  defp parse_return_type(signature) do
    # Simple heuristic - in practice, would need full ABI
    cond do
      String.contains?(signature, "returns(uint256)") -> "uint256"
      String.contains?(signature, "returns(bool)") -> "bool"
      String.contains?(signature, "returns(address)") -> "address"
      String.contains?(signature, "returns(bytes32)") -> "bytes32"
      true -> "bytes"
    end
  end

  defp decode_uint256(data) when is_binary(data) do
    data
    |> String.replace_prefix("0x", "")
    |> Base.decode16!(case: :mixed)
    |> :binary.decode_unsigned(:big)
  end

  defp decode_bool(data) do
    decode_uint256(data) != 0
  end

  defp decode_address(data) do
    data
    |> String.replace_prefix("0x", "")
    |> Base.decode16!(case: :mixed)
    |> Binary.take(-20)
    |> Base.encode16(case: :lower)
    |> (fn addr -> "0x" <> addr end).()
  end

  defp decode_bytes32(data) do
    data
    |> String.replace_prefix("0x", "")
    |> Base.decode16!(case: :mixed)
    |> Binary.take(32)
    |> Base.encode16(case: :lower)
    |> (fn hash -> "0x" <> hash end).()
  end

  # Utility functions

  defp pad_left(binary, target_size) do
    current_size = byte_size(binary)

    if current_size >= target_size do
      binary
    else
      padding = target_size - current_size
      :binary.copy(<<0>>, padding) <> binary
    end
  end

  defp pad_right(binary, target_size) do
    current_size = byte_size(binary)

    if current_size >= target_size do
      binary
    else
      padding = target_size - current_size
      binary <> :binary.copy(<<0>>, padding)
    end
  end

  defp pad_to_32_bytes(binary) do
    size = byte_size(binary)
    remainder = rem(size, 32)

    if remainder == 0 do
      binary
    else
      padding = 32 - remainder
      binary <> :binary.copy(<<0>>, padding)
    end
  end
end
