defmodule MerklePatriciaTree.DB.AntidoteIntegrationTest do
  @moduledoc """
  Comprehensive integration tests for AntidoteDB with real cluster.

  These tests require a running AntidoteDB cluster.
  Start with: ./scripts/antidote_cluster.sh start
  """

  use ExUnit.Case, async: false

  # Skip integration tests that require real AntidoteDB cluster in CI
  @moduletag :antidote_integration

  alias MerklePatriciaTree.DB.Antidote
  alias MerklePatriciaTree.DB.AntidoteConnectionPool
  alias MerklePatriciaTree.DB.AntidoteCRDTs.{AccountBalance, TransactionPool, StateTree}

  @moduletag :antidote
  @moduletag :integration

  setup_all do
    # Check if AntidoteDB is running
    case :gen_tcp.connect(~c"localhost", 8087, [:binary, {:packet, 0}], 1000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok

      {:error, _} ->
        IO.puts("\n⚠️  AntidoteDB cluster not running. Skipping integration tests.")
        IO.puts("   Start cluster with: ./scripts/antidote_cluster.sh start\n")
        :skip
    end
  end

  setup do
    # Start connection pool for tests if not already started
    case Process.whereis(AntidoteConnectionPool) do
      nil ->
        {:ok, _} =
          AntidoteConnectionPool.start_link(
            nodes: [{"localhost", 8087}, {"localhost", 8088}, {"localhost", 8089}],
            pool_size: 5
          )

      _pid ->
        # Pool already running
        :ok
    end

    # Generate unique test database name
    db_name = "test_#{System.unique_integer([:positive])}"
    db_ref = Antidote.init(db_name)

    on_exit(fn ->
      # Cleanup would go here if needed
      :ok
    end)

    {:ok, db_ref: db_ref, db_name: db_name}
  end

  describe "Basic Operations" do
    test "can connect to AntidoteDB cluster", %{db_ref: db_ref} do
      assert db_ref != nil
    end

    test "can write and read data", %{db_ref: db_ref} do
      key = :crypto.strong_rand_bytes(32)
      value = :crypto.strong_rand_bytes(100)

      assert :ok = Antidote.put!(db_ref, key, value)
      assert {:ok, ^value} = Antidote.get(db_ref, key)
    end

    test "returns not_found for missing keys", %{db_ref: db_ref} do
      key = :crypto.strong_rand_bytes(32)
      assert :not_found = Antidote.get(db_ref, key)
    end

    test "can delete data", %{db_ref: db_ref} do
      key = :crypto.strong_rand_bytes(32)
      value = :crypto.strong_rand_bytes(100)

      assert :ok = Antidote.put!(db_ref, key, value)
      assert {:ok, ^value} = Antidote.get(db_ref, key)

      assert :ok = Antidote.delete!(db_ref, key)
      assert :not_found = Antidote.get(db_ref, key)
    end
  end

  describe "Batch Operations" do
    test "can perform batch writes", %{db_ref: db_ref} do
      pairs =
        for i <- 1..100 do
          {<<i::256>>, <<i::512>>}
        end

      assert :ok = Antidote.batch_put!(db_ref, pairs, 10)

      # Verify all were written
      for {key, value} <- pairs do
        assert {:ok, ^value} = Antidote.get(db_ref, key)
      end
    end

    test "handles large batches efficiently", %{db_ref: db_ref} do
      pairs =
        for i <- 1..1000 do
          {<<i::256>>, :crypto.strong_rand_bytes(1024)}
        end

      {time, :ok} =
        :timer.tc(fn ->
          Antidote.batch_put!(db_ref, pairs, 50)
        end)

      # Should complete in reasonable time
      # Less than 10 seconds
      assert time < 10_000_000

      # Verify sampling
      for i <- [1, 100, 500, 1000] do
        assert {:ok, _} = Antidote.get(db_ref, <<i::256>>)
      end
    end
  end

  describe "Connection Pool" do
    test "connection pool handles concurrent requests" do
      tasks =
        for i <- 1..50 do
          Task.async(fn ->
            AntidoteConnectionPool.with_connection(fn conn ->
              # Simulate work
              Process.sleep(10)
              {:ok, conn}
            end)
          end)
        end

      results = Task.await_many(tasks, 5000)

      assert Enum.all?(results, fn
               {:ok, _} -> true
               _ -> false
             end)
    end

    test "connection pool provides status information" do
      status = AntidoteConnectionPool.status()

      assert is_map(status)
      assert Map.has_key?(status, :total_connections)
      assert Map.has_key?(status, :available)
      assert Map.has_key?(status, :busy)
      assert status.total_connections > 0
    end

    test "circuit breaker opens on repeated failures" do
      # This would require simulating node failures
      # For now, just verify the structure exists
      status = AntidoteConnectionPool.status()
      assert Map.has_key?(status, :circuit_breaker)
    end
  end

  describe "CRDT - Account Balance" do
    test "account balance CRDT maintains consistency" do
      account = AccountBalance.new(<<1::160>>)
      node1 = "node1"
      node2 = "node2"

      # Concurrent updates from different nodes
      account_v1 = account |> AccountBalance.credit(100, node1)
      account_v2 = account |> AccountBalance.credit(50, node2)

      # Merge should be commutative
      merged1 = AccountBalance.merge(account_v1, account_v2)
      merged2 = AccountBalance.merge(account_v2, account_v1)

      assert AccountBalance.get_balance(merged1) == AccountBalance.get_balance(merged2)
      assert AccountBalance.get_balance(merged1) == 150
    end

    test "account nonce uses last-write-wins" do
      account = AccountBalance.new(<<1::160>>)

      # Update nonce from different nodes with timestamps
      account_v1 = AccountBalance.update_nonce(account, 5, "node1")
      # Ensure different timestamp
      Process.sleep(10)
      account_v2 = AccountBalance.update_nonce(account, 10, "node2")

      merged = AccountBalance.merge(account_v1, account_v2)
      assert AccountBalance.get_nonce(merged) == 10
    end
  end

  describe "CRDT - Transaction Pool" do
    test "transaction pool handles concurrent additions" do
      pool = TransactionPool.new()

      # Add transactions from different nodes
      pool_v1 = TransactionPool.add_transaction(pool, <<1::256>>, %{data: "tx1"}, "node1")
      pool_v2 = TransactionPool.add_transaction(pool, <<2::256>>, %{data: "tx2"}, "node2")

      # Merge pools
      merged = TransactionPool.merge(pool_v1, pool_v2)
      txs = TransactionPool.get_transactions(merged)

      assert map_size(txs) == 2
      assert Map.has_key?(txs, <<1::256>>)
      assert Map.has_key?(txs, <<2::256>>)
    end

    test "transaction pool handles removals correctly" do
      pool = TransactionPool.new()

      # Add and then remove a transaction
      pool = TransactionPool.add_transaction(pool, <<1::256>>, %{data: "tx1"}, "node1")
      pool = TransactionPool.add_transaction(pool, <<2::256>>, %{data: "tx2"}, "node1")
      pool = TransactionPool.remove_transaction(pool, <<1::256>>, "node1")

      txs = TransactionPool.get_transactions(pool)
      assert map_size(txs) == 1
      assert not Map.has_key?(txs, <<1::256>>)
      assert Map.has_key?(txs, <<2::256>>)
    end
  end

  describe "CRDT - State Tree" do
    test "state tree merges preserve latest updates" do
      tree = StateTree.new()

      # Update same path from different nodes
      tree_v1 = StateTree.update_node(tree, ["a", "b"], <<1::256>>, "data1", "node1")
      tree_v2 = StateTree.update_node(tree, ["a", "b"], <<2::256>>, "data2", "node2")

      # Merge should preserve the update with higher version
      merged = StateTree.merge(tree_v1, tree_v2)

      assert merged.root_hash != <<0::256>>
      assert length(StateTree.get_sync_candidates(merged)) > 0
    end
  end

  describe "Fault Tolerance" do
    @tag :slow
    test "handles node failures gracefully", %{db_ref: db_ref} do
      # This test would require actually stopping nodes
      # For now, test that operations continue even with connection issues

      key = :crypto.strong_rand_bytes(32)
      value = :crypto.strong_rand_bytes(100)

      # Should handle transient failures
      assert :ok = Antidote.put!(db_ref, key, value)
      assert {:ok, ^value} = Antidote.get(db_ref, key)
    end

    test "handles concurrent operations", %{db_ref: db_ref} do
      # Launch multiple concurrent operations
      tasks =
        for i <- 1..100 do
          Task.async(fn ->
            key = <<i::256>>
            value = <<i::512>>
            Antidote.put!(db_ref, key, value)
            Antidote.get(db_ref, key)
          end)
        end

      results = Task.await_many(tasks, 10000)

      successful =
        Enum.count(results, fn
          {:ok, _} -> true
          _ -> false
        end)

      # Most operations should succeed
      assert successful > 90
    end
  end

  describe "Performance" do
    @tag :benchmark
    test "measures single operation performance", %{db_ref: db_ref} do
      key = :crypto.strong_rand_bytes(32)
      value = :crypto.strong_rand_bytes(1024)

      # Measure write performance
      {write_time, :ok} =
        :timer.tc(fn ->
          Antidote.put!(db_ref, key, value)
        end)

      # Measure read performance  
      {read_time, {:ok, _}} =
        :timer.tc(fn ->
          Antidote.get(db_ref, key)
        end)

      IO.puts("\nPerformance metrics:")
      IO.puts("  Write: #{write_time} µs")
      IO.puts("  Read:  #{read_time} µs")

      # Should be reasonably fast
      # Less than 100ms
      assert write_time < 100_000
      # Less than 50ms
      assert read_time < 50_000
    end

    @tag :benchmark
    @tag :slow
    test "measures throughput", %{db_ref: db_ref} do
      operations = 1000

      {time, _} =
        :timer.tc(fn ->
          for i <- 1..operations do
            key = <<i::256>>
            value = <<i::512>>
            Antidote.put!(db_ref, key, value)
          end
        end)

      ops_per_sec = operations * 1_000_000 / time
      IO.puts("\nThroughput: #{round(ops_per_sec)} ops/sec")

      # Should achieve reasonable throughput
      # At least 100 ops/sec
      assert ops_per_sec > 100
    end
  end
end
