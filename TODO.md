# Mana Ethereum Client - TODO

## DVT Status: Phase 1-3 Complete

### Completed Features
- **DVT Foundation**: Threshold BLS, DKG, Key Management, HSM
- **DVT Consensus**: BFT duties, slashing protection, Byzantine tolerance
- **DVT Communication**: P2P protocols, message auth, partition recovery
- **Performance**: 35x Verkle advantage, <2s consensus latency

### Next: Testnet Deployment
- [ ] DVT testnet validator setup
- [ ] Load testing and optimization
- [ ] Security audit preparation
- [ ] Operator documentation

### DVT Commands
```bash
# Test DVT
mix test apps/ex_wire/test/ex_wire/dvt/

# Start DVT cluster
ExWire.DVT.KeyManager.create_cluster("test", key, 3, 5, nodes)
ExWire.DVT.CommunicationSupervisor.configure_cluster("test", config)
```

---

## Property Testing Infrastructure - COMPLETED

### Issues Fixed (2025-11-15)

#### Root Cause Analysis
The property testing GitHub Actions were failing because critical infrastructure modules were missing:

1. **Missing `Blockchain.PropertyTesting.Framework` Module**
   - Location: `apps/blockchain/lib/blockchain/property_testing/framework.ex`
   - Status: Created
   - This module provides custom macros for enhanced property-based testing:
     - `property_test/2` - Enhanced property tests with better reporting
     - `fuzz_test/4` - Fuzzing tests with configurable iterations and error handling
     - `test_deterministic/2` - Tests for deterministic function behavior
     - `performance_test/4` - Performance validation tests
     - `test_error_handling/2` - Robustness testing for error cases

2. **Missing Generator Functions in `Blockchain.PropertyTesting.Generators`**
   - Location: `apps/blockchain/lib/blockchain/property_testing/generators.ex`
   - Added missing generators:
     - `transaction/0` - Generates random valid transactions
     - `block/0` - Generates random valid blocks
     - `wei_amount/0` - Generates Wei amounts across different ranges
     - `ethereum_address/0` - Generates 20-byte Ethereum addresses

3. **Test File Updates**
   - Files fixed:
     - `apps/blockchain/test/blockchain/property_tests/transaction_property_test.exs`
     - `apps/blockchain/test/blockchain/property_tests/fuzzing_test.exs`
     - `apps/evm/test/evm/property_tests/evm_property_test.exs`
     - `apps/ex_wire/test/ex_wire/property_tests/p2p_property_test.exs`

4. **Created `Blockchain.PropertyTesting.Reporter` Module**
   - Location: `apps/blockchain/lib/blockchain/property_testing/reporter.ex`
   - Provides report generation for property test results (JSON, JUnit XML)

5. **Created `Blockchain.PropertyTesting.Runner` Module**
   - Location: `apps/blockchain/lib/blockchain/property_testing/runner.ex`
   - Provides test execution and benchmarking capabilities

### Adding New Property Tests
1. Use `Blockchain.PropertyTesting.Framework` in your test module
2. Access all generators via `Blockchain.PropertyTesting.Generators`
3. Choose the appropriate macro for your test type:
   - `property_test` for general property testing
   - `fuzz_test` for intensive fuzzing
   - `test_deterministic` for determinism checks
   - `performance_test` for performance validation
   - `test_error_handling` for error case testing

### Adding New Generators
1. Add to `apps/blockchain/lib/blockchain/property_testing/generators.ex`
2. Document with `@doc` annotations
3. Use `StreamData` primitives and combinators

### Known Limitations
- Property tests require longer execution times than unit tests
- Some fuzzing tests are configured to run only on schedule or manual trigger
- Performance benchmarks may vary across different CI runner configurations

### References
- GitHub Actions Workflow: `.github/workflows/property-testing.yml`
- Main CI Workflow: `.github/workflows/ci.yml`
- Property Testing Documentation: https://hexdocs.pm/stream_data/ExUnitProperties.html
