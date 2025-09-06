# Architecture Overview

## Design Philosophy

Mana-Ethereum is built as a distributed Ethereum client designed for enterprise deployment across multiple data centers. The architecture prioritizes fault tolerance, scalability, and regulatory compliance.

## Core Architecture

### Umbrella Application Structure

Mana is structured as an Elixir umbrella project with specialized applications:

```
mana/
├── apps/
│   ├── blockchain/          # Core blockchain logic
│   ├── evm/                 # Ethereum Virtual Machine
│   ├── ex_wire/            # P2P networking & L2 integration
│   ├── cli/                # Command-line interface
│   ├── exth/               # Shared utilities
│   ├── exth_crypto/        # Cryptographic operations
│   ├── merkle_patricia_tree/ # State storage
│   └── jsonrpc2/           # JSON-RPC API server
```

### Application Responsibilities

#### Blockchain
- Block processing and validation
- Transaction pool management
- Account state management
- Chain synchronization
- Consensus rule enforcement

#### EVM
- Smart contract execution
- Gas metering and limits
- EVM instruction implementation
- Storage and memory management
- Error handling and reverts

#### Ex_Wire
- P2P protocol implementation
- Layer 2 integration
- Network discovery and peer management
- Message routing and validation
- Enterprise security features

#### Merkle Patricia Tree
- Ethereum state trie implementation
- Verkle tree support
- Distributed storage backend
- State pruning and archival
- CRDT-based multi-datacenter replication

## Distributed Architecture

### Multi-Datacenter Design

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│   Datacenter A  │    │   Datacenter B  │    │   Datacenter C  │
│                 │    │                 │    │                 │
│  ┌───────────┐  │    │  ┌───────────┐  │    │  ┌───────────┐  │
│  │   Mana    │◄─┼────┼─►│   Mana    │◄─┼────┼─►│   Mana    │  │
│  │   Node    │  │    │  │   Node    │  │    │  │   Node    │  │
│  └─────┬─────┘  │    │  └─────┬─────┘  │    │  └─────┬─────┘  │
│        │        │    │        │        │    │        │        │
│  ┌─────▼─────┐  │    │  ┌─────▼─────┐  │    │  ┌─────▼─────┐  │
│  │ AntidoteDB│  │    │  │ AntidoteDB│  │    │  │ AntidoteDB│  │
│  └───────────┘  │    │  └───────────┘  │    │  └───────────┘  │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Byzantine Fault Tolerance

- Tolerates up to f failures in a 3f+1 system
- Automatic failover and recovery
- Consistent state across all nodes
- Network partition tolerance

### CRDT-Based State Management

- Conflict-free Replicated Data Types
- Eventual consistency guarantees
- Automatic conflict resolution
- Low-latency cross-datacenter replication

## Storage Architecture

### Hybrid Storage Model

```
┌─────────────────────────────────────┐
│            Mana Node                │
├─────────────────────────────────────┤
│  Hot State (ETS)                    │
│  - Recent blocks                    │
│  - Active transactions              │
│  - Peer information                 │
├─────────────────────────────────────┤
│  Warm State (AntidoteDB)            │
│  - Account balances                 │
│  - Contract storage                 │
│  - Historical blocks                │
├─────────────────────────────────────┤
│  Cold Storage (Optional)            │
│  - Archived data                    │
│  - Compliance records               │
└─────────────────────────────────────┘
```

### Verkle Tree Implementation

- 35x performance improvement over Merkle Patricia Trees
- 200-byte witnesses vs 3KB for MPT
- Built-in state expiry mechanism
- Efficient multi-proof generation

## Network Architecture

### P2P Protocol Stack

```
┌─────────────────────────────────────┐
│        Application Layer            │
├─────────────────────────────────────┤
│  Ethereum Wire Protocol (devp2p)   │
├─────────────────────────────────────┤
│     RLPx Encryption Layer          │
├─────────────────────────────────────┤
│    Node Discovery (Kademlia)       │
├─────────────────────────────────────┤
│         TCP/UDP Transport           │
└─────────────────────────────────────┘
```

### Message Flow

1. **Peer Discovery**: Kademlia DHT for peer location
2. **Connection**: RLPx handshake and encryption
3. **Protocol Negotiation**: Capability exchange
4. **Message Exchange**: Block, transaction, and state synchronization

## Processing Architecture

### Actor Model

Built on Elixir's Actor model with supervised processes:

```
┌─────────────────┐
│   Supervisor    │
├─────────────────┤
│  ┌───────────┐  │
│  │   Sync    │  │  Synchronization
│  │ Manager   │  │
│  └───────────┘  │
│  ┌───────────┐  │
│  │Transaction│  │  Transaction Pool
│  │   Pool    │  │
│  └───────────┘  │
│  ┌───────────┐  │
│  │   P2P     │  │  Network Layer
│  │ Manager   │  │
│  └───────────┘  │
│  ┌───────────┐  │
│  │   State   │  │  State Management
│  │ Manager   │  │
│  └───────────┘  │
└─────────────────┘
```

### Concurrent Processing

- Parallel transaction execution
- Concurrent block validation
- Asynchronous I/O operations
- Lock-free data structures

## Security Architecture

### Cryptographic Operations

- Native BLS12-381 signatures (Rust NIFs)
- KZG commitments for blob transactions
- ECDSA for transaction signatures
- HSM integration for key management

### Network Security

- RLPx encryption for all P2P communication
- Peer authentication and verification
- DoS protection mechanisms
- Rate limiting and connection throttling

### Enterprise Security

- Role-Based Access Control (RBAC)
- Hardware Security Module integration
- Audit logging and compliance reporting
- Multi-signature wallet support

## Performance Characteristics

### Throughput

- 15-30 TPS baseline (matching mainnet)
- Up to 100x burst capacity under load testing
- 7.45M storage operations per second
- Sub-second block validation

### Latency

- <100ms transaction pool insertion
- <500ms block propagation
- <1s cross-datacenter synchronization
- <5s P2P message delivery (P99)

### Scalability

- Horizontal scaling via data center addition
- Vertical scaling through process optimization
- Dynamic load balancing
- Automatic resource management

## Next Topics

- [Distributed Consensus](distributed-consensus.md) - Multi-datacenter consensus
- [Layer 2 Integration](layer2-integration.md) - L2 protocol support
- [Verkle Trees](verkle-trees.md) - Advanced state tree implementation