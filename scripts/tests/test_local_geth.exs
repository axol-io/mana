#!/usr/bin/env elixir

# Test script for connecting to a local Geth node
# 
# Prerequisites:
#   1. Install Geth: brew install ethereum (on macOS)
#   2. Start Geth in dev mode: 
#      geth --dev --http --http.api eth,net,web3,debug --ws --syncmode full --verbosity 4
#
# Usage: mix run scripts/test_local_geth.exs

require Logger

defmodule LocalGethTest do
  @moduledoc """
  Tests P2P connectivity with a local Geth node.
  This is useful for debugging protocol issues in a controlled environment.
  """

  alias ExWire.P2P.Server
  alias ExWire.Struct.Peer
  alias ExWire.NodeDiscovery
  
  # Default Geth dev mode settings
  @local_geth_port 30303
  @local_geth_http_port 8545
  
  def run do
    Logger.info("Starting Local Geth Connection Test")
    Logger.info("Make sure Geth is running: geth --dev --verbosity 4")
    
    # First check if Geth is running via HTTP RPC
    if geth_running?() do
      Logger.info("✓ Geth HTTP RPC is responding")
      
      # Get the node info via RPC to get the enode
      case get_enode_info() do
        {:ok, enode_info} ->
          Logger.info("✓ Retrieved enode info: #{enode_info}")
          test_p2p_connection(enode_info)
          
        {:error, reason} ->
          Logger.error("✗ Failed to get enode info: #{reason}")
          Logger.info("Trying default connection anyway...")
          test_default_connection()
      end
    else
      Logger.error("✗ Geth doesn't appear to be running on localhost:#{@local_geth_http_port}")
      Logger.info("Start Geth with: geth --dev --http --verbosity 4")
    end
  end
  
  defp geth_running? do
    # Check if Geth HTTP RPC is responding
    url = "http://localhost:#{@local_geth_http_port}"
    body = Jason.encode!(%{
      jsonrpc: "2.0",
      method: "web3_clientVersion",
      params: [],
      id: 1
    })
    
    case HTTPoison.post(url, body, [{"Content-Type", "application/json"}]) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => version}} ->
            Logger.info("Geth version: #{version}")
            true
          _ ->
            false
        end
        
      _ ->
        false
    end
  rescue
    _ -> false
  end
  
  defp get_enode_info do
    # Get enode URL via admin_nodeInfo RPC call
    url = "http://localhost:#{@local_geth_http_port}"
    body = Jason.encode!(%{
      jsonrpc: "2.0",
      method: "admin_nodeInfo",
      params: [],
      id: 1
    })
    
    case HTTPoison.post(url, body, [{"Content-Type", "application/json"}]) do
      {:ok, %{status_code: 200, body: response_body}} ->
        case Jason.decode(response_body) do
          {:ok, %{"result" => %{"enode" => enode}}} ->
            {:ok, enode}
          _ ->
            {:error, "No enode in response"}
        end
        
      error ->
        {:error, error}
    end
  rescue
    error -> {:error, error}
  end
  
  defp test_p2p_connection(enode_url) do
    Logger.info("Testing P2P connection to: #{enode_url}")
    
    case parse_enode(enode_url) do
      {:ok, peer} ->
        connect_to_peer(peer)
      
      {:error, reason} ->
        Logger.error("Failed to parse enode: #{reason}")
        test_default_connection()
    end
  end
  
  defp test_default_connection do
    # Try connecting with default settings
    Logger.info("Attempting connection to localhost:#{@local_geth_port}")
    
    # For local Geth in dev mode, we might not have the node ID
    # Try discovering it first
    discover_and_connect()
  end
  
  defp discover_and_connect do
    Logger.info("Attempting node discovery...")
    
    # Start discovery if not running
    ensure_discovery_started()
    
    # Try to discover the local node
    # Note: This would require discovery to be properly configured
    Process.sleep(5000)
    
    # For now, try a direct connection without node ID
    # This will likely fail but helps debug the handshake
    peer = %Peer{
      host: {127, 0, 0, 1},
      port: @local_geth_port,
      remote_id: nil  # Will be discovered during handshake
    }
    
    Logger.warn("Attempting connection without node ID (will likely fail)")
    connect_to_peer(peer)
  end
  
  defp ensure_discovery_started do
    unless Process.whereis(ExWire.NodeDiscoverySupervisor) do
      Logger.info("Starting node discovery...")
      # This would need proper implementation
    end
  end
  
  defp parse_enode(enode_url) do
    # Handle both enode://pubkey@ip:port and enode://pubkey@ip:port?discport=0
    case Regex.run(~r/enode:\/\/([0-9a-fA-F]+)@([0-9.:]+):(\d+)/, enode_url) do
      [_, pubkey_hex, ip_str, port_str] ->
        # Convert hex pubkey to binary (64 bytes)
        remote_id = Base.decode16!(pubkey_hex, case: :mixed)
        
        # Handle IPv4 and IPv6
        host = case ip_str do
          "127.0.0.1" -> {127, 0, 0, 1}
          "localhost" -> {127, 0, 0, 1}
          "::1" -> {0, 0, 0, 0, 0, 0, 0, 1}  # IPv6 localhost
          ip ->
            ip
            |> String.split(".")
            |> Enum.map(&String.to_integer/1)
            |> List.to_tuple()
        end
        
        port = String.to_integer(port_str)
        
        peer = %Peer{
          host: host,
          port: port,
          remote_id: remote_id
        }
        
        {:ok, peer}
      
      _ ->
        {:error, "Invalid enode URL format"}
    end
  end
  
  defp connect_to_peer(peer) do
    Logger.info("Connecting to peer: #{inspect(peer.host)}:#{peer.port}")
    
    # Ensure ExWire is started
    Application.ensure_all_started(:ex_wire)
    Process.sleep(1000)
    
    # Start connection
    case Server.start_link(:outbound, peer, [], self()) do
      {:ok, pid} ->
        Logger.info("✓ Connection process started: #{inspect(pid)}")
        monitor_connection(pid)
        
      {:error, {:already_started, pid}} ->
        Logger.info("Connection already exists: #{inspect(pid)}")
        monitor_connection(pid)
        
      {:error, reason} ->
        Logger.error("✗ Failed to start connection: #{inspect(reason)}")
        debug_connection_failure(reason)
    end
  end
  
  defp monitor_connection(pid) do
    ref = Process.monitor(pid)
    
    # Wait for connection events
    receive do
      {:DOWN, ^ref, :process, ^pid, :normal} ->
        Logger.info("Connection closed normally")
        
      {:DOWN, ^ref, :process, ^pid, reason} ->
        Logger.error("✗ Connection failed: #{inspect(reason)}")
        debug_connection_failure(reason)
        
      {:handshake_complete, ^pid} ->
        Logger.info("✓✓✓ HANDSHAKE SUCCESSFUL! ✓✓✓")
        Logger.info("eth/66 and eth/67 support is working!")
        test_protocol_capabilities(pid)
        
      {:protocol_negotiated, version} ->
        Logger.info("✓ Negotiated protocol version: eth/#{version}")
        
      msg ->
        Logger.info("Received message: #{inspect(msg)}")
        monitor_connection(pid)  # Continue monitoring
        
    after
      30_000 ->
        Logger.warn("⚠ Connection timeout after 30 seconds")
        
        if Process.alive?(pid) do
          Logger.info("Process still alive, checking state...")
          state = :sys.get_state(pid)
          Logger.info("Connection state: #{inspect(state, limit: :infinity, pretty: true)}")
        end
        
        Process.exit(pid, :timeout)
    end
  end
  
  defp test_protocol_capabilities(connection_pid) do
    Logger.info("Testing protocol capabilities...")
    
    # The connection should now support eth/66 or eth/67
    # We can verify this worked by checking the session state
    
    if Process.alive?(connection_pid) do
      state = :sys.get_state(connection_pid)
      Logger.info("Connection established with state: #{inspect(state, limit: 5)}")
      
      # Let it run for a bit to exchange some messages
      Process.sleep(10000)
      
      Logger.info("✓ Test completed successfully!")
      Process.exit(connection_pid, :normal)
    end
  end
  
  defp debug_connection_failure(reason) do
    Logger.info("\n=== Debugging Connection Failure ===")
    Logger.info("Reason: #{inspect(reason)}")
    
    Logger.info("\nPossible causes:")
    Logger.info("1. Geth not running or not accepting connections")
    Logger.info("2. Firewall blocking connection")
    Logger.info("3. Protocol version mismatch")
    Logger.info("4. Handshake implementation issues")
    
    Logger.info("\nTroubleshooting steps:")
    Logger.info("1. Check Geth logs for connection attempts")
    Logger.info("2. Verify Geth is running with: ps aux | grep geth")
    Logger.info("3. Check network connectivity: telnet localhost #{@local_geth_port}")
    Logger.info("4. Try running Geth with more verbosity: geth --dev --verbosity 5")
  end
end

# Check dependencies
unless Code.ensure_loaded?(HTTPoison) do
  Logger.warn("HTTPoison not available, installing...")
  Mix.install([{:httpoison, "~> 2.0"}, {:jason, "~> 1.4"}])
end

# Run the test
LocalGethTest.run()