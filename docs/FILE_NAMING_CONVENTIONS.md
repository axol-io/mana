# File Naming Conventions for Mana-Ethereum

## Overview

This document establishes file naming conventions to ensure code quality and prevent AI-generated generic names that lack semantic meaning.

## Prohibited Patterns

### AI-Generated Generic Prefixes/Suffixes
Avoid these common AI-generated patterns:

**Prohibited:**
- `simple_*` → Use specific feature names instead
- `comprehensive_*` → Use `full_*` or `complete_*` if needed  
- `optimized_*` → Use `*_cache`, `*_fast`, or specific optimization type
- `enhanced_*` → Use `*_v2`, `*_extended`, or describe the enhancement
- `advanced_*` → Use specific technical terms
- `basic_*` → Use the core feature name without qualifier
- `improved_*` → Describe the specific improvement
- `extended_*` → Describe what was extended
- `generic_*` → Always use specific names
- `default_*` → Use `standard_*` or the actual default type

### Vague Utility Patterns
**Prohibited:**
- `*_helper` (except in `test/support/`)
- `*_utils` → Use `*_tools`, `*_operations`, or specific domain
- `*_misc` → Break into focused modules
- `*_common` → Use shared domain-specific names

### Temporary/Placeholder Patterns
**Prohibited:**
- `temp_*`
- `tmp_*` 
- `new_*` (unless specifically about "new" functionality)
- `old_*`
- `test_*` (outside actual test files)

## Recommended Naming Patterns

### Domain-Driven Names
Use names that reflect the business domain:

**Good Examples:**
```
# Blockchain Domain
transaction_pool.ex          # Not: simple_pool.ex
block_validator.ex           # Not: enhanced_validator.ex  
consensus_engine.ex          # Not: advanced_consensus.ex
merkle_proof_generator.ex    # Not: optimized_proof.ex

# P2P Networking
peer_discovery.ex            # Not: simple_discovery.ex
message_handler.ex           # Not: comprehensive_handler.ex
connection_manager.ex        # Not: advanced_manager.ex

# Cryptography  
signature_verifier.ex        # Not: enhanced_verifier.ex
key_derivation.ex            # Not: advanced_crypto.ex
hash_calculator.ex           # Not: optimized_hash.ex

# Storage
trie_node_cache.ex           # Not: advanced_cache.ex
state_storage.ex             # Not: comprehensive_storage.ex
witness_generator.ex         # Not: optimized_witness.ex
```

### Performance-Specific Names
When performance is the distinguishing factor:

**Good Examples:**
```
# Instead of optimized_*
verkle_cache.ex              # Cache-based optimization
parallel_processor.ex        # Parallelization optimization  
batch_validator.ex          # Batch processing optimization
streaming_parser.ex         # Streaming optimization

# Instead of enhanced_*
transaction_pool_v2.ex      # Version-based enhancement
extended_api.ex             # Extension-based enhancement
multi_sig_validator.ex      # Feature-based enhancement
```

### Module Organization
Organize by responsibility and layer:

```
# Core Logic
blockchain/
├── transaction.ex
├── block.ex  
├── account.ex
└── state_manager.ex

# Performance Layer
blockchain/performance/
├── batch_processor.ex
├── parallel_validator.ex
└── cache_manager.ex

# Enterprise Features  
enterprise/
├── hsm_integration.ex
├── audit_logger.ex
└── compliance_reporter.ex
```

## File Naming Rules

### 1. Use Snake Case
- All files: `snake_case.ex`
- Test files: `module_name_test.exs`

### 2. Be Specific and Descriptive
- Describe the primary responsibility
- Use domain terminology
- Avoid implementation details in names

### 3. Module Name Matches File Name
```elixir
# File: apps/blockchain/lib/blockchain/transaction_validator.ex
defmodule Blockchain.TransactionValidator do
  # ...
end
```

### 4. Test Files Mirror Implementation
```
lib/blockchain/transaction_validator.ex
test/blockchain/transaction_validator_test.exs
```

### 5. Grouping Related Functionality
Use directories for related functionality:

```
# Good
ex_wire/eth2/
├── beacon_state.ex
├── attestation_processor.ex  
├── sync_committee.ex
└── validator_registry.ex

# Not recommended
ex_wire/
├── simple_eth2.ex
├── comprehensive_beacon.ex
├── advanced_sync.ex
└── optimized_validator.ex
```

## Validation

### Automated Checking
The codebase includes `mix check_file_naming` to detect prohibited patterns:

```bash
# Check file naming conventions
mix check_file_naming

# Strict mode (fails CI)
mix check_file_naming --strict

# Run with ex_check
mix check
```

### Manual Review Checklist
Before creating new files:

- [ ] Does the name describe the primary responsibility?
- [ ] Would a new developer understand the purpose from the name?
- [ ] Does it use domain-specific terminology?
- [ ] Does it avoid AI-generated generic patterns?
- [ ] Does the module name match the file name?

## Migration Guidelines

### Renaming Existing Files

1. **Use Git to preserve history:**
   ```bash
   git mv old_name.ex new_name.ex
   ```

2. **Update module definitions:**
   ```elixir
   # Update module name to match new file name
   defmodule NewModuleName do
   ```

3. **Update all references:**
   - Import statements
   - Alias declarations  
   - Function calls
   - Test files
   - Documentation

4. **Update test files:**
   ```bash
   git mv old_name_test.exs new_name_test.exs
   ```

### Common Refactoring Patterns

```elixir
# Before: Generic AI names
defmodule ExWire.SimpleSync do      # → ExWire.BlockSync
defmodule Blockchain.SimplePool do  # → Blockchain.BasicTransactionPool  
defmodule VerkleTree.AdvancedCache do # → VerkleTree.NodeCache

# After: Specific, descriptive names
defmodule ExWire.BlockSync do
defmodule Blockchain.BasicTransactionPool do
defmodule VerkleTree.NodeCache do
```

## Exceptions

### Allowed Generic Names
Some contexts permit generic names:

1. **Test Support Files:**
   ```
   test/support/test_helper.ex     ✓ Allowed
   test/support/data_helper.ex     ✓ Allowed
   ```

2. **Mix Tasks (when appropriate):**
   ```
   lib/mix/tasks/benchmark.ex      ✓ Allowed
   lib/mix/tasks/validate.ex       ✓ Allowed
   ```

3. **Benchmark Files:**
   ```
   bench/simple_benchmark.exs      ✓ Allowed (benchmarks can be simple)
   ```

4. **Scripts (more flexible):**
   ```
   scripts/simple_test.exs         ✓ Allowed (scripts can be simple)
   ```

## Benefits

Following these conventions provides:

1. **Code Clarity:** Names immediately convey purpose
2. **Maintainability:** Easier to locate and understand code
3. **Team Productivity:** Faster onboarding and collaboration
4. **Quality Assurance:** Prevents lazy AI-generated naming
5. **Professional Standards:** Industry-standard naming practices

## Enforcement

- **Pre-commit:** Automated checking via `mix check`
- **CI Pipeline:** Fails builds with generic names in strict mode
- **Code Review:** Manual verification during PR reviews
- **Documentation:** This guide serves as the standard reference

---

For questions or naming suggestions, consult with the development team or reference domain-specific terminology in the Ethereum specification.