# Layer 2 Integration

## Overview

Mana-Ethereum provides native support for Layer 2 scaling solutions, including both Optimistic and ZK rollups. The architecture supports multiple L2 protocols simultaneously with unified state management and cross-layer communication.

## Supported Layer 2 Protocols

### Optimistic Rollups

#### Optimism (Bedrock)
- Complete fraud proof system
- L1 data availability
- Sequencer batch processing
- Fault dispute game with MIPS bisection

#### Arbitrum (Nitro)
- Interactive fraud proofs
- Advanced compression (Brotli)
- Fast confirmation times
- Multi-round challenge protocol

### ZK Rollups

#### zkSync Era
- PLONK proof system
- Account abstraction
- Native token support
- Efficient state transitions

#### Polygon zkEVM
- EVM-equivalent execution
- Recursive SNARKs
- Ethereum compatibility
- Low verification costs

## Architecture

### L2 Processing Stack

```
┌─────────────────────────────────────┐
│            Mana Node                │
├─────────────────────────────────────┤
│  L2 Aggregator                      │
│  - Batch collection                 │
│  - Proof verification               │
│  - State root updates               │
├─────────────────────────────────────┤
│  L2 Protocol Handlers               │
│  - Optimism handler                 │
│  - Arbitrum handler                 │
│  - zkSync handler                   │
├─────────────────────────────────────┤
│  Cross-Layer Bridge                 │
│  - Message passing                  │
│  - Asset transfers                  │
│  - Event monitoring                 │
├─────────────────────────────────────┤
│  Ethereum L1 Integration            │
│  - Block processing                 │
│  - Transaction validation           │
│  - State management                 │
└─────────────────────────────────────┘
```

### Message Flow

```
L2 Sequencer → Mana L2 Handler → Batch Processor → State Update → L1 Submission
     ↓              ↓                ↓              ↓             ↓
   Tx Pool    → Validation    → Proof Gen    → State Root  → Block Include
```

## Proof Systems

### Supported Proof Types

#### Groth16
- Trusted setup required
- Fast verification (~5ms)
- Small proof size (256 bytes)
- Used by early ZK rollups

#### PLONK
- Universal setup
- Medium verification time (~50ms)
- Flexible circuit design
- Used by zkSync, Polygon

#### STARK
- No trusted setup
- Quantum resistant
- Larger proof size (~100KB)
- Post-quantum security

#### FRI/FFLONK
- Fast recursive proofs
- Efficient aggregation
- Low memory requirements
- Next-generation systems

### Proof Verification

```elixir
defmodule Mana.L2.ProofVerifier do
  def verify_proof(proof, public_inputs, system) do
    case system do
      :groth16 -> verify_groth16(proof, public_inputs)
      :plonk -> verify_plonk(proof, public_inputs)
      :stark -> verify_stark(proof, public_inputs)
      :fflonk -> verify_fflonk(proof, public_inputs)
    end
  end
  
  def batch_verify(proofs, system) do
    # Aggregate multiple proofs for efficiency
    aggregate_proof = aggregate_proofs(proofs, system)
    verify_aggregated(aggregate_proof, system)
  end
end
```

## State Management

### L2 State Tracking

```elixir
defmodule Mana.L2.StateManager do
  defstruct [
    :l2_chain_id,
    :sequencer_address,
    :state_root,
    :batch_number,
    :pending_batches,
    :finalized_batches
  ]
  
  def update_state_root(manager, new_root, batch_number) do
    %{manager | 
      state_root: new_root,
      batch_number: batch_number
    }
  end
end
```

### Cross-Layer State Synchronization

```
L1 State:     [Block N] → [Block N+1] → [Block N+2]
                 ↓            ↓            ↓
L2 Batches:   [Batch 1]   [Batch 2]   [Batch 3]
                 ↓            ↓            ↓
L2 State:    [Root A]     [Root B]     [Root C]
```

## Bridge Operations

### Deposit Flow (L1 → L2)

```elixir
defmodule Mana.L2.Bridge.Deposit do
  def process_deposit(l1_tx, l2_chain_id) do
    with {:ok, deposit_event} <- parse_deposit_event(l1_tx),
         {:ok, l2_tx} <- create_l2_transaction(deposit_event),
         {:ok, _} <- validate_deposit(deposit_event) do
      
      # Add to L2 pending transactions
      L2.TransactionPool.add_transaction(l2_tx, l2_chain_id)
    end
  end
end
```

### Withdrawal Flow (L2 → L1)

```elixir
defmodule Mana.L2.Bridge.Withdrawal do
  def initiate_withdrawal(l2_tx, merkle_proof) do
    with {:ok, withdrawal_event} <- parse_withdrawal_event(l2_tx),
         {:ok, _} <- verify_inclusion_proof(merkle_proof),
         {:ok, _} <- start_challenge_period(withdrawal_event) do
      
      schedule_withdrawal_finalization(withdrawal_event)
    end
  end
  
  def finalize_withdrawal(withdrawal_event) do
    # Execute after challenge period
    if challenge_period_expired?(withdrawal_event) do
      execute_l1_transaction(withdrawal_event.l1_tx)
    end
  end
end
```

### Message Passing

```elixir
defmodule Mana.L2.MessagePassing do
  def send_cross_layer_message(from_layer, to_layer, message) do
    encoded_message = encode_message(message)
    
    case {from_layer, to_layer} do
      {:l1, :l2} -> queue_l1_to_l2_message(encoded_message)
      {:l2, :l1} -> queue_l2_to_l1_message(encoded_message)
      {:l2, :l2} -> relay_l2_to_l2_message(encoded_message)
    end
  end
end
```

## Batch Processing

### Optimistic Rollup Batches

```elixir
defmodule Mana.L2.OptimisticBatch do
  defstruct [
    :batch_number,
    :transactions,
    :state_root,
    :parent_hash,
    :timestamp,
    :sequencer_signature
  ]
  
  def process_batch(batch) do
    with {:ok, _} <- validate_batch_signature(batch),
         {:ok, _} <- verify_transaction_sequence(batch.transactions),
         {:ok, new_state_root} <- execute_transactions(batch.transactions) do
      
      update_l2_state(batch.batch_number, new_state_root)
    end
  end
end
```

### ZK Rollup Batches

```elixir
defmodule Mana.L2.ZKBatch do
  defstruct [
    :batch_number,
    :state_transition_proof,
    :new_state_root,
    :transaction_data,
    :public_inputs
  ]
  
  def process_zk_batch(batch) do
    with {:ok, _} <- verify_zk_proof(batch.state_transition_proof, batch.public_inputs),
         {:ok, _} <- validate_state_transition(batch.new_state_root) do
      
      update_l2_state(batch.batch_number, batch.new_state_root)
    end
  end
end
```

## Performance Optimizations

### Proof Aggregation

```elixir
defmodule Mana.L2.ProofAggregation do
  def aggregate_proofs(proofs, system) do
    case system do
      :plonk ->
        # Aggregate multiple PLONK proofs
        aggregate_plonk_proofs(proofs)
      
      :stark ->
        # Recursive STARK composition
        compose_stark_proofs(proofs)
      
      :groth16 ->
        # Batch verification for Groth16
        batch_verify_groth16(proofs)
    end
  end
end
```

### Parallel Processing

```elixir
defmodule Mana.L2.ParallelProcessor do
  def process_batches_parallel(batches) do
    batches
    |> Task.async_stream(&process_single_batch/1, 
                        max_concurrency: System.schedulers_online())
    |> Enum.map(&elem(&1, 1))
  end
end
```

## Configuration

### L2 Protocol Configuration

```elixir
# config/l2.exs
config :ex_wire, :layer2,
  # Enable L2 support
  enabled: true,
  
  # Optimism configuration
  optimism: [
    enabled: true,
    chain_id: 10,
    l1_rpc_url: "https://mainnet.infura.io/v3/YOUR_KEY",
    sequencer_url: "https://mainnet.optimism.io",
    challenge_period: 604800, # 7 days in seconds
    batch_size: 100
  ],
  
  # Arbitrum configuration
  arbitrum: [
    enabled: true,
    chain_id: 42161,
    l1_rpc_url: "https://mainnet.infura.io/v3/YOUR_KEY",
    sequencer_url: "https://arb1.arbitrum.io/rpc",
    confirmation_blocks: 20,
    batch_size: 200
  ],
  
  # zkSync configuration
  zksync: [
    enabled: true,
    chain_id: 324,
    l1_rpc_url: "https://mainnet.infura.io/v3/YOUR_KEY",
    operator_url: "https://mainnet.era.zksync.io",
    proof_system: :plonk,
    batch_size: 500
  ]
```

### Proof Verification Settings

```elixir
config :ex_wire, :proof_verification,
  # Parallel verification
  max_concurrent_verifications: 4,
  
  # Verification timeouts
  groth16_timeout: 5_000,
  plonk_timeout: 60_000,
  stark_timeout: 120_000,
  
  # Proof aggregation
  enable_aggregation: true,
  aggregation_batch_size: 10
```

## Monitoring and Metrics

### L2 Metrics

```
# Batch processing
mana_l2_batches_processed_total{l2_type="optimism"}
mana_l2_batch_processing_time_seconds{l2_type="arbitrum"}

# Proof verification
mana_l2_proofs_verified_total{proof_type="plonk"}
mana_l2_proof_verification_time_seconds{proof_type="stark"}

# Bridge operations
mana_l2_deposits_total{l2_chain="10"}
mana_l2_withdrawals_total{l2_chain="42161"}

# State management
mana_l2_state_root_updates_total
mana_l2_finalized_batches_total
```

### Health Checks

```bash
# L2 service health
curl http://localhost:8080/health/l2

# Response:
{
  "status": "healthy",
  "l2_protocols": {
    "optimism": {"status": "active", "latest_batch": 12345},
    "arbitrum": {"status": "active", "latest_batch": 67890},
    "zksync": {"status": "syncing", "latest_batch": 11111}
  },
  "proof_verification": {
    "queue_size": 5,
    "avg_verification_time_ms": 45
  }
}
```

## Troubleshooting

### Common Issues

#### Batch Processing Delays
```bash
# Check batch queue
curl http://localhost:8080/metrics | grep mana_l2_batch_queue_size

# Monitor processing time
curl http://localhost:8080/metrics | grep mana_l2_batch_processing_time
```

#### Proof Verification Failures
```bash
# Check proof verification errors
tail -f logs/l2_verification.log | grep ERROR

# Verify proof system configuration
mix run -e "Mana.L2.ProofVerifier.test_verification()"
```

#### Bridge Issues
```bash
# Monitor bridge transactions
curl http://localhost:8080/debug/bridge/pending_deposits
curl http://localhost:8080/debug/bridge/pending_withdrawals
```

## Next Steps

- [Enterprise Features](../enterprise/compliance.md) - Enterprise L2 compliance
- [API Reference](../api/json-rpc.md) - L2-specific API methods
- [Load Testing](../testing/load-testing.md) - L2 performance testing