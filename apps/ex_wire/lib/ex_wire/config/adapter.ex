defmodule ExWire.Config.Adapter do
  @moduledoc """
  Adapter module that bridges the new ConfigManager with the existing
  ExWire.Config module for backward compatibility.
  """

  alias ExWire.ConfigManager

  @doc """
  Initializes the configuration system with legacy support.
  """
  def init do
    # Convert existing Application env to ConfigManager format
    migrate_application_config()

    # Start the ConfigManager if not already started
    case Process.whereis(ConfigManager) do
      nil -> ConfigManager.start_link()
      _ -> :ok
    end
  end

  @doc """
  Gets a configuration value using the legacy key format.
  """
  def get_legacy(key, default \\ nil) do
    path = legacy_key_to_path(key)
    ConfigManager.get(path, default)
  end

  @doc """
  Sets a configuration value using the legacy key format.
  """
  def set_legacy(key, value) do
    path = legacy_key_to_path(key)
    ConfigManager.set(path, value)
  end

  @doc """
  Migrates Application environment configuration to ConfigManager.
  """
  def migrate_application_config do
    config = build_config_from_env()

    # Write to temporary _config for ConfigManager to load
    temp_config = %{
      blockchain: %{
        network: get_chain_network(),
        chain_id: get_chain_id()
      },
      p2p: %{
        port: Application.get_env(:ex_wire, :port, 30303),
        discovery: Application.get_env(:ex_wire, :discovery, true),
        protocol_version: Application.get_env(:ex_wire, :protocol_version, 67),
        p2p_version: Application.get_env(:ex_wire, :p2p_version, 5),
        capabilities: get_capabilities(),
        max_peers: Application.get_env(:ex_wire, :max_peers, 50),
        bootnodes: Application.get_env(:ex_wire, :bootnodes, [])
      },
      sync: %{
        enabled: Application.get_env(:ex_wire, :sync, true),
        mode: get_sync_mode(),
        checkpoint_sync: Application.get_env(:ex_wire, :checkpoint_sync, true),
        warp: Application.get_env(:ex_wire, :warp, false)
      },
      storage: %{
        db_root: Application.get_env(:ex_wire, :db_root, "./db"),
        pruning: Application.get_env(:ex_wire, :pruning, true),
        cache_size: Application.get_env(:ex_wire, :cache_size, 1024)
      },
      consensus: %{
        commitment_count: Application.get_env(:ex_wire, :commitment_count, 1),
        fork_choice_algorithm: "lmd_ghost",
        attestation_processing: "parallel"
      },
      monitoring: %{
        metrics_enabled: Application.get_env(:ex_wire, :metrics_enabled, true),
        metrics_port: Application.get_env(:ex_wire, :metrics_port, 9090)
      },
      security: %{
        private_key: Application.get_env(:ex_wire, :private_key, :random),
        bls_signatures: true,
        slashing_protection: true
      },
      runtime: %{
        mana_version: Application.get_env(:ex_wire, :mana_version, "unknown"),
        environment: Mix.env()
      }
    }

    # Store for ConfigManager initialization
    Application.put_env(:ex_wire, :__migrated_config__, temp_config)

    config
  end

  defp build_config_from_env do
    # Build comprehensive config from Application environment
    %{
      blockchain: build_blockchain_config(),
      p2p: build_p2p_config(),
      sync: build_sync_config(),
      storage: build_storage_config(),
      consensus: build_consensus_config(),
      monitoring: build_monitoring_config(),
      security: build_security_config(),
      runtime: build_runtime_config()
    }
  end

  defp build_blockchain_config do
    chain = Application.get_env(:ex_wire, :chain)

    %{
      network: if(chain, do: to_string(chain), else: "mainnet"),
      chain_id: get_chain_id(),
      eip1559: true
    }
  end

  defp build_p2p_config do
    node_discovery = Application.get_env(:ex_wire, :node_discovery, [])

    %{
      port: Keyword.get(node_discovery, :port, 30303),
      discovery: Application.get_env(:ex_wire, :discovery, true),
      protocol_version: Application.get_env(:ex_wire, :protocol_version, 67),
      p2p_version: Application.get_env(:ex_wire, :p2p_version, 5),
      capabilities: get_capabilities(),
      max_peers: Application.get_env(:ex_wire, :max_peers, 50),
      bootnodes: Application.get_env(:ex_wire, :bootnodes, []),
      public_ip: Application.get_env(:ex_wire, :public_ip, [127, 0, 0, 1])
    }
  end

  defp build_sync_config do
    %{
      enabled: Application.get_env(:ex_wire, :sync, true),
      mode: get_sync_mode(),
      checkpoint_sync: Application.get_env(:ex_wire, :checkpoint_sync, true),
      warp: Application.get_env(:ex_wire, :warp, false),
      parallel_downloads: 10
    }
  end

  defp build_storage_config do
    %{
      db_root: Application.get_env(:ex_wire, :db_root, "./db"),
      pruning: Application.get_env(:ex_wire, :pruning, true),
      pruning_mode: "balanced",
      cache_size: Application.get_env(:ex_wire, :cache_size, 1024)
    }
  end

  defp build_consensus_config do
    %{
      commitment_count: Application.get_env(:ex_wire, :commitment_count, 1),
      fork_choice_algorithm: "lmd_ghost",
      attestation_processing: "parallel",
      max_parallel_attestations: 100
    }
  end

  defp build_monitoring_config do
    %{
      metrics_enabled: Application.get_env(:ex_wire, :metrics_enabled, true),
      metrics_port: Application.get_env(:ex_wire, :metrics_port, 9090),
      grafana_enabled: true,
      prometheus_enabled: true
    }
  end

  defp build_security_config do
    %{
      private_key: Application.get_env(:ex_wire, :private_key, :random),
      bls_signatures: true,
      slashing_protection: true,
      rate_limiting: true
    }
  end

  defp build_runtime_config do
    %{
      mana_version: Application.get_env(:ex_wire, :mana_version, "unknown"),
      environment: Mix.env(),
      node_name: node()
    }
  end

  defp get_capabilities do
    caps = Application.get_env(:ex_wire, :caps, [])

    Enum.map(caps, fn
      {name, version} -> "#{name}/#{version}"
      cap -> to_string(cap)
    end)
  end

  defp get_chain_network do
    case Application.get_env(:ex_wire, :chain) do
      :mainnet -> "mainnet"
      :goerli -> "goerli"
      :sepolia -> "sepolia"
      _ -> "mainnet"
    end
  end

  defp get_chain_id do
    case Application.get_env(:ex_wire, :chain) do
      :mainnet -> 1
      :goerli -> 5
      :sepolia -> 11_155_111
      _ -> 1
    end
  end

  defp get_sync_mode do
    cond do
      Application.get_env(:ex_wire, :warp, false) -> "warp"
      Application.get_env(:ex_wire, :fast_sync, false) -> "fast"
      true -> "full"
    end
  end

  defp legacy_key_to_path(key) when is_atom(key) do
    case key do
      :chain -> [:blockchain, :network]
      :chain_id -> [:blockchain, :chain_id]
      :port -> [:p2p, :port]
      :discovery -> [:p2p, :discovery]
      :protocol_version -> [:p2p, :protocol_version]
      :p2p_version -> [:p2p, :p2p_version]
      :caps -> [:p2p, :capabilities]
      :max_peers -> [:p2p, :max_peers]
      :bootnodes -> [:p2p, :bootnodes]
      :public_ip -> [:p2p, :public_ip]
      :sync -> [:sync, :enabled]
      :warp -> [:sync, :warp]
      :checkpoint_sync -> [:sync, :checkpoint_sync]
      :db_root -> [:storage, :db_root]
      :pruning -> [:storage, :pruning]
      :cache_size -> [:storage, :cache_size]
      :commitment_count -> [:consensus, :commitment_count]
      :private_key -> [:security, :private_key]
      :mana_version -> [:runtime, :mana_version]
      _ -> [key]
    end
  end

  @doc """
  Provides backward compatibility shim for ExWire.Config functions.
  """
  defmacro __using__(_opts) do
    quote do
      import ExWire.Config.Adapter

      # Override the original get_env functions
      def get_env(given_params, key, default \\ nil) do
        if config_manager_available?() do
          ExWire.Config.Adapter.get_legacy(key, default)
        else
          # Fall back to original implementation
          if res = Keyword.get(given_params, key) do
            res
          else
            Application.get_env(:ex_wire, key, default)
          end
        end
      end

      def get_env!(given_params, key) do
        result = get_env(given_params, key)

        if is_nil(result) do
          raise ArgumentError, message: "Please set config variable: _config :ex_wire, #{key}, ..."
        else
          result
        end
      end

      def set_env!(value, key) do
        if config_manager_available?() do
          ExWire.Config.Adapter.set_legacy(key, value)
        else
          Application.put_env(:ex_wire, key, value)
        end

        value
      end

      defp config_manager_available? do
        Process.whereis(ExWire.ConfigManager) != nil
      end
    end
  end
end
