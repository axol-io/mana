# WebSocket API

## Overview

Mana-Ethereum provides real-time event subscriptions through WebSocket connections. The WebSocket API supports Ethereum standard subscriptions plus Mana-specific features for distributed operations and Layer 2 events.

## Connection

### Endpoint

```
ws://localhost:8546
wss://your-node.example.com:8546  # TLS
```

### Authentication

For authenticated endpoints:

```javascript
const ws = new WebSocket('wss://your-node.example.com:8546', {
  headers: {
    'Authorization': 'Bearer YOUR_JWT_TOKEN'
  }
});
```

## Standard Ethereum Subscriptions

### New Block Headers

Subscribe to new block headers:

```javascript
// Subscribe
{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "eth_subscribe",
  "params": ["newHeads"]
}

// Response
{
  "jsonrpc": "2.0",
  "id": 1,
  "result": "0x1234567890abcdef"
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "eth_subscription",
  "params": {
    "subscription": "0x1234567890abcdef",
    "result": {
      "number": "0x1234",
      "hash": "0xabcd...",
      "parentHash": "0xefgh...",
      "timestamp": "0x5f5e100"
    }
  }
}
```

### Pending Transactions

Subscribe to pending transactions:

```javascript
// Subscribe
{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "eth_subscribe",
  "params": ["newPendingTransactions"]
}

// Subscribe with full transaction objects
{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "eth_subscribe",
  "params": ["newPendingTransactions", true]
}
```

### Event Logs

Subscribe to contract event logs:

```javascript
// Basic log subscription
{
  "jsonrpc": "2.0",
  "id": 4,
  "method": "eth_subscribe",
  "params": [
    "logs",
    {
      "address": "0x742d35Cc6634C0532925a3b8D24D2c7FcDb80a2b",
      "topics": ["0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"]
    }
  ]
}

// Multi-address subscription
{
  "jsonrpc": "2.0",
  "id": 5,
  "method": "eth_subscribe",
  "params": [
    "logs",
    {
      "address": [
        "0x742d35Cc6634C0532925a3b8D24D2c7FcDb80a2b",
        "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
      ],
      "topics": [
        "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef",
        null,
        "0x000000000000000000000000742d35Cc6634C0532925a3b8D24D2c7FcDb80a2b"
      ]
    }
  ]
}
```

### Synchronization Status

Subscribe to sync progress updates:

```javascript
{
  "jsonrpc": "2.0",
  "id": 6,
  "method": "eth_subscribe",
  "params": ["syncing"]
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "eth_subscription",
  "params": {
    "subscription": "0x...",
    "result": {
      "startingBlock": "0x0",
      "currentBlock": "0x1234",
      "highestBlock": "0x5678",
      "knownStates": "0x9abc",
      "pulledStates": "0x1234"
    }
  }
}
```

## Mana-Specific Subscriptions

### Distributed Node Status

Monitor multi-datacenter node health:

```javascript
{
  "jsonrpc": "2.0",
  "id": 7,
  "method": "mana_subscribe",
  "params": ["nodeStatus"]
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "mana_subscription",
  "params": {
    "subscription": "0x...",
    "result": {
      "datacenter": "us-east-1",
      "status": "healthy",
      "consensus_role": "leader",
      "connected_datacenters": ["us-west-2", "eu-west-1"],
      "last_consensus_round": "2024-01-15T10:30:00Z"
    }
  }
}
```

### Layer 2 Events

Subscribe to Layer 2 batch processing:

```javascript
// Subscribe to all L2 events
{
  "jsonrpc": "2.0",
  "id": 8,
  "method": "mana_subscribe",
  "params": ["layer2Events"]
}

// Subscribe to specific L2 chain
{
  "jsonrpc": "2.0",
  "id": 9,
  "method": "mana_subscribe",
  "params": [
    "layer2Events",
    {
      "chainId": 10,  // Optimism
      "eventTypes": ["batchSubmitted", "stateRootUpdate", "withdrawal"]
    }
  ]
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "mana_subscription",
  "params": {
    "subscription": "0x...",
    "result": {
      "chainId": 10,
      "eventType": "batchSubmitted",
      "batchNumber": 12345,
      "transactionCount": 100,
      "stateRoot": "0xabcd...",
      "timestamp": "2024-01-15T10:30:00Z"
    }
  }
}
```

### Proof Verification Events

Monitor ZK proof verification:

```javascript
{
  "jsonrpc": "2.0",
  "id": 10,
  "method": "mana_subscribe",
  "params": [
    "proofVerification",
    {
      "proofTypes": ["plonk", "stark"],
      "includeMetrics": true
    }
  ]
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "mana_subscription",
  "params": {
    "subscription": "0x...",
    "result": {
      "proofType": "plonk",
      "status": "verified",
      "chainId": 324,
      "batchNumber": 67890,
      "verificationTime": 45.2,
      "timestamp": "2024-01-15T10:30:00Z"
    }
  }
}
```

### Verkle Tree Updates

Monitor Verkle tree state changes:

```javascript
{
  "jsonrpc": "2.0",
  "id": 11,
  "method": "mana_subscribe",
  "params": ["verkleUpdates"]
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "mana_subscription",
  "params": {
    "subscription": "0x...",
    "result": {
      "blockNumber": "0x1234",
      "verkleRoot": "0xdef...",
      "stateExpiry": {
        "expiredAccounts": 150,
        "reclaimedStorage": "0x12345"
      },
      "witnessSize": 200
    }
  }
}
```

### Consensus Events

Monitor distributed consensus rounds:

```javascript
{
  "jsonrpc": "2.0",
  "id": 12,
  "method": "mana_subscribe",
  "params": [
    "consensusEvents",
    {
      "includeVoting": true,
      "includeFailures": true
    }
  ]
}

// Notifications
{
  "jsonrpc": "2.0",
  "method": "mana_subscription",
  "params": {
    "subscription": "0x...",
    "result": {
      "eventType": "consensusRound",
      "roundNumber": 12345,
      "leader": "datacenter_a",
      "participants": ["datacenter_a", "datacenter_b", "datacenter_c"],
      "duration": 150.5,
      "status": "committed"
    }
  }
}
```

## Subscription Management

### Unsubscribe

```javascript
{
  "jsonrpc": "2.0",
  "id": 13,
  "method": "eth_unsubscribe",
  "params": ["0x1234567890abcdef"]
}
```

### List Active Subscriptions

```javascript
{
  "jsonrpc": "2.0",
  "id": 14,
  "method": "mana_listSubscriptions",
  "params": []
}

// Response
{
  "jsonrpc": "2.0",
  "id": 14,
  "result": [
    {
      "id": "0x1234567890abcdef",
      "type": "newHeads",
      "created": "2024-01-15T10:00:00Z"
    },
    {
      "id": "0xfedcba0987654321",
      "type": "layer2Events",
      "params": {"chainId": 10},
      "created": "2024-01-15T10:15:00Z"
    }
  ]
}
```

## Client Libraries

### JavaScript/TypeScript

```javascript
const WebSocket = require('ws');

class ManaWebSocketClient {
  constructor(url) {
    this.ws = new WebSocket(url);
    this.subscriptions = new Map();
    this.requestId = 1;
    
    this.ws.on('message', (data) => {
      const message = JSON.parse(data);
      if (message.method === 'eth_subscription') {
        this.handleNotification(message);
      }
    });
  }
  
  async subscribe(type, params = []) {
    const id = this.requestId++;
    const request = {
      jsonrpc: '2.0',
      id,
      method: 'eth_subscribe',
      params: [type, ...params]
    };
    
    this.ws.send(JSON.stringify(request));
    
    return new Promise((resolve) => {
      this.subscriptions.set(id, resolve);
    });
  }
  
  handleNotification(message) {
    // Handle subscription notifications
    const { subscription, result } = message.params;
    console.log(`Subscription ${subscription}:`, result);
  }
}

// Usage
const client = new ManaWebSocketClient('ws://localhost:8546');
const subId = await client.subscribe('newHeads');
```

### Python

```python
import asyncio
import json
import websockets

class ManaWebSocketClient:
    def __init__(self, url):
        self.url = url
        self.subscriptions = {}
        self.request_id = 1
    
    async def connect(self):
        self.ws = await websockets.connect(self.url)
        
    async def subscribe(self, subscription_type, params=None):
        if params is None:
            params = []
            
        request = {
            'jsonrpc': '2.0',
            'id': self.request_id,
            'method': 'eth_subscribe',
            'params': [subscription_type] + params
        }
        
        await self.ws.send(json.dumps(request))
        self.request_id += 1
        
        # Wait for subscription confirmation
        response = await self.ws.recv()
        return json.loads(response)['result']
    
    async def listen(self):
        async for message in self.ws:
            data = json.loads(message)
            if data.get('method') == 'eth_subscription':
                yield data['params']

# Usage
async def main():
    client = ManaWebSocketClient('ws://localhost:8546')
    await client.connect()
    
    sub_id = await client.subscribe('newHeads')
    print(f"Subscribed with ID: {sub_id}")
    
    async for notification in client.listen():
        print(f"New block: {notification['result']['number']}")

asyncio.run(main())
```

### Go

```go
package main

import (
    "context"
    "encoding/json"
    "log"
    
    "github.com/gorilla/websocket"
)

type ManaWebSocketClient struct {
    conn      *websocket.Conn
    requestID int
}

type SubscriptionNotification struct {
    Subscription string      `json:"subscription"`
    Result       interface{} `json:"result"`
}

func NewManaWebSocketClient(url string) (*ManaWebSocketClient, error) {
    conn, _, err := websocket.DefaultDialer.Dial(url, nil)
    if err != nil {
        return nil, err
    }
    
    return &ManaWebSocketClient{
        conn:      conn,
        requestID: 1,
    }, nil
}

func (c *ManaWebSocketClient) Subscribe(subType string, params ...interface{}) (string, error) {
    request := map[string]interface{}{
        "jsonrpc": "2.0",
        "id":      c.requestID,
        "method":  "eth_subscribe",
        "params":  append([]interface{}{subType}, params...),
    }
    
    if err := c.conn.WriteJSON(request); err != nil {
        return "", err
    }
    
    c.requestID++
    
    var response map[string]interface{}
    if err := c.conn.ReadJSON(&response); err != nil {
        return "", err
    }
    
    return response["result"].(string), nil
}

func (c *ManaWebSocketClient) Listen(ctx context.Context) (<-chan SubscriptionNotification, error) {
    notifications := make(chan SubscriptionNotification)
    
    go func() {
        defer close(notifications)
        
        for {
            select {
            case <-ctx.Done():
                return
            default:
                var message map[string]interface{}
                if err := c.conn.ReadJSON(&message); err != nil {
                    log.Printf("Read error: %v", err)
                    return
                }
                
                if message["method"] == "eth_subscription" {
                    params := message["params"].(map[string]interface{})
                    notification := SubscriptionNotification{
                        Subscription: params["subscription"].(string),
                        Result:       params["result"],
                    }
                    notifications <- notification
                }
            }
        }
    }()
    
    return notifications, nil
}
```

## Rate Limiting

WebSocket connections are subject to rate limiting:

- **Subscription Limit**: 100 active subscriptions per connection
- **Message Rate**: 1000 messages per minute
- **Connection Limit**: 10 concurrent connections per IP

Exceeded limits result in connection termination with close code 1008.

## Error Handling

### Connection Errors

```javascript
ws.on('error', (error) => {
  console.error('WebSocket error:', error);
});

ws.on('close', (code, reason) => {
  console.log(`Connection closed: ${code} - ${reason}`);
  
  // Reconnection logic
  setTimeout(() => {
    reconnect();
  }, 5000);
});
```

### Subscription Errors

```javascript
// Invalid subscription type
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32602,
    "message": "Invalid subscription type"
  }
}

// Rate limit exceeded
{
  "jsonrpc": "2.0",
  "id": 1,
  "error": {
    "code": -32000,
    "message": "Subscription limit exceeded"
  }
}
```

## Monitoring

### Connection Metrics

```bash
# Active WebSocket connections
curl http://localhost:9568/metrics | grep mana_websocket_connections_active

# Subscription metrics
curl http://localhost:9568/metrics | grep mana_websocket_subscriptions_total
```

### Health Check

```bash
# WebSocket health
curl http://localhost:8080/health/websocket

# Response:
{
  "status": "healthy",
  "active_connections": 45,
  "total_subscriptions": 234,
  "message_rate": 1250.5
}
```

## Next Steps

- [JSON-RPC API](json-rpc.md) - HTTP API reference
- [Quick Start](../getting-started/quick-start.md) - Getting started guide
- [Load Testing](../testing/load-testing.md) - WebSocket load testing