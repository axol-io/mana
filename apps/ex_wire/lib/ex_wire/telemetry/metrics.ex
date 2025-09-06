defmodule ExWire.Telemetry.Metrics do
  @moduledoc """
  Telemetry metrics configuration for Prometheus export.

  This module configures all metrics that are exposed to Prometheus
  for monitoring the Mana Ethereum client.
  """

  use Prometheus.Metric

  def setup do
    # System metrics
    setup_system_metrics()

    # Blockchain metrics
    setup_blockchain_metrics()

    # P2P network metrics
    setup_p2p_metrics()

    # Transaction pool metrics
    setup_txpool_metrics()

    # Layer 2 metrics
    setup_layer2_metrics()

    # Consensus metrics
    setup_consensus_metrics()

    # RPC metrics
    setup_rpc_metrics()
  end

  defp setup_system_metrics do
    # Memory metrics (automatically collected by prometheus_ex)
    :prometheus_vm_memory_collector.setup()
    :prometheus_vm_statistics_collector.setup()
    :prometheus_vm_system_info_collector.setup()
  end

  defp setup_blockchain_metrics do
    # Current block height
    Gauge.new(
      name: :mana_sync_current_block,
      help: "Current synchronized block number",
      labels: [:node_id]
    )

    # Highest known block
    Gauge.new(
      name: :mana_sync_highest_block,
      help: "Highest known block number from peers",
      labels: [:node_id]
    )

    # Sync status
    Gauge.new(
      name: :mana_sync_status,
      help: "Sync status (0=syncing, 1=synced)",
      labels: [:node_id]
    )

    # Block processing time
    Histogram.new(
      name: :mana_block_processing_duration_seconds,
      help: "Time taken to process a block",
      buckets: [0.01, 0.05, 0.1, 0.5, 1, 2, 5],
      labels: [:node_id]
    )

    # Chain reorganizations
    Counter.new(
      name: :mana_chain_reorgs_total,
      help: "Total number of chain reorganizations",
      labels: [:node_id]
    )
  end

  defp setup_p2p_metrics do
    # Connected peers
    Gauge.new(
      name: :mana_p2p_peers_connected,
      help: "Number of connected peers",
      labels: [:node_id]
    )

    # Messages received
    Counter.new(
      name: :mana_p2p_messages_received_total,
      help: "Total number of P2P messages received",
      labels: [:node_id, :message_type]
    )

    # Messages sent
    Counter.new(
      name: :mana_p2p_messages_sent_total,
      help: "Total number of P2P messages sent",
      labels: [:node_id, :message_type]
    )

    # Network bandwidth
    Counter.new(
      name: :mana_p2p_bytes_received_total,
      help: "Total bytes received over P2P network",
      labels: [:node_id]
    )

    Counter.new(
      name: :mana_p2p_bytes_sent_total,
      help: "Total bytes sent over P2P network",
      labels: [:node_id]
    )
  end

  defp setup_txpool_metrics do
    # Pending transactions
    Gauge.new(
      name: :mana_txpool_pending_transactions,
      help: "Number of pending transactions in the pool",
      labels: [:node_id]
    )

    # Queued transactions
    Gauge.new(
      name: :mana_txpool_queued_transactions,
      help: "Number of queued transactions",
      labels: [:node_id]
    )

    # Processed transactions
    Counter.new(
      name: :mana_txpool_processed_transactions_total,
      help: "Total number of transactions processed",
      labels: [:node_id]
    )

    # Rejected transactions
    Counter.new(
      name: :mana_txpool_rejected_transactions_total,
      help: "Total number of transactions rejected",
      labels: [:node_id, :reason]
    )
  end

  defp setup_layer2_metrics do
    # Optimism metrics
    Counter.new(
      name: :mana_l2_optimism_batches_processed_total,
      help: "Total Optimism batches processed",
      labels: [:node_id]
    )

    # Arbitrum metrics
    Counter.new(
      name: :mana_l2_arbitrum_batches_processed_total,
      help: "Total Arbitrum batches processed",
      labels: [:node_id]
    )

    # zkSync metrics
    Counter.new(
      name: :mana_l2_zksync_proofs_verified_total,
      help: "Total zkSync proofs verified",
      labels: [:node_id]
    )

    Counter.new(
      name: :mana_l2_zksync_batches_processed_total,
      help: "Total zkSync batches processed",
      labels: [:node_id]
    )

    # General L2 metrics
    Counter.new(
      name: :mana_l2_transactions_processed_total,
      help: "Total L2 transactions processed",
      labels: [:node_id, :layer]
    )

    Histogram.new(
      name: :mana_l2_proof_verification_duration_seconds,
      help: "Time taken to verify L2 proofs",
      buckets: [0.1, 0.5, 1, 2, 5, 10],
      labels: [:node_id, :layer]
    )

    Counter.new(
      name: :mana_l2_batch_failures_total,
      help: "Total L2 batch processing failures",
      labels: [:node_id, :layer, :reason]
    )

    Counter.new(
      name: :mana_l2_proof_verification_failures_total,
      help: "Total L2 proof verification failures",
      labels: [:node_id, :layer, :reason]
    )

    # Bridge metrics
    Counter.new(
      name: :mana_l2_bridge_deposits_total,
      help: "Total bridge deposits processed",
      labels: [:node_id, :layer]
    )

    Counter.new(
      name: :mana_l2_bridge_withdrawals_total,
      help: "Total bridge withdrawals processed",
      labels: [:node_id, :layer]
    )

    # Compression ratio
    Gauge.new(
      name: :mana_l2_compression_ratio,
      help: "Data compression ratio for L2 batches",
      labels: [:node_id, :layer]
    )
  end

  defp setup_consensus_metrics do
    # Attestations
    Counter.new(
      name: :mana_consensus_attestations_processed_total,
      help: "Total attestations processed",
      labels: [:node_id]
    )

    Counter.new(
      name: :mana_consensus_missed_attestations_total,
      help: "Total missed attestations",
      labels: [:node_id]
    )

    # Finality
    Gauge.new(
      name: :mana_consensus_finality_lag_slots,
      help: "Number of slots behind finality",
      labels: [:node_id]
    )

    # Validator performance
    Gauge.new(
      name: :mana_consensus_validator_balance,
      help: "Validator balance in Gwei",
      labels: [:node_id, :validator_index]
    )

    Counter.new(
      name: :mana_consensus_blocks_proposed_total,
      help: "Total blocks proposed",
      labels: [:node_id]
    )
  end

  defp setup_rpc_metrics do
    # Request counter
    Counter.new(
      name: :mana_rpc_requests_total,
      help: "Total RPC requests received",
      labels: [:node_id, :method]
    )

    # Error counter
    Counter.new(
      name: :mana_rpc_errors_total,
      help: "Total RPC errors",
      labels: [:node_id, :method, :error_code]
    )

    # Request duration
    Histogram.new(
      name: :mana_rpc_request_duration_seconds,
      help: "RPC request duration",
      buckets: [0.001, 0.005, 0.01, 0.05, 0.1, 0.5, 1, 2],
      labels: [:node_id, :method]
    )

    # Active connections
    Gauge.new(
      name: :mana_rpc_connections_active,
      help: "Number of active RPC connections",
      labels: [:node_id]
    )
  end

  @doc """
  Update metrics values. This should be called periodically or on events.
  """
  def update_metrics(metric_name, value, labels \\ []) do
    case metric_name do
      # Gauge metrics
      :mana_sync_current_block ->
        Gauge.set([name: metric_name, labels: labels], value)

      :mana_sync_highest_block ->
        Gauge.set([name: metric_name, labels: labels], value)

      :mana_p2p_peers_connected ->
        Gauge.set([name: metric_name, labels: labels], value)

      :mana_txpool_pending_transactions ->
        Gauge.set([name: metric_name, labels: labels], value)

      # Counter metrics
      :mana_p2p_messages_received_total ->
        Counter.inc([name: metric_name, labels: labels], value)

      :mana_txpool_processed_transactions_total ->
        Counter.inc([name: metric_name, labels: labels], value)

      # Histogram metrics
      :mana_block_processing_duration_seconds ->
        Histogram.observe([name: metric_name, labels: labels], value)

      :mana_rpc_request_duration_seconds ->
        Histogram.observe([name: metric_name, labels: labels], value)

      _ ->
        :ok
    end
  end
end
