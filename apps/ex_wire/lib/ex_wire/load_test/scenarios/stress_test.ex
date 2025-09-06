defmodule ExWire.LoadTest.Scenarios.StressTest do
  @moduledoc """
  Stress testing scenarios to find system breaking points.
  """

  alias ExWire.LoadTest.{TransactionGenerator, MetricsCollector}
  require Logger

  @doc """
  Test with increasing transaction rate until system fails.
  """
  def high_transaction_rate(config) do
    Logger.info("Testing high transaction rate")

    Enum.reduce_while(1..100, %{}, fn multiplier, _acc ->
      tps = config.target_tps * multiplier
      Logger.info("Testing #{tps} TPS")

      # 10 second test
      result = test_transaction_rate(config, tps, 10_000)

      if result.success_rate < 90 do
        {:halt, %{breaking_point: multiplier, tps: tps, success_rate: result.success_rate}}
      else
        {:cont, result}
      end
    end)
  end

  @doc """
  Test with increasingly large blocks.
  """
  def large_blocks(config) do
    Logger.info("Testing large block sizes")

    block_sizes = [100, 500, 1000, 2000, 5000]

    Enum.map(block_sizes, fn size ->
      transactions =
        TransactionGenerator.generate_simple_transfers(
          count: size,
          accounts: config.test_accounts
        )

      start_time = System.monotonic_time(:millisecond)
      # Process block
      process_large_block(transactions)
      end_time = System.monotonic_time(:millisecond)

      %{
        block_size: size,
        processing_time_ms: end_time - start_time,
        success: true
      }
    end)
  end

  @doc """
  Test state bloat with many accounts and storage.
  """
  def state_bloat(config) do
    Logger.info("Testing state bloat")

    account_counts = [1000, 10_000, 100_000]

    Enum.map(account_counts, fn count ->
      accounts = generate_accounts_with_storage(count)

      # Measure state operations
      {time, _result} =
        :timer.tc(fn ->
          Enum.each(accounts, fn acc ->
            update_account_state(acc)
          end)
        end)

      %{
        account_count: count,
        operation_time_us: time,
        avg_time_per_account: time / count
      }
    end)
  end

  @doc """
  Test concurrent request handling.
  """
  def concurrent_requests(config) do
    Logger.info("Testing concurrent requests")

    concurrency_levels = [10, 50, 100, 500, 1000]

    Enum.map(concurrency_levels, fn level ->
      tasks =
        Enum.map(1..level, fn _ ->
          Task.async(fn ->
            # Simulate RPC request
            {:ok, :response}
          end)
        end)

      start_time = System.monotonic_time(:millisecond)
      results = Task.await_many(tasks, 30_000)
      end_time = System.monotonic_time(:millisecond)

      success_count = Enum.count(results, &match?({:ok, _}, &1))

      %{
        concurrency: level,
        duration_ms: end_time - start_time,
        success_rate: success_count / level * 100
      }
    end)
  end

  @doc """
  Test memory pressure scenarios.
  """
  def memory_pressure(config) do
    Logger.info("Testing memory pressure")

    initial_memory = :erlang.memory(:total)

    # Generate large amounts of data
    large_transactions =
      Enum.map(1..10_000, fn _ ->
        TransactionGenerator.generate_state_stress_transactions(
          count: 10,
          accounts: config.test_accounts
        )
      end)
      |> List.flatten()

    peak_memory = :erlang.memory(:total)

    # Process and clear
    Enum.each(large_transactions, fn tx ->
      MetricsCollector.record_transaction_sent(
        "memory_pressure",
        :crypto.hash(:sha256, :erlang.term_to_binary(tx))
      )
    end)

    :erlang.garbage_collect()
    final_memory = :erlang.memory(:total)

    %{
      initial_memory_mb: initial_memory / 1_048_576,
      peak_memory_mb: peak_memory / 1_048_576,
      final_memory_mb: final_memory / 1_048_576,
      memory_growth: (peak_memory - initial_memory) / 1_048_576,
      memory_recovered: (peak_memory - final_memory) / 1_048_576
    }
  end

  # Private helper functions

  defp test_transaction_rate(config, tps, duration_ms) do
    transactions_per_batch = max(1, round(tps / 10))
    batches = round(duration_ms / 100)

    results =
      Enum.map(1..batches, fn _ ->
        transactions =
          TransactionGenerator.generate_simple_transfers(
            count: transactions_per_batch,
            accounts: config.test_accounts
          )

        Enum.map(transactions, fn tx ->
          try do
            MetricsCollector.record_transaction_sent("stress_test", tx_hash(tx))
            {:ok, tx}
          rescue
            _ -> {:error, :failed}
          end
        end)

        Process.sleep(100)
      end)
      |> List.flatten()

    success_count = Enum.count(results, &match?({:ok, _}, &1))
    total = length(results)

    %{
      success: success_count == total,
      success_rate: success_count / total * 100,
      total_transactions: total
    }
  end

  defp process_large_block(transactions) do
    Enum.each(transactions, fn tx ->
      # Simulate block processing
      :crypto.hash(:sha256, :erlang.term_to_binary(tx))
    end)
  end

  defp generate_accounts_with_storage(count) do
    Enum.map(1..count, fn i ->
      %{
        address: :crypto.strong_rand_bytes(20),
        balance: :rand.uniform(1_000_000),
        nonce: i,
        storage: generate_storage_slots(:rand.uniform(100))
      }
    end)
  end

  defp generate_storage_slots(count) do
    Enum.map(1..count, fn _ ->
      {:crypto.strong_rand_bytes(32), :crypto.strong_rand_bytes(32)}
    end)
    |> Map.new()
  end

  defp update_account_state(account) do
    # Simulate state update
    Map.update!(account, :nonce, &(&1 + 1))
  end

  defp tx_hash(tx) do
    :crypto.hash(:sha256, :erlang.term_to_binary(tx))
    |> Base.encode16(case: :lower)
  end
end
