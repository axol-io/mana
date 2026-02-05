defmodule History.RPC.HealthHandler do
  @moduledoc """
  Health check endpoint handler.
  """
  @behaviour :cowboy_handler

  alias History.{Sync, Storage}

  @impl true
  def init(req, state) do
    status = get_health_status()

    response = Jason.encode!(status)

    http_status = if status.healthy, do: 200, else: 503

    req =
      req
      |> :cowboy_req.set_resp_header("content-type", "application/json")
      |> :cowboy_req.set_resp_header("access-control-allow-origin", "*")

    {:ok, :cowboy_req.reply(http_status, %{}, response, req), state}
  end

  defp get_health_status do
    sync_status = Sync.Pipeline.status()
    storage_stats = Storage.stats()

    synced = sync_status.synced_block
    highest = sync_status.highest_block
    sync_lag = highest - synced

    %{
      healthy: sync_lag < 1000 and sync_status.peers > 0,
      version: "0.1.0",
      sync: %{
        synced_block: synced,
        highest_block: highest,
        lag: sync_lag,
        peers: sync_status.peers,
        syncing: sync_status.syncing
      },
      storage: %{
        total_blocks: storage_stats.total_blocks,
        total_logs: storage_stats.total_logs,
        disk_usage_mb: div(storage_stats.disk_usage_bytes, 1_048_576),
        shards: storage_stats.shards
      },
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end
end
