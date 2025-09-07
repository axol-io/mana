defmodule ExWire.Eth2.BeaconState do
  @moduledoc """
  Ethereum 2.0 Beacon State data structure.
  Contains the complete state of the beacon chain at a given slot.
  """

  defstruct [
    # Versioning
    :genesis_time,
    :genesis_validators_root,
    :slot,
    :fork,

    # History
    :latest_block_header,
    :block_roots,
    :state_roots,
    :historical_roots,

    # Eth1
    :eth1_data,
    :eth1_data_votes,
    :eth1_deposit_index,

    # Registry
    :validators,
    :balances,

    # Randomness
    :randao_mixes,

    # Slashings
    :slashings,

    # Participation
    :previous_epoch_participation,
    :current_epoch_participation,

    # Finality
    :justification_bits,
    :previous_justified_checkpoint,
    :current_justified_checkpoint,
    :finalized_checkpoint,

    # Sync
    :current_sync_committee,
    :next_sync_committee,

    # Execution
    :latest_execution_payload_header,

    # Withdrawals
    :next_withdrawal_index,
    :next_withdrawal_validator_index,

    # Deep history (Capella)
    :historical_summaries
  ]
end

defmodule ExWire.Eth2.Validator do
  @moduledoc """
  Validator record in the beacon chain.
  """

  defstruct [
    :pubkey,
    :withdrawal_credentials,
    :effective_balance,
    :slashed,
    :activation_eligibility_epoch,
    :activation_epoch,
    :exit_epoch,
    :withdrawable_epoch
  ]
end

defmodule ExWire.Eth2.BeaconBlock do
  @moduledoc """
  Beacon chain block structure.
  """

  defstruct [
    :slot,
    :proposer_index,
    :parent_root,
    :state_root,
    :body
  ]
end

defmodule ExWire.Eth2.BeaconBlock.Body do
  @moduledoc """
  Beacon block body containing all operations.
  """

  defstruct [
    :randao_reveal,
    :eth1_data,
    :graffiti,
    :proposer_slashings,
    :attester_slashings,
    :attestations,
    :deposits,
    :voluntary_exits,
    :sync_aggregate,
    :execution_payload,
    :bls_to_execution_changes,
    :blob_kzg_commitments
  ]
end

defmodule ExWire.Eth2.SignedBeaconBlock do
  @moduledoc """
  Signed beacon block with BLS signature.
  """

  defstruct [
    :message,
    :signature
  ]
end

defmodule ExWire.Eth2.Attestation do
  @moduledoc """
  Attestation to a block by a committee of validators.
  """

  defstruct [
    :aggregation_bits,
    :data,
    :signature
  ]
end

defmodule ExWire.Eth2.AttestationData do
  @moduledoc """
  Data being attested to in an attestation.
  """

  defstruct [
    :slot,
    :index,
    :beacon_block_root,
    :source,
    :target
  ]
end

defmodule ExWire.Eth2.ExecutionPayloadHeader do
  @moduledoc """
  Header of an execution payload for light clients.
  """

  defstruct [
    :parent_hash,
    :fee_recipient,
    :state_root,
    :receipts_root,
    :logs_bloom,
    :prev_randao,
    :block_number,
    :gas_limit,
    :gas_used,
    :timestamp,
    :extra_data,
    :base_fee_per_gas,
    :block_hash,
    :transactions_root,
    :withdrawals_root,
    :blob_gas_used,
    :excess_blob_gas
  ]
end

defmodule ExWire.Eth2.Withdrawal do
  @moduledoc """
  Validator withdrawal from beacon chain to execution layer.
  """

  defstruct [
    :index,
    :validator_index,
    :address,
    :amount
  ]
end

defmodule ExWire.Eth2.SyncAggregate do
  @moduledoc """
  Sync committee aggregate signature.
  """

  defstruct [
    :sync_committee_bits,
    :sync_committee_signature
  ]
end

defmodule ExWire.Eth2.ProposerSlashing do
  @moduledoc """
  Evidence of a validator proposing two conflicting blocks.
  """

  defstruct [
    :signed_header_1,
    :signed_header_2
  ]
end

defmodule ExWire.Eth2.AttesterSlashing do
  @moduledoc """
  Evidence of validators making conflicting attestations.
  """

  defstruct [
    :attestation_1,
    :attestation_2
  ]
end

defmodule ExWire.Eth2.Deposit do
  @moduledoc """
  Deposit from Eth1 chain to become a validator.
  """

  defstruct [
    :proof,
    :data
  ]
end

defmodule ExWire.Eth2.DepositData do
  @moduledoc """
  Data for a validator deposit.
  """

  defstruct [
    :pubkey,
    :withdrawal_credentials,
    :amount,
    :signature
  ]
end

defmodule ExWire.Eth2.VoluntaryExit do
  @moduledoc """
  Voluntary exit of a validator.
  """

  defstruct [
    :epoch,
    :validator_index
  ]
end

defmodule ExWire.Eth2.SignedVoluntaryExit do
  @moduledoc """
  Signed voluntary exit.
  """

  defstruct [
    :message,
    :signature
  ]
end

defmodule ExWire.Eth2.BLSToExecutionChange do
  @moduledoc """
  Change withdrawal credentials from BLS to execution address.
  """

  defstruct [
    :validator_index,
    :from_bls_pubkey,
    :to_execution_address
  ]
end

defmodule ExWire.Eth2.SignedBLSToExecutionChange do
  @moduledoc """
  Signed BLS to execution change.
  """

  defstruct [
    :message,
    :signature
  ]
end

defmodule ExWire.Eth2.Fork do
  @moduledoc """
  Fork version and epoch.
  """

  defstruct [
    :previous_version,
    :current_version,
    :epoch
  ]
end

defmodule ExWire.Eth2.ForkData do
  @moduledoc """
  Fork data for domain computation.
  """

  defstruct [
    :current_version,
    :genesis_validators_root
  ]
end

defmodule ExWire.Eth2.HistoricalSummary do
  @moduledoc """
  Historical summary for deep history.
  """

  defstruct [
    :block_summary_root,
    :state_summary_root
  ]
end

defmodule ExWire.Eth2.Eth1Data do
  @moduledoc """
  Eth1 chain reference data.
  """

  defstruct [
    :deposit_root,
    :deposit_count,
    :block_hash
  ]
end

defmodule ExWire.Eth2.BeaconBlockHeader do
  @moduledoc """
  Beacon block header for light clients.
  """

  defstruct [
    :slot,
    :proposer_index,
    :parent_root,
    :state_root,
    :body_root
  ]
end

defmodule ExWire.Eth2.SignedBeaconBlockHeader do
  @moduledoc """
  Signed beacon block header.
  """

  defstruct [
    :message,
    :signature
  ]
end

defmodule ExWire.Eth2.IndexedAttestation do
  @moduledoc """
  Attestation with sorted validator indices.
  """

  defstruct [
    :attesting_indices,
    :data,
    :signature
  ]
end

defmodule ExWire.Eth2.PendingAttestation do
  @moduledoc """
  Pending attestation for processing.
  """

  defstruct [
    :aggregation_bits,
    :data,
    :inclusion_delay,
    :proposer_index
  ]
end

defmodule ExWire.Eth2.AggregateAndProof do
  @moduledoc """
  Aggregate attestation with proof of aggregator selection.
  """

  defstruct [
    :aggregator_index,
    :aggregate,
    :selection_proof
  ]
end

defmodule ExWire.Eth2.SignedAggregateAndProof do
  @moduledoc """
  Signed aggregate and proof.
  """

  defstruct [
    :message,
    :signature
  ]
end

defmodule ExWire.Eth2.SyncCommitteeMessage do
  @moduledoc """
  Sync committee member message.
  """

  defstruct [
    :slot,
    :beacon_block_root,
    :validator_index,
    :signature
  ]
end

defmodule ExWire.Eth2.SyncCommitteeContribution do
  @moduledoc """
  Aggregated sync committee signatures.
  """

  defstruct [
    :slot,
    :beacon_block_root,
    :subcommittee_index,
    :aggregation_bits,
    :signature
  ]
end

defmodule ExWire.Eth2.ContributionAndProof do
  @moduledoc """
  Sync committee contribution with proof.
  """

  defstruct [
    :aggregator_index,
    :contribution,
    :selection_proof
  ]
end

defmodule ExWire.Eth2.SignedContributionAndProof do
  @moduledoc """
  Signed contribution and proof.
  """

  defstruct [
    :message,
    :signature
  ]
end

defmodule ExWire.Eth2.BlobIdentifier do
  @moduledoc """
  Identifier for a blob sidecar.
  """

  defstruct [
    :block_root,
    :index
  ]
end
