defmodule ExWire.Eth2.ForkChoice do
  @moduledoc """
  Fork Choice implementation using LMD-GHOST with Casper FFG finality.
  Implements the consensus mechanism for choosing the canonical chain.
  """

  require Logger
  import Bitwise

  alias ExWire.Eth2.Checkpoint

  defstruct [
    :justified_checkpoint,
    :finalized_checkpoint,
    :best_justified_checkpoint,
    :proposer_boost_root,
    :time,
    :genesis_time,
    :blocks,
    :latest_messages,
    :unrealized_justifications,
    :unrealized_finalizations,
    :proposer_boost_amount
  ]

  @type store :: %__MODULE__{
          justified_checkpoint: Checkpoint.t(),
          finalized_checkpoint: Checkpoint.t(),
          best_justified_checkpoint: Checkpoint.t(),
          proposer_boost_root: binary(),
          time: non_neg_integer(),
          genesis_time: non_neg_integer(),
          blocks: map(),
          latest_messages: map(),
          unrealized_justifications: map(),
          unrealized_finalizations: map(),
          proposer_boost_amount: non_neg_integer()
        }

  # Constants
  @seconds_per_slot 12
  @slots_per_epoch 32
  @intervals_per_slot 3
  @proposer_score_boost 40

  # Public API

  @doc """
  Initialize fork choice store from genesis
  """
  def init do
    %__MODULE__{
      justified_checkpoint: %Checkpoint{epoch: 0, root: <<0::256>>},
      finalized_checkpoint: %Checkpoint{epoch: 0, root: <<0::256>>},
      best_justified_checkpoint: %Checkpoint{epoch: 0, root: <<0::256>>},
      proposer_boost_root: <<0::256>>,
      time: 0,
      genesis_time: 0,
      blocks: %{},
      latest_messages: %{},
      unrealized_justifications: %{},
      unrealized_finalizations: %{},
      proposer_boost_amount: 0
    }
  end

  @doc """
  Initialize fork choice from genesis state
  """
  def on_genesis(beacon_state, genesis_block) do
    genesis_root = hash_tree_root(genesis_block)

    %__MODULE__{
      justified_checkpoint: %Checkpoint{
        epoch: 0,
        root: genesis_root
      },
      finalized_checkpoint: %Checkpoint{
        epoch: 0,
        root: genesis_root
      },
      best_justified_checkpoint: %Checkpoint{
        epoch: 0,
        root: genesis_root
      },
      proposer_boost_root: <<0::256>>,
      time: beacon_state.genesis_time,
      genesis_time: beacon_state.genesis_time,
      blocks: %{
        genesis_root => %{
          block: genesis_block,
          state: beacon_state,
          parent_root: <<0::256>>,
          justified_checkpoint: %Checkpoint{epoch: 0, root: genesis_root},
          finalized_checkpoint: %Checkpoint{epoch: 0, root: genesis_root},
          weight: 0,
          invalid: false,
          best_child: nil,
          best_descendant: nil
        }
      },
      latest_messages: %{},
      unrealized_justifications: %{},
      unrealized_finalizations: %{},
      proposer_boost_amount: 0
    }
  end

  @doc """
  Process a new block for fork choice
  """
  def on_block(store, block, block_root, _state) do
    # Check block slot is not in the future
    current_slot = get_current_slot(store)

    if block.slot > current_slot do
      {:error, :future_block}
    else
      # Add block to store
      block_info = %{
        block: block,
        state: state,
        parent_root: block.parent_root,
        justified_checkpoint: state.current_justified_checkpoint,
        finalized_checkpoint: state.finalized_checkpoint,
        weight: 0,
        invalid: false,
        best_child: nil,
        best_descendant: nil,
        has_blob_commitments: length(block.body.blob_kzg_commitments) > 0
      }

      store = put_in(store.blocks[block_root], block_info)

      # Update checkpoints if better
      store = update_checkpoints(store, state)

      # Update proposer boost
      store =
        if should_update_proposer_boost?(store, block_root) do
          %{
            store
            | proposer_boost_root: block_root,
              proposer_boost_amount: calculate_proposer_boost(state)
          }
        else
          store
        end

      # Update unrealized checkpoints
      store = update_unrealized_checkpoints(store, block_root, state)

      store
    end
  end

  @doc """
  Process an attestation for fork choice
  """
  def on_attestation(store, attestation) do
    target = attestation.data.target

    # Get target block
    case Map.get(store.blocks, target.root) do
      nil ->
        # Unknown target, ignore
        store

      target_block_info ->
        # Extract validator indices from attestation
        validators =
          get_attesting_indices(
            target_block_info._state,
            attestation.data,
            attestation.aggregation_bits
          )

        # Update latest messages
        store =
          Enum.reduce(validators, store, fn validator_index, acc_store ->
            update_latest_message(acc_store, validator_index, attestation.data)
          end)

        store
    end
  end

  @doc """
  Get the head block according to fork choice
  """
  def get_head(store) do
    # Start from justified checkpoint
    head = store.justified_checkpoint.root

    # Apply LMD-GHOST
    find_head(store, head)
  end

  @doc """
  Update time in the store
  """
  def on_tick(store, time) do
    if time > store.time do
      # Update store time
      store = %{store | time: time}

      # Update proposer boost if new slot
      current_slot = get_current_slot(store)

      if current_slot_changed?(store, time) do
        # Reset proposer boost
        %{store | proposer_boost_root: <<0::256>>, proposer_boost_amount: 0}
      else
        store
      end
    else
      store
    end
  end

  @doc """
  Prune old blocks from the store
  """
  def prune(store) do
    finalized_root = store.finalized_checkpoint.root

    # Find all blocks that are not descendants of finalized block
    blocks_to_remove =
      Enum.filter(store.blocks, fn {block_root, _info} ->
        not is_descendant?(store, block_root, finalized_root)
      end)
      |> Enum.map(fn {root, _} -> root end)

    # Remove blocks
    blocks = Map.drop(store.blocks, blocks_to_remove)

    %{store | blocks: blocks}
  end

  # Private Functions - Fork Choice Algorithm

  defp find_head(store, start_root) do
    block_info = Map.get(store.blocks, start_root)

    if block_info == nil do
      start_root
    else
      # Get children
      children = get_children(store, start_root)

      if children == [] do
        start_root
      else
        # Get child with highest weight
        best_child =
          Enum.max_by(children, fn child_root ->
            get_weight(store, child_root)
          end)

        # Recurse
        find_head(store, best_child)
      end
    end
  end

  defp get_weight(store, block_root) do
    block_info = Map.get(store.blocks, block_root)

    if block_info == nil || block_info.invalid do
      0
    else
      # Sum attestation weight
      attestation_weight = calculate_attestation_weight(store, block_root)

      # Add proposer boost if applicable
      proposer_boost =
        if store.proposer_boost_root == block_root do
          store.proposer_boost_amount
        else
          0
        end

      attestation_weight + proposer_boost
    end
  end

  defp calculate_attestation_weight(store, block_root) do
    # Get all validators who attested to this block or its descendants
    validators_supporting =
      Enum.filter(store.latest_messages, fn {_validator, message} ->
        is_descendant_or_equal?(store, message.beacon_block_root, block_root)
      end)

    # Sum their effective balances
    Enum.reduce(validators_supporting, 0, fn {validator_index, _message}, acc ->
      # Get validator balance (simplified)
      acc + get_validator_effective_balance(store, validator_index)
    end)
  end

  defp get_children(store, parent_root) do
    store.blocks
    |> Enum.filter(fn {_root, info} -> info.parent_root == parent_root end)
    |> Enum.map(fn {root, _info} -> root end)
  end

  defp is_descendant?(store, descendant_root, ancestor_root) do
    if descendant_root == ancestor_root do
      true
    else
      case Map.get(store.blocks, descendant_root) do
        nil ->
          false

        block_info ->
          if block_info.parent_root == <<0::256>> do
            false
          else
            is_descendant?(store, block_info.parent_root, ancestor_root)
          end
      end
    end
  end

  defp is_descendant_or_equal?(store, descendant_root, ancestor_root) do
    descendant_root == ancestor_root || is_descendant?(store, descendant_root, ancestor_root)
  end

  # Private Functions - Checkpoint Updates

  defp update_checkpoints(store, _state) do
    # Update justified checkpoint if better
    store =
      if state.current_justified_checkpoint.epoch > store.justified_checkpoint.epoch do
        %{
          store
          | justified_checkpoint: state.current_justified_checkpoint,
            best_justified_checkpoint: _state.current_justified_checkpoint
        }
      else
        store
      end

    # Update finalized checkpoint if better
    if state.finalized_checkpoint.epoch > store.finalized_checkpoint.epoch do
      %{store | finalized_checkpoint: state.finalized_checkpoint}
    else
      store
    end
  end

  defp update_unrealized_checkpoints(store, block_root, _state) do
    # Store unrealized justification and finalization
    store =
      put_in(
        store.unrealized_justifications[block_root],
        state.current_justified_checkpoint
      )

    put_in(
      store.unrealized_finalizations[block_root],
      state.finalized_checkpoint
    )
  end

  # Private Functions - Latest Messages

  defp update_latest_message(store, validator_index, attestation_data) do
    # Get existing message if any
    existing = Map.get(store.latest_messages, validator_index)

    # Update if newer or doesn't exist
    if existing == nil || attestation_data.target.epoch > existing.epoch do
      message = %{
        epoch: attestation_data.target.epoch,
        beacon_block_root: attestation_data.beacon_block_root
      }

      put_in(store.latest_messages[validator_index], message)
    else
      store
    end
  end

  # Private Functions - Proposer Boost

  defp should_update_proposer_boost?(store, block_root) do
    # Apply proposer boost to blocks arriving early in the slot
    time_into_slot = rem(store.time - store.genesis_time, @seconds_per_slot)
    is_before_attesting_interval = time_into_slot < div(@seconds_per_slot, @intervals_per_slot)

    is_before_attesting_interval && is_first_block_for_slot?(store, block_root)
  end

  defp is_first_block_for_slot?(store, block_root) do
    block_info = Map.get(store.blocks, block_root)

    if block_info do
      slot = block_info.block.slot

      # Check if this is the first block we've seen for this slot
      not Enum.any?(store.blocks, fn {other_root, other_info} ->
        other_root != block_root && other_info.block.slot == slot
      end)
    else
      false
    end
  end

  defp calculate_proposer_boost(_state) do
    # Calculate proposer boost amount
    # This is a percentage of the total active balance
    total_active_balance = calculate_total_active_balance(state)
    div(total_active_balance * @proposer_score_boost, 100)
  end

  defp calculate_total_active_balance(_state) do
    # Sum effective balances of active validators
    state.validators
    |> Enum.with_index()
    |> Enum.filter(fn {validator, _index} ->
      is_active_validator?(validator, get_current_epoch(state))
    end)
    |> Enum.reduce(0, fn {validator, _index}, acc ->
      acc + validator.effective_balance
    end)
  end

  # Private Functions - Helpers

  defp get_current_slot(store) do
    div(store.time - store.genesis_time, @seconds_per_slot)
  end

  defp current_slot_changed?(store, new_time) do
    old_slot = div(store.time - store.genesis_time, @seconds_per_slot)
    new_slot = div(new_time - store.genesis_time, @seconds_per_slot)

    new_slot > old_slot
  end

  defp get_current_epoch(_state) do
    div(state.slot, @slots_per_epoch)
  end

  defp is_active_validator?(validator, epoch) do
    validator.activation_epoch <= epoch && epoch < validator.exit_epoch
  end

  defp get_attesting_indices(_state, attestation_data, aggregation_bits) do
    # Get committee for this attestation
    committee =
      get_beacon_committee(
        state,
        attestation_data.slot,
        attestation_data.index
      )

    # Filter by aggregation bits
    committee
    |> Enum.with_index()
    |> Enum.filter(fn {_validator_index, i} ->
      bit_set?(aggregation_bits, i)
    end)
    |> Enum.map(fn {validator_index, _i} -> validator_index end)
  end

  defp get_beacon_committee(_state, slot, index) do
    # Simplified committee retrieval
    # In production, this would use the actual committee computation
    []
  end

  defp get_validator_effective_balance(_store, _validator_index) do
    # Simplified - return standard effective balance
    # 32 ETH in Gwei
    32_000_000_000
  end

  defp bit_set?(bits, index) do
    byte_index = div(index, 8)
    bit_index = rem(index, 8)

    case :binary.at(bits, byte_index) do
      nil -> false
      byte -> (byte &&& 1 <<< bit_index) != 0
    end
  end

  defp hash_tree_root(object) do
    # Simplified SSZ hash tree root
    :crypto.hash(:sha256, :erlang.term_to_binary(object))
  end
end
