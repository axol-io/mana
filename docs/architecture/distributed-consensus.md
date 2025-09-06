# Distributed Consensus

## Overview

Mana-Ethereum implements a novel distributed consensus mechanism that allows a single logical Ethereum node to operate across multiple data centers while maintaining Byzantine fault tolerance and consistency with the Ethereum network.

## Consensus Architecture

### Multi-Datacenter Deployment

```
                    ┌─── Ethereum Network ───┐
                    │                        │
                    ▼                        ▼
    ┌──────────────────────┐    ┌──────────────────────┐
    │   Datacenter A       │    │   Datacenter B       │
    │  ┌─────────────────┐ │    │  ┌─────────────────┐ │
    │  │  Mana Instance  │ │◄──►│  │  Mana Instance  │ │
    │  └─────────────────┘ │    │  └─────────────────┘ │
    │  ┌─────────────────┐ │    │  ┌─────────────────┐ │
    │  │   AntidoteDB    │ │◄──►│  │   AntidoteDB    │ │
    │  └─────────────────┘ │    │  └─────────────────┘ │
    └──────────────────────┘    └──────────────────────┘
                    ▲                        ▲
                    │                        │
                    └─── Ethereum Network ───┘
```

### Consensus Properties

- **Byzantine Fault Tolerance**: Tolerates f failures in 3f+1 system
- **Eventual Consistency**: All replicas converge to same state
- **Network Partition Tolerance**: Continues operation during splits
- **Ethereum Compatibility**: Maintains consensus with Ethereum mainnet

## CRDT-Based State Replication

### Conflict-Free Replicated Data Types

Mana uses CRDTs to ensure consistent state across data centers:

#### G-Counter (Grow-only Counter)
```elixir
# Account nonce increments
%GCounter{
  actor_id: :datacenter_a,
  counters: %{
    datacenter_a: 15,
    datacenter_b: 12,
    datacenter_c: 18
  }
}
```

#### OR-Set (Observed-Remove Set)
```elixir
# Transaction pool management
%ORSet{
  added: MapSet.new([tx1, tx2, tx3]),
  removed: MapSet.new([tx4]),
  version_vector: %{datacenter_a: 5, datacenter_b: 3}
}
```

#### LWW-Map (Last-Writer-Wins Map)
```elixir
# Account balance updates
%LWWMap{
  entries: %{
    "0x1234..." => {balance: 1000, timestamp: 1640995200, actor: :datacenter_a}
  }
}
```

### Conflict Resolution

#### Transaction Ordering
```
Datacenter A receives: [tx1, tx2, tx3]
Datacenter B receives: [tx2, tx1, tx4]

Resolution:
1. Deterministic ordering by (nonce, gas_price, timestamp)
2. Conflict detection for same nonce
3. Highest gas price wins
4. Propagate resolution to all datacenters
```

#### State Reconciliation
```
State A: account_balance = 1000 (timestamp: T1)
State B: account_balance = 950  (timestamp: T2, T2 > T1)

Resolution: account_balance = 950 (last-writer-wins)
```

## Byzantine Agreement Protocol

### Three-Phase Consensus

#### Phase 1: Proposal
```
Datacenter A (Leader):
1. Receives new block from Ethereum network
2. Validates block locally
3. Proposes block to other datacenters
4. Includes CRDT merge operations
```

#### Phase 2: Validation
```
Datacenters B, C:
1. Receive block proposal
2. Validate block independently
3. Check CRDT consistency
4. Send validation result to leader
```

#### Phase 3: Commit
```
Datacenter A (Leader):
1. Collects validation results
2. Requires 2f+1 confirmations
3. Commits block if consensus reached
4. Broadcasts commit message
```

### Failure Handling

#### Leader Election
```elixir
defmodule Mana.Consensus.Leader do
  def elect_leader(datacenters) do
    # Deterministic leader selection
    datacenters
    |> Enum.sort()
    |> Enum.at(rem(:os.system_time(), length(datacenters)))
  end
end
```

#### Network Partition Recovery
```elixir
defmodule Mana.Consensus.Recovery do
  def handle_partition_heal(partition_a, partition_b) do
    # 1. Compare version vectors
    # 2. Merge CRDT states
    # 3. Resolve conflicts
    # 4. Synchronize with Ethereum network
    merge_states(partition_a.state, partition_b.state)
  end
end
```

## Performance Characteristics

### Latency Metrics

| Operation | Single DC | Multi-DC | Network Partition |
|-----------|-----------|----------|-------------------|
| Block Processing | 50ms | 150ms | 50ms (local) |
| Transaction Pool | 10ms | 30ms | 10ms (local) |
| State Query | 5ms | 15ms | 5ms (local) |
| Consensus Round | N/A | 200ms | N/A |

### Throughput

- **Normal Operation**: Matches single datacenter performance
- **Partition Tolerance**: Each partition maintains local performance
- **Recovery**: Automatic state synchronization upon heal

## Configuration

### Datacenter Setup

```elixir
# config/distributed.exs
config :ex_wire, :consensus,
  # Datacenter identification
  datacenter_id: :datacenter_a,
  
  # Other datacenters
  peers: [
    datacenter_b: "10.0.1.100:4369",
    datacenter_c: "10.0.2.100:4369"
  ],
  
  # Consensus parameters
  consensus_timeout: 5000,
  max_failures: 1,
  
  # CRDT settings
  merge_interval: 1000,
  conflict_resolution: :lww
```

### Network Configuration

```elixir
config :ex_wire, :network,
  # Inter-datacenter communication
  cluster: [
    enabled: true,
    cookie: :secure_cluster_cookie,
    heartbeat_interval: 1000
  ],
  
  # Failure detection
  failure_detector: [
    phi_threshold: 8.0,
    sample_size: 100,
    min_std_deviation: 0.5
  ]
```

## Monitoring and Observability

### Consensus Metrics

```
# Prometheus metrics
mana_consensus_rounds_total
mana_consensus_latency_seconds
mana_consensus_failures_total
mana_crdt_merge_operations_total
mana_partition_events_total
```

### Health Checks

```bash
# Check consensus status
curl http://localhost:8080/health/consensus

# Response:
{
  "status": "healthy",
  "datacenter": "datacenter_a",
  "role": "leader",
  "peers_connected": 2,
  "last_consensus_round": "2024-01-15T10:30:00Z"
}
```

## Fault Scenarios

### Single Datacenter Failure

```
Normal: A ←→ B ←→ C
Failure: A  ×  B ←→ C

Result:
- B and C continue operation
- A automatically rejoins when recovered
- State synchronized via CRDT merge
```

### Network Partition

```
Partition: A ←→ B    |    C
Result:
- Majority partition (A,B) continues
- Minority partition (C) operates locally
- Automatic healing when network recovers
```

### Byzantine Behavior

```
Scenario: Datacenter A sends conflicting blocks

Detection:
1. Hash mismatch detected by B and C
2. Byzantine failure threshold exceeded
3. A excluded from consensus rounds
4. Manual intervention required
```

## Implementation Details

### CRDT Implementation

```elixir
defmodule Mana.CRDT.AccountState do
  defstruct [:balance, :nonce, :version_vector]
  
  def merge(state1, state2) do
    %__MODULE__{
      balance: max_by_timestamp(state1.balance, state2.balance),
      nonce: max(state1.nonce, state2.nonce),
      version_vector: VV.merge(state1.version_vector, state2.version_vector)
    }
  end
end
```

### Consensus Protocol

```elixir
defmodule Mana.Consensus.Protocol do
  def propose_block(block, peers) do
    # Phase 1: Propose
    proposals = Enum.map(peers, &send_proposal(&1, block))
    
    # Phase 2: Collect votes
    votes = collect_votes(proposals, @consensus_timeout)
    
    # Phase 3: Commit or abort
    if length(votes) >= majority_threshold() do
      commit_block(block)
      broadcast_commit(peers, block)
    else
      abort_consensus_round()
    end
  end
end
```

## Next Steps

- [Layer 2 Integration](layer2-integration.md) - How L2 works with distributed consensus
- [Verkle Trees](verkle-trees.md) - Distributed state tree implementation