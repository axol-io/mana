# Quick Start

Get your Mana-Ethereum node running in minutes.

## 1. Install and Configure

Follow the [installation guide](installation.md) to set up Mana-Ethereum, then create a basic configuration:

```bash
# Create basic config
cat > config/local.exs << 'EOF'
import Config

config :blockchain,
  chain: :mainnet,
  sync_mode: :fast

config :ex_wire,
  network: [
    interface: {127, 0, 0, 1},
    port: 30303,
    discovery: false
  ]

config :jsonrpc2,
  http: [port: 8545],
  ws: [port: 8546]
EOF
```

## 2. Start the Node

### Development Mode

```bash
# Start interactive node
iex -S mix

# In the console
iex> Blockchain.start_sync()
```

### Production Mode

```bash
# Build and start release
mix release
_build/prod/rel/mana/bin/mana start
```

### Docker

```bash
# Quick start with Docker
docker run -d \
  --name mana-node \
  -p 8545:8545 \
  -p 8546:8546 \
  mana-ethereum:latest
```

## 3. Verify Operation

### Check Node Status

```bash
# HTTP RPC
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
  http://localhost:8545

# WebSocket (using websocat)
echo '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | \
  websocat ws://localhost:8546
```

### Monitor Sync Progress

```bash
# Check sync status
curl -s -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' \
  http://localhost:8545 | jq

# Expected response during sync:
# {
#   "jsonrpc": "2.0",
#   "id": 1,
#   "result": {
#     "startingBlock": "0x0",
#     "currentBlock": "0x1234",
#     "highestBlock": "0x5678"
#   }
# }
```

## 4. Basic Operations

### Account Management

```bash
# Create new account
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"personal_newAccount","params":["password"],"id":1}' \
  http://localhost:8545

# List accounts
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_accounts","params":[],"id":1}' \
  http://localhost:8545
```

### Transaction Handling

```bash
# Get transaction count
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getTransactionCount","params":["0xYOUR_ADDRESS","latest"],"id":1}' \
  http://localhost:8545

# Send transaction
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{
    "jsonrpc":"2.0",
    "method":"eth_sendTransaction",
    "params":[{
      "from":"0xFROM_ADDRESS",
      "to":"0xTO_ADDRESS",
      "value":"0x1000000000000000000",
      "gas":"0x5208",
      "gasPrice":"0x4a817c800"
    }],
    "id":1
  }' \
  http://localhost:8545
```

### Query Blockchain Data

```bash
# Get latest block
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["latest",false],"id":1}' \
  http://localhost:8545

# Get balance
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"eth_getBalance","params":["0xYOUR_ADDRESS","latest"],"id":1}' \
  http://localhost:8545
```

## 5. Enable Advanced Features

### Layer 2 Support

Update your configuration to enable Layer 2:

```elixir
# config/local.exs
config :ex_wire, :layer2,
  enabled: true,
  optimism: [
    enabled: true,
    l1_rpc_url: "http://localhost:8545"
  ]
```

### Monitoring

Enable Prometheus metrics:

```elixir
config :ex_wire, :monitoring,
  enabled: true,
  prometheus: [enabled: true, port: 9568]
```

Access metrics:
```bash
curl http://localhost:9568/metrics
```

### Load Testing

Run load tests to verify performance:

```bash
# Basic load test
mix load_test --scenario baseline --duration 60

# Mainnet simulation
mix load_test --scenario mainnet --duration 300
```

## 6. Connect External Tools

### MetaMask Configuration

Add custom network in MetaMask:
- Network Name: Mana Local
- RPC URL: http://localhost:8545
- Chain ID: 1337
- Currency Symbol: ETH

### Web3 Libraries

#### JavaScript
```javascript
const Web3 = require('web3');
const web3 = new Web3('http://localhost:8545');

// Get latest block
web3.eth.getBlockNumber().then(console.log);
```

#### Python
```python
from web3 import Web3

w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))
print(f"Latest block: {w3.eth.block_number}")
```

## 7. Troubleshooting

### Node Won't Start

```bash
# Check logs
tail -f _build/prod/rel/mana/log/mana.log

# Debug mode
MANA_LOG_LEVEL=debug _build/prod/rel/mana/bin/mana start
```

### Sync Issues

```bash
# Reset blockchain data
rm -rf _build/prod/rel/mana/data/blockchain

# Force resync
curl -X POST \
  -H "Content-Type: application/json" \
  --data '{"jsonrpc":"2.0","method":"debug_resync","params":[],"id":1}' \
  http://localhost:8545
```

### Performance Issues

```bash
# Check system resources
top -p $(pgrep -f mana)

# Monitor memory usage
curl -s http://localhost:9568/metrics | grep memory
```

## Next Steps

### Production Deployment
- [Production Guide](../deployment/production.md) - Deploy to production
- [Kubernetes](../deployment/kubernetes.md) - Deploy with K8s
- [Monitoring](../deployment/monitoring.md) - Set up observability

### Advanced Features
- [Architecture](../architecture/overview.md) - Understand the architecture
- [Layer 2](../architecture/layer2-integration.md) - Layer 2 integration
- [Enterprise](../enterprise/compliance.md) - Enterprise features

### API Reference
- [JSON-RPC API](../api/json-rpc.md) - Complete API reference
- [WebSocket API](../api/websocket.md) - Real-time subscriptions