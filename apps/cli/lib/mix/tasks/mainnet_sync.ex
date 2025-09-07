defmodule Mix.Tasks.MainnetSync do
  @moduledoc """
  Advanced mainnet sync with multiple provider options.

  This task provides comprehensive blockchain synchronization with:
  - P2P networking (default) - True decentralized sync
  - RPC fallback - For cases where P2P is unavailable
  - Hybrid mode - P2P primary with RPC backup
  - Performance monitoring and optimization

  Command Line Options:

      `--provider` - Sync provider: p2p, rpc, hybrid (default: p2p)
      `--chain` - Blockchain network (default: mainnet)
      `--max-peers` - Maximum P2P connections (default: 25) 
      `--rpc-url` - RPC endpoint for RPC/hybrid mode
      `--sync-mode` - Sync type: full, fast, warp (default: fast)
      `--port` - P2P listening port (default: 30303)
      `--discovery` - Enable peer discovery (default: true)
      `--monitor` - Enable performance monitoring (default: true)
      
  Examples:

      # Pure P2P sync (recommended for production)
      mix mainnet_sync
      
      # P2P sync with custom settings
      mix mainnet_sync --max-peers 50 --sync-mode warp
      
      # RPC fallback
      mix mainnet_sync --provider rpc --rpc-url https://eth-mainnet.g.alchemy.com/v2/API_KEY
      
      # Hybrid mode (P2P primary, RPC backup)
      mix mainnet_sync --provider hybrid --rpc-url https://eth-mainnet.g.alchemy.com/v2/API_KEY
  """
  use Mix.Task
  require Logger

  @shortdoc "Advanced mainnet sync with P2P and RPC providers"

  def run(args) do
    case parse_args(args) do
      {:ok, opts} ->
        :ok = Logger.warning("Starting Mana Ethereum mainnet sync...")
        log_sync_config(opts)

        # Start the sync based on provider type
        case opts.provider do
          :p2p -> start_p2p_sync(opts)
          :rpc -> start_rpc_sync(opts)
          :hybrid -> start_hybrid_sync(opts)
        end

      {:error, error} ->
        _ = Logger.error("Configuration error: #{error}")
        Logger.flush()
        System.halt(1)
    end
  end

  defp parse_args(args) do
    {parsed, _argv, errors} =
      OptionParser.parse(args,
        switches: [
          provider: :string,
          chain: :string,
          max_peers: :integer,
          rpc_url: :string,
          sync_mode: :string,
          port: :integer,
          discovery: :boolean,
          monitor: :boolean,
          help: :boolean
        ],
        aliases: [
          p: :provider,
          c: :chain,
          u: :rpc_url,
          h: :help
        ]
      )

    if parsed[:help] || !Enum.empty?(errors) do
      IO.puts(@moduledoc)

      if !Enum.empty?(errors) do
        IO.puts("\nErrors:")
        Enum.each(errors, &IO.puts("  #{inspect(&1)}"))
      end

      System.halt(0)
    end

    with {:ok, provider} <- parse_provider(parsed[:provider]),
         {:ok, _} <- validate_provider_config(provider, parsed[:rpc_url]) do
      opts = %{
        provider: provider,
        chain: String.to_atom(parsed[:chain] || "mainnet"),
        max_peers: parsed[:max_peers] || 25,
        rpc_url: parsed[:rpc_url],
        sync_mode: String.to_atom(parsed[:sync_mode] || "fast"),
        port: parsed[:port] || 30303,
        discovery: parsed[:discovery] != false,
        monitor: parsed[:monitor] != false
      }

      {:ok, opts}
    end
  end

  defp parse_provider(nil), do: {:ok, :p2p}
  defp parse_provider("p2p"), do: {:ok, :p2p}
  defp parse_provider("rpc"), do: {:ok, :rpc}
  defp parse_provider("hybrid"), do: {:ok, :hybrid}

  defp parse_provider(other) do
    {:error, "Invalid provider '#{other}'. Must be: p2p, rpc, or hybrid"}
  end

  defp validate_provider_config(:rpc, nil) do
    {:error, "RPC provider requires --rpc-url option"}
  end

  defp validate_provider_config(:hybrid, nil) do
    {:error, "Hybrid provider requires --rpc-url option for fallback"}
  end

  defp validate_provider_config(_, _), do: {:ok, :valid}

  defp create_eth_capabilities do
    [
      %ExWire.Packet.Capability{name: "eth", version: 67},
      %ExWire.Packet.Capability{name: "eth", version: 66}
    ]
  end

  defp log_sync_config(opts) do
    :ok = Logger.info("═══════════════════════════════════════")
    :ok = Logger.info("    🌐 MANA ETHEREUM CLIENT")
    :ok = Logger.info("═══════════════════════════════════════")
    :ok = Logger.info("Provider: #{String.upcase(to_string(opts.provider))}")
    :ok = Logger.info("Chain: #{opts.chain}")
    :ok = Logger.info("Sync Mode: #{opts.sync_mode}")

    if opts.provider in [:p2p, :hybrid] do
      :ok = Logger.info("Max Peers: #{opts.max_peers}")
      :ok = Logger.info("P2P Port: #{opts.port}")
      :ok = Logger.info("Discovery: #{opts.discovery}")
    end

    if opts.provider in [:rpc, :hybrid] do
      rpc_host = URI.parse(opts.rpc_url || "").host || "undefined"
      :ok = Logger.info("RPC Endpoint: #{rpc_host}")
    end

    :ok = Logger.info("Monitoring: #{opts.monitor}")
    :ok = Logger.info("═══════════════════════════════════════")
  end

  defp start_p2p_sync(opts) do
    :ok = Logger.info("🔗 Starting P2P mainnet sync...")

    # Configure ExWire for P2P
    configure_p2p(opts)

    # Start sync using P2P provider
    provider_args = [
      max_peers: opts.max_peers,
      discovery: opts.discovery
    ]

    case CLI.sync(opts.chain, CLI.BlockProvider.P2P, provider_args) do
      {:ok, _blocktree} ->
        :ok = Logger.info("✅ P2P sync completed successfully!")

      {:error, _reason} ->
        _ = Logger.error("❌ P2P sync failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_rpc_sync(opts) do
    :ok = Logger.info("🌐 Starting RPC mainnet sync...")

    if is_nil(opts.rpc_url) do
      _ = Logger.error("RPC URL is required for RPC sync")
      System.halt(1)
    end

    # Start sync using RPC provider
    case CLI.sync(opts.chain, CLI.BlockProvider.RPC, [opts.rpc_url]) do
      {:ok, _blocktree} ->
        :ok = Logger.info("✅ RPC sync completed successfully!")

      {:error, _reason} ->
        _ = Logger.error("❌ RPC sync failed: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp start_hybrid_sync(opts) do
    :ok = Logger.info("🔄 Starting hybrid mainnet sync (P2P primary, RPC fallback)...")

    configure_p2p(opts)

    # Try P2P first
    p2p_args = [
      max_peers: opts.max_peers,
      discovery: opts.discovery
    ]

    case CLI.sync(opts.chain, CLI.BlockProvider.P2P, p2p_args) do
      {:ok, _blocktree} ->
        :ok = Logger.info("✅ Hybrid sync completed via P2P!")

      {:error, _reason} ->
        :ok = Logger.warning("⚠️  P2P sync failed (#{inspect(reason)}), falling back to RPC...")

        # Fallback to RPC
        case CLI.sync(opts.chain, CLI.BlockProvider.RPC, [opts.rpc_url]) do
          {:ok, _blocktree} ->
            :ok = Logger.info("✅ Hybrid sync completed via RPC fallback!")

          {:error, rpc_reason} ->
            _ = Logger.error("❌ Both P2P and RPC sync failed!")
            _ = Logger.error("   P2P error: #{inspect(reason)}")
            _ = Logger.error("   RPC error: #{inspect(rpc_reason)}")
            System.halt(1)
        end
    end
  end

  defp configure_p2p(opts) do
    # Configure ExWire for P2P networking
    try do
      ExWire.Config.configure!(
        chain: opts.chain,
        sync: true,
        discovery: opts.discovery,
        warp: opts.sync_mode == :warp,
        bootnodes: :from_chain,
        protocol_version: 67,
        p2p_version: 5,
        caps: create_eth_capabilities()
      )

      # Set port configuration
      Application.put_env(:ex_wire, :port, opts.port)
      Application.put_env(:ex_wire, :max_peers, opts.max_peers)

      :ok = Logger.debug("P2P configuration completed")
    rescue
      error ->
        _ = Logger.error("Failed to configure P2P: #{inspect(error)}")
        System.halt(1)
    end
  end
end
