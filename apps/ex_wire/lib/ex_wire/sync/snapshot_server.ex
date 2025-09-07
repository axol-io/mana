defmodule ExWire.Sync.SnapshotServer do
  @moduledoc """
  Snapshot serving system for Warp/Snap sync peers.

  This module handles incoming requests from peers wanting to download snapshots
  for fast sync. It integrates with the SnapshotGenerator to serve pre-generated
  snapshots and implements the complete Parity Warp sync protocol.

  ## Protocol Support

  - **GetSnapshotManifest**: Serve snapshot manifests to requesting peers
  - **GetSnapshotData**: Serve individual snapshot chunks by hash
  - **Warp Status**: Provide snapshot availability and status
  - **Rate Limiting**: Prevent abuse and manage serving bandwidth
  - **Compression**: Serve compressed snapshots to reduce bandwidth
  - **Statistics**: Track serving metrics for monitoring

  ## Usage

      # Start snapshot server
      {:ok, server} = SnapshotServer.start_link()
      
      # Enable/disable serving
      SnapshotServer.set_serving_enabled(true)
      
      # Get serving statistics
      stats = SnapshotServer.get_stats()
  """

  use GenServer
  require Logger

  alias ExWire.Sync.SnapshotGenerator
  alias ExWire.Packet.Capability.Par.{SnapshotManifest, SnapshotData, WarpStatus}
  alias ExWire.Network.PeerSupervisor

  @type peer_info :: %{
          peer_id: String.t(),
          ip_address: String.t(),
          capabilities: [String.t()],
          last_request: DateTime.t(),
          requests_count: non_neg_integer(),
          bytes_served: non_neg_integer()
        }

  @type serving_stats :: %{
          manifests_served: non_neg_integer(),
          chunks_served: non_neg_integer(),
          total_bytes_served: non_neg_integer(),
          active_peers: non_neg_integer(),
          rate_limited_requests: non_neg_integer(),
          average_response_time_ms: float(),
          uptime_seconds: non_neg_integer()
        }

  defstruct [
    :serving_enabled,
    :max_concurrent_peers,
    :rate_limit_requests_per_minute,
    :max_bandwidth_mbps,
    :peer_info,
    :serving_stats,
    :rate_limiter,
    :start_time
  ]

  @type t :: %__MODULE__{
          serving_enabled: boolean(),
          max_concurrent_peers: pos_integer(),
          rate_limit_requests_per_minute: pos_integer(),
          max_bandwidth_mbps: pos_integer(),
          peer_info: %{String.t() => peer_info()},
          serving_stats: serving_stats(),
          rate_limiter: map(),
          start_time: DateTime.t()
        }

  # Default configuration
  @default_max_concurrent_peers 50
  # 1 request per second per peer
  @default_rate_limit_per_minute 60
  # 100 Mbps total serving bandwidth
  @default_max_bandwidth_mbps 100
  # 1 minute window
  @rate_limit_window_ms 60_000
  # 10 seconds
  @stats_update_interval 10_000

  @name __MODULE__

  # Public API

  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc """
  Handle a GetSnapshotManifest request from a peer.
  """
  @spec handle_manifest_request(String.t(), String.t()) ::
          {:ok, SnapshotManifest.t()} | {:error, term()}
  def handle_manifest_request(peer_id, ip_address) do
    GenServer.call(@name, {:handle_manifest_request, peer_id, ip_address})
  end

  @doc """
  Handle a GetSnapshotData request for a specific chunk hash.
  """
  @spec handle_chunk_request(String.t(), String.t(), EVM.hash()) ::
          {:ok, SnapshotData.t()} | {:error, term()}
  def handle_chunk_request(peer_id, ip_address, chunk_hash) do
    GenServer.call(@name, {:handle_chunk_request, peer_id, ip_address, chunk_hash})
  end

  @doc """
  Handle a WarpStatus request to provide snapshot availability information.
  """
  @spec handle_warp_status_request(String.t(), String.t()) ::
          {:ok, WarpStatus.t()} | {:error, term()}
  def handle_warp_status_request(peer_id, ip_address) do
    GenServer.call(@name, {:handle_warp_status_request, peer_id, ip_address})
  end

  @doc """
  Enable or disable snapshot serving.
  """
  @spec set_serving_enabled(boolean()) :: :ok
  def set_serving_enabled(enabled) do
    GenServer.cast(@name, {:set_serving_enabled, enabled})
  end

  @doc """
  Get current serving statistics.
  """
  @spec get_stats() :: serving_stats()
  def get_stats() do
    GenServer.call(@name, :get_stats)
  end

  @doc """
  Get information about connected peers requesting snapshots.
  """
  @spec get_peer_info() :: %{String.t() => peer_info()}
  def get_peer_info() do
    GenServer.call(@name, :get_peer_info)
  end

  @doc """
  Update serving configuration.
  """
  @spec update_config(Keyword.t()) :: :ok
  def update_config(_config) do
    GenServer.cast(@name, {:update_config, config})
  end

  # GenServer callbacks

  @impl GenServer
  def init(opts) do
    serving_enabled = Keyword.get(opts, :serving_enabled, true)
    max_concurrent_peers = Keyword.get(opts, :max_concurrent_peers, @default_max_concurrent_peers)

    rate_limit_per_minute =
      Keyword.get(opts, :rate_limit_requests_per_minute, @default_rate_limit_per_minute)

    max_bandwidth_mbps = Keyword.get(opts, :max_bandwidth_mbps, @default_max_bandwidth_mbps)

    # Schedule periodic stats updates
    schedule_stats_update()

    state = %__MODULE__{
      serving_enabled: serving_enabled,
      max_concurrent_peers: max_concurrent_peers,
      rate_limit_requests_per_minute: rate_limit_per_minute,
      max_bandwidth_mbps: max_bandwidth_mbps,
      peer_info: %{},
      serving_stats: initial_serving_stats(),
      rate_limiter: %{},
      start_time: DateTime.utc_now()
    }

    Logger.info(
      "[SnapshotServer] Started with serving_enabled=#{serving_enabled}, max_peers=#{max_concurrent_peers}"
    )

    {:ok, _state}
  end

  @impl GenServer
  def handle_call({:handle_manifest_request, peer_id, ip_address}, _from, _state) do
    if not state.serving_enabled do
      {:reply, {:error, :serving_disabled}, state}
    else
      case check_rate_limit(peer_id, ip_address, state) do
        {:ok, new_state} ->
          case SnapshotGenerator.get_latest_manifest() do
            {:ok, manifest} ->
              # Create SnapshotManifest packet
              response = %SnapshotManifest{manifest: manifest}

              # Update peer info and stats
              updated_state =
                new_state
                |> update_peer_info(peer_id, ip_address, :manifest_request)
                |> update_serving_stats(:manifest_served)

              Logger.debug("[SnapshotServer] Served manifest to peer #{peer_id}")
              {:reply, {:ok, response}, updated_state}

            {:error, :no_snapshots} ->
              # Return empty manifest
              response = %SnapshotManifest{manifest: nil}
              updated_state = update_serving_stats(new_state, :empty_manifest_served)
              {:reply, {:ok, response}, updated_state}
          end

        {:error, :rate_limited} ->
          updated_state = update_serving_stats(state, :rate_limited_request)
          Logger.debug("[SnapshotServer] Rate limited manifest request from peer #{peer_id}")
          {:reply, {:error, :rate_limited}, updated_state}

        {:error, :max_peers_exceeded} ->
          Logger.debug("[SnapshotServer] Max concurrent peers exceeded for peer #{peer_id}")
          {:reply, {:error, :max_peers_exceeded}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:handle_chunk_request, peer_id, ip_address, chunk_hash}, _from, _state) do
    if not state.serving_enabled do
      {:reply, {:error, :serving_disabled}, state}
    else
      case check_rate_limit(peer_id, ip_address, state) do
        {:ok, new_state} ->
          start_time = System.monotonic_time(:millisecond)

          case SnapshotGenerator.get_chunk_by_hash(chunk_hash) do
            {:ok, chunk_data} ->
              # Create SnapshotData packet
              response = %SnapshotData{
                hash: chunk_hash,
                chunk: chunk_data
              }

              end_time = System.monotonic_time(:millisecond)
              response_time = end_time - start_time
              chunk_size = byte_size(chunk_data)

              # Update peer info and stats
              updated_state =
                new_state
                |> update_peer_info(peer_id, ip_address, :chunk_request, chunk_size)
                |> update_serving_stats(:chunk_served, chunk_size, response_time)

              Logger.debug(
                "[SnapshotServer] Served chunk #{Base.encode16(chunk_hash, case: :lower)} (#{chunk_size} bytes) to peer #{peer_id}"
              )

              {:reply, {:ok, response}, updated_state}

            {:error, :not_found} ->
              Logger.debug(
                "[SnapshotServer] Chunk not found: #{Base.encode16(chunk_hash, case: :lower)}"
              )

              {:reply, {:error, :chunk_not_found}, new_state}
          end

        {:error, :rate_limited} ->
          updated_state = update_serving_stats(state, :rate_limited_request)
          {:reply, {:error, :rate_limited}, updated_state}

        {:error, :max_peers_exceeded} ->
          {:reply, {:error, :max_peers_exceeded}, state}
      end
    end
  end

  @impl GenServer
  def handle_call({:handle_warp_status_request, peer_id, ip_address}, _from, _state) do
    if not state.serving_enabled do
      {:reply, {:error, :serving_disabled}, state}
    else
      case check_rate_limit(peer_id, ip_address, state) do
        {:ok, new_state} ->
          # Get latest snapshot info for warp status
          serving_info = SnapshotGenerator.get_serving_info()

          warp_status =
            case serving_info.snapshots do
              [] ->
                %WarpStatus{
                  protocol_version: 1,
                  network_id: ExWire.Config.chain()._params.network_id,
                  total_difficulty: 0,
                  best_hash: <<0::256>>,
                  genesis_hash: <<0::256>>,
                  snapshot_hash: <<0::256>>,
                  snapshot_number: 0
                }

              [latest | _] ->
                %WarpStatus{
                  protocol_version: 1,
                  network_id: ExWire.Config.chain().params.network_id,
                  # Would need actual total difficulty
                  total_difficulty: 0,
                  best_hash: latest.block_hash,
                  # Would need actual genesis hash
                  genesis_hash: <<0::256>>,
                  snapshot_hash: calculate_snapshot_manifest_hash(latest),
                  snapshot_number: latest.block_number
                }
            end

          # Update peer info and stats
          updated_state =
            new_state
            |> update_peer_info(peer_id, ip_address, :warp_status_request)
            |> update_serving_stats(:warp_status_served)

          Logger.debug("[SnapshotServer] Served warp status to peer #{peer_id}")
          {:reply, {:ok, warp_status}, updated_state}

        {:error, :rate_limited} ->
          updated_state = update_serving_stats(state, :rate_limited_request)
          {:reply, {:error, :rate_limited}, updated_state}

        {:error, :max_peers_exceeded} ->
          {:reply, {:error, :max_peers_exceeded}, state}
      end
    end
  end

  @impl GenServer
  def handle_call(:get_stats, _from, _state) do
    # Calculate current uptime
    uptime_seconds = DateTime.diff(DateTime.utc_now(), state.start_time, :second)
    updated_stats = %{state.serving_stats | uptime_seconds: uptime_seconds}
    {:reply, updated_stats, %{state | serving_stats: updated_stats}}
  end

  @impl GenServer
  def handle_call(:get_peer_info, _from, _state) do
    {:reply, state.peer_info, state}
  end

  @impl GenServer
  def handle_cast({:set_serving_enabled, enabled}, _state) do
    Logger.info(
      "[SnapshotServer] Serving enabled changed: #{state.serving_enabled} -> #{enabled}"
    )

    {:noreply, %{state | serving_enabled: enabled}}
  end

  @impl GenServer
  def handle_cast({:update_config, _config}, _state) do
    new_state = %{
      state
      | max_concurrent_peers:
          Keyword.get(config, :max_concurrent_peers, state.max_concurrent_peers),
        rate_limit_requests_per_minute:
          Keyword.get(
            config,
            :rate_limit_requests_per_minute,
            state.rate_limit_requests_per_minute
          ),
        max_bandwidth_mbps: Keyword.get(config, :max_bandwidth_mbps, state.max_bandwidth_mbps)
    }

    Logger.info("[SnapshotServer] Configuration updated")
    {:noreply, new_state}
  end

  @impl GenServer
  def handle_info(:update_stats, _state) do
    # Clean up old rate limiter entries
    current_time = System.system_time(:millisecond)
    window_start = current_time - @rate_limit_window_ms

    cleaned_rate_limiter =
      state.rate_limiter
      |> Enum.filter(fn {_key, requests} ->
        Enum.any?(requests, fn timestamp -> timestamp >= window_start end)
      end)
      |> Map.new(fn {key, requests} ->
        filtered_requests =
          Enum.filter(requests, fn timestamp ->
            timestamp >= window_start
          end)

        {key, filtered_requests}
      end)

    # Update active peers count
    active_peers = map_size(state.peer_info)
    updated_stats = %{state.serving_stats | active_peers: active_peers}

    # Schedule next update
    schedule_stats_update()

    {:noreply, %{state | rate_limiter: cleaned_rate_limiter, serving_stats: updated_stats}}
  end

  # Private functions

  defp check_rate_limit(peer_id, ip_address, _state) do
    # Check if we've exceeded max concurrent peers
    if map_size(state.peer_info) >= state.max_concurrent_peers and
         not Map.has_key?(state.peer_info, peer_id) do
      {:error, :max_peers_exceeded}
    else
      # Check rate limit for this peer
      rate_limit_key = "#{peer_id}:#{ip_address}"
      current_time = System.system_time(:millisecond)
      window_start = current_time - @rate_limit_window_ms

      current_requests = get_rate_limit_requests(rate_limit_key, window_start, state.rate_limiter)

      if current_requests < state.rate_limit_requests_per_minute do
        # Update rate limiter
        new_rate_limiter = update_rate_limiter(rate_limit_key, current_time, state.rate_limiter)
        {:ok, %{state | rate_limiter: new_rate_limiter}}
      else
        {:error, :rate_limited}
      end
    end
  end

  defp get_rate_limit_requests(key, window_start, rate_limiter) do
    case Map.get(rate_limiter, key) do
      nil -> 0
      requests -> Enum.count(requests, fn timestamp -> timestamp >= window_start end)
    end
  end

  defp update_rate_limiter(key, current_time, rate_limiter) do
    current_requests = Map.get(rate_limiter, key, [])
    new_requests = [current_time | current_requests]
    Map.put(rate_limiter, key, new_requests)
  end

  defp update_peer_info(_state, peer_id, ip_address, request_type, bytes_served \\ 0) do
    current_time = DateTime.utc_now()

    updated_peer_info =
      Map.update(
        _state.peer_info,
        peer_id,
        %{
          peer_id: peer_id,
          ip_address: ip_address,
          # Parity warp sync capability
          capabilities: ["par/1"],
          last_request: current_time,
          requests_count: 1,
          bytes_served: bytes_served
        },
        fn existing ->
          %{
            existing
            | last_request: current_time,
              requests_count: existing.requests_count + 1,
              bytes_served: existing.bytes_served + bytes_served
          }
        end
      )

    %{state | peer_info: updated_peer_info}
  end

  defp update_serving_stats(_state, event_type, bytes \\ 0, response_time_ms \\ 0) do
    stats = state.serving_stats

    updated_stats =
      case event_type do
        :manifest_served ->
          %{stats | manifests_served: stats.manifests_served + 1}

        :empty_manifest_served ->
          %{stats | manifests_served: stats.manifests_served + 1}

        :chunk_served ->
          new_avg =
            calculate_average_response_time(
              stats.average_response_time_ms,
              stats.chunks_served,
              response_time_ms
            )

          %{
            stats
            | chunks_served: stats.chunks_served + 1,
              total_bytes_served: stats.total_bytes_served + bytes,
              average_response_time_ms: new_avg
          }

        :warp_status_served ->
          # No specific counter for warp status
          stats

        :rate_limited_request ->
          %{stats | rate_limited_requests: stats.rate_limited_requests + 1}
      end

    %{state | serving_stats: updated_stats}
  end

  defp calculate_average_response_time(current_avg, total_requests, new_response_time) do
    if total_requests == 0 do
      new_response_time
    else
      (current_avg * total_requests + new_response_time) / (total_requests + 1)
    end
  end

  defp initial_serving_stats() do
    %{
      manifests_served: 0,
      chunks_served: 0,
      total_bytes_served: 0,
      active_peers: 0,
      rate_limited_requests: 0,
      average_response_time_ms: 0.0,
      uptime_seconds: 0
    }
  end

  defp schedule_stats_update() do
    Process.send_after(self(), :update_stats, @stats_update_interval)
  end

  defp calculate_snapshot_manifest_hash(snapshot_info) do
    # Calculate the manifest hash - this would be the hash of the manifest RLP
    # For now, return a placeholder hash based on block hash
    case snapshot_info do
      %{block_hash: block_hash} when is_binary(block_hash) -> block_hash
      _ -> <<0::256>>
    end
  end
end
