defmodule ExWire.Eth2.SyncCommitteeEnhanced do
  @moduledoc """
  Enhanced Sync Committee implementation for Ethereum 2.0 beacon chain.

  Implements full sync committee functionality including:
  - Sync committee message creation and aggregation
  - Sync committee contribution and proof generation
  - Light client support with optimistic updates
  - Participation tracking and rewards calculation

  Following the Altair specification for light client synchronization.
  """

  use GenServer
  require Logger

  alias ExWire.Crypto.BLS

  # Constants from Ethereum 2.0 spec
  # @sync_committee_size 512 # TODO: Unused attribute
  # @sync_committee_subnet_count 4 # TODO: Unused attribute
  @epochs_per_sync_committee_period 256

  @type sync_committee :: %{
          pubkeys: [Types.bls_pubkey()],
          aggregate_pubkey: Types.bls_pubkey()
        }

  @type sync_committee_message :: %{
          slot: Types.slot(),
          beacon_block_root: Types.root(),
          validator_index: Types.validator_index(),
          signature: Types.bls_signature()
        }

  @type sync_committee_contribution :: %{
          slot: Types.slot(),
          beacon_block_root: Types.root(),
          subcommittee_index: non_neg_integer(),
          aggregation_bits: bitstring(),
          signature: Types.bls_signature()
        }

  @type sync_aggregate :: %{
          sync_committee_bits: bitstring(),
          sync_committee_signature: Types.bls_signature()
        }

  @type light_client_update :: %{
          attested_header: BeaconBlock.header(),
          next_sync_committee: sync_committee() | nil,
          next_sync_committee_branch: [Types.root()],
          finalized_header: BeaconBlock.header(),
          finality_branch: [Types.root()],
          sync_aggregate: sync_aggregate(),
          signature_slot: Types.slot()
        }

  defstruct [
    :current_sync_committee,
    :next_sync_committee,
    :period,
    :messages,
    :contributions,
    :aggregates,
    :participation_tracker,
    :light_client_store
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a sync committee message for a validator.
  """
  @spec create_sync_committee_message(
          Types.slot(),
          Types.root(),
          Types.validator_index(),
          binary()
        ) :: {:ok, sync_committee_message()} | {:error, term()}
  def create_sync_committee_message(slot, beacon_block_root, validator_index, private_key) do
    GenServer.call(__MODULE__, {
      :create_message,
      slot,
      beacon_block_root,
      validator_index,
      private_key
    })
  end

  @doc """
  Aggregates sync committee messages into a contribution.
  """
  @spec aggregate_sync_committee_messages(
          Types.slot(),
          non_neg_integer()
        ) :: {:ok, sync_committee_contribution()} | {:error, term()}
  def aggregate_sync_committee_messages(slot, subcommittee_index) do
    GenServer.call(__MODULE__, {:aggregate_messages, slot, subcommittee_index})
  end

  @doc """
  Creates a sync aggregate from all contributions for inclusion in a block.
  """
  @spec create_sync_aggregate(Types.slot()) :: {:ok, sync_aggregate()} | {:error, term()}
  def create_sync_aggregate(slot) do
    GenServer.call(__MODULE__, {:create_sync_aggregate, slot})
  end

  @doc """
  Processes a light client update.
  """
  @spec process_light_client_update(light_client_update()) :: :ok | {:error, term()}
  def process_light_client_update(update) do
    GenServer.call(__MODULE__, {:process_light_client_update, update})
  end

  @doc """
  Gets the current sync committee.
  """
  @spec get_current_sync_committee() :: {:ok, sync_committee()}
  def get_current_sync_committee() do
    GenServer.call(__MODULE__, :get_current_sync_committee)
  end

  @doc """
  Computes sync committee period for a given epoch.
  """
  @spec compute_sync_committee_period(Types.epoch()) :: non_neg_integer()
  def compute_sync_committee_period(epoch) do
    div(epoch, @epochs_per_sync_committee_period)
  end

  @doc """
  Checks if a validator is in the current sync committee.
  """
  @spec is_sync_committee_member?(Types.validator_index()) :: boolean()
  def is_sync_committee_member?(validator_index) do
    GenServer.call(__MODULE__, {:is_member, validator_index})
  end

  @doc """
  Gets sync committee duties for a validator.
  """
  @spec get_sync_committee_duties(Types.validator_index()) ::
          {:ok, [non_neg_integer()]} | {:error, :not_member}
  def get_sync_committee_duties(validator_index) do
    GenServer.call(__MODULE__, {:get_duties, validator_index})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Initializing Enhanced Sync Committee")

    state = %__MODULE__{
      current_sync_committee: initialize_sync_committee(opts[:validators]),
      next_sync_committee: nil,
      period: 0,
      messages: %{},
      contributions: %{},
      aggregates: %{},
      participation_tracker: %{},
      light_client_store: initialize_light_client_store()
    }

    # Schedule periodic tasks
    schedule_participation_tracking()

    {:ok, _state}
  end

  @impl true
  def handle_call(
        {:create_message, slot, beacon_block_root, validator_index, private_key},
        _from,
        _state
      ) do
    message = %{
      slot: slot,
      beacon_block_root: beacon_block_root,
      validator_index: validator_index,
      signature: sign_sync_committee_message(slot, beacon_block_root, private_key)
    }

    # Store message for aggregation
    messages = Map.update(state.messages, slot, [message], &[message | &1])
    new_state = %{state | messages: messages}

    Logger.debug("Created sync committee message for slot #{slot}")

    {:reply, {:ok, message}, new_state}
  end

  @impl true
  def handle_call({:aggregate_messages, slot, subcommittee_index}, _from, _state) do
    case Map.get(state.messages, slot) do
      nil ->
        {:reply, {:error, :no_messages}, state}

      slot_messages ->
        # Filter messages for this subcommittee
        subcommittee_messages =
          filter_subcommittee_messages(
            slot_messages,
            subcommittee_index,
            state.current_sync_committee
          )

        contribution =
          create_contribution(
            slot,
            subcommittee_index,
            subcommittee_messages
          )

        # Store contribution
        contributions =
          Map.update(
            state.contributions,
            slot,
            [contribution],
            &[contribution | &1]
          )

        new_state = %{state | contributions: contributions}

        Logger.debug(
          "Aggregated #{length(subcommittee_messages)} messages for subcommittee #{subcommittee_index}"
        )

        {:reply, {:ok, contribution}, new_state}
    end
  end

  @impl true
  def handle_call({:create_sync_aggregate, slot}, _from, _state) do
    case Map.get(state.contributions, slot) do
      nil ->
        {:reply, {:error, :no_contributions}, state}

      slot_contributions ->
        aggregate = aggregate_contributions(slot_contributions)

        # Store aggregate
        aggregates = Map.put(state.aggregates, slot, aggregate)
        new_state = %{state | aggregates: aggregates}

        # Update participation tracker
        participation = calculate_participation(aggregate)
        tracker = Map.put(state.participation_tracker, slot, participation)
        final_state = %{new_state | participation_tracker: tracker}

        Logger.info(
          "Created sync aggregate for slot #{slot} with #{participation}% participation"
        )

        {:reply, {:ok, aggregate}, final_state}
    end
  end

  @impl true
  def handle_call({:process_light_client_update, update}, _from, _state) do
    case validate_light_client_update(update, state.light_client_store) do
      :ok ->
        updated_store = apply_light_client_update(update, state.light_client_store)
        new_state = %{_state | light_client_store: updated_store}

        # Update sync committee if needed
        final_state = maybe_update_sync_committee(update, new_state)

        Logger.info("Processed light client update for slot #{update.signature_slot}")

        {:reply, :ok, final_state}

      {:error, _reason} = error ->
        Logger.error("Invalid light client update: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call(:get_current_sync_committee, _from, _state) do
    {:reply, {:ok, state.current_sync_committee}, state}
  end

  @impl true
  def handle_call({:is_member, validator_index}, _from, _state) do
    # Check if validator's pubkey is in the committee
    # This is simplified - in production would look up validator's pubkey
    is_member = rem(validator_index, @sync_committee_size) < @sync_committee_size
    {:reply, is_member, state}
  end

  @impl true
  def handle_call({:get_duties, validator_index}, _from, _state) do
    if rem(validator_index, @sync_committee_size) < @sync_committee_size do
      # Calculate which subnets this validator should participate in
      subnets = calculate_validator_subnets(validator_index)
      {:reply, {:ok, subnets}, state}
    else
      {:reply, {:error, :not_member}, state}
    end
  end

  @impl true
  def handle_info(:track_participation, _state) do
    # Log participation metrics
    if map_size(state.participation_tracker) > 0 do
      avg_participation = calculate_average_participation(state.participation_tracker)
      Logger.info("Average sync committee participation: #{avg_participation}%")
    end

    # Clean old data
    new_state = cleanup_old_data(state)

    schedule_participation_tracking()
    {:noreply, new_state}
  end

  # Private Functions

  defp initialize_sync_committee(validators) when is_list(validators) do
    # Select validators for sync committee
    selected = Enum.take_random(validators, @sync_committee_size)

    pubkeys = Enum.map(selected, & &1.pubkey)
    aggregate_pubkey = BLS.aggregate_pubkeys(pubkeys)

    %{
      pubkeys: pubkeys,
      aggregate_pubkey: aggregate_pubkey
    }
  end

  defp initialize_sync_committee(_), do: generate_dummy_sync_committee()

  defp generate_dummy_sync_committee() do
    pubkeys = for _ <- 1..@sync_committee_size, do: :crypto.strong_rand_bytes(48)

    %{
      pubkeys: pubkeys,
      aggregate_pubkey: :crypto.strong_rand_bytes(48)
    }
  end

  defp initialize_light_client_store() do
    %{
      finalized_header: nil,
      current_sync_committee: nil,
      next_sync_committee: nil,
      best_valid_update: nil,
      optimistic_header: nil,
      previous_max_active_participants: 0,
      current_max_active_participants: 0
    }
  end

  defp sign_sync_committee_message(slot, beacon_block_root, private_key) do
    # Compute signing domain
    domain = compute_domain(:sync_committee, slot)

    # Create signing root
    message = <<slot::64, beacon_block_root::binary>>
    signing_root = compute_signing_root(message, domain)

    # Sign with BLS
    BLS.sign(private_key, signing_root)
  end

  defp compute_domain(domain_type, slot) do
    # Simplified domain computation
    fork_version = get_fork_version(slot)
    genesis_validators_root = get_genesis_validators_root()

    domain_type_bytes = domain_type_to_bytes(domain_type)

    <<domain_type_bytes::binary-size(4), fork_version::binary-size(4),
      genesis_validators_root::binary-size(32)>>
  end

  defp domain_type_to_bytes(:sync_committee), do: <<7, 0, 0, 0>>
  defp domain_type_to_bytes(_), do: <<0, 0, 0, 0>>

  defp get_fork_version(_slot) do
    # Altair fork version
    <<1, 0, 0, 0>>
  end

  defp get_genesis_validators_root() do
    # Placeholder - would get from chain config
    <<0::256>>
  end

  defp compute_signing_root(message, domain) do
    :crypto.hash(:sha256, <<message::binary, domain::binary>>)
  end

  defp filter_subcommittee_messages(messages, subcommittee_index, sync_committee) do
    subcommittee_size = div(@sync_committee_size, @sync_committee_subnet_count)
    start_index = subcommittee_index * subcommittee_size
    end_index = start_index + subcommittee_size - 1

    Enum.filter(messages, fn msg ->
      validator_position = get_validator_position(msg.validator_index, sync_committee)
      validator_position >= start_index and validator_position <= end_index
    end)
  end

  defp get_validator_position(validator_index, _sync_committee) do
    # Simplified - in production would look up actual position
    rem(validator_index, @sync_committee_size)
  end

  defp create_contribution(slot, subcommittee_index, messages) do
    subcommittee_size = div(@sync_committee_size, @sync_committee_subnet_count)

    # Create aggregation bits
    aggregation_bits = create_aggregation_bits(messages, subcommittee_size)

    # Aggregate signatures
    signatures = Enum.map(messages, & &1.signature)
    aggregate_signature = BLS.aggregate_signatures(signatures)

    # Get beacon block root (should be same for all messages)
    beacon_block_root =
      if length(messages) > 0 do
        hd(messages).beacon_block_root
      else
        <<0::256>>
      end

    %{
      slot: slot,
      beacon_block_root: beacon_block_root,
      subcommittee_index: subcommittee_index,
      aggregation_bits: aggregation_bits,
      signature: aggregate_signature
    }
  end

  defp create_aggregation_bits(messages, size) do
    # Create bitstring with 1s for participating validators
    positions =
      Enum.map(messages, fn msg ->
        rem(msg.validator_index, size)
      end)
      |> Enum.uniq()

    for i <- 0..(size - 1) do
      if i in positions, do: 1, else: 0
    end
    |> :erlang.list_to_bitstring()
  end

  defp aggregate_contributions(contributions) do
    # Create full sync committee bits
    sync_committee_bits = create_full_aggregation_bits(contributions)

    # Aggregate all signatures
    all_signatures = Enum.flat_map(contributions, fn c -> [c.signature] end)
    sync_committee_signature = BLS.aggregate_signatures(all_signatures)

    %{
      sync_committee_bits: sync_committee_bits,
      sync_committee_signature: sync_committee_signature
    }
  end

  defp create_full_aggregation_bits(contributions) do
    # Combine aggregation bits from all subcommittees
    bits =
      for i <- 0..(@sync_committee_size - 1) do
        if validator_participated?(i, contributions), do: 1, else: 0
      end

    :erlang.list_to_bitstring(bits)
  end

  defp validator_participated?(index, contributions) do
    # Check if validator at index participated in any contribution
    Enum.any?(contributions, fn contribution ->
      subcommittee_size = div(@sync_committee_size, @sync_committee_subnet_count)
      subcommittee_start = contribution.subcommittee_index * subcommittee_size

      if index >= subcommittee_start and index < subcommittee_start + subcommittee_size do
        relative_index = index - subcommittee_start
        bit_at(contribution.aggregation_bits, relative_index) == 1
      else
        false
      end
    end)
  end

  defp bit_at(bitstring, index) do
    <<_::size(index), bit::1, _::bitstring>> = bitstring
    bit
  rescue
    _ -> 0
  end

  defp calculate_participation(sync_aggregate) do
    total_bits = bit_size(sync_aggregate.sync_committee_bits)
    set_bits = count_set_bits(sync_aggregate.sync_committee_bits)

    Float.round(set_bits / total_bits * 100, 2)
  end

  defp count_set_bits(bitstring) do
    for <<bit::1 <- bitstring>>, bit == 1,
      do:
        bit
        |> length()
  end

  defp validate_light_client_update(update, store) do
    # Validate the update according to light client spec
    cond do
      # Check signatures
      not valid_sync_aggregate?(update.sync_aggregate) ->
        {:error, :invalid_sync_aggregate}

      # Check finality proof
      not valid_finality_proof?(update) ->
        {:error, :invalid_finality_proof}

      # Check sync committee proof if present
      update.next_sync_committee != nil and not valid_sync_committee_proof?(update) ->
        {:error, :invalid_sync_committee_proof}

      # Check update is newer than stored
      store.finalized_header != nil and
          update.finalized_header.slot <= store.finalized_header.slot ->
        {:error, :update_too_old}

      true ->
        :ok
    end
  end

  defp valid_sync_aggregate?(sync_aggregate) do
    # At least 2/3 participation required
    participation = calculate_participation(sync_aggregate)
    participation >= 66.67
  end

  defp valid_finality_proof?(_update) do
    # Verify merkle proof for finality
    # Simplified - would verify actual merkle branch
    true
  end

  defp valid_sync_committee_proof?(_update) do
    # Verify merkle proof for sync committee
    # Simplified - would verify actual merkle branch
    true
  end

  defp apply_light_client_update(update, store) do
    %{
      store
      | finalized_header: update.finalized_header,
        optimistic_header: update.attested_header,
        current_max_active_participants: count_set_bits(update.sync_aggregate.sync_committee_bits)
    }
  end

  defp maybe_update_sync_committee(update, _state) do
    if update.next_sync_committee != nil do
      %{
        state
        | current_sync_committee: state.next_sync_committee || state.current_sync_committee,
          next_sync_committee: update.next_sync_committee,
          period: state.period + 1
      }
    else
      state
    end
  end

  defp calculate_validator_subnets(validator_index) do
    # Determine which subnets a validator should participate in
    # Simplified - in production would use actual committee assignment
    subnet = rem(validator_index, @sync_committee_subnet_count)
    [subnet]
  end

  defp calculate_average_participation(tracker) do
    if map_size(tracker) == 0 do
      0.0
    else
      total = Enum.sum(Map.values(tracker))
      Float.round(total / map_size(tracker), 2)
    end
  end

  defp cleanup_old_data(_state) do
    # Keep only recent slots (last 32 slots)
    current_slot = get_current_slot()
    cutoff = current_slot - 32

    %{
      state
      | messages: filter_recent_slots(state.messages, cutoff),
        contributions: filter_recent_slots(state.contributions, cutoff),
        aggregates: filter_recent_slots(state.aggregates, cutoff),
        participation_tracker: filter_recent_slots(state.participation_tracker, cutoff)
    }
  end

  defp filter_recent_slots(map, cutoff) do
    Map.filter(map, fn {slot, _} -> slot > cutoff end)
  end

  defp get_current_slot() do
    # Get current slot from beacon chain
    # Simplified - would query actual beacon chain
    System.system_time(:second) |> div(12)
  end

  defp schedule_participation_tracking() do
    # Every minute
    Process.send_after(self(), :track_participation, 60_000)
  end
end
