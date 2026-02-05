defmodule History.Storage do
  @moduledoc """
  Sharded storage for historical blockchain data.

  Uses CubDB for persistent storage with sharding for parallel access.
  Data is partitioned by block number across multiple shards.

  ## Sharding Strategy

      block_number -> shard_id = rem(block_number, num_shards)
  """

  alias History.Storage.Shard

  @type log :: History.log()
  @default_shards 16

  # Shard routing

  @doc """
  Get the shard name for a given block number.
  """
  @spec shard_for(non_neg_integer()) :: atom()
  def shard_for(block_number) do
    num_shards = Application.get_env(:history, :shards, @default_shards)
    :"history_shard_#{rem(block_number, num_shards)}"
  end

  # Header operations

  @spec put_header(non_neg_integer(), map()) :: :ok
  def put_header(block_number, header) do
    block_number |> shard_for() |> Shard.put({:header, block_number}, header)
  end

  @spec get_header(non_neg_integer()) :: {:ok, map()} | {:error, :not_found}
  def get_header(block_number) do
    block_number |> shard_for() |> Shard.get({:header, block_number})
  end

  # Transaction operations

  @spec put_transactions(non_neg_integer(), [map()]) :: :ok
  def put_transactions(block_number, transactions) do
    block_number |> shard_for() |> Shard.put({:transactions, block_number}, transactions)
  end

  @spec get_transactions(non_neg_integer()) :: {:ok, [map()]} | {:error, :not_found}
  def get_transactions(block_number) do
    block_number |> shard_for() |> Shard.get({:transactions, block_number})
  end

  # Log operations

  @spec put_logs(non_neg_integer(), [log()]) :: :ok
  def put_logs(block_number, logs) do
    block_number |> shard_for() |> Shard.put({:logs, block_number}, logs)
  end

  @spec get_logs(non_neg_integer()) :: {:ok, [log()]} | {:error, :not_found}
  def get_logs(block_number) do
    block_number |> shard_for() |> Shard.get({:logs, block_number})
  end

  @spec get_logs_range(non_neg_integer(), non_neg_integer()) :: [log()]
  def get_logs_range(from_block, to_block) do
    from_block..to_block
    |> Task.async_stream(
      fn n ->
        case get_logs(n) do
          {:ok, logs} -> logs
          _ -> []
        end
      end,
      max_concurrency: System.schedulers_online() * 2
    )
    |> Enum.flat_map(fn {:ok, logs} -> logs end)
  end

  # Block operations

  @spec get_block(non_neg_integer()) :: {:ok, map()} | {:error, :not_found}
  def get_block(block_number) do
    with {:ok, header} <- get_header(block_number) do
      {:ok,
       %{
         number: block_number,
         hash: header.block_hash,
         parent_hash: header.parent_hash,
         timestamp: header.timestamp,
         gas_limit: header.gas_limit,
         gas_used: header.gas_used,
         difficulty: header.difficulty,
         extra_data: header.extra_data
       }}
    end
  end

  # Checkpoint operations

  @spec get_synced_block() :: non_neg_integer() | nil
  def get_synced_block do
    case Shard.get(:history_shard_0, :synced_block) do
      {:ok, block} -> block
      _ -> nil
    end
  end

  @spec checkpoint(non_neg_integer()) :: :ok
  def checkpoint(block_number), do: Shard.put(:history_shard_0, :synced_block, block_number)

  # Statistics

  @spec stats() :: map()
  def stats do
    num_shards = Application.get_env(:history, :shards, @default_shards)

    shard_stats =
      0..(num_shards - 1)
      |> Enum.map(&Shard.stats(:"history_shard_#{&1}"))

    %{
      total_blocks: shard_stats |> Enum.map(& &1.blocks) |> Enum.sum(),
      total_logs: shard_stats |> Enum.map(& &1.logs) |> Enum.sum(),
      disk_usage_bytes: shard_stats |> Enum.map(& &1.disk_bytes) |> Enum.sum(),
      shards: num_shards
    }
  end
end
