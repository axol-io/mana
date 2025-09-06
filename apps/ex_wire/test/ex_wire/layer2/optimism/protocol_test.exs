defmodule ExWire.Layer2.Optimism.ProtocolTest do
  use ExUnit.Case, async: false

  alias ExWire.Layer2.Optimism.Protocol
  alias ExWire.Layer2.Batch

  @moduletag :layer2
  @moduletag :optimism

  setup do
    # Start the protocol server for tests
    {:ok, _pid} = Protocol.start_link(network: :sepolia)
    :ok
  end

  describe "L2 output submission" do
    test "submits L2 output root to oracle" do
      batch = %Batch{
        number: 100,
        timestamp: DateTime.utc_now(),
        transactions: [],
        sequencer_address: <<0::160>>
      }

      state_root = :crypto.strong_rand_bytes(32)

      assert {:ok, submission} = Protocol.submit_l2_output(batch, state_root)
      assert submission.l2_block_number == 100
      assert byte_size(submission.output_root) == 32
      assert submission.proposer == batch.sequencer_address
    end
  end

  describe "deposits" do
    test "creates deposit transaction from L1 to L2" do
      params = %{
        from: <<1::160>>,
        to: <<2::160>>,
        # 1 ETH
        value: 1_000_000_000_000_000_000,
        gas_limit: 100_000,
        # Sample calldata
        data: <<0x60, 0x80>>
      }

      assert {:ok, deposit_hash} = Protocol.deposit_transaction(params)
      # 32 bytes hex encoded
      assert String.length(deposit_hash) == 64
    end

    test "handles deposit with mint value" do
      params = %{
        from: <<1::160>>,
        to: <<2::160>>,
        value: 0,
        # Mint 1 ETH on L2
        mint: 1_000_000_000_000_000_000,
        gas_limit: 100_000
      }

      assert {:ok, _deposit_hash} = Protocol.deposit_transaction(params)
    end
  end

  describe "withdrawals" do
    test "initiates withdrawal from L2 to L1" do
      params = %{
        from: <<1::160>>,
        to: <<2::160>>,
        # 0.5 ETH
        value: 500_000_000_000_000_000,
        gas_limit: 100_000,
        data: <<>>
      }

      assert {:ok, result} = Protocol.initiate_withdrawal(params)
      assert byte_size(result.hash) == 32
      assert result.withdrawal.sender == params.from
      assert result.withdrawal.target == params.to
      assert result.withdrawal.value == params.value
    end

    test "proves withdrawal with merkle proof" do
      # First initiate a withdrawal
      params = %{
        from: <<1::160>>,
        to: <<2::160>>,
        value: 100_000_000_000_000_000,
        gas_limit: 100_000
      }

      {:ok, result} = Protocol.initiate_withdrawal(params)
      withdrawal_hash = result.hash

      # Create proof data
      proof_data = %{
        storage_proof: :crypto.strong_rand_bytes(256),
        output_root_proof: :crypto.strong_rand_bytes(256),
        l2_output_index: 42
      }

      assert {:ok, proven} = Protocol.prove_withdrawal(withdrawal_hash, proof_data)
      assert proven.proven_at != nil
      assert proven.proof == proof_data
    end

    test "rejects invalid withdrawal proof" do
      # Try to prove non-existent withdrawal
      fake_hash = :crypto.strong_rand_bytes(32)
      proof_data = %{invalid: "proof"}

      assert {:error, :withdrawal_not_found} =
               Protocol.prove_withdrawal(fake_hash, proof_data)
    end

    test "cannot finalize withdrawal before challenge period" do
      # Initiate and prove withdrawal
      params = %{
        from: <<1::160>>,
        to: <<2::160>>,
        value: 100_000_000_000_000_000,
        gas_limit: 100_000
      }

      {:ok, result} = Protocol.initiate_withdrawal(params)
      withdrawal_hash = result.hash

      proof_data = %{
        storage_proof: :crypto.strong_rand_bytes(256),
        output_root_proof: :crypto.strong_rand_bytes(256),
        l2_output_index: 42
      }

      {:ok, _proven} = Protocol.prove_withdrawal(withdrawal_hash, proof_data)

      # Try to finalize immediately (should fail)
      assert {:error, :challenge_period_not_passed} =
               Protocol.finalize_withdrawal(withdrawal_hash)
    end
  end

  describe "cross-domain messaging" do
    test "sends message from L1 to L2" do
      target = <<3::160>>
      message = "Hello L2"
      gas_limit = 200_000

      assert {:ok, message_hash} =
               Protocol.send_message(:l1_to_l2, target, message, gas_limit)

      assert String.length(message_hash) == 64
    end

    test "sends message from L2 to L1" do
      target = <<4::160>>
      message = "Hello L1"
      gas_limit = 150_000

      assert {:ok, message_hash} =
               Protocol.send_message(:l2_to_l1, target, message, gas_limit)

      assert String.length(message_hash) == 64
    end
  end

  describe "dispute games" do
    test "creates dispute game for output challenge" do
      l2_block_number = 1000
      claimed_output_root = :crypto.strong_rand_bytes(32)

      assert {:ok, game_id} =
               Protocol.create_dispute_game(l2_block_number, claimed_output_root)

      assert String.starts_with?(game_id, "game_")
    end
  end

  describe "network configuration" do
    test "loads correct contracts for mainnet" do
      # This would test actual contract addresses
      # For now just verify the module initializes
      assert {:ok, _pid} = Protocol.start_link(network: :mainnet)
    end

    test "loads correct contracts for testnet" do
      assert {:ok, _pid} = Protocol.start_link(network: :goerli)
    end
  end
end
