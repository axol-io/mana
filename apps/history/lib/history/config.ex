defmodule History.Config do
  @moduledoc """
  Configuration for the History node.
  """

  defstruct [
    :chain,
    :data_dir,
    :storage,
    :index,
    :cache,
    :sync,
    :rpc
  ]

  @type t :: %__MODULE__{
          chain: :mainnet | :sepolia | :holesky | atom(),
          data_dir: String.t(),
          storage: keyword(),
          index: keyword(),
          cache: keyword(),
          sync: keyword(),
          rpc: keyword()
        }

  @default_config %{
    chain: :mainnet,
    data_dir: "./data/history",
    storage: [
      shards: 16,
      max_open_files: 256,
      compaction_interval_ms: 300_000
    ],
    index: [
      bits_per_entry: 10,
      expected_entries: 1_000_000_000
    ],
    cache: [
      max_headers: 10_000,
      max_receipts: 1_000
    ],
    sync: [
      batch_size: 100,
      max_peers: 50,
      skip_evm: true,
      checkpoint_interval: 1_000,
      request_timeout_ms: 10_000
    ],
    rpc: [
      enabled: true,
      port: 8545,
      host: "127.0.0.1",
      max_logs_per_query: 10_000,
      max_block_range: 10_000
    ]
  }

  @doc """
  Load configuration from application environment with defaults.
  """
  @spec load() :: t()
  def load do
    app_config = Application.get_all_env(:history)

    config =
      @default_config
      |> deep_merge(Enum.into(app_config, %{}))

    %__MODULE__{
      chain: config.chain,
      data_dir: config.data_dir,
      storage: config.storage,
      index: config.index,
      cache: config.cache,
      sync: config.sync,
      rpc: config.rpc
    }
  end

  @doc """
  Get chain-specific configuration.
  """
  @spec chain_config(atom()) :: %{
          chain_id: non_neg_integer(),
          genesis_hash: binary(),
          bootnodes: [String.t()]
        }
  def chain_config(:mainnet) do
    %{
      chain_id: 1,
      genesis_hash:
        Base.decode16!(
          "D4E56740F876AEF8C010B86A40D5F56745A118D0906A34E69AEC8C0DB1CB8FA3",
          case: :mixed
        ),
      bootnodes: mainnet_bootnodes()
    }
  end

  def chain_config(:sepolia) do
    %{
      chain_id: 11_155_111,
      genesis_hash:
        Base.decode16!(
          "25A5CC106EEA7138ACAB33231D7160D69CB777EE0C2C553FCDDF5138993E6DD9",
          case: :mixed
        ),
      bootnodes: sepolia_bootnodes()
    }
  end

  def chain_config(:holesky) do
    %{
      chain_id: 17_000,
      genesis_hash:
        Base.decode16!(
          "B5F7F912443C940F21FD1E0B9DD60ED3DA3C0C3E0D5BE6F6D0C7B5A01A1A1A1A",
          case: :mixed
        ),
      bootnodes: holesky_bootnodes()
    }
  end

  defp mainnet_bootnodes do
    [
      "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303",
      "enode://22a8232c3abc76a16ae9d6c3b164f98775fe226f0917b0ca871128a74a8e9630b458460865bab457221f1d448dd9791d24c4e5d88786180ac185df813a68d4de@3.209.45.79:30303",
      "enode://2b252ab6a1d0f971d9722cb839a42cb81db019ba44c08754628ab4a823487071b5695317c8ccd085219c3a03af063495b2f1da8d18218da2d6a82981b45e6ffc@65.108.70.101:30303",
      "enode://4aeb4ab6c14b23e2c4cfdce879c04b0748a20d8e9b59e25bbe4467a85c7b7b2e2d5fcf2c6f7a9c6d8b7e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0@65.109.20.50:30303"
    ]
  end

  defp sepolia_bootnodes do
    [
      "enode://9246d00bc8fd1742e5ad2428b80fc4dc45d786283e05ef6edbd9002cbc335d40998444732fbe921cb88e1d2c73d1b1de53bae6a2237996e9bfe14f871baf7066@18.168.182.86:30303",
      "enode://ec66ddcf1a974950bd4c782789a7e04f8aa7c1d2e8e4d9dcb4c4d73a5e5e5a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6@51.141.78.53:30303"
    ]
  end

  defp holesky_bootnodes do
    [
      "enode://ac906289e4b7f12df423d654c5a962b6ebe5b3a74cc9e06571e3ad5e7e5e5a5b6c7d8e9f0a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6@178.128.136.233:30303"
    ]
  end

  defp deep_merge(left, right) when is_map(left) and is_map(right) do
    Map.merge(left, right, fn
      _key, left_val, right_val when is_map(left_val) and is_map(right_val) ->
        deep_merge(left_val, right_val)

      _key, left_val, right_val when is_list(left_val) and is_list(right_val) ->
        Keyword.merge(left_val, right_val)

      _key, _left_val, right_val ->
        right_val
    end)
  end

  defp deep_merge(left, right) when is_list(left) and is_list(right) do
    Keyword.merge(left, right)
  end

  defp deep_merge(_left, right), do: right
end
