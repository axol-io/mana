defmodule ExWire.Eth2.DenebFork do
  @moduledoc """
  Deneb fork transition logic for Ethereum 2.0.

  Implements the consensus layer changes for the Deneb upgrade including:
  - EIP-4844 blob transactions
  - Fork transition at epoch 269,568 (mainnet)
  - State migration and validation rules
  """

  require Logger

  alias ExWire.Eth2.{BeaconState, BeaconBlock, ExecutionPayload}
  alias Blockchain.BlobGasMarket

  # Mainnet fork epochs
  @altair_fork_epoch 74_240
  @bellatrix_fork_epoch 144_896
  @capella_fork_epoch 194_048
  @deneb_fork_epoch 269_568

  # Fork versions
  @phase0_fork_version Base.decode16!("00000000", case: :lower)
  @altair_fork_version Base.decode16!("01000000", case: :lower)
  @bellatrix_fork_version Base.decode16!("02000000", case: :lower)
  @capella_fork_version Base.decode16!("03000000", case: :lower)
  @deneb_fork_version Base.decode16!("04000000", case: :lower)

  # Deneb-specific constants
  @max_blobs_per_block 6
  @max_blob_commitments_per_block 4096
  @blob_sidecar_subnet_count 6

  @doc """
  Check if a given epoch is in the Deneb fork.
  """
  @spec is_deneb_epoch?(non_neg_integer()) :: boolean()
  def is_deneb_epoch?(epoch) do
    epoch >= @deneb_fork_epoch
  end

  @doc """
  Get the fork version for a given epoch.
  """
  @spec get_fork_version(non_neg_integer()) :: binary()
  def get_fork_version(epoch) do
    cond do
      epoch >= @deneb_fork_epoch -> @deneb_fork_version
      epoch >= @capella_fork_epoch -> @capella_fork_version
      epoch >= @bellatrix_fork_epoch -> @bellatrix_fork_version
      epoch >= @altair_fork_epoch -> @altair_fork_version
      true -> @phase0_fork_version
    end
  end

  @doc """
  Upgrade state to Deneb when crossing the fork boundary.
  """
  @spec upgrade_to_deneb(BeaconState.t()) :: {:ok, BeaconState.t()} | {:error, term()}
  def upgrade_to_deneb(pre_state) do
    current_epoch = get_current_epoch(pre_state)

    if current_epoch == @deneb_fork_epoch do
      Logger.info("Upgrading state to Deneb at epoch #{current_epoch}")

      # Update fork version
      new_fork = %{
        previous_version: @capella_fork_version,
        current_version: @deneb_fork_version,
        epoch: @deneb_fork_epoch
      }

      # Initialize blob gas tracking in execution payload header
      updated_payload_header =
        if pre_state.latest_execution_payload_header do
          %{pre_state.latest_execution_payload_header | blob_gas_used: 0, excess_blob_gas: 0}
        else
          nil
        end

      # Create upgraded state
      post_state = %{
        pre_state
        | fork: new_fork,
          latest_execution_payload_header: updated_payload_header
      }

      {:ok, post_state}
    else
      {:error, {:not_deneb_epoch, current_epoch}}
    end
  end

  @doc """
  Validate a beacon block for Deneb-specific rules.
  """
  @spec validate_deneb_block(BeaconBlock.t(), BeaconState.t()) :: :ok | {:error, term()}
  def validate_deneb_block(block, state) do
    if is_deneb_epoch?(get_current_epoch(state)) do
      with :ok <- validate_blob_commitments(block),
           :ok <- validate_execution_payload_deneb(block.body.execution_payload),
           :ok <- validate_blob_gas_usage(block) do
        :ok
      end
    else
      # Pre-Deneb validation
      :ok
    end
  end

  @doc """
  Process Deneb-specific operations in a block.
  """
  @spec process_deneb_operations(BeaconState.t(), BeaconBlock.t()) ::
          {:ok, BeaconState.t()} | {:error, term()}
  def process_deneb_operations(state, block) do
    if is_deneb_epoch?(get_current_epoch(state)) do
      # Process blob KZG commitments
      state = process_blob_kzg_commitments(state, block)

      # Update blob gas state
      state = update_blob_gas_state(state, block)

      {:ok, state}
    else
      {:ok, state}
    end
  end

  @doc """
  Get Deneb-specific configuration.
  """
  @spec deneb_config() :: map()
  def deneb_config do
    %{
      fork_epoch: @deneb_fork_epoch,
      fork_version: @deneb_fork_version,
      max_blobs_per_block: @max_blobs_per_block,
      max_blob_commitments_per_block: @max_blob_commitments_per_block,
      blob_sidecar_subnet_count: @blob_sidecar_subnet_count,
      features: [
        :eip_4844_blobs,
        :blob_gas_market,
        :kzg_commitments,
        :blob_sidecars,
        :eip_7044_exits,
        :eip_7045_attestations,
        :eip_7514_validator_churn
      ]
    }
  end

  @doc """
  Check if a feature is active in Deneb.
  """
  @spec is_feature_active?(atom(), non_neg_integer()) :: boolean()
  def is_feature_active?(feature, epoch) do
    if is_deneb_epoch?(epoch) do
      feature in deneb_config().features
    else
      false
    end
  end

  # Private helper functions

  defp validate_blob_commitments(block) do
    commitments = block.body.blob_kzg_commitments

    cond do
      length(commitments) > @max_blobs_per_block ->
        {:error, {:too_many_blob_commitments, length(commitments)}}

      not Enum.all?(commitments, &valid_commitment?/1) ->
        {:error, :invalid_blob_commitment}

      true ->
        :ok
    end
  end

  defp valid_commitment?(commitment) when byte_size(commitment) == 48 do
    # Basic validation - check it's not zero
    commitment != <<0::384>>
  end

  defp valid_commitment?(_), do: false

  defp validate_execution_payload_deneb(nil), do: :ok

  defp validate_execution_payload_deneb(payload) do
    # Validate Deneb-specific execution payload fields
    with :ok <- validate_blob_gas_fields(payload),
         :ok <- validate_withdrawals(payload) do
      :ok
    end
  end

  defp validate_blob_gas_fields(payload) do
    cond do
      not is_integer(payload.blob_gas_used) or payload.blob_gas_used < 0 ->
        {:error, :invalid_blob_gas_used}

      not is_integer(payload.excess_blob_gas) or payload.excess_blob_gas < 0 ->
        {:error, :invalid_excess_blob_gas}

      payload.blob_gas_used > BlobGasMarket.max_blob_gas_per_block() ->
        {:error, :blob_gas_limit_exceeded}

      true ->
        :ok
    end
  end

  defp validate_withdrawals(payload) do
    # Ensure withdrawals are present (required post-Capella)
    if is_list(payload.withdrawals) do
      :ok
    else
      {:error, :missing_withdrawals}
    end
  end

  defp validate_blob_gas_usage(block) do
    blob_count = length(block.body.blob_kzg_commitments)

    if block.body.execution_payload do
      # Gas per blob
      expected_blob_gas = blob_count * 131_072
      actual_blob_gas = block.body.execution_payload.blob_gas_used

      if expected_blob_gas == actual_blob_gas do
        :ok
      else
        {:error, {:blob_gas_mismatch, expected_blob_gas, actual_blob_gas}}
      end
    else
      if blob_count == 0 do
        :ok
      else
        {:error, :blobs_without_execution_payload}
      end
    end
  end

  defp process_blob_kzg_commitments(state, block) do
    # Store blob commitments in state for later verification
    commitments = block.body.blob_kzg_commitments

    # This would typically update some tracking structure
    # For now, just log the processing
    if length(commitments) > 0 do
      Logger.debug("Processing #{length(commitments)} blob KZG commitments")
    end

    state
  end

  defp update_blob_gas_state(state, block) do
    if block.body.execution_payload do
      payload = block.body.execution_payload

      # Update the latest execution payload header with blob gas info
      updated_header = %{
        state.latest_execution_payload_header
        | blob_gas_used: payload.blob_gas_used,
          excess_blob_gas: payload.excess_blob_gas
      }

      %{state | latest_execution_payload_header: updated_header}
    else
      state
    end
  end

  defp get_current_epoch(state) do
    # 32 slots per epoch
    div(state.slot, 32)
  end

  defp max_blob_gas_per_block() do
    # 6 blobs * 131,072 gas per blob
    786_432
  end
end
