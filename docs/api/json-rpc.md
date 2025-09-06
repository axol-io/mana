# Mana Ethereum JSON-RPC API Documentation

## Overview

The Mana Ethereum client provides a complete JSON-RPC API compatible with the Ethereum specification. This document outlines all available methods, their parameters, and expected responses.

## Base URL

```
HTTP: http://localhost:8545
WebSocket: ws://localhost:8546
```

## Authentication

By default, the API is open. For production deployments, use JWT authentication:

```bash
curl -X POST http://localhost:8545 \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer YOUR_JWT_TOKEN" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Rate Limiting

- Default: 1000 requests per minute per IP
- Batch requests: Maximum 100 operations per batch
- WebSocket connections: Maximum 100 concurrent connections

## Standard Ethereum Methods

### eth_blockNumber

Returns the current block number.

**Parameters:** None

**Returns:** `QUANTITY` - Integer of the current block number

**Example:**
```json
// Request
{
  "jsonrpc": "2.0",
  "method": "eth_blockNumber",
  "params": [],
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x5bad55"
}
```

### eth_getBalance

Returns the balance of an account at a given block.

**Parameters:**
1. `DATA`, 20 bytes - Address to check balance
2. `QUANTITY|TAG` - Block number or "latest", "earliest", "pending"

**Returns:** `QUANTITY` - Balance in wei

**Example:**
```json
// Request
{
  "jsonrpc": "2.0",
  "method": "eth_getBalance",
  "params": [
    "0x407d73d8a49eeb85d32cf465507dd71d507100c1",
    "latest"
  ],
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x0234c8a3397aab58"
}
```

### eth_getTransactionByHash

Returns transaction information by hash.

**Parameters:**
1. `DATA`, 32 bytes - Transaction hash

**Returns:** Transaction object or null

**Example:**
```json
// Request
{
  "jsonrpc": "2.0",
  "method": "eth_getTransactionByHash",
  "params": [
    "0x88df016429689c079f3b2f6ad39fa052532c56795b733da78a91ebe6a713944b"
  ],
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": {
    "blockHash": "0x1d59ff54b1eb26b013ce3cb5fc9dab3705b415a67127a003c3e61eb445bb8df2",
    "blockNumber": "0x5daf3b",
    "from": "0xa7d9ddbe1f17865597fbd27ec712455208b6b76d",
    "gas": "0xc350",
    "gasPrice": "0x4a817c800",
    "hash": "0x88df016429689c079f3b2f6ad39fa052532c56795b733da78a91ebe6a713944b",
    "input": "0x68656c6c6f21",
    "nonce": "0x15",
    "to": "0xf02c1c8e6114b1dbe8937a39260b5b0a374432bb",
    "transactionIndex": "0x41",
    "value": "0xf3dbb76162000",
    "type": "0x0",
    "v": "0x25",
    "r": "0x1b5e176d927f8e9ab405058b2d2457392da3e20f328b16ddabcebc33eaac5fea",
    "s": "0x4ba69724e8f69de52f0125ad8b3c5c2cef33019bac3249e2c0a2192766d1721c"
  }
}
```

### eth_sendRawTransaction

Submits a signed transaction to the network.

**Parameters:**
1. `DATA` - Signed transaction data

**Returns:** `DATA`, 32 bytes - Transaction hash

**Example:**
```json
// Request
{
  "jsonrpc": "2.0",
  "method": "eth_sendRawTransaction",
  "params": [
    "0xf86c808504a817c80082520894..."
  ],
  "id": 1
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0xe670ec64341771606e55d6b4ca35a1a6b75ee3d5145a99d05921026d1527331"
}
```

### eth_call

Executes a call without creating a transaction.

**Parameters:**
1. `Object` - Transaction call object
   - `from`: `DATA`, 20 bytes (optional)
   - `to`: `DATA`, 20 bytes
   - `gas`: `QUANTITY` (optional)
   - `gasPrice`: `QUANTITY` (optional)
   - `value`: `QUANTITY` (optional)
   - `data`: `DATA` (optional)
2. `QUANTITY|TAG` - Block number or "latest", "earliest", "pending"

**Returns:** `DATA` - Return value of executed contract

### eth_estimateGas

Estimates gas needed for a transaction.

**Parameters:**
1. `Object` - Transaction object (same as eth_call)

**Returns:** `QUANTITY` - Gas amount

### eth_getBlockByNumber

Returns block information by number.

**Parameters:**
1. `QUANTITY|TAG` - Block number or "latest", "earliest", "pending"
2. `Boolean` - If true, returns full transaction objects

**Returns:** Block object or null

### eth_getBlockByHash

Returns block information by hash.

**Parameters:**
1. `DATA`, 32 bytes - Block hash
2. `Boolean` - If true, returns full transaction objects

**Returns:** Block object or null

### eth_getTransactionReceipt

Returns receipt of a transaction.

**Parameters:**
1. `DATA`, 32 bytes - Transaction hash

**Returns:** Receipt object or null

### eth_getLogs

Returns logs matching filter criteria.

**Parameters:**
1. `Object` - Filter object
   - `fromBlock`: `QUANTITY|TAG` (optional)
   - `toBlock`: `QUANTITY|TAG` (optional)
   - `address`: `DATA|Array` (optional)
   - `topics`: `Array of DATA` (optional)
   - `blockhash`: `DATA`, 32 bytes (optional)

**Returns:** Array of log objects

## Layer 2 Specific Methods

### mana_getOptimismBatchStatus

Returns the status of an Optimism batch.

**Parameters:**
1. `QUANTITY` - Batch number

**Returns:** Batch status object

### mana_getArbitrumSequencerInfo

Returns current Arbitrum sequencer information.

**Parameters:** None

**Returns:** Sequencer info object

### mana_getZkSyncProofStatus

Returns zkSync proof verification status.

**Parameters:**
1. `DATA`, 32 bytes - Proof hash

**Returns:** Proof status object

## Consensus Methods

### eth_getWork

Returns current block mining work.

**Parameters:** None

**Returns:** Array with current block header pow-hash, seed hash, boundary condition

### eth_submitWork

Submits a proof-of-work solution.

**Parameters:**
1. `DATA`, 8 bytes - Nonce
2. `DATA`, 32 bytes - Header's pow-hash
3. `DATA`, 32 bytes - Mix digest

**Returns:** `Boolean` - True if solution was accepted

## Network Methods

### net_version

Returns the network ID.

**Parameters:** None

**Returns:** `String` - Network ID

### net_peerCount

Returns number of connected peers.

**Parameters:** None

**Returns:** `QUANTITY` - Number of connected peers

### net_listening

Returns true if client is listening for connections.

**Parameters:** None

**Returns:** `Boolean` - True when listening

## Web3 Methods

### web3_clientVersion

Returns the client version.

**Parameters:** None

**Returns:** `String` - Client version

### web3_sha3

Returns Keccak-256 hash of data.

**Parameters:**
1. `DATA` - Data to hash

**Returns:** `DATA`, 32 bytes - Keccak-256 hash

## Debug Methods (Development Only)

### debug_traceTransaction

Returns execution trace of a transaction.

**Parameters:**
1. `DATA`, 32 bytes - Transaction hash
2. `Object` - Tracer options (optional)

**Returns:** Trace object

### debug_traceBlockByNumber

Returns execution traces for all transactions in a block.

**Parameters:**
1. `QUANTITY|TAG` - Block number
2. `Object` - Tracer options (optional)

**Returns:** Array of trace objects

## Error Codes

| Code | Message | Description |
|------|---------|-------------|
| -32700 | Parse error | Invalid JSON |
| -32600 | Invalid Request | JSON is not a valid request |
| -32601 | Method not found | Method does not exist |
| -32602 | Invalid params | Invalid method parameters |
| -32603 | Internal error | Internal JSON-RPC error |
| -32000 | Server error | Generic server error |
| -32001 | Resource not found | Requested resource not found |
| -32002 | Resource unavailable | Requested resource not available |
| -32003 | Transaction rejected | Transaction creation failed |
| -32004 | Method not supported | Method is not implemented |
| -32005 | Limit exceeded | Request exceeds defined limit |

## Batch Requests

Send multiple requests in a single call:

```json
// Request
[
  {"jsonrpc": "2.0", "method": "eth_blockNumber", "params": [], "id": 1},
  {"jsonrpc": "2.0", "method": "net_peerCount", "params": [], "id": 2}
]

// Response
[
  {"jsonrpc": "2.0", "id": 1, "result": "0x5bad55"},
  {"jsonrpc": "2.0", "id": 2, "result": "0x19"}
]
```

## WebSocket Subscriptions

### eth_subscribe

Creates a subscription for specific events.

**Parameters:**
1. `String` - Subscription type ("newHeads", "logs", "newPendingTransactions", "syncing")
2. `Object` - Options (optional)

**Returns:** `SUBSCRIPTION ID` - Subscription identifier

**Example:**
```json
// Subscribe to new blocks
{
  "jsonrpc": "2.0",
  "method": "eth_subscribe",
  "params": ["newHeads"],
  "id": 1
}

// Notification
{
  "jsonrpc": "2.0",
  "method": "eth_subscription",
  "params": {
    "subscription": "0x9ce59a13059e417087c02d3236a0b1cc",
    "result": {
      "number": "0x5bad55",
      "hash": "0xd4e56740f876aef8c010b86a40d5f56745a118d0906a34e69aec8c0db1cb8fa3",
      ...
    }
  }
}
```

### eth_unsubscribe

Cancels a subscription.

**Parameters:**
1. `SUBSCRIPTION ID` - Subscription to cancel

**Returns:** `Boolean` - True if cancelled successfully

## Rate Limiting Response

When rate limited, the API returns:

```json
{
  "jsonrpc": "2.0",
  "id": null,
  "error": {
    "code": -32005,
    "message": "Limit exceeded",
    "data": {
      "rate": 1000,
      "period": "1m",
      "retry_after": 45
    }
  }
}
```

## Health Check Endpoints

### GET /health

Returns node health status.

**Response:**
```json
{
  "status": "healthy",
  "version": "1.0.0",
  "uptime": 3600,
  "peers": 25,
  "syncing": false,
  "current_block": 6000000
}
```

### GET /ready

Returns readiness status for load balancer.

**Response:**
- `200 OK` - Node is ready
- `503 Service Unavailable` - Node is not ready

## Metrics Endpoint

### GET /metrics

Returns Prometheus-formatted metrics.

```
# HELP mana_sync_current_block Current synchronized block number
# TYPE mana_sync_current_block gauge
mana_sync_current_block{node_id="mana-1"} 6000000

# HELP mana_p2p_peers_connected Number of connected peers
# TYPE mana_p2p_peers_connected gauge
mana_p2p_peers_connected{node_id="mana-1"} 25
```

## SDK Examples

### JavaScript (ethers.js)

```javascript
const { ethers } = require('ethers');

const provider = new ethers.JsonRpcProvider('http://localhost:8545');

// Get block number
const blockNumber = await provider.getBlockNumber();

// Get balance
const balance = await provider.getBalance('0x...');

// Send transaction
const tx = await wallet.sendTransaction({
  to: '0x...',
  value: ethers.parseEther('1.0')
});
```

### Python (web3.py)

```python
from web3 import Web3

w3 = Web3(Web3.HTTPProvider('http://localhost:8545'))

# Get block number
block_number = w3.eth.block_number

# Get balance
balance = w3.eth.get_balance('0x...')

# Send transaction
tx_hash = w3.eth.send_transaction({
  'from': '0x...',
  'to': '0x...',
  'value': w3.toWei(1, 'ether')
})
```

### Go (go-ethereum)

```go
client, err := ethclient.Dial("http://localhost:8545")

// Get block number
blockNumber, err := client.BlockNumber(context.Background())

// Get balance
balance, err := client.BalanceAt(context.Background(), address, nil)

// Send transaction
tx := types.NewTransaction(nonce, toAddress, value, gasLimit, gasPrice, data)
signedTx, err := types.SignTx(tx, types.NewEIP155Signer(chainID), privateKey)
err = client.SendTransaction(context.Background(), signedTx)
```

## Support

For API issues or questions:
- GitHub Issues: https://github.com/mana-ethereum/mana/issues
- Documentation: https://docs.mana-ethereum.io
- Discord: https://discord.gg/mana-ethereum