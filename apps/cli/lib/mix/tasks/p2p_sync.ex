defmodule Mix.Tasks.P2pSync do
  @moduledoc """
  Starts P2P blockchain sync with mainnet peers.

  This command initializes a full P2P Ethereum client that:
  - Discovers peers through Kademlia DHT
  - Connects to Ethereum mainnet bootnodes
  - Syncs blocks via P2P protocol (not RPC)
  - Participates in the peer-to-peer network

  Command Line Options:

      `--chain` - Chain to sync (default: mainnet)
      `--discovery` - Enable peer discovery (default: true)
      `--max-peers` - Maximum peer connections (default: 25)
      `--port` - P2P listening port (default: 30303)
      `--sync-mode` - Sync mode: full, fast, warp (default: fast)
      
  Examples:

      mix p2p_sync
      mix p2p_sync --chain mainnet --max-peers 50
      mix p2p_sync --sync-mode warp --port 30304
  """
  use Mix.Task
  require Logger

  @shortdoc "Starts P2P mainnet sync with peer discovery"

  def run(args) do
    case parse_args(args) do
      {:ok, opts} ->
        :ok = Logger.warning("Starting P2P mainnet sync...")
        :ok = Logger.info("Chain: #{opts.chain}")
        :ok = Logger.info("Max peers: #{opts.max_peers}")
        :ok = Logger.info("Sync mode: #{opts.sync_mode}")
        :ok = Logger.info("Discovery: #{opts.discovery}")

        # Configure ExWire for P2P sync
        configure_p2p_sync(opts)

        # Start the P2P sync
        start_p2p_sync(opts)

      {:error, error} ->
        _ = Logger.error("Error: #{error}")
        Logger.flush()
        System.halt(1)
    end
  end

  defp parse_args(args) do
    {parsed, _argv, _errors} =
      OptionParser.parse(args,
        switches: [
          chain: :string,
          discovery: :boolean,
          max_peers: :integer,
          port: :integer,
          sync_mode: :string,
          help: :boolean
        ],
        aliases: [
          h: :help
        ]
      )

    if parsed[:help] do
      IO.puts(@moduledoc)
      System.halt(0)
    end

    opts = %{
      chain: String.to_atom(parsed[:chain] || "mainnet"),
      discovery: parsed[:discovery] != false,
      max_peers: parsed[:max_peers] || 25,
      port: parsed[:port] || 30303,
      sync_mode: String.to_atom(parsed[:sync_mode] || "fast")
    }

    {:ok, opts}
  end

  defp configure_p2p_sync(opts) do
    # Configure ExWire for P2P mainnet sync
    ExWire.Config.configure!(
      chain: opts.chain,
      sync: true,
      discovery: opts.discovery,
      warp: opts.sync_mode == :warp,
      bootnodes: :from_chain,
      protocol_version: 67,
      p2p_version: 5,
      caps: [
        %ExWire.Packet.Capability{name: "eth", version: 67},
        %ExWire.Packet.Capability{name: "eth", version: 66}
      ]
    )

    # Set listening port
    Application.put_env(:ex_wire, :port, opts.port)

    # Configure peer limits
    Application.put_env(:ex_wire, :max_peers, opts.max_peers)

    :ok
  end

  defp start_p2p_sync(opts) do
    # Start ExWire application with P2P sync
    case Application.ensure_all_started(:ex_wire) do
      {:ok, _started} ->
        :ok = Logger.info("P2P sync started successfully")
        :ok = Logger.info("Listening on port #{opts.port}")

        # Log peer discovery status
        if opts.discovery do
          :ok = Logger.info("Peer discovery enabled - finding mainnet peers...")
        else
          :ok = Logger.info("Peer discovery disabled - using bootnodes only")
        end

        # Monitor sync progress
        monitor_sync_progress()

        # Keep the process running
        :timer.sleep(:infinity)

      {:error, {:already_started, _}} ->
        :ok = Logger.info("P2P sync already running")
        monitor_sync_progress()
        :timer.sleep(:infinity)

      {:error, reason} ->
        _ = Logger.error("Failed to start P2P sync: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp monitor_sync_progress do
    # Spawn a process to monitor and log sync progress
    spawn(fn ->
      # Wait 10 seconds before first check
      :timer.sleep(10_000)
      monitor_loop()
    end)
  end

  defp monitor_loop do
    try do
      # Get current sync state with runtime checks
      peer_count =
        if Code.ensure_loaded?(ExWire.PeerSupervisor) and
             function_exported?(ExWire.PeerSupervisor, :connected_peer_count, 0) do
          ExWire.PeerSupervisor.connected_peer_count()
        else
          0
        end

      # Log peer status
      :ok = Logger.info("Connected peers: #{peer_count}")

      # Try to get current block if sync has started
      if Code.ensure_loaded?(ExWire.Sync) and
           function_exported?(ExWire.Sync, :get_state, 0) do
        case ExWire.Sync.get_state() do
          {:ok, sync_state} ->
            current_block = sync_state.current_block_number || 0
            :ok = Logger.info("Current block: #{current_block}")

          _ ->
            :ok = Logger.info("Sync not yet started")
        end
      else
        :ok = Logger.info("Sync module not available")
      end
    rescue
      error ->
        :ok = Logger.debug("Monitor error (expected during startup): #{inspect(error)}")
    end

    # Check again in 30 seconds
    :timer.sleep(30_000)
    monitor_loop()
  end
end
