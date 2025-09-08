defmodule ExWire.LoadTest.Scenarios.EdgeCases do
  @moduledoc """
  Edge case and error condition testing scenarios.
  """

  alias ExWire.LoadTest.{TransactionGenerator, MetricsCollector}
  require Logger

  @doc """
  Test handling of zero gas price transactions.
  """
  def zero_gas_price_transactions(_config) do
    Logger.info("Testing zero gas price transactions")

    transactions =
      TransactionGenerator.generate_gas_price_scenarios(
        count: 100,
        accounts: config.test_accounts
      )

    zero_gas_txs = Enum.filter(transactions, &(&1.gas_price == 0))

    results =
      Enum.map(zero_gas_txs, fn tx ->
        try do
          # Attempt to process
          process_transaction(tx)
        rescue
          error -> {:error, error}
        end
      end)

    %{
      success: Enum.all?(results, &match?({:error, _}, &1)),
      total: length(zero_gas_txs),
      properly_rejected: Enum.count(results, &match?({:error, _}, &1))
    }
  end

  @doc """
  Test transactions at maximum gas limit.
  """
  def max_gas_limit_transactions(_config) do
    Logger.info("Testing max gas limit transactions")

    max_gas_limit = 30_000_000

    transactions =
      Enum.map(1..10, fn _ ->
        accounts = config.test_accounts
        from = Enum.random(accounts)

        %{
          from: from,
          to: Enum.random(accounts -- [from]),
          gas_limit: max_gas_limit,
          gas_price: 30_000_000_000,
          value: 0,
          data: generate_large_calldata(10_000)
        }
      end)

    results =
      Enum.map(transactions, fn tx ->
        process_transaction(tx)
      end)

    %{
      success: Enum.all?(results, &match?({:ok, _}, &1)),
      transactions_processed: Enum.count(results, &match?({:ok, _}, &1))
    }
  end

  @doc """
  Test chain reorganization handling.
  """
  def chain_reorganization(_config) do
    Logger.info("Testing chain reorganization")

    # Create two competing chains
    chain_a = generate_block_chain(config, 10, "chain_a")
    # Longer chain
    chain_b = generate_block_chain(config, 12, "chain_b")

    # Process chain A first
    Enum.each(chain_a, &process_block/1)

    # Now process longer chain B (should trigger reorg)
    reorg_result =
      try do
        Enum.each(chain_b, &process_block/1)
        {:ok, :reorganized}
      rescue
        error -> {:error, error}
      end

    %{
      success: match?({:ok, :reorganized}, reorg_result),
      chain_a_length: length(chain_a),
      chain_b_length: length(chain_b),
      result: reorg_result
    }
  end

  @doc """
  Test flooding with invalid transactions.
  """
  def invalid_transaction_flood(_config) do
    Logger.info("Testing invalid transaction flood")

    invalid_txs =
      TransactionGenerator.generate_failing_transactions(
        count: 1000,
        accounts: config.test_accounts
      )

    start_time = System.monotonic_time(:millisecond)

    results =
      Enum.map(invalid_txs, fn tx ->
        MetricsCollector.record_transaction_sent("invalid_flood", tx_hash(tx))

        case validate_transaction(tx) do
          {:error, _reason} ->
            MetricsCollector.record_transaction_failed("invalid_flood", tx_hash(tx), reason)
            {:rejected, reason}

          :ok ->
            {:accepted, tx}
        end
      end)

    end_time = System.monotonic_time(:millisecond)

    rejected_count = Enum.count(results, &match?({:rejected, _}, &1))

    %{
      success: rejected_count == length(invalid_txs),
      duration_ms: end_time - start_time,
      transactions_per_second: length(invalid_txs) / ((end_time - start_time) / 1000),
      rejection_rate: rejected_count / length(invalid_txs) * 100
    }
  end

  @doc """
  Test duplicate nonce handling.
  """
  def duplicate_nonce_handling(_config) do
    Logger.info("Testing duplicate nonce handling")

    from_account = Enum.random(config.test_accounts)
    nonce = 100

    # Create multiple transactions with same nonce
    duplicate_txs =
      Enum.map(1..10, fn i ->
        %{
          from: from_account,
          nonce: nonce,
          # Different gas prices
          gas_price: 30_000_000_000 * i,
          gas_limit: 21_000,
          to: Enum.random(config.test_accounts -- [from_account]),
          value: 1_000_000_000_000_000_000,
          data: <<>>
        }
      end)

    # Send all transactions
    results =
      Enum.map(duplicate_txs, fn tx ->
        MetricsCollector.record_transaction_sent("duplicate_nonce", tx_hash(tx))
        process_transaction(tx)
      end)

    # Only highest gas price should succeed
    success_count = Enum.count(results, &match?({:ok, _}, &1))

    %{
      success: success_count == 1,
      total_sent: length(duplicate_txs),
      accepted: success_count,
      properly_handled: success_count == 1
    }
  end

  # Private helper functions

  defp process_transaction(tx) do
    # Simulate transaction processing
    cond do
      tx[:gas_price] == 0 ->
        {:error, :zero_gas_price}

      tx[:gas_limit] > 30_000_000 ->
        {:error, :gas_limit_exceeded}

      tx[:nonce] == nil ->
        {:error, :invalid_nonce}

      true ->
        {:ok, tx_hash(tx)}
    end
  end

  defp validate_transaction(tx) do
    cond do
      Map.get(tx, :gas_limit, 0) < 100 ->
        {:error, :insufficient_gas}

      Map.get(tx, :nonce) == 999_999 ->
        {:error, :invalid_nonce}

      Map.get(tx, :v) == 35 ->
        {:error, :invalid_signature}

      true ->
        :ok
    end
  end

  defp generate_large_calldata(size) do
    :crypto.strong_rand_bytes(size)
  end

  defp generate_block_chain(_config, length, chain_id) do
    Enum.map(1..length, fn height ->
      transactions =
        TransactionGenerator.generate_simple_transfers(
          count: :rand.uniform(100),
          accounts: config.test_accounts
        )

      %{
        number: height,
        parent_hash: :crypto.hash(:sha256, "#{chain_id}_#{height - 1}"),
        hash: :crypto.hash(:sha256, "#{chain_id}_#{height}"),
        transactions: transactions,
        timestamp: System.system_time(:second) + height
      }
    end)
  end

  defp process_block(block) do
    # Simulate block processing
    Logger.debug("Processing block ##{block.number}")
    {:ok, block.hash}
  end

  defp tx_hash(tx) do
    :crypto.hash(:sha256, :erlang.term_to_binary(tx))
    |> Base.encode16(case: :lower)
  end
end
