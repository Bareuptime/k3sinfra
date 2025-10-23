# RabbitMQ HA Cluster - Changes Summary

## Overview

The `install.sh` script has been completely rewritten to deploy a **High Availability (HA) RabbitMQ cluster** with **quorum queues** for true data replication and fault tolerance.

## What Changed

### 1. Installation Script (`install.sh`)

#### Before
- Single RabbitMQ instance (1 replica)
- No HA configuration
- Basic setup with minimal configuration
- Classic queues by default

#### After
- **3-node HA cluster** by default (configurable)
- **Quorum queues enabled** by default for automatic replication
- **Comprehensive cluster configuration**:
  - Automatic cluster formation via K8s discovery
  - Pod anti-affinity for node distribution
  - Automatic partition healing
  - Performance tuning
  - Resource optimization (512Mi-2Gi memory)
- **Validation**: Warns if even number of replicas (odd numbers recommended)
- **Verification**: Automatically checks cluster formation after deployment
- **Policy setup**: Configures queue policies automatically

### 2. Key Features Added

#### High Availability
```yaml
replicas: 3  # Configurable, default 3
affinity:
  podAntiAffinity:  # Ensures pods run on different nodes
    preferredDuringSchedulingIgnoredDuringExecution: ...
```

#### Quorum Queues (True HA)
```yaml
rabbitmq:
  additionalConfig: |
    # Quorum queues by default
    default_queue_type = quorum
    
    # Cluster configuration
    cluster_formation.peer_discovery_backend = rabbit_peer_discovery_k8s
    cluster_partition_handling = autoheal
```

#### Resource Optimization
```yaml
resources:
  requests:
    cpu: 250m
    memory: 512Mi  # Increased from 256Mi
  limits:
    cpu: 1000m     # Increased from 500m
    memory: 2Gi    # Increased from 512Mi
```

#### Additional Plugins
- `rabbitmq_management` - Web UI
- `rabbitmq_peer_discovery_k8s` - Cluster formation
- `rabbitmq_prometheus` - Metrics
- `rabbitmq_shovel` - Message migration
- `rabbitmq_shovel_management` - Shovel UI

### 3. New Documentation

#### `QUORUM-QUEUES-GUIDE.md`
Comprehensive guide covering:
- What are quorum queues and why use them
- Code examples in Python, Node.js, Go, Java
- Migration strategies from classic queues
- Best practices for configuration
- Monitoring and troubleshooting
- Performance considerations

#### `HA-SETUP.md`
Detailed HA cluster documentation:
- Cluster configuration details
- Monitoring commands
- Scaling procedures
- Troubleshooting guide
- Security best practices

#### `test-ha-cluster.sh`
Automated test suite that verifies:
- All pods are running
- Cluster formation is correct
- No network partitions
- Quorum queue support
- Message publish/consume
- Optional failover testing

#### Updated `README.md`
- Complete rewrite focusing on HA features
- Quick start guide
- Migration instructions
- Monitoring and operations
- Performance tuning tips

### 4. Installation Info Output

The script now generates comprehensive `rabbitmq-info.txt` with:
- Cluster configuration details
- HA features summary
- Code examples for creating quorum queues
- Monitoring commands
- Connection information

## Migration Guide

### For New Installations

Simply run:
```bash
cd infra/k3s/rabbitmq
./install.sh
```

Follow prompts:
- Namespace: `common` (or your choice)
- Replicas: `3` (recommended)
- Username: `admin`
- Password: (secure password)

### For Existing Single-Instance Deployments

#### Option 1: Scale Existing (if using Bitnami/Helm)
```bash
# Scale to 3 replicas
kubectl scale statefulset rabbitmq -n message-broker --replicas=3

# Wait for cluster formation
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n message-broker --timeout=600s

# Verify
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl cluster_status
```

#### Option 2: Fresh Install (Recommended)
```bash
# 1. Backup existing data
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl export_definitions /tmp/definitions.json
kubectl cp message-broker/rabbitmq-0:/tmp/definitions.json ./backup-definitions.json

# 2. Cleanup old installation
NAMESPACE=message-broker ./install.sh -d

# 3. Install new HA cluster
./install.sh
# Choose namespace: message-broker
# Choose replicas: 3

# 4. Import definitions (if needed)
kubectl cp ./backup-definitions.json message-broker/rabbitmq-server-0:/tmp/definitions.json
kubectl exec -n message-broker rabbitmq-server-0 -- rabbitmqctl import_definitions /tmp/definitions.json
```

### Migrating Queues to Quorum Type

Existing classic queues won't automatically become quorum queues. See `QUORUM-QUEUES-GUIDE.md` for detailed migration strategies:

1. **Blue-Green Migration** (Recommended)
   - Create new quorum queues
   - Update applications
   - Drain old queues
   - Delete old queues

2. **Shovel Migration** (Zero Downtime)
   - Use RabbitMQ Shovel plugin
   - Move messages from classic to quorum queues
   - No application downtime

## Testing

Run the automated test suite:
```bash
cd infra/k3s/rabbitmq
NAMESPACE=common ./test-ha-cluster.sh
```

This will verify:
- ✓ All pods running and ready
- ✓ Cluster formation correct
- ✓ No network partitions
- ✓ Quorum queues supported
- ✓ Message publish/consume works
- ✓ Optional: Failover recovery

## Benefits

### Before (Single Instance)
- ❌ Single point of failure
- ❌ No automatic failover
- ❌ Data loss on pod failure
- ❌ Manual recovery required
- ❌ No message replication

### After (HA Cluster)
- ✅ Fault tolerant (survives node failures)
- ✅ Automatic failover
- ✅ No data loss (quorum queues)
- ✅ Automatic recovery
- ✅ Message replication across nodes
- ✅ Better performance (distributed load)
- ✅ Production-ready

## Performance Impact

### Throughput
- **Classic queues**: ~50-100k msg/sec
- **Quorum queues**: ~20-50k msg/sec
- **Trade-off**: Safety over raw speed (acceptable for most workloads)

### Latency
- **Additional latency**: 1-5ms (due to Raft consensus)
- **Acceptable** for most production use cases

### Resource Usage
- **Memory**: Increased (512Mi-2Gi per node vs 256Mi-512Mi)
- **Storage**: 8Gi per node (3 nodes = 24Gi total)
- **CPU**: Optimized (250m-1000m per node)

## Rollback

If you need to rollback to single instance:

```bash
# Scale down to 1 replica
kubectl scale rabbitmqcluster rabbitmq -n common --replicas=1

# Or use old installation method
# (Note: You'll need to restore the old install.sh from git history)
```

## Support

For issues or questions:
1. Check `HA-SETUP.md` for troubleshooting
2. Check `QUORUM-QUEUES-GUIDE.md` for queue-specific issues
3. Run `test-ha-cluster.sh` to diagnose problems
4. Check RabbitMQ logs: `kubectl logs -n common rabbitmq-server-0`

## References

- [RabbitMQ Quorum Queues](https://www.rabbitmq.com/quorum-queues.html)
- [RabbitMQ Clustering](https://www.rabbitmq.com/clustering.html)
- [RabbitMQ Operator](https://www.rabbitmq.com/kubernetes/operator/operator-overview.html)
- [Production Checklist](https://www.rabbitmq.com/production-checklist.html)
