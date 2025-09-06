defmodule ExWire.SimpleSyncTest do
  use ExUnit.Case, async: true

  alias ExWire.SimpleSync, as: Sync

  setup do
    # Start a sync service for this test with unique name
    sync_name = :"sync_#{System.unique_integer([:positive])}"
    {:ok, pid} = GenServer.start_link(Sync, [chain: :testnet], name: sync_name)

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
    end)

    {:ok, sync: sync_name}
  end

  describe "initialization" do
    test "starts with correct initial state", %{sync: sync} do
      status = GenServer.call(sync, :get_sync_status)

      assert status.status == :initializing
      assert status.current_block == 0
      assert status.highest_block == 0
      assert status.chain == :testnet
      assert status.connected_peers == 0
    end
  end

  describe "peer management" do
    test "adds peers correctly", %{sync: sync} do
      peer1 = %{id: "peer1", address: "127.0.0.1", port: 30303}
      peer2 = %{id: "peer2", address: "127.0.0.2", port: 30303}

      GenServer.cast(sync, {:add_peer, peer1})
      GenServer.cast(sync, {:add_peer, peer2})

      # Give it time to process
      Process.sleep(50)

      status = GenServer.call(sync, :get_sync_status)
      assert status.connected_peers == 2
    end

    test "removes peers correctly", %{sync: sync} do
      peer = %{id: "test_peer", address: "127.0.0.1", port: 30303}

      GenServer.cast(sync, {:add_peer, peer})
      Process.sleep(50)

      status_after_add = GenServer.call(sync, :get_sync_status)
      assert status_after_add.connected_peers == 1

      GenServer.cast(sync, {:remove_peer, "test_peer"})
      Process.sleep(50)

      status_after_remove = GenServer.call(sync, :get_sync_status)
      assert status_after_remove.connected_peers == 0
    end

    test "handles removing non-existent peer gracefully", %{sync: sync} do
      GenServer.cast(sync, {:remove_peer, "nonexistent_peer"})
      Process.sleep(50)

      status = GenServer.call(sync, :get_sync_status)
      assert status.connected_peers == 0
    end
  end

  describe "block synchronization" do
    test "syncs blocks successfully", %{sync: sync} do
      result = GenServer.call(sync, {:sync_blocks, 1, 100})

      assert {:ok, 99} = result

      # Check initial status
      status = GenServer.call(sync, :get_sync_status)
      assert status.status == :syncing
      assert status.current_block == 1
      assert status.highest_block == 100
    end

    test "rejects invalid block range", %{sync: sync} do
      result = GenServer.call(sync, {:sync_blocks, 100, 50})
      assert {:error, :invalid_range} = result

      result2 = GenServer.call(sync, {:sync_blocks, 50, 50})
      assert {:error, :invalid_range} = result2
    end

    test "tracks sync progress correctly", %{sync: sync} do
      GenServer.call(sync, {:sync_blocks, 1, 100})

      # Get initial progress
      progress = GenServer.call(sync, :get_sync_progress)
      assert progress.current_block == 1
      assert progress.highest_block == 100
      assert progress.percentage >= 0.0
      assert progress.blocks_remaining == 99

      # Wait a bit for some processing
      Process.sleep(200)

      # Check progress again
      progress2 = GenServer.call(sync, :get_sync_progress)
      assert progress2.current_block > progress.current_block
      assert progress2.percentage > progress.percentage
    end

    test "completes sync eventually", %{sync: sync} do
      # Small range for quick completion
      GenServer.call(sync, {:sync_blocks, 1, 20})

      # Wait for completion
      Process.sleep(1000)

      status = GenServer.call(sync, :get_sync_status)
      assert status.status == :synchronized
      assert status.current_block == 20
    end
  end

  describe "sync status determination" do
    test "shows disconnected when no peers", %{sync: sync} do
      # Wait for status update
      # Wait for first status update
      Process.sleep(1100)

      status = GenServer.call(sync, :get_sync_status)
      assert status.status == :disconnected
    end

    test "shows syncing status during block sync", %{sync: sync} do
      # Add a peer first
      GenServer.cast(sync, {:add_peer, %{id: "peer1", address: "127.0.0.1"}})
      Process.sleep(50)

      GenServer.call(sync, {:sync_blocks, 1, 1000})

      status = GenServer.call(sync, :get_sync_status)
      assert status.status == :syncing
    end

    test "transitions to synchronized when sync complete", %{sync: sync} do
      # Add a peer and sync small range
      GenServer.cast(sync, {:add_peer, %{id: "peer1", address: "127.0.0.1"}})
      GenServer.call(sync, {:sync_blocks, 1, 5})

      # Wait for completion
      Process.sleep(500)

      status = GenServer.call(sync, :get_sync_status)
      assert status.status == :synchronized
    end
  end

  describe "progress tracking" do
    test "calculates percentage correctly", %{sync: sync} do
      GenServer.call(sync, {:sync_blocks, 0, 100})

      progress = GenServer.call(sync, :get_sync_progress)
      assert progress.percentage >= 0.0
      assert progress.percentage <= 100.0
    end

    test "handles zero highest block", %{sync: sync} do
      progress = GenServer.call(sync, :get_sync_progress)

      assert progress.current_block == 0
      assert progress.highest_block == 0
      assert progress.percentage == 0.0
      assert progress.blocks_remaining == 0
    end
  end

  describe "concurrent operations" do
    @tag :concurrent
    test "handles multiple peer operations concurrently", %{sync: sync} do
      tasks =
        for i <- 1..20 do
          Task.async(fn ->
            peer = %{id: "peer_#{i}", address: "127.0.0.#{i}"}
            GenServer.cast(sync, {:add_peer, peer})
          end)
        end

      Task.await_many(tasks)
      Process.sleep(100)

      status = GenServer.call(sync, :get_sync_status)
      assert status.connected_peers == 20
    end

    @tag :concurrent
    test "handles concurrent sync requests safely", %{sync: sync} do
      # Only one sync should succeed, others should be handled gracefully
      task1 = Task.async(fn -> GenServer.call(sync, {:sync_blocks, 1, 100}) end)
      task2 = Task.async(fn -> GenServer.call(sync, {:sync_blocks, 50, 150}) end)

      result1 = Task.await(task1)
      result2 = Task.await(task2)

      # At least one should succeed
      assert match?({:ok, _}, result1) or match?({:ok, _}, result2)
    end
  end

  describe "error handling" do
    test "survives unexpected messages", %{sync: sync} do
      # Send unexpected message
      send(sync, :unexpected_message)
      Process.sleep(50)

      # Should still be responsive
      status = GenServer.call(sync, :get_sync_status)
      assert is_map(status)
    end

    test "handles edge cases in block ranges", %{sync: sync} do
      # Very large range
      result1 = GenServer.call(sync, {:sync_blocks, 1, 1_000_000})
      assert {:ok, 999_999} = result1

      # Single block
      result2 = GenServer.call(sync, {:sync_blocks, 100, 101})
      assert {:ok, 1} = result2
    end
  end

  describe "chain configuration" do
    test "respects chain configuration" do
      {:ok, pid} = GenServer.start_link(Sync, chain: :mainnet)

      status = GenServer.call(pid, :get_sync_status)
      assert status.chain == :mainnet

      GenServer.stop(pid)
    end

    test "defaults to mainnet if no chain specified" do
      {:ok, pid} = GenServer.start_link(Sync, [])

      status = GenServer.call(pid, :get_sync_status)
      assert status.chain == :mainnet

      GenServer.stop(pid)
    end
  end

  describe "metrics tracking" do
    test "tracks blocks synced correctly", %{sync: sync} do
      GenServer.call(sync, {:sync_blocks, 1, 20})

      # Wait for some processing
      Process.sleep(300)

      # The internal metrics should be updated (we can't directly access them in this simple implementation)
      # but we can verify through the progress tracking
      progress = GenServer.call(sync, :get_sync_progress)
      assert progress.current_block > 1
    end
  end
end
