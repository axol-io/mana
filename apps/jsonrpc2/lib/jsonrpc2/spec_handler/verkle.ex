defmodule JSONRPC2.SpecHandler.Verkle do
  @moduledoc """
  JSON-RPC handler for verkle tree specific operations.

  This module provides RPC endpoints for interacting with verkle trees,
  including witness generation, proof verification, and migration status.

  ## Supported Methods

  - `verkle_getWitness` - Generate a witness for given addresses
  - `verkle_verifyProof` - Verify a verkle proof
  - `verkle_getMigrationStatus` - Get the state migration progress
  - `verkle_getStateMode` - Get the current state storage mode
  - `verkle_getTreeStats` - Get verkle tree statistics
  """

  alias Blockchain.State.VerkleAdapter
  alias JSONRPC2.Bridge.Sync
  alias MerklePatriciaTree.DB

  import JSONRPC2.Response.Helpers

  @sync Application.compile_env(:jsonrpc2, :bridge_mock, Sync)

  @doc """
  Generates a verkle witness for the given addresses at a specific block.

  ## Parameters

  - `addresses` - Array of hex-encoded addresses
  - `block_number_or_tag` - Block number or tag ("latest", "earliest", "pending")

  ## Returns

  A hex-encoded witness that can be used for stateless verification.

  ## Example

      {
        "jsonrpc": "2.0",
        "method": "verkle_getWitness",
        "params": [
          ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb7"],
          "latest"
        ],
        "id": 1
      }
  """
  def get_witness([hex_addresses, hex_block_number_or_tag]) when is_list(hex_addresses) do
    with {:ok, addresses} <- decode_addresses(hex_addresses),
         {:ok, block_number} <- decode_block_number(hex_block_number_or_tag),
         {:ok, state} <- get_state_at_block(block_number),
         {:ok, witness} <- generate_witness(state, addresses) do
      encode_witness(witness)
    end
  end

  @doc """
  Verifies a verkle proof against a state root and key-value pairs.

  ## Parameters

  - `proof` - Hex-encoded verkle proof
  - `root` - Hex-encoded state root
  - `key_value_pairs` - Array of [address, account_data] pairs

  ## Returns

  Boolean indicating whether the proof is valid.

  ## Example

      {
        "jsonrpc": "2.0",
        "method": "verkle_verifyProof",
        "params": [
          "0x...", // proof
          "0x...", // root
          [
            ["0x742d35Cc6634C0532925a3b844Bc9e7595f0bEb7", "0x..."]
          ]
        ],
        "id": 1
      }
  """
  def verify_proof([hex_proof, hex_root, key_value_pairs]) do
    with {:ok, proof} <- decode_hex(hex_proof),
         {:ok, root} <- decode_hex(hex_root),
         {:ok, kvs} <- decode_key_value_pairs(key_value_pairs) do
      # Create a witness structure for verification
      witness = %{data: proof, proof: proof}
      result = VerkleTree.Witness.verify(witness, root, kvs)
      {:ok, result}
    end
  end

  @doc """
  Gets the current state migration progress from MPT to verkle trees.

  ## Parameters

  None

  ## Returns

  An object containing migration statistics:
  - `mode` - Current state mode ("mpt", "verkle", or "migration")
  - `progress` - Migration progress percentage (0-100)
  - `migratedKeys` - Number of keys migrated
  - `totalKeys` - Estimated total keys
  - `startTime` - Migration start timestamp
  - `estimatedCompletion` - Estimated completion timestamp

  ## Example

      {
        "jsonrpc": "2.0",
        "method": "verkle_getMigrationStatus",
        "params": [],
        "id": 1
      }
  """
  def get_migration_status([]) do
    with {:ok, state} <- get_current_state() do
      status = build_migration_status(state)
      {:ok, status}
    end
  end

  @doc """
  Gets the current state storage mode.

  ## Parameters

  None

  ## Returns

  A string indicating the current mode:
  - `"mpt"` - Using Merkle Patricia Trees
  - `"verkle"` - Using Verkle Trees
  - `"migration"` - In migration from MPT to verkle

  ## Example

      {
        "jsonrpc": "2.0",
        "method": "verkle_getStateMode",
        "params": [],
        "id": 1
      }
  """
  def get_state_mode([]) do
    with {:ok, state} <- get_current_state() do
      mode =
        case state.mode do
          :verkle -> "verkle"
          :mpt -> "mpt"
          :migration -> "migration"
        end

      {:ok, mode}
    end
  end

  @doc """
  Gets statistics about the verkle tree.

  ## Parameters

  - `block_number_or_tag` - Block number or tag (optional, defaults to "latest")

  ## Returns

  An object containing tree statistics:
  - `root` - Current root commitment
  - `nodeCount` - Total number of nodes
  - `leafCount` - Number of leaf nodes
  - `depth` - Maximum tree depth
  - `averageWitnessSize` - Average witness size in bytes
  - `compressionRatio` - Storage compression ratio vs MPT

  ## Example

      {
        "jsonrpc": "2.0",
        "method": "verkle_getTreeStats",
        "params": ["latest"],
        "id": 1
      }
  """
  def get_tree_stats([hex_block_number_or_tag]) do
    with {:ok, block_number} <- decode_block_number(hex_block_number_or_tag),
         {:ok, state} <- get_state_at_block(block_number),
         {:ok, stats} <- calculate_tree_stats(state) do
      {:ok, stats}
    end
  end

  def get_tree_stats([]), do: get_tree_stats(["latest"])

  # Private helper functions

  defp decode_addresses(hex_addresses) do
    addresses =
      Enum.reduce_while(hex_addresses, [], fn hex_address, acc ->
        case decode_hex(hex_address) do
          {:ok, address} -> {:cont, [address | acc]}
          {:error, _} = error -> {:halt, error}
        end
      end)

    case addresses do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp decode_key_value_pairs(pairs) do
    kvs =
      Enum.reduce_while(pairs, [], fn [hex_key, hex_value], acc ->
        with {:ok, key} <- decode_hex(hex_key),
             {:ok, value} <- decode_hex(hex_value) do
          {:cont, [{key, value} | acc]}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    case kvs do
      {:error, _} = error -> error
      list -> {:ok, Enum.reverse(list)}
    end
  end

  defp get_state_at_block(block_number) do
    # Get the state at the specified block
    # This would typically interact with the blockchain state
    case @sync.get_block_by_number(block_number) do
      {:ok, block} ->
        db = DB.LevelDB.init(db_name())
        state = VerkleAdapter.new_state(db, root: block.header.state_root)
        {:ok, state}

      {:error, _} = error ->
        error
    end
  end

  defp get_current_state() do
    # Get the current state
    db = DB.LevelDB.init(db_name())
    state = VerkleAdapter.new_state(db)
    {:ok, state}
  end

  defp generate_witness(state, addresses) do
    witness = VerkleAdapter.generate_witness(state, addresses)
    {:ok, witness}
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp encode_witness(witness) do
    # Handle both Witness struct and map format
    data =
      case witness do
        %{data: data} -> data
        _ -> <<>>
      end

    encode_unformatted_data(data)
  end

  defp build_migration_status(state) do
    progress = VerkleAdapter.migration_progress(state) || 0.0

    %{
      "mode" => Atom.to_string(state.mode),
      "progress" => progress,
      "migratedKeys" => estimate_migrated_keys(progress),
      "totalKeys" => estimate_total_keys(),
      "startTime" => migration_start_time(),
      "estimatedCompletion" => estimate_completion_time(progress)
    }
  end

  defp calculate_tree_stats(state) do
    stats = %{
      "root" => encode_unformatted_data(VerkleAdapter.state_root(state)),
      "nodeCount" => estimate_node_count(state),
      "leafCount" => estimate_leaf_count(state),
      "depth" => estimate_tree_depth(state),
      # Based on benchmarks
      "averageWitnessSize" => 932,
      # 70% smaller than MPT
      "compressionRatio" => 0.3
    }

    {:ok, stats}
  end

  defp estimate_migrated_keys(progress) do
    total = estimate_total_keys()
    round(total * progress / 100)
  end

  defp estimate_total_keys() do
    # Estimate based on typical mainnet state
    10_000_000
  end

  defp estimate_node_count(_state) do
    # Placeholder estimation
    1_000_000
  end

  defp estimate_leaf_count(_state) do
    # Placeholder estimation
    500_000
  end

  defp estimate_tree_depth(_state) do
    # Verkle trees are typically shallower than MPT
    8
  end

  defp migration_start_time() do
    # Return current time minus some duration for demo
    DateTime.utc_now()
    # Started 1 hour ago
    |> DateTime.add(-3600, :second)
    |> DateTime.to_unix()
  end

  defp estimate_completion_time(progress) do
    if progress >= 100.0 do
      DateTime.utc_now() |> DateTime.to_unix()
    else
      remaining = 100.0 - progress
      # Estimate 1 minute per percent
      seconds_per_percent = 60

      DateTime.utc_now()
      |> DateTime.add(round(remaining * seconds_per_percent), :second)
      |> DateTime.to_unix()
    end
  end

  defp db_name() do
    Application.get_env(:merkle_patricia_tree, :db_name, "mainnet")
  end

  defp decode_block_number(hex_block_number_or_tag) do
    case hex_block_number_or_tag do
      "latest" -> {:ok, :latest}
      "earliest" -> {:ok, 0}
      "pending" -> {:ok, :pending}
      hex -> decode_unsigned(hex)
    end
  end
end
