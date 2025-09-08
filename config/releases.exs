import Config

# Runtime configuration for releases
# This file is evaluated at runtime when the application starts

# Get environment variables
port = String.to_integer(System.get_env("PORT") || "8545")
node_name = System.get_env("NODE_NAME") || "mana@localhost"
discovery_enabled = System.get_env("DISCOVERY_ENABLED", "true") == "true"
max_peers = String.to_integer(System.get_env("MAX_PEERS") || "50")

# Network configuration
config :mana,
  port: port,
  node_name: node_name,
  discovery_enabled: discovery_enabled,
  max_peers: max_peers

# AntidoteDB cluster configuration
antidote_nodes =
  case System.get_env("ANTIDOTE_NODES") do
    nil ->
      [
        {'localhost', 8087},
        {'localhost', 8088},
        {'localhost', 8089}
      ]

    nodes_string ->
      nodes_string
      |> String.split(",")
      |> Enum.map(fn node ->
        [host, port] = String.split(node, ":")
        {String.to_charlist(host), String.to_integer(port)}
      end)
  end

config :mana, MerklePatriciaTree.DB,
  adapter: MerklePatriciaTree.DB.AntidoteOptimized,
  nodes: antidote_nodes,
  connection_opts: [
    timeout: String.to_integer(System.get_env("DB_TIMEOUT") || "10000"),
    connect_timeout: String.to_integer(System.get_env("DB_CONNECT_TIMEOUT") || "5000"),
    keepalive: true,
    nodelay: true
  ]

# HSM Configuration (Enterprise)
if System.get_env("HSM_ENABLED") == "true" do
  config :ex_wire, ExWire.Enterprise.HSMIntegration,
    enabled: true,
    pkcs11_library: System.get_env("PKCS11_LIBRARY") || "/usr/lib/softhsm/libsofthsm2.so",
    slot_id: String.to_integer(System.get_env("HSM_SLOT_ID") || "0"),
    pin: System.get_env("HSM_PIN") || "1234",
    key_label: System.get_env("HSM_KEY_LABEL") || "mana-signing-key"
end

# Monitoring configuration
if System.get_env("TELEMETRY_ENABLED") == "true" do
  config :mana,
    telemetry_enabled: true,
    prometheus_port: String.to_integer(System.get_env("PROMETHEUS_PORT") || "9090")

  config :blockchain, Blockchain.Monitoring.PrometheusExporter,
    enabled: true,
    port: String.to_integer(System.get_env("METRICS_PORT") || "9091")
end

# Logging configuration
log_level =
  case System.get_env("LOG_LEVEL") do
    "debug" -> :debug
    "info" -> :info
    "warning" -> :warning
    "error" -> :error
    _ -> :info
  end

config :logger, level: log_level

# Enable structured logging for production
if System.get_env("STRUCTURED_LOGGING") == "true" do
  config :logger, :console,
    format: {Blockchain.Monitoring.StructuredLogger, :format},
    metadata: [:request_id, :module, :function, :line, :pid]
end

# Performance tuning
config :mana,
  verkle_cache_size: String.to_integer(System.get_env("VERKLE_CACHE_SIZE") || "100000"),
  witness_cache_size: String.to_integer(System.get_env("WITNESS_CACHE_SIZE") || "10000"),
  concurrent_witness_workers: String.to_integer(System.get_env("WITNESS_WORKERS") || "8")

# Layer 2 configuration  
if System.get_env("LAYER2_ENABLED") == "true" do
  config :ex_wire, ExWire.Layer2,
    enabled: true,
    optimism_l1_rpc: System.get_env("OPTIMISM_L1_RPC"),
    arbitrum_l1_rpc: System.get_env("ARBITRUM_L1_RPC"),
    batch_size: String.to_integer(System.get_env("L2_BATCH_SIZE") || "100")
end

# Security hardening
config :mana,
  security_hardening: [
    rate_limiting_enabled: System.get_env("RATE_LIMITING") == "true",
    max_requests_per_second: String.to_integer(System.get_env("MAX_RPS") || "1000"),
    ddos_protection: System.get_env("DDOS_PROTECTION") == "true"
  ]
