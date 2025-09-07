defmodule Mix.Tasks.DvtStatus do
  @moduledoc """
  DVT Validator Status and Management Tool

  Monitor and manage running DVT validator clusters.

  ## Usage

      # Get status of specific cluster
      mix dvt_status --cluster-id "test-cluster-1"

      # Get detailed status with metrics
      mix dvt_status --cluster-id "test-cluster-1" --detailed

      # Monitor cluster continuously
      mix dvt_status --cluster-id "test-cluster-1" --watch

      # Get status of all running clusters
      mix dvt_status --all

      # Export cluster status as JSON
      mix dvt_status --cluster-id "test-cluster-1" --format json

  ## Options

    * `--cluster-id` - DVT cluster identifier
    * `--all` - Show status of all running clusters  
    * `--detailed` - Include performance metrics and detailed status
    * `--watch` - Continuously monitor (refresh every 10 seconds)
    * `--format` - Output format: table (default), json, csv
    * `--node-id` - Show status for specific node only
    * `--export` - Export status to file

  """

  use Mix.Task
  require Logger

  alias ExWire.DVT.{TestnetValidator, KeyManager, DutyConsensus}

  @switches [
    cluster_id: :string,
    all: :boolean,
    detailed: :boolean,
    watch: :boolean,
    format: :string,
    node_id: :integer,
    export: :string,
    help: :boolean
  ]

  @aliases [
    c: :cluster_id,
    a: :all,
    d: :detailed,
    w: :watch,
    h: :help
  ]

  def run(args) do
    case OptionParser.parse(args, switches: @switches, aliases: @aliases) do
      {opts, [], []} ->
        if opts[:help] do
          print_help()
        else
          run_status_command(opts)
        end

      {_opts, extra_args, []} ->
        Mix.shell().error("Unknown arguments: #{Enum.join(extra_args, ", ")}")
        print_help()

      {_opts, _args, invalid} ->
        invalid_opts = Enum.map(invalid, fn {opt, _} -> "--#{opt}" end)
        Mix.shell().error("Invalid options: #{Enum.join(invalid_opts, ", ")}")
        print_help()
    end
  end

  defp run_status_command(opts) do
    Application.ensure_all_started(:ex_wire)

    cond do
      opts[:all] ->
        show_all_clusters(opts)

      opts[:cluster_id] ->
        if opts[:watch] do
          watch_cluster(opts[:cluster_id], opts)
        else
          show_cluster_status(opts[:cluster_id], opts)
        end

      true ->
        Mix.shell().error("Either --cluster-id or --all must be specified")
        print_help()
    end
  end

  defp show_all_clusters(opts) do
    case discover_running_clusters() do
      {:ok, clusters} when length(clusters) > 0 ->
        print_all_clusters_status(clusters, opts)

      {:ok, []} ->
        Mix.shell().info("No running DVT clusters found")

      {:error, reason} ->
        Mix.shell().error("Failed to discover clusters: #{reason}")
    end
  end

  defp show_cluster_status(cluster_id, opts) do
    case get_cluster_status(cluster_id, opts) do
      {:ok, status} ->
        print_cluster_status(status, opts)

        if opts[:export] do
          export_status(status, opts[:export], opts)
        end

      {:error, :not_found} ->
        Mix.shell().error("Cluster '#{cluster_id}' not found or not running")
        suggest_available_clusters()

      {:error, reason} ->
        Mix.shell().error("Failed to get cluster status: #{reason}")
    end
  end

  defp watch_cluster(cluster_id, opts) do
    Mix.shell().info("Watching DVT cluster: #{cluster_id} (Press Ctrl+C to stop)")
    Mix.shell().info("Refreshing every 10 seconds...\n")

    watch_loop(cluster_id, opts)
  end

  defp watch_loop(cluster_id, opts) do
    # Clear screen
    IO.puts("\e[2J\e[H")
    
    Mix.shell().info("DVT Cluster Status - #{DateTime.utc_now() |> DateTime.to_string()}")
    Mix.shell().info("=" |> String.duplicate(60))

    case get_cluster_status(cluster_id, opts) do
      {:ok, status} ->
        print_cluster_status(status, opts)

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
    end

    # Wait for 10 seconds or until interrupted
    receive do
      :stop -> :ok
    after
      10_000 -> watch_loop(cluster_id, opts)
    end
  end

  defp get_cluster_status(cluster_id, opts) do
    case find_cluster_nodes(cluster_id) do
      {:ok, nodes} when length(nodes) > 0 ->
        collect_cluster_status(cluster_id, nodes, opts)

      {:ok, []} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_cluster_nodes(cluster_id) do
    # Look for running validator processes for this cluster
    processes = Registry.select(ExWire.DVT.TestnetValidatorRegistry, [
      {{:"$1", :"$2", :"$3"}, 
       [{:==, {:element, 1, :"$1"}, cluster_id}], 
       [{{:"$1", :"$2"}}]}
    ])

    nodes = Enum.map(processes, fn {{cluster_id, node_id}, pid} ->
      %{cluster_id: cluster_id, node_id: node_id, pid: pid}
    end)

    {:ok, nodes}
  end

  defp collect_cluster_status(cluster_id, nodes, opts) do
    node_statuses = Enum.map(nodes, fn node ->
      case get_node_status(node, opts) do
        {:ok, status} -> {:ok, status}
        {:error, reason} -> {:error, {node.node_id, reason}}
      end
    end)

    case Enum.split_with(node_statuses, fn {status, _} -> status == :ok end) do
      {successful, failed} ->
        cluster_status = %{
          cluster_id: cluster_id,
          total_nodes: length(nodes),
          healthy_nodes: length(successful),
          failed_nodes: length(failed),
          node_details: Enum.map(successful, fn {:ok, status} -> status end),
          failures: Enum.map(failed, fn {:error, {node_id, reason}} -> 
            %{node_id: node_id, error: reason}
          end),
          overall_health: calculate_cluster_health(successful, failed),
          timestamp: DateTime.utc_now()
        }

        {:ok, cluster_status}
    end
  end

  defp get_node_status(node, opts) do
    try do
      case TestnetValidator.get_validator_status(node.cluster_id, node.node_id) do
        {:ok, status} ->
          enhanced_status = if opts[:detailed] do
            Map.merge(status, get_detailed_node_metrics(node))
          else
            status
          end
          
          {:ok, enhanced_status}

        {:error, reason} ->
          {:error, reason}
      end
    rescue
      e -> {:error, "Node #{node.node_id} unreachable: #{Exception.message(e)}"}
    catch
      :exit, reason -> {:error, "Node #{node.node_id} crashed: #{inspect(reason)}"}
    end
  end

  defp get_detailed_node_metrics(node) do
    %{
      system_metrics: %{
        memory_usage: get_process_memory(node.pid),
        message_queue_length: get_message_queue_length(node.pid),
        uptime: get_process_uptime(node.pid)
      },
      performance_metrics: get_performance_metrics(node)
    }
  end

  defp calculate_cluster_health(successful, failed) do
    total = length(successful) + length(failed)
    healthy_ratio = length(successful) / total

    cond do
      healthy_ratio >= 0.8 -> :healthy
      healthy_ratio >= 0.6 -> :degraded  
      healthy_ratio >= 0.4 -> :unhealthy
      true -> :critical
    end
  end

  defp print_all_clusters_status(clusters, opts) do
    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode!(clusters, pretty: true))

      "csv" ->
        print_clusters_csv(clusters)

      _ ->
        print_clusters_table(clusters, opts)
    end
  end

  defp print_cluster_status(status, opts) do
    case opts[:format] do
      "json" ->
        Mix.shell().info(Jason.encode!(status, pretty: true))

      "csv" ->
        print_cluster_csv(status)

      _ ->
        print_cluster_table(status, opts)
    end
  end

  defp print_clusters_table(clusters, _opts) do
    Mix.shell().info("DVT Clusters Status")
    Mix.shell().info("=" |> String.duplicate(80))

    headers = ["Cluster ID", "Nodes", "Health", "Network", "Uptime"]
    rows = Enum.map(clusters, fn cluster ->
      [
        cluster.cluster_id,
        "#{cluster.healthy_nodes}/#{cluster.total_nodes}",
        format_health_status(cluster.overall_health),
        cluster.network || "unknown",
        format_uptime(cluster.uptime || 0)
      ]
    end)

    print_table(headers, rows)
  end

  defp print_cluster_table(status, opts) do
    health_icon = case status.overall_health do
      :healthy -> "✅"
      :degraded -> "⚠️"
      :unhealthy -> "🔶"
      :critical -> "❌"
    end

    Mix.shell().info("#{health_icon} DVT Cluster: #{status.cluster_id}")
    Mix.shell().info("=" |> String.duplicate(60))
    Mix.shell().info("Overall Health: #{format_health_status(status.overall_health)}")
    Mix.shell().info("Active Nodes: #{status.healthy_nodes}/#{status.total_nodes}")
    Mix.shell().info("Timestamp: #{DateTime.to_string(status.timestamp)}")

    if length(status.failures) > 0 do
      Mix.shell().info("\n❌ Failed Nodes:")
      Enum.each(status.failures, fn failure ->
        Mix.shell().info("  Node #{failure.node_id}: #{failure.error}")
      end)
    end

    Mix.shell().info("\n📊 Node Status:")
    
    headers = if opts[:detailed] do
      ["Node", "Status", "Network", "Peers", "Duties", "Memory", "Uptime"]
    else
      ["Node", "Status", "Network", "Peers", "Duties"]
    end

    rows = Enum.map(status.node_details, fn node ->
      base_row = [
        "#{node.node_id}",
        format_node_status(node.cluster_state.status),
        "#{node.network}",
        "#{node.p2p_peers}",
        "#{length(node.duties)}"
      ]

      if opts[:detailed] do
        memory = node.system_metrics.memory_usage |> format_memory()
        uptime = node.system_metrics.uptime |> format_uptime()
        base_row ++ [memory, uptime]
      else
        base_row
      end
    end)

    print_table(headers, rows)

    if opts[:detailed] do
      print_detailed_metrics(status)
    end
  end

  defp print_detailed_metrics(status) do
    Mix.shell().info("\n📈 Performance Metrics:")
    
    if length(status.node_details) > 0 do
      avg_latency = status.node_details
        |> Enum.map(fn node -> node.performance.average_duty_latency end)
        |> Enum.sum()
        |> div(length(status.node_details))

      avg_success_rate = status.node_details
        |> Enum.map(fn node -> node.performance.attestation_success_rate end)
        |> Enum.sum()
        |> Kernel./(length(status.node_details))

      Mix.shell().info("  Average Duty Latency: #{avg_latency}ms")
      Mix.shell().info("  Average Success Rate: #{Float.round(avg_success_rate * 100, 2)}%")
    end
  end

  defp print_table(headers, rows) do
    # Calculate column widths
    all_rows = [headers | rows]
    col_widths = all_rows
      |> Enum.zip()
      |> Enum.map(fn col_tuple -> 
        col_tuple 
        |> Tuple.to_list() 
        |> Enum.map(&String.length/1) 
        |> Enum.max()
      end)

    # Print header
    header_row = headers
      |> Enum.zip(col_widths)
      |> Enum.map(fn {header, width} -> String.pad_trailing(header, width) end)
      |> Enum.join(" | ")
    
    Mix.shell().info(header_row)
    Mix.shell().info("-" |> String.duplicate(String.length(header_row)))

    # Print rows
    Enum.each(rows, fn row ->
      formatted_row = row
        |> Enum.zip(col_widths)
        |> Enum.map(fn {cell, width} -> String.pad_trailing(to_string(cell), width) end)
        |> Enum.join(" | ")
      
      Mix.shell().info(formatted_row)
    end)
  end

  defp discover_running_clusters do
    # Find all registered validator processes
    processes = Registry.select(ExWire.DVT.TestnetValidatorRegistry, [
      {{:"$1", :"$2", :"$3"}, [], [{{:"$1", :"$2"}}]}
    ])

    # Group by cluster_id
    clusters_map = Enum.group_by(processes, fn {{cluster_id, _node_id}, _pid} -> cluster_id end)

    clusters = Enum.map(clusters_map, fn {cluster_id, nodes} ->
      %{
        cluster_id: cluster_id,
        total_nodes: length(nodes),
        healthy_nodes: length(nodes), # Simplified - all registered are healthy
        overall_health: :healthy,
        network: :unknown,
        uptime: 0
      }
    end)

    {:ok, clusters}
  end

  defp suggest_available_clusters do
    case discover_running_clusters() do
      {:ok, clusters} when length(clusters) > 0 ->
        cluster_ids = Enum.map(clusters, & &1.cluster_id)
        Mix.shell().info("Available clusters: #{Enum.join(cluster_ids, ", ")}")

      _ ->
        Mix.shell().info("No DVT clusters are currently running")
        Mix.shell().info("Use 'mix dvt_testnet_setup' to start a new cluster")
    end
  end

  # Helper functions for formatting

  defp format_health_status(:healthy), do: "Healthy"
  defp format_health_status(:degraded), do: "Degraded"
  defp format_health_status(:unhealthy), do: "Unhealthy"  
  defp format_health_status(:critical), do: "Critical"

  defp format_node_status(:healthy), do: "✅ Online"
  defp format_node_status(:degraded), do: "⚠️ Degraded"
  defp format_node_status(:unhealthy), do: "🔶 Unhealthy"
  defp format_node_status(_), do: "❌ Offline"

  defp format_memory(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)}GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)}MB"
      bytes >= 1_024 -> "#{Float.round(bytes / 1_024, 1)}KB"
      true -> "#{bytes}B"
    end
  end
  defp format_memory(_), do: "N/A"

  defp format_uptime(seconds) when is_integer(seconds) do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)
    "#{hours}h#{minutes}m"
  end
  defp format_uptime(_), do: "N/A"

  # System metrics helpers

  defp get_process_memory(pid) do
    case Process.info(pid, :memory) do
      {:memory, memory} -> memory
      _ -> 0
    end
  end

  defp get_message_queue_length(pid) do
    case Process.info(pid, :message_queue_len) do
      {:message_queue_len, len} -> len
      _ -> 0
    end
  end

  defp get_process_uptime(pid) do
    case Process.info(pid, :reductions) do
      {:reductions, _} -> 
        # Simplified uptime calculation
        System.system_time(:second) - 3600
      _ -> 0
    end
  end

  defp get_performance_metrics(_node) do
    # Placeholder - would collect real metrics
    %{
      consensus_latency: 1200,
      message_throughput: 45.2,
      error_rate: 0.02
    }
  end

  defp export_status(status, filename, opts) do
    content = case opts[:format] do
      "json" -> Jason.encode!(status, pretty: true)
      "csv" -> format_status_as_csv(status)
      _ -> inspect(status, pretty: true)
    end

    File.write!(filename, content)
    Mix.shell().info("Status exported to: #{filename}")
  end

  defp format_status_as_csv(status) do
    headers = "cluster_id,total_nodes,healthy_nodes,overall_health,timestamp\n"
    data = "#{status.cluster_id},#{status.total_nodes},#{status.healthy_nodes},#{status.overall_health},#{status.timestamp}\n"
    headers <> data
  end

  defp print_clusters_csv(clusters) do
    Mix.shell().info("cluster_id,total_nodes,healthy_nodes,overall_health")
    Enum.each(clusters, fn cluster ->
      Mix.shell().info("#{cluster.cluster_id},#{cluster.total_nodes},#{cluster.healthy_nodes},#{cluster.overall_health}")
    end)
  end

  defp print_cluster_csv(status) do
    Mix.shell().info("node_id,status,network,peers,duties")
    Enum.each(status.node_details, fn node ->
      Mix.shell().info("#{node.node_id},#{node.cluster_state.status},#{node.network},#{node.p2p_peers},#{length(node.duties)}")
    end)
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end