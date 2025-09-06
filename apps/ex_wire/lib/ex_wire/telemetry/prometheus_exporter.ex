defmodule ExWire.Telemetry.PrometheusExporter do
  @moduledoc """
  Prometheus metrics exporter for the Mana Ethereum client.

  This module starts a Cowboy HTTP server to expose metrics
  to Prometheus on the configured port.
  """

  use GenServer
  require Logger

  @default_port 9568
  @metrics_path "/metrics"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, @default_port)

    # Setup Prometheus collectors and metrics
    setup_prometheus()

    # Start Cowboy HTTP server
    start_http_server(port)

    # Start metric update timer
    schedule_metric_update()

    {:ok, %{port: port}}
  end

  defp setup_prometheus do
    # Setup default Prometheus collectors
    :prometheus_registry.register_collector(:prometheus_vm_memory_collector)
    :prometheus_registry.register_collector(:prometheus_vm_statistics_collector)
    :prometheus_registry.register_collector(:prometheus_vm_system_info_collector)

    # Setup Mana-specific metrics
    ExWire.Telemetry.Metrics.setup()

    Logger.info("Prometheus metrics initialized")
  end

  defp start_http_server(port) do
    dispatch =
      :cowboy_router.compile([
        {:_,
         [
           {@metrics_path, :prometheus_cowboy2_handler, []},
           {"/health", __MODULE__.HealthHandler, []},
           {"/ready", __MODULE__.ReadyHandler, []}
         ]}
      ])

    case :cowboy.start_clear(
           :prometheus_http,
           [{:port, port}],
           %{env: %{dispatch: dispatch}}
         ) do
      {:ok, _} ->
        Logger.info("Prometheus exporter started on port #{port}")
        {:ok, port}

      {:error, reason} ->
        Logger.error("Failed to start Prometheus exporter: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp schedule_metric_update do
    Process.send_after(self(), :update_metrics, 5_000)
  end

  @impl true
  def handle_info(:update_metrics, state) do
    update_metrics()
    schedule_metric_update()
    {:noreply, state}
  end

  defp update_metrics do
    # Update blockchain metrics
    update_blockchain_metrics()

    # Update P2P metrics
    update_p2p_metrics()

    # Update transaction pool metrics
    update_txpool_metrics()

    # Update Layer 2 metrics if enabled
    update_layer2_metrics()

    # Update consensus metrics if Eth2 is enabled
    update_consensus_metrics()
  end

  defp update_blockchain_metrics do
    # Get current block from blockchain state
    case get_current_block() do
      {:ok, block_number} ->
        ExWire.Telemetry.Metrics.update_metrics(
          :mana_sync_current_block,
          block_number,
          node_id: node_id()
        )

      _ ->
        :ok
    end

    # Get highest block from peers
    case get_highest_block() do
      {:ok, highest_block} ->
        ExWire.Telemetry.Metrics.update_metrics(
          :mana_sync_highest_block,
          highest_block,
          node_id: node_id()
        )

      _ ->
        :ok
    end
  end

  defp update_p2p_metrics do
    # Update peer count
    case get_peer_count() do
      {:ok, count} ->
        ExWire.Telemetry.Metrics.update_metrics(
          :mana_p2p_peers_connected,
          count,
          node_id: node_id()
        )

      _ ->
        :ok
    end
  end

  defp update_txpool_metrics do
    # Update pending transactions
    case get_pending_tx_count() do
      {:ok, count} ->
        ExWire.Telemetry.Metrics.update_metrics(
          :mana_txpool_pending_transactions,
          count,
          node_id: node_id()
        )

      _ ->
        :ok
    end
  end

  defp update_layer2_metrics do
    # This would fetch actual Layer 2 metrics from the Layer 2 modules
    :ok
  end

  defp update_consensus_metrics do
    # This would fetch actual consensus metrics from Eth2 modules
    :ok
  end

  # Helper functions to get actual metric values
  # These would interface with the actual Mana modules

  defp get_current_block do
    # Get current block from blockchain module
    case Blockchain.get_latest_block_number() do
      {:ok, block_num} -> {:ok, block_num}
      _ -> {:ok, 0}
    end
  end

  defp get_highest_block do
    # Get highest known block from sync module
    case ExWire.Sync.get_highest_block_number() do
      {:ok, block_num} -> {:ok, block_num}
      # Fallback to current if sync not available
      _ -> get_current_block()
    end
  end

  defp get_peer_count do
    # Get connected peer count from P2P module
    case ExWire.P2P.get_peer_count() do
      {:ok, count} -> {:ok, count}
      _ -> {:ok, 0}
    end
  end

  defp get_pending_tx_count do
    # Get pending transaction count from mempool
    case ExWire.TxPool.get_pending_count() do
      {:ok, count} -> {:ok, count}
      _ -> {:ok, 0}
    end
  end

  defp node_id do
    # Get node ID from configuration or generate
    "mana-node-1"
  end

  # Health check handler
  defmodule HealthHandler do
    @behaviour :cowboy_handler

    def init(req, state) do
      req =
        :cowboy_req.reply(
          200,
          %{"content-type" => "text/plain"},
          "OK\n",
          req
        )

      {:ok, req, state}
    end
  end

  # Readiness check handler
  defmodule ReadyHandler do
    @behaviour :cowboy_handler

    def init(req, state) do
      # Check if node is synced and ready
      status =
        if is_node_ready?() do
          {200, "READY\n"}
        else
          {503, "NOT READY\n"}
        end

      {code, body} = status

      req =
        :cowboy_req.reply(
          code,
          %{"content-type" => "text/plain"},
          body,
          req
        )

      {:ok, req, state}
    end

    defp is_node_ready? do
      # Check actual node readiness
      with {:ok, current} <- ExWire.Telemetry.PrometheusExporter.get_current_block(),
           {:ok, highest} <- ExWire.Telemetry.PrometheusExporter.get_highest_block(),
           {:ok, peers} <- ExWire.Telemetry.PrometheusExporter.get_peer_count(),
           # Within 10 blocks is considered synced
           true <- highest - current < 10,
           # Has at least one peer
           true <- peers > 0 do
        true
      else
        _ -> false
      end
    end
  end
end
