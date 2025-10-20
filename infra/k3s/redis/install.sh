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

echo "Installing Redis in K3s..."

# Prompt for configuration
read -p "Enter namespace [default]: " NAMESPACE
NAMESPACE=${NAMESPACE:-default}

read -p "Enter Redis username [admin]: " REDIS_USER
REDIS_USER=${REDIS_USER:-admin}

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

# Install Redis
# Note: Add legacy image support if needed in future
helm upgrade --install redis bitnami/redis \
  --namespace $NAMESPACE \
  --set auth.enabled=true \
  --set auth.username=$REDIS_USER \
  --set auth.password=$REDIS_PASS \
  --set master.persistence.size=1Gi \
  --set replica.replicaCount=1 \
  --set replica.persistence.size=1Gi \
  --set global.security.allowInsecureImages=true

echo "Waiting for Redis to be ready..."
kubectl wait --for=condition=available statefulset/redis-master -n $NAMESPACE --timeout=300s 2>/dev/null || true

# Connection info
REDIS_URL="redis://$REDIS_USER:$REDIS_PASS@redis-master.$NAMESPACE.svc.cluster.local:6379"

# Save credentials
cat > redis-info.txt <<EOF
Redis Installation Info
=======================
Namespace: $NAMESPACE
Username: $REDIS_USER
Password: $REDIS_PASS

Connection:
URL: $REDIS_URL
Host: redis-master.$NAMESPACE.svc.cluster.local
Port: 6379
EOF

echo ""
echo "========================================="
echo "✅ Redis installed successfully!"
echo "========================================="
echo ""
echo "Connection URL: $REDIS_URL"
echo ""
echo "Credentials saved to: redis-info.txt"
echo ""
echo "To cleanup: NAMESPACE=$NAMESPACE ./install.sh -d"
