defmodule ExWire.Eth2.StateStore do
  @moduledoc """
  Efficient state storage with differential updates and tiered storage.
  Implements copy-on-write semantics with structural sharing for memory efficiency.
  """

  use GenServer
  require Logger

  defstruct [
    # Recent states in memory
    :hot_states,
    # Recent epoch in ETS
    :warm_states,
    # Historical states in DB
    :cold_storage,
    # State root index
    :state_roots,
    # Checkpoint states
    :checkpoints,
    :metrics,
    :config
  ]

  # Configuration
  # Keep last 2 epochs in memory
  @hot_slots 64
  # Keep last ~10 hours in ETS
  @warm_slots 2048
  # Store full state every 256 slots
  @checkpoint_interval 256
  # Prune every 2 hours
  @prune_interval 7200

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Store a beacon state efficiently
  """
  def store_state(_state, slot, state_root) do
    GenServer.call(__MODULE__, {:store_state, state, slot, state_root})
  end

  @doc """
  Retrieve a beacon state by slot
  """
  def get_state(slot) do
    GenServer.call(__MODULE__, {:get_state, slot})
  end

  @doc """
  Get state by state root
  """
  def get_state_by_root(state_root) do
    GenServer.call(__MODULE__, {:get_state_by_root, state_root})
  end

  @doc """
  Prune old states
  """
  def prune(finalized_slot) do
    GenServer.cast(__MODULE__, {:prune, finalized_slot})
  end

  @doc """
  Get storage metrics
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting StateStore with differential storage")

    # Create ETS tables
    :ets.new(:warm_states, [:set, :public, :named_table, {:read_concurrency, true}])
    :ets.new(:state_roots, [:set, :public, :named_table])
    :ets.new(:state_deltas, [:ordered_set, :public, :named_table])

    state = %__MODULE__{
      hot_states: %{},
      warm_states: :warm_states,
      cold_storage: init_cold_storage(opts),
      state_roots: :state_roots,
      checkpoints: %{},
      metrics: initialize_metrics(),
      config: build_config(opts)
    }

    # Schedule periodic pruning
    schedule_pruning()

    {:ok, _state}
  end

  @impl true
  def handle_call({:store_state, beacon_state, slot, state_root}, _from, _state) do
    # Determine storage tier
    current_slot = beacon_state.slot

    state =
      cond do
        # Hot storage - keep full state in memory
        slot > current_slot - @hot_slots ->
          store_hot(state, beacon_state, slot, state_root)

        # Warm storage - store in ETS with compression
        slot > current_slot - @warm_slots ->
          store_warm(state, beacon_state, slot, state_root)

        # Cold storage - store to disk
        true ->
          store_cold(state, beacon_state, slot, state_root)
      end

    # Store checkpoint if needed
    state =
      if rem(slot, @checkpoint_interval) == 0 do
        store_checkpoint(state, beacon_state, slot, state_root)
      else
        state
      end

    # Update metrics
    state = update_metrics(state, :states_stored)

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:get_state, slot}, _from, _state) do
    result = retrieve_state(state, slot)

    state =
      case result do
        {:ok, _} -> update_metrics(state, :states_retrieved)
        _ -> update_metrics(state, :retrieval_misses)
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call({:get_state_by_root, state_root}, _from, _state) do
    # Look up slot by state root
    case :ets.lookup(:state_roots, state_root) do
      [{^state_root, slot}] ->
        result = retrieve_state(state, slot)
        {:reply, result, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:get_metrics, _from, _state) do
    metrics =
      Map.merge(state.metrics, %{
        hot_states_count: map_size(state.hot_states),
        warm_states_count: :ets.info(:warm_states, :size),
        checkpoint_count: map_size(state.checkpoints),
        memory_usage: estimate_memory_usage(state)
      })

    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_cast({:prune, finalized_slot}, _state) do
    Logger.info("Pruning states before slot #{finalized_slot}")

    # Prune hot states
    hot_states =
      Map.filter(state.hot_states, fn {slot, _} ->
        slot >= finalized_slot
      end)

    # Prune warm states
    :ets.select_delete(:warm_states, [
      {{:"$1", :_}, [{:<, :"$1", finalized_slot}], [true]}
    ])

    # Prune state roots
    :ets.select_delete(:state_roots, [
      {{:_, :"$1"}, [{:<, :"$1", finalized_slot}], [true]}
    ])

    # Keep checkpoints for finalized slots
    checkpoints =
      Map.filter(state.checkpoints, fn {slot, _} ->
        slot >= finalized_slot || rem(slot, @checkpoint_interval * 8) == 0
      end)

    state = %{state | hot_states: hot_states, checkpoints: checkpoints}

    {:noreply, state}
  end

  @impl true
  def handle_info(:scheduled_pruning, _state) do
    # Get finalized slot (simplified - should get from beacon chain)
    current_slot = get_current_slot()
    finalized_slot = max(0, current_slot - @warm_slots * 2)

    handle_cast({:prune, finalized_slot}, state)

    schedule_pruning()
    {:noreply, state}
  end

  # Private Functions - Storage Operations

  defp store_hot(_state, beacon_state, slot, state_root) do
    # Store full state in memory
    hot_states = Map.put(state.hot_states, slot, beacon_state)

    # Index by state root
    :ets.insert(:state_roots, {state_root, slot})

    # Limit hot storage size
    hot_states =
      if map_size(hot_states) > @hot_slots do
        oldest_slot = Enum.min(Map.keys(hot_states))

        # Move to warm storage
        case Map.get(hot_states, oldest_slot) do
          nil ->
            hot_states

          old_state ->
            store_warm(state, old_state, oldest_slot, compute_state_root(old_state))
            Map.delete(hot_states, oldest_slot)
        end
      else
        hot_states
      end

    %{_state | hot_states: hot_states}
  end

  defp store_warm(_state, beacon_state, slot, state_root) do
    # Compress state before storing in ETS
    compressed = compress_state(beacon_state)

    :ets.insert(:warm_states, {slot, compressed})
    :ets.insert(:state_roots, {state_root, slot})

    # Store delta from previous state if not a checkpoint
    if rem(slot, @checkpoint_interval) != 0 do
      store_delta(state, beacon_state, slot)
    end

    state
  end

  defp store_cold(_state, beacon_state, slot, state_root) do
    # Store to persistent storage
    case state.cold_storage do
      {:rocksdb, db} ->
        key = "state:#{slot}"
        value = :erlang.term_to_binary(beacon_state, [:compressed])
        :rocksdb.put(db, key, value, [])

      {:s3, bucket} ->
        # Store to S3
        key = "states/#{div(slot, 1000)}/#{slot}"
        upload_to_s3(bucket, key, beacon_state)

      _ ->
        :ok
    end

    :ets.insert(:state_roots, {state_root, slot})
    state
  end

  defp store_checkpoint(_state, beacon_state, slot, state_root) do
    Logger.debug("Storing checkpoint at slot #{slot}")

    checkpoint = %{
      state: beacon_state,
      state_root: state_root,
      slot: slot,
      epoch: div(slot, 32)
    }

    %{state | checkpoints: Map.put(state.checkpoints, slot, checkpoint)}
  end

  defp store_delta(_state, beacon_state, slot) do
    # Find previous state
    prev_slot = slot - 1

    case retrieve_state(state, prev_slot) do
      {:ok, prev_state} ->
        delta = compute_delta(prev_state, beacon_state)
        :ets.insert(:state_deltas, {slot, delta})

      _ ->
        # No previous state, store full state as delta
        :ets.insert(:state_deltas, {slot, {:full, beacon_state}})
    end

    state
  end

  # Private Functions - Retrieval

  defp retrieve_state(_state, slot) do
    # Check hot storage first
    case Map.get(state.hot_states, slot) do
      nil ->
        # Check warm storage
        case :ets.lookup(:warm_states, slot) do
          [{^slot, compressed}] ->
            {:ok, decompress_state(compressed)}

          [] ->
            # Check checkpoints
            case Map.get(state.checkpoints, slot) do
              nil ->
                # Try to reconstruct from deltas
                reconstruct_from_deltas(state, slot)

              checkpoint ->
                {:ok, checkpoint._state}
            end
        end

      beacon_state ->
        {:ok, beacon_state}
    end
  end

  defp reconstruct_from_deltas(_state, target_slot) do
    # Find nearest checkpoint
    checkpoint_slot = div(target_slot, @checkpoint_interval) * @checkpoint_interval

    case Map.get(state.checkpoints, checkpoint_slot) do
      nil ->
        retrieve_from_cold_storage(state, target_slot)

      checkpoint ->
        # Apply deltas from checkpoint to target
        base_state = checkpoint._state

        deltas =
          :ets.select(:state_deltas, [
            {{:"$1", :"$2"},
             [{:andalso, {:>, :"$1", checkpoint_slot}, {:"=<", :"$1", target_slot}}],
             [{{:"$1", :"$2"}}]}
          ])
          |> Enum.sort_by(&elem(&1, 0))

        final_state =
          Enum.reduce(deltas, base_state, fn {_slot, delta}, acc ->
            apply_delta(acc, delta)
          end)

        {:ok, final_state}
    end
  end

  defp retrieve_from_cold_storage(_state, slot) do
    case state.cold_storage do
      {:rocksdb, db} ->
        key = "state:#{slot}"

        case :rocksdb.get(db, key, []) do
          {:ok, value} ->
            {:ok, :erlang.binary_to_term(value)}

          :not_found ->
            {:error, :not_found}
        end

      _ ->
        {:error, :not_found}
    end
  end

  # Private Functions - Delta Operations

  defp compute_delta(old_state, new_state) do
    # Compute minimal delta between states
    delta = %{}

    # Only store changed fields
    delta =
      if old_state.slot != new_state.slot do
        Map.put(delta, :slot, new_state.slot)
      else
        delta
      end

    # Check validator changes
    delta =
      if old_state.validators != new_state.validators do
        validator_delta = compute_validator_delta(old_state.validators, new_state.validators)
        Map.put(delta, :validators, validator_delta)
      else
        delta
      end

    # Check balance changes
    delta =
      if old_state.balances != new_state.balances do
        balance_delta = compute_balance_delta(old_state.balances, new_state.balances)
        Map.put(delta, :balances, balance_delta)
      else
        delta
      end

    # Add other changed fields
    delta
  end

  defp apply_delta(_state, {:full, new_state}) do
    new_state
  end

  defp apply_delta(_state, delta) when is_map(delta) do
    Enum.reduce(delta, state, fn {field, change}, acc ->
      apply_field_delta(acc, field, change)
    end)
  end

  defp apply_field_delta(_state, :slot, new_slot) do
    %{state | slot: new_slot}
  end

  defp apply_field_delta(_state, :validators, validator_delta) do
    new_validators = apply_validator_delta(state.validators, validator_delta)
    %{state | validators: new_validators}
  end

  defp apply_field_delta(_state, :balances, balance_delta) do
    new_balances = apply_balance_delta(state.balances, balance_delta)
    %{state | balances: new_balances}
  end

  defp apply_field_delta(_state, field, value) do
    Map.put(state, field, value)
  end

  defp compute_validator_delta(old_validators, new_validators) do
    # Track only changed validators
    changes =
      Enum.with_index(new_validators)
      |> Enum.filter(fn {validator, index} ->
        Enum.at(old_validators, index) != validator
      end)
      |> Enum.map(fn {validator, index} ->
        {index, validator}
      end)
      |> Enum.into(%{})

    %{
      changes: changes,
      new_count: length(new_validators)
    }
  end

  defp apply_validator_delta(validators, %{changes: changes, new_count: new_count}) do
    # Resize if needed
    validators =
      if length(validators) < new_count do
        validators ++ List.duplicate(nil, new_count - length(validators))
      else
        Enum.take(validators, new_count)
      end

    # Apply changes
    Enum.reduce(changes, validators, fn {index, validator}, acc ->
      List.replace_at(acc, index, validator)
    end)
  end

  defp compute_balance_delta(old_balances, new_balances) do
    # Store only changed balances
    Enum.with_index(new_balances)
    |> Enum.filter(fn {balance, index} ->
      Enum.at(old_balances, index, 0) != balance
    end)
    |> Enum.map(fn {balance, index} ->
      {index, balance}
    end)
    |> Enum.into(%{})
  end

  defp apply_balance_delta(balances, delta) do
    Enum.reduce(delta, balances, fn {index, balance}, acc ->
      List.replace_at(acc, index, balance)
    end)
  end

  # Private Functions - Compression

  defp compress_state(beacon_state) do
    # Use zlib compression
    state_binary = :erlang.term_to_binary(beacon_state)
    :zlib.compress(state_binary)
  end

  defp decompress_state(compressed) do
    state_binary = :zlib.uncompress(compressed)
    :erlang.binary_to_term(state_binary)
  end

  # Private Functions - Helpers

  defp init_cold_storage(opts) do
    case Keyword.get(opts, :cold_storage, :rocksdb) do
      :rocksdb ->
        path = Keyword.get(opts, :db_path, "data/beacon_states")
        File.mkdir_p!(path)
        {:ok, db} = :rocksdb.open(path, create_if_missing: true)
        {:rocksdb, db}

      :s3 ->
        bucket = Keyword.get(opts, :s3_bucket, "mana-beacon-states")
        {:s3, bucket}

      _ ->
        nil
    end
  end

  defp compute_state_root(beacon_state) do
    # Simplified - should use SSZ
    :crypto.hash(:sha256, :erlang.term_to_binary(beacon_state))
  end

  defp upload_to_s3(_bucket, _key, _data) do
    # S3 upload implementation
    :ok
  end

  defp get_current_slot do
    # Get from beacon chain
    System.system_time(:second) |> div(12)
  end

  defp estimate_memory_usage(_state) do
    # ~50MB per state
    hot_size = map_size(state.hot_states) * 50_000_000

    warm_size = :ets.info(:warm_states, :memory) * :erlang.system_info(:wordsize)

    checkpoint_size = map_size(state.checkpoints) * 50_000_000

    hot_size + warm_size + checkpoint_size
  end

  defp initialize_metrics do
    %{
      states_stored: 0,
      states_retrieved: 0,
      retrieval_misses: 0,
      compressions: 0,
      decompressions: 0,
      delta_applications: 0
    }
  end

  defp update_metrics(_state, metric, count \\ 1) do
    update_in(state.metrics[metric], &(&1 + count))
  end

  defp build_config(opts) do
    %{
      hot_slots: Keyword.get(opts, :hot_slots, @hot_slots),
      warm_slots: Keyword.get(opts, :warm_slots, @warm_slots),
      checkpoint_interval: Keyword.get(opts, :checkpoint_interval, @checkpoint_interval),
      compression_enabled: Keyword.get(opts, :compression_enabled, true)
    }
  end

  defp schedule_pruning do
    Process.send_after(self(), :scheduled_pruning, @prune_interval * 1000)
  end
end
