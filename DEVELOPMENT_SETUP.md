# Mana-Ethereum Development Setup Guide

## Quick Start

Get up and running with Mana-Ethereum development in under 10 minutes.

### Prerequisites
- **Elixir 1.18.4** with Erlang/OTP 26+
- **Rust 1.75+** (for native extensions)
- **PostgreSQL 15+** (optional, for metadata)
- **Docker & Docker Compose** (for services)

### Installation

1. **Clone and Setup**
   ```bash
   git clone https://github.com/your-org/mana-ethereum.git
   cd mana-ethereum
   
   # Install dependencies
   mix deps.get
   mix local.hex --force
   mix local.rebar --force
   ```

2. **Compile with Native Extensions**
   ```bash
   # Full compilation (first time)
   mix compile
   
   # Fast development compilation (skip Rust NIFs)
   RUSTLER_SKIP_COMPILE=1 mix compile
   ```

3. **Start Development Services**
   ```bash
   # Start AntidoteDB and monitoring
   docker-compose up -d
   
   # Or use individual services
   ./scripts/start-antidote.sh
   ./scripts/start-monitoring.sh
   ```

### Development Commands (from .claude/CLAUDE.md)

```bash
# Fast iteration (skip native compilation)
alias mtest='RUSTLER_SKIP_COMPILE=1 mix test'

# Check everything before commit
alias mcheck='mix format && mix credo --strict && mix test --exclude slow'

# Layer 2 development
alias ml2='MIX_ENV=test mix test --only layer2 --trace'

# Quick consensus tests
alias mcons='MIX_ENV=test mix test apps/ex_wire/test/ex_wire/eth2/ --only consensus_spec'

# Performance benchmarks
alias mbench='mix benchmark.verkle && MIX_ENV=test mix run -e "ExWire.Layer2.PerformanceBenchmark.run_full_benchmark()"'
```

## Development Workflow

### Code Organization
```
mana/
├── apps/
│   ├── blockchain/      # Core blockchain logic
│   ├── evm/            # Ethereum Virtual Machine
│   ├── ex_wire/        # P2P networking & Layer 2
│   ├── cli/            # Command-line interface
│   ├── common/         # Shared utilities
│   ├── exth_crypto/    # Cryptographic operations
│   ├── jsonrpc2/       # JSON-RPC API server
│   ├── merkle_patricia_tree/ # Storage & Verkle trees
│   └── mana/           # Main application
├── config/             # Configuration files
├── docs/              # Documentation
├── scripts/           # Development & deployment scripts
└── monitoring/        # Observability stack
```

### Testing Strategy

#### Test Categories
- **Unit Tests**: Individual function testing (`mix test`)
- **Integration Tests**: Cross-module functionality
- **Property Tests**: StreamData-based generative testing
- **Consensus Tests**: Ethereum Common Tests compliance
- **Performance Tests**: Benchmarks for critical paths
- **Enterprise Tests**: HSM, RBAC, compliance features

#### Running Tests
```bash
# All tests (excluding CI-only)
mix test --exclude network --exclude skip_ci --exclude byzantine_fault --exclude rocksdb_required --exclude antidote_integration

# Specific test suites
mix test apps/blockchain/test/         # Blockchain tests
mix test apps/ex_wire/test/ex_wire/eth2/ --only consensus_spec  # Consensus tests
MIX_ENV=test mix test --only layer2    # Layer 2 tests
mix test --only enterprise             # Enterprise features

# Performance tests
mix benchmark.verkle                   # Verkle tree benchmarks
mix test --only performance           # Performance test suite
```

### Code Quality

#### Formatting and Linting
```bash
mix format                    # Format code
mix format --check-formatted  # Check formatting
mix credo --strict           # Static analysis
mix dialyzer                 # Type checking
```

#### Pre-commit Checklist
1. `mix format` - Format all code
2. `mix credo --strict` - Pass all linting rules  
3. `mix test --exclude slow` - Pass all fast tests
4. `mix dialyzer` - Pass type checking
5. Performance regression check if modifying critical paths

### Development Environment

#### VS Code Setup
```json
// .vscode/settings.json
{
    "elixir.projectPath": ".",
    "elixir.dialyzerEnabled": true,
    "elixir.formatOnSave": true,
    "elixir.testOnSave": true,
    "rust-analyzer.linkedProjects": [
        "./apps/ex_wire/native/bls_nif/Cargo.toml",
        "./apps/ex_wire/native/kzg_nif/Cargo.toml",
        "./apps/merkle_patricia_tree/native/verkle_crypto/Cargo.toml"
    ]
}
```

#### Environment Variables
```bash
# .env file
export MIX_ENV=dev
export RUSTLER_SKIP_COMPILE=1  # Fast development
export LOG_LEVEL=info
export ANTIDOTE_NODES=localhost:8087
export HSM_ENABLED=false       # Disable HSM for development
```

## Feature Development

### Adding New EIPs

1. **VM Changes** (apps/evm/)
   ```elixir
   # apps/evm/lib/evm/operation/eip_xxxx.ex
   defmodule EVM.Operation.EipXXXX do
     @spec execute(EVM.state()) :: EVM.state()
     def execute(state) do
       # Implementation
     end
   end
   ```

2. **Consensus Changes** (apps/blockchain/)
   ```elixir
   # apps/blockchain/lib/blockchain/eip_xxxx.ex
   defmodule Blockchain.EipXXXX do
     def apply_changes(state, block) do
       # Implementation
     end
   end
   ```

3. **Tests**
   ```elixir
   # test/evm/operation/eip_xxxx_test.exs
   defmodule EVM.Operation.EipXXXXTest do
     use ExUnit.Case
     # Test cases
   end
   ```

### Layer 2 Integration

1. **Protocol Implementation** (apps/ex_wire/lib/ex_wire/layer2/)
2. **Batch Processing** (flow-based concurrent processing)
3. **Proof Verification** (ZK/Optimistic rollups)
4. **State Synchronization** (L1 ↔ L2 communication)

### Verkle Tree Development

```elixir
# Verkle tree operations
tree = VerkleTree.new()
updated_tree = VerkleTree.put(tree, key, value)
{value, proof} = VerkleTree.get_with_proof(updated_tree, key)
witness = VerkleTree.Witness.generate(updated_tree, [key])
```

Performance considerations:
- Use batch operations for multiple keys
- Leverage native crypto (Rust NIFs) for production
- Cache frequently accessed nodes
- Monitor witness generation performance

## Enterprise Features

### HSM Integration Development

```elixir
# Test HSM functionality
config :ex_wire, ExWire.Enterprise.HSMIntegration,
  enabled: true,
  test_mode: true,  # Use SoftHSM for development
  pkcs11_library: "/usr/lib/softhsm/libsofthsm2.so"
```

### Compliance Framework

```elixir
# Add new compliance check
defmodule Blockchain.Compliance.CustomCompliance do
  use Blockchain.Compliance.BaseCompliance
  
  def audit(state) do
    # Custom compliance logic
  end
end
```

## Performance Development

### Benchmarking

```bash
# Verkle tree performance
mix benchmark.verkle

# Layer 2 throughput  
MIX_ENV=test mix run -e "ExWire.Layer2.PerformanceBenchmark.run_full_benchmark()"

# Custom benchmarks
mix run scripts/custom_benchmark.exs
```

### Profiling

```elixir
# Profile specific functions
:fprof.apply(&VerkleTree.batch_put/2, [tree, operations])
:fprof.profile()
:fprof.analyse()

# Memory profiling
:recon.proc_count(:memory, 10)
:observer.start()  # GUI profiler
```

## Native Development (Rust)

### Verkle Crypto (apps/merkle_patricia_tree/native/)
```bash
cd apps/merkle_patricia_tree/native/verkle_crypto
cargo build                    # Debug build
cargo build --release         # Production build
cargo test                     # Run Rust tests
```

### BLS/KZG NIFs (apps/ex_wire/native/)
```bash
cd apps/ex_wire/native/bls_nif
cargo build --release
cargo test

cd ../kzg_nif  
cargo build --release
cargo test
```

## Debugging

### Common Issues

#### Compilation Failures
```bash
# Clean and rebuild
mix deps.clean --all
mix clean
rm -rf _build deps
mix deps.get
mix compile --force
```

#### Test Failures
```bash
# Run single test with trace
mix test test/path/to/test.exs:line_number --trace

# Debug failing test
require IEx; IEx.pry()  # Add to test code
```

#### Performance Issues
```bash
# Check ETS memory usage
:ets.i()

# Monitor GenServer processes
:sys.get_status(ProcessName)

# Profile memory allocation
:recon_alloc.memory(resident)
```

### Development Tools

#### IEx Helpers
```elixir
# In iex
h VerkleTree.put/3           # Get help
v(1)                         # Get previous result
recompile()                  # Recompile changed files
:observer.start()            # Start observer GUI
```

#### Database Inspection
```bash
# AntidoteDB
docker exec -it antidote antidote-admin status
docker exec -it antidote antidote-admin info

# Local ETS inspection
:ets.tab2list(:verkle_cache)
```

## Contributing

### Pull Request Process
1. Fork repository
2. Create feature branch: `git checkout -b feature/amazing-feature`
3. Run full test suite: `mix test --exclude network`
4. Ensure code quality: `mix format && mix credo --strict`
5. Add performance benchmarks for critical path changes
6. Submit PR with detailed description

### Code Style
- Follow existing Elixir conventions
- Use meaningful module and function names
- Add `@doc` and `@spec` for public functions
- Write comprehensive tests
- Benchmark performance-critical changes

### Commit Messages
```
type(scope): brief description

Longer description if needed.

- Specific change 1
- Specific change 2

Performance impact: +15% throughput
Breaking change: None
```

## Resources

### Documentation
- [Elixir Guides](https://hexdocs.pm/elixir/)
- [Verkle Trees Specification](https://notes.ethereum.org/@vbuterin/verkle_tree_eip)
- [EIP-4844 Specification](https://eips.ethereum.org/EIPS/eip-4844)
- [AntidoteDB Documentation](https://antidotedb.gitbook.io/documentation/)

### Development Community
- [Ethereum Research](https://ethresear.ch/)
- [Elixir Forum](https://elixirforum.com/)
- [Rust in Blockchain](https://rustinblockchain.org/)

---

Happy coding! 🚀