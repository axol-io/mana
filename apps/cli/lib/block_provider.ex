defmodule CLI.BlockProvider do
  @moduledoc """
  Behavior for block providers that can sync blockchain data.

  Block providers abstract the source of blockchain data, allowing
  Mana to sync from different sources like:
  - RPC endpoints (Infura, Alchemy, local nodes)
  - P2P networking (direct peer-to-peer sync)
  - Local files (for testing or offline sync)
  """

  @doc """
  Sets up the block provider and returns initial state.

  The setup process should:
  - Initialize connections (RPC clients, P2P peers, etc.)
  - Validate configuration
  - Return a state object that will be passed to other functions
  """
  @callback setup(args :: [any()]) :: {:ok, state :: any()} | {:error, reason :: any()}

  @doc """
  Gets the highest known block number from the provider.

  This is used to track sync progress and determine how many
  blocks need to be synced.
  """
  @callback get_block_number(state :: any()) ::
              {:ok, block_number :: integer()} | {:error, reason :: any()}

  @doc """
  Retrieves a specific block by number.

  Should return the complete block with header, transactions,
  and any other required data. The state may be updated
  to reflect connection changes, peer updates, etc.
  """
  @callback get_block(block_number :: integer(), state :: any()) ::
              {:ok, block :: Blockchain.Block.t(), new_state :: any()} | {:error, reason :: any()}
end
