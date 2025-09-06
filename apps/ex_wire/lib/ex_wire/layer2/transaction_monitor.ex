defmodule ExWire.Layer2.TransactionMonitor do
  @moduledoc """
  Monitors Ethereum L1 transactions for confirmation and handles retry logic.

  Features:
  - Tracks pending transactions with configurable confirmation requirements
  - Automatic retry with gas price increases for stuck transactions
  - Configurable timeout and confirmation thresholds
  - Event-based notifications for transaction state changes
  - Batch monitoring for efficiency
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.Web3Client

  defstruct client: nil,
            pending_transactions: %{},
            confirmation_blocks: 12,
            # 15 seconds
            check_interval: 15_000,
            # 30 minutes
            timeout_duration: 1_800_000,
            gas_bump_factor: 1.1,
            max_retries: 3,
            subscribers: MapSet.new()

  @type transaction_status ::
          :pending | :confirmed | :failed | :timeout | :replaced | :retrying

  @type monitored_transaction :: %{
          hash: String.t(),
          status: transaction_status(),
          block_number: non_neg_integer() | nil,
          confirmations: non_neg_integer(),
          created_at: DateTime.t(),
          last_checked: DateTime.t(),
          retry_count: non_neg_integer(),
          original_params: map(),
          replacement_hashes: [String.t()],
          callbacks: [function()]
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start monitoring a transaction
  """
  @spec monitor_transaction(String.t(), map(), keyword()) :: :ok
  def monitor_transaction(tx_hash, tx_params, opts \\ []) do
    GenServer.cast(__MODULE__, {:monitor, tx_hash, tx_params, opts})
  end

  @doc """
  Stop monitoring a transaction
  """
  @spec stop_monitoring(String.t()) :: :ok
  def stop_monitoring(tx_hash) do
    GenServer.cast(__MODULE__, {:stop_monitoring, tx_hash})
  end

  @doc """
  Get status of a monitored transaction
  """
  @spec get_status(String.t()) :: {:ok, monitored_transaction()} | {:error, :not_found}
  def get_status(tx_hash) do
    GenServer.call(__MODULE__, {:get_status, tx_hash})
  end

  @doc """
  Get all pending transactions
  """
  @spec get_pending() :: [monitored_transaction()]
  def get_pending do
    GenServer.call(__MODULE__, :get_pending)
  end

  @doc """
  Subscribe to transaction status updates
  """
  @spec subscribe() :: :ok
  def subscribe do
    GenServer.cast(__MODULE__, {:subscribe, self()})
  end

  @doc """
  Unsubscribe from transaction status updates
  """
  @spec unsubscribe() :: :ok
  def unsubscribe do
    GenServer.cast(__MODULE__, {:unsubscribe, self()})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      client: opts[:client] || ExWire.Layer2.Web3Client,
      confirmation_blocks: opts[:confirmation_blocks] || 12,
      check_interval: opts[:check_interval] || 15_000,
      timeout_duration: opts[:timeout_duration] || 1_800_000,
      gas_bump_factor: opts[:gas_bump_factor] || 1.1,
      max_retries: opts[:max_retries] || 3
    }

    # Schedule periodic checks
    schedule_check(state.check_interval)

    Logger.info(
      "Transaction monitor started with #{state.confirmation_blocks} confirmation blocks"
    )

    {:ok, state}
  end

  @impl true
  def handle_cast({:monitor, tx_hash, tx_params, opts}, state) do
    transaction = %{
      hash: tx_hash,
      status: :pending,
      block_number: nil,
      confirmations: 0,
      created_at: DateTime.utc_now(),
      last_checked: DateTime.utc_now(),
      retry_count: 0,
      original_params: tx_params,
      replacement_hashes: [],
      callbacks: opts[:callbacks] || []
    }

    new_pending = Map.put(state.pending_transactions, tx_hash, transaction)
    new_state = %{state | pending_transactions: new_pending}

    Logger.info("Started monitoring transaction #{tx_hash}")
    notify_subscribers({:monitoring_started, tx_hash}, new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:stop_monitoring, tx_hash}, state) do
    new_pending = Map.delete(state.pending_transactions, tx_hash)
    new_state = %{state | pending_transactions: new_pending}

    Logger.info("Stopped monitoring transaction #{tx_hash}")
    notify_subscribers({:monitoring_stopped, tx_hash}, new_state)

    {:noreply, new_state}
  end

  @impl true
  def handle_cast({:subscribe, pid}, state) do
    Process.monitor(pid)
    new_subscribers = MapSet.put(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_cast({:unsubscribe, pid}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  @impl true
  def handle_call({:get_status, tx_hash}, _from, state) do
    case Map.get(state.pending_transactions, tx_hash) do
      nil -> {:reply, {:error, :not_found}, state}
      transaction -> {:reply, {:ok, transaction}, state}
    end
  end

  @impl true
  def handle_call(:get_pending, _from, state) do
    pending = Map.values(state.pending_transactions)
    {:reply, pending, state}
  end

  @impl true
  def handle_info(:check_transactions, state) do
    new_state = check_all_transactions(state)
    schedule_check(state.check_interval)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    new_subscribers = MapSet.delete(state.subscribers, pid)
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  # Private Functions

  defp check_all_transactions(state) do
    {completed, still_pending} =
      state.pending_transactions
      |> Enum.map(fn {hash, tx} -> {hash, check_single_transaction(tx, state)} end)
      |> Enum.split_with(fn {_hash, tx} -> tx.status in [:confirmed, :failed, :timeout] end)

    # Log completed transactions
    Enum.each(completed, fn {hash, tx} ->
      Logger.info("Transaction #{hash} completed with status: #{tx.status}")
      notify_subscribers({:transaction_completed, hash, tx.status}, state)

      # Execute callbacks
      Enum.each(tx.callbacks, fn callback ->
        try do
          callback.(tx)
        rescue
          exception ->
            Logger.error("Transaction callback failed: #{inspect(exception)}")
        end
      end)
    end)

    # Keep only pending transactions
    new_pending = Map.new(still_pending)
    %{state | pending_transactions: new_pending}
  end

  defp check_single_transaction(tx, state) do
    now = DateTime.utc_now()

    # Check for timeout
    if DateTime.diff(now, tx.created_at, :millisecond) > state.timeout_duration do
      %{tx | status: :timeout, last_checked: now}
    else
      case get_transaction_status(tx.hash, state) do
        {:ok, :confirmed, block_number, confirmations} ->
          if confirmations >= state.confirmation_blocks do
            %{
              tx
              | status: :confirmed,
                block_number: block_number,
                confirmations: confirmations,
                last_checked: now
            }
          else
            %{
              tx
              | status: :pending,
                block_number: block_number,
                confirmations: confirmations,
                last_checked: now
            }
          end

        {:ok, :pending} ->
          # Check if we should retry (speed up) this transaction
          should_retry = should_retry_transaction?(tx, now)

          if should_retry and tx.retry_count < state.max_retries do
            case retry_transaction(tx, state) do
              {:ok, new_hash} ->
                Logger.info("Retried transaction #{tx.hash} with new hash #{new_hash}")

                %{
                  tx
                  | status: :retrying,
                    retry_count: tx.retry_count + 1,
                    replacement_hashes: [new_hash | tx.replacement_hashes],
                    last_checked: now
                }

              {:error, reason} ->
                Logger.error("Failed to retry transaction #{tx.hash}: #{inspect(reason)}")
                %{tx | last_checked: now}
            end
          else
            %{tx | last_checked: now}
          end

        {:ok, :failed} ->
          %{tx | status: :failed, last_checked: now}

        {:error, :not_found} ->
          # Transaction may have been replaced
          case check_replacement_transactions(tx, state) do
            {:ok, replacement_hash, block_number, confirmations} ->
              %{
                tx
                | hash: replacement_hash,
                  status:
                    if(confirmations >= state.confirmation_blocks, do: :confirmed, else: :pending),
                  block_number: block_number,
                  confirmations: confirmations,
                  last_checked: now
              }

            {:error, _} ->
              %{tx | last_checked: now}
          end

        {:error, reason} ->
          Logger.warning("Error checking transaction #{tx.hash}: #{inspect(reason)}")
          %{tx | last_checked: now}
      end
    end
  end

  defp get_transaction_status(tx_hash, state) do
    case Web3Client.get_transaction_receipt(state.client, tx_hash) do
      {:ok, receipt} ->
        if receipt.status do
          case Web3Client.get_block_number(state.client) do
            {:ok, current_block} ->
              confirmations = current_block - receipt.block_number
              {:ok, :confirmed, receipt.block_number, confirmations}

            {:error, _} ->
              # Assume confirmed if we can't get current block
              {:ok, :confirmed, receipt.block_number, state.confirmation_blocks}
          end
        else
          {:ok, :failed}
        end

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp should_retry_transaction?(tx, now) do
    # Retry if transaction has been pending for more than 2 minutes
    pending_time = DateTime.diff(now, tx.created_at, :millisecond)
    # 2 minutes
    pending_time > 120_000
  end

  defp retry_transaction(tx, state) do
    # Increase gas price by the bump factor
    original_gas_price = tx.original_params[:gasPrice] || tx.original_params[:maxFeePerGas]

    if original_gas_price do
      new_gas_price = trunc(original_gas_price * state.gas_bump_factor)

      # Create new transaction with higher gas price
      retry_params =
        tx.original_params
        # Use same nonce to replace
        |> Map.put(:nonce, tx.original_params[:nonce])
        |> update_gas_price(new_gas_price)

      Web3Client.send_transaction(state.client, retry_params)
    else
      {:error, :no_gas_price}
    end
  end

  defp update_gas_price(params, new_gas_price) do
    cond do
      params[:maxFeePerGas] ->
        # EIP-1559 transaction
        priority_fee = params[:maxPriorityFeePerGas] || trunc(new_gas_price * 0.05)

        params
        |> Map.put(:maxFeePerGas, new_gas_price)
        |> Map.put(:maxPriorityFeePerGas, priority_fee)

      true ->
        # Legacy transaction
        Map.put(params, :gasPrice, new_gas_price)
    end
  end

  defp check_replacement_transactions(tx, state) do
    # Check if any replacement transactions are confirmed
    tx.replacement_hashes
    |> Enum.find_value(fn hash ->
      case get_transaction_status(hash, state) do
        {:ok, :confirmed, block_number, confirmations} ->
          {:ok, hash, block_number, confirmations}

        _ ->
          false
      end
    end)
    |> case do
      {:ok, hash, block_number, confirmations} ->
        {:ok, hash, block_number, confirmations}

      _ ->
        {:error, :no_replacement_found}
    end
  end

  defp notify_subscribers(message, state) do
    Enum.each(state.subscribers, fn pid ->
      send(pid, {:transaction_monitor, message})
    end)
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_transactions, interval)
  end
end
