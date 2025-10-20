#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up RabbitMQ installation..."

    # Uninstall RabbitMQ
    helm uninstall rabbitmq -n ${NAMESPACE:-default} 2>/dev/null || true

    # Delete PVCs
    kubectl delete pvc -n ${NAMESPACE:-default} -l app.kubernetes.io/name=rabbitmq 2>/dev/null || true

    # Clean local files
    rm -f rabbitmq-info.txt

    echo "✅ RabbitMQ cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing RabbitMQ in K3s..."

# Prompt for configuration
read -p "Enter namespace [default]: " NAMESPACE
NAMESPACE=${NAMESPACE:-default}

read -p "Enter RabbitMQ username [admin]: " RABBITMQ_USER
RABBITMQ_USER=${RABBITMQ_USER:-admin}

read -sp "Enter RabbitMQ password: " RABBITMQ_PASS
echo

if [[ -z "$RABBITMQ_PASS" ]]; then
  echo "Password cannot be empty"
  exit 1
fi

# Add Bitnami repo
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update

# Create namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install RabbitMQ
# Using bitnamilegacy repository due to Bitnami catalog changes (Aug 2025)
helm upgrade --install rabbitmq bitnami/rabbitmq \
  --namespace $NAMESPACE \
  --set auth.username=$RABBITMQ_USER \
  --set auth.password=$RABBITMQ_PASS \
  --set persistence.size=8Gi \
  --set replicaCount=1 \
  --set image.registry=docker.io \
  --set image.repository=bitnamilegacy/rabbitmq \
  --set image.tag=3.13.7-debian-12-r7 \
  --set global.security.allowInsecureImages=true \
  --set resources.requests.memory=256Mi \
  --set resources.limits.memory=512Mi

echo "Waiting for RabbitMQ to be ready..."
kubectl wait --for=condition=available statefulset/rabbitmq -n $NAMESPACE --timeout=300s 2>/dev/null || true

# Connection info
RABBITMQ_URL="amqp://$RABBITMQ_USER:$RABBITMQ_PASS@rabbitmq.$NAMESPACE.svc.cluster.local:5672"
RABBITMQ_MGMT_URL="http://rabbitmq.$NAMESPACE.svc.cluster.local:15672"

# Save credentials
cat > rabbitmq-info.txt <<EOF
RabbitMQ Installation Info
==========================
Namespace: $NAMESPACE
Username: $RABBITMQ_USER
Password: $RABBITMQ_PASS

Connection:
AMQP URL: $RABBITMQ_URL
Management URL: $RABBITMQ_MGMT_URL

Ports:
- AMQP: 5672
- Management: 15672

Access Management UI:
kubectl port-forward svc/rabbitmq -n $NAMESPACE 15672:15672
Then open http://localhost:15672
EOF

echo ""
echo "========================================="
echo "✅ RabbitMQ installed successfully!"
echo "========================================="
echo ""
echo "AMQP URL: $RABBITMQ_URL"
echo "Management: http://localhost:15672 (after port-forward)"
echo ""
echo "Credentials saved to: rabbitmq-info.txt"
echo ""
echo "To cleanup: NAMESPACE=$NAMESPACE ./install.sh -d"
