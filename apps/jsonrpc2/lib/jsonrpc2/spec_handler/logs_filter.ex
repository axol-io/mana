defmodule JSONRPC2.SpecHandler.LogsFilter do
  @moduledoc """
  Handles filtering of logs for the eth_getLogs JSON-RPC method.
  """

  import JSONRPC2.Response.Helpers

  alias Blockchain.{Block, Transaction}
  alias Blockchain.Transaction.Receipt
  alias ExthCrypto.Hash.Keccak

  @type filter_params :: %{
          fromBlock: binary() | nil,
          toBlock: binary() | nil,
          address: binary() | list(binary()) | nil,
          topics: list(binary() | list(binary()) | nil) | nil,
          blockhash: binary() | nil
        }

  @doc """
  Filters logs based on the provided parameters.

  ## Parameters
    - params: Filter parameters map
    - state_trie: The blockchain state trie
    
  ## Returns
    - {:ok, list} - List of matching logs
    - {:error, _reason} - Error if filtering fails
  """
  @spec filter_logs(map(), MerklePatriciaTree.Trie.t()) :: {:ok, list()} | {:error, any()}
  def filter_logs(_params, state_trie) do
    with {:ok, filter} <- parse_filter_params(params),
         {:ok, blocks} <- get_blocks_in_range(filter, state_trie),
         logs <- collect_logs_from_blocks(blocks, filter, state_trie) do
      {:ok, format_logs(logs)}
    end
  end

  defp parse_filter_params(_params) do
    filter = %{
      from_block: params["fromBlock"] || "latest",
      to_block: params["toBlock"] || "latest",
      addresses: parse_addresses(params["address"]),
      topics: parse_topics(params["topics"]),
      block_hash: params["blockhash"]
    }

    {:ok, filter}
  end

  defp parse_addresses(nil), do: []
  defp parse_addresses(address) when is_binary(address), do: [address]
  defp parse_addresses(addresses) when is_list(addresses), do: addresses

  defp parse_topics(nil), do: []
  defp parse_topics(topics) when is_list(topics), do: topics
  defp parse_topics(_), do: []

  defp get_blocks_in_range(%{block_hash: block_hash}, state_trie) when not is_nil(block_hash) do
    # If blockhash is specified, only get that specific block
    case decode_hex(block_hash) do
      {:ok, hash} ->
        case Block.get_block(hash, state_trie) do
          {:ok, block} -> {:ok, [block]}
          _ -> {:ok, []}
        end

      _ ->
        {:error, :invalid_block_hash}
    end
  end

  defp get_blocks_in_range(%{from_block: from, to_block: to}, state_trie) do
    with {:ok, from_number} <- parse_block_number(from, state_trie),
         {:ok, to_number} <- parse_block_number(to, state_trie) do
      blocks =
        from_number..to_number
        |> Enum.map(fn number ->
          case Block.get_block(number, state_trie) do
            {:ok, block} -> block
            _ -> nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, blocks}
    end
  end

  defp parse_block_number("earliest", _state_trie), do: {:ok, 0}

  defp parse_block_number("latest", _state_trie) do
    # Get the latest block number from the state
    # This is a simplified implementation
    # Integration with blockchain state for latest block number
    {:ok, 0}
  end

  defp parse_block_number("pending", state_trie) do
    parse_block_number("latest", state_trie)
  end

  defp parse_block_number(hex_number, _state_trie) when is_binary(hex_number) do
    decode_unsigned(hex_number)
  end

  defp collect_logs_from_blocks(blocks, filter, state_trie) do
    Enum.flat_map(blocks, fn block ->
      collect_logs_from_block(block, filter, state_trie)
    end)
  end

  defp collect_logs_from_block(block, filter, state_trie) do
    # Get all receipts for this block
    block.transactions
    |> Enum.with_index()
    |> Enum.flat_map(fn {transaction, index} ->
      case get_transaction_receipt(transaction, block, state_trie) do
        {:ok, receipt} ->
          filter_receipt_logs(receipt, transaction, block, index, filter)

        _ ->
          []
      end
    end)
  end

  defp get_transaction_receipt(transaction, block, state_trie) do
    # Get the receipt from the receipts trie
    receipts_trie =
      MerklePatriciaTree.Trie.new(
        MerklePatriciaTree.TrieStorage.set_root_hash(state_trie, block.header.receipts_root)
      )

    # The key is the RLP-encoded transaction index
    key = ExRLP.encode(transaction.transaction_index || 0)

    case MerklePatriciaTree.Trie.get_key(receipts_trie, key) do
      encoded_receipt when not is_nil(encoded_receipt) ->
        {:ok, Receipt.deserialize(encoded_receipt)}

      _ ->
        {:error, :receipt_not_found}
    end
  rescue
    _ -> {:error, :receipt_decode_error}
  end

  defp filter_receipt_logs(receipt, transaction, block, tx_index, filter) do
    receipt.logs
    |> Enum.with_index()
    |> Enum.filter(fn {log, _log_index} ->
      matches_filter?(log, filter)
    end)
    |> Enum.map(fn {log, log_index} ->
      %{
        log: log,
        transaction: transaction,
        block: block,
        transaction_index: tx_index,
        log_index: log_index
      }
    end)
  end

  defp matches_filter?(log, filter) do
    matches_address?(log, filter.addresses) &&
      matches_topics?(log, filter.topics)
  end

  defp matches_address?(_log, []), do: true

  defp matches_address?(log, addresses) do
    Enum.any?(addresses, fn address ->
      case decode_hex(address) do
        {:ok, decoded} -> decoded == log.address
        _ -> false
      end
    end)
  end

  defp matches_topics?(_log, []), do: true

  defp matches_topics?(log, filter_topics) do
    log_topics = log.topics || []

    filter_topics
    |> Enum.with_index()
    |> Enum.all?(fn {filter_topic, index} ->
      case {filter_topic, Enum.at(log_topics, index)} do
        # null means any topic
        {nil, _} ->
          true

        # no topic at this position
        {_, nil} ->
          false

        {filter_topic, log_topic} when is_binary(filter_topic) ->
          case decode_hex(filter_topic) do
            {:ok, decoded} -> decoded == log_topic
            _ -> false
          end

        {filter_topics, log_topic} when is_list(filter_topics) ->
          # OR condition for array of topics
          Enum.any?(filter_topics, fn ft ->
            case decode_hex(ft) do
              {:ok, decoded} -> decoded == log_topic
              _ -> false
            end
          end)
      end
    end)
  end

  defp format_logs(logs) do
    Enum.map(logs, fn log_info ->
      %{
        "address" => encode_hex(log_info.log.address),
        "topics" => Enum.map(log_info.log.topics || [], &encode_hex/1),
        "data" => encode_hex(log_info.log.data || <<>>),
        "blockNumber" => encode_quantity(log_info.block.header.number),
        "transactionHash" => encode_hex(transaction_hash(log_info.transaction)),
        "transactionIndex" => encode_quantity(log_info.transaction_index),
        "blockHash" => encode_hex(block_hash(log_info.block)),
        "logIndex" => encode_quantity(log_info.log_index),
        "removed" => false
      }
    end)
  end

  defp transaction_hash(transaction) do
    transaction
    |> Transaction.serialize()
    |> Keccak.kec()
  end

  defp block_hash(block) do
    Block.hash(block)
  end

  defp encode_hex(binary) when is_binary(binary) do
    "0x" <> Base.encode16(binary, case: :lower)
  end
end
