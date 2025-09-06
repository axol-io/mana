defmodule ExWire.Layer2.L1ContractIntegrationTest do
  use ExUnit.Case, async: true
  
  alias ExWire.Layer2.L1ContractInterface

  @moduletag :layer2

  setup do
    contracts = %{
      optimism_portal: "0x1234567890123456789012345678901234567890",
      l2_output_oracle: "0x2345678901234567890123456789012345678901", 
      arbitrum_bridge: "0x3456789012345678901234567890123456789012"
    }
    
    {:ok, contracts: contracts}
  end

  describe "ABI Encoding Validation" do
    test "encodes deposit transaction parameters correctly" do
      params = [
        "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        1_000_000_000_000_000_000,
        100_000,
        false,
        "0x"
      ]

      {:ok, encoded} = L1ContractInterface.encode_function_call(
        "depositTransaction(address,uint256,uint64,bool,bytes)",
        params
      )

      assert is_binary(encoded)
      assert byte_size(encoded) >= 4
      
      # Verify function selector
      function_selector = binary_part(encoded, 0, 4)
      assert function_selector == <<0xe9, 0xe0, 0x5c, 0x42>>
    end

    test "encodes L2 output submission parameters" do
      params = [
        "0x" <> String.duplicate("aa", 32),
        1_000_000,
        "0x" <> String.duplicate("bb", 32),
        18_000_000
      ]

      {:ok, encoded} = L1ContractInterface.encode_function_call(
        "proposeL2Output(bytes32,uint256,bytes32,uint256)",
        params
      )

      assert is_binary(encoded)
      assert byte_size(encoded) >= 4 + (4 * 32)  # Selector + 4 params
    end

    test "encodes withdrawal proof parameters" do
      withdrawal_tuple = [
        1,
        "0x1111111111111111111111111111111111111111",
        "0x2222222222222222222222222222222222222222",
        500_000_000_000_000_000,
        50_000,
        "0x"
      ]

      {:ok, encoded} = L1ContractInterface.encode_tuple(withdrawal_tuple)
      
      assert is_binary(encoded)
      assert byte_size(encoded) >= 192  # 6 parameters * 32 bytes each
    end
  end

  describe "ABI Decoding Validation" do
    test "decodes uint256 oracle response" do
      encoded_response = "0x" <> String.pad_leading(Integer.to_string(42, 16), 64, "0")
      
      {:ok, decoded} = L1ContractInterface.decode_result(
        encoded_response,
        "latestOutputIndex() returns (uint256)"
      )

      assert decoded == 42
    end

    test "decodes boolean response" do
      # Encoded 'true' as uint256
      encoded_true = "0x" <> String.pad_leading("1", 64, "0")
      
      {:ok, decoded} = L1ContractInterface.decode_result(
        encoded_true,
        "isFinalized() returns (bool)"
      )

      assert decoded == true
    end

    test "decodes address response" do
      address = "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd"
      # Address encoded as 32-byte value (padded)
      encoded_address = "0x" <> String.pad_leading(String.slice(address, 2..-1), 64, "0")
      
      {:ok, decoded} = L1ContractInterface.decode_result(
        encoded_address,
        "getContract() returns (address)"
      )

      assert String.downcase(decoded) == String.downcase(address)
    end
  end

  describe "Contract Interface Construction" do
    test "builds optimism portal deposit transaction data" do
      deposit_params = build_deposit_params(%{
        to: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        value: 1_000_000_000_000_000_000,
        gas_limit: 100_000,
        is_creation: false,
        data: "0x",
        mint: 0
      })

      result = construct_deposit_transaction_data(deposit_params)
      
      assert {:ok, transaction_data} = result
      assert is_binary(transaction_data)
      assert byte_size(transaction_data) > 4
    end

    test "builds L2 output submission data" do
      output_data = build_output_data(%{
        output_root: generate_hash(),
        l2_block_number: 1_000_000,
        l1_blockhash: generate_hash(),
        l1_block_number: 18_000_000
      })

      result = construct_output_submission_data(output_data)
      
      assert {:ok, submission_data} = result
      assert is_binary(submission_data)
    end

    test "builds withdrawal proof data" do
      withdrawal = build_withdrawal(%{
        nonce: 1,
        sender: "0x1111111111111111111111111111111111111111",
        target: "0x2222222222222222222222222222222222222222",
        value: 500_000_000_000_000_000,
        gas_limit: 50_000,
        data: "0x"
      })

      proof = build_proof(%{
        version: 0,
        state_root: generate_hash(),
        message_passer_storage_root: generate_hash(),
        latest_block_hash: generate_hash(),
        l2_output_index: 100,
        withdrawal_proof: [generate_hash(), generate_hash()]
      })

      result = construct_withdrawal_proof_data(withdrawal, proof)
      
      assert {:ok, proof_data} = result
      assert is_binary(proof_data)
    end
  end

  describe "Parameter Validation" do
    test "validates deposit parameters" do
      valid_params = %{
        to: "0xabcdefabcdefabcdefabcdefabcdefabcdefabcd",
        value: 1_000_000_000_000_000_000,
        gas_limit: 100_000,
        is_creation: false,
        data: "0x"
      }

      assert validate_deposit_params(valid_params) == :ok

      invalid_params = %{
        to: "invalid_address",
        value: -1,
        gas_limit: 0,
        is_creation: "not_boolean",
        data: nil
      }

      assert validate_deposit_params(invalid_params) == {:error, :invalid_parameters}
    end

    test "validates output submission parameters" do
      valid_params = %{
        output_root: generate_hash(),
        l2_block_number: 1_000_000,
        l1_blockhash: generate_hash(),
        l1_block_number: 18_000_000
      }

      assert validate_output_params(valid_params) == :ok

      invalid_params = %{
        output_root: "invalid_hash",
        l2_block_number: -1,
        l1_blockhash: nil,
        l1_block_number: "not_number"
      }

      assert validate_output_params(invalid_params) == {:error, :invalid_parameters}
    end
  end

  describe "Gas Estimation" do
    test "estimates gas for deposit transaction" do
      params = build_deposit_params(%{
        to: "0xabcd",
        value: 1_000_000_000_000_000_000,
        gas_limit: 100_000,
        is_creation: false,
        data: "0x"
      })

      estimated_gas = estimate_deposit_gas(params)
      
      assert is_integer(estimated_gas)
      assert estimated_gas > 21_000
      assert estimated_gas < 200_000
    end

    test "estimates gas for output submission" do
      output_data = build_output_data(%{
        output_root: generate_hash(),
        l2_block_number: 1_000_000,
        l1_blockhash: generate_hash(),
        l1_block_number: 18_000_000
      })

      estimated_gas = estimate_output_submission_gas(output_data)
      
      assert is_integer(estimated_gas)
      assert estimated_gas > 50_000
      assert estimated_gas < 500_000
    end
  end

  describe "Cross-Protocol Operations" do
    test "constructs multi-protocol transaction batch" do
      operations = [
        {:optimism_deposit, build_deposit_params(%{to: "0x1111", value: 1_000_000_000})},
        {:arbitrum_deposit, %{amount: 2_000_000_000}},
        {:output_submission, build_output_data(%{l2_block_number: 100})}
      ]

      results = construct_operation_batch(operations)
      
      assert length(results) == 3
      assert Enum.all?(results, fn
        {:ok, _data} -> true
        _ -> false
      end)
    end

    test "validates cross-protocol consistency" do
      optimism_state = %{
        latest_output: 100,
        finalization_period: 604_800
      }

      arbitrum_state = %{
        latest_node: 200,
        confirmation_period: 45_818
      }

      consistency_check = validate_cross_protocol_consistency(optimism_state, arbitrum_state)
      assert is_boolean(consistency_check)
    end
  end

  # Pure functional helper functions

  defp build_deposit_params(overrides \\ %{}) do
    defaults = %{
      to: "0x0000000000000000000000000000000000000000",
      value: 0,
      gas_limit: 21_000,
      is_creation: false,
      data: "0x",
      mint: 0
    }

    Map.merge(defaults, overrides)
  end

  defp build_output_data(overrides \\ %{}) do
    defaults = %{
      output_root: generate_hash(),
      l2_block_number: 1,
      l1_blockhash: generate_hash(),
      l1_block_number: 18_000_000
    }

    Map.merge(defaults, overrides)
  end

  defp build_withdrawal(overrides \\ %{}) do
    defaults = %{
      nonce: 1,
      sender: "0x0000000000000000000000000000000000000000",
      target: "0x0000000000000000000000000000000000000000",
      value: 0,
      gas_limit: 21_000,
      data: "0x"
    }

    Map.merge(defaults, overrides)
  end

  defp build_proof(overrides \\ %{}) do
    defaults = %{
      version: 0,
      state_root: generate_hash(),
      message_passer_storage_root: generate_hash(),
      latest_block_hash: generate_hash(),
      l2_output_index: 0,
      withdrawal_proof: []
    }

    Map.merge(defaults, overrides)
  end

  defp construct_deposit_transaction_data(params) do
    L1ContractInterface.encode_function_call(
      "depositTransaction(address,uint256,uint64,bool,bytes)",
      [
        params.to,
        params.value,
        params.gas_limit,
        params.is_creation,
        params.data
      ]
    )
  end

  defp construct_output_submission_data(output_data) do
    L1ContractInterface.encode_function_call(
      "proposeL2Output(bytes32,uint256,bytes32,uint256)",
      [
        output_data.output_root,
        output_data.l2_block_number,
        output_data.l1_blockhash,
        output_data.l1_block_number
      ]
    )
  end

  defp construct_withdrawal_proof_data(withdrawal, proof) do
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

    L1ContractInterface.encode_function_call(
      "proveWithdrawalTransaction((uint256,address,address,uint256,uint256,bytes),uint256,(bytes32,bytes32,bytes32,bytes32),bytes[])",
      [
        withdrawal_tuple,
        proof.l2_output_index,
        output_root_proof,
        proof.withdrawal_proof
      ]
    )
  end

  defp validate_deposit_params(params) do
    with :ok <- validate_address(params[:to]),
         :ok <- validate_positive_integer(params[:value]),
         :ok <- validate_positive_integer(params[:gas_limit]),
         :ok <- validate_boolean(params[:is_creation]),
         :ok <- validate_hex_data(params[:data]) do
      :ok
    else
      _ -> {:error, :invalid_parameters}
    end
  end

  defp validate_output_params(params) do
    with :ok <- validate_hash(params[:output_root]),
         :ok <- validate_positive_integer(params[:l2_block_number]),
         :ok <- validate_hash(params[:l1_blockhash]),
         :ok <- validate_positive_integer(params[:l1_block_number]) do
      :ok
    else
      _ -> {:error, :invalid_parameters}
    end
  end

  defp validate_address(address) when is_binary(address) do
    if String.match?(address, ~r/^0x[a-fA-F0-9]{40}$/) do
      :ok
    else
      {:error, :invalid_address}
    end
  end
  defp validate_address(_), do: {:error, :invalid_address}

  defp validate_positive_integer(value) when is_integer(value) and value >= 0, do: :ok
  defp validate_positive_integer(_), do: {:error, :invalid_integer}

  defp validate_boolean(value) when is_boolean(value), do: :ok
  defp validate_boolean(_), do: {:error, :invalid_boolean}

  defp validate_hex_data("0x" <> data) do
    if String.match?(data, ~r/^[a-fA-F0-9]*$/) do
      :ok
    else
      {:error, :invalid_hex_data}
    end
  end
  defp validate_hex_data(_), do: {:error, :invalid_hex_data}

  defp validate_hash("0x" <> hash) do
    if String.length(hash) == 64 and String.match?(hash, ~r/^[a-fA-F0-9]{64}$/) do
      :ok
    else
      {:error, :invalid_hash}
    end
  end
  defp validate_hash(_), do: {:error, :invalid_hash}

  defp estimate_deposit_gas(params) do
    base_gas = 21_000
    data_gas = calculate_data_gas(params.data)
    creation_gas = if params.is_creation, do: 32_000, else: 0
    
    base_gas + data_gas + creation_gas
  end

  defp estimate_output_submission_gas(output_data) do
    # Base cost for L2 output submission
    base_gas = 100_000
    
    # Additional cost based on data size
    data_size_gas = byte_size(output_data.output_root) * 68
    
    base_gas + data_size_gas
  end

  defp calculate_data_gas(data) do
    data
    |> String.replace_prefix("0x", "")
    |> String.graphemes()
    |> Enum.chunk_every(2)
    |> Enum.reduce(0, fn
      ["0", "0"] -> &(&1 + 4)   # Zero byte costs 4 gas
      _ -> &(&1 + 16)           # Non-zero byte costs 16 gas
    end)
  end

  defp construct_operation_batch(operations) do
    Enum.map(operations, &construct_operation/1)
  end

  defp construct_operation({:optimism_deposit, params}) do
    construct_deposit_transaction_data(params)
  end

  defp construct_operation({:arbitrum_deposit, params}) do
    L1ContractInterface.encode_function_call(
      "depositEth()",
      []
    )
  end

  defp construct_operation({:output_submission, params}) do
    construct_output_submission_data(params)
  end

  defp validate_cross_protocol_consistency(optimism_state, arbitrum_state) do
    # Simple consistency check - both protocols should be progressing
    optimism_state.latest_output > 0 and arbitrum_state.latest_node > 0
  end

  defp generate_hash do
    "0x" <> (:crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower))
  end
end