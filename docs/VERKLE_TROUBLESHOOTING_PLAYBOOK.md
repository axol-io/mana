# Verkle Trees Troubleshooting Playbook

**Version**: 1.0  
**Last Updated**: 2025-09-05  
**Classification**: Internal Operations

## Quick Reference

| Issue | Severity | Response Time | Escalation |
|-------|----------|---------------|------------|
| High Latency | 🟡 Medium | 15 minutes | Performance Team |
| Memory Leak | 🟠 High | 5 minutes | Platform Team |
| Crypto Errors | 🔴 Critical | Immediate | Security Team |
| State Corruption | 🔴 Critical | Immediate | Lead Architect |

## Alert Response Procedures

### 🟡 VerkleHighLatency Alert

**Symptoms**: Insert latency P99 > 500μs for 2+ minutes

**Immediate Actions**:
```bash
# Check current performance
curl http://localhost:8080/verkle/performance | jq '.latency_p99_us'

# Check cache hit rate
curl http://localhost:8080/metrics | grep verkle_cache_hit_rate

# Check memory usage
curl http://localhost:8080/metrics | grep verkle_memory_usage
```

**Diagnosis Steps**:
1. **Cache Performance**:
   ```bash
   # Check cache statistics
   curl http://localhost:8080/verkle/cache/stats
   
   # Look for low hit rates < 85%
   if [ $(curl -s http://localhost:8080/metrics | grep cache_hit_rate | awk '{print $2}') -lt 85 ]; then
       echo "Low cache hit rate detected"
   fi
   ```

2. **Memory Pressure**:
   ```bash
   # Check if system is swapping
   vmstat 1 3
   
   # Check Verkle memory usage
   curl http://localhost:8080/verkle/memory/detailed
   ```

3. **CPU Saturation**:
   ```bash
   # Check CPU load
   top -bn1 | grep "load average"
   
   # Check Verkle-specific CPU usage
   curl http://localhost:8080/verkle/cpu/profile
   ```

**Resolution Actions**:
```bash
# Option 1: Clear cache to resolve memory pressure
curl -X POST http://localhost:8080/verkle/cache/clear

# Option 2: Reduce cache size temporarily
export VERKLE_CACHE_SIZE=256MB
systemctl restart mana-verkle

# Option 3: Enable performance mode
export VERKLE_PERFORMANCE_MODE=aggressive
systemctl restart mana-verkle
```

**Validation**:
```bash
# Wait 5 minutes then check latency
sleep 300
latency=$(curl -s http://localhost:8080/verkle/performance | jq '.latency_p99_us')
if [ $latency -lt 100 ]; then
    echo "✅ Latency resolved: ${latency}μs"
else
    echo "❌ Latency still high: ${latency}μs - ESCALATE"
fi
```

### 🟠 VerkleMemoryLeak Alert

**Symptoms**: Memory usage > 6GB and growing

**Immediate Actions**:
```bash
# Get detailed memory breakdown
curl http://localhost:8080/verkle/memory/detailed

# Check for memory leaks in caches
curl http://localhost:8080/verkle/cache/sizes

# Emergency memory cleanup
curl -X POST http://localhost:8080/verkle/memory/emergency_cleanup
```

**Diagnosis Steps**:
1. **Cache Size Analysis**:
   ```bash
   # Check cache growth over time
   curl http://localhost:8080/verkle/cache/history | tail -20
   
   # Identify largest cache consumers
   curl http://localhost:8080/verkle/cache/top_consumers
   ```

2. **Witness Memory Usage**:
   ```bash
   # Check witness cache size
   curl http://localhost:8080/verkle/witnesses/memory_usage
   
   # Check for stuck witnesses
   curl http://localhost:8080/verkle/witnesses/stuck
   ```

3. **Native Memory Leaks**:
   ```bash
   # Check native heap usage
   curl http://localhost:8080/verkle/native/memory
   
   # Check for Rust NIF memory issues
   curl http://localhost:8080/verkle/native/health
   ```

**Resolution Actions**:
```bash
# Aggressive cache cleanup
curl -X POST http://localhost:8080/verkle/cache/aggressive_cleanup

# Restart with memory debugging
export VERKLE_MEMORY_DEBUG=true
export VERKLE_CACHE_SIZE=1GB
systemctl restart mana-verkle

# If critical, temporary fallback to MPT
export VERKLE_FALLBACK_MODE=mpt
systemctl restart mana-verkle
```

### 🔴 VerkleWitnessVerificationFailure Alert

**Symptoms**: Witness verification success rate < 95%

**Immediate Actions**:
```bash
# Check crypto system health
curl http://localhost:8080/verkle/crypto/health

# Get recent verification failures
curl http://localhost:8080/verkle/witnesses/failures | tail -20

# Enable strict verification mode
curl -X POST http://localhost:8080/verkle/verification/strict_mode
```

**Diagnosis Steps**:
1. **Cryptographic Issues**:
   ```bash
   # Test crypto functions
   curl -X POST http://localhost:8080/verkle/crypto/self_test
   
   # Check NIF compilation status
   curl http://localhost:8080/verkle/native/compilation_status
   ```

2. **Network Issues**:
   ```bash
   # Check peer quality
   curl http://localhost:8080/verkle/peers/quality
   
   # Check for malicious peers
   curl http://localhost:8080/verkle/peers/suspicious
   ```

3. **State Corruption**:
   ```bash
   # Verify state integrity
   curl -X POST http://localhost:8080/verkle/state/verify_integrity
   
   # Check for missing witnesses
   curl http://localhost:8080/verkle/witnesses/missing_count
   ```

**Resolution Actions**:
```bash
# Recompile native extensions
mix clean && mix compile --force

# Restart with crypto validation
export VERKLE_CRYPTO_VALIDATION=strict
systemctl restart mana-verkle

# If persistent, disable affected peers
curl -X POST http://localhost:8080/verkle/peers/quarantine_suspicious
```

## Performance Troubleshooting

### Latency Issues

**Scenario**: Verkle operations slower than 35x MPT improvement

**Debug Commands**:
```bash
# Profile hot paths
curl -X POST http://localhost:8080/verkle/profile/start
# ... wait 60 seconds ...
curl -X POST http://localhost:8080/verkle/profile/stop
curl http://localhost:8080/verkle/profile/results

# Check SIMD utilization
curl http://localhost:8080/verkle/simd/status

# Analyze cache patterns
curl http://localhost:8080/verkle/cache/access_patterns
```

**Common Solutions**:
```bash
# Enable SIMD optimizations
export VERKLE_SIMD_ENABLED=true

# Increase batch sizes
export VERKLE_BATCH_SIZE=256

# Enable parallel processing
export VERKLE_PARALLEL_WORKERS=8

systemctl restart mana-verkle
```

### Throughput Issues

**Scenario**: Operations per second below targets

**Debug Commands**:
```bash
# Check bottlenecks
curl http://localhost:8080/verkle/bottlenecks/analyze

# Monitor queue depths
curl http://localhost:8080/verkle/queues/depths

# Check network efficiency
curl http://localhost:8080/verkle/network/efficiency
```

## Network Troubleshooting

### State Sync Issues

**Scenario**: Verkle state sync failing or slow

**Debug Steps**:
```bash
# Check sync status
curl http://localhost:8080/verkle/sync/status

# Identify sync bottlenecks
curl http://localhost:8080/verkle/sync/bottlenecks

# Check peer witness quality
curl http://localhost:8080/verkle/peers/witness_quality
```

**Common Fixes**:
```bash
# Force state healing
curl -X POST http://localhost:8080/verkle/state/force_heal

# Increase sync workers
export VERKLE_SYNC_WORKERS=32
systemctl restart mana-verkle

# Enable witness compression
export VERKLE_WITNESS_COMPRESSION=true
systemctl restart mana-verkle
```

### Witness Request Timeouts

**Scenario**: High witness request failure rate

**Debug Commands**:
```bash
# Check timeout patterns
curl http://localhost:8080/verkle/requests/timeout_analysis

# Check peer responsiveness
curl http://localhost:8080/verkle/peers/response_times

# Analyze network conditions
curl http://localhost:8080/verkle/network/conditions
```

## Data Integrity Troubleshooting

### State Corruption Detection

**Scenario**: Suspected Verkle state corruption

**Emergency Response**:
```bash
# Stop all operations
curl -X POST http://localhost:8080/verkle/emergency_stop

# Run integrity check
curl -X POST http://localhost:8080/verkle/integrity/full_check

# Generate state report
curl http://localhost:8080/verkle/state/integrity_report > integrity_report.json
```

**Recovery Steps**:
```bash
# Attempt automatic repair
curl -X POST http://localhost:8080/verkle/repair/auto

# If repair fails, restore from backup
./scripts/restore_verkle.sh $(date -d "yesterday" +%Y%m%d)

# Validate recovery
curl -X POST http://localhost:8080/verkle/validate/post_recovery
```

### Witness Corruption

**Scenario**: Invalid witnesses detected

**Immediate Actions**:
```bash
# Identify corrupted witnesses
curl http://localhost:8080/verkle/witnesses/corrupted_list

# Quarantine bad witnesses
curl -X POST http://localhost:8080/verkle/witnesses/quarantine_corrupted

# Request witness regeneration
curl -X POST http://localhost:8080/verkle/witnesses/regenerate_corrupted
```

## Monitoring Command Reference

### Health Checks
```bash
# Overall health
curl http://localhost:8080/verkle/health

# Detailed health with metrics
curl http://localhost:8080/verkle/health/detailed

# Component-specific health
curl http://localhost:8080/verkle/crypto/health
curl http://localhost:8080/verkle/cache/health
curl http://localhost:8080/verkle/network/health
```

### Performance Metrics
```bash
# Current performance snapshot
curl http://localhost:8080/verkle/performance/snapshot

# Performance over time
curl http://localhost:8080/verkle/performance/trends?hours=24

# Compare with baselines
curl http://localhost:8080/verkle/performance/vs_baseline
```

### Resource Usage
```bash
# Memory usage breakdown
curl http://localhost:8080/verkle/resources/memory

# CPU usage by component
curl http://localhost:8080/verkle/resources/cpu

# Network utilization
curl http://localhost:8080/verkle/resources/network
```

## Emergency Procedures

### Complete System Recovery

**When**: System is unresponsive or corrupted beyond repair

```bash
#!/bin/bash
# emergency_recovery.sh

echo "🚨 EMERGENCY VERKLE RECOVERY INITIATED"

# Stop all services
systemctl stop mana-verkle

# Backup current state for forensics
mkdir -p /emergency_backup/$(date +%Y%m%d_%H%M%S)
cp -r data/verkle /emergency_backup/$(date +%Y%m%d_%H%M%S)/

# Restore from latest good backup
LATEST_BACKUP=$(ls -t /backup/verkle/ | head -1)
echo "Restoring from backup: $LATEST_BACKUP"
cp -r /backup/verkle/$LATEST_BACKUP/* data/verkle/

# Start with recovery mode
export VERKLE_RECOVERY_MODE=true
export VERKLE_STRICT_VALIDATION=true
systemctl start mana-verkle

# Wait for startup
sleep 60

# Validate recovery
if curl -s http://localhost:8080/verkle/health | grep "healthy"; then
    echo "✅ Emergency recovery successful"
    # Disable recovery mode
    export VERKLE_RECOVERY_MODE=false
    systemctl restart mana-verkle
else
    echo "❌ Emergency recovery failed - ESCALATE TO ARCHITECT"
fi
```

### Performance Degradation Response

**When**: Performance drops below acceptable thresholds

```bash
#!/bin/bash
# performance_emergency.sh

echo "⚡ PERFORMANCE EMERGENCY RESPONSE"

# Get current performance metrics
LATENCY=$(curl -s http://localhost:8080/verkle/performance | jq '.latency_p99_us')
echo "Current P99 latency: ${LATENCY}μs"

if [ $LATENCY -gt 1000 ]; then
    echo "🔴 Critical performance degradation"
    
    # Emergency performance mode
    export VERKLE_EMERGENCY_PERFORMANCE=true
    export VERKLE_CACHE_SIZE=4GB
    export VERKLE_PARALLEL_WORKERS=16
    
    systemctl restart mana-verkle
    
    # Monitor recovery
    sleep 120
    NEW_LATENCY=$(curl -s http://localhost:8080/verkle/performance | jq '.latency_p99_us')
    echo "New P99 latency: ${NEW_LATENCY}μs"
    
    if [ $NEW_LATENCY -lt 500 ]; then
        echo "✅ Performance recovered"
    else
        echo "❌ Performance still degraded - ESCALATE"
    fi
fi
```

## Contact Escalation

### Level 1: Operations Team
- **Response Time**: 15 minutes
- **Coverage**: 24/7
- **Contact**: ops-verkle@mana-ethereum.org

### Level 2: Performance Team  
- **Response Time**: 30 minutes
- **Coverage**: Business hours
- **Contact**: performance@mana-ethereum.org

### Level 3: Security Team
- **Response Time**: 15 minutes (security issues)
- **Coverage**: 24/7
- **Contact**: security-urgent@mana-ethereum.org

### Level 4: Lead Architect
- **Response Time**: 1 hour (critical only)
- **Coverage**: On-call
- **Contact**: architect-escalation@mana-ethereum.org

## Incident Response Templates

### Performance Incident
```markdown
# Verkle Performance Incident

**Incident ID**: VERKLE-PERF-$(date +%Y%m%d-%H%M%S)
**Start Time**: $(date)
**Severity**: [Low/Medium/High/Critical]

## Symptoms
- P99 Latency: XXXμs (target: <100μs)
- Cache Hit Rate: XX% (target: >85%)
- Error Rate: X.X% (target: <0.1%)

## Actions Taken
- [ ] Checked cache performance
- [ ] Analyzed memory usage  
- [ ] Reviewed CPU utilization
- [ ] Applied mitigation

## Resolution
[Description of resolution]

## Follow-up Actions
- [ ] Root cause analysis
- [ ] Performance optimization
- [ ] Monitoring improvements
```

### Security Incident
```markdown
# Verkle Security Incident

**Incident ID**: VERKLE-SEC-$(date +%Y%m%d-%H%M%S)
**Start Time**: $(date)
**Severity**: [Critical/High/Medium/Low]

## Nature of Incident
[Witness verification failure/Crypto corruption/etc]

## Immediate Actions Taken
- [ ] Enabled strict verification
- [ ] Quarantined suspicious peers
- [ ] Validated crypto functions

## Security Impact Assessment
[Assessment of potential impact]

## Mitigation Status
[Current status and next steps]
```

---

**Document Classification**: Internal Operations  
**Version**: 1.0  
**Emergency Contact**: +1-555-VERKLE-EMG