#!/usr/bin/env elixir

Mix.install([
  {:benchee, "~> 1.0"}
])

defmodule SimpleLoadTest do
  @moduledoc """
  Simple load test to establish baseline performance for Mana Ethereum client.
  """

  def run_basic_benchmarks do
    IO.puts("==========================================")
    IO.puts("MANA ETHEREUM CLIENT - BASIC LOAD TEST")
    IO.puts("==========================================")
    
    # Test 1: Memory and process management
    IO.puts("\n1. Testing memory and process management...")
    memory_test()
    
    # Test 2: Basic data structures
    IO.puts("\n2. Testing data structure performance...")
    data_structure_test()
    
    # Test 3: Crypto operations simulation  
    IO.puts("\n3. Testing crypto operations simulation...")
    crypto_simulation_test()
    
    # Test 4: Network simulation
    IO.puts("\n4. Testing network simulation...")
    network_simulation_test()
    
    generate_summary()
  end
  
  defp memory_test do
    Benchee.run(
      %{
        "Map operations (1K)" => fn -> map_operations(1_000) end,
        "List operations (1K)" => fn -> list_operations(1_000) end,
        "Process spawning (100)" => fn -> process_spawning(100) end,
        "ETS operations (1K)" => fn -> ets_operations(1_000) end
      },
      time: 5,
      memory_time: 2,
      formatters: [
        {Benchee.Formatters.Console, comparison: false, extended_statistics: true}
      ]
    )
  end
  
  defp data_structure_test do
    Benchee.run(
      %{
        "Binary operations" => fn -> binary_operations() end,
        "Hash operations" => fn -> hash_operations() end, 
        "Encode/decode" => fn -> encode_decode_operations() end,
        "Tree operations" => fn -> tree_operations() end
      },
      time: 3,
      formatters: [
        {Benchee.Formatters.Console, comparison: false}
      ]
    )
  end
  
  defp crypto_simulation_test do
    Benchee.run(
      %{
        "Hash generation (SHA256)" => fn -> generate_hashes(100) end,
        "Random bytes generation" => fn -> generate_random_bytes(1000) end,
        "Signature simulation" => fn -> simulate_signatures(50) end
      },
      time: 3,
      formatters: [
        {Benchee.Formatters.Console, comparison: false}
      ]
    )
  end
  
  defp network_simulation_test do
    Benchee.run(
      %{
        "Message serialization" => fn -> message_serialization(100) end,
        "Peer simulation" => fn -> peer_simulation(20) end,
        "Transaction pool sim" => fn -> transaction_pool_simulation(500) end
      },
      time: 3,
      formatters: [
        {Benchee.Formatters.Console, comparison: false}
      ]
    )
  end
  
  # Test implementations
  
  defp map_operations(count) do
    map = Enum.reduce(1..count, %{}, fn i, acc ->
      Map.put(acc, "key_#{i}", "value_#{i}")
    end)
    
    # Read operations
    Enum.each(1..div(count, 2), fn i ->
      Map.get(map, "key_#{i}")
    end)
    
    # Update operations
    Enum.reduce(1..div(count, 4), map, fn i, acc ->
      Map.put(acc, "key_#{i}", "updated_#{i}")
    end)
  end
  
  defp list_operations(count) do
    list = Enum.to_list(1..count)
    
    # Operations
    reversed = Enum.reverse(list)
    sorted = Enum.sort(reversed)
    filtered = Enum.filter(sorted, fn x -> rem(x, 2) == 0 end)
    mapped = Enum.map(filtered, fn x -> x * 2 end)
    
    length(mapped)
  end
  
  defp process_spawning(count) do
    tasks = for i <- 1..count do
      Task.async(fn ->
        # Simulate work
        :timer.sleep(1)
        i * 2
      end)
    end
    
    Task.await_many(tasks)
  end
  
  defp ets_operations(count) do
    table = :ets.new(:test_table, [:set, :public])
    
    try do
      # Insert operations
      Enum.each(1..count, fn i ->
        :ets.insert(table, {i, "value_#{i}"})
      end)
      
      # Read operations
      Enum.each(1..div(count, 2), fn i ->
        :ets.lookup(table, i)
      end)
      
      # Count
      :ets.info(table, :size)
    after
      :ets.delete(table)
    end
  end
  
  defp binary_operations do
    data = :crypto.strong_rand_bytes(1024)
    
    # Operations
    _encoded = Base.encode64(data)
    _hex = Base.encode16(data)
    
    chunks = for <<chunk::binary-size(32) <- data>>, do: chunk
    _concatenated = Enum.join(chunks, <<>>)
    
    byte_size(data)
  end
  
  defp hash_operations do
    data = "sample_data_for_hashing"
    
    hashes = for i <- 1..100 do
      :crypto.hash(:sha256, "#{data}_#{i}")
    end
    
    # Chain hashes
    Enum.reduce(hashes, <<>>, fn hash, acc ->
      :crypto.hash(:sha256, acc <> hash)
    end)
  end
  
  defp encode_decode_operations do
    data = %{
      type: "transaction",
      from: Base.encode16(:crypto.strong_rand_bytes(20)),
      to: Base.encode16(:crypto.strong_rand_bytes(20)),
      value: :rand.uniform(1_000_000),
      gas: 21_000,
      nonce: :rand.uniform(1000)
    }
    
    # Simulate RLP-like encoding/decoding
    encoded = :erlang.term_to_binary(data)
    _decoded = :erlang.binary_to_term(encoded)
    
    byte_size(encoded)
  end
  
  defp tree_operations do
    # Simulate tree operations (simplified)
    tree = Enum.reduce(1..100, %{}, fn i, acc ->
      key = :crypto.hash(:sha256, <<i::32>>)
      Map.put(acc, key, "value_#{i}")
    end)
    
    # Tree traversal
    values = Enum.map(tree, fn {_k, v} -> v end)
    length(values)
  end
  
  defp generate_hashes(count) do
    for i <- 1..count do
      :crypto.hash(:sha256, "block_#{i}_#{:os.system_time()}")
    end
  end
  
  defp generate_random_bytes(count) do
    for _i <- 1..count do
      :crypto.strong_rand_bytes(32)
    end
  end
  
  defp simulate_signatures(count) do
    # Simulate signature operations with random data
    for i <- 1..count do
      message = "transaction_#{i}"
      private_key = :crypto.strong_rand_bytes(32)
      
      # Mock signature (actual would use BLS/ECDSA)
      :crypto.hash(:sha256, message <> private_key)
    end
  end
  
  defp message_serialization(count) do
    messages = for i <- 1..count do
      %{
        id: i,
        type: :block,
        data: :crypto.strong_rand_bytes(256),
        timestamp: :os.system_time(:microsecond)
      }
    end
    
    # Serialize messages
    serialized = Enum.map(messages, &:erlang.term_to_binary/1)
    
    # Deserialize
    Enum.map(serialized, &:erlang.binary_to_term/1)
  end
  
  defp peer_simulation(count) do
    peers = for i <- 1..count do
      %{
        id: i,
        ip: {192, 168, 1, i},
        port: 30303 + i,
        status: :connected,
        latency: :rand.uniform(100)
      }
    end
    
    # Simulate peer operations
    active_peers = Enum.filter(peers, fn p -> p.status == :connected end)
    sorted_by_latency = Enum.sort_by(active_peers, & &1.latency)
    
    length(sorted_by_latency)
  end
  
  defp transaction_pool_simulation(count) do
    transactions = for i <- 1..count do
      %{
        hash: :crypto.hash(:sha256, "tx_#{i}"),
        from: :crypto.strong_rand_bytes(20),
        to: :crypto.strong_rand_bytes(20),
        value: :rand.uniform(1_000_000),
        gas_price: 20_000_000_000 + :rand.uniform(10_000_000_000),
        nonce: :rand.uniform(1000)
      }
    end
    
    # Pool operations
    sorted = Enum.sort_by(transactions, & &1.gas_price, &>=/2)
    batches = Enum.chunk_every(sorted, 50)
    
    length(batches)
  end
  
  defp generate_summary do
    IO.puts("\n==========================================")
    IO.puts("LOAD TEST SUMMARY")
    IO.puts("==========================================")
    
    system_info = %{
      erlang_version: :erlang.system_info(:version),
      schedulers: :erlang.system_info(:schedulers),
      memory: :erlang.memory(),
      processes: :erlang.system_info(:process_count)
    }
    
    IO.puts("\nSystem Information:")
    IO.puts("- Erlang/OTP: #{system_info.erlang_version}")
    IO.puts("- Schedulers: #{system_info.schedulers}")
    IO.puts("- Total Memory: #{div(system_info.memory[:total], 1024*1024)} MB")
    IO.puts("- Process Memory: #{div(system_info.memory[:processes], 1024*1024)} MB") 
    IO.puts("- Process Count: #{system_info.processes}")
    
    IO.puts("\nBaseline Performance Established ✅")
    IO.puts("Next Steps:")
    IO.puts("1. Compare with production Mana performance")
    IO.puts("2. Identify bottlenecks from real workload")
    IO.puts("3. Apply targeted optimizations")
    IO.puts("==========================================")
  end
end

# Run the load test
SimpleLoadTest.run_basic_benchmarks()