defmodule History.RPC.WebSocket do
  @moduledoc """
  WebSocket server for real-time log subscriptions.

  Implements `eth_subscribe` for log events, compatible with
  standard Ethereum WebSocket clients.

  ## Subscription Types

  - `logs` - Subscribe to new logs matching a filter
  - `newHeads` - Subscribe to new block headers (as they sync)
  - `syncing` - Subscribe to sync status updates

  ## Protocol

  JSON-RPC 2.0 over WebSocket:

      --> {"jsonrpc":"2.0","id":1,"method":"eth_subscribe","params":["logs",{"address":"0x..."}]}
      <-- {"jsonrpc":"2.0","id":1,"result":"0x1"}  // subscription id
      <-- {"jsonrpc":"2.0","method":"eth_subscription","params":{"subscription":"0x1","result":{...}}}
  """
  @behaviour :cowboy_websocket

  require Logger

  alias History.{Query, Sync, Storage}

  defstruct [:subscriptions, :next_sub_id]

  # Cowboy WebSocket callbacks

  @impl true
  def init(req, _opts) do
    state = %__MODULE__{
      subscriptions: %{},
      next_sub_id: 1
    }

    {:cowboy_websocket, req, state, %{idle_timeout: 60_000}}
  end

  @impl true
  def websocket_init(state) do
    # Subscribe to sync events for pushing new logs
    :ok = Phoenix.PubSub.subscribe(History.PubSub, "blocks")
    {:ok, state}
  end

  @impl true
  def websocket_handle({:text, message}, state) do
    case Jason.decode(message) do
      {:ok, request} ->
        handle_rpc(request, state)

      {:error, _} ->
        error = encode_error(nil, -32700, "Parse error")
        {:reply, {:text, error}, state}
    end
  end

  def websocket_handle(_frame, state) do
    {:ok, state}
  end

  @impl true
  def websocket_info({:new_block, block_number, logs}, state) do
    # Push logs to matching subscriptions
    messages =
      state.subscriptions
      |> Enum.filter(fn {_id, sub} -> sub.type == :logs end)
      |> Enum.flat_map(fn {sub_id, sub} ->
        matching_logs = filter_logs_for_subscription(logs, sub.filter)

        Enum.map(matching_logs, fn log ->
          encode_subscription_message(sub_id, log)
        end)
      end)

    # Push new heads to subscribers
    head_messages =
      state.subscriptions
      |> Enum.filter(fn {_id, sub} -> sub.type == :newHeads end)
      |> Enum.map(fn {sub_id, _sub} ->
        case Storage.get_block(block_number) do
          {:ok, block} -> encode_subscription_message(sub_id, format_block(block))
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    all_messages = messages ++ head_messages

    if length(all_messages) > 0 do
      frames = Enum.map(all_messages, &{:text, &1})
      {:reply, frames, state}
    else
      {:ok, state}
    end
  end

  def websocket_info({:sync_status, status}, state) do
    messages =
      state.subscriptions
      |> Enum.filter(fn {_id, sub} -> sub.type == :syncing end)
      |> Enum.map(fn {sub_id, _sub} ->
        encode_subscription_message(sub_id, status)
      end)

    if length(messages) > 0 do
      frames = Enum.map(messages, &{:text, &1})
      {:reply, frames, state}
    else
      {:ok, state}
    end
  end

  def websocket_info(_info, state) do
    {:ok, state}
  end

  # RPC handlers

  defp handle_rpc(%{"method" => "eth_subscribe", "params" => params, "id" => id}, state) do
    case handle_subscribe(params, state) do
      {:ok, sub_id, new_state} ->
        response = encode_result(id, to_hex(sub_id))
        {:reply, {:text, response}, new_state}

      {:error, message} ->
        response = encode_error(id, -32000, message)
        {:reply, {:text, response}, state}
    end
  end

  defp handle_rpc(%{"method" => "eth_unsubscribe", "params" => [sub_id_hex], "id" => id}, state) do
    sub_id = parse_hex_int(sub_id_hex)
    new_subscriptions = Map.delete(state.subscriptions, sub_id)
    response = encode_result(id, true)
    {:reply, {:text, response}, %{state | subscriptions: new_subscriptions}}
  end

  # Also support regular RPC methods over WebSocket
  defp handle_rpc(%{"method" => "eth_getLogs", "params" => [filter], "id" => id}, state) do
    case Query.get_logs(parse_filter(filter)) do
      {:ok, logs} ->
        response = encode_result(id, logs)
        {:reply, {:text, response}, state}

      {:error, reason} ->
        response = encode_error(id, -32000, inspect(reason))
        {:reply, {:text, response}, state}
    end
  end

  defp handle_rpc(%{"method" => "eth_blockNumber", "id" => id}, state) do
    case Sync.Pipeline.block_number() do
      {:ok, number} ->
        response = encode_result(id, to_hex(number))
        {:reply, {:text, response}, state}

      {:error, reason} ->
        response = encode_error(id, -32000, inspect(reason))
        {:reply, {:text, response}, state}
    end
  end

  defp handle_rpc(%{"method" => "eth_chainId", "id" => id}, state) do
    config = History.Config.load()
    chain_config = History.Config.chain_config(config.chain)
    response = encode_result(id, to_hex(chain_config.chain_id))
    {:reply, {:text, response}, state}
  end

  defp handle_rpc(%{"method" => method, "id" => id}, state) do
    response = encode_error(id, -32601, "Method not found: #{method}")
    {:reply, {:text, response}, state}
  end

  defp handle_rpc(_request, state) do
    response = encode_error(nil, -32600, "Invalid Request")
    {:reply, {:text, response}, state}
  end

  # Subscription handlers

  defp handle_subscribe(["logs" | rest], state) do
    filter = if length(rest) > 0, do: parse_filter(hd(rest)), else: %{}

    sub_id = state.next_sub_id

    subscription = %{
      type: :logs,
      filter: filter,
      created_at: System.monotonic_time()
    }

    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, sub_id, subscription),
        next_sub_id: sub_id + 1
    }

    {:ok, sub_id, new_state}
  end

  defp handle_subscribe(["newHeads" | _], state) do
    sub_id = state.next_sub_id

    subscription = %{
      type: :newHeads,
      filter: %{},
      created_at: System.monotonic_time()
    }

    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, sub_id, subscription),
        next_sub_id: sub_id + 1
    }

    {:ok, sub_id, new_state}
  end

  defp handle_subscribe(["syncing" | _], state) do
    sub_id = state.next_sub_id

    subscription = %{
      type: :syncing,
      filter: %{},
      created_at: System.monotonic_time()
    }

    new_state = %{
      state
      | subscriptions: Map.put(state.subscriptions, sub_id, subscription),
        next_sub_id: sub_id + 1
    }

    {:ok, sub_id, new_state}
  end

  defp handle_subscribe([type | _], _state) do
    {:error, "Unsupported subscription type: #{type}"}
  end

  defp handle_subscribe(_, _state) do
    {:error, "Invalid subscription params"}
  end

  # Helpers

  defp filter_logs_for_subscription(logs, filter) do
    Enum.filter(logs, fn log ->
      matches_address?(log, filter) and matches_topics?(log, filter)
    end)
  end

  defp matches_address?(_log, filter) when not is_map_key(filter, :address), do: true

  defp matches_address?(log, %{address: addresses}) when is_list(addresses) do
    normalized = Enum.map(addresses, &normalize_address/1)
    normalize_address(log.address) in normalized
  end

  defp matches_address?(log, %{address: address}) do
    normalize_address(log.address) == normalize_address(address)
  end

  defp matches_topics?(_log, filter) when not is_map_key(filter, :topics), do: true

  defp matches_topics?(log, %{topics: topic_filters}) do
    topic_filters
    |> Enum.with_index()
    |> Enum.all?(fn {filter_topic, index} ->
      log_topic = Enum.at(log.topics, index)
      topic_matches?(log_topic, filter_topic)
    end)
  end

  defp topic_matches?(_log_topic, nil), do: true

  defp topic_matches?(log_topic, filter_topics) when is_list(filter_topics) do
    Enum.any?(filter_topics, fn ft -> log_topic == ft end)
  end

  defp topic_matches?(log_topic, filter_topic), do: log_topic == filter_topic

  defp normalize_address(nil), do: nil

  defp normalize_address(address) when is_binary(address) do
    address |> String.downcase() |> String.replace_prefix("0x", "")
  end

  defp parse_filter(filter) when is_map(filter) do
    %{}
    |> maybe_put(:address, filter["address"])
    |> maybe_put(:topics, filter["topics"])
  end

  defp parse_filter(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_hex_int("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_hex_int(num) when is_integer(num), do: num
  defp parse_hex_int(_), do: 0

  defp to_hex(number) when is_integer(number) do
    "0x" <> Integer.to_string(number, 16)
  end

  defp format_block(block) do
    %{
      number: to_hex(block.number),
      hash: block.hash,
      parentHash: block.parent_hash,
      timestamp: to_hex(block.timestamp)
    }
  end

  defp encode_result(id, result) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, result: result})
  end

  defp encode_error(id, code, message) do
    Jason.encode!(%{jsonrpc: "2.0", id: id, error: %{code: code, message: message}})
  end

  defp encode_subscription_message(sub_id, result) do
    Jason.encode!(%{
      jsonrpc: "2.0",
      method: "eth_subscription",
      params: %{
        subscription: to_hex(sub_id),
        result: result
      }
    })
  end
end
