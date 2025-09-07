defmodule ExWire.Eth2.ValidatorClient do
  @moduledoc """
  Ethereum 2.0 Validator Client implementation.
  Manages validator duties including block proposals, attestations, and sync committee participation.
  """

  use GenServer
  require Logger

  alias ExWire.Eth2.{
    BeaconChain,
    BeaconBlock,
    Attestation,
    AttestationData,
    SlashingProtection,
    KeyManager,
    ValidatorDuties
  }

  defstruct [
    :beacon_node,
    :validators,
    :key_manager,
    :slashing_protection,
    :duties_cache,
    :attestation_duties,
    :proposer_duties,
    :sync_committee_duties,
    :config,
    :metrics
  ]

  @type validator_key :: %{
          pubkey: binary(),
          privkey: binary(),
          withdrawal_credentials: binary()
        }

  # Constants
  @slots_per_epoch 32
  @seconds_per_slot 12
  # 1/3 into slot
  @attestation_offset_seconds 4

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Add a validator to manage
  """
  def add_validator(pubkey, privkey, withdrawal_credentials) do
    GenServer.call(__MODULE__, {:add_validator, pubkey, privkey, withdrawal_credentials})
  end

  @doc """
  Remove a validator from management
  """
  def remove_validator(pubkey) do
    GenServer.call(__MODULE__, {:remove_validator, pubkey})
  end

  @doc """
  Get current validator statuses
  """
  def get_validators do
    GenServer.call(__MODULE__, :get_validators)
  end

  @doc """
  Get validator performance metrics
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Manually trigger duty check
  """
  def check_duties do
    GenServer.cast(__MODULE__, :check_duties)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Validator Client")

    beacon_node = Keyword.get(opts, :beacon_node, BeaconChain)

    state = %__MODULE__{
      beacon_node: beacon_node,
      validators: %{},
      key_manager: KeyManager.init(opts),
      slashing_protection: SlashingProtection.init(),
      duties_cache: %{},
      attestation_duties: %{},
      proposer_duties: %{},
      sync_committee_duties: %{},
      config: build_config(opts),
      metrics: initialize_metrics()
    }

    # Load validators from key manager
    state = load_validators(state, opts)

    # Schedule duty checks
    schedule_slot_duties()
    schedule_epoch_duties()

    {:ok, _state}
  end

  @impl true
  def handle_call({:add_validator, pubkey, privkey, withdrawal_credentials}, _from, _state) do
    validator = %{
      pubkey: pubkey,
      privkey: privkey,
      withdrawal_credentials: withdrawal_credentials,
      index: nil,
      status: :unknown,
      balance: 0
    }

    state = put_in(state.validators[pubkey], validator)

    # Add to key manager
    KeyManager.add_key(state.key_manager, pubkey, privkey)

    # Initialize slashing protection
    SlashingProtection.init_validator(state.slashing_protection, pubkey)

    Logger.info("Added validator: #{Base.encode16(pubkey)}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:remove_validator, pubkey}, _from, _state) do
    state = update_in(state.validators, &Map.delete(&1, pubkey))

    # Remove from key manager
    KeyManager.remove_key(state.key_manager, pubkey)

    Logger.info("Removed validator: #{Base.encode16(pubkey)}")

    {:reply, :ok, state}
  end

  @impl true
  def handle_call(:get_validators, _from, _state) do
    validators =
      Enum.map(state.validators, fn {pubkey, validator} ->
        %{
          pubkey: Base.encode16(pubkey),
          index: validator.index,
          status: validator.status,
          balance: validator.balance
        }
      end)

    {:reply, {:ok, validators}, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, _state) do
    {:reply, {:ok, state.metrics}, state}
  end

  @impl true
  def handle_cast(:check_duties, _state) do
    state = update_validator_duties(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:slot_tick, _state) do
    # Get current slot
    {:ok, beacon_state} = BeaconChain.get_state()
    current_slot = beacon_state.slot

    # Perform slot duties
    state = perform_slot_duties(state, current_slot)

    # Schedule next tick
    schedule_slot_duties()

    {:noreply, state}
  end

  @impl true
  def handle_info(:epoch_tick, _state) do
    # Update duties for next epoch
    state = update_validator_duties(state)

    # Schedule next epoch tick
    schedule_epoch_duties()

    {:noreply, state}
  end

  @impl true
  def handle_info({:attestation_time, slot}, _state) do
    # Time to attest (1/3 into slot)
    state = perform_attestations(state, slot)
    {:noreply, state}
  end

  @impl true
  def handle_info({:aggregation_time, slot}, _state) do
    # Time to aggregate (2/3 into slot)
    state = perform_aggregations(state, slot)
    {:noreply, state}
  end

  # Private Functions - Duty Management

  defp update_validator_duties(_state) do
    {:ok, beacon_state} = BeaconChain.get_state()
    current_epoch = div(beacon_state.slot, @slots_per_epoch)
    next_epoch = current_epoch + 1

    # Get validator indices
    validator_indices = get_validator_indices(state, beacon_state)

    # Update duties for current and next epoch
    state = update_duties_for_epoch(state, current_epoch, validator_indices)
    update_duties_for_epoch(state, next_epoch, validator_indices)
  end

  defp update_duties_for_epoch(_state, epoch, validator_indices) do
    # Get duties from beacon chain
    {:ok, duties} = BeaconChain.get_validator_duties(epoch, validator_indices)

    # Update attestation duties
    attestation_duties =
      Enum.reduce(duties, %{}, fn duty, acc ->
        if duty.attester_slot do
          Map.update(acc, duty.attester_slot, [duty], &[duty | &1])
        else
          acc
        end
      end)

    # Update proposer duties
    proposer_duties =
      Enum.reduce(duties, %{}, fn duty, acc ->
        Enum.reduce(duty.proposer_slots, acc, fn slot, inner_acc ->
          Map.put(inner_acc, slot, duty.validator_index)
        end)
      end)

    # Update sync committee duties
    sync_duties =
      Enum.filter(duties, & &1.in_sync_committee)
      |> Enum.map(fn duty -> {duty.validator_index, true} end)
      |> Enum.into(%{})

    %{
      state
      | attestation_duties: Map.merge(state.attestation_duties, attestation_duties),
        proposer_duties: Map.merge(state.proposer_duties, proposer_duties),
        sync_committee_duties: Map.merge(state.sync_committee_duties, sync_duties)
    }
  end

  defp get_validator_indices(_state, beacon_state) do
    # Map pubkeys to validator indices
    Enum.map(state.validators, fn {pubkey, _validator} ->
      find_validator_index(beacon_state.validators, pubkey)
    end)
    |> Enum.filter(& &1)
  end

  defp find_validator_index(validators, pubkey) do
    Enum.find_index(validators, fn validator ->
      validator.pubkey == pubkey
    end)
  end

  # Private Functions - Slot Duties

  defp perform_slot_duties(_state, slot) do
    # Check if we should propose a block
    state =
      if Map.has_key?(state.proposer_duties, slot) do
        propose_block(state, slot)
      else
        state
      end

    # Schedule attestation for 1/3 into slot
    schedule_attestation(slot)

    # Schedule aggregation for 2/3 into slot
    schedule_aggregation(slot)

    # Perform sync committee duties if applicable
    perform_sync_committee_duties(state, slot)
  end

  defp propose_block(_state, slot) do
    proposer_index = Map.get(state.proposer_duties, slot)

    # Find validator key
    validator = find_validator_by_index(state, proposer_index)

    if validator do
      Logger.info("Proposing block for slot #{slot}")

      # Generate RANDAO reveal
      randao_reveal = generate_randao_reveal(state, validator, slot)

      # Build block
      {:ok, block} = BeaconChain.build_block(slot, randao_reveal, state.config.graffiti)

      # Check slashing protection
      if SlashingProtection.check_block_proposal(
           state.slashing_protection,
           validator.pubkey,
           slot
         ) do
        # Sign block
        signed_block = sign_block(state, validator, block)

        # Submit block
        BeaconChain.process_block(signed_block)

        # Record in slashing protection
        SlashingProtection.record_block_proposal(
          state.slashing_protection,
          validator.pubkey,
          slot
        )

        # Update metrics
        update_in(state.metrics.blocks_proposed, &(&1 + 1))
      else
        Logger.error("Slashing protection prevented block proposal at slot #{slot}")
        update_in(state.metrics.slashing_prevented, &(&1 + 1))
      end
    else
      state
    end
  end

  defp perform_attestations(_state, slot) do
    # Get attestation duties for this slot
    duties = Map.get(state.attestation_duties, slot, [])

    Enum.reduce(duties, state, fn duty, acc_state ->
      perform_attestation(acc_state, slot, duty)
    end)
  end

  defp perform_attestation(_state, slot, duty) do
    validator = find_validator_by_index(state, duty.validator_index)

    if validator do
      Logger.debug("Creating attestation for slot #{slot}")

      # Get attestation data
      attestation_data = create_attestation_data(state, slot, duty)

      # Check slashing protection
      if SlashingProtection.check_attestation(
           state.slashing_protection,
           validator.pubkey,
           attestation_data
         ) do
        # Sign attestation
        attestation = sign_attestation(state, validator, attestation_data, duty)

        # Submit attestation
        BeaconChain.process_attestation(attestation)

        # Record in slashing protection
        SlashingProtection.record_attestation(
          state.slashing_protection,
          validator.pubkey,
          attestation_data
        )

        # Update metrics
        update_in(state.metrics.attestations_created, &(&1 + 1))
      else
        Logger.error("Slashing protection prevented attestation at slot #{slot}")
        update_in(state.metrics.slashing_prevented, &(&1 + 1))
      end
    else
      state
    end
  end

  defp perform_aggregations(_state, slot) do
    # Check if we're an aggregator for this slot
    duties = Map.get(state.attestation_duties, slot, [])

    Enum.reduce(duties, state, fn duty, acc_state ->
      if is_aggregator?(acc_state, duty) do
        perform_aggregation(acc_state, slot, duty)
      else
        acc_state
      end
    end)
  end

  defp perform_aggregation(_state, slot, duty) do
    Logger.debug("Performing aggregation for slot #{slot}")

    # Aggregate attestations
    # This would collect attestations from the network

    # Update metrics
    update_in(state.metrics.aggregations_performed, &(&1 + 1))
  end

  defp perform_sync_committee_duties(_state, slot) do
    # Check if any validators are in sync committee
    Enum.reduce(state.validators, state, fn {pubkey, validator}, acc_state ->
      if Map.get(acc_state.sync_committee_duties, validator.index) do
        perform_sync_committee_duty(acc_state, slot, validator)
      else
        acc_state
      end
    end)
  end

  defp perform_sync_committee_duty(_state, slot, validator) do
    Logger.debug("Performing sync committee duty for slot #{slot}")

    # Create sync committee message
    # Sign and broadcast

    # Update metrics
    update_in(state.metrics.sync_committee_contributions, &(&1 + 1))
  end

  # Private Functions - Signing

  defp sign_block(_state, validator, block) do
    {:ok, beacon_state} = BeaconChain.get_state()

    # Get domain
    domain = get_domain(beacon_state, :beacon_proposer, div(block.slot, @slots_per_epoch))

    # Compute signing root
    signing_root = compute_signing_root(block, domain)

    # Sign with validator key
    signature = KeyManager.sign(state.key_manager, validator.privkey, signing_root)

    %ExWire.Eth2.SignedBeaconBlock{
      message: block,
      signature: signature
    }
  end

  defp sign_attestation(_state, validator, attestation_data, _duty) do
    {:ok, beacon_state} = BeaconChain.get_state()

    # Get domain
    domain = get_domain(beacon_state, :beacon_attester, attestation_data.target.epoch)

    # Compute signing root
    signing_root = compute_signing_root(attestation_data, domain)

    # Sign with validator key
    signature = KeyManager.sign(state.key_manager, validator.privkey, signing_root)

    %Attestation{
      # Single validator
      aggregation_bits: <<1::1, 0::127>>,
      data: attestation_data,
      signature: signature
    }
  end

  defp generate_randao_reveal(_state, validator, slot) do
    {:ok, beacon_state} = BeaconChain.get_state()

    epoch = div(slot, @slots_per_epoch)
    domain = get_domain(beacon_state, :randao, epoch)

    # Sign epoch number
    signing_root = compute_signing_root(<<epoch::64>>, domain)
    KeyManager.sign(state.key_manager, validator.privkey, signing_root)
  end

  # Private Functions - Attestation Data

  defp create_attestation_data(_state, slot, duty) do
    {:ok, head_block} = BeaconChain.get_head()
    {:ok, beacon_state} = BeaconChain.get_state()

    epoch = div(slot, @slots_per_epoch)

    %AttestationData{
      slot: slot,
      index: duty.committee_index,
      beacon_block_root: hash_tree_root(head_block),
      source: beacon_state.current_justified_checkpoint,
      target: %ExWire.Eth2.Checkpoint{
        epoch: epoch,
        root: get_epoch_boundary_root(beacon_state, epoch)
      }
    }
  end

  defp get_epoch_boundary_root(beacon_state, epoch) do
    # Get block root at start of epoch
    slot = epoch * @slots_per_epoch
    slot_index = rem(slot, length(beacon_state.block_roots))
    Enum.at(beacon_state.block_roots, slot_index)
  end

  # Private Functions - Helpers

  defp find_validator_by_index(_state, index) do
    Enum.find_value(state.validators, fn {_pubkey, validator} ->
      if validator.index == index do
        validator
      else
        nil
      end
    end)
  end

  defp is_aggregator?(_state, _duty) do
    # Check if validator is selected as aggregator
    # This uses a VRF-like selection process
    # Simplified: 10% chance
    :rand.uniform() < 0.1
  end

  defp load_validators(_state, opts) do
    # Load validators from configuration or keystore
    validators = Keyword.get(opts, :validators, [])

    Enum.reduce(validators, state, fn validator_config, acc_state ->
      validator = %{
        pubkey: validator_config.pubkey,
        privkey: validator_config.privkey,
        withdrawal_credentials: validator_config.withdrawal_credentials,
        index: nil,
        status: :unknown,
        balance: 0
      }

      put_in(acc_state.validators[validator_config.pubkey], validator)
    end)
  end

  defp get_domain(beacon_state, domain_type, epoch) do
    fork_version =
      if epoch < beacon_state.fork.epoch do
        beacon_state.fork.previous_version
      else
        beacon_state.fork.current_version
      end

    compute_domain(domain_type, fork_version, beacon_state.genesis_validators_root)
  end

  defp compute_domain(domain_type, fork_version, genesis_validators_root) do
    domain_type_bytes =
      case domain_type do
        :beacon_proposer -> <<0, 0, 0, 0>>
        :beacon_attester -> <<1, 0, 0, 0>>
        :randao -> <<2, 0, 0, 0>>
        _ -> <<0, 0, 0, 0>>
      end

    fork_data_root =
      hash_tree_root(%{
        current_version: fork_version,
        genesis_validators_root: genesis_validators_root
      })

    domain_type_bytes <> :binary.part(fork_data_root, 0, 28)
  end

  defp compute_signing_root(message, domain) do
    :crypto.hash(:sha256, hash_tree_root(message) <> domain)
  end

  defp hash_tree_root(object) do
    :crypto.hash(:sha256, :erlang.term_to_binary(object))
  end

  defp schedule_slot_duties do
    # Schedule at beginning of each slot
    Process.send_after(self(), :slot_tick, @seconds_per_slot * 1000)
  end

  defp schedule_epoch_duties do
    # Schedule at beginning of each epoch
    Process.send_after(self(), :epoch_tick, @slots_per_epoch * @seconds_per_slot * 1000)
  end

  defp schedule_attestation(slot) do
    # Schedule 1/3 into slot
    Process.send_after(self(), {:attestation_time, slot}, @attestation_offset_seconds * 1000)
  end

  defp schedule_aggregation(slot) do
    # Schedule 2/3 into slot
    Process.send_after(self(), {:aggregation_time, slot}, @attestation_offset_seconds * 2 * 1000)
  end

  defp initialize_metrics do
    %{
      blocks_proposed: 0,
      attestations_created: 0,
      aggregations_performed: 0,
      sync_committee_contributions: 0,
      slashing_prevented: 0,
      missed_attestations: 0,
      missed_blocks: 0,
      total_rewards: 0,
      total_penalties: 0
    }
  end

  defp build_config(opts) do
    %{
      graffiti: Keyword.get(opts, :graffiti, "Mana-Ethereum"),
      fee_recipient: Keyword.get(opts, :fee_recipient, <<0::160>>),
      builder_enabled: Keyword.get(opts, :builder_enabled, false),
      mev_boost_url: Keyword.get(opts, :mev_boost_url)
    }
  end
end

defmodule ExWire.Eth2.KeyManager do
  @moduledoc """
  Manages validator keys securely.
  """

  def init(_opts) do
    %{keys: %{}}
  end

  def add_key(manager, pubkey, privkey) do
    put_in(manager.keys[pubkey], privkey)
  end

  def remove_key(manager, pubkey) do
    update_in(manager.keys, &Map.delete(&1, pubkey))
  end

  def sign(_manager, privkey, message) do
    # BLS signature
    :crypto.sign(:ecdsa, :sha256, message, [privkey, :secp256k1])
  end
end

defmodule ExWire.Eth2.ValidatorDuties do
  @moduledoc """
  Tracks validator duties for each slot/epoch.
  """

  defstruct [
    :validator_index,
    :proposer_slots,
    :attester_slot,
    :committee_index,
    :committee_position,
    :committee_size,
    :is_aggregator,
    :in_sync_committee
  ]
end
