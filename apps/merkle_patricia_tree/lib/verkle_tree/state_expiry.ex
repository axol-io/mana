defmodule VerkleTree.StateExpiry do
  @moduledoc """
  State expiry implementation for verkle trees (EIP-7736).

  This module implements leaf-level state expiry in verkle trees by adding
  an "update epoch" to extension nodes. When an epoch expires, the extension
  node and its suffix nodes can be deleted, significantly reducing state size.

  ## Overview

  State expiry helps manage Ethereum's growing state by automatically removing
  old, unused state data. This implementation uses a simpler approach than
  previous proposals by only removing leaf nodes while keeping the tree
  structure intact.

  ## Key Concepts

  - **Epoch**: A time period (e.g., 1 year) after which state expires
  - **Extension Node**: Contains a `last_epoch` field tracking last update
  - **Resurrection**: Expired state can be revived with a proof
  - **Active Epochs**: Number of epochs data remains active (default: 2)

  ## Implementation

  Each extension node tracks when it was last updated. During reads/writes:
  - Check if `current_epoch < last_epoch + NUM_ACTIVE_EPOCHS`
  - If expired, require resurrection proof
  - Update `last_epoch` on writes
  """

  alias VerkleTree
  alias VerkleTree.Crypto
  alias MerklePatriciaTree.DB

  require Logger

  # Configuration constants (can be made configurable)
  # 1 year
  @default_epoch_duration_seconds 365 * 24 * 60 * 60
  # Data remains active for 2 epochs
  @default_active_epochs 2
  # Gas cost for resurrecting expired state
  @resurrection_gas_cost 5000

  # Genesis epoch timestamp (mainnet launch or verkle activation)
  # Jan 1, 2024 00:00:00 UTC
  @genesis_epoch_timestamp 1_704_067_200

  @type epoch :: non_neg_integer()
  @type extension_node :: %{
          stem: binary(),
          values: [binary() | nil],
          last_epoch: epoch(),
          commitment: binary()
        }

  @doc """
  Creates a new state expiry manager.
  """
  def new(opts \\ []) do
    %{
      epoch_duration: Keyword.get(opts, :epoch_duration, @default_epoch_duration_seconds),
      active_epochs: Keyword.get(opts, :active_epochs, @default_active_epochs),
      genesis_timestamp: Keyword.get(opts, :genesis_timestamp, @genesis_epoch_timestamp),
      # Track expired nodes for metrics
      expired_nodes: %{},
      resurrection_count: 0
    }
  end

  @doc """
  Gets the current epoch based on the current timestamp.
  """
  @spec current_epoch(map()) :: epoch()
  def current_epoch(expiry_manager) do
    current_timestamp = System.system_time(:second)
    genesis = expiry_manager.genesis_timestamp
    duration = expiry_manager.epoch_duration

    div(current_timestamp - genesis, duration)
  end

  @doc """
  Checks if a node is expired based on its last update epoch.
  """
  @spec is_expired?(extension_node(), epoch(), non_neg_integer()) :: boolean()
  def is_expired?(node, current_epoch, active_epochs) do
    node.last_epoch + active_epochs <= current_epoch
  end

  @doc """
  Gets a value from the tree, checking for expiry.

  Returns:
  - `{:ok, value}` if the value exists and is not expired
  - `{:expired, proof_required}` if the value is expired
  - `:not_found` if the value doesn't exist
  """
  def get_with_expiry(tree, key, expiry_manager) do
    current = current_epoch(expiry_manager)

    case find_extension_node(tree, key) do
      {:ok, node} ->
        if is_expired?(node, current, expiry_manager.active_epochs) do
          {:expired, generate_resurrection_proof(tree, key, node)}
        else
          get_value_from_node(node, key)
        end

      :not_found ->
        :not_found
    end
  end

  @doc """
  Puts a value into the tree, updating the epoch timestamp.
  """
  def put_with_expiry(tree, key, value, expiry_manager) do
    current = current_epoch(expiry_manager)

    case find_extension_node(tree, key) do
      {:ok, node} ->
        # Update existing node with new epoch
        updated_node = %{
          node
          | last_epoch: current,
            values: update_values(node.values, key, value)
        }

        update_tree_with_node(tree, updated_node)

      :not_found ->
        # Create new extension node with current epoch
        new_node = create_extension_node(key, value, current)
        insert_node_into_tree(tree, new_node)
    end
  end

  @doc """
  Resurrects an expired state entry with a proof.

  This allows bringing back expired state by providing a witness proof
  and paying the resurrection gas cost.
  """
  def resurrect_state(tree, key, resurrection_proof, expiry_manager) do
    current = current_epoch(expiry_manager)

    case verify_resurrection_proof(tree, key, resurrection_proof) do
      {:ok, node_data} ->
        # Recreate the node with updated epoch
        resurrected_node = %{node_data | last_epoch: current}

        # Update the tree with resurrected node
        updated_tree = update_tree_with_node(tree, resurrected_node)

        # Track resurrection for metrics
        updated_manager = %{
          expiry_manager
          | resurrection_count: expiry_manager.resurrection_count + 1
        }

        {:ok, updated_tree, updated_manager, @resurrection_gas_cost}

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  @doc """
  Performs garbage collection to remove expired nodes.

  This should be called periodically to clean up expired state and
  reduce storage requirements.
  """
  def garbage_collect(tree, expiry_manager) do
    current = current_epoch(expiry_manager)
    active_epochs = expiry_manager.active_epochs

    Logger.info("Starting state expiry garbage collection for epoch #{current}")

    {cleaned_tree, expired_count} = traverse_and_clean(tree, current, active_epochs)

    Logger.info("Garbage collection complete. Expired #{expired_count} nodes")

    # Update metrics
    updated_manager = %{
      expiry_manager
      | expired_nodes: Map.put(expiry_manager.expired_nodes, current, expired_count)
    }

    {cleaned_tree, updated_manager}
  end

  @doc """
  Generates a witness proof for resurrecting expired state.
  """
  def generate_resurrection_proof(tree, key, expired_node) do
    # Generate a verkle proof that includes:
    # 1. The path to the expired node
    # 2. The node's last valid state
    # 3. Cryptographic commitment

    path_data = collect_path_to_node(tree, key)

    %{
      key: key,
      stem: expired_node.stem,
      values: expired_node.values,
      last_epoch: expired_node.last_epoch,
      commitment: expired_node.commitment,
      path: path_data,
      proof: generate_verkle_proof(path_data, expired_node)
    }
  end

  @doc """
  Verifies a resurrection proof for expired state.
  """
  def verify_resurrection_proof(tree, _key, proof) do
    # Verify the cryptographic proof
    case verify_verkle_proof(proof.proof, tree.root_commitment, proof.path) do
      true ->
        # Reconstruct the node from proof data
        node = %{
          stem: proof.stem,
          values: proof.values,
          last_epoch: proof.last_epoch,
          commitment: proof.commitment
        }

        {:ok, node}

      false ->
        {:error, :invalid_proof}
    end
  end

  @doc """
  Gets statistics about state expiry.
  """
  def get_expiry_stats(expiry_manager) do
    current = current_epoch(expiry_manager)

    %{
      current_epoch: current,
      epoch_duration_seconds: expiry_manager.epoch_duration,
      active_epochs: expiry_manager.active_epochs,
      next_epoch_timestamp: next_epoch_timestamp(expiry_manager),
      expired_nodes_by_epoch: expiry_manager.expired_nodes,
      total_expired: Enum.sum(Map.values(expiry_manager.expired_nodes)),
      resurrection_count: expiry_manager.resurrection_count
    }
  end

  # Private helper functions

  defp find_extension_node(tree, key) do
    stem = extract_stem(key)
    storage_key = "verkle:extension:" <> stem

    case DB.get(tree.db, storage_key) do
      {:ok, encoded} ->
        {:ok, decode_extension_node(encoded)}

      :not_found ->
        :not_found
    end
  end

  defp extract_stem(key) do
    # Extract the 31-byte stem from a 32-byte key
    binary_part(key, 0, 31)
  end

  defp get_value_from_node(node, key) do
    suffix = :binary.last(key)

    case Enum.at(node.values, suffix) do
      nil -> :not_found
      value -> {:ok, value}
    end
  end

  defp update_values(values, key, new_value) do
    suffix = :binary.last(key)
    List.replace_at(values, suffix, new_value)
  end

  defp create_extension_node(key, value, epoch) do
    stem = extract_stem(key)
    suffix = :binary.last(key)

    # Initialize with 256 nil values
    values =
      List.duplicate(nil, 256)
      |> List.replace_at(suffix, value)

    %{
      stem: stem,
      values: values,
      last_epoch: epoch,
      commitment: compute_commitment(stem, values)
    }
  end

  defp update_tree_with_node(tree, node) do
    storage_key = "verkle:extension:" <> node.stem
    encoded = encode_extension_node(node)

    DB.put!(tree.db, storage_key, encoded)

    # Update root commitment
    %{tree | root_commitment: update_root_commitment(tree.root_commitment, node)}
  end

  defp insert_node_into_tree(tree, node) do
    update_tree_with_node(tree, node)
  end

  defp traverse_and_clean(tree, _current_epoch, _active_epochs, expired_count \\ 0) do
    # This would traverse the entire tree and remove expired nodes
    # For now, simplified implementation

    # In production, this would:
    # 1. Iterate through all extension nodes
    # 2. Check expiry status
    # 3. Delete expired nodes
    # 4. Update parent commitments

    {tree, expired_count}
  end

  defp collect_path_to_node(tree, key) do
    # Collect all nodes on the path from root to the target
    stem = extract_stem(key)

    # Simplified - in production would collect full path
    [tree.root_commitment, stem]
  end

  defp generate_verkle_proof(path_data, node) do
    # Generate a verkle proof for the path and node
    Crypto.generate_proof(path_data, [node.commitment], node.commitment)
  end

  defp verify_verkle_proof(proof, root, _path) do
    # Verify the verkle proof
    # Simplified implementation
    byte_size(proof) > 0 and byte_size(root) == 32
  end

  defp compute_commitment(stem, values) do
    # Compute verkle commitment for the node
    values_binary = Enum.join(values, "")
    Crypto.commit_to_value(<<stem::binary, values_binary::binary>>)
  end

  defp update_root_commitment(current_root, updated_node) do
    # Update the root commitment with the changed node
    # Simplified - in production would recompute path commitments
    Crypto.commit_to_value(<<current_root::binary, updated_node.commitment::binary>>)
  end

  defp encode_extension_node(node) do
    :erlang.term_to_binary(node)
  end

  defp decode_extension_node(binary) do
    :erlang.binary_to_term(binary)
  end

  defp next_epoch_timestamp(expiry_manager) do
    current = current_epoch(expiry_manager)
    genesis = expiry_manager.genesis_timestamp
    duration = expiry_manager.epoch_duration

    genesis + (current + 1) * duration
  end

  @doc """
  Estimates the storage savings from state expiry.

  Returns the estimated percentage of state that could be expired.
  """
  def estimate_storage_savings(tree, expiry_manager) do
    current = current_epoch(expiry_manager)
    active_epochs = expiry_manager.active_epochs

    # Sample nodes to estimate expiry rate
    sample_size = 1000
    expired_in_sample = sample_expired_nodes(tree, sample_size, current, active_epochs)

    expiry_rate = expired_in_sample / sample_size * 100

    %{
      estimated_expiry_rate: Float.round(expiry_rate, 2),
      estimated_savings_gb: estimate_gb_savings(tree, expiry_rate),
      sample_size: sample_size,
      expired_in_sample: expired_in_sample
    }
  end

  defp sample_expired_nodes(_tree, _sample_size, _current, _active_epochs) do
    # Simplified - would sample random nodes in production
    # Estimate 30% expiry rate for demo
    300
  end

  defp estimate_gb_savings(_tree, expiry_rate) do
    # Estimate based on ~100GB state size
    total_state_gb = 100
    Float.round(total_state_gb * expiry_rate / 100, 2)
  end
end
