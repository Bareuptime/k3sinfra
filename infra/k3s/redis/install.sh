#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up Redis installation..."

    # Uninstall Redis
    helm uninstall redis -n ${NAMESPACE:-default} 2>/dev/null || true

    # Delete PVCs
    kubectl delete pvc -n ${NAMESPACE:-default} -l app.kubernetes.io/name=redis 2>/dev/null || true

    # Clean local files
    rm -f redis-info.txt

    echo "✅ Redis cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing Redis with Sentinel (Bitnami Legacy)..."

# Prompt for configuration
read -p "Enter namespace [default]: " NAMESPACE
NAMESPACE=${NAMESPACE:-default}

read -sp "Enter Redis password: " REDIS_PASS
echo

if [[ -z "$REDIS_PASS" ]]; then
  echo "Password cannot be empty"
  exit 1
fi

# Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# Create namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install Redis with Sentinel
# Using bitnamilegacy repository due to Bitnami catalog changes (Aug 2025)
helm upgrade --install redis bitnami/redis \
  --namespace $NAMESPACE \
  --set auth.enabled=true \
  --set auth.password=$REDIS_PASS \
  --set architecture=replication \
  --set sentinel.enabled=true \
  --set sentinel.quorum=2 \
  --set master.count=1 \
  --set replica.replicaCount=2 \
  --set master.persistence.size=1Gi \
  --set replica.persistence.size=1Gi \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/redis \
  --set image.tag=7.4.2-debian-12-r0 \
  --set sentinel.image.registry=docker.io \
  --set sentinel.image.repository=bitnamilegacy/redis-sentinel \
  --set sentinel.image.tag=7.4.2-debian-12-r0 \
  --set global.security.allowInsecureImages=true \
  --set master.resources.requests.memory=128Mi \
  --set master.resources.limits.memory=512Mi \
  --set replica.resources.requests.memory=128Mi \
  --set replica.resources.limits.memory=512Mi

echo "Waiting for Redis to be ready..."
kubectl wait --for=condition=available statefulset/redis-master -n $NAMESPACE --timeout=300s 2>/dev/null || true
kubectl wait --for=condition=available statefulset/redis-replicas -n $NAMESPACE --timeout=300s 2>/dev/null || true

# Connection info
REDIS_MASTER_SERVICE="redis-master.$NAMESPACE.svc.cluster.local"
REDIS_SENTINEL_SERVICE="redis-sentinel.$NAMESPACE.svc.cluster.local"
REDIS_URL="redis://:$REDIS_PASS@$REDIS_MASTER_SERVICE:6379"

# Save credentials
cat > redis-info.txt <<EOF
Redis Installation Info (Bitnami with Sentinel HA)
===================================================
Namespace: $NAMESPACE
Password: $REDIS_PASS

Architecture:
- 1x Master + 2x Replicas
- 3x Sentinel instances for automatic failover
- Using bitnamilegacy images (no security updates)

Connection:
URL: $REDIS_URL
Master: $REDIS_MASTER_SERVICE:6379
Sentinel: $REDIS_SENTINEL_SERVICE:26379

Environment Variables for App:
REDIS_MASTER_HOST=$REDIS_MASTER_SERVICE
REDIS_MASTER_PORT=6379
REDIS_PASSWORD=$REDIS_PASS
REDIS_SENTINEL_HOSTS=$REDIS_SENTINEL_SERVICE:26379
REDIS_SENTINEL_MASTER=mymaster

Features:
✅ High Availability with Sentinel
✅ Automatic master failover
✅ 1 Master + 2 Replicas

Limitations:
⚠️ Using bitnamilegacy repository
⚠️ No security updates
⚠️ Consider migrating to operator version

Test:
kubectl run redis-client --rm -it --restart=Never --image=redis:alpine -n $NAMESPACE -- redis-cli -h $REDIS_MASTER_SERVICE -a $REDIS_PASS ping
EOF

echo ""
echo "========================================="
echo "✅ Redis with Sentinel installed successfully!"
echo "========================================="
echo ""
echo "Connection URL: $REDIS_URL"
echo ""
echo "Credentials saved to: redis-info.txt"
echo ""
echo "⚠️  Note: Using Bitnami Legacy images (no security updates)"
echo "   Consider using: ./install-operator.sh for production"
echo ""
echo "To cleanup: NAMESPACE=$NAMESPACE ./install.sh -d"
