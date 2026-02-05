defmodule History.Application do
  @moduledoc """
  Application supervisor for the History node.

  Starts the stateless sync pipeline, log storage, and query services.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    config = History.Config.load()

    children = [
      # PubSub for real-time event broadcasting
      {Phoenix.PubSub, name: History.PubSub},

      # Telemetry metrics
      {History.Telemetry, []},

      # Sharded log storage
      {History.Storage.Supervisor, config.storage},

      # Bloom filter index for fast log queries
      {History.Index.BloomIndex, config.index},

      # Block header cache
      {History.Cache.Headers, config.cache},

      # Stateless sync pipeline (no EVM execution)
      {History.Sync.Pipeline, config.sync},

      # HTTP + WebSocket server
      {History.RPC.Endpoint, config.rpc}
    ]

    opts = [strategy: :one_for_one, name: History.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
