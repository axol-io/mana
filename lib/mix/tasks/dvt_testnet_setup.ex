defmodule Mix.Tasks.DvtTestnetSetup do
  @moduledoc """
  DVT Testnet Validator Setup Task

  This task sets up a complete DVT validator cluster for testnet operation.

  ## Usage

      # Set up a 5-node cluster with 3-of-5 threshold
      mix dvt_testnet_setup --cluster-id "test-cluster-1" --nodes 5 --threshold 3

      # Set up with specific network
      mix dvt_testnet_setup --cluster-id "hoodi-cluster" --network hoodi --nodes 7 --threshold 5

      # Generate configuration only (no startup)
      mix dvt_testnet_setup --cluster-id "config-only" --config-only

      # Set up with custom beacon node
      mix dvt_testnet_setup --cluster-id "custom" --beacon-node "http://my-beacon:5052"

  ## Options

    * `--cluster-id` - Unique identifier for the DVT cluster (required)
    * `--nodes` - Total number of nodes in cluster (default: 5)
    * `--threshold` - Threshold for signatures (default: 3)
    * `--network` - Network to deploy on: hoodi, sepolia, goerli (default: hoodi)
    * `--beacon-node` - Beacon node URL (default: http://localhost:5052)
    * `--config-only` - Generate configuration files only, don't start services
    * `--bootstrap` - Start as bootstrap node
    * `--join` - Join existing cluster with given peers
    * `--monitoring-port` - Base port for monitoring (default: 8080)
    * `--p2p-port` - Base port for P2P networking (default: 9100)

  ## Examples

      # Full cluster setup for Hoodi testnet
      mix dvt_testnet_setup \\
        --cluster-id "production-hoodi-1" \\
        --network hoodi \\
        --nodes 7 \\
        --threshold 5 \\
        --beacon-node "https://hoodi-beacon-api.stakingfacilities.com"

      # Development cluster setup
      mix dvt_testnet_setup \\
        --cluster-id "dev-cluster" \\
        --nodes 3 \\
        --threshold 2 \\
        --config-only

  """

  use Mix.Task
  require Logger

  alias ExWire.DVT.{TestnetValidator, KeyManager, CommunicationSupervisor}

  @switches [
    cluster_id: :string,
    nodes: :integer,
    threshold: :integer,
    network: :string,
    beacon_node: :string,
    config_only: :boolean,
    bootstrap: :boolean,
    join: :string,
    monitoring_port: :integer,
    p2p_port: :integer,
    help: :boolean
  ]

  @aliases [
    c: :cluster_id,
    n: :nodes,
    t: :threshold,
    h: :help
  ]

  def run(args) do
    case parse_args(args) do
      {:ok, opts} ->
        if opts[:help] do
          print_help()
        else
          setup_dvt_cluster(opts)
        end

      {:error, reason} ->
        Mix.shell().error("Error: #{reason}")
        print_help()
        System.halt(1)
    end
  end

  defp parse_args(args) do
    case OptionParser.parse(args, switches: @switches, aliases: @aliases) do
      {opts, [], []} ->
        validate_opts(opts)

      {_opts, extra_args, []} ->
        {:error, "Unknown arguments: #{Enum.join(extra_args, ", ")}"}

      {_opts, _args, invalid} ->
        invalid_opts = Enum.map(invalid, fn {opt, _} -> "--#{opt}" end)
        {:error, "Invalid options: #{Enum.join(invalid_opts, ", ")}"}
    end
  end

  defp validate_opts(opts) do
    with :ok <- validate_required_opts(opts),
         :ok <- validate_cluster_config(opts),
         :ok <- validate_network(opts) do
      {:ok, normalize_opts(opts)}
    end
  end

  defp validate_required_opts(opts) do
    if opts[:cluster_id] do
      :ok
    else
      {:error, "cluster-id is required"}
    end
  end

  defp validate_cluster_config(opts) do
    nodes = opts[:nodes] || 5
    threshold = opts[:threshold] || 3

    cond do
      nodes < 3 ->
        {:error, "Minimum 3 nodes required for DVT cluster"}

      nodes > 15 ->
        {:error, "Maximum 15 nodes supported"}

      threshold < 2 ->
        {:error, "Minimum threshold of 2 required"}

      threshold > nodes ->
        {:error, "Threshold cannot exceed total nodes"}

      threshold <= nodes / 2 ->
        {:error, "Threshold must be more than half of total nodes"}

      true ->
        :ok
    end
  end

  defp validate_network(opts) do
    network = String.to_atom(opts[:network] || "hoodi")

    if network in [:hoodi, :sepolia, :goerli] do
      :ok
    else
      {:error, "Unsupported network: #{network}. Use hoodi, sepolia, or goerli"}
    end
  end

  defp normalize_opts(opts) do
    opts
    |> Keyword.put_new(:nodes, 5)
    |> Keyword.put_new(:threshold, 3)
    |> Keyword.put_new(:network, "hoodi")
    |> Keyword.put_new(:beacon_node, "http://localhost:5052")
    |> Keyword.put_new(:monitoring_port, 8080)
    |> Keyword.put_new(:p2p_port, 9100)
    |> Keyword.update!(:network, &String.to_atom/1)
  end

  defp setup_dvt_cluster(opts) do
    Mix.shell().info("Setting up DVT testnet validator cluster...")
    Mix.shell().info("Cluster ID: #{opts[:cluster_id]}")
    Mix.shell().info("Network: #{opts[:network]}")
    Mix.shell().info("Nodes: #{opts[:nodes]} (threshold: #{opts[:threshold]})")

    # Start the applications
    start_applications()

    # Generate cluster configuration
    with {:ok, cluster_config} <- generate_cluster_config(opts),
         {:ok, validator_configs} <- generate_node_configs(cluster_config, opts),
         :ok <- write_configuration_files(cluster_config, validator_configs),
         {:ok, _} <- setup_cluster_keys(cluster_config),
         :ok <- setup_monitoring(opts) do

      if opts[:config_only] do
        Mix.shell().info("✅ Configuration files generated successfully!")
        print_configuration_summary(cluster_config, validator_configs)
      else
        case start_validator_cluster(validator_configs) do
          {:ok, pids} ->
            Mix.shell().info("✅ DVT validator cluster started successfully!")
            print_cluster_info(cluster_config, pids)
            wait_for_shutdown()

          {:error, reason} ->
            Mix.shell().error("❌ Failed to start validator cluster: #{reason}")
            System.halt(1)
        end
      end
    else
      {:error, reason} ->
        Mix.shell().error("❌ Cluster setup failed: #{reason}")
        System.halt(1)
    end
  end

  defp start_applications do
    Application.ensure_all_started(:ex_wire)
    Application.ensure_all_started(:exth_crypto)
    Application.ensure_all_started(:merkle_patricia_tree)
  end

  defp generate_cluster_config(opts) do
    cluster_config = %{
      cluster_id: opts[:cluster_id],
      network: opts[:network],
      total_nodes: opts[:nodes],
      threshold: opts[:threshold],
      beacon_node_url: opts[:beacon_node],
      monitoring_port: opts[:monitoring_port],
      p2p_port: opts[:p2p_port],
      created_at: System.system_time(:second),
      peers: generate_peer_addresses(opts)
    }

    {:ok, cluster_config}
  end

  defp generate_node_configs(cluster_config, opts) do
    validator_configs = Enum.map(1..cluster_config.total_nodes, fn node_id ->
      %{
        cluster_id: cluster_config.cluster_id,
        node_id: node_id,
        threshold: cluster_config.threshold,
        total_nodes: cluster_config.total_nodes,
        network: cluster_config.network,
        beacon_node_url: cluster_config.beacon_node_url,
        p2p_port: cluster_config.p2p_port + node_id,
        monitoring_port: cluster_config.monitoring_port + node_id,
        peers: cluster_config.peers,
        data_dir: Path.join("data", "dvt-node-#{node_id}"),
        log_file: Path.join("logs", "dvt-node-#{node_id}.log")
      }
    end)

    {:ok, validator_configs}
  end

  defp generate_peer_addresses(opts) do
    # Generate multiaddresses for peer discovery
    Enum.map(1..opts[:nodes], fn node_id ->
      port = opts[:p2p_port] + node_id
      "/ip4/127.0.0.1/tcp/#{port}/p2p/16Uiu2HAm#{generate_peer_id()}"
    end)
  end

  defp generate_peer_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
    |> String.slice(0, 45)
  end

  defp write_configuration_files(cluster_config, validator_configs) do
    # Create directories
    File.mkdir_p!("config/dvt")
    File.mkdir_p!("data")
    File.mkdir_p!("logs")

    # Write cluster configuration
    cluster_file = "config/dvt/cluster-#{cluster_config.cluster_id}.json"
    File.write!(cluster_file, Jason.encode!(cluster_config, pretty: true))

    # Write individual node configurations
    Enum.each(validator_configs, fn config ->
      node_file = "config/dvt/node-#{config.cluster_id}-#{config.node_id}.json"
      File.write!(node_file, Jason.encode!(config, pretty: true))
    end)

    # Write deployment script
    deployment_script = generate_deployment_script(cluster_config, validator_configs)
    File.write!("scripts/deploy-dvt-#{cluster_config.cluster_id}.sh", deployment_script)
    File.chmod!("scripts/deploy-dvt-#{cluster_config.cluster_id}.sh", 0o755)

    Mix.shell().info("📄 Configuration files written:")
    Mix.shell().info("  - #{cluster_file}")
    Mix.shell().info("  - config/dvt/node-*.json (#{length(validator_configs)} files)")
    Mix.shell().info("  - scripts/deploy-dvt-#{cluster_config.cluster_id}.sh")

    :ok
  end

  defp setup_cluster_keys(cluster_config) do
    Mix.shell().info("🔑 Generating DVT cluster keys...")

    # Generate distributed keys for the cluster
    case KeyManager.create_cluster(
      cluster_config.cluster_id,
      :crypto.strong_rand_bytes(32),
      cluster_config.threshold,
      cluster_config.total_nodes,
      cluster_config.peers
    ) do
      {:ok, key_data} ->
        # Write key shares to secure files
        Enum.each(1..cluster_config.total_nodes, fn node_id ->
          key_file = "data/dvt-node-#{node_id}/keyshare.json"
          File.mkdir_p!(Path.dirname(key_file))
          
          key_share = %{
            node_id: node_id,
            cluster_id: cluster_config.cluster_id,
            key_share: Map.get(key_data.key_shares, node_id),
            validator_pubkey: key_data.validator_pubkey,
            threshold: cluster_config.threshold,
            created_at: System.system_time(:second)
          }
          
          File.write!(key_file, Jason.encode!(key_share, pretty: true))
          File.chmod!(key_file, 0o600) # Restrict permissions
        end)

        Mix.shell().info("✅ DVT keys generated and distributed")
        {:ok, key_data}

      {:error, reason} ->
        {:error, "Key generation failed: #{reason}"}
    end
  end

  defp setup_monitoring(opts) do
    # Generate Prometheus configuration
    prometheus_config = generate_prometheus_config(opts)
    File.write!("config/prometheus-dvt-#{opts[:cluster_id]}.yml", prometheus_config)

    # Generate Grafana dashboard
    grafana_dashboard = generate_grafana_dashboard(opts)
    File.write!("monitoring/grafana-dashboard-#{opts[:cluster_id]}.json", grafana_dashboard)

    Mix.shell().info("📊 Monitoring configuration generated")
    :ok
  end

  defp start_validator_cluster(validator_configs) do
    Mix.shell().info("🚀 Starting validator nodes...")

    # Start Registry for validator processes
    Registry.start_link(keys: :unique, name: ExWire.DVT.TestnetValidatorRegistry)

    # Start each validator node
    results = Enum.map(validator_configs, fn config ->
      case TestnetValidator.start_validator(config) do
        {:ok, pid} ->
          Mix.shell().info("  ✅ Node #{config.node_id} started (PID: #{inspect(pid)})")
          {:ok, {config.node_id, pid}}

        {:error, reason} ->
          Mix.shell().error("  ❌ Node #{config.node_id} failed: #{reason}")
          {:error, {config.node_id, reason}}
      end
    end)

    case Enum.split_with(results, fn {status, _} -> status == :ok end) do
      {successes, []} ->
        pids = Enum.map(successes, fn {:ok, {node_id, pid}} -> {node_id, pid} end)
        {:ok, pids}

      {_successes, failures} ->
        failed_nodes = Enum.map(failures, fn {:error, {node_id, reason}} -> 
          "Node #{node_id}: #{reason}"
        end)
        {:error, "Failed to start nodes: #{Enum.join(failed_nodes, ", ")}"}
    end
  end

  defp print_configuration_summary(cluster_config, validator_configs) do
    Mix.shell().info("""

    📋 DVT Cluster Configuration Summary:
    =====================================
    
    Cluster ID: #{cluster_config.cluster_id}
    Network: #{cluster_config.network}
    Total Nodes: #{cluster_config.total_nodes}
    Threshold: #{cluster_config.threshold}
    Beacon Node: #{cluster_config.beacon_node_url}
    
    Node Configuration:
    """)

    Enum.each(validator_configs, fn config ->
      Mix.shell().info("  • Node #{config.node_id}: P2P=#{config.p2p_port}, Monitor=#{config.monitoring_port}")
    end)

    Mix.shell().info("""
    
    📁 Files Generated:
    - Configuration: config/dvt/cluster-#{cluster_config.cluster_id}.json
    - Node configs: config/dvt/node-*.json
    - Deployment script: scripts/deploy-dvt-#{cluster_config.cluster_id}.sh
    - Key shares: data/dvt-node-*/keyshare.json
    - Monitoring: config/prometheus-dvt-#{cluster_config.cluster_id}.yml
    
    🚀 Next Steps:
    1. Review generated configuration files
    2. Run deployment script: ./scripts/deploy-dvt-#{cluster_config.cluster_id}.sh
    3. Monitor cluster: http://localhost:#{cluster_config.monitoring_port}/metrics
    """)
  end

  defp print_cluster_info(cluster_config, pids) do
    Mix.shell().info("""

    🎉 DVT Validator Cluster Running!
    ==================================
    
    Cluster ID: #{cluster_config.cluster_id}
    Network: #{cluster_config.network}
    Active Nodes: #{length(pids)}
    
    Running Nodes:
    """)

    Enum.each(pids, fn {node_id, pid} ->
      monitoring_port = cluster_config.monitoring_port + node_id
      Mix.shell().info("  • Node #{node_id} (PID: #{inspect(pid)})")
      Mix.shell().info("    - Metrics: http://localhost:#{monitoring_port}/metrics")
      Mix.shell().info("    - Logs: logs/dvt-node-#{node_id}.log")
    end)

    Mix.shell().info("""
    
    📊 Monitoring:
    - Cluster status: mix dvt_status --cluster-id #{cluster_config.cluster_id}
    - Performance: mix dvt_metrics --cluster-id #{cluster_config.cluster_id}
    - Prometheus: config/prometheus-dvt-#{cluster_config.cluster_id}.yml
    
    Press Ctrl+C to shutdown cluster
    """)
  end

  defp wait_for_shutdown do
    Process.flag(:trap_exit, true)
    
    receive do
      {:EXIT, _pid, _reason} -> :ok
    after
      :infinity -> :ok
    end
  end

  defp generate_deployment_script(cluster_config, validator_configs) do
    """
    #!/bin/bash
    # DVT Cluster Deployment Script
    # Generated for cluster: #{cluster_config.cluster_id}
    
    set -e
    
    echo "🚀 Deploying DVT Validator Cluster: #{cluster_config.cluster_id}"
    echo "Network: #{cluster_config.network}"
    echo "Nodes: #{cluster_config.total_nodes} (threshold: #{cluster_config.threshold})"
    
    # Create directories
    mkdir -p data logs
    #{Enum.map(validator_configs, fn config ->
      "mkdir -p #{config.data_dir}"
    end) |> Enum.join("\n")}
    
    # Start validator nodes in background
    #{Enum.map(validator_configs, fn config ->
      """
      echo "Starting Node #{config.node_id}..."
      MIX_ENV=prod elixir -S mix dvt_testnet_validator \\
        --config config/dvt/node-#{config.cluster_id}-#{config.node_id}.json \\
        --daemon \\
        --pidfile data/dvt-node-#{config.node_id}/node.pid \\
        --logfile #{config.log_file} &
      """
    end) |> Enum.join("\n")}
    
    # Wait for all nodes to start
    sleep 10
    
    # Verify cluster health
    echo "🔍 Verifying cluster health..."
    mix dvt_status --cluster-id #{cluster_config.cluster_id}
    
    echo "✅ DVT Cluster deployed successfully!"
    echo "Monitor with: mix dvt_status --cluster-id #{cluster_config.cluster_id}"
    """
  end

  defp generate_prometheus_config(opts) do
    """
    global:
      scrape_interval: 15s

    scrape_configs:
      - job_name: 'dvt-validator-#{opts[:cluster_id]}'
        static_configs:
          - targets:
    #{Enum.map(1..opts[:nodes], fn node_id ->
      "            - 'localhost:#{opts[:monitoring_port] + node_id}'"
    end) |> Enum.join("\n")}
        metrics_path: /metrics
        scrape_interval: 10s
    """
  end

  defp generate_grafana_dashboard(opts) do
    Jason.encode!(%{
      dashboard: %{
        title: "DVT Cluster #{opts[:cluster_id]}",
        tags: ["dvt", "validator", opts[:network]],
        panels: [
          %{
            title: "Cluster Health",
            type: "stat",
            targets: [%{expr: "dvt_cluster_health{cluster_id=\"#{opts[:cluster_id]}\"}"}]
          },
          %{
            title: "Consensus Latency",
            type: "graph",
            targets: [%{expr: "dvt_consensus_latency{cluster_id=\"#{opts[:cluster_id]}\"}"}]
          }
        ]
      }
    }, pretty: true)
  end

  defp print_help do
    Mix.shell().info(@moduledoc)
  end
end