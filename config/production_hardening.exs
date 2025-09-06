# Production Hardening Configuration
#
# This configuration file consolidates all production hardening settings
# for the Mana Ethereum client, including timeouts, rate limits, and
# security configurations.

import Config

# ============================================================================
# GenServer Timeout Configuration
# ============================================================================

# Quick operations (1 second) - Simple queries and status checks
config :common, :quick_timeouts, %{
  get_stats: 1_000,
  get_transaction: 1_000,
  get_pending: 1_000,
  get_next_nonce: 1_000,
  get_balance: 1_000,
  get_block_number: 1_000,
  peer_count: 1_000,
  is_mining: 1_000,
  gas_price: 1_000
}

# Standard operations (5 seconds) - Default timeout for most operations
config :common, :standard_timeouts, %{
  add_transaction: 5_000,
  get_block: 5_000,
  get_logs: 5_000,
  estimate_gas: 5_000,
  get_code: 5_000,
  get_storage_at: 5_000,
  get_proof: 5_000,
  subscribe: 5_000,
  unsubscribe: 5_000
}

# Critical operations (30 seconds) - Long-running operations
config :common, :critical_timeouts, %{
  send_transaction: 30_000,
  sync_block: 30_000,
  validate_block: 30_000,
  import_block: 30_000,
  execute_transaction: 30_000,
  create_block: 30_000,
  verify_proof: 30_000,
  sync_state: 30_000,
  download_snapshot: 30_000
}

# Extreme operations (2 minutes) - Very long operations
config :common, :extreme_timeouts, %{
  initial_sync: 120_000,
  full_validation: 120_000,
  snapshot_generation: 120_000,
  state_migration: 120_000
}

# ============================================================================
# Circuit Breaker Configuration
# ============================================================================

config :ex_wire, :circuit_breakers, %{
  transaction_pool: [
    failure_threshold: 5,
    success_threshold: 2,
    timeout: 10_000,
    half_open_timeout: 30_000
  ],
  sync_manager: [
    failure_threshold: 3,
    success_threshold: 1,
    timeout: 30_000,
    half_open_timeout: 60_000
  ],
  jsonrpc: [
    failure_threshold: 10,
    success_threshold: 3,
    timeout: 5_000,
    half_open_timeout: 15_000
  ],
  state_store: [
    failure_threshold: 3,
    success_threshold: 2,
    timeout: 15_000,
    half_open_timeout: 30_000
  ]
}

# ============================================================================
# Transaction Pool Configuration
# ============================================================================

config :blockchain, :transaction_pool, %{
  # Maximum number of transactions in pool
  max_size: 10_000,

  # Maximum total gas in pool (approximately 1 block worth)
  max_total_gas: 30_000_000,

  # Maximum size of a single transaction in bytes
  # 128 KB
  max_transaction_size: 131_072,

  # Cleanup interval in milliseconds
  # 1 minute
  cleanup_interval: 60_000,

  # Transaction age limit in seconds
  # 1 hour
  max_transaction_age: 3600
}

# ============================================================================
# Rate Limiter Configuration
# ============================================================================

config :jsonrpc2, :rate_limiter, %{
  # Default limits per category
  limits: %{
    read: [
      requests_per_second: 100,
      burst_size: 200
    ],
    write: [
      requests_per_second: 10,
      burst_size: 20
    ],
    compute: [
      requests_per_second: 20,
      burst_size: 40
    ],
    subscribe: [
      requests_per_second: 5,
      burst_size: 10
    ]
  },

  # IP-based rate limiting
  enable_ip_limiting: true,

  # API key rate limiting
  enable_api_key_limiting: true,

  # Token bucket algorithm parameters
  token_bucket: [
    # tokens per second
    refill_rate: 10,
    # maximum tokens
    bucket_size: 100
  ]
}

# ============================================================================
# Input Validation Configuration
# ============================================================================

config :common, :input_validation, %{
  # Size limits in bytes
  # 10 MB
  max_request_size: 10_485_760,
  # 1 MB
  max_param_size: 1_048_576,
  # 5 MB
  max_data_size: 5_242_880,

  # Array and batch limits
  max_array_length: 1000,
  max_batch_size: 100,

  # Security settings
  enable_injection_prevention: true,
  enable_format_validation: true,
  sanitize_inputs: true,

  # Validation strictness
  strict_address_validation: true,
  strict_hash_validation: true,
  allow_unknown_methods: false
}

# ============================================================================
# Error Handler Configuration
# ============================================================================

config :blockchain, :error_handler, %{
  # Error tracking
  track_errors: true,
  error_sample_rate: 1.0,

  # Error categories and their severity
  error_categories: %{
    validation: :warning,
    timeout: :error,
    circuit_breaker: :critical,
    rate_limit: :warning,
    internal: :critical
  },

  # Retry configuration
  enable_retries: true,
  max_retries: 3,
  retry_backoff: :exponential,
  # milliseconds
  base_retry_delay: 1000
}

# ============================================================================
# Telemetry Configuration
# ============================================================================

config :common, :telemetry, %{
  # Enable telemetry events
  enabled: true,

  # Event sampling rate (0.0 to 1.0)
  sampling_rate: 1.0,

  # Events to track
  tracked_events: [
    [:common, :genserver, :call, :*],
    [:jsonrpc, :request, :*],
    [:blockchain, :transaction, :*],
    [:ex_wire, :circuit_breaker, :*],
    [:jsonrpc2, :rate_limiter, :*]
  ],

  # Metrics to export
  export_metrics: true,
  # 1 minute
  metrics_interval: 60_000
}

# ============================================================================
# Production Environment Overrides
# ============================================================================

if config_env() == :prod do
  # More conservative timeouts in production
  config :common, :default_timeout_multiplier, 1.5

  # Stricter rate limits in production
  config :jsonrpc2, :rate_limit_multiplier, 0.8

  # Higher circuit breaker thresholds in production
  config :ex_wire, :circuit_breaker_multiplier, 1.2

  # Enable all security features
  config :common, :security_mode, :strict
end

# ============================================================================
# Development Environment Overrides
# ============================================================================

if config_env() == :dev do
  # Relaxed timeouts for development
  config :common, :default_timeout_multiplier, 2.0

  # Looser rate limits for testing
  config :jsonrpc2, :rate_limit_multiplier, 10.0

  # Lower circuit breaker thresholds for testing
  config :ex_wire, :circuit_breaker_multiplier, 0.5

  # Relaxed security for development
  config :common, :security_mode, :relaxed
end
