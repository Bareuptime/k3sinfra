# RabbitMQ High Availability (HA) Cluster Setup

## Overview

RabbitMQ has been configured as a 3-node HA cluster in the `message-broker` namespace.

## Cluster Configuration

- **Nodes**: 3 replicas (rabbitmq-0, rabbitmq-1, rabbitmq-2)
- **Namespace**: message-broker
- **Version**: RabbitMQ 4.1.3 on Erlang 27.3.4
- **Storage**: 8Gi per node (local-path storage class)
- **Resources per node**:
  - Memory Request: 2Gi
  - Memory Limit: 4Gi

## Cluster Status

All 3 nodes are running as disk nodes in the cluster:
- rabbit@rabbitmq-0.rabbitmq-headless.message-broker.svc.cluster.local
- rabbit@rabbitmq-1.rabbitmq-headless.message-broker.svc.cluster.local
- rabbit@rabbitmq-2.rabbitmq-headless.message-broker.svc.cluster.local

## Services

- **rabbitmq**: ClusterIP service for client connections (10.43.112.106)
  - AMQP: 5672
  - Management UI: 15672
  - Inter-node communication: 25672
  - EPMD: 4369
  - Prometheus metrics: 9419

- **rabbitmq-headless**: Headless service for cluster formation

## High Availability Features

### 1. Automatic Cluster Formation
- Uses `rabbitmq_peer_discovery_k8s` plugin
- Nodes automatically discover and join the cluster
- No manual intervention required for cluster formation

### 2. Automatic Failover
- If a node fails, StatefulSet automatically recreates it
- Node rejoins the cluster automatically upon restart
- Tested: Pod deletion and recovery works seamlessly

### 3. Queue Policies
A policy has been configured for all queues:
```bash
Policy: ha-replication
Pattern: .*
Settings:
  - max-length: 1,000,000 messages
  - overflow: reject-publish
```

## Important Notes for RabbitMQ 4.x

### Classic Queues vs Quorum Queues

**Current Setup**: Existing queues are classic queues (non-replicated by default in RabbitMQ 4.x)

**Recommendation**: Migrate to Quorum Queues for true HA

#### Why Quorum Queues?
- Built-in replication across cluster nodes
- Automatic leader election
- Data safety guarantees
- Better suited for HA scenarios

#### Migration Path

For new queues, declare them as quorum queues:

**Python (pika)**:
```python
channel.queue_declare(
    queue='my-queue',
    durable=True,
    arguments={'x-queue-type': 'quorum'}
)
```

**Node.js (amqplib)**:
```javascript
channel.assertQueue('my-queue', {
    durable: true,
    arguments: {'x-queue-type': 'quorum'}
});
```

**For existing queues**, you'll need to:
1. Create new quorum queues with different names
2. Update applications to use new queues
3. Drain and delete old classic queues

## Monitoring

### Check Cluster Status
```bash
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl cluster_status
```

### Check Node Health
```bash
kubectl get pods -n message-broker -l app.kubernetes.io/name=rabbitmq
```

### Check Queues
```bash
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl list_queues name type messages consumers
```

### Check Connections
```bash
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl list_connections
```

### Access Management UI
```bash
kubectl port-forward -n message-broker svc/rabbitmq 15672:15672
```
Then open: http://localhost:15672

## Scaling

### Scale Up
```bash
kubectl scale statefulset rabbitmq -n message-broker --replicas=5
```

### Scale Down (Careful!)
```bash
# First, ensure no critical data on the node being removed
kubectl scale statefulset rabbitmq -n message-broker --replicas=2
```

**Note**: Always maintain an odd number of nodes (3, 5, 7) for quorum-based features.

## Backup and Recovery

### Backup Configuration
Backups are stored in `/tmp/rabbitmq-backup/`:
- rabbitmq-secret.yaml
- rabbitmq-config-secret.yaml
- configmaps.yaml

### Restore from Backup
```bash
kubectl apply -f /tmp/rabbitmq-backup/rabbitmq-secret.yaml
kubectl apply -f /tmp/rabbitmq-backup/rabbitmq-config-secret.yaml
```

## Troubleshooting

### Node Not Joining Cluster
```bash
# Check logs
kubectl logs -n message-broker rabbitmq-X

# Force node to forget cluster
kubectl exec -n message-broker rabbitmq-X -- rabbitmqctl stop_app
kubectl exec -n message-broker rabbitmq-X -- rabbitmqctl reset
kubectl exec -n message-broker rabbitmq-X -- rabbitmqctl start_app
```

### Network Partition
```bash
# Check for partitions
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl cluster_status | grep -A 5 "Network Partitions"

# If partitions exist, restart affected nodes
kubectl delete pod rabbitmq-X -n message-broker
```

### Memory Issues
```bash
# Check memory usage
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl status | grep memory

# Increase memory limits if needed
kubectl edit statefulset rabbitmq -n message-broker
```

## Performance Considerations

1. **Network Latency**: All nodes should be in the same datacenter/region
2. **Disk I/O**: Use fast storage for better performance
3. **Memory**: Monitor memory usage, especially with many queues/connections
4. **Connection Distribution**: Use load balancer or connection pooling

## Security

- Credentials stored in Kubernetes secrets
- TLS can be enabled for inter-node communication
- Management UI should be accessed via port-forward or ingress with authentication

## Next Steps

1. **Migrate to Quorum Queues**: Update application code to use quorum queues
2. **Enable TLS**: Configure TLS for client and inter-node communication
3. **Set up Monitoring**: Integrate with Prometheus/Grafana
4. **Configure Alerts**: Set up alerts for node failures, memory issues, etc.
5. **Load Testing**: Test cluster under production-like load

## References

- [RabbitMQ Clustering Guide](https://www.rabbitmq.com/clustering.html)
- [Quorum Queues](https://www.rabbitmq.com/quorum-queues.html)
- [RabbitMQ on Kubernetes](https://www.rabbitmq.com/kubernetes/operator/operator-overview.html)
