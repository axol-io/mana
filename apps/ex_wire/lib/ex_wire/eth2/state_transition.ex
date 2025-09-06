defmodule ExWire.Eth2.StateTransition do
  @moduledoc """
  State transition functions for Ethereum 2.0 beacon chain.

  Implements the beacon chain state transition function that processes
  blocks and updates the beacon state according to the Ethereum 2.0 specification.
  """

  alias ExWire.Eth2.{BeaconState, BeaconBlock}

  @slots_per_epoch 32

  @doc """
  Full state transition function: processes slots and blocks.
  """
  @spec state_transition(BeaconState.t(), BeaconBlock.t()) ::
          {:ok, BeaconState.t()} | {:error, term()}
  def state_transition(state, block) do
    with {:ok, state} <- process_slots_until_block(state, block.slot),
         {:ok, state} <- process_block(state, block) do
      {:ok, state}
    end
  end

  @doc """
  Process empty slots until the target slot.
  """
  @spec process_slots_until_block(BeaconState.t(), non_neg_integer()) ::
          {:ok, BeaconState.t()} | {:error, term()}
  def process_slots_until_block(state, target_slot) when target_slot > state.slot do
    # Process each slot individually
    process_slots_range(state, state.slot + 1, target_slot)
  end

  def process_slots_until_block(state, target_slot) when target_slot == state.slot do
    {:ok, state}
  end

  def process_slots_until_block(_state, target_slot) do
    {:error, {:invalid_target_slot, target_slot}}
  end

  @doc """
  Process a beacon block and return the new state.
  """
  @spec process_block(BeaconState.t(), BeaconBlock.t()) ::
          {:ok, BeaconState.t()} | {:error, term()}
  def process_block(state, block) do
    # Use the BeaconBlock module's process_block function
    ExWire.Eth2.BeaconBlock.Operations.process_block(state, block)
  end

  @doc """
  Process epoch transition at epoch boundaries.
  """
  @spec process_epoch_transition(BeaconState.t()) :: BeaconState.t()
  def process_epoch_transition(state) do
    # Use the BeaconState module's process_epoch function
    ExWire.Eth2.BeaconState.Operations.process_epoch(state)
  end

  @doc """
  Validate a state transition.
  """
  @spec validate_state_transition(BeaconState.t(), BeaconBlock.t(), BeaconState.t()) ::
          :ok | {:error, term()}
  def validate_state_transition(pre_state, block, post_state) do
    with {:ok, expected_state} <- state_transition(pre_state, block) do
      if states_equal?(expected_state, post_state) do
        :ok
      else
        {:error, :state_mismatch}
      end
    end
  end

  @doc """
  Get the next slot that should have a block.
  """
  @spec get_next_slot(BeaconState.t()) :: non_neg_integer()
  def get_next_slot(%{slot: slot}), do: slot + 1

  @doc """
  Check if a slot is at an epoch boundary.
  """
  @spec is_epoch_boundary?(non_neg_integer()) :: boolean()
  def is_epoch_boundary?(slot), do: rem(slot, @slots_per_epoch) == 0

  @doc """
  Get the epoch for a given slot.
  """
  @spec get_epoch_for_slot(non_neg_integer()) :: non_neg_integer()
  def get_epoch_for_slot(slot), do: div(slot, @slots_per_epoch)

  @doc """
  Get the first slot of an epoch.
  """
  @spec get_epoch_start_slot(non_neg_integer()) :: non_neg_integer()
  def get_epoch_start_slot(epoch), do: epoch * @slots_per_epoch

  @doc """
  Advance state to the next epoch.
  """
  @spec advance_to_next_epoch(BeaconState.t()) :: BeaconState.t()
  def advance_to_next_epoch(state) do
    current_epoch = ExWire.Eth2.BeaconState.Operations.get_current_epoch(state)
    next_epoch_start_slot = get_epoch_start_slot(current_epoch + 1)

    # Process slots up to the next epoch
    case process_slots_until_block(state, next_epoch_start_slot) do
      {:ok, new_state} -> new_state
      # Fallback
      {:error, _} -> state
    end
  end

  # Private functions

  defp process_slots_range(state, current_slot, target_slot) when current_slot > target_slot do
    {:ok, state}
  end

  defp process_slots_range(state, current_slot, target_slot) do
    # Process single slot
    new_state = process_single_slot(state, current_slot)

    # Check if we need epoch processing
    final_state =
      if is_epoch_boundary?(current_slot) and current_slot > 0 do
        process_epoch_transition(new_state)
      else
        new_state
      end

    # Continue to next slot
    process_slots_range(final_state, current_slot + 1, target_slot)
  end

  defp process_single_slot(state, slot) do
    # Use BeaconState's process_slot function
    state
    |> Map.put(:slot, slot)
    |> ExWire.Eth2.BeaconState.Operations.process_slot()
  end

  defp states_equal?(state1, state2) do
    # Simplified state comparison - in production would compare all fields
    state1.slot == state2.slot and
      state1.finalized_checkpoint == state2.finalized_checkpoint and
      state1.current_justified_checkpoint == state2.current_justified_checkpoint
  end
end
