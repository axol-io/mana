defmodule JSONRPC2.SpecHandler.EthCall do
  @moduledoc """
  Handles the eth_call JSON-RPC method for executing contract calls without creating a transaction.
  """

  alias Blockchain.Contract.MessageCall
  alias Blockchain.Transaction
  alias EVM
  alias EVM.Configuration
  alias JSONRPC2.SpecHandler.CallRequest
  alias MerklePatriciaTree.TrieStorage

  @doc """
  Executes a message call immediately without creating a transaction on the blockchain.

  ## Parameters
    - state: The blockchain state trie
    - call_request: The call request parameters
    - block_number: The block number to execute the call against
    - chain: The blockchain chain configuration
    
  ## Returns
    - {:ok, binary} - The return value of the executed call
    - {:error, _reason} - Error if the call fails
  """
  @spec run(
          TrieStorage.t(),
          CallRequest.t(),
          non_neg_integer(),
          Blockchain.Chain.t()
        ) :: {:ok, binary()} | {:error, any()}
  def run(_state, call_request, block_number, chain) do
    with {:ok, block} <- Blockchain.Block.get_block(block_number, state),
         {:ok, result} <- execute_call(state, call_request, block, chain) do
      {:ok, result}
    else
      error -> error
    end
  end

  defp execute_call(_state, call_request, block, chain) do
    # Get the block state
    block_state = TrieStorage.set_root_hash(state, block.header.state_root)

    # Get the sender account (or use zero address if not specified)
    sender_address = call_request.from || <<0::160>>

    # Get the configuration for the block
    config = Configuration.for_block_number(block.header.number, chain)

    # Set up the message call
    message_call = %MessageCall{
      account_repo: block_state,
      sender: sender_address,
      originator: sender_address,
      recipient: call_request.to || <<0::160>>,
      contract: call_request.to || <<0::160>>,
      available_gas: call_request.gas || 3_000_000,
      gas_price: call_request.gas_price || 0,
      value: call_request.value || 0,
      apparent_value: call_request.value || 0,
      data: call_request.data || <<>>,
      stack_depth: 0,
      block_header: block.header,
      config: config
    }

    # Execute the call
    case MessageCall.execute(message_call) do
      {:ok, {_gas_remaining, _sub_state, _exec_env, output}} ->
        {:ok, output}

      {_gas_remaining, _sub_state, _exec_env, output} ->
        {:ok, output}

      {:error, _reason} = error ->
        error

      _ ->
        {:error, :execution_failed}
    end
  end
end
