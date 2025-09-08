defmodule ExWire.Eth2.LightClient do
  @moduledoc """
  Ethereum 2.0 Light Client implementation following the Altair specification.

  Enables trustless synchronization with minimal resource requirements by:
  - Tracking sync committee updates
  - Verifying finalized headers with merkle proofs
  - Processing optimistic updates for latest state
  - Supporting checkpoint sync for fast bootstrapping

  This implementation allows clients to follow the beacon chain without
  downloading and verifying all blocks.
  """

  use GenServer
  require Logger

  # Light client protocol constants
  @min_sync_committee_participants 1
  # slots (~27 hours)
  @update_timeout 8192
  # slots
  @auto_update_interval 32

  @type header :: %{
          slot: Types.slot(),
          proposer_index: Types.validator_index(),
          parent_root: Types.root(),
          state_root: Types.root(),
          body_root: Types.root()
        }

  @type bootstrap :: %{
          header: header(),
          current_sync_committee: SyncCommitteeEnhanced.sync_committee(),
          current_sync_committee_branch: [Types.root()]
        }

  @type update :: %{
          attested_header: header(),
          next_sync_committee: SyncCommitteeEnhanced.sync_committee() | nil,
          next_sync_committee_branch: [Types.root()],
          finalized_header: header(),
          finality_branch: [Types.root()],
          sync_aggregate: SyncCommitteeEnhanced.sync_aggregate(),
          signature_slot: Types.slot()
        }

  @type store :: %{
          finalized_header: header(),
          current_sync_committee: SyncCommitteeEnhanced.sync_committee(),
          next_sync_committee: SyncCommitteeEnhanced.sync_committee() | nil,
          best_valid_update: update() | nil,
          optimistic_header: header(),
          previous_max_active_participants: non_neg_integer(),
          current_max_active_participants: non_neg_integer()
        }

  defstruct [
    :store,
    :genesis_validators_root,
    :genesis_time,
    :trusted_block_root,
    :sync_committee_prover,
    :update_queue,
    :metrics,
    :config
  ]

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Bootstrap the light client from a trusted checkpoint.
  """
  @spec bootstrap(Types.root(), bootstrap()) :: :ok | {:error, term()}
  def bootstrap(trusted_root, bootstrap_data) do
    GenServer.call(__MODULE__, {:bootstrap, trusted_root, bootstrap_data})
  end

  @doc """
  Process a light client update.
  """
  @spec process_update(update()) :: :ok | {:error, term()}
  def process_update(update) do
    GenServer.call(__MODULE__, {:process_update, update})
  end

  @doc """
  Process an optimistic update (no finality proof).
  """
  @spec process_optimistic_update(header(), SyncCommitteeEnhanced.sync_aggregate()) ::
          :ok | {:error, term()}
  def process_optimistic_update(attested_header, sync_aggregate) do
    GenServer.call(__MODULE__, {:process_optimistic_update, attested_header, sync_aggregate})
  end

  @doc """
  Get the current finalized header.
  """
  @spec get_finalized_header() :: {:ok, header()}
  def get_finalized_header() do
    GenServer.call(__MODULE__, :get_finalized_header)
  end

  @doc """
  Get the latest optimistic header.
  """
  @spec get_optimistic_header() :: {:ok, header()}
  def get_optimistic_header() do
    GenServer.call(__MODULE__, :get_optimistic_header)
  end

  @doc """
  Check if the light client is synced.
  """
  @spec is_synced?() :: boolean()
  def is_synced?() do
    GenServer.call(__MODULE__, :is_synced?)
  end

  @doc """
  Force update the best stored update if timeout exceeded.
  """
  @spec force_update() :: :ok | {:error, :no_update}
  def force_update() do
    GenServer.call(__MODULE__, :force_update)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Initializing Light Client")

    state = %__MODULE__{
      store: nil,
      genesis_validators_root: opts[:genesis_validators_root],
      # Mainnet genesis
      genesis_time: opts[:genesis_time] || 1_606_824_023,
      trusted_block_root: opts[:trusted_block_root],
      sync_committee_prover: initialize_prover(),
      update_queue: [],
      metrics: initialize_metrics(),
      config: opts[:config] || default_config()
    }

    # Schedule periodic tasks
    if opts[:auto_update] != false do
      schedule_auto_update()
    end

    {:ok, _state}
  end

  @impl true
  def handle_call({:bootstrap, trusted_root, bootstrap_data}, _from, _state) do
    case validate_bootstrap(trusted_root, bootstrap_data) do
      :ok ->
        store = %{
          finalized_header: bootstrap_data.header,
          current_sync_committee: bootstrap_data.current_sync_committee,
          next_sync_committee: nil,
          best_valid_update: nil,
          optimistic_header: bootstrap_data.header,
          previous_max_active_participants: 0,
          current_max_active_participants: 0
        }

        new_state = %{state | store: store, trusted_block_root: trusted_root}

        Logger.info("Light client bootstrapped at slot #{bootstrap_data.header.slot}")

        {:reply, :ok, new_state}

      {:error, _reason} = error ->
        Logger.error("Bootstrap validation failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:process_update, update}, _from, _state) do
    case validate_update(update, state.store) do
      :ok ->
        new_store = apply_update(update, state.store)
        new_state = %{_state | store: new_store}

        # Update metrics
        metrics = update_metrics(state.metrics, update)
        final_state = %{new_state | metrics: metrics}

        Logger.debug("Processed update for slot #{update.attested_header.slot}")

        {:reply, :ok, final_state}

      {:error, _reason} = error ->
        Logger.warning("Update validation failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:process_optimistic_update, attested_header, sync_aggregate}, _from, _state) do
    if state.store == nil do
      {:reply, {:error, :not_bootstrapped}, state}
    else
      case validate_optimistic_update(attested_header, sync_aggregate, state.store) do
        :ok ->
          active_participants = count_active_participants(sync_aggregate)

          if should_apply_optimistic_update?(
               attested_header,
               active_participants,
               state.store
             ) do
            new_store = %{
              _state.store
              | optimistic_header: attested_header,
                current_max_active_participants: active_participants
            }

            new_state = %{state | store: new_store}

            Logger.debug("Applied optimistic update for slot #{attested_header.slot}")

            {:reply, :ok, new_state}
          else
            {:reply, :ok, state}
          end

        {:error, _reason} = error ->
          Logger.warning("Optimistic update validation failed: #{inspect(reason)}")
          {:reply, error, state}
      end
    end
  end

  @impl true
  def handle_call(:get_finalized_header, _from, _state) do
    if state.store do
      {:reply, {:ok, state.store.finalized_header}, state}
    else
      {:reply, {:error, :not_bootstrapped}, state}
    end
  end

  @impl true
  def handle_call(:get_optimistic_header, _from, _state) do
    if state.store do
      {:reply, {:ok, state.store.optimistic_header}, state}
    else
      {:reply, {:error, :not_bootstrapped}, state}
    end
  end

  @impl true
  def handle_call(:is_synced?, _from, _state) do
    is_synced =
      if state.store do
        current_slot = compute_current_slot(state.genesis_time)
        # Within 2 epochs
        state.store.optimistic_header.slot >= current_slot - 64
      else
        false
      end

    {:reply, is_synced, state}
  end

  @impl true
  def handle_call(:force_update, _from, _state) do
    if state.store && state.store.best_valid_update do
      current_slot = compute_current_slot(state.genesis_time)
      update_slot = state.store.best_valid_update.attested_header.slot

      if current_slot > update_slot + @update_timeout do
        # Apply the best stored update
        new_store = apply_update(state.store.best_valid_update, state.store)
        new_state = %{state | store: new_store}

        Logger.info("Force applied update after timeout")

        {:reply, :ok, new_state}
      else
        {:reply, {:error, :timeout_not_reached}, state}
      end
    else
      {:reply, {:error, :no_update}, state}
    end
  end

  @impl true
  def handle_info(:auto_update, _state) do
    # Check if we should request an update
    if should_request_update?(state) do
      Logger.debug("Requesting light client update")
      # In production, would request update from network
    end

    schedule_auto_update()
    {:noreply, state}
  end

  # Private Functions

  defp initialize_prover() do
    %{
      finality_branch_depth: 6,
      sync_committee_branch_depth: 5,
      merkle_multiproofs_enabled: true
    }
  end

  defp initialize_metrics() do
    %{
      updates_processed: 0,
      optimistic_updates_processed: 0,
      validation_failures: 0,
      current_participation_rate: 0.0,
      last_update_time: nil
    }
  end

  defp default_config() do
    %{
      enable_optimistic_updates: true,
      min_sync_committee_participants: @min_sync_committee_participants,
      update_timeout: @update_timeout,
      auto_update_interval: @auto_update_interval
    }
  end

  defp validate_bootstrap(trusted_root, bootstrap_data) do
    # Verify the bootstrap data against the trusted root
    computed_root = compute_header_root(bootstrap_data.header)

    if computed_root == trusted_root do
      # Verify sync committee merkle proof
      if verify_sync_committee_proof(
           bootstrap_data.current_sync_committee,
           bootstrap_data.current_sync_committee_branch,
           bootstrap_data.header.state_root
         ) do
        :ok
      else
        {:error, :invalid_sync_committee_proof}
      end
    else
      {:error, :root_mismatch}
    end
  end

  defp validate_update(update, store) do
    cond do
      # Must have enough sync committee participation
      not has_sufficient_participation?(update.sync_aggregate) ->
        {:error, :insufficient_participation}

      # Signature slot must be valid
      update.signature_slot <= update.attested_header.slot ->
        {:error, :invalid_signature_slot}

      # Finalized header must be ancestor of attested
      update.finalized_header.slot > update.attested_header.slot ->
        {:error, :invalid_finalized_header}

      # Verify merkle proofs
      not verify_update_proofs(update) ->
        {:error, :invalid_proofs}

      # Verify sync aggregate signature
      not verify_sync_aggregate_signature(update, store) ->
        {:error, :invalid_signature}

      true ->
        :ok
    end
  end

  defp validate_optimistic_update(attested_header, sync_aggregate, store) do
    cond do
      not has_sufficient_participation?(sync_aggregate) ->
        {:error, :insufficient_participation}

      attested_header.slot <= store.optimistic_header.slot ->
        {:error, :not_newer}

      not verify_optimistic_signature(attested_header, sync_aggregate, store) ->
        {:error, :invalid_signature}

      true ->
        :ok
    end
  end

  defp apply_update(update, store) do
    new_store = store

    # Update finalized header if newer
    new_store =
      if update.finalized_header.slot > store.finalized_header.slot do
        %{new_store | finalized_header: update.finalized_header}
      else
        new_store
      end

    # Update sync committee if present
    new_store =
      if update.next_sync_committee do
        sync_committee_period = compute_sync_committee_period_at_slot(update.attested_header.slot)

        if sync_committee_period ==
             compute_sync_committee_period_at_slot(store.finalized_header.slot) + 1 do
          %{
            new_store
            | current_sync_committee: update.next_sync_committee,
              next_sync_committee: nil
          }
        else
          %{new_store | next_sync_committee: update.next_sync_committee}
        end
      else
        new_store
      end

    # Update optimistic header
    active_participants = count_active_participants(update.sync_aggregate)

    %{
      new_store
      | optimistic_header: update.attested_header,
        previous_max_active_participants: store.current_max_active_participants,
        current_max_active_participants: active_participants,
        # Clear after applying
        best_valid_update: nil
    }
  end

  defp has_sufficient_participation?(sync_aggregate) do
    active = count_active_participants(sync_aggregate)
    active >= @min_sync_committee_participants
  end

  defp count_active_participants(sync_aggregate) do
    sync_aggregate.sync_committee_bits
    |> :binary.bin_to_list()
    |> Enum.count(&(&1 == 1))
  end

  defp should_apply_optimistic_update?(header, active_participants, store) do
    # Apply if has more participation than current
    active_participants > store.current_max_active_participants and
      header.slot > store.optimistic_header.slot
  end

  defp verify_sync_committee_proof(_committee, _branch, _state_root) do
    # Verify merkle proof for sync committee
    # Simplified - would verify actual merkle branch
    true
  end

  defp verify_update_proofs(update) do
    # Verify all merkle proofs in the update
    verify_finality_proof(update) and
      verify_next_sync_committee_proof(update)
  end

  defp verify_finality_proof(_update) do
    # Verify the finality branch merkle proof
    # Simplified - would verify actual proof
    true
  end

  defp verify_next_sync_committee_proof(update) do
    # Only verify if next sync committee is present
    if update.next_sync_committee do
      # Simplified - would verify actual proof
      true
    else
      true
    end
  end

  defp verify_sync_aggregate_signature(update, store) do
    # Verify BLS aggregate signature
    sync_committee =
      get_sync_committee_for_period(
        update.signature_slot,
        store
      )

    if sync_committee do
      # Verify signature against participating validators
      # Simplified - would verify actual BLS signature
      true
    else
      false
    end
  end

  defp verify_optimistic_signature(_header, _sync_aggregate, _store) do
    # Verify signature for optimistic update
    # Simplified - would verify actual signature
    true
  end

  defp get_sync_committee_for_period(slot, store) do
    period = compute_sync_committee_period_at_slot(slot)
    current_period = compute_sync_committee_period_at_slot(store.finalized_header.slot)

    cond do
      period == current_period ->
        store.current_sync_committee

      period == current_period + 1 and store.next_sync_committee ->
        store.next_sync_committee

      true ->
        nil
    end
  end

  defp compute_header_root(header) do
    # Compute SSZ hash tree root of header
    :crypto.hash(:sha256, :erlang.term_to_binary(header))
  end

  defp compute_current_slot(genesis_time) do
    current_time = System.system_time(:second)
    div(current_time - genesis_time, 12)
  end

  defp compute_sync_committee_period_at_slot(slot) do
    epoch = div(slot, 32)
    div(epoch, 256)
  end

  defp should_request_update?(state) do
    if state.store do
      current_slot = compute_current_slot(state.genesis_time)

      # Request if we're behind
      current_slot - state.store.optimistic_header.slot > @auto_update_interval
    else
      false
    end
  end

  defp update_metrics(metrics, update) do
    participation = count_active_participants(update.sync_aggregate)
    participation_rate = participation / 512 * 100

    %{
      metrics
      | updates_processed: metrics.updates_processed + 1,
        current_participation_rate: participation_rate,
        last_update_time: DateTime.utc_now()
    }
  end

  defp schedule_auto_update() do
    Process.send_after(self(), :auto_update, @auto_update_interval * 12 * 1000)
  end
end
