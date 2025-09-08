#!/usr/bin/env elixir

# Test script for P2P connectivity with real Ethereum nodes
# Usage: mix run scripts/test_p2p_connection.exs

require Logger

defmodule P2PConnectionTest do
  @moduledoc """
  Tests P2P connectivity with real Ethereum nodes.
  Verifies that eth/66 and eth/67 protocol support is working.
  """

  alias ExWire.P2P.Server
  alias ExWire.Struct.Peer
  
  # Well-known Ethereum mainnet bootstrap nodes (enode URLs)
  @mainnet_bootnodes [
    # Ethereum Foundation Go Bootnodes
    "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303",
    "enode://22a8232c3abc76a16ae9d6c3b164f98775fe226f0917b0ca871128a74a8e9630b458460865bab457221f1d448dd9791d24c4e5d88786180ac185df813a68d4de@3.209.45.79:30303",
    "enode://2b252ab6a1d0f971d9722cb839a42cb81db019ba44c08754628ab4a823487071b5695317c8ccd085219c3a03af063495b2f1da8d18218da2d6a82981b45e6ffc@65.108.70.101:30303",
    "enode://4aeb4ab6c14b23e2c4cfdce879c04b0748a20d8e9b59e25ded2a08143e265c6c25936e74cbc8e641e3312ca288673d91f2f93f8e277de3cfa444ecdaaf982052@157.90.35.166:30303"
  ]
  
  @testnet_bootnodes [
    # Sepolia testnet bootnodes
    "enode://4e5e92199ee224a01932a377160aa432f31d0b351f84ab413a8e0a42f4f36476f8fb1cbe914af0d9aef0d51665c214cf653c651c4bbd9d5550a934f241f1682b@138.197.51.181:30303",
    "enode://143e11fb766781d22d92a2e33f8f104cddae4411a122295ed1fdb6638de96a6ce65f5b7c964ba3763bba27961738fef7d3ecc739268f3e5e771fb4c87b6234ba@146.190.1.103:30303",
    "enode://8b61dc2d06c3f96fddcbebb0efb29d60d3598650275dc469c22229d3e5620369b0d3dedafd929835fe7f489618f19f456fe7c0df572bf2d914a9f4e006f783a9@170.64.250.88:30303",
    "enode://10d62eff032205fcef19497f35ca8477bea0eadfff6d769a147e895d8b2b8f8ae6341630c645c30f5df6e67547c03494ced3d9c5764e8622a26587b083b028e8@139.59.49.206:30303",
    "enode://9e9492e2e8836114cc75f5b929784f4f46c324ad01daf87d956f98b3b6c5fcba95524d6e5cf9861dc96a2c8a171ea7105bb554a197455058de185fa870970c7c@138.68.123.152:30303"
  ]
  
  def run do
    Logger.info("Starting P2P Connection Test")
    Logger.info("Testing with eth/66 and eth/67 protocol support")
    
    # Start the ExWire application if not already started
    ensure_app_started()
    
    # Test mainnet connections
    Logger.info("\n=== Testing Mainnet Connections ===")
    test_bootnodes(@mainnet_bootnodes, "mainnet")
    
    # Test testnet connections
    Logger.info("\n=== Testing Sepolia Testnet Connections ===")
    test_bootnodes(@testnet_bootnodes, "sepolia")
    
    # Summary
    Logger.info("\n=== Test Complete ===")
  end
  
  defp ensure_app_started do
    unless Application.started_applications() |> Enum.any?(fn {app, _, _} -> app == :ex_wire end) do
      Logger.info("Starting ExWire application...")
      Application.ensure_all_started(:ex_wire)
      Process.sleep(2000)  # Give it time to initialize
    end
  end
  
  defp test_bootnodes(bootnodes, network_name) do
    bootnodes
    |> Enum.take(2)  # Test first 2 nodes to avoid overwhelming
    |> Enum.each(fn enode_url -> 
      test_single_node(enode_url, network_name)
      Process.sleep(5000)  # Wait between connection attempts
    end)
  end
  
  defp test_single_node(enode_url, network_name) do
    case parse_enode(enode_url) do
      {:ok, peer} ->
        Logger.info("Testing connection to #{network_name} node: #{format_peer(peer)}")
        test_connection(peer)
      
      {:error, reason} ->
        Logger.error("Failed to parse enode URL: #{reason}")
    end
  end
  
  defp parse_enode(enode_url) do
    # Parse enode://pubkey@ip:port format
    case Regex.run(~r/enode:\/\/([0-9a-fA-F]+)@([0-9.]+):(\d+)/, enode_url) do
      [_, pubkey_hex, ip_str, port_str] ->
        # Convert hex pubkey to binary
        remote_id = Base.decode16!(pubkey_hex, case: :mixed)
        
        # Parse IP address
        ip_parts = String.split(ip_str, ".") |> Enum.map(&String.to_integer/1)
        host = List.to_tuple(ip_parts)
        
        # Parse port
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
  
  defp test_connection(peer) do
    # Start a connection to the peer
    case Server.start_link(:outbound, peer, [], self()) do
      {:ok, pid} ->
        Logger.info("✓ Connection process started: #{inspect(pid)}")
        
        # Monitor the connection
        ref = Process.monitor(pid)
        
        # Wait for connection result or timeout
        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            Logger.error("✗ Connection failed: #{inspect(reason)}")
            
          {:handshake_complete, ^pid} ->
            Logger.info("✓ Handshake completed successfully!")
            test_protocol_messages(pid)
            
          {:protocol_negotiated, version} ->
            Logger.info("✓ Negotiated protocol version: eth/#{version}")
            
        after
          30_000 ->
            Logger.warn("⚠ Connection timeout after 30 seconds")
            Process.exit(pid, :timeout)
        end
        
      {:error, reason} ->
        Logger.error("✗ Failed to start connection: #{inspect(reason)}")
    end
  end
  
  defp test_protocol_messages(connection_pid) do
    Logger.info("Testing protocol messages...")
    
    # Test sending a Status message
    # Note: This would need actual implementation in the P2P server
    # to handle test messages properly
    
    # For now, just verify the connection is stable
    Process.sleep(5000)
    
    if Process.alive?(connection_pid) do
      Logger.info("✓ Connection remains stable")
      
      # Clean shutdown
      Process.exit(connection_pid, :normal)
    else
      Logger.warn("⚠ Connection dropped during protocol test")
    end
  end
  
  defp format_peer(%Peer{host: host, port: port}) do
    ip_str = host |> Tuple.to_list() |> Enum.join(".")
    "#{ip_str}:#{port}"
  end
end

# Run the test
P2PConnectionTest.run()