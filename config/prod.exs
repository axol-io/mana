# Production Configuration for Mana-Ethereum with Optimized Verkle Trees
# This configuration enables all performance optimizations for maximum throughput

import Config

# Core Application Configuration
config :mana,
  # Network and P2P settings
  network_id: 1,
  bootnodes: [
    "enode://d860a01f9722d78051619d1e2351aba3f43f943f6f00718d1b9baa4101932a1f5011f16bb2b1bb35db20d6fe28fa0bf09636d26a87d31de9ec6203eeedb1f666@18.138.108.67:30303"
  ],

  # Enable production performance features
  performance_mode: :production,
  metrics_enabled: true,
  telemetry_enabled: true

# Verkle Trees Production Configuration
config :merkle_patricia_tree,
  # Core Verkle settings
  verkle_enabled: true,
  verkle_version: "1.0.0",

  # Performance Optimizations
  verkle_cache_enabled: true,
  # 4GB cache for production
  verkle_cache_size: 4_294_967_296,
  # 5 minutes
  verkle_cache_cleanup_interval: 300_000,
  # Clean at 85% full
  verkle_cache_cleanup_threshold: 0.85,

  # SIMD and Parallel Processing
  verkle_simd_enabled: true,
  # Increased for production
  verkle_simd_batch_size: 16,
  verkle_parallel_enabled: true,
  verkle_parallel_workers: System.schedulers_online() * 2,
  # Use parallel for 64+ operations
  verkle_parallel_threshold: 64,

  # Memory Management
  verkle_memory_pools_enabled: true,
  # Pre-allocated witness buffers
  verkle_witness_pool_size: 1000,
  # Pre-allocated hash states
  verkle_hash_state_pool_size: 500,
  verkle_memory_mapped_storage: true,
  # 128MB segments
  verkle_mmap_segment_size: 134_217_728,
  # 4GB max mapped memory
  verkle_mmap_max_segments: 32,

  # Cryptographic Settings
  # Use Rust NIFs
  verkle_crypto_backend: :native,
  verkle_batch_verification: true,
  verkle_batch_witness_generation: true,
  verkle_commitment_scheme: :pedersen,

  # Network Protocol Optimization
  # Large batches for production
  verkle_network_batch_size: 256,
  verkle_network_compression_enabled: true,
  verkle_network_compression_threshold: 4096,
  verkle_witness_compression_enabled: true,
  verkle_adaptive_batching: true,
  # 30 second timeout
  verkle_request_timeout: 30_000,
  verkle_max_concurrent_requests: System.schedulers_online() * 4,

  # State Management
  verkle_state_sync_enabled: true,
  verkle_witness_based_sync: true,
  verkle_state_healing_enabled: true,
  # Validate with 3 peers
  verkle_cross_validation_peers: 3,
  verkle_incremental_healing: true,

  # Cache Strategy
  verkle_predictive_prefetching: true,
  verkle_access_pattern_learning: true,
  verkle_sequential_access_optimization: true,
  verkle_cache_warming_enabled: true,

  # Monitoring and Metrics
  verkle_metrics_enabled: true,
  verkle_performance_dashboard_enabled: true,
  verkle_alert_thresholds: %{
    error_rate_percent: 0.5,
    latency_p99_us: 100,
    cache_hit_rate_percent: 90.0,
    memory_usage_percent: 85.0,
    throughput_ops_per_sec: 1_000_000
  },
  verkle_telemetry_enabled: true,
  verkle_detailed_metrics: true

# AntidoteDB Configuration for 7.45M ops/sec
config :antidote,
  # Connection settings
  hostname: ~c"localhost",
  # Load balanced port
  port: 8086,

  # Connection pooling for high throughput
  connection_pool_size: 100,
  connection_pool_overflow: 50,
  connection_timeout: 10_000,

  # Performance settings
  batch_size: 1000,
  batch_timeout: 10,
  read_concurrency: 10,
  write_concurrency: 10,

  # Consistency settings optimized for performance
  default_bucket_properties: %{
    # Replicate to 3 nodes
    n_val: 3,
    # Read from 1 replica (fast reads)
    r: 1,
    # Write to 1 replica (fast writes)
    w: 1,
    # No primary read requirement
    pr: 0,
    # No primary write requirement
    pw: 0
  }

# Database Configuration
config :mana, MerklePatriciaTree.DB,
  # Use AntidoteDB for production storage
  adapter: MerklePatriciaTree.DB.AntidoteOptimized,

  # Connection settings
  nodes: [
    # Direct nodes for maximum performance
    {~c"localhost", 8087},
    {~c"localhost", 8088},
    {~c"localhost", 8089}
  ],

  # Performance tuning
  connection_opts: [
    {:timeout, 10_000},
    {:connect_timeout, 5_000},
    {:keepalive, true},
    {:nodelay, true}
  ]

# ExWire P2P Configuration
config :ex_wire,
  # Network settings
  port: 30303,
  discovery_enabled: true,
  max_peers: 100,

  # Verkle protocol settings
  verkle_protocol_enabled: true,
  verkle_witness_request_timeout: 15_000,
  verkle_max_concurrent_witness_requests: 32,
  verkle_compression_enabled: true,
  verkle_batch_witness_requests: true,

  # Performance optimizations
  # 128KB buffers
  tcp_buffer_size: 131_072,
  tcp_nodelay: true,
  tcp_keepalive: true

# Blockchain Configuration
config :blockchain,
  # State transition optimizations
  verkle_state_enabled: true,
  verkle_witness_validation: true,
  parallel_transaction_processing: true,
  transaction_pool_size: 10_000,

  # Block processing
  # 30MB blocks
  max_block_size: 30_000_000,
  block_gas_limit: 30_000_000,

  # Memory management
  # 2GB state cache
  state_cache_size: 2_147_483_648

# EVM Configuration
config :evm,
  # Performance settings
  precompiles_enabled: true,
  native_arithmetic: true,
  memory_expansion_optimized: true,

  # Gas settings
  gas_limit: 30_000_000,
  # 20 gwei
  gas_price: 20_000_000_000

# Telemetry and Monitoring
config :telemetry,
  enabled: true,
  metrics: [
    # Verkle tree metrics
    "verkle.operation.duration",
    "verkle.cache.hit_rate",
    "verkle.witness.generation_time",
    "verkle.network.throughput",
    "verkle.memory.usage",

    # Database metrics
    "antidote.operation.duration",
    "antidote.connection.pool_size",
    "antidote.throughput.ops_per_sec",

    # System metrics
    "vm.memory.total",
    "vm.memory.processes",
    "vm.schedulers.utilization"
  ]

# Logging Configuration
config :logger,
  level: :info,
  backends: [
    :console,
    {LoggerFileBackend, :info_log},
    {LoggerFileBackend, :error_log}
  ]

config :logger, :info_log,
  path: "logs/info.log",
  level: :info,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :module, :function]

config :logger, :error_log,
  path: "logs/error.log",
  level: :error,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :module, :function, :line]

# Prometheus Metrics Export
config :prometheus, Mana.MetricsExporter,
  # Metrics server
  port: 9090,
  path: "/metrics",
  format: :auto,

  # Verkle-specific metrics
  custom_metrics: [
    {:verkle_operations_total, :counter, "Total Verkle operations"},
    {:verkle_operation_duration_microseconds, :histogram,
     "Verkle operation duration in microseconds"},
    {:verkle_cache_hit_rate_percent, :gauge, "Verkle cache hit rate percentage"},
    {:verkle_witness_size_bytes, :histogram, "Verkle witness size in bytes"},
    {:verkle_memory_usage_bytes, :gauge, "Verkle memory usage in bytes"},
    {:verkle_throughput_ops_per_second, :gauge, "Verkle throughput in operations per second"}
  ]

# Production Security Settings
config :mana,
  # Network security
  # Allow HTTP for local development
  secure_connections_only: false,
  rate_limiting_enabled: true,
  max_requests_per_minute: 10_000,

  # Resource limits
  # 8GB memory limit
  max_memory_usage: 8_589_934_592,
  # 80% CPU limit
  max_cpu_usage: 80,

  # Monitoring
  health_check_enabled: true,
  health_check_port: 8080,
  health_check_path: "/health"

# Runtime Configuration
config :mana,
  # Performance tuning
  erlang_vm_args: [
    # 2M processes
    "+P 2097152",
    # 1M ports  
    "+Q 1048576",
    # 128KB distribution buffer
    "+zdbbl 131072",
    # Scheduler bind type
    "+sbwt very_short",
    # Scheduler wakeup threshold
    "+swt very_low",
    # Scheduler wakeup strategy
    "+sws legacy",
    # Scheduler utilization balancing
    "+sub true",
    # Scheduler preferred process priority
    "+spp true",
    # Break ignore
    "+B i"
  ]
