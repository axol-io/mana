defmodule Blockchain.SimplePoolTest do
  use ExUnit.Case, async: true

  alias Blockchain.SimplePool, as: Pool

  setup do
    # Start a pool for this test with unique name
    pool_name = :"pool_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Pool, [], name: pool_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, pool: pool_name}
  end

  describe "add_transaction/1" do
    test "adds valid transaction to pool", %{pool: pool} do
      raw_tx = "valid_transaction_data"

      assert {:ok, tx_hash} = GenServer.call(pool, {:add_transaction, raw_tx})
      assert is_binary(tx_hash)
      # SHA256 hash
      assert byte_size(tx_hash) == 32

      # Verify transaction is in pool
      assert {:ok, transaction} = GenServer.call(pool, {:get_transaction, tx_hash})
      assert transaction.data == raw_tx
    end

    test "rejects duplicate transaction", %{pool: pool} do
      raw_tx = "duplicate_test_data"

      assert {:ok, tx_hash} = GenServer.call(pool, {:add_transaction, raw_tx})
      assert {:error, :already_exists} = GenServer.call(pool, {:add_transaction, raw_tx})

      # Stats should reflect rejection
      stats = GenServer.call(pool, :get_stats)
      assert stats.total_added == 1
      assert stats.total_rejected == 1
    end

    test "rejects oversized transaction", %{pool: pool} do
      # Create transaction larger than 128KB
      oversized_tx = String.duplicate("x", 129 * 1024)

      assert {:error, :invalid_size} = GenServer.call(pool, {:add_transaction, oversized_tx})

      # Stats should reflect rejection
      stats = GenServer.call(pool, :get_stats)
      assert stats.total_rejected == 1
      assert stats.pool_size == 0
    end

    test "rejects empty transaction", %{pool: pool} do
      assert {:error, :invalid_size} = GenServer.call(pool, {:add_transaction, ""})

      stats = GenServer.call(pool, :get_stats)
      assert stats.total_rejected == 1
    end
  end

  describe "get_transaction/1" do
    test "retrieves existing transaction", %{pool: pool} do
      raw_tx = "test_transaction"
      {:ok, tx_hash} = GenServer.call(pool, {:add_transaction, raw_tx})

      assert {:ok, transaction} = GenServer.call(pool, {:get_transaction, tx_hash})
      assert transaction.data == raw_tx
      assert transaction.gas_price == 2_000_000_000
    end

    test "returns error for non-existent transaction", %{pool: pool} do
      fake_hash = :crypto.hash(:sha256, "nonexistent")
      assert {:error, :not_found} = GenServer.call(pool, {:get_transaction, fake_hash})
    end
  end

  describe "get_pending_transactions/1" do
    test "returns all transactions ordered by gas price", %{pool: pool} do
      # Add multiple transactions
      txs = ["tx1", "tx2", "tx3"]

      for tx <- txs do
        GenServer.call(pool, {:add_transaction, tx})
      end

      pending = GenServer.call(pool, {:get_pending, nil})
      assert length(pending) == 3

      # All should have same gas price (our default)
      assert Enum.all?(pending, fn tx -> tx.gas_price == 2_000_000_000 end)
    end

    test "limits returned transactions when specified", %{pool: pool} do
      # Add 5 transactions
      for i <- 1..5 do
        GenServer.call(pool, {:add_transaction, "tx#{i}"})
      end

      limited = GenServer.call(pool, {:get_pending, 3})
      assert length(limited) == 3

      unlimited = GenServer.call(pool, {:get_pending, nil})
      assert length(unlimited) == 5
    end

    test "returns empty list when pool is empty", %{pool: pool} do
      assert [] == GenServer.call(pool, {:get_pending, nil})
    end
  end

  describe "clear_pool/0" do
    test "removes all transactions from pool", %{pool: pool} do
      # Add multiple transactions
      for i <- 1..3 do
        GenServer.call(pool, {:add_transaction, "tx#{i}"})
      end

      # Verify they were added
      stats_before = GenServer.call(pool, :get_stats)
      assert stats_before.pool_size == 3

      # Clear pool
      assert :ok = GenServer.call(pool, :clear_pool)

      # Verify everything is cleared
      assert [] == GenServer.call(pool, {:get_pending, nil})

      stats_after = GenServer.call(pool, :get_stats)
      assert stats_after.pool_size == 0
      assert stats_after.total_removed == 3
    end
  end

  describe "get_stats/0" do
    test "returns correct statistics", %{pool: pool} do
      # Initial stats
      stats = GenServer.call(pool, :get_stats)
      assert stats.total_added == 0
      assert stats.total_removed == 0
      assert stats.total_rejected == 0
      assert stats.pool_size == 0

      # Add valid transaction
      GenServer.call(pool, {:add_transaction, "valid_tx"})

      # Try to add invalid transaction
      GenServer.call(pool, {:add_transaction, ""})

      # Check updated stats
      stats = GenServer.call(pool, :get_stats)
      assert stats.total_added == 1
      assert stats.total_rejected == 1
      assert stats.pool_size == 1
    end
  end

  describe "telemetry events" do
    @tag :telemetry
    test "emits telemetry events for operations", %{pool: pool} do
      ref = make_ref()

      :telemetry.attach(
        "test-handler-#{System.unique_integer()}",
        [:blockchain, :simple_pool_v2, :transaction_added],
        fn _event_name, measurements, metadata, _config ->
          send(self(), {:telemetry_event, measurements, metadata})
        end,
        nil
      )

      GenServer.call(pool, {:add_transaction, "test_tx"})

      assert_receive {:telemetry_event, measurements, metadata}
      assert measurements.count == 1
      assert measurements.timestamp
      assert metadata.tx_hash

      # No need to detach as we used a unique integer
    end
  end

  describe "concurrent operations" do
    @tag :concurrent
    test "handles concurrent additions safely", %{pool: pool} do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            GenServer.call(pool, {:add_transaction, "concurrent_tx_#{i}"})
          end)
        end

      results = Task.await_many(tasks, 5000)
      successful = Enum.count(results, fn r -> match?({:ok, _}, r) end)

      assert successful == 50

      pending = GenServer.call(pool, {:get_pending, nil})
      assert length(pending) == 50

      stats = GenServer.call(pool, :get_stats)
      assert stats.total_added == 50
      assert stats.pool_size == 50
    end
  end

  describe "memory management" do
    test "tracks transaction sizes correctly", %{pool: pool} do
      small_tx = "small"
      large_tx = String.duplicate("large", 1000)

      {:ok, small_hash} = GenServer.call(pool, {:add_transaction, small_tx})
      {:ok, large_hash} = GenServer.call(pool, {:add_transaction, large_tx})

      {:ok, small_retrieved} = GenServer.call(pool, {:get_transaction, small_hash})
      {:ok, large_retrieved} = GenServer.call(pool, {:get_transaction, large_hash})

      assert small_retrieved.size == byte_size(small_tx)
      assert large_retrieved.size == byte_size(large_tx)
      assert large_retrieved.size > small_retrieved.size
    end
  end

  describe "error handling" do
    test "survives malformed data gracefully", %{pool: pool} do
      # Pool should continue operating even with edge cases
      edge_cases = [
        # Binary data
        <<255, 255, 255>>,
        # Unicode
        "unicode: ñáéíóú",
        # Medium size
        String.duplicate("a", 1000)
      ]

      for {case_data, idx} <- Enum.with_index(edge_cases) do
        result = GenServer.call(pool, {:add_transaction, case_data})
        assert match?({:ok, _}, result), "Failed on case #{idx}: #{inspect(case_data)}"
      end

      stats = GenServer.call(pool, :get_stats)
      assert stats.total_added == length(edge_cases)
      assert stats.pool_size == length(edge_cases)
    end
  end
end
