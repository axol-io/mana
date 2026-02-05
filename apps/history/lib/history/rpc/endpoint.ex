defmodule History.RPC.Endpoint do
  @moduledoc """
  Unified HTTP + WebSocket endpoint for the History RPC server.

  Routes:
  - POST / - JSON-RPC over HTTP
  - GET /ws - WebSocket connection
  - GET /health - Health check
  """
  use Supervisor

  require Logger

  def start_link(config) do
    Supervisor.start_link(__MODULE__, config, name: __MODULE__)
  end

  @impl true
  def init(config) do
    enabled = Keyword.get(config, :enabled, true)

    if enabled do
      port = Keyword.get(config, :port, 8545)
      host = Keyword.get(config, :host, "127.0.0.1")

      Logger.info("[History.RPC] Starting HTTP+WS server on #{host}:#{port}")

      dispatch =
        :cowboy_router.compile([
          {:_,
           [
             {"/ws", History.RPC.WebSocket, []},
             {"/health", History.RPC.HealthHandler, []},
             {:_, History.RPC.HttpHandler, []}
           ]}
        ])

      # Use cowboy directly
      case :cowboy.start_clear(:history_rpc, [port: port, ip: parse_host(host)], %{
             env: %{dispatch: dispatch}
           }) do
        {:ok, _pid} ->
          Logger.info("[History.RPC] Server started successfully")

        {:error, reason} ->
          Logger.error("[History.RPC] Failed to start server: #{inspect(reason)}")
      end

      Supervisor.init([], strategy: :one_for_one)
    else
      Supervisor.init([], strategy: :one_for_one)
    end
  end

  defp parse_host(host) when is_binary(host) do
    host
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> List.to_tuple()
  end
end
