defmodule History.Telemetry do
  @moduledoc """
  Telemetry and metrics for the History node.

  Emits telemetry events for:
  - Sync progress (blocks synced, logs indexed)
  - Query performance (latency, result size)
  - Storage stats (disk usage, shard distribution)
  """
  use GenServer

  require Logger

  @prefix [:history]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_) do
    # Attach telemetry handlers
    :telemetry.attach_many(
      "history-logger",
      [
        @prefix ++ [:sync, :block_synced],
        @prefix ++ [:sync, :started],
        @prefix ++ [:query, :get_logs],
        @prefix ++ [:storage, :put],
        @prefix ++ [:storage, :get]
      ],
      &handle_event/4,
      nil
    )

    {:ok, %{}}
  end

  @doc """
  Emit a telemetry event.
  """
  @spec emit(atom(), map()) :: :ok
  def emit(event, measurements) when is_atom(event) do
    :telemetry.execute(@prefix ++ [event], measurements, %{})
  end

  @spec emit(atom(), map(), map()) :: :ok
  def emit(event, measurements, metadata) do
    :telemetry.execute(@prefix ++ [event], measurements, metadata)
  end

  @doc """
  Measure execution time of a function and emit telemetry.
  """
  @spec measure(atom(), (-> result)) :: result when result: any()
  def measure(event, fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    duration = System.monotonic_time(:microsecond) - start

    emit(event, %{duration_us: duration})
    result
  end

  # Telemetry handlers

  defp handle_event([:history, :sync, :block_synced], measurements, _metadata, _config) do
    Logger.debug(
      "[History.Sync] Block #{measurements.block_number} synced, #{measurements.log_count} logs"
    )
  end

  defp handle_event([:history, :sync, :started], measurements, _metadata, _config) do
    Logger.info(
      "[History.Sync] Started sync for #{measurements.chain} from block #{measurements.start_block}"
    )
  end

  defp handle_event([:history, :query, :get_logs], measurements, _metadata, _config) do
    Logger.debug(
      "[History.Query] eth_getLogs returned #{measurements.count} logs in #{measurements.duration_us}us"
    )
  end

  defp handle_event(_event, _measurements, _metadata, _config) do
    :ok
  end
end
