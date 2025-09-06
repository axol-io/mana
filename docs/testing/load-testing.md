# Load Testing Framework

## Overview

The Mana Ethereum client includes a comprehensive load testing framework designed to validate performance under mainnet-scale conditions. The framework can simulate realistic Ethereum workloads, stress test system limits, and identify performance bottlenecks.

## Quick Start

```bash
# Run default load test suite
mix load_test

# Run specific scenario
mix load_test --scenario mainnet --duration 300

# Use custom configuration
mix load_test --config config/load_test_config.json

# Generate detailed report
mix load_test --scenario stress --report
```

## Test Scenarios

### Baseline
Establishes baseline performance metrics with simple workloads.

```bash
mix load_test --scenario baseline
```

### Mainnet Simulation
Simulates realistic Ethereum mainnet conditions:
- 15-30 TPS throughput
- 12-second block times
- Mixed transaction types (60% transfers, 30% contracts, 10% DeFi)
- EIP-1559 gas dynamics
- MEV activity patterns

```bash
mix load_test --scenario mainnet --duration 600
```

### Stress Testing
Finds system breaking points by gradually increasing load:
- High transaction rates (up to 100x normal)
- Large blocks (up to 5000 transactions)
- State bloat simulation
- Memory pressure testing
- Concurrent request handling

```bash
mix load_test --scenario stress
```

### Edge Cases
Tests error handling and edge conditions:
- Zero gas price transactions
- Maximum gas limit transactions
- Chain reorganizations
- Invalid transaction floods
- Duplicate nonce handling

```bash
mix load_test --scenario edge
```

### Network Resilience
Tests performance under adverse network conditions:
- Latency spikes (up to 1 second)
- Packet loss (up to 10%)
- Network partitions
- Bandwidth limitations

```bash
mix load_test --scenario network
```

### Layer 2 Load Testing
Tests Layer 2 implementations under load:
- Optimism batch processing
- Arbitrum sequencer performance
- zkSync proof generation

```bash
mix load_test --scenario layer2
```

## Configuration

### Command Line Options

| Option | Description | Default |
|--------|-------------|---------|
| `--scenario` | Test scenario to run | `full` |
| `--duration` | Test duration in seconds | `60` |
| `--accounts` | Number of test accounts | `1000` |
| `--tps` | Target transactions per second | `15` |
| `--config` | Path to JSON config file | - |
| `--output` | Output directory for results | `./load_test_results` |
| `--prometheus` | Enable Prometheus export | `true` |
| `--report` | Generate HTML report | `true` |
| `--verbose` | Enable verbose logging | `false` |

### Configuration File

Create a `load_test_config.json`:

```json
{
  "scenario": "mainnet",
  "duration": 300,
  "accounts": 10000,
  "target_tps": 15,
  
  "mainnet_simulation": {
    "block_time_seconds": 12,
    "gas_limit": 30000000,
    "base_fee_gwei": 30
  },
  
  "stress_test": {
    "max_tps_multiplier": 100,
    "max_block_size": 5000
  },
  
  "network_conditions": {
    "latency_ms": 20,
    "packet_loss_rate": 0.001,
    "bandwidth_mbps": 100
  }
}
```

## Transaction Patterns

The framework generates realistic transaction workloads:

### Transaction Types
- **Simple Transfers** (60%): Basic ETH transfers
- **Token Transfers** (20%): ERC20 token operations
- **Contract Calls** (15%): Smart contract interactions
- **Complex Operations** (5%): DeFi swaps, NFT mints, etc.

### Special Events
- **NFT Drops**: Burst of 100-200 TPS targeting single contract
- **DeFi Liquidations**: High-priority complex transactions
- **Gas Wars**: Escalating gas prices during high demand
- **MEV Activity**: Sandwich attacks and arbitrage patterns

## Metrics Collection

### Real-Time Metrics
The framework collects metrics during execution:
- Transactions per second (current and peak)
- Block production times
- Gas usage patterns
- Transaction confirmation latency
- Memory and CPU usage
- Network I/O statistics

### Prometheus Integration
Metrics are exported to Prometheus on port 9091:

```bash
# View metrics
curl http://localhost:9091/metrics
```

### Grafana Dashboards
Import the included dashboards for visualization:
- Load Test Overview
- Transaction Performance
- Network Conditions
- System Resources

## Network Simulation

### Condition Presets
- **Perfect**: No latency or packet loss
- **LAN**: 1ms latency
- **WiFi**: 5ms latency, 0.1% packet loss
- **Cable**: 15ms latency, 0.05% packet loss
- **4G**: 50ms latency, 1% packet loss
- **Congested**: 100ms latency, 5% packet loss

### Chaos Engineering
Test resilience with failure injection:
- Random network failures
- Cascading failures
- Network storms
- Bandwidth throttling

## Results and Reporting

### Output Files
Results are saved to the output directory:
- `results_<timestamp>.json`: Raw test data
- `metrics_<timestamp>.txt`: Performance metrics
- `report_<timestamp>.html`: Visual report

### HTML Report
The framework generates interactive HTML reports with:
- Performance charts
- Latency percentiles
- Success rates
- Breaking point analysis
- Comparison tables

### Success Criteria
Default thresholds for passing tests:
- Minimum 95% success rate
- P99 latency under 5 seconds
- Memory growth under 4GB
- Minimum 10 TPS sustained

## Advanced Usage

### Custom Transaction Generators

```elixir
defmodule MyCustomGenerator do
  alias ExWire.LoadTest.TransactionGenerator
  
  def generate_custom_workload(config) do
    TransactionGenerator.generate_simple_transfers(
      count: 100,
      accounts: config.test_accounts
    )
  end
end
```

### Custom Scenarios

```elixir
defmodule MyScenario do
  def run(config) do
    # Custom test logic
    transactions = generate_workload()
    process_transactions(transactions)
    collect_metrics()
  end
end
```

### Continuous Load Testing

```bash
# Run load tests in CI/CD pipeline
#!/bin/bash
mix load_test --scenario baseline --duration 60
if [ $? -ne 0 ]; then
  echo "Baseline test failed"
  exit 1
fi

mix load_test --scenario mainnet --duration 300
if [ $? -ne 0 ]; then
  echo "Mainnet simulation failed"
  exit 1
fi
```

## Troubleshooting

### Common Issues

**Out of Memory**
- Reduce `--accounts` parameter
- Decrease test duration
- Use smaller batch sizes

**Connection Refused**
- Ensure node is running
- Check RPC endpoint configuration
- Verify network settings

**Low TPS**
- Check system resources
- Verify network conditions
- Review transaction complexity

### Debug Mode

```bash
# Enable verbose logging
mix load_test --verbose

# Run single transaction type
iex -S mix
> TransactionGenerator.generate_simple_transfers(count: 1)
> Framework.run_baseline_test(%{target_tps: 1})
```

## Performance Tuning

### System Requirements
- **CPU**: 8+ cores recommended
- **RAM**: 16GB minimum, 32GB recommended
- **Network**: 100 Mbps+ bandwidth
- **Storage**: SSD with 50GB free space

### Optimization Tips
1. Run tests on dedicated hardware
2. Close unnecessary applications
3. Use local test network
4. Monitor system resources
5. Adjust batch sizes based on capacity

## Integration with Monitoring

### Prometheus Queries

```promql
# Average TPS over 5 minutes
rate(mana_load_test_transactions_confirmed[5m])

# P95 latency
histogram_quantile(0.95, rate(mana_load_test_transaction_latency_bucket[5m]))

# Memory growth rate
rate(mana_load_test_memory_usage[10m])
```

### Alert Rules

```yaml
groups:
  - name: load_test
    rules:
      - alert: LowTransactionRate
        expr: rate(mana_load_test_transactions_confirmed[5m]) < 10
        annotations:
          summary: "Transaction rate below threshold"
      
      - alert: HighLatency
        expr: histogram_quantile(0.99, rate(mana_load_test_transaction_latency_bucket[5m])) > 5000
        annotations:
          summary: "P99 latency exceeds 5 seconds"
```

## Contributing

To add new test scenarios or improve the framework:

1. Create scenario module in `apps/ex_wire/lib/ex_wire/load_test/scenarios/`
2. Add transaction patterns to `TransactionGenerator`
3. Update network conditions in `NetworkSimulator`
4. Add metrics to `MetricsCollector`
5. Update CLI task with new options
6. Document changes in this guide

## Support

For issues or questions:
- Check logs in `load_test_results/` directory
- Review system metrics during test execution
- Open issue on GitHub with test configuration and results