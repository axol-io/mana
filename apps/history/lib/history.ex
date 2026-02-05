defmodule History do
  @moduledoc """
  Stateless Ethereum History Node.

  A lightweight alternative to running a full archive node, optimized for
  historical event log queries. Syncs headers, transactions, receipts, and
  logs directly from the P2P network without EVM execution.

  ## Features

  - **Efficient Storage**: ~250GB for Ethereum mainnet event data (vs 2TB+ archive)
  - **Fast Sync**: 1000+ blocks/sec from P2P network
  - **No RPC Dependency**: Syncs directly via devp2p, no external RPC needed
  - **Sharded Storage**: CubDB-based sharded storage for parallel queries
  - **Bloom Indexing**: Fast log filtering via bloom filter index
  - **Distributed Ready**: Integrates with Mana's AntidoteDB for multi-node

  ## Supported RPC Methods

  - `eth_getLogs` - Filter and retrieve historical event logs
  - `eth_blockNumber` - Current synced block number
  - `eth_getBlockByNumber` - Block header by number
  - `eth_chainId` - Chain identifier

  ## Usage

      # Query logs
      History.get_logs(%{
        address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
        topics: ["0xddf252ad..."],
        from_block: 18_000_000,
        to_block: 18_100_000
      })

      # Get sync status
      History.sync_status()
  """

  alias History.{Query, Storage, Sync}

  @type log :: %{
          address: binary(),
          topics: [binary()],
          data: binary(),
          block_number: non_neg_integer(),
          block_hash: binary(),
          transaction_hash: binary(),
          transaction_index: non_neg_integer(),
          log_index: non_neg_integer()
        }

  @type log_filter :: %{
          optional(:address) => binary() | [binary()],
          optional(:topics) => [binary() | [binary()] | nil],
          optional(:from_block) => non_neg_integer() | :earliest | :latest,
          optional(:to_block) => non_neg_integer() | :earliest | :latest,
          optional(:block_hash) => binary()
        }

  @doc """
  Query historical event logs with optional filtering.

  ## Parameters

  - `filter` - Log filter criteria:
    - `:address` - Contract address or list of addresses
    - `:topics` - Topic filters (position-indexed, nil for wildcard)
    - `:from_block` - Start block (number, :earliest, or :latest)
    - `:to_block` - End block (number, :earliest, or :latest)
    - `:block_hash` - Query single block by hash

  ## Examples

      iex> History.get_logs(%{
      ...>   address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
      ...>   topics: ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
      ...>   from_block: 18_000_000,
      ...>   to_block: 18_000_100
      ...> })
      {:ok, [%{address: "0x...", ...}, ...]}
  """
  @spec get_logs(log_filter()) :: {:ok, [log()]} | {:error, term()}
  defdelegate get_logs(filter), to: Query

  @doc """
  Get the current synced block number.
  """
  @spec block_number() :: {:ok, non_neg_integer()} | {:error, term()}
  defdelegate block_number(), to: Sync.Pipeline

  @doc """
  Get block header by number.
  """
  @spec get_block(non_neg_integer()) :: {:ok, map()} | {:error, :not_found}
  defdelegate get_block(number), to: Storage

  @doc """
  Get sync status and progress.
  """
  @spec sync_status() :: map()
  defdelegate sync_status(), to: Sync.Pipeline, as: :status

  @doc """
  Get storage statistics.
  """
  @spec storage_stats() :: map()
  defdelegate storage_stats(), to: Storage, as: :stats
end
