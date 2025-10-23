# RabbitMQ High Availability Installation

## 🏆 Recommended: Official RabbitMQ Operator with HA Cluster

**Use**: `install.sh`

**Features:**
- ✅ Official RabbitMQ project
- ✅ Uses official `rabbitmq:3.13-management` Docker image
- ✅ **High Availability**: 3-node cluster by default
- ✅ **Quorum Queues**: True HA with automatic replication
- ✅ **Automatic Failover**: Built-in cluster healing
- ✅ **Production-ready**: Officially supported and maintained
- ✅ **Pod Anti-Affinity**: Distributes pods across nodes
- ✅ **Prometheus Metrics**: Built-in monitoring

**Install:**
```bash
./install.sh
```

**Cleanup:**
```bash
NAMESPACE=common ./install.sh -d
```

**Configuration Options:**
- Namespace: Default `common`
- Replicas: Default `3` (recommended: odd numbers like 3, 5, 7)
- Username: Default `admin`
- Password: Required (prompted during installation)

---

## What You Get

### High Availability Cluster
- **3-node cluster** (configurable) for fault tolerance
- **Automatic cluster formation** via Kubernetes service discovery
- **Pod anti-affinity** ensures pods run on different nodes
- **Automatic partition healing** for network split scenarios

### Quorum Queues (True HA)
- **Automatic replication** across all cluster nodes
- **Raft consensus algorithm** for data consistency
- **Automatic leader election** on node failure
- **No message loss** during failover
- **Default queue type** set to quorum for all new queues

### Production Features
- **Persistent storage**: 8Gi per node (configurable)
- **Resource limits**: Optimized for production workloads
- **Prometheus metrics**: Built-in monitoring on port 15692
- **Management UI**: Web interface on port 15672
- **Health checks**: Kubernetes liveness and readiness probes

---

## Quick Start

### 1. Install HA Cluster
```bash
cd infra/k3s/rabbitmq
./install.sh
```

Follow the prompts:
- Namespace: `common` (or your choice)
- Replicas: `3` (recommended)
- Username: `admin` (or your choice)
- Password: (enter secure password)

### 2. Verify Installation
```bash
# Check all pods are running
kubectl get pods -n common -l app.kubernetes.io/name=rabbitmq

# Check cluster status
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl cluster_status

# Access Management UI
kubectl port-forward -n common svc/rabbitmq 15672:15672
# Open http://localhost:15672
```

### 3. Create Quorum Queues
See `QUORUM-QUEUES-GUIDE.md` for detailed examples in:
- Python (pika)
- Node.js (amqplib)
- Go (amqp091-go)
- Java (Spring AMQP)

**Quick Example (Python):**
```python
channel.queue_declare(
    queue='my-ha-queue',
    durable=True,
    arguments={'x-queue-type': 'quorum'}
)
```

---

## Documentation

- **`HA-SETUP.md`**: Comprehensive HA cluster guide
- **`QUORUM-QUEUES-GUIDE.md`**: Complete quorum queue documentation
- **`rabbitmq-info.txt`**: Generated after installation with connection details

---

## Migration from Single Instance

If you have an existing single-instance RabbitMQ:

```bash
# 1. Backup existing data (if needed)
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl export_definitions /tmp/definitions.json

# 2. Scale to HA cluster
kubectl scale statefulset rabbitmq -n message-broker --replicas=3

# 3. Wait for cluster formation
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n message-broker --timeout=600s

# 4. Verify cluster
kubectl exec -n message-broker rabbitmq-0 -- rabbitmqctl cluster_status
```

**Note**: Existing classic queues won't be automatically replicated. See `QUORUM-QUEUES-GUIDE.md` for migration strategies.

## Monitoring and Operations

### Check Cluster Health
```bash
# Cluster status
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl cluster_status

# Node health
kubectl get pods -n common -l app.kubernetes.io/name=rabbitmq

# Queue status
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl list_queues name type messages consumers
```

### Scaling Operations
```bash
# Scale up (always use odd numbers: 3, 5, 7)
kubectl scale rabbitmqcluster rabbitmq -n common --replicas=5

# Scale down (careful with data)
kubectl scale rabbitmqcluster rabbitmq -n common --replicas=3
```

### Troubleshooting
```bash
# View logs
kubectl logs -n common rabbitmq-server-0 -f

# Check for network partitions
kubectl exec -n common rabbitmq-server-0 -- rabbitmqctl cluster_status | grep -A 5 "Network Partitions"

# Force node to rejoin cluster
kubectl delete pod rabbitmq-server-X -n common
```

---

## Performance Tuning

### For High Throughput
- Increase replicas to 5 or 7
- Use multiple queues (sharding)
- Increase resources (CPU/Memory)
- Use lazy queues for large backlogs

### For Low Latency
- Keep cluster size at 3 nodes
- Use classic queues for non-critical data
- Optimize network between nodes
- Use local storage class

---

## Security Best Practices

1. **Change default credentials** immediately after installation
2. **Enable TLS** for production (see RabbitMQ docs)
3. **Use network policies** to restrict access
4. **Regular backups** of definitions and data
5. **Monitor metrics** for unusual activity

---

## More Information

- [RabbitMQ Cluster Operator Docs](https://www.rabbitmq.com/kubernetes/operator/install-operator)
- [Quorum Queues Documentation](https://www.rabbitmq.com/quorum-queues.html)
- [Official RabbitMQ Docker Image](https://hub.docker.com/_/rabbitmq)
- [RabbitMQ Clustering Guide](https://www.rabbitmq.com/clustering.html)
- [Production Checklist](https://www.rabbitmq.com/production-checklist.html)
