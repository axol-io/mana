defmodule ExthCrypto.Application do
  @moduledoc """
  Application module for ExthCrypto.

  This application starts the HSM supervisor if HSM is enabled in configuration.
  """

  use Application
  require Logger

  alias ExthCrypto.HSM.Supervisor, as: HSMSupervisor
  alias ExthCrypto.Hash.Cache

  def start(_type, _args) do
    children = build_children()

    opts = [strategy: :one_for_one, name: ExthCrypto.Supervisor]

    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        Logger.info("ExthCrypto application started")

        if hsm_enabled?() do
          Logger.info("HSM integration is enabled")
        end

        {:ok, pid}

      error ->
        Logger.error("Failed to start ExthCrypto application: #{inspect(error)}")
        error
    end
  end

  defp build_children() do
    children = []

    # Add hash cache for performance optimization
    cache_config = get_cache_config()
    children = [{Cache, cache_config} | children]

    # Add HSM supervisor if HSM is enabled
    children =
      if hsm_enabled?() do
        Logger.info("HSM enabled - starting HSM supervisor")
        [{HSMSupervisor, []} | children]
      else
        Logger.info("HSM disabled - skipping HSM supervisor")
        children
      end

    children
  end

  defp get_cache_config() do
    Application.get_env(:exth_crypto, :hash_cache, [
      max_size: 10_000,
      ttl: 300_000,  # 5 minutes
      cleanup_interval: 60_000,  # 1 minute
      enable_stats: true
    ])
  end

  defp hsm_enabled?() do
    case Application.get_env(:exth_crypto, :hsm, %{}) do
      %{enabled: true} -> true
      config when is_map(config) -> Map.get(config, :enabled, false)
      _ -> false
    end
  end
end
