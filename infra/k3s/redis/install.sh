#!/bin/bash
set -euo pipefail

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
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install Redis
helm upgrade --install redis bitnami/redis \
  --namespace $NAMESPACE \
  --set auth.enabled=true \
  --set auth.username=$REDIS_USER \
  --set auth.password=$REDIS_PASS \
  --set master.persistence.size=5Gi \
  --set replica.replicaCount=1 \
  --set replica.persistence.size=5Gi

echo "Waiting for Redis to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=redis --namespace $NAMESPACE --timeout=300s

# Connection info
REDIS_URL="redis://$REDIS_USER:$REDIS_PASS@redis-master.$NAMESPACE.svc.cluster.local:6379"

echo ""
echo "Redis installed successfully!"
echo ""
echo "Connection info:"
echo "  URL: $REDIS_URL"
echo "  Host: redis-master.$NAMESPACE.svc.cluster.local"
echo "  Port: 6379"
echo "  Username: $REDIS_USER"
echo "  Password: $REDIS_PASS"
echo ""
echo "Test connection:"
echo "  kubectl run redis-client --rm -it --restart=Never --image=redis:alpine --namespace $NAMESPACE -- redis-cli -h redis-master -a $REDIS_PASS"

# Save connection info
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

Test:
kubectl run redis-client --rm -it --restart=Never --image=redis:alpine --namespace $NAMESPACE -- redis-cli -h redis-master -a $REDIS_PASS
EOF

echo "Connection info saved to redis-info.txt"
