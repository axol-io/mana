defmodule ExWire.Eth2.MainnetConfig do
  @moduledoc """
  Ethereum mainnet configuration constants for Deneb.

  All official mainnet parameters for consensus layer operations,
  including fork epochs, domain types, and protocol constants.
  """

  # Fork epochs (mainnet)
  @phase0_fork_epoch 0
  @altair_fork_epoch 74_240
  @bellatrix_fork_epoch 144_896
  @capella_fork_epoch 194_048
  @deneb_fork_epoch 269_568

  # Fork versions
  @phase0_fork_version Base.decode16!("00000001", case: :lower)
  @altair_fork_version Base.decode16!("01000001", case: :lower)
  @bellatrix_fork_version Base.decode16!("02000001", case: :lower)
  @capella_fork_version Base.decode16!("03000001", case: :lower)
  @deneb_fork_version Base.decode16!("04000001", case: :lower)

  # Domain types
  @domain_beacon_proposer Base.decode16!("00000000", case: :lower)
  @domain_beacon_attester Base.decode16!("01000000", case: :lower)
  @domain_randao Base.decode16!("02000000", case: :lower)
  @domain_deposit Base.decode16!("03000000", case: :lower)
  @domain_voluntary_exit Base.decode16!("04000000", case: :lower)
  @domain_selection_proof Base.decode16!("05000000", case: :lower)
  @domain_aggregate_and_proof Base.decode16!("06000000", case: :lower)
  @domain_sync_committee Base.decode16!("07000000", case: :lower)
  @domain_sync_committee_selection_proof Base.decode16!("08000000", case: :lower)
  @domain_contribution_and_proof Base.decode16!("09000000", case: :lower)
  @domain_bls_to_execution_change Base.decode16!("0a000000", case: :lower)
  @domain_blob_sidecar Base.decode16!("0b000000", case: :lower)

  # Time parameters
  @seconds_per_slot 12
  @seconds_per_eth1_block 14
  @min_validator_withdrawability_delay 256
  @shard_committee_period 256
  @eth1_follow_distance 2048

  # Slots
  @slots_per_epoch 32
  @slots_per_historical_root 8192
  @min_seed_lookahead 1
  @max_seed_lookahead 4
  @min_epochs_to_inactivity_penalty 4

  # Validator
  # 1 ETH in Gwei
  @min_deposit_amount 1_000_000_000
  # 32 ETH in Gwei
  @max_effective_balance 32_000_000_000
  # 16 ETH in Gwei
  @ejection_balance 16_000_000_000
  # 1 ETH in Gwei
  @effective_balance_increment 1_000_000_000

  # Attestation
  @max_committees_per_slot 64
  @target_committee_size 128
  @max_validators_per_committee 2048
  @shuffle_round_count 90

  # Deposit contract
  @deposit_chain_id 1
  @deposit_network_id 1
  @deposit_contract_address :binary.encode_unsigned(0x00000000000000000000000000000000000022)

  # Gwei values
  @gwei_per_eth 1_000_000_000
  @wei_per_gwei 1_000_000_000

  # Initial values
  @genesis_slot 0
  @genesis_epoch 0
  # 2^64 - 1
  @far_future_epoch 18_446_744_073_709_551_615

  # Rewards and penalties
  @base_reward_factor 64
  @whistleblower_reward_quotient 512
  @proposer_reward_quotient 8
  # 2^26
  @inactivity_penalty_quotient 67_108_864
  @min_slashing_penalty_quotient 128
  @proportional_slashing_multiplier 1

  # Max operations per block
  @max_proposer_slashings 16
  @max_attester_slashings 2
  @max_attestations 128
  @max_deposits 16
  @max_voluntary_exits 16

  # Sync committee
  @sync_committee_size 512
  @epochs_per_sync_committee_period 256

  # Deneb/EIP-4844 specific
  @max_blobs_per_block 6
  @max_blob_commitments_per_block 4096
  @field_elements_per_blob 4096
  @bytes_per_field_element 32
  @bytes_per_blob 131_072
  @kzg_commitment_inclusion_proof_depth 17
  @blob_sidecar_subnet_count 6
  @min_epochs_for_blob_sidecars_request 4096

  # Blob gas
  # 2^17
  @blob_gas_per_blob 131_072
  # 3 * blob_gas_per_blob
  @target_blob_gas_per_block 393_216
  # 6 * blob_gas_per_blob
  @max_blob_gas_per_block 786_432
  @blob_base_fee_update_fraction 3_338_477

  # Withdrawals
  @max_withdrawals_per_payload 16
  @max_validators_per_withdrawals_sweep 16_384

  # Capella
  @max_bls_to_execution_changes 16

  # Light client
  @light_client_update_timeout 8192
  @light_client_finality_update_timeout 512

  # Getters for all constants

  def phase0_fork_epoch, do: @phase0_fork_epoch
  def altair_fork_epoch, do: @altair_fork_epoch
  def bellatrix_fork_epoch, do: @bellatrix_fork_epoch
  def capella_fork_epoch, do: @capella_fork_epoch
  def deneb_fork_epoch, do: @deneb_fork_epoch

  def phase0_fork_version, do: @phase0_fork_version
  def altair_fork_version, do: @altair_fork_version
  def bellatrix_fork_version, do: @bellatrix_fork_version
  def capella_fork_version, do: @capella_fork_version
  def deneb_fork_version, do: @deneb_fork_version

  def domain_beacon_proposer, do: @domain_beacon_proposer
  def domain_beacon_attester, do: @domain_beacon_attester
  def domain_randao, do: @domain_randao
  def domain_deposit, do: @domain_deposit
  def domain_voluntary_exit, do: @domain_voluntary_exit
  def domain_selection_proof, do: @domain_selection_proof
  def domain_aggregate_and_proof, do: @domain_aggregate_and_proof
  def domain_sync_committee, do: @domain_sync_committee
  def domain_sync_committee_selection_proof, do: @domain_sync_committee_selection_proof
  def domain_contribution_and_proof, do: @domain_contribution_and_proof
  def domain_bls_to_execution_change, do: @domain_bls_to_execution_change
  def domain_blob_sidecar, do: @domain_blob_sidecar

  def seconds_per_slot, do: @seconds_per_slot
  def slots_per_epoch, do: @slots_per_epoch
  def epochs_per_sync_committee_period, do: @epochs_per_sync_committee_period

  def max_effective_balance, do: @max_effective_balance
  def min_deposit_amount, do: @min_deposit_amount

  def max_committees_per_slot, do: @max_committees_per_slot
  def target_committee_size, do: @target_committee_size

  def max_proposer_slashings, do: @max_proposer_slashings
  def max_attester_slashings, do: @max_attester_slashings
  def max_attestations, do: @max_attestations
  def max_deposits, do: @max_deposits
  def max_voluntary_exits, do: @max_voluntary_exits

  def sync_committee_size, do: @sync_committee_size

  def max_blobs_per_block, do: @max_blobs_per_block
  def bytes_per_blob, do: @bytes_per_blob
  def blob_gas_per_blob, do: @blob_gas_per_blob
  def target_blob_gas_per_block, do: @target_blob_gas_per_block
  def max_blob_gas_per_block, do: @max_blob_gas_per_block
  def blob_sidecar_subnet_count, do: @blob_sidecar_subnet_count
  def min_epochs_for_blob_sidecars_request, do: @min_epochs_for_blob_sidecars_request

  def max_withdrawals_per_payload, do: @max_withdrawals_per_payload
  def max_bls_to_execution_changes, do: @max_bls_to_execution_changes

  @doc """
  Get fork version for a given epoch.
  """
  @spec get_fork_version_for_epoch(non_neg_integer()) :: binary()
  def get_fork_version_for_epoch(epoch) do
    cond do
      epoch >= @deneb_fork_epoch -> @deneb_fork_version
      epoch >= @capella_fork_epoch -> @capella_fork_version
      epoch >= @bellatrix_fork_epoch -> @bellatrix_fork_version
      epoch >= @altair_fork_epoch -> @altair_fork_version
      true -> @phase0_fork_version
    end
  end

  @doc """
  Get the current fork name for an epoch.
  """
  @spec get_fork_name(non_neg_integer()) :: atom()
  def get_fork_name(epoch) do
    cond do
      epoch >= @deneb_fork_epoch -> :deneb
      epoch >= @capella_fork_epoch -> :capella
      epoch >= @bellatrix_fork_epoch -> :bellatrix
      epoch >= @altair_fork_epoch -> :altair
      true -> :phase0
    end
  end

  @doc """
  Check if an epoch has reached a specific fork.
  """
  @spec has_reached_fork?(non_neg_integer(), atom()) :: boolean()
  def has_reached_fork?(_epoch, :phase0), do: true
  def has_reached_fork?(epoch, :altair), do: epoch >= @altair_fork_epoch
  def has_reached_fork?(epoch, :bellatrix), do: epoch >= @bellatrix_fork_epoch
  def has_reached_fork?(epoch, :capella), do: epoch >= @capella_fork_epoch
  def has_reached_fork?(epoch, :deneb), do: epoch >= @deneb_fork_epoch
  def has_reached_fork?(_, _), do: false

  @doc """
  Get complete mainnet preset configuration.
  """
  @spec mainnet_preset() :: map()
  def mainnet_preset do
    %{
      # Meta
      preset_base: "mainnet",

      # Misc
      max_committees_per_slot: @max_committees_per_slot,
      target_committee_size: @target_committee_size,
      max_validators_per_committee: @max_validators_per_committee,
      shuffle_round_count: @shuffle_round_count,

      # Gwei values
      min_deposit_amount: @min_deposit_amount,
      max_effective_balance: @max_effective_balance,
      effective_balance_increment: @effective_balance_increment,

      # Time
      seconds_per_slot: @seconds_per_slot,
      slots_per_epoch: @slots_per_epoch,

      # Max operations
      max_proposer_slashings: @max_proposer_slashings,
      max_attester_slashings: @max_attester_slashings,
      max_attestations: @max_attestations,
      max_deposits: @max_deposits,
      max_voluntary_exits: @max_voluntary_exits,

      # Deneb
      max_blobs_per_block: @max_blobs_per_block,
      field_elements_per_blob: @field_elements_per_blob,
      bytes_per_field_element: @bytes_per_field_element,
      bytes_per_blob: @bytes_per_blob,

      # Sync
      sync_committee_size: @sync_committee_size,
      epochs_per_sync_committee_period: @epochs_per_sync_committee_period
    }
  end
end
