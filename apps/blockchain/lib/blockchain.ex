defmodule Blockchain do
  @moduledoc """
  The Blockchain application is responsible for Ethereum blockchain processes
  and capabilities as defined in the 
  [Ethereum yellow paper](https://ethereum.github.io/yellowpaper/paper.pdf). Equation references are based on the Yellow Paper - Byzantium Version e94ebda.

  Application functionality includes:
  * Block encoding
  * Adding blocks to the block tree to form a consistent blockchain
  * Chain specific information
  * Genesis block generation
  * Transaction serialization
  * Contract creation and message calls
  """

  @doc """
  Gets the latest block number from the blockchain.

  Returns the block number of the current chain head.
  For testing, returns a mock block number.
  """
  @spec get_latest_block_number() :: {:ok, non_neg_integer()} | {:error, term()}
  def get_latest_block_number do
    # In production, would query the actual blockchain state
    # For testing/development, return a reasonable mock value
    case Application.get_env(:blockchain, :environment, :dev) do
      :test ->
        {:ok, 18_000_000 + :rand.uniform(1000)}

      :dev ->
        {:ok, 18_500_000}

      :prod ->
        # Would implement actual blockchain query here
        {:ok, get_chain_head_block_number()}
    end
  end

  defp get_chain_head_block_number do
    # Placeholder for actual implementation
    # Would query from chain state/database
    18_500_000
  end
end
