defmodule History.RPC.HttpHandler do
  @moduledoc """
  Cowboy HTTP handler for JSON-RPC requests.
  """
  @behaviour :cowboy_handler

  alias History.{Query, Sync, Storage}

  @impl true
  def init(req, state) do
    method = :cowboy_req.method(req)

    case method do
      "POST" ->
        handle_post(req, state)

      "OPTIONS" ->
        # CORS preflight
        req =
          req
          |> :cowboy_req.set_resp_header("access-control-allow-origin", "*")
          |> :cowboy_req.set_resp_header("access-control-allow-methods", "POST, OPTIONS")
          |> :cowboy_req.set_resp_header("access-control-allow-headers", "content-type")

        {:ok, :cowboy_req.reply(204, req), state}

      _ ->
        {:ok, :cowboy_req.reply(405, req), state}
    end
  end

  defp handle_post(req, state) do
    {:ok, body, req} = :cowboy_req.read_body(req)

    response =
      case Jason.decode(body) do
        {:ok, request} when is_list(request) ->
          # Batch request
          results = Enum.map(request, &handle_single_rpc/1)
          Jason.encode!(results)

        {:ok, request} when is_map(request) ->
          # Single request
          result = handle_single_rpc(request)
          Jason.encode!(result)

        {:error, _} ->
          Jason.encode!(%{
            jsonrpc: "2.0",
            id: nil,
            error: %{code: -32700, message: "Parse error"}
          })
      end

    req =
      req
      |> :cowboy_req.set_resp_header("content-type", "application/json")
      |> :cowboy_req.set_resp_header("access-control-allow-origin", "*")

    {:ok, :cowboy_req.reply(200, %{}, response, req), state}
  end

  defp handle_single_rpc(%{"method" => method, "params" => params, "id" => id}) do
    case handle_method(method, params) do
      {:ok, result} ->
        %{jsonrpc: "2.0", id: id, result: result}

      {:error, code, message} ->
        %{jsonrpc: "2.0", id: id, error: %{code: code, message: message}}
    end
  end

  defp handle_single_rpc(%{"method" => method, "id" => id}) do
    handle_single_rpc(%{"method" => method, "params" => [], "id" => id})
  end

  defp handle_single_rpc(_) do
    %{jsonrpc: "2.0", id: nil, error: %{code: -32600, message: "Invalid Request"}}
  end

  defp handle_method("eth_getLogs", [filter]) do
    case Query.get_logs(parse_filter(filter)) do
      {:ok, logs} -> {:ok, logs}
      {:error, reason} -> {:error, -32000, inspect(reason)}
    end
  end

  defp handle_method("eth_blockNumber", _params) do
    case Sync.Pipeline.block_number() do
      {:ok, number} -> {:ok, to_hex(number)}
      {:error, reason} -> {:error, -32000, inspect(reason)}
    end
  end

  defp handle_method("eth_getBlockByNumber", [block_param | _]) do
    block_number = parse_block_number(block_param)

    case Storage.get_block(block_number) do
      {:ok, block} -> {:ok, format_block(block)}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp handle_method("eth_chainId", _params) do
    config = History.Config.load()
    chain_config = History.Config.chain_config(config.chain)
    {:ok, to_hex(chain_config.chain_id)}
  end

  defp handle_method("net_version", _params) do
    config = History.Config.load()
    chain_config = History.Config.chain_config(config.chain)
    {:ok, Integer.to_string(chain_config.chain_id)}
  end

  defp handle_method("web3_clientVersion", _params) do
    {:ok, "Mana-History/0.1.0"}
  end

  defp handle_method(method, _params) do
    {:error, -32601, "Method not found: #{method}"}
  end

  # Helpers

  defp parse_filter(filter) when is_map(filter) do
    %{}
    |> maybe_put(:address, filter["address"])
    |> maybe_put(:topics, filter["topics"])
    |> maybe_put(:from_block, parse_block_number(filter["fromBlock"]))
    |> maybe_put(:to_block, parse_block_number(filter["toBlock"]))
    |> maybe_put(:block_hash, parse_hex(filter["blockHash"]))
  end

  defp parse_filter(_), do: %{}

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_block_number(nil), do: :latest
  defp parse_block_number("latest"), do: :latest
  defp parse_block_number("earliest"), do: :earliest
  defp parse_block_number("pending"), do: :latest

  defp parse_block_number("0x" <> hex) do
    case Integer.parse(hex, 16) do
      {number, ""} -> number
      _ -> :latest
    end
  end

  defp parse_block_number(number) when is_integer(number), do: number
  defp parse_block_number(_), do: :latest

  defp parse_hex(nil), do: nil
  defp parse_hex("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp parse_hex(hex) when is_binary(hex), do: Base.decode16!(hex, case: :mixed)

  defp to_hex(number) when is_integer(number) do
    "0x" <> Integer.to_string(number, 16)
  end

  defp format_block(block) do
    %{
      number: to_hex(block.number),
      hash: block.hash,
      parentHash: block.parent_hash,
      timestamp: to_hex(block.timestamp),
      gasLimit: to_hex(block.gas_limit),
      gasUsed: to_hex(block.gas_used),
      difficulty: to_hex(block.difficulty),
      extraData: block.extra_data
    }
  end
end
