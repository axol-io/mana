# Hardware Security Module Integration

## Overview

Mana-Ethereum integrates with Hardware Security Modules (HSMs) to provide enterprise-grade cryptographic security. HSM integration ensures private keys never exist in software memory and all cryptographic operations are performed in tamper-resistant hardware.

## Supported HSMs

### Network-Attached HSMs
- Thales Luna Network HSM 7
- SafeNet Luna PCIe HSM
- AWS CloudHSM
- Azure Dedicated HSM

### PKCS#11 Compatible
- SoftHSM (software emulation for testing)
- YubiHSM 2
- Nitrokey HSM
- OpenSC compatible smart cards

## Configuration

### Basic HSM Setup

```elixir
# config/hsm.exs
config :ex_wire, :enterprise,
  hsm: [
    enabled: true,
    provider: :pkcs11,
    
    # PKCS#11 library path
    library_path: "/usr/lib/softhsm/libsofthsm2.so",
    
    # HSM slot configuration
    slot_id: 0,
    pin: {:system, "HSM_PIN"},
    
    # Key management
    key_labels: [
      validator: "mana_validator_key",
      node: "mana_node_key",
      api: "mana_api_key"
    ]
  ]
```

### AWS CloudHSM Integration

```elixir
config :ex_wire, :enterprise,
  hsm: [
    enabled: true,
    provider: :aws_cloudhsm,
    
    # CloudHSM cluster configuration
    cluster_id: "cluster-abc123def456",
    region: "us-east-1",
    
    # Authentication
    credentials: [
      crypto_user: {:system, "CLOUDHSM_USER"},
      password: {:system, "CLOUDHSM_PASSWORD"}
    ],
    
    # Client configuration
    client_config: "/opt/cloudhsm/etc/cloudhsm_client.cfg"
  ]
```

### Thales Luna HSM

```elixir
config :ex_wire, :enterprise,
  hsm: [
    enabled: true,
    provider: :luna_hsm,
    
    # Network HSM connection
    server_config: [
      host: "192.168.1.100",
      port: 1792,
      certificate: "/etc/ssl/certs/luna_client.pem",
      private_key: "/etc/ssl/private/luna_client.key"
    ],
    
    # Partition configuration
    partition: "mana_partition",
    partition_password: {:system, "LUNA_PARTITION_PASSWORD"}
  ]
```

## Key Management

### Key Generation

```elixir
defmodule Mana.HSM.KeyManager do
  @moduledoc """
  HSM-based cryptographic key management
  """
  
  def generate_validator_key do
    with {:ok, hsm_session} <- HSM.connect(),
         {:ok, key_handle} <- HSM.generate_key(hsm_session, 
           type: :ecdsa_secp256k1,
           label: "mana_validator_#{timestamp()}",
           extractable: false,
           persistent: true
         ) do
      {:ok, key_handle}
    else
      {:error, reason} -> {:error, "Key generation failed: #{reason}"}
    end
  end
  
  def get_public_key(key_handle) do
    with {:ok, hsm_session} <- HSM.connect(),
         {:ok, public_key_der} <- HSM.export_public_key(hsm_session, key_handle) do
      
      # Convert DER to Ethereum address format
      public_key = :crypto.der_decode(:SubjectPublicKeyInfo, public_key_der)
      address = derive_ethereum_address(public_key)
      
      {:ok, address}
    end
  end
end
```

### Key Usage

```elixir
defmodule Mana.HSM.Signer do
  def sign_transaction(transaction, key_handle) do
    with {:ok, hsm_session} <- HSM.connect(),
         tx_hash <- Blockchain.Transaction.hash(transaction),
         {:ok, signature} <- HSM.sign(hsm_session, key_handle, tx_hash) do
      
      # Convert HSM signature to Ethereum format
      {r, s, recovery_id} = decode_ecdsa_signature(signature)
      
      v = if recovery_id == 0, do: 27, else: 28
      %{transaction | v: v, r: r, s: s}
    end
  end
  
  def sign_block(block, key_handle) do
    with {:ok, hsm_session} <- HSM.connect(),
         block_hash <- Blockchain.Block.hash(block),
         {:ok, signature} <- HSM.sign(hsm_session, key_handle, block_hash) do
      
      Map.put(block, :signature, signature)
    end
  end
end
```

## High Availability

### HSM Clustering

```elixir
config :ex_wire, :enterprise,
  hsm: [
    enabled: true,
    provider: :clustered,
    
    # Multiple HSM instances for redundancy
    cluster: [
      %{
        name: :primary_hsm,
        provider: :luna_hsm,
        host: "hsm-1.internal",
        priority: 1
      },
      %{
        name: :secondary_hsm,
        provider: :luna_hsm, 
        host: "hsm-2.internal",
        priority: 2
      },
      %{
        name: :tertiary_hsm,
        provider: :aws_cloudhsm,
        cluster_id: "cluster-backup",
        priority: 3
      }
    ],
    
    # Failover configuration
    failover: [
      timeout: 5000,
      max_retries: 3,
      retry_delay: 1000
    ]
  ]
```

### Load Balancing

```elixir
defmodule Mana.HSM.LoadBalancer do
  @moduledoc """
  Distributes cryptographic operations across multiple HSMs
  """
  
  def sign_with_load_balancing(data, key_handle) do
    hsm = select_hsm()
    
    case HSM.sign(hsm, key_handle, data) do
      {:ok, signature} -> 
        record_success(hsm)
        {:ok, signature}
      
      {:error, reason} ->
        record_failure(hsm, reason)
        retry_with_next_hsm(data, key_handle)
    end
  end
  
  defp select_hsm do
    # Round-robin with health checks
    get_healthy_hsms()
    |> Enum.min_by(&get_current_load/1)
  end
end
```

## Performance Optimization

### Connection Pooling

```elixir
defmodule Mana.HSM.ConnectionPool do
  use GenServer
  
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end
  
  def get_connection do
    GenServer.call(__MODULE__, :get_connection)
  end
  
  def return_connection(connection) do
    GenServer.cast(__MODULE__, {:return_connection, connection})
  end
  
  def init(opts) do
    pool_size = Keyword.get(opts, :pool_size, 10)
    connections = Enum.map(1..pool_size, fn _ ->
      {:ok, conn} = HSM.connect()
      conn
    end)
    
    {:ok, %{connections: connections, in_use: []}}
  end
  
  def handle_call(:get_connection, from, state) do
    case state.connections do
      [conn | rest] ->
        new_state = %{
          connections: rest,
          in_use: [{conn, from} | state.in_use]
        }
        {:reply, {:ok, conn}, new_state}
      
      [] ->
        {:reply, {:error, :pool_exhausted}, state}
    end
  end
end
```

### Batch Operations

```elixir
defmodule Mana.HSM.BatchOperations do
  def batch_sign(operations, batch_size \\ 10) do
    operations
    |> Enum.chunk_every(batch_size)
    |> Task.async_stream(&process_batch/1, max_concurrency: 4)
    |> Enum.flat_map(fn {:ok, results} -> results end)
  end
  
  defp process_batch(batch) do
    with {:ok, hsm_session} <- HSM.connect() do
      Enum.map(batch, fn {data, key_handle} ->
        HSM.sign(hsm_session, key_handle, data)
      end)
    end
  end
end
```

## Security Features

### Key Rotation

```elixir
defmodule Mana.HSM.KeyRotation do
  @rotation_interval :timer.hours(24 * 30)  # 30 days
  
  def schedule_rotation do
    Process.send_after(self(), :rotate_keys, @rotation_interval)
  end
  
  def rotate_validator_key do
    # Generate new key
    {:ok, new_key} = Mana.HSM.KeyManager.generate_validator_key()
    
    # Update validator configuration
    update_validator_key(new_key)
    
    # Archive old key (keep for signature verification)
    archive_old_key()
    
    # Schedule next rotation
    schedule_rotation()
  end
end
```

### Access Control

```elixir
config :ex_wire, :enterprise,
  hsm: [
    access_control: [
      # Role-based key access
      roles: [
        validator: ["mana_validator_key"],
        api_server: ["mana_api_key"],
        admin: ["mana_validator_key", "mana_api_key", "mana_admin_key"]
      ],
      
      # Time-based restrictions
      time_restrictions: [
        validator: {:always},
        api_server: {:business_hours},
        admin: {:manual_approval}
      ],
      
      # Multi-person control
      dual_control: [
        key_generation: true,
        key_deletion: true,
        configuration_changes: true
      ]
    ]
  ]
```

## Monitoring and Auditing

### HSM Health Monitoring

```elixir
defmodule Mana.HSM.HealthMonitor do
  def check_hsm_health do
    with {:ok, hsm_session} <- HSM.connect(),
         {:ok, info} <- HSM.get_info(hsm_session) do
      
      metrics = %{
        status: info.status,
        temperature: info.temperature,
        free_memory: info.free_memory,
        session_count: info.active_sessions,
        last_error: info.last_error
      }
      
      report_metrics(metrics)
      check_thresholds(metrics)
    end
  end
  
  defp check_thresholds(metrics) do
    cond do
      metrics.temperature > 70 ->
        alert(:critical, "HSM temperature critical: #{metrics.temperature}°C")
      
      metrics.free_memory < 1024 ->
        alert(:warning, "HSM memory low: #{metrics.free_memory}KB")
      
      metrics.session_count > 50 ->
        alert(:warning, "High HSM session count: #{metrics.session_count}")
      
      true ->
        :ok
    end
  end
end
```

### Audit Logging

```elixir
defmodule Mana.HSM.AuditLogger do
  def log_operation(operation, key_id, user, result) do
    audit_entry = %{
      timestamp: DateTime.utc_now(),
      operation: operation,
      key_id: key_id,
      user: user,
      result: result,
      hsm_session_id: get_session_id(),
      source_ip: get_client_ip()
    }
    
    # Write to secure audit log
    write_audit_log(audit_entry)
    
    # Send to SIEM if configured
    if siem_enabled?() do
      send_to_siem(audit_entry)
    end
  end
  
  defp write_audit_log(entry) do
    log_file = "/var/log/mana/hsm_audit.log"
    timestamp = DateTime.to_iso8601(entry.timestamp)
    
    log_line = "#{timestamp} #{entry.operation} key=#{entry.key_id} " <>
               "user=#{entry.user} result=#{entry.result} " <>
               "session=#{entry.hsm_session_id} ip=#{entry.source_ip}\n"
    
    File.write!(log_file, log_line, [:append])
  end
end
```

## Compliance Integration

### FIPS 140-2 Compliance

```elixir
config :ex_wire, :enterprise,
  hsm: [
    compliance: [
      fips_140_2_level: 3,
      enforce_fips_mode: true,
      
      # Algorithm restrictions
      allowed_algorithms: [
        :ecdsa_secp256k1,
        :aes_256_gcm,
        :sha256,
        :sha3_256
      ],
      
      # Key requirements
      key_requirements: [
        min_key_size: 256,
        require_hardware_generation: true,
        non_extractable: true
      ]
    ]
  ]
```

### Common Criteria

```elixir
config :ex_wire, :enterprise,
  hsm: [
    common_criteria: [
      evaluation_level: :eal4,
      protection_profile: "HSM_PP_v1.0",
      
      # Security functions
      required_functions: [
        :key_generation,
        :digital_signature,
        :user_authentication,
        :audit_logging,
        :secure_key_storage
      ]
    ]
  ]
```

## Troubleshooting

### Connection Issues

```bash
# Test HSM connectivity
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --list-slots

# Check HSM status
/opt/mana/bin/mana eval "Mana.HSM.test_connection()"

# View HSM logs
tail -f /var/log/mana/hsm.log
```

### Performance Issues

```bash
# Monitor HSM operations
curl http://localhost:9568/metrics | grep hsm_operations

# Check connection pool status
/opt/mana/bin/mana eval "Mana.HSM.ConnectionPool.status()"
```

### Key Management Issues

```bash
# List available keys
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so --list-objects

# Test key operations
/opt/mana/bin/mana eval "Mana.HSM.KeyManager.test_key_operations()"
```

## Best Practices

### Security
- Use hardware-backed HSMs for production
- Implement dual control for sensitive operations
- Regular key rotation (recommended: 30 days)
- Monitor and audit all HSM operations
- Use role-based access control

### Performance
- Maintain connection pools for high throughput
- Batch operations when possible
- Monitor HSM temperature and performance
- Implement proper failover mechanisms

### Operations
- Regular HSM firmware updates
- Backup HSM configurations securely
- Test disaster recovery procedures
- Monitor HSM health continuously

## Next Steps

- [Compliance](compliance.md) - Enterprise compliance features
- [Support](support.md) - Enterprise support options
- [Security](../deployment/security.md) - Additional security measures