#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up Redis Operator installation..."

    # Delete Redis replication
    kubectl delete redisreplication redis -n $NAMESPACE 2>/dev/null || true
    kubectl delete redissentinel redis-sentinel -n $NAMESPACE 2>/dev/null || true

    # Delete operator
    kubectl delete -f https://raw.githubusercontent.com/OT-CONTAINER-KIT/redis-operator/master/config/crd/bases/redis.redis.opstreelabs.in_redis.yaml 2>/dev/null || true
    kubectl delete -f https://raw.githubusercontent.com/OT-CONTAINER-KIT/redis-operator/master/config/crd/bases/redis.redis.opstreelabs.in_redisreplications.yaml 2>/dev/null || true
    kubectl delete -f https://raw.githubusercontent.com/OT-CONTAINER-KIT/redis-operator/master/config/crd/bases/redis.redis.opstreelabs.in_redissentinels.yaml 2>/dev/null || true
    helm uninstall redis-operator -n redis-operator 2>/dev/null || true
    kubectl delete namespace redis-operator 2>/dev/null || true

    # Clean local files
    rm -f redis-info.txt redis-replication.yaml redis-sentinel.yaml

    echo "✅ Redis Operator cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing Redis with Sentinel using OT-Container-Kit Operator..."

# Prompt for configuration
read -p "Enter namespace [common]: " NAMESPACE
NAMESPACE=${NAMESPACE:-common}

read -p "Enter Redis password: " REDIS_PASS

if [[ -z "$REDIS_PASS" ]]; then
  echo "Password cannot be empty"
  exit 1
fi

# Create namespaces
kubectl create namespace redis-operator --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install Redis Operator
echo "Installing Redis Operator..."
helm repo add ot-helm https://ot-container-kit.github.io/helm-charts/ 2>/dev/null || true
helm repo update

helm upgrade --install redis-operator ot-helm/redis-operator \
  --namespace redis-operator \
  --create-namespace

echo "Waiting for operator to be ready..."
kubectl wait --for=condition=available deployment/redis-operator -n redis-operator --timeout=300s

# Create Redis password secret
echo "Creating Redis password secret..."
kubectl create secret generic redis-secret \
  --from-literal=password=$REDIS_PASS \
  --namespace $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

# Create Redis Replication (Master-Replica setup)
cat > redis-replication.yaml <<EOF
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisReplication
metadata:
  name: redis
  namespace: $NAMESPACE
spec:
  clusterSize: 3
  podSecurityContext:
    runAsUser: 1000
    fsGroup: 1000
  kubernetesConfig:
    image: redis:7.4.1
    imagePullPolicy: IfNotPresent
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
  storage:
    volumeClaimTemplate:
      spec:
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 1Gi
        storageClassName: local-path
  redisConfig:
    additionalRedisConfig: redis-external-config
  redisExporter:
    enabled: false
EOF

# Create Redis Sentinel
cat > redis-sentinel.yaml <<EOF
apiVersion: redis.redis.opstreelabs.in/v1beta2
kind: RedisSentinel
metadata:
  name: redis-sentinel
  namespace: $NAMESPACE
spec:
  clusterSize: 3
  podSecurityContext:
    runAsUser: 1000
    fsGroup: 1000
  kubernetesConfig:
    image: redis:7.4.1
    imagePullPolicy: IfNotPresent
    resources:
      requests:
        cpu: 100m
        memory: 128Mi
      limits:
        cpu: 500m
        memory: 512Mi
  redisReplication:
    name: redis
EOF

# Create Redis config
kubectl create configmap redis-external-config \
  --from-literal=redis.conf="requirepass $REDIS_PASS
masterauth $REDIS_PASS" \
  --namespace $NAMESPACE \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Deploying Redis Replication..."
kubectl apply -f redis-replication.yaml

echo "Waiting for Redis master and replicas to be ready..."
sleep 20
kubectl wait --for=condition=ready pod -l role=master -n $NAMESPACE --timeout=300s || true
kubectl wait --for=condition=ready pod -l role=replica -n $NAMESPACE --timeout=300s || true

echo "Deploying Redis Sentinel..."
kubectl apply -f redis-sentinel.yaml

echo "Waiting for Sentinel to be ready..."
sleep 15
kubectl wait --for=condition=ready pod -l role=sentinel -n $NAMESPACE --timeout=300s || true

# Get service info
REDIS_SERVICE="redis-$NAMESPACE"
SENTINEL_SERVICE="redis-sentinel-$NAMESPACE"
REDIS_URL="redis://:$REDIS_PASS@$REDIS_SERVICE.$NAMESPACE.svc.cluster.local:6379"

# Save credentials
cat > redis-info.txt <<EOF
Redis Operator Installation Info (with Sentinel HA)
====================================================
Namespace: $NAMESPACE
Password: $REDIS_PASS

Architecture:
- 3x Redis instances (1 master + 2 replicas)
- 3x Sentinel instances for automatic failover
- Official Redis images (redis:7.4.1)

Connection:
Primary URL: $REDIS_URL
Master Service: $REDIS_SERVICE.$NAMESPACE.svc.cluster.local:6379
Sentinel Service: $SENTINEL_SERVICE.$NAMESPACE.svc.cluster.local:26379

Environment Variables for App:
REDIS_HOST=$REDIS_SERVICE.$NAMESPACE.svc.cluster.local
REDIS_PORT=6379
REDIS_PASSWORD=$REDIS_PASS
REDIS_SENTINEL_HOSTS=$SENTINEL_SERVICE.$NAMESPACE.svc.cluster.local:26379
REDIS_SENTINEL_MASTER=mymaster

Features:
- Automatic failover with Sentinel
- Data persistence enabled
- 3-node high availability setup
- Official Redis Docker images
- Managed by OT-Container-Kit Redis Operator

Test Connection:
kubectl run redis-client --rm -it --restart=Never --image=redis:7.4.1 -n $NAMESPACE -- redis-cli -h $REDIS_SERVICE -a $REDIS_PASS ping

Check Sentinel Status:
kubectl run redis-client --rm -it --restart=Never --image=redis:7.4.1 -n $NAMESPACE -- redis-cli -h $SENTINEL_SERVICE -p 26379 sentinel masters
EOF

echo ""
echo "========================================="
echo "✅ Redis with Sentinel installed successfully!"
echo "========================================="
echo ""
echo "Architecture: 1 Master + 2 Replicas + 3 Sentinels"
echo "Connection: $REDIS_URL"
echo ""
echo "Credentials saved to: redis-info.txt"
echo ""
echo "To cleanup: NAMESPACE=$NAMESPACE ./install-operator.sh -d"
