defmodule JSONRPC2.SpecHandler do
  use JSONRPC2.Server.Handler

  alias Blockchain.Chain
  alias ExthCrypto.Hash.Keccak
  alias JSONRPC2.Bridge.Sync
  alias JSONRPC2.SpecHandler.CallRequest
  alias JSONRPC2.SpecHandler.GasEstimater
  alias JSONRPC2.Struct.EthSyncing

  import JSONRPC2.Response.Helpers

  # @sync Application.compile_env(:jsonrpc2, :bridge_mock, Sync) # TODO: Unused attribute

  # web3 Methods
  def handle_request("web3_clientVersion", _),
    do: Application.get_env(:jsonrpc2, :mana_version)

  def handle_request("web3_sha3", [param]) do
    with {:ok, binary} <- decode_hex(param) do
      binary
      |> Keccak.kec()
      |> encode_unformatted_data()
    end
  end

  # net Methods
  def handle_request("net_version", _), do: "#{Application.get_env(:ex_wire, :network_id)}"
  def handle_request("net_listening", _), do: Application.get_env(:ex_wire, :discovery)

  def handle_request("net_peerCount", _) do
    connected_peer_count = @sync.connected_peer_count()

    encode_quantity(connected_peer_count)
  end

  # eth Methods
  def handle_request("eth_protocolVersion", _), do: {:error, :not_supported}

  def handle_request("eth_syncing", _) do
    case @sync.last_sync_block_stats() do
      {_current_block_header_number, _starting_block, _highest_block} = params ->
        EthSyncing.output(params)

      false ->
        false
    end
  end

  def handle_request("eth_coinbase", _), do: {:error, :not_supported}
  def handle_request("eth_mining", _), do: {:error, :not_supported}
  def handle_request("eth_hashrate", _), do: {:error, :not_supported}

  def handle_request("eth_gasPrice", _) do
    # Return a default gas price of 20 Gwei (20 * 10^9 wei)
    # This should ideally be calculated based on recent block gas prices
    default_gas_price = 20_000_000_000
    encode_quantity(default_gas_price)
  end

  def handle_request("eth_accounts", _), do: {:error, :not_supported}

  def handle_request("eth_blockNumber", _) do
    {current_block_header_number, _starting_block, _highest_block} = @sync.last_sync_block_stats()

    encode_quantity(current_block_header_number)
  end

  def handle_request("eth_getBalance", [hex_address, hex_number_or_tag]) do
    with {:ok, block_number} <- decode_block_number(hex_number_or_tag),
         {:ok, address} <- decode_hex(hex_address) do
  # @sync.balance(address, block_number) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getStorageAt", [
        hex_storage_address,
        hex_storage_position,
        hex_block_number_or_tag
      ]) do
    with {:ok, storage_address} <- decode_hex(hex_storage_address),
         {:ok, storage_key} <- decode_unsigned(hex_storage_position),
         {:ok, block_number} <- decode_block_number(hex_block_number_or_tag) do
  # @sync.storage(storage_address, storage_key, block_number) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getTransactionCount", [hex_address, hex_block_number_or_tag]) do
    with {:ok, address} <- decode_hex(hex_address) do
      case hex_block_number_or_tag do
        "pending" ->
          # Get nonce including pending transactions
          encode_quantity(Blockchain.TransactionPool.get_next_nonce(address))

        _ ->
          with {:ok, block_number} <- decode_block_number(hex_block_number_or_tag) do
  # @sync.transaction_count(address, block_number) # TODO: Unused attribute
          end
      end
    end
  end

  def handle_request("eth_getBlockTransactionCountByHash", [block_hash_hex]) do
    with {:ok, block_hash} <- decode_hex(block_hash_hex) do
  # @sync.block_transaction_count(block_hash) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getBlockTransactionCountByNumber", [block_number_hex]) do
    with {:ok, block_number} <- decode_unsigned(block_number_hex) do
  # @sync.block_transaction_count(block_number) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getUncleCountByBlockHash", [block_hash_hex]) do
    with {:ok, block_hash} <- decode_hex(block_hash_hex) do
  # @sync.uncle_count(block_hash) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getUncleCountByBlockNumber", [block_number_hex]) do
    with {:ok, block_number} <- decode_unsigned(block_number_hex) do
  # @sync.uncle_count(block_number) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getCode", [hex_address, hex_number_or_tag]) do
    with {:ok, block_number} <- decode_block_number(hex_number_or_tag),
         {:ok, address} <- decode_hex(hex_address) do
  # @sync.code(address, block_number) # TODO: Unused attribute
    end
  end

  def handle_request("eth_sign", _), do: {:error, :not_supported}

  def handle_request("eth_sendTransaction", [_transaction_params]) do
    # This requires wallet functionality to sign transactions
    # Currently not supported as it requires private key management
    {:error, "eth_sendTransaction requires wallet functionality which is not implemented"}
  end

  def handle_request("eth_sendRawTransaction", [raw_transaction]) do
    # Add pre-signed transaction to the pool
    case Blockchain.TransactionPool.add_transaction(raw_transaction) do
      {:ok, transaction_hash} ->
        # Return transaction hash
        transaction_hash

      {:error, _reason} ->
        {:error, _reason}
    end
  end

  def handle_request("eth_call", [raw_call_request, hex_block_number_or_tag]) do
    with {:ok, call_request} <- CallRequest.new(raw_call_request),
         {:ok, block_number} <- decode_block_number(hex_block_number_or_tag) do
      sync_data = @sync.last_sync_state()
      state = sync_data.trie
      chain = Map.get(sync_data, :chain, Chain.load_chain(:foundation))

      case JSONRPC2.SpecHandler.EthCall.run(state, call_request, block_number, chain) do
        {:ok, result} -> encode_unformatted_data(result)
        {:error, _reason} -> nil
      end
    end
  end

  def handle_request("eth_estimateGas", [raw_call_request, hex_block_number_or_tag]) do
    with {:ok, call_request} <- CallRequest.new(raw_call_request),
         {:ok, block_number} <- decode_block_number(hex_block_number_or_tag) do
      sync_data = @sync.last_sync_state()
      state = sync_data.trie
      chain = Map.get(sync_data, :chain, Chain.load_chain(:foundation))

      with {:ok, gas} <- GasEstimater.run(state, call_request, block_number, chain) do
        encode_quantity(gas)
      end
    end
  end

  def handle_request("eth_getBlockByHash", [hex_hash, include_full_transactions]) do
    with {:ok, hash} <- decode_hex(hex_hash) do
  # @sync.block(hash, include_full_transactions) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getBlockByNumber", [number_hex, include_full_transactions]) do
    with {:ok, number} <- decode_unsigned(number_hex) do
  # @sync.block(number, include_full_transactions) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getTransactionByHash", [hex_transaction_hash]) do
    with {:ok, transaction_hash} <- decode_hex(hex_transaction_hash) do
      # First check the transaction pool for pending transactions
      case Blockchain.TransactionPool.get_transaction(transaction_hash) do
        nil ->
          # Not in pool, check blockchain
  # @sync.transaction_by_hash(transaction_hash) # TODO: Unused attribute

        pending_tx ->
          # Return pending transaction
          format_pending_transaction(pending_tx)
      end
    end
  end

  def handle_request("eth_getTransactionByBlockHashAndIndex", [
        block_hash_hex,
        transaction_index_hex
      ]) do
    with {:ok, block_hash} <- decode_hex(block_hash_hex),
         {:ok, transaction_index} <- decode_unsigned(transaction_index_hex) do
  # @sync.transaction_by_block_and_index(block_hash, transaction_index) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getTransactionByBlockNumberAndIndex", [
        block_number_hex,
        transaction_index_hex
      ]) do
    with {:ok, block_number} <- decode_unsigned(block_number_hex),
         {:ok, transaction_index} <- decode_unsigned(transaction_index_hex) do
  # @sync.transaction_by_block_and_index(block_number, transaction_index) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getTransactionReceipt", [hex_transaction_hash]) do
    with {:ok, transaction_hash} <- decode_hex(hex_transaction_hash) do
  # @sync.transaction_receipt(transaction_hash) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getUncleByBlockHashAndIndex", [hex_block_hash, hex_index]) do
    with {:ok, block_hash} <- decode_hex(hex_block_hash),
         {:ok, index} <- decode_unsigned(hex_index) do
  # @sync.uncle(block_hash, index) # TODO: Unused attribute
    end
  end

  def handle_request("eth_getUncleByBlockNumberAndIndex", [hex_block_number, hex_index]) do
    with {:ok, block_number} <- decode_unsigned(hex_block_number),
         {:ok, index} <- decode_unsigned(hex_index) do
  # @sync.uncle(block_number, index) # TODO: Unused attribute
    end
  end

  # eth_getCompilers is deprecated
  def handle_request("eth_getCompilers", _), do: {:error, :not_supported}
  # eth_compileLLL is deprecated
  def handle_request("eth_compileLLL", _), do: {:error, :not_supported}
  # eth_compileSolidity is deprecated
  def handle_request("eth_compileSolidity", _), do: {:error, :not_supported}
  # eth_compileSerpent is deprecated
  def handle_request("eth_compileSerpent", _), do: {:error, :not_supported}

  def handle_request("eth_newFilter", [filter_params]) do
    case JSONRPC2.FilterManager.new_filter(filter_params) do
      {:ok, filter_id} -> filter_id
      _ -> nil
    end
  end

  def handle_request("eth_newBlockFilter", _) do
    case JSONRPC2.FilterManager.new_block_filter() do
      {:ok, filter_id} -> filter_id
      _ -> nil
    end
  end

  def handle_request("eth_newPendingTransactionFilter", _) do
    case JSONRPC2.FilterManager.new_pending_transaction_filter() do
      {:ok, filter_id} -> filter_id
      _ -> nil
    end
  end

  def handle_request("eth_uninstallFilter", [filter_id]) do
    JSONRPC2.FilterManager.uninstall_filter(filter_id)
  end

  def handle_request("eth_getFilterChanges", [filter_id]) do
    case JSONRPC2.FilterManager.get_filter_changes(filter_id) do
      {:ok, changes} -> changes
      _ -> nil
    end
  end

  def handle_request("eth_getFilterLogs", [filter_id]) do
    case JSONRPC2.FilterManager.get_filter_logs(filter_id) do
      {:ok, logs} -> logs
      _ -> nil
    end
  end

  def handle_request("eth_getLogs", [filter_params]) do
    sync_data = @sync.last_sync_state()
    state_trie = sync_data.trie

    case JSONRPC2.SpecHandler.LogsFilter.filter_logs(filter_params, state_trie) do
      {:ok, logs} -> logs
      {:error, _reason} -> []
    end
  end

  def handle_request("eth_getWork", _), do: {:error, :not_supported}
  def handle_request("eth_submitWork", _), do: {:error, :not_supported}
  def handle_request("eth_submitHashrate", _), do: {:error, :not_supported}
  def handle_request("eth_getProof", _), do: {:error, :not_supported}

  def handle_request("eth_pendingTransactions", _) do
    # Return all pending transactions from the pool
    pending_txs =
      Blockchain.TransactionPool.get_pending_transactions()
      |> Enum.map(&format_pending_transaction/1)

    pending_txs
  end

  # WebSocket subscription methods
  def handle_request("eth_subscribe", [subscription_type | _params], %{ws_pid: ws_pid})
      when is_pid(ws_pid) do
    # Extract params based on subscription type
    subscription_params =
      case {subscription_type, params} do
        {"logs", [filter_params]} -> filter_params
        {_, []} -> %{}
        {_, [p]} -> p
        _ -> %{}
      end

    case JSONRPC2.SubscriptionManager.subscribe(subscription_type, subscription_params, ws_pid) do
      {:ok, subscription_id} -> subscription_id
      {:error, _reason} -> {:error, _reason}
    end
  end

  def handle_request("eth_subscribe", _params, _context) do
    {:error, "eth_subscribe is only available over WebSocket connections"}
  end

  def handle_request("eth_unsubscribe", [subscription_id], %{ws_pid: ws_pid})
      when is_pid(ws_pid) do
    case JSONRPC2.SubscriptionManager.unsubscribe(subscription_id, ws_pid) do
      {:ok, result} -> result
      {:error, _reason} -> {:error, _reason}
    end
  end

  def handle_request("eth_unsubscribe", _params, _context) do
    {:error, "eth_unsubscribe is only available over WebSocket connections"}
  end

  # db_putString is deprecated
  def handle_request("db_putString", _), do: {:error, :not_supported}
  # db_getString is deprecated
  def handle_request("db_getString", _), do: {:error, :not_supported}
  # db_putHex is deprecated
  def handle_request("db_putHex", _), do: {:error, :not_supported}
  # db_getHex is deprecated
  def handle_request("db_getHex", _), do: {:error, :not_supported}
  def handle_request("shh_post", _), do: {:error, :not_supported}
  def handle_request("shh_version", _), do: {:error, :not_supported}
  def handle_request("shh_newIdentity", _), do: {:error, :not_supported}
  def handle_request("shh_hasIdentity", _), do: {:error, :not_supported}
  def handle_request("shh_newGroup", _), do: {:error, :not_supported}
  def handle_request("shh_addToGroup", _), do: {:error, :not_supported}
  def handle_request("shh_newFilter", _), do: {:error, :not_supported}
  def handle_request("shh_uninstallFilter", _), do: {:error, :not_supported}
  def handle_request("shh_getFilterChanges", _), do: {:error, :not_supported}
  def handle_request("shh_getMessages", _), do: {:error, :not_supported}

  # Verkle Tree Methods
  def handle_request("verkle_getWitness", _params) do
    alias JSONRPC2.SpecHandler.Verkle
    Verkle.get_witness(params)
  end

  def handle_request("verkle_verifyProof", _params) do
    alias JSONRPC2.SpecHandler.Verkle
    Verkle.verify_proof(params)
  end

  def handle_request("verkle_getMigrationStatus", _params) do
    alias JSONRPC2.SpecHandler.Verkle
    Verkle.get_migration_status(params)
  end

  def handle_request("verkle_getStateMode", _params) do
    alias JSONRPC2.SpecHandler.Verkle
    Verkle.get_state_mode(params)
  end

  def handle_request("verkle_getTreeStats", _params) do
    alias JSONRPC2.SpecHandler.Verkle
    Verkle.get_tree_stats(params)
  end

  defp decode_block_number(hex_block_number_or_tag) do
    case hex_block_number_or_tag do
      "pending" -> {:ok, @sync.highest_block_number()}
      "latest" -> {:ok, @sync.highest_block_number()}
      "earliest" -> {:ok, @sync.starting_block_number()}
      hex_number -> decode_unsigned(hex_number)
    end
  end

  defp format_pending_transaction(tx) do
    %{
      # Pending transactions have no block
      "blockHash" => nil,
      "blockNumber" => nil,
      "from" => encode_unformatted_data(Map.get(tx, :from, <<0::160>>)),
      "gas" => encode_quantity(Map.get(tx, :gas_limit, tx[:gas])),
      "gasPrice" => encode_quantity(tx.gas_price),
      "hash" => encode_unformatted_data(tx.hash),
      "input" => encode_unformatted_data(Map.get(tx, :data, <<>>)),
      "nonce" => encode_quantity(tx.nonce),
      "to" => if(tx.to, do: encode_unformatted_data(tx.to), else: nil),
      # No index for pending
      "transactionIndex" => nil,
      "value" => encode_quantity(Map.get(tx, :value, 0)),
      "v" => encode_quantity(Map.get(tx, :v, 0)),
      "r" => encode_quantity(Map.get(tx, :r, 0)),
      "s" => encode_quantity(Map.get(tx, :s, 0))
    }
  end
end
