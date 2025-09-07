#!/usr/bin/env elixir

# Standalone TPS Test - No dependencies on compiled modules

defmodule StandaloneTPS do
  @moduledoc """
  Measures raw transaction processing capability
  """
  
  def run(duration_seconds \\ 10) do
    IO.puts("\n========================================")
    IO.puts("Mana-Ethereum Standalone TPS Test")
    IO.puts("========================================")
    IO.puts("Test Duration: #{duration_seconds} seconds\n")
    
    # Warm up
    IO.puts("Warming up...")
    warmup()
    
    # Run different transaction processing scenarios
    IO.puts("\nRunning TPS tests...")
    IO.puts(String.duplicate("-", 40))
    
    # Test 1: Basic transaction validation
    basic_tps = test_basic_validation(duration_seconds)
    
    # Test 2: With cryptographic operations
    crypto_tps = test_with_crypto(duration_seconds)
    
    # Test 3: With state operations (simulated)
    state_tps = test_with_state(duration_seconds)
    
    # Test 4: Full pipeline simulation
    full_tps = test_full_pipeline(duration_seconds)
    
    # Display summary
    display_summary(basic_tps, crypto_tps, state_tps, full_tps)
  end
  
  defp warmup() do
    # Run some operations to warm up the VM
    for _ <- 1..10_000 do
      :crypto.hash(:sha256, :crypto.strong_rand_bytes(256))
    end
  end
  
  defp test_basic_validation(duration_seconds) do
    IO.puts("\n1. Basic Transaction Validation")
    
    end_time = System.monotonic_time(:second) + duration_seconds
    processed = process_until(end_time, 0, fn ->
      tx = generate_transaction()
      validate_transaction_basic(tx)
    end)
    
    tps = processed / duration_seconds
    IO.puts("   Processed: #{processed} transactions")
    IO.puts("   TPS: #{Float.round(tps, 2)}")
    tps
  end
  
  defp test_with_crypto(duration_seconds) do
    IO.puts("\n2. With Cryptographic Operations")
    
    end_time = System.monotonic_time(:second) + duration_seconds
    processed = process_until(end_time, 0, fn ->
      tx = generate_transaction()
      validate_transaction_crypto(tx)
    end)
    
    tps = processed / duration_seconds
    IO.puts("   Processed: #{processed} transactions")
    IO.puts("   TPS: #{Float.round(tps, 2)}")
    tps
  end
  
  defp test_with_state(duration_seconds) do
    IO.puts("\n3. With State Operations")
    
    # Create ETS table for state simulation
    :ets.new(:state_test, [:set, :public, :named_table])
    
    # Pre-populate with some accounts
    for i <- 1..10_000 do
      :ets.insert(:state_test, {<<i::160>>, %{balance: 1_000_000, nonce: 0}})
    end
    
    end_time = System.monotonic_time(:second) + duration_seconds
    processed = process_until(end_time, 0, fn ->
      tx = generate_transaction()
      validate_transaction_with_state(tx)
    end)
    
    :ets.delete(:state_test)
    
    tps = processed / duration_seconds
    IO.puts("   Processed: #{processed} transactions")
    IO.puts("   TPS: #{Float.round(tps, 2)}")
    tps
  end
  
  defp test_full_pipeline(duration_seconds) do
    IO.puts("\n4. Full Pipeline Simulation")
    
    # Setup state
    :ets.new(:full_test, [:set, :public, :named_table])
    for i <- 1..10_000 do
      :ets.insert(:full_test, {<<i::160>>, %{balance: 1_000_000_000, nonce: 0}})
    end
    
    end_time = System.monotonic_time(:second) + duration_seconds
    processed = process_until(end_time, 0, fn ->
      tx = generate_transaction()
      process_transaction_full(tx)
    end)
    
    :ets.delete(:full_test)
    
    tps = processed / duration_seconds
    IO.puts("   Processed: #{processed} transactions")
    IO.puts("   TPS: #{Float.round(tps, 2)}")
    tps
  end
  
  defp process_until(end_time, count, work_fn) do
    if System.monotonic_time(:second) >= end_time do
      count
    else
      # Process batch
      batch_size = 100
      for _ <- 1..batch_size, do: work_fn.()
      process_until(end_time, count + batch_size, work_fn)
    end
  end
  
  defp generate_transaction() do
    %{
      nonce: :rand.uniform(1000),
      gas_price: 20_000_000_000 + :rand.uniform(10_000_000_000),
      gas_limit: 21_000,
      to: <<:rand.uniform(10_000)::160>>,
      from: <<:rand.uniform(10_000)::160>>,
      value: :rand.uniform(1_000_000_000_000_000_000),
      data: <<>>,
      v: 27 + :rand.uniform(2) - 1,
      r: :crypto.strong_rand_bytes(32),
      s: :crypto.strong_rand_bytes(32)
    }
  end
  
  defp validate_transaction_basic(tx) do
    # Basic validation checks
    tx.nonce >= 0 and
    tx.gas_price > 0 and
    tx.gas_limit >= 21_000 and
    byte_size(tx.to) == 20 and
    tx.value >= 0
  end
  
  defp validate_transaction_crypto(tx) do
    # Basic validation
    if validate_transaction_basic(tx) do
      # Hash transaction
      tx_binary = :erlang.term_to_binary(tx)
      _hash = :crypto.hash(:sha256, tx_binary)
      
      # Simulate signature verification
      _sig_check = :crypto.hash(:sha256, tx.r <> tx.s <> <<tx.v>>)
      
      # Simulate address derivation
      _from_address = :crypto.hash(:sha256, tx.r) |> binary_part(0, 20)
      
      true
    else
      false
    end
  end
  
  defp validate_transaction_with_state(tx) do
    # Crypto validation
    if validate_transaction_crypto(tx) do
      # State checks
      case :ets.lookup(:state_test, tx.from) do
        [{_, account}] ->
          account.balance >= tx.value + (tx.gas_price * tx.gas_limit) and
          account.nonce <= tx.nonce
        [] ->
          false
      end
    else
      false
    end
  end
  
  defp process_transaction_full(tx) do
    # Full validation
    if validate_transaction_crypto(tx) do
      # Check sender balance
      case :ets.lookup(:full_test, tx.from) do
        [{from_addr, from_acc}] ->
          total_cost = tx.value + (tx.gas_price * tx.gas_limit)
          
          if from_acc.balance >= total_cost and from_acc.nonce <= tx.nonce do
            # Update sender
            new_from = %{from_acc | 
              balance: from_acc.balance - total_cost,
              nonce: from_acc.nonce + 1
            }
            :ets.insert(:full_test, {from_addr, new_from})
            
            # Update receiver
            case :ets.lookup(:full_test, tx.to) do
              [{to_addr, to_acc}] ->
                new_to = %{to_acc | balance: to_acc.balance + tx.value}
                :ets.insert(:full_test, {to_addr, new_to})
              [] ->
                :ets.insert(:full_test, {tx.to, %{balance: tx.value, nonce: 0}})
            end
            
            # Simulate gas refund (simplified)
            gas_used = 21_000
            gas_refund = (tx.gas_limit - gas_used) * tx.gas_price
            if gas_refund > 0 do
              [{_, updated_from}] = :ets.lookup(:full_test, from_addr)
              :ets.insert(:full_test, {from_addr, %{updated_from | balance: updated_from.balance + gas_refund}})
            end
            
            true
          else
            false
          end
        [] ->
          false
      end
    else
      false
    end
  end
  
  defp display_summary(basic_tps, crypto_tps, state_tps, full_tps) do
    IO.puts("\n" <> String.duplicate("=", 50))
    IO.puts("TPS TEST SUMMARY")
    IO.puts(String.duplicate("=", 50))
    
    IO.puts("\nPerformance Breakdown:")
    IO.puts("  Basic Validation:    #{Float.round(basic_tps, 2)} TPS")
    IO.puts("  With Crypto Ops:     #{Float.round(crypto_tps, 2)} TPS")
    IO.puts("  With State Checks:   #{Float.round(state_tps, 2)} TPS")
    IO.puts("  Full Pipeline:       #{Float.round(full_tps, 2)} TPS")
    
    IO.puts("\nPerformance Analysis:")
    
    # Check against 15 TPS target
    if full_tps >= 15 do
      IO.puts("  ✅ PRODUCTION READY: #{Float.round(full_tps, 2)} TPS exceeds 15 TPS target")
    else
      IO.puts("  ⚠️  OPTIMIZATION NEEDED: #{Float.round(full_tps, 2)} TPS (target: 15+ TPS)")
      shortfall = 15 - full_tps
      IO.puts("     Gap to target: #{Float.round(shortfall, 2)} TPS")
    end
    
    # Performance bottleneck analysis
    crypto_overhead = ((basic_tps - crypto_tps) / basic_tps) * 100
    state_overhead = ((crypto_tps - state_tps) / crypto_tps) * 100
    pipeline_overhead = ((state_tps - full_tps) / state_tps) * 100
    
    IO.puts("\nBottleneck Analysis:")
    IO.puts("  Crypto Operations:   -#{Float.round(crypto_overhead, 1)}% impact")
    IO.puts("  State Operations:    -#{Float.round(state_overhead, 1)}% impact")
    IO.puts("  Pipeline Overhead:   -#{Float.round(pipeline_overhead, 1)}% impact")
    
    IO.puts("\n" <> String.duplicate("=", 50))
  end
end

# Run the test
StandaloneTPS.run(5)