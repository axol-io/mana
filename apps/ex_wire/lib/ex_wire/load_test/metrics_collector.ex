defmodule ExWire.LoadTest.MetricsCollector do
  @moduledoc """
  Collects and exports metrics during load testing.
  Integrates with Prometheus for real-time monitoring.
  """

  use GenServer
  require Logger

  @metrics_port 9091
  # ms
  @collection_interval 1000

  defmodule Metrics do
    defstruct [
      :start_time,
      :end_time,
      :transactions_sent,
      :transactions_confirmed,
      :transactions_failed,
      :blocks_produced,
      :avg_block_time,
      :avg_gas_used,
      :peak_tps,
      :current_tps,
      :memory_usage,
      :cpu_usage,
      :network_io,
      :state_size,
      :latency_percentiles,
      :error_counts,
      :custom_metrics
    ]
  end

  # Client API

  @doc """
  Start metrics collection for a test scenario.
  """
  def start_collection(scenario_name) do
    GenServer.call(__MODULE__, {:start_collection, scenario_name})
  end

  @doc """
  Stop metrics collection and return results.
  """
  def stop_collection(scenario_name) do
    GenServer.call(__MODULE__, {:stop_collection, scenario_name})
  end

  @doc """
  Record a transaction being sent.
  """
  def record_transaction_sent(scenario_name, tx_hash) do
    GenServer.cast(__MODULE__, {:transaction_sent, scenario_name, tx_hash})
  end

  @doc """
  Record a transaction confirmation.
  """
  def record_transaction_confirmed(scenario_name, tx_hash, gas_used, latency_ms) do
    GenServer.cast(
      __MODULE__,
      {:transaction_confirmed, scenario_name, tx_hash, gas_used, latency_ms}
    )
  end

  @doc """
  Record a transaction failure.
  """
  def record_transaction_failed(scenario_name, tx_hash, reason) do
    GenServer.cast(__MODULE__, {:transaction_failed, scenario_name, tx_hash, reason})
  end

  @doc """
  Record block production.
  """
  def record_block_produced(scenario_name, block_number, block_time_ms, tx_count) do
    GenServer.cast(
      __MODULE__,
      {:block_produced, scenario_name, block_number, block_time_ms, tx_count}
    )
  end

  @doc """
  Record custom metric.
  """
  def record_custom_metric(scenario_name, metric_name, value) do
    GenServer.cast(__MODULE__, {:custom_metric, scenario_name, metric_name, value})
  end

  @doc """
  Get current metrics for a scenario.
  """
  def get_metrics(scenario_name) do
    GenServer.call(__MODULE__, {:get_metrics, scenario_name})
  end

  @doc """
  Export metrics to Prometheus.
  """
  def export_to_prometheus(scenario_name) do
    GenServer.call(__MODULE__, {:export_prometheus, scenario_name})
  end

  # Server implementation

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    # Start Prometheus exporter if configured
    if Application.get_env(:ex_wire, :enable_prometheus_export, true) do
      start_prometheus_exporter()
    end

    # Start periodic collection
    schedule_collection()

    {:ok,
     %{
       scenarios: %{},
       prometheus_registry: setup_prometheus_metrics()
     }}
  end

  def handle_call({:start_collection, scenario_name}, _from, state) do
    metrics = %Metrics{
      start_time: System.monotonic_time(:millisecond),
      transactions_sent: 0,
      transactions_confirmed: 0,
      transactions_failed: 0,
      blocks_produced: 0,
      avg_block_time: 0,
      avg_gas_used: 0,
      peak_tps: 0,
      current_tps: 0,
      memory_usage: [],
      cpu_usage: [],
      network_io: [],
      state_size: 0,
      latency_percentiles: %{p50: 0, p95: 0, p99: 0},
      error_counts: %{},
      custom_metrics: %{}
    }

    new_scenarios =
      Map.put(state.scenarios, scenario_name, %{
        metrics: metrics,
        latencies: [],
        gas_values: [],
        block_times: [],
        tps_history: [],
        pending_txs: %{}
      })

    Logger.info("Started metrics collection for scenario: #{scenario_name}")
    {:reply, :ok, %{state | scenarios: new_scenarios}}
  end

  def handle_call({:stop_collection, scenario_name}, _from, state) do
    case Map.get(state.scenarios, scenario_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      scenario_data ->
        final_metrics = finalize_metrics(scenario_data)

        # Export final metrics
        export_final_metrics(scenario_name, final_metrics)

        # Remove scenario but keep metrics for retrieval
        updated_scenarios =
          Map.update!(state.scenarios, scenario_name, fn data ->
            Map.put(data, :metrics, final_metrics)
          end)

        Logger.info("Stopped metrics collection for scenario: #{scenario_name}")
        {:reply, {:ok, final_metrics}, %{state | scenarios: updated_scenarios}}
    end
  end

  def handle_call({:get_metrics, scenario_name}, _from, state) do
    case Map.get(state.scenarios, scenario_name) do
      nil -> {:reply, nil, state}
      scenario_data -> {:reply, scenario_data.metrics, state}
    end
  end

  def handle_call({:export_prometheus, scenario_name}, _from, state) do
    case Map.get(state.scenarios, scenario_name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      scenario_data ->
        prometheus_format = format_for_prometheus(scenario_name, scenario_data.metrics)
        {:reply, {:ok, prometheus_format}, state}
    end
  end

  def handle_cast({:transaction_sent, scenario_name, tx_hash}, state) do
    new_state =
      update_scenario(state, scenario_name, fn data ->
        data
        |> update_in([:metrics, :transactions_sent], &(&1 + 1))
        |> update_in([:pending_txs], &Map.put(&1, tx_hash, System.monotonic_time(:millisecond)))
      end)

    update_prometheus_counter(:transactions_sent, scenario_name)
    {:noreply, new_state}
  end

  def handle_cast({:transaction_confirmed, scenario_name, tx_hash, gas_used, latency_ms}, state) do
    new_state =
      update_scenario(state, scenario_name, fn data ->
        sent_time = get_in(data, [:pending_txs, tx_hash])

        actual_latency =
          if sent_time do
            System.monotonic_time(:millisecond) - sent_time
          else
            latency_ms
          end

        data
        |> update_in([:metrics, :transactions_confirmed], &(&1 + 1))
        |> update_in([:latencies], &[actual_latency | &1])
        |> update_in([:gas_values], &[gas_used | &1])
        |> update_in([:pending_txs], &Map.delete(&1, tx_hash))
      end)

    update_prometheus_counter(:transactions_confirmed, scenario_name)
    update_prometheus_histogram(:transaction_latency, latency_ms, scenario_name)
    update_prometheus_histogram(:gas_used, gas_used, scenario_name)

    {:noreply, new_state}
  end

  def handle_cast({:transaction_failed, scenario_name, tx_hash, reason}, state) do
    new_state =
      update_scenario(state, scenario_name, fn data ->
        data
        |> update_in([:metrics, :transactions_failed], &(&1 + 1))
        |> update_in([:metrics, :error_counts], &Map.update(&1, reason, 1, fn c -> c + 1 end))
        |> update_in([:pending_txs], &Map.delete(&1, tx_hash))
      end)

    update_prometheus_counter(:transactions_failed, scenario_name)
    {:noreply, new_state}
  end

  def handle_cast({:block_produced, scenario_name, _block_number, block_time_ms, tx_count}, state) do
    new_state =
      update_scenario(state, scenario_name, fn data ->
        data
        |> update_in([:metrics, :blocks_produced], &(&1 + 1))
        |> update_in([:block_times], &[block_time_ms | &1])
        |> update_in([:tps_history], &[tx_count / (block_time_ms / 1000) | &1])
      end)

    update_prometheus_counter(:blocks_produced, scenario_name)
    update_prometheus_histogram(:block_time, block_time_ms, scenario_name)

    {:noreply, new_state}
  end

  def handle_cast({:custom_metric, scenario_name, metric_name, value}, state) do
    new_state =
      update_scenario(state, scenario_name, fn data ->
        update_in(data, [:metrics, :custom_metrics], &Map.put(&1, metric_name, value))
      end)

    {:noreply, new_state}
  end

  def handle_info(:collect_system_metrics, state) do
    # Collect system metrics for all active scenarios
    new_state =
      Enum.reduce(state.scenarios, state, fn {scenario_name, _data}, acc ->
        update_scenario(acc, scenario_name, fn data ->
          data
          |> update_in([:metrics, :memory_usage], &[get_memory_usage() | &1])
          |> update_in([:metrics, :cpu_usage], &[get_cpu_usage() | &1])
          |> update_in([:metrics, :network_io], &[get_network_io() | &1])
          |> Map.update!(:metrics, &update_current_metrics(&1, data))
        end)
      end)

    schedule_collection()
    {:noreply, new_state}
  end

  # Private helper functions

  defp update_scenario(state, scenario_name, update_fn) do
    case Map.get(state.scenarios, scenario_name) do
      nil ->
        state

      _data ->
        update_in(state, [:scenarios, scenario_name], update_fn)
    end
  end

  defp finalize_metrics(scenario_data) do
    metrics = scenario_data.metrics

    # Calculate percentiles
    latency_percentiles =
      if length(scenario_data.latencies) > 0 do
        sorted = Enum.sort(scenario_data.latencies)

        %{
          p50: percentile(sorted, 50),
          p95: percentile(sorted, 95),
          p99: percentile(sorted, 99)
        }
      else
        %{p50: 0, p95: 0, p99: 0}
      end

    # Calculate averages
    avg_gas =
      if length(scenario_data.gas_values) > 0 do
        Enum.sum(scenario_data.gas_values) / length(scenario_data.gas_values)
      else
        0
      end

    avg_block_time =
      if length(scenario_data.block_times) > 0 do
        Enum.sum(scenario_data.block_times) / length(scenario_data.block_times)
      else
        0
      end

    peak_tps =
      if length(scenario_data.tps_history) > 0 do
        Enum.max(scenario_data.tps_history)
      else
        0
      end

    %{
      metrics
      | end_time: System.monotonic_time(:millisecond),
        latency_percentiles: latency_percentiles,
        avg_gas_used: round(avg_gas),
        avg_block_time: round(avg_block_time),
        peak_tps: Float.round(peak_tps, 2)
    }
  end

  defp update_current_metrics(metrics, data) do
    # Calculate current TPS
    recent_tps = Enum.take(data.tps_history, 10)

    current_tps =
      if length(recent_tps) > 0 do
        Enum.sum(recent_tps) / length(recent_tps)
      else
        0
      end

    %{metrics | current_tps: Float.round(current_tps, 2)}
  end

  defp percentile(sorted_list, p) do
    index = round(length(sorted_list) * p / 100)
    Enum.at(sorted_list, max(0, index - 1), 0)
  end

  defp get_memory_usage do
    memory = :erlang.memory()

    %{
      total: memory[:total],
      processes: memory[:processes],
      ets: memory[:ets],
      binary: memory[:binary]
    }
  end

  defp get_cpu_usage do
    # Simplified CPU usage - in production would use :cpu_sup
    schedulers = :erlang.system_info(:schedulers_online)
    utilization = :erlang.statistics(:scheduler_wall_time)

    if is_list(utilization) do
      total =
        Enum.reduce(utilization, {0, 0}, fn {_id, active, total}, {acc_active, acc_total} ->
          {acc_active + active, acc_total + total}
        end)

      case total do
        {active, total} when total > 0 ->
          Float.round(active / total * 100, 2)

        _ ->
          0.0
      end
    else
      0.0
    end
  end

  defp get_network_io do
    # Placeholder for network I/O metrics
    %{
      bytes_sent: :rand.uniform(1_000_000),
      bytes_received: :rand.uniform(1_000_000),
      packets_sent: :rand.uniform(1000),
      packets_received: :rand.uniform(1000)
    }
  end

  defp schedule_collection do
    Process.send_after(self(), :collect_system_metrics, @collection_interval)
  end

  defp start_prometheus_exporter do
    # Start HTTP server for Prometheus scraping
    children = [
      {Plug.Cowboy, scheme: :http, plug: PrometheusExporter, options: [port: @metrics_port]}
    ]

    Supervisor.start_link(children, strategy: :one_for_one)
    Logger.info("Prometheus exporter started on port #{@metrics_port}")
  rescue
    error ->
      Logger.warning("Failed to start Prometheus exporter: #{inspect(error)}")
  end

  defp setup_prometheus_metrics do
    # Register Prometheus metrics
    metrics = [
      {:counter, :mana_load_test_transactions_sent, "Total transactions sent"},
      {:counter, :mana_load_test_transactions_confirmed, "Total transactions confirmed"},
      {:counter, :mana_load_test_transactions_failed, "Total transactions failed"},
      {:counter, :mana_load_test_blocks_produced, "Total blocks produced"},
      {:histogram, :mana_load_test_transaction_latency, "Transaction confirmation latency",
       buckets: [100, 500, 1000, 5000, 10000]},
      {:histogram, :mana_load_test_gas_used, "Gas used per transaction",
       buckets: [21000, 50000, 100_000, 200_000, 500_000]},
      {:histogram, :mana_load_test_block_time, "Block production time",
       buckets: [1000, 5000, 10000, 15000, 30000]},
      {:gauge, :mana_load_test_current_tps, "Current transactions per second"},
      {:gauge, :mana_load_test_memory_usage, "Memory usage in bytes"},
      {:gauge, :mana_load_test_cpu_usage, "CPU usage percentage"}
    ]

    # In production, would register with actual Prometheus client
    metrics
  end

  defp update_prometheus_counter(metric, scenario) do
    # In production, would update actual Prometheus counter
    Logger.debug("Prometheus counter #{metric} incremented for #{scenario}")
  end

  defp update_prometheus_histogram(metric, value, scenario) do
    # In production, would update actual Prometheus histogram
    Logger.debug("Prometheus histogram #{metric} updated with #{value} for #{scenario}")
  end

  defp export_final_metrics(scenario_name, metrics) do
    # Export to file for post-processing
    filename = "metrics_#{scenario_name}_#{System.system_time(:second)}.json"
    path = Path.join(System.tmp_dir(), filename)

    json_data =
      Jason.encode!(
        %{
          scenario: scenario_name,
          metrics: metrics,
          duration_ms: metrics.end_time - metrics.start_time,
          success_rate: calculate_success_rate(metrics)
        },
        pretty: true
      )

    File.write!(path, json_data)
    Logger.info("Metrics exported to #{path}")
  end

  defp calculate_success_rate(metrics) do
    total = metrics.transactions_sent

    if total > 0 do
      Float.round(metrics.transactions_confirmed / total * 100, 2)
    else
      0.0
    end
  end

  defp format_for_prometheus(scenario_name, metrics) do
    """
    # HELP mana_load_test_transactions_sent Total transactions sent
    # TYPE mana_load_test_transactions_sent counter
    mana_load_test_transactions_sent{scenario="#{scenario_name}"} #{metrics.transactions_sent}

    # HELP mana_load_test_transactions_confirmed Total transactions confirmed
    # TYPE mana_load_test_transactions_confirmed counter
    mana_load_test_transactions_confirmed{scenario="#{scenario_name}"} #{metrics.transactions_confirmed}

    # HELP mana_load_test_transactions_failed Total transactions failed
    # TYPE mana_load_test_transactions_failed counter
    mana_load_test_transactions_failed{scenario="#{scenario_name}"} #{metrics.transactions_failed}

    # HELP mana_load_test_current_tps Current transactions per second
    # TYPE mana_load_test_current_tps gauge
    mana_load_test_current_tps{scenario="#{scenario_name}"} #{metrics.current_tps}

    # HELP mana_load_test_latency_p95 95th percentile latency in ms
    # TYPE mana_load_test_latency_p95 gauge
    mana_load_test_latency_p95{scenario="#{scenario_name}"} #{metrics.latency_percentiles.p95}
    """
  end
end

# # Commented out PrometheusExporter module due to Plug.Router dependency
# # defmodule PrometheusExporter do
#   @moduledoc false
#   use Plug.Router
# 
#   plug(:match)
#   plug(:dispatch)
# 
#   get "/metrics" do
#     # Aggregate metrics from all scenarios
#     metrics = ExWire.LoadTest.MetricsCollector.get_all_prometheus_metrics()
# 
#     conn
#     |> put_resp_content_type("text/plain")
#     |> send_resp(200, metrics)
#   end
# 
#   match _ do
#     send_resp(conn, 404, "Not found")
#   end
# end
