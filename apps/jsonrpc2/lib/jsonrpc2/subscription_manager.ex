defmodule JSONRPC2.SubscriptionManager do
  @moduledoc """
  GenServer that manages WebSocket subscriptions for JSON-RPC eth_subscribe/eth_unsubscribe.

  Supports the following subscription types:
  - newHeads: New block headers  
  - logs: Event logs matching filter criteria
  - newPendingTransactions: New pending transactions
  - syncing: Sync status changes

  Each subscription is identified by a unique subscription ID and associated with a WebSocket PID.
  """

  use GenServer
  require Logger

  alias JSONRPC2.Response.Helpers
  alias JSONRPC2.Bridge.Sync

  @sync Application.compile_env(:jsonrpc2, :bridge_mock, Sync)

  # Client API

  @doc """
  Starts the SubscriptionManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new subscription for the given WebSocket connection.

  ## Parameters
  - subscription_type: "newHeads", "logs", "newPendingTransactions", or "syncing"
  - params: Additional parameters (e.g., filter criteria for logs)
  - ws_pid: PID of the WebSocket connection

  ## Returns
  - {:ok, subscription_id} on success
  - {:error, reason} on failure
  """
  def subscribe(subscription_type, params \\ %{}, ws_pid) do
    GenServer.call(__MODULE__, {:subscribe, subscription_type, params, ws_pid})
  end

  @doc """
  Cancels an existing subscription.

  ## Parameters
  - subscription_id: The ID of the subscription to cancel
  - ws_pid: PID of the WebSocket connection (for validation)

  ## Returns
  - {:ok, true} if subscription was cancelled
  - {:ok, false} if subscription was not found
  - {:error, reason} on failure
  """
  def unsubscribe(subscription_id, ws_pid) do
    GenServer.call(__MODULE__, {:unsubscribe, subscription_id, ws_pid})
  end

  @doc """
  Notifies the subscription manager of a new block.
  Called by the blockchain when a new block is added.
  """
  def notify_new_block(block) do
    GenServer.cast(__MODULE__, {:new_block, block})
  end

  @doc """
  Notifies the subscription manager of new logs.
  Called when new logs are generated.
  """
  def notify_new_logs(logs) do
    GenServer.cast(__MODULE__, {:new_logs, logs})
  end

  @doc """
  Notifies the subscription manager of a new pending transaction.
  """
  def notify_new_pending_transaction(transaction) do
    GenServer.cast(__MODULE__, {:new_pending_transaction, transaction})
  end

  @doc """
  Notifies the subscription manager of sync status changes.
  """
  def notify_sync_status(status) do
    GenServer.cast(__MODULE__, {:sync_status, status})
  end

  @doc """
  Removes all subscriptions for a disconnected WebSocket.
  """
  def cleanup_subscriptions(ws_pid) do
    GenServer.cast(__MODULE__, {:cleanup, ws_pid})
  end

  # Server Callbacks

  @impl true
  def init(_opts) do
    # Monitor WebSocket processes to cleanup subscriptions on disconnect
    Process.flag(:trap_exit, true)

    state = %{
      # Map of subscription_id => %{type, params, ws_pid, created_at}
      subscriptions: %{},
      # Map of ws_pid => [subscription_ids]
      connections: %{},
      # Counter for generating unique subscription IDs
      next_id: 1,
      # Last known block for newHeads subscriptions
      last_block: nil,
      # Last sync status
      last_sync_status: nil
    }

    # Start periodic tasks
    schedule_periodic_check()

    {:ok, state}
  end

  @impl true
  def handle_call({:subscribe, subscription_type, params, ws_pid}, _from, state) do
    case validate_subscription_type(subscription_type) do
      :ok ->
        # Generate unique subscription ID
        subscription_id = generate_subscription_id(state.next_id)

        # Create subscription record
        subscription = %{
          id: subscription_id,
          type: subscription_type,
          params: params,
          ws_pid: ws_pid,
          created_at: System.system_time(:second)
        }

        # Monitor the WebSocket process
        Process.monitor(ws_pid)

        # Update state
        new_state =
          state
          |> put_in([:subscriptions, subscription_id], subscription)
          |> update_in([:connections, ws_pid], fn
            nil -> [subscription_id]
            ids -> [subscription_id | ids]
          end)
          |> Map.put(:next_id, state.next_id + 1)

        Logger.info(
          "Created subscription #{subscription_id} of type #{subscription_type} for #{inspect(ws_pid)}"
        )

        {:reply, {:ok, subscription_id}, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:unsubscribe, subscription_id, ws_pid}, _from, state) do
    case Map.get(state.subscriptions, subscription_id) do
      nil ->
        {:reply, {:ok, false}, state}

      %{ws_pid: ^ws_pid} = _subscription ->
        # Remove subscription
        new_state = remove_subscription(state, subscription_id, ws_pid)

        Logger.info("Cancelled subscription #{subscription_id}")

        {:reply, {:ok, true}, new_state}

      %{ws_pid: other_pid} ->
        Logger.warning(
          "Unauthorized unsubscribe attempt for #{subscription_id} from #{inspect(ws_pid)}, owned by #{inspect(other_pid)}"
        )

        {:reply, {:error, :unauthorized}, state}
    end
  end

  @impl true
  def handle_cast({:new_block, block}, state) do
    # Notify all newHeads subscribers
    state.subscriptions
    |> Enum.filter(fn {_id, sub} -> sub.type == "newHeads" end)
    |> Enum.each(fn {id, sub} ->
      send_notification(sub.ws_pid, id, format_block_header(block))
    end)

    {:noreply, %{state | last_block: block}}
  end

  @impl true
  def handle_cast({:new_logs, logs}, state) do
    # Notify logs subscribers with matching filters
    state.subscriptions
    |> Enum.filter(fn {_id, sub} -> sub.type == "logs" end)
    |> Enum.each(fn {id, sub} ->
      matching_logs = filter_logs(logs, sub.params)

      if matching_logs != [] do
        send_notification(sub.ws_pid, id, format_logs(matching_logs))
      end
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:new_pending_transaction, transaction}, state) do
    # Notify all newPendingTransactions subscribers
    state.subscriptions
    |> Enum.filter(fn {_id, sub} -> sub.type == "newPendingTransactions" end)
    |> Enum.each(fn {id, sub} ->
      send_notification(sub.ws_pid, id, format_transaction_hash(transaction))
    end)

    {:noreply, state}
  end

  @impl true
  def handle_cast({:sync_status, status}, state) do
    # Only notify if sync status changed
    if status != state.last_sync_status do
      state.subscriptions
      |> Enum.filter(fn {_id, sub} -> sub.type == "syncing" end)
      |> Enum.each(fn {id, sub} ->
        send_notification(sub.ws_pid, id, format_sync_status(status))
      end)
    end

    {:noreply, %{state | last_sync_status: status}}
  end

  @impl true
  def handle_cast({:cleanup, ws_pid}, state) do
    new_state = cleanup_connection(state, ws_pid)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, ws_pid, _reason}, state) do
    # WebSocket disconnected, cleanup subscriptions
    Logger.info("WebSocket #{inspect(ws_pid)} disconnected, cleaning up subscriptions")
    new_state = cleanup_connection(state, ws_pid)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:periodic_check, state) do
    # Periodic maintenance tasks
    # For now, just log statistics
    total_subs = map_size(state.subscriptions)
    total_connections = map_size(state.connections)

    if total_subs > 0 do
      Logger.debug(
        "SubscriptionManager: #{total_subs} active subscriptions across #{total_connections} connections"
      )
    end

    # Schedule next check
    schedule_periodic_check()

    {:noreply, state}
  end

  # Private Functions

  defp validate_subscription_type(type)
       when type in ["newHeads", "logs", "newPendingTransactions", "syncing"],
       do: :ok

  defp validate_subscription_type(type), do: {:error, "Invalid subscription type: #{type}"}

  defp generate_subscription_id(counter) do
    # Generate a unique subscription ID in hex format
    counter
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
    |> then(&"0x#{&1}")
  end

  defp remove_subscription(state, subscription_id, ws_pid) do
    state
    |> update_in([:subscriptions], &Map.delete(&1, subscription_id))
    |> update_in([:connections, ws_pid], fn
      nil -> nil
      ids -> Enum.reject(ids, &(&1 == subscription_id))
    end)
    |> then(fn s ->
      # Clean up empty connection entries
      if get_in(s, [:connections, ws_pid]) == [] do
        update_in(s, [:connections], &Map.delete(&1, ws_pid))
      else
        s
      end
    end)
  end

  defp cleanup_connection(state, ws_pid) do
    subscription_ids = Map.get(state.connections, ws_pid, [])

    Enum.reduce(subscription_ids, state, fn id, acc ->
      remove_subscription(acc, id, ws_pid)
    end)
  end

  defp send_notification(ws_pid, subscription_id, result) do
    # Format as JSON-RPC notification
    notification = %{
      jsonrpc: "2.0",
      method: "eth_subscription",
      params: %{
        subscription: subscription_id,
        result: result
      }
    }

    # Send to WebSocket process
    # The WebSocket handler will serialize and send to client
    send(ws_pid, {:send_notification, notification})
  end

  defp filter_logs(logs, filter_params) do
    # Apply filter criteria to logs
    # This should match the logic in LogsFilter module
    logs
    |> Enum.filter(fn log ->
      match_addresses?(log, Map.get(filter_params, "address")) &&
        match_topics?(log, Map.get(filter_params, "topics", []))
    end)
  end

  defp match_addresses?(_log, nil), do: true

  defp match_addresses?(log, address) when is_binary(address) do
    log.address == address
  end

  defp match_addresses?(log, addresses) when is_list(addresses) do
    log.address in addresses
  end

  defp match_topics?(_log, []), do: true

  defp match_topics?(log, topics) do
    Enum.zip(topics, log.topics)
    |> Enum.all?(fn
      {nil, _} -> true
      {topic, log_topic} when is_binary(topic) -> topic == log_topic
      {topics, log_topic} when is_list(topics) -> log_topic in topics
    end)
  end

  defp format_block_header(block) do
    # Format block header for newHeads subscription
    %{
      difficulty: Helpers.encode_quantity(block.header.difficulty),
      extraData: Helpers.encode_unformatted_data(block.header.extra_data),
      gasLimit: Helpers.encode_quantity(block.header.gas_limit),
      gasUsed: Helpers.encode_quantity(block.header.gas_used),
      hash: Helpers.encode_unformatted_data(block.header.block_hash),
      logsBloom: Helpers.encode_unformatted_data(block.header.logs_bloom),
      miner: Helpers.encode_unformatted_data(block.header.beneficiary),
      mixHash: Helpers.encode_unformatted_data(block.header.mix_hash),
      nonce: Helpers.encode_unformatted_data(block.header.nonce),
      number: Helpers.encode_quantity(block.header.number),
      parentHash: Helpers.encode_unformatted_data(block.header.parent_hash),
      receiptsRoot: Helpers.encode_unformatted_data(block.header.receipts_root),
      sha3Uncles: Helpers.encode_unformatted_data(block.header.ommers_hash),
      stateRoot: Helpers.encode_unformatted_data(block.header.state_root),
      timestamp: Helpers.encode_quantity(block.header.timestamp),
      transactionsRoot: Helpers.encode_unformatted_data(block.header.transactions_root)
    }
  end

  defp format_logs(logs) do
    # Format logs for logs subscription
    Enum.map(logs, fn log ->
      %{
        address: Helpers.encode_unformatted_data(log.address),
        topics: Enum.map(log.topics, &Helpers.encode_unformatted_data/1),
        data: Helpers.encode_unformatted_data(log.data),
        blockNumber: Helpers.encode_quantity(log.block_number),
        transactionHash: Helpers.encode_unformatted_data(log.transaction_hash),
        transactionIndex: Helpers.encode_quantity(log.transaction_index),
        blockHash: Helpers.encode_unformatted_data(log.block_hash),
        logIndex: Helpers.encode_quantity(log.log_index),
        removed: log.removed || false
      }
    end)
  end

  defp format_transaction_hash(transaction) do
    # Format transaction hash for newPendingTransactions subscription
    Helpers.encode_unformatted_data(transaction.hash)
  end

  defp format_sync_status(status) do
    # Format sync status for syncing subscription
    case status do
      false ->
        false

      {current, starting, highest} ->
        %{
          startingBlock: Helpers.encode_quantity(starting),
          currentBlock: Helpers.encode_quantity(current),
          highestBlock: Helpers.encode_quantity(highest)
        }
    end
  end

  defp schedule_periodic_check do
    # Schedule periodic maintenance check every 60 seconds
    Process.send_after(self(), :periodic_check, 60_000)
  end
end
