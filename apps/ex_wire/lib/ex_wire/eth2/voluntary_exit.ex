defmodule ExWire.Eth2.VoluntaryExit.Validator do
  @moduledoc """
  EIP-7044 Perpetually Valid Signed Voluntary Exits.

  This module implements the validation logic for voluntary exits that remain
  valid across fork boundaries, as specified in EIP-7044.
  """

  require Logger
  alias ExWire.Eth2.{VoluntaryExit, SignedVoluntaryExit, BeaconState}

  # EIP-7044 constants
  # Genesis fork version acts as a universal domain
  @capella_fork_version Base.decode16!("03000000", case: :lower)
  # Domain for voluntary exits
  @domain_voluntary_exit Base.decode16!("04000000", case: :lower)

  @doc """
  Validate a signed voluntary exit with EIP-7044 perpetual validity.

  Unlike regular voluntary exits, EIP-7044 exits use the Capella fork version
  as the domain, making them valid across all future forks.
  """
  @spec validate_signed_voluntary_exit(SignedVoluntaryExit.t(), BeaconState.t()) ::
          :ok | {:error, term()}
  def validate_signed_voluntary_exit(signed_exit, state) do
    with :ok <- validate_exit_message(signed_exit.message, state),
         :ok <- validate_exit_signature(signed_exit, state) do
      :ok
    end
  end

  @doc """
  Validate the voluntary exit message content.
  """
  @spec validate_exit_message(VoluntaryExit.t(), BeaconState.t()) :: :ok | {:error, term()}
  def validate_exit_message(exit, state) do
    validator = Enum.at(state.validators, exit.validator_index)

    cond do
      is_nil(validator) ->
        {:error, :validator_not_found}

      validator.exit_epoch != :far_future_epoch ->
        {:error, :validator_already_exited}

      get_current_epoch(state) < exit.epoch ->
        {:error, :exit_epoch_in_future}

      get_current_epoch(state) < validator.activation_epoch + get_shard_committee_period() ->
        {:error, :validator_not_active_long_enough}

      exit.epoch < get_earliest_exit_epoch(state) ->
        {:error, :exit_epoch_too_early}

      true ->
        :ok
    end
  end

  @doc """
  Validate the voluntary exit signature using EIP-7044 perpetual validity rules.
  """
  @spec validate_exit_signature(SignedVoluntaryExit.t(), BeaconState.t()) ::
          :ok | {:error, term()}
  def validate_exit_signature(signed_exit, state) do
    validator = Enum.at(state.validators, signed_exit.message.validator_index)

    if is_nil(validator) do
      {:error, :validator_not_found}
    else
      # EIP-7044: Use Capella fork version for perpetual validity
      domain = compute_domain_for_exit(state)
      signing_root = compute_signing_root(signed_exit.message, domain)

      # Verify BLS signature
      case ExWire.Crypto.BLS.verify(validator.pubkey, signing_root, signed_exit.signature) do
        {:ok, true} ->
          :ok

        {:ok, false} ->
          {:error, :invalid_signature}

        {:error, reason} ->
          {:error, {:signature_verification_failed, reason}}
      end
    end
  end

  @doc """
  Process a voluntary exit, updating the validator's exit epoch.
  """
  @spec process_voluntary_exit(BeaconState.t(), SignedVoluntaryExit.t()) ::
          {:ok, BeaconState.t()} | {:error, term()}
  def process_voluntary_exit(state, signed_exit) do
    with :ok <- validate_signed_voluntary_exit(signed_exit, state) do
      exit = signed_exit.message
      validator = Enum.at(state.validators, exit.validator_index)

      # Set exit epoch
      exit_epoch = max(exit.epoch, get_earliest_exit_epoch(state))
      updated_validator = %{validator | exit_epoch: exit_epoch}

      # Update validators list
      new_validators = List.replace_at(state.validators, exit.validator_index, updated_validator)
      new_state = %{state | validators: new_validators}

      Logger.info(
        "Processed voluntary exit for validator #{exit.validator_index}, exit epoch: #{exit_epoch}"
      )

      {:ok, new_state}
    end
  end

  @doc """
  Get the earliest possible exit epoch based on current state.
  """
  @spec get_earliest_exit_epoch(BeaconState.t()) :: non_neg_integer()
  def get_earliest_exit_epoch(state) do
    # Find maximum exit epoch among current validators
    max_exit_epoch =
      state.validators
      |> Enum.map(& &1.exit_epoch)
      |> Enum.reject(&(&1 == :far_future_epoch))
      |> Enum.max(fn -> get_current_epoch(state) end)

    # Exit queue churn limit
    current_epoch = get_current_epoch(state)
    max(current_epoch + 1, max_exit_epoch + 1)
  end

  @doc """
  Check if a validator can submit a voluntary exit.
  """
  @spec can_validator_exit?(BeaconState.t(), non_neg_integer()) :: boolean()
  def can_validator_exit?(state, validator_index) do
    case Enum.at(state.validators, validator_index) do
      nil ->
        false

      validator ->
        current_epoch = get_current_epoch(state)

        validator.exit_epoch == :far_future_epoch &&
          current_epoch >= validator.activation_epoch + get_shard_committee_period()
    end
  end

  # Private helper functions

  defp compute_domain_for_exit(state) do
    # EIP-7044: Use Capella fork version for perpetual validity
    fork_data = %{
      current_version: @capella_fork_version,
      genesis_validators_root: state.genesis_validators_root
    }

    compute_domain(@domain_voluntary_exit, fork_data)
  end

  defp compute_domain(domain_type, fork_data) do
    fork_data_root = SSZ.hash_tree_root(fork_data)
    # First 28 bytes
    domain_type <> fork_data_root[0..27]
  end

  defp compute_signing_root(object, domain) do
    signing_data = %{
      object_root: SSZ.hash_tree_root(object),
      domain: domain
    }

    SSZ.hash_tree_root(signing_data)
  end

  defp get_current_epoch(state) do
    # 32 slots per epoch
    div(state.slot, 32)
  end

  defp get_shard_committee_period do
    # MIN_VALIDATOR_WITHDRAWABILITY_DELAY = 256 epochs
    256
  end
end
