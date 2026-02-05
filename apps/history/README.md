# History - Stateless Ethereum History Node

A lightweight alternative to running a full Ethereum archive node, optimized for historical event log queries. Inspired by [SHiNode](https://github.com/vicnaum/shinode) but implemented in Elixir for integration with the Mana stack.

## Features

- **Efficient Storage**: ~250GB for Ethereum mainnet event data (vs 2TB+ archive)
- **Fast Sync**: 1000+ blocks/sec from P2P network
- **No RPC Dependency**: Syncs directly via devp2p, no external RPC needed
- **Sharded Storage**: 16 CubDB shards for parallel queries
- **Bloom Indexing**: Skip 90%+ of blocks via bloom pre-filtering
- **WebSocket Support**: Real-time log subscriptions via `eth_subscribe`
- **Distributed Ready**: Integrates with Mana's AntidoteDB for multi-node

## Architecture

```
P2P Network (devp2p)
        |
        v
+-------------------+
| History.Sync      |  <- Stateless sync (headers, txs, receipts)
| Pipeline          |     No EVM execution
+-------------------+
        |
        v
+-------------------+
| History.Storage   |  <- Sharded CubDB storage
| (16 shards)       |     Parallel writes/reads
+-------------------+
        |
        v
+-------------------+
| History.Index     |  <- Bloom filter index
| BloomIndex        |     Fast pre-filtering
+-------------------+
        |
        v
+-------------------+
| History.RPC       |  <- HTTP + WebSocket
| Endpoint          |     JSON-RPC 2.0
+-------------------+
```

## Supported RPC Methods

### HTTP (POST /)

| Method | Description |
|--------|-------------|
| `eth_getLogs` | Query historical event logs with filters |
| `eth_blockNumber` | Get current synced block number |
| `eth_getBlockByNumber` | Get block header by number |
| `eth_chainId` | Get chain identifier |
| `net_version` | Get network version |
| `web3_clientVersion` | Get client version |

### WebSocket (GET /ws)

| Method | Description |
|--------|-------------|
| `eth_subscribe("logs", {...})` | Subscribe to new logs matching filter |
| `eth_subscribe("newHeads")` | Subscribe to new block headers |
| `eth_subscribe("syncing")` | Subscribe to sync status updates |
| `eth_unsubscribe` | Unsubscribe from a subscription |

All HTTP methods are also available over WebSocket.

## Usage

### Configuration

```elixir
# config/config.exs
config :history,
  chain: :mainnet,
  data_dir: "/data/history",
  storage: [shards: 16],
  sync: [batch_size: 100, max_peers: 50],
  rpc: [enabled: true, port: 8545, host: "0.0.0.0"]
```

### Query Logs (HTTP)

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "eth_getLogs",
    "params": [{
      "address": "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
      "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"],
      "fromBlock": "0x112A880",
      "toBlock": "0x112A8E4"
    }]
  }'
```

### Subscribe to Logs (WebSocket)

```javascript
const ws = new WebSocket('ws://localhost:8545/ws');

ws.onopen = () => {
  ws.send(JSON.stringify({
    jsonrpc: '2.0',
    id: 1,
    method: 'eth_subscribe',
    params: ['logs', {
      address: '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2',
      topics: ['0xddf252ad...']
    }]
  }));
};

ws.onmessage = (event) => {
  const msg = JSON.parse(event.data);
  if (msg.method === 'eth_subscription') {
    console.log('New log:', msg.params.result);
  }
};
```

### Elixir API

```elixir
# Query logs directly
{:ok, logs} = History.get_logs(%{
  address: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2",
  topics: ["0xddf252ad..."],
  from_block: 18_000_000,
  to_block: 18_100_000
})

# Get sync status
status = History.sync_status()
# %{synced_block: 18_500_000, highest_block: 18_500_100, peers: 25, syncing: true}

# Get storage stats
stats = History.storage_stats()
# %{total_blocks: 18_500_000, total_logs: 5_000_000_000, disk_usage_bytes: 250_000_000_000, shards: 16}
```

## Storage Layout

Data is sharded by block number across 16 CubDB instances:

```
data/history/
├── history_shard_0/
├── history_shard_1/
...
├── history_shard_15/
└── index/
    └── bloom_index.bin
```

Each shard stores:
- `{:header, block_number}` -> Block header
- `{:transactions, block_number}` -> List of transactions
- `{:logs, block_number}` -> List of logs

## Bloom Filter Indexing

Each block's logs are indexed via a 2048-bit bloom filter (Ethereum standard).
When querying logs:

1. Build query bloom from filter criteria (address, topics)
2. Check each block's bloom - skip if no match possible (~90% of blocks)
3. Load and filter actual logs only for matching blocks

## Integration Points

### Axol API

History can serve as the backend for Axol API's historical log queries:

```python
# In Axol API
if to_block < current_block - 1000:
    return await history_client.get_logs(...)  # Historical
else:
    return await erpc_client.get_logs(...)     # Recent
```

### Sphinx MEV Engine

History enables MEV strategy backtesting:

- Historical DEX swap events for arbitrage backtesting
- Gas price patterns for optimization
- Protocol event analytics for strategy development

## Development

```bash
# Run tests
cd apps/history && mix test

# Start standalone
cd apps/history && mix run --no-halt

# IEx session
cd apps/history && iex -S mix
```

## Dependencies

- `cubdb` - Embedded key-value storage
- `cowboy` - HTTP/WebSocket server
- `phoenix_pubsub` - Internal event broadcasting
- `jason` - JSON encoding/decoding
- `telemetry` - Metrics and instrumentation

## License

Apache 2.0 / MIT (same as Mana)
