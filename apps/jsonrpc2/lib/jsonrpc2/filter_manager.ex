defmodule JSONRPC2.FilterManager do
  @moduledoc """
  Manages filters for the Ethereum JSON-RPC API.
  Stores filter state and handles filter operations.
  """

  use GenServer

  import JSONRPC2.Response.Helpers

  # Client API

  @doc """
  Starts the FilterManager GenServer.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Creates a new log filter.
  """
  def new_filter(filter_params) do
    GenServer.call(__MODULE__, {:new_filter, :log, filter_params})
  end

  @doc """
  Creates a new block filter.
  """
  def new_block_filter() do
    GenServer.call(__MODULE__, {:new_filter, :block, %{}})
  end

  @doc """
  Creates a new pending transaction filter.
  """
  def new_pending_transaction_filter() do
    GenServer.call(__MODULE__, {:new_filter, :pending_tx, %{}})
  end

  @doc """
  Removes a filter.
  """
  def uninstall_filter(filter_id) do
    GenServer.call(__MODULE__, {:uninstall_filter, filter_id})
  end

  @doc """
  Gets changes for a filter since last poll.
  """
  def get_filter_changes(filter_id) do
    GenServer.call(__MODULE__, {:get_filter_changes, filter_id})
  end

  @doc """
  Gets all logs matching a filter.
  """
  def get_filter_logs(filter_id) do
    GenServer.call(__MODULE__, {:get_filter_logs, filter_id})
  end

  # Server callbacks

  @impl true
  def init(_opts) do
    state = %{
      filters: %{},
      next_id: 1,
      # Filters expire after 5 minutes of inactivity
      timeout_ms: 5 * 60 * 1000
    }

    # Schedule periodic cleanup
    schedule_cleanup()

    {:ok, _state}
  end

  @impl true
  def handle_call({:new_filter, type, _params}, _from, _state) do
    filter_id = generate_filter_id(state.next_id)

    filter = %{
      id: filter_id,
      type: type,
      params: params,
      created_at: System.system_time(:second),
      last_poll: System.system_time(:second),
      last_block: get_current_block_number(),
      changes: []
    }

    new_filters = Map.put(state.filters, filter_id, filter)
    new_state = %{state | filters: new_filters, next_id: state.next_id + 1}

    {:reply, {:ok, filter_id}, new_state}
  end

  @impl true
  def handle_call({:uninstall_filter, filter_id}, _from, _state) do
    case Map.get(state.filters, filter_id) do
      nil ->
        {:reply, false, _state}

      _filter ->
        new_filters = Map.delete(state.filters, filter_id)
        {:reply, true, %{state | filters: new_filters}}
    end
  end

  @impl true
  def handle_call({:get_filter_changes, filter_id}, _from, _state) do
    case Map.get(state.filters, filter_id) do
      nil ->
        {:reply, {:error, :filter_not_found}, state}

      filter ->
        # Get changes since last poll
        changes = get_changes_for_filter(filter)

        # Update filter with new last_poll time and clear changes
        updated_filter = %{
          filter
          | last_poll: System.system_time(:second),
            last_block: get_current_block_number(),
            changes: []
        }

        new_filters = Map.put(state.filters, filter_id, updated_filter)

        {:reply, {:ok, changes}, %{state | filters: new_filters}}
    end
  end

  @impl true
  def handle_call({:get_filter_logs, filter_id}, _from, _state) do
    case Map.get(state.filters, filter_id) do
      nil ->
        {:reply, {:error, :filter_not_found}, state}

      %{type: :log, params: params} = filter ->
        # Get all logs matching the filter
        logs = get_all_logs_for_filter(params)

        # Update last poll time
        updated_filter = %{filter | last_poll: System.system_time(:second)}
        new_filters = Map.put(state.filters, filter_id, updated_filter)

        {:reply, {:ok, logs}, %{state | filters: new_filters}}

      _ ->
        # This method only works for log filters
        {:reply, {:error, :invalid_filter_type}, state}
    end
  end

  @impl true
  def handle_info(:cleanup, _state) do
    # Remove expired filters
    current_time = System.system_time(:second)
    timeout_seconds = div(state.timeout_ms, 1000)

    active_filters =
      state.filters
      |> Enum.filter(fn {_id, filter} ->
        current_time - filter.last_poll < timeout_seconds
      end)
      |> Map.new()

    # Schedule next cleanup
    schedule_cleanup()

    {:noreply, %{state | filters: active_filters}}
  end

  # Private functions

  defp generate_filter_id(next_id) do
    # Generate a hex-encoded filter ID
    encode_quantity(next_id)
  end

  defp get_current_block_number() do
    # Get from sync state
    case Process.whereis(ExWire.Sync) do
      nil ->
        0

      _ ->
        sync_data = JSONRPC2.Bridge.Sync.last_sync_state()

        case sync_data do
          %{highest_block_number: number} -> number
          _ -> 0
        end
    end
  end

  defp get_changes_for_filter(%{type: :block} = filter) do
    # Return block hashes for new blocks since last poll
    current_block = get_current_block_number()

    if current_block > filter.last_block do
      # Get block hashes from filter.last_block + 1 to current_block
      # This is simplified - should actually fetch the block hashes
      (filter.last_block + 1)..current_block
      |> Enum.map(fn block_num ->
        # Block hash lookup from blockchain state
        encode_quantity(block_num)
      end)
    else
      []
    end
  end

  defp get_changes_for_filter(%{type: :pending_tx} = _filter) do
    # Return transaction hashes for new pending transactions
    # For now, return empty as we don't track pending transactions
    []
  end

  defp get_changes_for_filter(%{type: :log, params: _params} = filter) do
    # Get logs that match the filter since last poll
    sync_data = JSONRPC2.Bridge.Sync.last_sync_state()

    # Update params to only get logs since last poll
    updated_params =
      Map.merge(params, %{
        "fromBlock" => encode_quantity(filter.last_block + 1),
        "toBlock" => "latest"
      })

    case JSONRPC2.SpecHandler.LogsFilter.filter_logs(updated_params, sync_data.trie) do
      {:ok, logs} -> logs
      _ -> []
    end
  end

  defp get_all_logs_for_filter(_params) do
    sync_data = JSONRPC2.Bridge.Sync.last_sync_state()

    case JSONRPC2.SpecHandler.LogsFilter.filter_logs(params, sync_data.trie) do
      {:ok, logs} -> logs
      _ -> []
    end
  end

  defp schedule_cleanup() do
    # Schedule cleanup every minute
    Process.send_after(self(), :cleanup, 60_000)
  end
end
