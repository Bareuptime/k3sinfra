# RabbitMQ HA Cluster - Quick Reference

## Installation

```bash
cd infra/k3s/rabbitmq
./install.sh
```

**Defaults**: 3 replicas, namespace: common, username: admin

---

## Connection Strings

### Internal (from pods)
```
amqp://admin:PASSWORD@rabbitmq.common.svc.cluster.local:5672
```

### Management UI (after port-forward)
```bash
kubectl port-forward -n common svc/rabbitmq 15672:15672
# http://localhost:15672
```

---

## Creating Quorum Queues

### Python (pika)
```python
channel.queue_declare(
    queue='my-queue',
    durable=True,
    arguments={'x-queue-type': 'quorum'}
)
```

### Node.js (amqplib)
```javascript
await channel.assertQueue('my-queue', {
    durable: true,
    arguments: {'x-queue-type': 'quorum'}
});
```

### Go (amqp091-go)
```go
ch.QueueDeclare(
    "my-queue", true, false, false, false,
    amqp.Table{"x-queue-type": "quorum"},
)
```

---

## Monitoring Commands

### Check Cluster Status
```bash
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl cluster_status
```

### Check Pods
```bash
kubectl get pods -n common -l app.kubernetes.io/name=rabbitmq
```

### Check Queues
```bash
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type messages consumers
```

### Check Connections
```bash
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_connections
```

### View Logs
```bash
kubectl logs -n common rabbitmq-server-0 -f
```

---

## Scaling

### Scale Up (use odd numbers: 3, 5, 7)
```bash
kubectl scale rabbitmqcluster rabbitmq -n common --replicas=5
```

### Scale Down
```bash
kubectl scale rabbitmqcluster rabbitmq -n common --replicas=3
```

---

## Troubleshooting

### Pod Not Ready
```bash
kubectl describe pod rabbitmq-server-X -n common
kubectl logs rabbitmq-server-X -n common
```

### Network Partition
```bash
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl cluster_status | grep -A 5 "Network Partitions"
```

### Force Pod Restart
```bash
kubectl delete pod rabbitmq-server-X -n common
```

### Reset Node (last resort)
```bash
kubectl exec -n common rabbitmq-server-X -- rabbitmqctl stop_app
kubectl exec -n common rabbitmq-server-X -- rabbitmqctl reset
kubectl exec -n common rabbitmq-server-X -- rabbitmqctl start_app
```

---

## Testing

### Run Test Suite
```bash
NAMESPACE=common ./test-ha-cluster.sh
```

### Manual Test
```bash
# Create test queue
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl eval \
  'rabbit_amqqueue:declare({resource, <<"/">>, queue, <<"test">>}, true, false, [{<<"x-queue-type">>, longstr, <<"quorum">>}], none, <<"admin">>).'

# Publish message
kubectl exec -n common rabbitmq-server-0 -- rabbitmqadmin publish routing_key=test payload="test message"

# Check message
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name messages
```

---

## Cleanup

```bash
NAMESPACE=common ./install.sh -d
```

---

## Important Notes

⚠️ **Quorum Queues**: All new queues are quorum queues by default (replicated across all nodes)

⚠️ **Odd Numbers**: Always use odd number of replicas (3, 5, 7) for quorum consensus

⚠️ **Classic Queues**: Existing classic queues need manual migration to quorum type

⚠️ **Backups**: Always backup before scaling down or deleting

---

## Common Issues

### Issue: Pod stuck in Pending
**Solution**: Check PVC status, ensure storage class exists
```bash
kubectl get pvc -n common
kubectl describe pvc persistence-rabbitmq-server-X -n common
```

### Issue: Cluster not forming
**Solution**: Check network connectivity, DNS resolution
```bash
kubectl exec -n common rabbitmq-server-0 -- nslookup rabbitmq-server-1.rabbitmq-nodes.common.svc.cluster.local
```

### Issue: High memory usage
**Solution**: Set max-length on queues, increase memory limits
```bash
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl set_policy max-length ".*" '{"max-length":50000}' --apply-to queues
```

---

## Files

- `install.sh` - Installation script
- `README.md` - Complete documentation
- `HA-SETUP.md` - HA cluster guide
- `QUORUM-QUEUES-GUIDE.md` - Quorum queue documentation
- `CHANGES.md` - What changed
- `test-ha-cluster.sh` - Automated tests
- `rabbitmq-info.txt` - Generated after install

---

## Resources

- [Quorum Queues](https://www.rabbitmq.com/quorum-queues.html)
- [Clustering](https://www.rabbitmq.com/clustering.html)
- [Monitoring](https://www.rabbitmq.com/monitoring.html)
- [Production Checklist](https://www.rabbitmq.com/production-checklist.html)
