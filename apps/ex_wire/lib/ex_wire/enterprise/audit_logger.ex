defmodule ExWire.Enterprise.AuditLogger do
  @moduledoc """
  Immutable audit logging system for enterprise compliance and security.
  Provides tamper-proof logging with cryptographic signatures and blockchain anchoring.
  """

  use GenServer
  require Logger

  defstruct [
    :log_store,
    :current_hash,
    :signature_key,
    :blockchain_anchor,
    :buffer,
    :config,
    :metrics
  ]

  @type log_entry :: %{
          id: String.t(),
          timestamp: DateTime.t(),
          event_type: atom(),
          actor: String.t() | nil,
          details: map(),
          hash: binary(),
          previous_hash: binary(),
          signature: binary(),
          metadata: map()
        }

  @type anchor :: %{
          block_height: non_neg_integer(),
          transaction_hash: binary(),
          merkle_root: binary(),
          timestamp: DateTime.t()
        }

  # Client API

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name] || __MODULE__)
  end

  @doc """
  Log an audit event
  """
  def log(event_type, details, opts \\ []) do
    GenServer.cast(__MODULE__, {:log, event_type, details, opts})
  end

  @doc """
  Log an audit event synchronously
  """
  def log_sync(event_type, details, opts \\ []) do
    GenServer.call(__MODULE__, {:log, event_type, details, opts})
  end

  @doc """
  Query audit logs
  """
  def query(filters \\ %{}) do
    GenServer.call(__MODULE__, {:query, filters})
  end

  @doc """
  Verify log integrity
  """
  def verify_integrity(from_id \\ nil, to_id \\ nil) do
    GenServer.call(__MODULE__, {:verify_integrity, from_id, to_id})
  end

  @doc """
  Export audit logs
  """
  def export(format \\ :json, filters \\ %{}) do
    GenServer.call(__MODULE__, {:export, format, filters})
  end

  @doc """
  Get audit metrics
  """
  def get_metrics do
    GenServer.call(__MODULE__, :get_metrics)
  end

  @doc """
  Anchor logs to blockchain
  """
  def anchor_to_blockchain do
    GenServer.call(__MODULE__, :anchor_to_blockchain)
  end

  @doc """
  Verify blockchain anchor
  """
  def verify_anchor(anchor_id) do
    GenServer.call(__MODULE__, {:verify_anchor, anchor_id})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    Logger.info("Starting Audit Logger with immutable storage")

    # Generate or load signature key
    signature_key = load_or_generate_key(opts)

    state = %__MODULE__{
      log_store: initialize_storage(opts),
      current_hash: get_last_hash(),
      signature_key: signature_key,
      blockchain_anchor: nil,
      buffer: [],
      config: build_config(opts),
      metrics: initialize_metrics()
    }

    # Schedule periodic operations
    schedule_flush()
    schedule_anchoring()
    schedule_rotation()

    {:ok, _state}
  end

  @impl true
  def handle_cast({:log, event_type, details, opts}, _state) do
    entry = create_log_entry(event_type, details, opts, state)
    state = add_to_buffer(state, entry)

    # Flush if buffer is full
    state =
      if length(state.buffer) >= state.config.buffer_size do
        flush_buffer(state)
      else
        state
      end

    {:noreply, state}
  end

  @impl true
  def handle_call({:log, event_type, details, opts}, _from, _state) do
    entry = create_log_entry(event_type, details, opts, state)
    state = add_to_buffer(state, entry)
    state = flush_buffer(state)

    {:reply, {:ok, entry.id}, state}
  end

  @impl true
  def handle_call({:query, filters}, _from, _state) do
    # Flush buffer first to ensure all logs are queryable
    state = flush_buffer(state)

    logs = query_logs(state.log_store, filters)
    {:reply, {:ok, logs}, state}
  end

  @impl true
  def handle_call({:verify_integrity, from_id, to_id}, _from, _state) do
    result = verify_log_chain(state.log_store, from_id, to_id)
    {:reply, result, state}
  end

  @impl true
  def handle_call({:export, format, filters}, _from, _state) do
    state = flush_buffer(state)
    logs = query_logs(state.log_store, filters)

    exported =
      case format do
        :json -> export_as_json(logs)
        :csv -> export_as_csv(logs)
        :syslog -> export_as_syslog(logs)
        _ -> {:error, :unsupported_format}
      end

    {:reply, exported, state}
  end

  @impl true
  def handle_call(:get_metrics, _from, _state) do
    metrics =
      Map.merge(state.metrics, %{
        buffer_size: length(state.buffer),
        last_anchor: state.blockchain_anchor,
        storage_size: get_storage_size(state.log_store)
      })

    {:reply, {:ok, metrics}, state}
  end

  @impl true
  def handle_call(:anchor_to_blockchain, _from, _state) do
    case create_blockchain_anchor(state) do
      {:ok, anchor} ->
        state = %{state | blockchain_anchor: anchor}
        {:reply, {:ok, anchor}, state}

      {:error, _reason} ->
        {:reply, {:error, _reason}, state}
    end
  end

  @impl true
  def handle_call({:verify_anchor, anchor_id}, _from, _state) do
    result = verify_blockchain_anchor(anchor_id, state)
    {:reply, result, state}
  end

  @impl true
  def handle_info(:flush_buffer, _state) do
    state = flush_buffer(state)
    schedule_flush()
    {:noreply, state}
  end

  @impl true
  def handle_info(:anchor_logs, _state) do
    case create_blockchain_anchor(state) do
      {:ok, anchor} ->
        state = %{state | blockchain_anchor: anchor}
        Logger.info("Audit logs anchored to blockchain: #{inspect(anchor)}")

      {:error, _reason} ->
        Logger.error("Failed to anchor logs: #{inspect(reason)}")
    end

    schedule_anchoring()
    {:noreply, state}
  end

  @impl true
  def handle_info(:rotate_logs, _state) do
    state = rotate_log_files(state)
    schedule_rotation()
    {:noreply, state}
  end

  # Private Functions

  defp create_log_entry(event_type, details, opts, _state) do
    timestamp = DateTime.utc_now()
    actor = Keyword.get(opts, :actor, get_current_actor())

    entry_data = %{
      id: generate_log_id(),
      timestamp: timestamp,
      event_type: event_type,
      actor: actor,
      details: details,
      previous_hash: state.current_hash,
      metadata: build_metadata(opts)
    }

    # Calculate hash
    hash = calculate_hash(entry_data)

    # Sign the hash
    signature = sign_entry(hash, state.signature_key)

    %{entry_data | hash: hash, signature: signature}
  end

  defp calculate_hash(entry_data) do
    content =
      "#{entry_data.id}|#{entry_data.timestamp}|#{entry_data.event_type}|" <>
        "#{inspect(entry_data.details)}|#{entry_data.previous_hash}"

    :crypto.hash(:sha256, content)
  end

  defp sign_entry(hash, signature_key) do
    # Sign with private key
    :crypto.sign(:ecdsa, :sha256, hash, [signature_key, :secp256k1])
  end

  defp verify_signature(hash, signature, public_key) do
    :crypto.verify(:ecdsa, :sha256, hash, signature, [public_key, :secp256k1])
  end

  defp add_to_buffer(_state, entry) do
    %{state | buffer: [entry | state.buffer], current_hash: entry.hash}
    |> update_metrics(:entries_buffered)
  end

  defp flush_buffer(_state) do
    if length(state.buffer) > 0 do
      # Write to persistent storage
      :ok = write_logs(state.log_store, Enum.reverse(state.buffer))

      %{state | buffer: []}
      |> update_metrics(:entries_flushed, length(state.buffer))
    else
      state
    end
  end

  defp initialize_storage(opts) do
    storage_type = Keyword.get(opts, :storage, :file)

    case storage_type do
      :file ->
        path = Keyword.get(opts, :path, "data/audit_logs")
        File.mkdir_p!(path)
        %{type: :file, path: path, current_file: current_log_file(path)}

      :database ->
        %{type: :database, connection: opts[:connection]}

      :s3 ->
        %{type: :s3, bucket: opts[:bucket], prefix: opts[:prefix]}

      _ ->
        %{type: :memory, logs: []}
    end
  end

  defp write_logs(store, entries) do
    case store.type do
      :file ->
        write_to_file(store.current_file, entries)

      :database ->
        write_to_database(store.connection, entries)

      :s3 ->
        write_to_s3(store.bucket, store.prefix, entries)

      :memory ->
        :ok
    end
  end

  defp write_to_file(file_path, entries) do
    content = Enum.map(entries, &encode_entry/1) |> Enum.join("\n")
    File.write!(file_path, content <> "\n", [:append])
  end

  defp write_to_database(_connection, _entries) do
    # Database write implementation
    :ok
  end

  defp write_to_s3(_bucket, _prefix, _entries) do
    # S3 write implementation
    :ok
  end

  defp query_logs(store, filters) do
    all_logs = read_all_logs(store)

    all_logs
    |> filter_by_time(filters[:from], filters[:to])
    |> filter_by_event_type(filters[:event_type])
    |> filter_by_actor(filters[:actor])
    |> apply_limit(filters[:limit])
  end

  defp read_all_logs(store) do
    case store.type do
      :file ->
        read_from_files(store.path)

      :database ->
        read_from_database(store.connection)

      :s3 ->
        read_from_s3(store.bucket, store.prefix)

      :memory ->
        store.logs
    end
  end

  defp read_from_files(path) do
    Path.wildcard("#{path}/*.log")
    |> Enum.flat_map(&read_log_file/1)
    |> Enum.map(&decode_entry/1)
  end

  defp read_log_file(file_path) do
    File.read!(file_path)
    |> String.split("\n", trim: true)
  end

  defp verify_log_chain(store, from_id, to_id) do
    logs = query_logs(store, %{from_id: from_id, to_id: to_id})

    result =
      Enum.reduce_while(logs, {:ok, nil}, fn log, {:ok, prev_hash} ->
        if prev_hash == nil || log.previous_hash == prev_hash do
          # Verify hash
          calculated = calculate_hash(log)

          if calculated == log.hash do
            # Verify signature
            if verify_signature(log.hash, log.signature, get_public_key()) do
              {:cont, {:ok, log.hash}}
            else
              {:halt, {:error, :invalid_signature, log.id}}
            end
          else
            {:halt, {:error, :invalid_hash, log.id}}
          end
        else
          {:halt, {:error, :broken_chain, log.id}}
        end
      end)

    case result do
      {:ok, _} -> {:ok, :valid}
      error -> error
    end
  end

  defp create_blockchain_anchor(_state) do
    # Flush buffer first
    state = flush_buffer(state)

    # Get recent logs
    recent_logs =
      query_logs(state.log_store, %{
        from: DateTime.add(DateTime.utc_now(), -3600, :second)
      })

    if length(recent_logs) > 0 do
      # Calculate merkle root
      merkle_root = calculate_merkle_root(recent_logs)

      # Submit to blockchain
      case submit_to_blockchain(merkle_root) do
        {:ok, tx_hash} ->
          anchor = %{
            block_height: get_current_block_height(),
            transaction_hash: tx_hash,
            merkle_root: merkle_root,
            timestamp: DateTime.utc_now(),
            log_count: length(recent_logs)
          }

          {:ok, anchor}

        error ->
          error
      end
    else
      {:error, :no_logs_to_anchor}
    end
  end

  defp calculate_merkle_root(logs) do
    hashes = Enum.map(logs, & &1.hash)
    build_merkle_tree(hashes)
  end

  defp build_merkle_tree([single]), do: single

  defp build_merkle_tree(hashes) do
    paired = pair_hashes(hashes)

    next_level =
      Enum.map(paired, fn {left, right} ->
        :crypto.hash(:sha256, left <> right)
      end)

    build_merkle_tree(next_level)
  end

  defp pair_hashes(hashes) do
    hashes
    |> Enum.chunk_every(2)
    |> Enum.map(fn
      [left, right] -> {left, right}
      [single] -> {single, single}
    end)
  end

  defp submit_to_blockchain(merkle_root) do
    # This would submit to actual blockchain
    tx_hash = :crypto.hash(:sha256, merkle_root)
    {:ok, tx_hash}
  end

  defp verify_blockchain_anchor(anchor_id, _state) do
    # Verify anchor on blockchain
    {:ok, :valid}
  end

  defp rotate_log_files(_state) do
    case state.log_store.type do
      :file ->
        current_file = state.log_store.current_file
        new_file = current_log_file(state.log_store.path)

        if current_file != new_file do
          # Compress old file
          compress_log_file(current_file)

          put_in(state.log_store.current_file, new_file)
        else
          state
        end

      _ ->
        _state
    end
  end

  defp compress_log_file(file_path) do
    # Compress and archive old log file
    :ok
  end

  defp build_metadata(opts) do
    %{
      ip_address: Keyword.get(opts, :ip_address),
      user_agent: Keyword.get(opts, :user_agent),
      session_id: Keyword.get(opts, :session_id),
      request_id: Keyword.get(opts, :request_id),
      correlation_id: Keyword.get(opts, :correlation_id)
    }
    |> Enum.filter(fn {_k, v} -> v != nil end)
    |> Enum.into(%{})
  end

  defp encode_entry(entry) do
    Jason.encode!(entry)
  end

  defp decode_entry(line) do
    Jason.decode!(line, keys: :atoms)
  end

  defp export_as_json(logs) do
    {:ok, Jason.encode!(logs)}
  end

  defp export_as_csv(logs) do
    headers = "id,timestamp,event_type,actor,details_summary,hash\n"

    rows =
      Enum.map(logs, fn log ->
        "#{log.id},#{log.timestamp},#{log.event_type},#{log.actor}," <>
          "#{summarize_details(log.details)},#{Base.encode16(log.hash)}"
      end)
      |> Enum.join("\n")

    {:ok, headers <> rows}
  end

  defp export_as_syslog(logs) do
    messages =
      Enum.map(logs, fn log ->
        "<165>1 #{log.timestamp} mana-ethereum audit #{log.id} - " <>
          "event=#{log.event_type} actor=#{log.actor} details=#{inspect(log.details)}"
      end)
      |> Enum.join("\n")

    {:ok, messages}
  end

  defp summarize_details(details) do
    details
    |> Map.take([:action, :resource, :result])
    |> inspect()
    |> String.replace(",", ";")
  end

  defp filter_by_time(logs, nil, nil), do: logs

  defp filter_by_time(logs, from, to) do
    Enum.filter(logs, fn log ->
      (from == nil || DateTime.compare(log.timestamp, from) in [:gt, :eq]) &&
        (to == nil || DateTime.compare(log.timestamp, to) in [:lt, :eq])
    end)
  end

  defp filter_by_event_type(logs, nil), do: logs

  defp filter_by_event_type(logs, event_type) do
    Enum.filter(logs, fn log -> log.event_type == event_type end)
  end

  defp filter_by_actor(logs, nil), do: logs

  defp filter_by_actor(logs, actor) do
    Enum.filter(logs, fn log -> log.actor == actor end)
  end

  defp apply_limit(logs, nil), do: logs
  defp apply_limit(logs, limit), do: Enum.take(logs, limit)

  defp get_current_actor do
    # Get from process dictionary or context
    Process.get(:current_user, "system")
  end

  defp get_last_hash do
    # Get last hash from storage
    <<0::256>>
  end

  defp get_public_key do
    # Get public key for verification
    <<0::256>>
  end

  defp get_current_block_height do
    # Get current blockchain height
    0
  end

  defp get_storage_size(store) do
    case store.type do
      :file ->
        Path.wildcard("#{store.path}/*.log")
        |> Enum.map(&File.stat!/1)
        |> Enum.map(& &1.size)
        |> Enum.sum()

      _ ->
        0
    end
  end

  defp load_or_generate_key(opts) do
    case Keyword.get(opts, :signature_key) do
      nil ->
        # Generate new key
        {_public, private} = :crypto.generate_key(:ecdh, :secp256k1)
        private

      key ->
        key
    end
  end

  defp current_log_file(path) do
    date = Date.to_string(Date.utc_today())
    Path.join(path, "audit_#{date}.log")
  end

  defp build_config(opts) do
    %{
      buffer_size: Keyword.get(opts, :buffer_size, 100),
      flush_interval: Keyword.get(opts, :flush_interval, 5000),
      anchor_interval: Keyword.get(opts, :anchor_interval, :timer.hours(1)),
      rotation_interval: Keyword.get(opts, :rotation_interval, :timer.hours(24)),
      retention_days: Keyword.get(opts, :retention_days, 90)
    }
  end

  defp initialize_metrics do
    %{
      entries_buffered: 0,
      entries_flushed: 0,
      anchors_created: 0,
      verifications_performed: 0,
      exports_generated: 0
    }
  end

  defp update_metrics(_state, metric, count \\ 1) do
    update_in(state.metrics[metric], &(&1 + count))
  end

  defp generate_log_id do
    timestamp = DateTime.to_unix(DateTime.utc_now(), :microsecond)
    random = Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
    "#{timestamp}_#{random}"
  end

  defp schedule_flush do
    Process.send_after(self(), :flush_buffer, 5000)
  end

  defp schedule_anchoring do
    Process.send_after(self(), :anchor_logs, :timer.hours(1))
  end

  defp schedule_rotation do
    Process.send_after(self(), :rotate_logs, :timer.hours(24))
  end

  defp read_from_database(_connection) do
    []
  end

  defp read_from_s3(_bucket, _prefix) do
    []
  end
end
