# Mana Ethereum Client - Operational Runbooks

## Table of Contents

1. [Emergency Response](#emergency-response)
2. [Performance Issues](#performance-issues)
3. [Node Management](#node-management)
4. [Database Operations](#database-operations)
5. [Network Issues](#network-issues)
6. [Monitoring & Alerting](#monitoring--alerting)
7. [Security Incidents](#security-incidents)
8. [Capacity Planning](#capacity-planning)
9. [Disaster Recovery](#disaster-recovery)
10. [Routine Maintenance](#routine-maintenance)

---

## Emergency Response

### Critical Node Failure

**Symptoms:**
- Node health check failures
- Zero JSON-RPC responses
- Missing from peer discovery
- Prometheus metrics unavailable

**Immediate Actions:**
1. Check node status: `kubectl get pods -n mana-system -l app=mana-node`
2. Review recent logs: `kubectl logs -n mana-system mana-node-0 --tail=100`
3. Check resource usage: `kubectl top pods -n mana-system`

**Resolution Steps:**
```bash
# 1. Restart failed pod
kubectl delete pod -n mana-system mana-node-0

# 2. If persistent, check underlying node
kubectl describe node <node-name>

# 3. Scale up temporarily
kubectl scale statefulset mana-node -n mana-system --replicas=4

# 4. Monitor recovery
watch kubectl get pods -n mana-system -l app=mana-node
```

**Escalation:** If resolution time > 15 minutes, escalate to Senior SRE.

### Multi-Datacenter Outage

**Symptoms:**
- Traffic routing failures
- Cross-datacenter replication stopped
- Global DNS health checks failing

**Immediate Actions:**
1. Check global DNS routing: `dig +short api.mana.ethereum.local`
2. Verify datacenter health checks in Route53/Traffic Manager
3. Review cross-datacenter VPN connectivity

**Resolution Steps:**
```bash
# 1. Check datacenter status
aws route53 get-health-check --health-check-id <health-check-id>

# 2. Manually route traffic to healthy datacenter
aws route53 change-resource-record-sets --hosted-zone-id <zone-id> \
  --change-batch file://emergency-routing.json

# 3. Notify operations channel
curl -X POST https://hooks.slack.com/... \
  -d '{"text":"Multi-datacenter outage detected. Manual routing initiated."}'
```

---

## Performance Issues

### Verkle Tree Performance Degradation

**Symptoms:**
- Alert: `VerklePerformanceDegradation`
- Operations/sec below 20,000
- Increased latency in witness generation

**Diagnosis:**
```bash
# Check current performance metrics
curl -s http://mana-metrics.mana-system.svc.cluster.local:9090/metrics | grep verkle

# Review recent performance trends
kubectl port-forward -n mana-system svc/grafana 3000:3000
# Navigate to Verkle Performance Dashboard
```

**Resolution Steps:**
1. **Check SIMD optimization status:**
   ```bash
   kubectl exec -n mana-system mana-node-0 -- \
     grep -i simd /proc/cpuinfo
   ```

2. **Verify ultra-performance mode:**
   ```bash
   kubectl exec -n mana-system mana-node-0 -- \
     env | grep ULTRA_PERFORMANCE
   ```

3. **Check memory pressure:**
   ```bash
   kubectl exec -n mana-system mana-node-0 -- \
     free -h
   ```

4. **Restart with performance profiling:**
   ```bash
   kubectl patch statefulset mana-node -n mana-system -p \
     '{"spec":{"template":{"spec":{"containers":[{"name":"mana","env":[{"name":"ENABLE_PROFILING","value":"true"}]}]}}}}'
   ```

### EVM Execution Slowdown

**Symptoms:**
- Alert: `EVMExecutionSlowdown`
- Opcode execution below 1M ops/sec
- Transaction processing delays

**Resolution Steps:**
1. **Check EVM SIMD status:**
   ```bash
   kubectl logs -n mana-system mana-node-0 | grep "EVM.*SIMD"
   ```

2. **Review execution metrics:**
   ```bash
   curl -s http://mana-metrics:9090/metrics | grep evm_opcodes
   ```

3. **Analyze gas usage patterns:**
   ```bash
   kubectl exec -n mana-system mana-node-0 -- \
     /opt/mana/bin/mana eval 'EVM.ExecutionAnalyzer.recent_patterns()'
   ```

4. **Enable advanced optimization:**
   ```bash
   kubectl set env statefulset/mana-node -n mana-system \
     EVM_ADVANCED_OPTIMIZATION=true
   ```

### Network Latency Issues

**Symptoms:**
- Alert: `NetworkLatencyHigh`
- Message propagation > 25ms
- Peer connection instability

**Resolution Steps:**
1. **Check peer connections:**
   ```bash
   curl -s http://mana-node-0:9090/metrics | grep libp2p_peers
   ```

2. **Review mesh optimization:**
   ```bash
   kubectl logs -n mana-system mana-node-0 | grep "mesh.*optimization"
   ```

3. **Analyze geographic distribution:**
   ```bash
   kubectl exec -n mana-system mana-node-0 -- \
     /opt/mana/bin/mana eval 'ExWire.LibP2P.PeerAnalyzer.geographic_stats()'
   ```

---

## Node Management

### Adding New Nodes

**Prerequisites:**
- Kubernetes cluster with ultra-performance node pool
- Sufficient storage and network capacity
- Updated container images

**Procedure:**
```bash
# 1. Scale up StatefulSet
kubectl scale statefulset mana-node -n mana-system --replicas=<new-count>

# 2. Verify new pod creation
kubectl get pods -n mana-system -l app=mana-node -w

# 3. Check new node health
kubectl exec -n mana-system mana-node-<N> -- /opt/mana/healthcheck.sh

# 4. Verify peer discovery
kubectl logs -n mana-system mana-node-<N> | grep "peer.*connected"

# 5. Update monitoring
# Add new node to Prometheus targets
kubectl patch configmap prometheus-config -n monitoring-system --patch-file node-patch.yaml
```

### Rolling Updates

**Zero-downtime update procedure:**
```bash
# 1. Update container image
kubectl patch statefulset mana-node -n mana-system -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"mana","image":"mana:new-version"}]}}}}'

# 2. Monitor rolling update
kubectl rollout status statefulset/mana-node -n mana-system

# 3. Verify each pod after update
for i in {0..2}; do
  kubectl exec -n mana-system mana-node-$i -- /opt/mana/healthcheck.sh
done

# 4. Run post-deployment tests
./scripts/post-deployment-tests.sh
```

### Node Retirement

**Safe node removal:**
```bash
# 1. Drain connections gracefully
kubectl exec -n mana-system mana-node-<N> -- \
  /opt/mana/bin/mana eval 'ExWire.P2P.graceful_shutdown()'

# 2. Wait for data sync completion
kubectl exec -n mana-system mana-node-<N> -- \
  /opt/mana/bin/mana eval 'AntidoteDB.sync_status()'

# 3. Remove from StatefulSet
kubectl scale statefulset mana-node -n mana-system --replicas=<reduced-count>

# 4. Clean up persistent volumes
kubectl delete pvc data-mana-node-<N> -n mana-system
```

---

## Database Operations

### AntidoteDB Cluster Management

**Health Check:**
```bash
# Check all AntidoteDB nodes
kubectl exec -n mana-system antidote-0 -- \
  curl -f http://localhost:8087/metrics

# Verify cluster connectivity
for i in {0..2}; do
  kubectl exec -n mana-system antidote-$i -- \
    /opt/antidote/bin/antidote eval 'net_adm:ping_list(nodes()).'
done
```

**Adding Database Node:**
```bash
# 1. Scale AntidoteDB StatefulSet
kubectl scale statefulset antidote -n mana-system --replicas=4

# 2. Wait for pod ready
kubectl wait --for=condition=Ready pod/antidote-3 -n mana-system --timeout=300s

# 3. Join cluster
kubectl exec -n mana-system antidote-3 -- \
  /opt/antidote/bin/antidote eval 'rpc:call(antidote@antidote-0, antidote_dc_manager, join_cluster, [antidote@antidote-3]).'

# 4. Verify cluster membership
kubectl exec -n mana-system antidote-0 -- \
  /opt/antidote/bin/antidote eval 'nodes().'
```

### Backup and Restore

**Automated Backup:**
```bash
#!/bin/bash
# backup-antidote.sh

BACKUP_DIR="/opt/backups/$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BACKUP_DIR"

# Backup each AntidoteDB node
for i in {0..2}; do
  kubectl exec -n mana-system antidote-$i -- \
    tar -czf /tmp/antidote-backup-$i.tar.gz /opt/antidote/data
  
  kubectl cp mana-system/antidote-$i:/tmp/antidote-backup-$i.tar.gz \
    "$BACKUP_DIR/antidote-backup-$i.tar.gz"
done

# Upload to cloud storage
aws s3 cp "$BACKUP_DIR" s3://mana-backups/antidote/ --recursive
```

**Restore Procedure:**
```bash
# 1. Scale down applications
kubectl scale statefulset mana-node -n mana-system --replicas=0

# 2. Stop AntidoteDB
kubectl scale statefulset antidote -n mana-system --replicas=0

# 3. Restore data from backup
for i in {0..2}; do
  kubectl cp backup/antidote-backup-$i.tar.gz mana-system/antidote-$i:/tmp/
  kubectl exec -n mana-system antidote-$i -- \
    tar -xzf /tmp/antidote-backup-$i.tar.gz -C /
done

# 4. Restart services
kubectl scale statefulset antidote -n mana-system --replicas=3
kubectl scale statefulset mana-node -n mana-system --replicas=3
```

---

## Network Issues

### Peer Discovery Problems

**Symptoms:**
- Low peer count
- Network partition warnings
- Sync delays

**Diagnosis:**
```bash
# Check current peer count
kubectl exec -n mana-system mana-node-0 -- \
  curl -s http://localhost:9090/metrics | grep libp2p_peers_connected

# Review discovery logs
kubectl logs -n mana-system mana-node-0 | grep -i discovery

# Check network connectivity
kubectl exec -n mana-system mana-node-0 -- \
  netstat -tuln | grep -E ':(30303|8545|8546)'
```

**Resolution:**
```bash
# 1. Restart peer discovery
kubectl exec -n mana-system mana-node-0 -- \
  /opt/mana/bin/mana eval 'ExWire.P2P.restart_discovery()'

# 2. Check firewall rules
kubectl exec -n mana-system mana-node-0 -- \
  iptables -L | grep -E '(30303|8545|8546)'

# 3. Force bootstrap from known peers
kubectl exec -n mana-system mana-node-0 -- \
  /opt/mana/bin/mana eval 'ExWire.P2P.force_bootstrap()'
```

### Cross-Datacenter Replication Issues

**Diagnosis:**
```bash
# Check VPN connectivity
aws ec2 describe-vpc-peering-connections --filters "Name=status-code,Values=active"

# Test cross-datacenter latency
kubectl exec -n mana-system mana-node-0 -- \
  ping -c 10 <remote-datacenter-endpoint>

# Check CRDT replication status
kubectl exec -n mana-system antidote-0 -- \
  curl -s http://localhost:8087/stats | grep replication
```

---

## Monitoring & Alerting

### Prometheus Issues

**Common Problems:**
- High cardinality metrics
- Storage space exhaustion
- Scrape failures

**Resolution:**
```bash
# Check Prometheus health
kubectl exec -n monitoring-system prometheus-0 -- \
  curl -s http://localhost:9090/-/healthy

# Review storage usage
kubectl exec -n monitoring-system prometheus-0 -- \
  du -sh /prometheus

# Restart Prometheus
kubectl delete pod -n monitoring-system prometheus-0
```

### Grafana Dashboard Issues

**Dashboard Not Loading:**
```bash
# Check Grafana status
kubectl get pods -n monitoring-system -l app=grafana

# Review datasource connectivity
kubectl exec -n monitoring-system grafana-xxx -- \
  curl -s http://prometheus:9090/api/v1/label/__name__/values

# Restart Grafana
kubectl delete pod -n monitoring-system -l app=grafana
```

---

## Security Incidents

### Unauthorized Access Detection

**Immediate Actions:**
1. Review access logs:
   ```bash
   kubectl logs -n mana-system mana-node-0 | grep -i "unauthorized\|forbidden\|attack"
   ```

2. Check network policies:
   ```bash
   kubectl get networkpolicy -n mana-system
   ```

3. Verify HSM security:
   ```bash
   kubectl exec -n mana-system mana-node-0 -- \
     /opt/mana/bin/mana eval 'ExWire.Enterprise.HSMSecurity.audit_recent_access()'
   ```

### DDoS Attack Response

**Mitigation Steps:**
```bash
# 1. Enable rate limiting
kubectl apply -f security/rate-limiting.yaml

# 2. Scale up to handle load
kubectl scale statefulset mana-node -n mana-system --replicas=6

# 3. Implement IP blocking
kubectl patch configmap nginx-config -n mana-system \
  --patch-file security/ip-block-patch.yaml

# 4. Activate DDoS protection
aws shield create-protection --resource-arn <load-balancer-arn>
```

---

## Capacity Planning

### Performance Capacity Analysis

**Monthly Review Process:**
```bash
# 1. Generate performance report
./scripts/generate-performance-report.sh --period 30d

# 2. Analyze growth trends
kubectl exec -n monitoring-system prometheus-0 -- \
  promtool query instant 'rate(verkle_operations_total[30d])'

# 3. Review resource utilization
kubectl top nodes
kubectl top pods -n mana-system --containers

# 4. Project future needs
./scripts/capacity-projection.sh --forecast 90d
```

### Scaling Triggers

**Automatic Scaling Thresholds:**
- CPU > 70% for 5 minutes → Scale up
- Memory > 80% for 5 minutes → Scale up
- Verkle ops < 20k/sec for 2 minutes → Scale up
- Queue depth > 1000 for 1 minute → Scale up

**Manual Scaling Decision Matrix:**
| Metric | Current | Target | Action |
|--------|---------|---------|--------|
| TPS | <50k | 100k+ | Add 2 nodes |
| Latency | >100ms | <50ms | Optimize/scale |
| Storage | >80% | <70% | Add storage |

---

## Disaster Recovery

### Full Datacenter Loss

**Recovery Procedure:**
1. **Assess Impact:**
   ```bash
   # Check remaining healthy datacenters
   dig +short api.mana.ethereum.local
   
   # Verify backup integrity
   aws s3 ls s3://mana-backups/latest/ --recursive
   ```

2. **Activate DR Datacenter:**
   ```bash
   # Deploy to DR region
   cd deployment/disaster-recovery
   terraform apply -var="dr_activation=true"
   
   # Update DNS routing
   aws route53 change-resource-record-sets \
     --hosted-zone-id Z123 \
     --change-batch file://dr-routing.json
   ```

3. **Data Recovery:**
   ```bash
   # Restore from latest backup
   ./scripts/restore-from-backup.sh \
     --backup-date="2024-01-01" \
     --target-datacenter="dr-us-west-1"
   ```

### Point-in-Time Recovery

**Specific Time Recovery:**
```bash
# 1. Identify backup timestamp
aws s3 ls s3://mana-backups/2024/01/01/ | grep -E "12:00"

# 2. Stop current services
kubectl scale statefulset mana-node -n mana-system --replicas=0

# 3. Restore to specific time
./scripts/point-in-time-restore.sh \
  --timestamp="2024-01-01T12:00:00Z" \
  --verify-integrity=true

# 4. Restart services
kubectl scale statefulset mana-node -n mana-system --replicas=3
```

---

## Routine Maintenance

### Weekly Maintenance Tasks

**Every Monday 02:00 UTC:**
```bash
#!/bin/bash
# weekly-maintenance.sh

# 1. Performance optimization
kubectl exec -n mana-system mana-node-0 -- \
  /opt/mana/bin/mana eval 'VerkleTree.UltraPerformanceOptimizer.weekly_optimization()'

# 2. Log rotation and cleanup
kubectl exec -n mana-system mana-node-0 -- \
  find /opt/mana/logs -name "*.log" -mtime +7 -delete

# 3. Database maintenance
kubectl exec -n mana-system antidote-0 -- \
  /opt/antidote/bin/antidote eval 'antidote_stats:weekly_maintenance().'

# 4. Certificate renewal check
kubectl exec -n mana-system mana-node-0 -- \
  openssl x509 -in /etc/ssl/mana.crt -noout -dates

# 5. Security audit
./scripts/weekly-security-audit.sh

# 6. Backup verification
./scripts/verify-backups.sh --last-week
```

### Monthly Maintenance

**First Sunday of Month 01:00 UTC:**
```bash
#!/bin/bash
# monthly-maintenance.sh

# 1. Full system health check
./scripts/comprehensive-health-check.sh

# 2. Performance baseline update
kubectl exec -n mana-system mana-node-0 -- \
  /opt/mana/bin/mana eval 'PerformanceMonitor.update_baselines()'

# 3. Security patches
kubectl patch daemonset node-patcher -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"patcher","env":[{"name":"PATCH_SCHEDULE","value":"now"}]}]}}}}'

# 4. Capacity planning review
./scripts/monthly-capacity-review.sh

# 5. Disaster recovery test
./scripts/dr-test.sh --dry-run=true
```

### Emergency Contact Information

**Escalation Chain:**
1. **Level 1 - On-call SRE:** Slack @sre-oncall, Phone: +1-xxx-xxx-xxxx
2. **Level 2 - Senior SRE:** Slack @sre-senior, Phone: +1-xxx-xxx-xxxx  
3. **Level 3 - Engineering Lead:** Slack @eng-lead, Phone: +1-xxx-xxx-xxxx
4. **Level 4 - CTO:** Slack @cto, Phone: +1-xxx-xxx-xxxx

**Communication Channels:**
- **Critical Alerts:** #mana-critical
- **General Operations:** #mana-ops
- **Performance Issues:** #mana-performance
- **Security Incidents:** #security-incidents

---

*Last Updated: $(date)*
*Next Review: First Monday of each month*