defmodule ExWire.Eth2.Attestation.Operations do
  @moduledoc """
  Attestation operations for Ethereum 2.0 beacon chain.

  Contains functions for creating, validating, and processing validator 
  attestations to beacon blocks.
  """

  import Bitwise
  alias ExWire.Eth2.{Attestation, AttestationData, BeaconState, Checkpoint}

  # The Attestation struct is defined in types.ex

  @target_committee_size 128
  @slots_per_epoch 32

  @doc """
  Creates a new attestation.
  """
  @spec new(non_neg_integer(), non_neg_integer(), binary(), Checkpoint.t(), Checkpoint.t()) ::
          Attestation.t()
  def new(slot, committee_index, beacon_block_root, source, target) do
    %ExWire.Eth2.Attestation{
      # All zeros initially
      aggregation_bits: <<0::@target_committee_size>>,
      data: %ExWire.Eth2.AttestationData{
        slot: slot,
        index: committee_index,
        beacon_block_root: beacon_block_root,
        source: source,
        target: target
      },
      # 96 bytes BLS signature placeholder
      signature: <<0::768>>
    }
  end

  @doc """
  Validates an attestation structure.
  """
  @spec validate_structure(Attestation.t()) :: :ok | {:error, term()}
  def validate_structure(%ExWire.Eth2.Attestation{} = attestation) do
    with :ok <- validate_aggregation_bits(attestation.aggregation_bits),
         :ok <- validate_data(attestation.data),
         :ok <- validate_signature(attestation.signature) do
      :ok
    end
  end

  @doc """
  Validates an attestation against the beacon state.
  """
  @spec validate_attestation(BeaconState.t(), Attestation.t()) :: :ok | {:error, term()}
  def validate_attestation(_state, attestation) do
    with :ok <- validate_structure(attestation),
         :ok <- validate_attestation_slot(state, attestation),
         :ok <- validate_committee_index(state, attestation),
         :ok <- validate_checkpoints(state, attestation) do
      :ok
    end
  end

  @doc """
  Processes an attestation by updating validator participation.
  """
  @spec process_attestation(BeaconState.t(), Attestation.t()) ::
          {:ok, BeaconState.t()} | {:error, term()}
  def process_attestation(_state, attestation) do
    case validate_attestation(state, attestation) do
      :ok ->
        new_state = update_participation(_state, attestation)
        {:ok, new_state}

      error ->
        error
    end
  end

  @doc """
  Aggregates multiple attestations with the same data.
  """
  @spec aggregate_attestations([Attestation.t()]) :: {:ok, Attestation.t()} | {:error, term()}
  def aggregate_attestations([]), do: {:error, :empty_list}
  def aggregate_attestations([single]), do: {:ok, single}

  def aggregate_attestations([first | rest]) do
    # Verify all have same data
    if Enum.all?(rest, fn att -> att.data == first.data end) do
      aggregated_bits =
        aggregate_bits([first.aggregation_bits | Enum.map(rest, & &1.aggregation_bits)])

      aggregated_signature =
        aggregate_signatures([first.signature | Enum.map(rest, & &1.signature)])

      {:ok, %{first | aggregation_bits: aggregated_bits, signature: aggregated_signature}}
    else
      {:error, :mismatched_data}
    end
  end

  @doc """
  Gets the committee for an attestation.
  """
  @spec get_beacon_committee(BeaconState.t(), non_neg_integer(), non_neg_integer()) :: [
          non_neg_integer()
        ]
  def get_beacon_committee(_state, slot, committee_index) do
    epoch = div(slot, @slots_per_epoch)

    committees_per_slot =
      max(
        1,
        div(
          length(ExWire.Eth2.BeaconState.Operations.get_active_validator_indices(state, epoch)),
          @slots_per_epoch
        )
      )

    # Simplified committee selection - in production would use proper shuffling
    active_validators =
      ExWire.Eth2.BeaconState.Operations.get_active_validator_indices(state, epoch)

    committee_size = div(length(active_validators), committees_per_slot)

    start_index = committee_index * committee_size
    Enum.slice(active_validators, start_index, committee_size)
  end

  @doc """
  Signs an attestation with a validator's private key.
  """
  @spec sign_attestation(AttestationData.t(), binary()) :: binary()
  def sign_attestation(data, private_key) do
    # In a real implementation, this would use BLS signing with domain separation
    :crypto.hash(:sha256, <<:erlang.term_to_binary(data)::binary, private_key::binary>>)
  end

  @doc """
  Verifies an attestation signature.
  """
  @spec verify_attestation_signature(Attestation.t(), [binary()]) :: boolean()
  def verify_attestation_signature(attestation, validator_pubkeys) do
    # In a real implementation, this would use BLS aggregate verification
    # For now, simplified verification
    expected =
      aggregate_signatures(
        Enum.map(validator_pubkeys, fn pubkey ->
          sign_attestation(attestation.data, pubkey)
        end)
      )

    attestation.signature == expected
  end

  # Private helper functions

  defp validate_aggregation_bits(bits) when is_binary(bits) do
    if byte_size(bits) == div(@target_committee_size, 8) do
      :ok
    else
      {:error, :invalid_aggregation_bits_size}
    end
  end

  defp validate_aggregation_bits(_), do: {:error, :invalid_aggregation_bits_type}

  defp validate_data(%ExWire.Eth2.AttestationData{} = data) do
    with :ok <- validate_slot(data.slot),
         :ok <- validate_committee_index(data.index),
         :ok <- validate_beacon_block_root(data.beacon_block_root),
         :ok <- validate_checkpoint(data.source),
         :ok <- validate_checkpoint(data.target) do
      :ok
    end
  end

  defp validate_data(_), do: {:error, :invalid_attestation_data}

  defp validate_signature(sig) when is_binary(sig) and byte_size(sig) == 96, do: :ok
  defp validate_signature(_), do: {:error, :invalid_signature}

  defp validate_slot(slot) when is_integer(slot) and slot >= 0, do: :ok
  defp validate_slot(_), do: {:error, :invalid_slot}

  defp validate_committee_index(index) when is_integer(index) and index >= 0, do: :ok
  defp validate_committee_index(_), do: {:error, :invalid_committee_index}

  defp validate_beacon_block_root(root) when is_binary(root) and byte_size(root) == 32, do: :ok
  defp validate_beacon_block_root(_), do: {:error, :invalid_beacon_block_root}

  defp validate_checkpoint(%ExWire.Eth2.Checkpoint{epoch: epoch, root: root})
       when is_integer(epoch) and epoch >= 0 and is_binary(root) and byte_size(root) == 32 do
    :ok
  end

  defp validate_checkpoint(_), do: {:error, :invalid_checkpoint}

  defp validate_attestation_slot(_state, %{data: %{slot: slot}}) do
    current_slot = state.slot

    if slot <= current_slot and slot + @slots_per_epoch >= current_slot do
      :ok
    else
      {:error, :attestation_too_old_or_future}
    end
  end

  defp validate_committee_index(_state, %{data: %{slot: slot, index: index}}) do
    epoch = div(slot, @slots_per_epoch)

    active_count =
      length(ExWire.Eth2.BeaconState.Operations.get_active_validator_indices(state, epoch))

    max_committees = max(1, div(active_count, @slots_per_epoch))

    if index < max_committees do
      :ok
    else
      {:error, :invalid_committee_index}
    end
  end

  defp validate_checkpoints(_state, %{data: %{source: source, target: target}}) do
    cond do
      source.epoch >= target.epoch ->
        {:error, :source_epoch_not_before_target}

      target.epoch != ExWire.Eth2.BeaconState.Operations.get_current_epoch(state) and
          target.epoch != ExWire.Eth2.BeaconState.Operations.get_previous_epoch(state) ->
        {:error, :invalid_target_epoch}

      true ->
        :ok
    end
  end

  defp update_participation(_state, attestation) do
    # Update participation flags for validators in the committee
    epoch = ExWire.Eth2.BeaconState.Operations.get_current_epoch(state)
    committee = get_beacon_committee(state, attestation.data.slot, attestation.data.index)

    # Simplified participation update - would be more complex in production
    new_participation =
      if epoch == ExWire.Eth2.BeaconState.Operations.get_current_epoch(state) do
        update_current_participation(
          state.current_epoch_participation,
          committee,
          attestation.aggregation_bits
        )
      else
        state.current_epoch_participation
      end

    %{state | current_epoch_participation: new_participation}
  end

  defp update_current_participation(participation, committee, aggregation_bits) do
    # Update participation based on aggregation bits
    # Placeholder - would implement bit manipulation
    participation
  end

  defp aggregate_bits(bit_lists) do
    # OR together all bit lists
    Enum.reduce(bit_lists, <<0::@target_committee_size>>, fn bits, acc ->
      # Bitwise OR of binary data (simplified)
      <<acc_int::@target_committee_size>> = acc
      <<bits_int::@target_committee_size>> = bits
      <<acc_int ||| bits_int::@target_committee_size>>
    end)
  end

  defp aggregate_signatures(signatures) do
    # In a real implementation, this would use BLS signature aggregation
    # For now, just hash them together as a placeholder
    combined = Enum.reduce(signatures, <<>>, fn sig, acc -> <<acc::binary, sig::binary>> end)
    :crypto.hash(:sha256, combined) |> :crypto.hash(:sha256) |> :crypto.hash(:sha256)
  end
end
