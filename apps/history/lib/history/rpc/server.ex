defmodule History.RPC.Server do
  @moduledoc """
  JSON-RPC 2.0 server for eth_getLogs and related methods.

  Implements a minimal RPC interface focused on historical log queries.

  ## Supported Methods

  - `eth_getLogs` - Query historical event logs
  - `eth_blockNumber` - Get current synced block number
  - `eth_getBlockByNumber` - Get block header by number
  - `eth_chainId` - Get chain identifier

  ## Usage

  Starts an HTTP server on the configured port (default 8545).
  Compatible with standard Ethereum JSON-RPC clients.
  """
  use Plug.Router

  require Logger

  alias History.{Query, Sync, Storage}

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  def start_link(config) do
    enabled = Keyword.get(config, :enabled, true)

    if enabled do
      port = Keyword.get(config, :port, 8545)
      host = Keyword.get(config, :host, "127.0.0.1")

      Logger.info("[History.RPC] Starting server on #{host}:#{port}")

      Plug.Cowboy.http(__MODULE__, [],
        port: port,
        ip: parse_host(host)
      )
    else
      :ignore
    end
  end

  def child_spec(config) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [config]},
      type: :worker,
      restart: :permanent
    }
  end

  # Routes

  post "/" do
    case handle_rpc(conn.body_params) do
      {:ok, result} ->
        send_json_response(conn, 200, %{
          jsonrpc: "2.0",
          id: conn.body_params["id"],
          result: result
        })

      {:error, code, message} ->
        send_json_response(conn, 200, %{
          jsonrpc: "2.0",
          id: conn.body_params["id"],
          error: %{code: code, message: message}
        })
    end
  end

  match _ do
    send_resp(conn, 404, "Not Found")
  end

  # RPC handlers

  defp handle_rpc(%{"method" => "eth_getLogs", "params" => [filter]}) do
    case Query.get_logs(parse_filter(filter)) do
      {:ok, logs} -> {:ok, logs}
      {:error, reason} -> {:error, -32000, inspect(reason)}
    end
  end

  defp handle_rpc(%{"method" => "eth_blockNumber"}) do
    case Sync.Pipeline.block_number() do
      {:ok, number} -> {:ok, to_hex(number)}
      {:error, reason} -> {:error, -32000, inspect(reason)}
    end
  end

  defp handle_rpc(%{"method" => "eth_getBlockByNumber", "params" => [block_param, _full_txs]}) do
    block_number = parse_block_number(block_param)

    case Storage.get_block(block_number) do
      {:ok, block} -> {:ok, format_block(block)}
      {:error, :not_found} -> {:ok, nil}
    end
  end

  defp handle_rpc(%{"method" => "eth_chainId"}) do
    config = History.Config.load()
    chain_config = History.Config.chain_config(config.chain)
    {:ok, to_hex(chain_config.chain_id)}
  end

  defp handle_rpc(%{"method" => method}) do
    {:error, -32601, "Method not found: #{method}"}
  end

  defp handle_rpc(_) do
    {:error, -32600, "Invalid Request"}
  end

  # Helpers

  defp parse_filter(filter) do
    %{}
    |> maybe_put(:address, filter["address"])
    |> maybe_put(:topics, filter["topics"])
    |> maybe_put(:from_block, parse_block_number(filter["fromBlock"]))
    |> maybe_put(:to_block, parse_block_number(filter["toBlock"]))
    |> maybe_put(:block_hash, parse_hex(filter["blockHash"]))
  end

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

  defp send_json_response(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp parse_host(host) when is_binary(host) do
    host
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end
end
