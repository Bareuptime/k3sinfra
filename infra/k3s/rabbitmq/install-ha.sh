#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    # Get namespace from environment or prompt
    if [ -z "${NAMESPACE:-}" ]; then
        read -p "Enter namespace to cleanup [common]: " NAMESPACE
        NAMESPACE=${NAMESPACE:-common}
    fi
    
    echo "Cleaning up RabbitMQ HA Cluster installation from namespace: $NAMESPACE..."

    # Delete RabbitMQ cluster
    kubectl delete rabbitmqcluster rabbitmq -n $NAMESPACE 2>/dev/null || true
    
    echo "Waiting for cluster to be deleted..."
    sleep 10

    # Optionally delete operator (commented out by default to preserve for other clusters)
    # kubectl delete -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml 2>/dev/null || true

    # Clean local files
    rm -f rabbitmq-info.txt rabbitmq-cluster.yaml

    echo "✅ RabbitMQ HA Cluster cleanup complete!"
    echo ""
    echo "Note: RabbitMQ Cluster Operator was not removed (it may manage other clusters)"
    echo "To remove operator: kubectl delete -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing RabbitMQ HA Cluster using Official Operator..."

# Prompt for configuration
read -p "Enter namespace [common]: " NAMESPACE
NAMESPACE=${NAMESPACE:-common}

read -p "Enter number of replicas [3]: " REPLICAS
REPLICAS=${REPLICAS:-3}

# Validate replicas is odd number (recommended for quorum)
if [ $((REPLICAS % 2)) -eq 0 ]; then
  echo "⚠️  Warning: Even number of replicas detected. Odd numbers (3, 5, 7) are recommended for quorum-based HA."
  read -p "Continue anyway? (y/n): " CONTINUE
  if [[ ! "$CONTINUE" =~ ^[Yy]$ ]]; then
    exit 1
  fi
fi

read -p "Enter RabbitMQ username [admin]: " RABBITMQ_USER
RABBITMQ_USER=${RABBITMQ_USER:-admin}

read -sp "Enter RabbitMQ password: " RABBITMQ_PASS
echo

if [[ -z "$RABBITMQ_PASS" ]]; then
  echo "Password cannot be empty"
  exit 1
fi

# Create namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install RabbitMQ Cluster Operator
echo "Installing RabbitMQ Cluster Operator..."
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

echo "Waiting for operator to be ready..."
kubectl wait --for=condition=available deployment/rabbitmq-cluster-operator -n rabbitmq-system --timeout=300s

# Create RabbitMQ HA cluster manifest
cat > rabbitmq-cluster.yaml <<EOF
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: rabbitmq
  namespace: $NAMESPACE
spec:
  replicas: $REPLICAS
  image: rabbitmq:3.13-management
  resources:
    requests:
      cpu: 250m
      memory: 512Mi
    limits:
      cpu: 1000m
      memory: 2Gi
  rabbitmq:
    additionalConfig: |
      # Default user credentials
      default_user = $RABBITMQ_USER
      default_pass = $RABBITMQ_PASS
      
      # Cluster configuration
      cluster_formation.peer_discovery_backend = rabbit_peer_discovery_k8s
      cluster_formation.k8s.host = kubernetes.default.svc.cluster.local
      cluster_formation.k8s.address_type = hostname
      cluster_formation.node_cleanup.interval = 30
      cluster_formation.node_cleanup.only_log_warning = true
      cluster_partition_handling = autoheal
      
      # Quorum queue defaults for HA
      default_queue_type = quorum
      
      # Memory and disk thresholds
      vm_memory_high_watermark.relative = 0.6
      disk_free_limit.absolute = 2GB
      
      # Performance tuning
      channel_max = 2048
      heartbeat = 60
      
      # Logging
      log.console.level = info
    additionalPlugins:
      - rabbitmq_management
      - rabbitmq_peer_discovery_k8s
      - rabbitmq_prometheus
      - rabbitmq_shovel
      - rabbitmq_shovel_management
  persistence:
    storageClassName: local-path
    storage: 8Gi
  affinity:
    podAntiAffinity:
      preferredDuringSchedulingIgnoredDuringExecution:
        - weight: 100
          podAffinityTerm:
            labelSelector:
              matchExpressions:
                - key: app.kubernetes.io/name
                  operator: In
                  values:
                    - rabbitmq
            topologyKey: kubernetes.io/hostname
  override:
    statefulSet:
      spec:
        template:
          spec:
            containers:
              - name: rabbitmq
                env:
                  - name: RABBITMQ_DEFAULT_QUEUE_TYPE
                    value: "quorum"
EOF

echo "Deploying RabbitMQ HA cluster with $REPLICAS replicas..."
kubectl apply -f rabbitmq-cluster.yaml

echo "Waiting for RabbitMQ cluster to be ready (this may take 2-3 minutes)..."
sleep 30
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n $NAMESPACE --timeout=600s

echo ""
echo "Verifying cluster formation..."
sleep 10

# Get the first pod name
FIRST_POD=$(kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq -o jsonpath='{.items[0].metadata.name}')

# Check cluster status
echo "Cluster Status:"
kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status 2>&1 | grep -A 20 "Running Nodes" || echo "Cluster status check completed"

echo ""
echo "Setting up quorum queue policies..."
# Set policy for quorum queues with replication
kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl set_policy ha-quorum-all ".*" \
  '{"max-length":1000000,"overflow":"reject-publish"}' \
  --apply-to queues --priority 1 2>/dev/null || echo "Policy already exists or will be applied"

# Get service info
RABBITMQ_SERVICE=$(kubectl get service rabbitmq -n $NAMESPACE -o jsonpath='{.metadata.name}')
RABBITMQ_URL="amqp://$RABBITMQ_USER:$RABBITMQ_PASS@$RABBITMQ_SERVICE.$NAMESPACE.svc.cluster.local:5672"
RABBITMQ_MGMT_URL="http://$RABBITMQ_SERVICE.$NAMESPACE.svc.cluster.local:15672"

# Save credentials and cluster info
cat > rabbitmq-info.txt <<EOF
RabbitMQ HA Cluster Installation Info
======================================
Namespace: $NAMESPACE
Replicas: $REPLICAS
Username: $RABBITMQ_USER
Password: $RABBITMQ_PASS

Connection:
AMQP URL: $RABBITMQ_URL
Management URL: $RABBITMQ_MGMT_URL

Ports:
- AMQP: 5672
- Management: 15672
- Prometheus Metrics: 15692

High Availability Features:
- ✅ $REPLICAS-node cluster for fault tolerance
- ✅ Quorum queues enabled by default (true HA)
- ✅ Automatic cluster formation via K8s discovery
- ✅ Pod anti-affinity for node distribution
- ✅ Automatic partition healing
- ✅ Data replication across all nodes

Access Management UI:
kubectl port-forward svc/$RABBITMQ_SERVICE -n $NAMESPACE 15672:15672
Then open http://localhost:15672

Monitoring Commands:
# Check cluster status
kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl cluster_status

# Check all pods
kubectl get pods -n $NAMESPACE -l app.kubernetes.io/name=rabbitmq

# Check queues
kubectl exec -n $NAMESPACE $FIRST_POD -- rabbitmqctl list_queues name type messages

Creating Quorum Queues (Application Code):
------------------------------------------
Python (pika):
  channel.queue_declare(
      queue='my-queue',
      durable=True,
      arguments={'x-queue-type': 'quorum'}
  )

Node.js (amqplib):
  channel.assertQueue('my-queue', {
      durable: true,
      arguments: {'x-queue-type': 'quorum'}
  });

Go (amqp091-go):
  ch.QueueDeclare(
      "my-queue",
      true,  // durable
      false, // autoDelete
      false, // exclusive
      false, // noWait
      amqp.Table{"x-queue-type": "quorum"},
  )

Note: With default_queue_type = quorum in config, new queues
will automatically be quorum queues unless specified otherwise.

Operator Info:
- Uses official RabbitMQ Docker images (rabbitmq:3.13-management)
- Managed by RabbitMQ Cluster Operator
- Production-ready and officially supported
- Quorum queues provide automatic replication and HA
EOF

echo ""
echo "========================================="
echo "✅ RabbitMQ HA Cluster installed successfully!"
echo "========================================="
echo ""
echo "Cluster: $REPLICAS nodes"
echo "AMQP URL: $RABBITMQ_URL"
echo "Management: http://localhost:15672 (after port-forward)"
echo ""
echo "📋 Important: Quorum queues are enabled by default for true HA"
echo "   All new queues will be replicated across cluster nodes"
echo ""
echo "Credentials and cluster info saved to: rabbitmq-info.txt"
echo ""
echo "To cleanup: NAMESPACE=$NAMESPACE ./install.sh -d"
