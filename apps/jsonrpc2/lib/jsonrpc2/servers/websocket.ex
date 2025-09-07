defmodule JSONRPC2.Servers.WebSocket do
  @behaviour :cowboy_websocket

  require Logger
  alias JSONRPC2.SubscriptionManager

  @moduledoc """
  A server for JSON-RPC 2.0 using WebSocket transport with support for eth_subscribe/eth_unsubscribe.
  """

  def init(req, _state) do
    {:cowboy_websocket, req, state}
  end

  def websocket_init(opts) when is_list(opts) do
    handler = Keyword.fetch!(opts, :handler)

    if !Code.ensure_loaded?(handler) do
      raise ArgumentError,
        message: "Could not load handler for #{inspect(__MODULE__)}, got: #{inspect(handler)}"
    end

    # Register this WebSocket connection
    Logger.info("WebSocket connection established: #{inspect(self())}")

    {:ok, Map.new(opts)}
  end

  def websocket_handle({:text, body_params}, _state = %{handler: _handler}) do
    do_handle_jsonrpc2(body_params, state)
  end

  def websocket_info({:send_notification, notification}, _state) do
    # Send subscription notification to client
    json = Jason.encode!(notification)
    {:reply, {:text, json}, state}
  end

  def websocket_info(_info, _state) do
    {:ok, _state}
  end

  def terminate(_reason, _req, _state) do
    # Cleanup subscriptions when WebSocket disconnects
    Logger.info("WebSocket connection terminated: #{inspect(self())}")
    SubscriptionManager.cleanup_subscriptions(self())
    :ok
  end

  defp do_handle_jsonrpc2(body_params, _state = %{handler: handler}) do
    # Pass WebSocket PID as context for subscription methods
    context = %{ws_pid: self()}

    resp_body =
      case handler.handle(body_params, context) do
        {:reply, reply} -> reply
        :noreply -> ""
      end

    {:reply, {:text, resp_body}, state}
  end
end
