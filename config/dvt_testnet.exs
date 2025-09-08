# DVT Testnet Configuration
# Configuration for DVT validator deployment on Ethereum testnets

import Config

# DVT Core Configuration
config :ex_wire, :dvt,
  # Testnet environment settings
  environment: :testnet,
  # Primary testnet for DVT validation
  network: :hoodi,

  # DVT Cluster Settings
  cluster_config: %{
    default_threshold: 3,
    default_total_nodes: 5,
    max_clusters_per_node: 10,
    partition_tolerance: :minority,
    auto_recovery_enabled: true,
    max_recovery_attempts: 5
  },

  # Communication Settings (Phase 3)
  p2p_config: %{
    listen_port: 9000,
    discovery_enabled: true,
    max_peers: 50,
    # 5 seconds
    heartbeat_interval: 5_000,
    # 30 seconds
    message_timeout: 30_000
  },

  # Authentication Settings
  auth_config: %{
    key_type: :ed25519,
    # 5 minutes
    replay_window_seconds: 300,
    max_clock_skew_seconds: 30,
    sequence_gap_threshold: 100
  },

  # Partition Detection Settings
  partition_config: %{
    # 15 seconds
    heartbeat_timeout: 15_000,
    # 30 seconds
    consensus_timeout: 30_000,
    # 33% unreachable = partition
    partition_threshold: 0.33,
    # 5 seconds
    recovery_probe_interval: 5_000,
    auto_recovery: true
  },

  # GossipSub Optimization
  gossipsub_config: %{
    mesh_degree: 6,
    mesh_degree_low: 4,
    mesh_degree_high: 8,
    gossip_lazy: 3,
    # 500ms for low latency
    heartbeat_interval: 500,
    # 30 seconds
    fanout_ttl: 30_000,
    message_cache_size: 1000
  },

  # Performance Monitoring
  monitoring_config: %{
    metrics_enabled: true,
    prometheus_port: 9090,
    log_level: :info,
    performance_tracking: true,
    network_analytics: true
  }

# Ethereum Testnet Settings
config :blockchain,
  # Multi-testnet configuration - supports hoodi, ephemery, kurtosis
  network: :hoodi,

  # Network-specific configurations
  networks: %{
    hoodi: %{
      chain_id: 17001,
      genesis_hash: "0xb5f7f912443c940f21fd611f12828d75b534364ed9e2ddr3c3a2ae00bb07acb3",
      beacon_nodes: [
        "https://hoodi-beacon-api.stakingfacilities.com",
        "https://hoodi.beaconstate.ethstaker.cc"
      ]
    },
    ephemery: %{
      # Ephemery chain ID
      chain_id: 39_438_000,
      genesis_hash: "0x4b363db94e286120d76eb905340fdd4e54bfe9f06bf33ff6cf5ad27f511bfe95",
      beacon_nodes: [
        "https://ephemery-beacon.pk910.de",
        "https://beacon.ephemery.dev"
      ]
    },
    kurtosis: %{
      # Local kurtosis network
      chain_id: 3_151_908,
      genesis_hash: "0x83c7e1b0a85065c0f3c2f7c0e8e0c7e0f3c2f7c0e8e0c7e0f3c2f7c0e8e0c7e0",
      beacon_nodes: [
        # Local kurtosis beacon node
        "http://localhost:4000",
        "http://localhost:4001"
      ]
    }
  },

  # Validator settings for DVT
  validator_config: %{
    # DVT-specific validator settings
    distributed_validation: true,
    threshold_signatures: true,
    slashing_protection: :enhanced,

    # Beacon chain endpoints - dynamically selected based on network
    # Will be set based on networks config above
    beacon_nodes: :dynamic,

    # DVT coordination settings
    # slots
    duty_lookahead: 2,
    # ms
    attestation_deadline: 4000,
    # ms
    proposal_deadline: 1000,
    # ms
    sync_committee_deadline: 500
  }

# Database Configuration for DVT State
config :merkle_patricia_tree,
  # Use AntidoteDB for distributed state in testnet
  storage_backend: :antidote,
  antidote_config: %{
    hosts: [
      {"antidote-1.dvt-testnet.mana.network", 8087},
      {"antidote-2.dvt-testnet.mana.network", 8087},
      {"antidote-3.dvt-testnet.mana.network", 8087}
    ],
    bucket: "dvt_testnet_state",
    read_concurrency: :eventual,
    transaction_protocol: :clocksi
  }

# Enterprise Features for Testnet
config :ex_wire, :enterprise,
  # RBAC for DVT operators
  rbac_enabled: true,
  rbac_config: %{
    operator_roles: [:validator, :aggregator, :proposer],
    permission_matrix: %{
      validator: [:attest, :sync_committee],
      aggregator: [:attest, :sync_committee, :aggregate],
      proposer: [:attest, :sync_committee, :aggregate, :propose]
    },
    # 1 hour
    session_timeout: 3600
  },

  # Audit logging for testnet operations
  audit_config: %{
    enabled: true,
    log_level: :info,
    destinations: [:file, :elasticsearch],
    retention_days: 30,
    sensitive_data_masking: true
  },

  # HSM integration (testnet uses software HSM)
  hsm_config: %{
    # For testnet - production would use hardware
    provider: :software_hsm,
    key_derivation: :bip32,
    backup_enabled: true,
    backup_locations: [
      "s3://mana-dvt-testnet-backups/keys/",
      "/mnt/secure-backup/dvt-keys/"
    ]
  }

# Networking Configuration
config :ex_wire,
  # LibP2P settings for DVT testnet
  libp2p_config: %{
    listen_addresses: [
      "/ip4/0.0.0.0/tcp/9000",
      "/ip6/::/tcp/9000"
    ],

    # Testnet bootstrap nodes
    bootstrap_nodes: [
      "/ip4/18.138.108.67/tcp/9000/p2p/16Uiu2HAm7Qwe19vz9WzD2Mxn7fXd1vgHHp4iccuyq7TxwRXoAGfc",
      "/ip4/18.218.102.47/tcp/9000/p2p/16Uiu2HAmA9xa5e_Sfqy7xHqB7se8a7uqvpZqwmcDOKJMXhRf1YwM"
    ],

    # Discovery settings
    mdns_enabled: true,
    dht_enabled: true,

    # Security settings
    noise_handshake: true,
    yamux_multiplexing: true
  }

# Logging Configuration
config :logger,
  level: :info,
  compile_time_purge_matching: [
    [level_lower_than: :info]
  ]

config :logger, :console,
  format: "[$level] $time $metadata$message\n",
  metadata: [:cluster_id, :node_id, :duty_type, :slot, :validator_index]

# JSON-RPC Configuration for DVT Management
config :jsonrpc2,
  # DVT management API endpoints
  dvt_handlers: [
    {"dvt_getClusterStatus", ExWire.DVT.API.ClusterStatus},
    {"dvt_getNetworkHealth", ExWire.DVT.API.NetworkHealth},
    {"dvt_getValidatorDuties", ExWire.DVT.API.ValidatorDuties},
    {"dvt_createCluster", ExWire.DVT.API.CreateCluster},
    {"dvt_joinCluster", ExWire.DVT.API.JoinCluster},
    {"dvt_leaveCluster", ExWire.DVT.API.LeaveCluster}
  ],

  # Security settings for API
  cors_enabled: true,
  rate_limiting: %{
    enabled: true,
    requests_per_minute: 60,
    burst_size: 10
  }

# Telemetry and Monitoring
config :telemetry_poller,
  measurements: [
    # DVT-specific metrics
    {ExWire.DVT.Telemetry, :cluster_health, []},
    {ExWire.DVT.Telemetry, :consensus_latency, []},
    {ExWire.DVT.Telemetry, :partition_events, []},
    {ExWire.DVT.Telemetry, :message_throughput, []},

    # System metrics
    {:process_info, event: [:memory, :message_queue_len]},
    {__MODULE__, :dispatch_system_metrics, []}
  ],
  period: :timer.seconds(10)

# Prometheus metrics export
config :prometheus, :instrumenters, [ExWire.DVT.PrometheusInstrumenter]

# Development/Testing Overrides
if Mix.env() == :dev do
  config :ex_wire, :dvt,
    # Faster timeouts for development
    partition_config: %{
      heartbeat_timeout: 5_000,
      consensus_timeout: 10_000,
      recovery_probe_interval: 2_000
    }
end

if Mix.env() == :test do
  config :ex_wire, :dvt,
    # Very fast timeouts for testing
    partition_config: %{
      heartbeat_timeout: 1_000,
      consensus_timeout: 2_000,
      recovery_probe_interval: 500
    },

    # Disable external dependencies
    p2p_config: %{
      discovery_enabled: false,
      max_peers: 5
    }
end
