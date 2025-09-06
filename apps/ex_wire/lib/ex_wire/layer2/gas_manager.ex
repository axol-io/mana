defmodule ExWire.Layer2.GasManager do
  @moduledoc """
  Manages gas estimation and optimization for L1 operations.

  Features:
  - Dynamic gas price strategies (slow, standard, fast)
  - EIP-1559 base fee tracking and prediction
  - Gas limit estimation with safety margins
  - Batch transaction optimization
  - Historical gas usage analysis
  - Priority fee calculation based on network congestion
  """

  use GenServer
  require Logger

  alias ExWire.Layer2.Web3Client

  @gas_strategies %{
    slow: %{percentile: 10, multiplier: 0.9},
    standard: %{percentile: 50, multiplier: 1.0},
    fast: %{percentile: 90, multiplier: 1.1},
    instant: %{percentile: 99, multiplier: 1.2}
  }

  # 20% buffer on gas estimates
  @gas_limit_buffer 1.2
  # 500 gwei max
  @max_gas_price 500_000_000_000
  # 1 gwei min
  @min_gas_price 1_000_000_000
  # Number of blocks to analyze for gas trends
  @history_blocks 20
  # 15 seconds
  @update_interval 15_000

  defstruct [
    :web3_client,
    :current_base_fee,
    :gas_history,
    :priority_fees,
    :last_update,
    :network_congestion,
    :cached_estimates,
    :strategy
  ]

  @type gas_strategy :: :slow | :standard | :fast | :instant

  @type gas_recommendation :: %{
          base_fee: non_neg_integer(),
          priority_fee: non_neg_integer(),
          max_fee: non_neg_integer(),
          legacy_gas_price: non_neg_integer(),
          # seconds
          estimated_wait: non_neg_integer()
        }

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Gets recommended gas prices based on strategy.
  """
  @spec get_gas_prices(gas_strategy()) :: {:ok, gas_recommendation()} | {:error, term()}
  def get_gas_prices(strategy \\ :standard) do
    GenServer.call(__MODULE__, {:get_gas_prices, strategy})
  end

  @doc """
  Estimates gas limit for a transaction.
  """
  @spec estimate_gas_limit(map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def estimate_gas_limit(tx_params) do
    GenServer.call(__MODULE__, {:estimate_gas_limit, tx_params})
  end

  @doc """
  Optimizes gas for a batch of transactions.
  """
  @spec optimize_batch(list(map())) :: {:ok, list(map())} | {:error, term()}
  def optimize_batch(transactions) do
    GenServer.call(__MODULE__, {:optimize_batch, transactions})
  end

  @doc """
  Gets current network congestion level.
  """
  @spec get_congestion_level() :: {:ok, :low | :medium | :high | :critical}
  def get_congestion_level do
    GenServer.call(__MODULE__, :get_congestion_level)
  end

  @doc """
  Predicts gas prices for a future block.
  """
  @spec predict_gas_prices(non_neg_integer()) :: {:ok, gas_recommendation()} | {:error, term()}
  def predict_gas_prices(blocks_ahead) do
    GenServer.call(__MODULE__, {:predict_gas_prices, blocks_ahead})
  end

  # Server Callbacks

  @impl true
  def init(opts) do
    state = %__MODULE__{
      web3_client: opts[:web3_client] || Web3Client,
      current_base_fee: nil,
      gas_history: [],
      priority_fees: %{},
      last_update: nil,
      network_congestion: :medium,
      cached_estimates: %{},
      strategy: opts[:default_strategy] || :standard
    }

    # Initialize gas data
    {:ok, state} = refresh_gas_data(state)

    # Schedule periodic updates
    schedule_update()

    Logger.info("Gas manager initialized")
    {:ok, state}
  end

  @impl true
  def handle_call({:get_gas_prices, strategy}, _from, state) do
    recommendation = calculate_gas_recommendation(strategy, state)
    {:reply, {:ok, recommendation}, state}
  end

  @impl true
  def handle_call({:estimate_gas_limit, tx_params}, _from, state) do
    case estimate_transaction_gas(tx_params, state) do
      {:ok, gas_limit} ->
        # Apply safety buffer
        safe_limit = trunc(gas_limit * @gas_limit_buffer)
        {:reply, {:ok, safe_limit}, state}

      {:error, reason} = error ->
        Logger.error("Gas estimation failed: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:optimize_batch, transactions}, _from, state) do
    optimized = optimize_transaction_batch(transactions, state)
    {:reply, {:ok, optimized}, state}
  end

  @impl true
  def handle_call(:get_congestion_level, _from, state) do
    {:reply, {:ok, state.network_congestion}, state}
  end

  @impl true
  def handle_call({:predict_gas_prices, blocks_ahead}, _from, state) do
    prediction = predict_future_gas(blocks_ahead, state)
    {:reply, {:ok, prediction}, state}
  end

  @impl true
  def handle_info(:update_gas_data, state) do
    {:ok, new_state} = refresh_gas_data(state)
    schedule_update()
    {:noreply, new_state}
  end

  # Private Functions

  defp refresh_gas_data(state) do
    with {:ok, fee_history} <- fetch_fee_history(state),
         {:ok, current_base_fee} <- get_current_base_fee(state),
         priority_fees <- analyze_priority_fees(fee_history),
         congestion <- calculate_congestion(fee_history) do
      new_state = %{
        state
        | current_base_fee: current_base_fee,
          gas_history: fee_history,
          priority_fees: priority_fees,
          last_update: DateTime.utc_now(),
          network_congestion: congestion,
          # Clear cache on update
          cached_estimates: %{}
      }

      {:ok, new_state}
    else
      {:error, reason} ->
        Logger.error("Failed to refresh gas data: #{inspect(reason)}")
        {:ok, state}
    end
  end

  defp fetch_fee_history(state) do
    case Web3Client.make_rpc_request(
           %{
             method: "eth_feeHistory",
             params: [@history_blocks, "latest", [10, 25, 50, 75, 90, 95, 99]]
           },
           state.web3_client
         ) do
      {:ok, history} ->
        {:ok, parse_fee_history(history)}

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    _ ->
      # Fallback to simple gas price if fee history not available
      fetch_legacy_gas_price(state)
  end

  defp fetch_legacy_gas_price(state) do
    case Web3Client.get_gas_price(state.web3_client) do
      {:ok, %{legacy_gas_price: price}} ->
        {:ok, %{base_fee: price, rewards: []}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_fee_history(history) do
    %{
      base_fees: Enum.map(history["baseFeePerGas"] || [], &hex_to_integer/1),
      rewards: history["reward"] || [],
      gas_used_ratios: history["gasUsedRatio"] || []
    }
  end

  defp get_current_base_fee(state) do
    case Web3Client.get_block("latest") do
      {:ok, block} ->
        {:ok, block.base_fee_per_gas || estimate_base_fee(state)}

      {:error, _} ->
        {:ok, estimate_base_fee(state)}
    end
  end

  defp estimate_base_fee(state) do
    if state.gas_history[:base_fees] && length(state.gas_history[:base_fees]) > 0 do
      List.last(state.gas_history[:base_fees])
    else
      # 20 gwei default
      20_000_000_000
    end
  end

  defp analyze_priority_fees(fee_history) do
    rewards = fee_history[:rewards] || []

    if length(rewards) > 0 do
      # Calculate percentiles from reward data
      %{
        p10: calculate_percentile(rewards, 10),
        p25: calculate_percentile(rewards, 25),
        p50: calculate_percentile(rewards, 50),
        p75: calculate_percentile(rewards, 75),
        p90: calculate_percentile(rewards, 90),
        p95: calculate_percentile(rewards, 95),
        p99: calculate_percentile(rewards, 99)
      }
    else
      # Default priority fees
      %{
        # 1 gwei
        p10: 1_000_000_000,
        # 1.5 gwei
        p25: 1_500_000_000,
        # 2 gwei
        p50: 2_000_000_000,
        # 3 gwei
        p75: 3_000_000_000,
        # 5 gwei
        p90: 5_000_000_000,
        # 7 gwei
        p95: 7_000_000_000,
        # 10 gwei
        p99: 10_000_000_000
      }
    end
  end

  defp calculate_percentile(data, percentile) do
    flat_data =
      data
      |> List.flatten()
      |> Enum.map(&hex_to_integer/1)
      |> Enum.sort()

    index = trunc(length(flat_data) * percentile / 100)
    # 2 gwei default
    Enum.at(flat_data, index, 2_000_000_000)
  end

  defp calculate_congestion(fee_history) do
    gas_used_ratios = fee_history[:gas_used_ratios] || []

    if length(gas_used_ratios) > 0 do
      avg_usage = Enum.sum(gas_used_ratios) / length(gas_used_ratios)

      cond do
        avg_usage < 0.5 -> :low
        avg_usage < 0.8 -> :medium
        avg_usage < 0.95 -> :high
        true -> :critical
      end
    else
      :medium
    end
  end

  defp calculate_gas_recommendation(strategy, state) do
    strategy_config = Map.get(@gas_strategies, strategy, @gas_strategies.standard)

    base_fee = state.current_base_fee || 20_000_000_000
    priority_fee = get_priority_fee_for_percentile(strategy_config.percentile, state)

    # Apply strategy multiplier
    adjusted_priority_fee = trunc(priority_fee * strategy_config.multiplier)

    # Calculate max fee (base fee * 2 + priority fee for headroom)
    max_fee = min(base_fee * 2 + adjusted_priority_fee, @max_gas_price)

    # Legacy gas price for non-EIP-1559 transactions
    legacy_gas_price = base_fee + adjusted_priority_fee

    # Estimate wait time based on strategy
    estimated_wait = estimate_wait_time(strategy)

    %{
      base_fee: base_fee,
      priority_fee: adjusted_priority_fee,
      max_fee: max_fee,
      legacy_gas_price: legacy_gas_price,
      estimated_wait: estimated_wait
    }
  end

  defp get_priority_fee_for_percentile(percentile, state) do
    case percentile do
      10 -> state.priority_fees[:p10] || 1_000_000_000
      25 -> state.priority_fees[:p25] || 1_500_000_000
      50 -> state.priority_fees[:p50] || 2_000_000_000
      75 -> state.priority_fees[:p75] || 3_000_000_000
      90 -> state.priority_fees[:p90] || 5_000_000_000
      95 -> state.priority_fees[:p95] || 7_000_000_000
      99 -> state.priority_fees[:p99] || 10_000_000_000
      _ -> state.priority_fees[:p50] || 2_000_000_000
    end
  end

  defp estimate_wait_time(strategy) do
    case strategy do
      # 5 minutes
      :slow -> 300
      # 1 minute
      :standard -> 60
      # 15 seconds
      :fast -> 15
      # 5 seconds
      :instant -> 5
      _ -> 60
    end
  end

  defp estimate_transaction_gas(tx_params, state) do
    # Check cache first
    cache_key = hash_tx_params(tx_params)

    case Map.get(state.cached_estimates, cache_key) do
      nil ->
        # Make actual estimation call
        Web3Client.estimate_gas(state.web3_client, tx_params)

      cached_value ->
        {:ok, cached_value}
    end
  end

  defp hash_tx_params(params) do
    :crypto.hash(:sha256, :erlang.term_to_binary(params))
    |> Base.encode16(case: :lower)
  end

  defp optimize_transaction_batch(transactions, state) do
    # Get current gas recommendation
    {:ok, gas_rec} = calculate_gas_recommendation(state.strategy, state)

    # Sort transactions by priority/value
    sorted_txs = Enum.sort_by(transactions, & &1[:priority], &>=/2)

    # Apply optimal gas prices based on position in batch
    sorted_txs
    |> Enum.with_index()
    |> Enum.map(fn {tx, index} ->
      # Higher priority transactions get slightly higher priority fees
      priority_multiplier = 1.0 + 0.1 * (length(sorted_txs) - index) / length(sorted_txs)
      adjusted_priority_fee = trunc(gas_rec.priority_fee * priority_multiplier)

      tx
      |> Map.put(:maxFeePerGas, gas_rec.max_fee)
      |> Map.put(:maxPriorityFeePerGas, adjusted_priority_fee)
      # Fallback for legacy
      |> Map.put(:gasPrice, gas_rec.legacy_gas_price)
    end)
  end

  defp predict_future_gas(blocks_ahead, state) do
    # Simple linear prediction based on recent trend
    base_fees = state.gas_history[:base_fees] || []

    if length(base_fees) >= 2 do
      # Calculate trend
      recent_fees = Enum.take(base_fees, -5)
      avg_change = calculate_average_change(recent_fees)

      # Project forward
      predicted_base_fee = state.current_base_fee + avg_change * blocks_ahead
      predicted_base_fee = max(@min_gas_price, min(predicted_base_fee, @max_gas_price))

      # Adjust priority fees based on predicted congestion
      predicted_congestion = predict_congestion(blocks_ahead, state)

      priority_multiplier =
        case predicted_congestion do
          :low -> 0.8
          :medium -> 1.0
          :high -> 1.5
          :critical -> 2.0
        end

      %{
        base_fee: trunc(predicted_base_fee),
        priority_fee: trunc(state.priority_fees[:p50] * priority_multiplier),
        max_fee: trunc(predicted_base_fee * 2),
        legacy_gas_price: trunc(predicted_base_fee + state.priority_fees[:p50]),
        estimated_wait: 60
      }
    else
      # Not enough data, return current prices
      calculate_gas_recommendation(:standard, state)
    end
  end

  defp calculate_average_change(fees) when length(fees) < 2, do: 0

  defp calculate_average_change(fees) do
    fees
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> b - a end)
    |> Enum.sum()
    |> Kernel./(length(fees) - 1)
  end

  defp predict_congestion(_blocks_ahead, state) do
    # Simple prediction - assumes congestion remains similar
    state.network_congestion
  end

  defp hex_to_integer("0x" <> hex), do: String.to_integer(hex, 16)
  defp hex_to_integer(value) when is_integer(value), do: value
  defp hex_to_integer(_), do: 0

  defp schedule_update do
    Process.send_after(self(), :update_gas_data, @update_interval)
  end
end
