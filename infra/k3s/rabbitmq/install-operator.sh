#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up RabbitMQ Operator installation..."

    # Delete RabbitMQ cluster
    kubectl delete rabbitmqcluster rabbitmq -n $NAMESPACE 2>/dev/null || true

    # Delete operator
    kubectl delete -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml 2>/dev/null || true

    # Clean local files
    rm -f rabbitmq-info.txt rabbitmq-cluster.yaml

    echo "✅ RabbitMQ Operator cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing RabbitMQ using Official Operator..."

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

# Create namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install RabbitMQ Cluster Operator
echo "Installing RabbitMQ Cluster Operator..."
kubectl apply -f https://github.com/rabbitmq/cluster-operator/releases/latest/download/cluster-operator.yml

echo "Waiting for operator to be ready..."
kubectl wait --for=condition=available deployment/rabbitmq-cluster-operator -n rabbitmq-system --timeout=300s

# Create RabbitMQ cluster manifest
cat > rabbitmq-cluster.yaml <<EOF
apiVersion: rabbitmq.com/v1beta1
kind: RabbitmqCluster
metadata:
  name: rabbitmq
  namespace: $NAMESPACE
spec:
  replicas: 1
  image: rabbitmq:3.13-management
  resources:
    requests:
      cpu: 250m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi
  rabbitmq:
    additionalConfig: |
      default_user = $RABBITMQ_USER
      default_pass = $RABBITMQ_PASS
  persistence:
    storageClassName: local-path
    storage: 8Gi
EOF

echo "Deploying RabbitMQ cluster..."
kubectl apply -f rabbitmq-cluster.yaml

echo "Waiting for RabbitMQ cluster to be ready..."
sleep 20
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq -n $NAMESPACE --timeout=300s

# Get service info
RABBITMQ_SERVICE=$(kubectl get service rabbitmq -n $NAMESPACE -o jsonpath='{.metadata.name}')
RABBITMQ_URL="amqp://$RABBITMQ_USER:$RABBITMQ_PASS@$RABBITMQ_SERVICE.$NAMESPACE.svc.cluster.local:5672"
RABBITMQ_MGMT_URL="http://$RABBITMQ_SERVICE.$NAMESPACE.svc.cluster.local:15672"

# Save credentials
cat > rabbitmq-info.txt <<EOF
RabbitMQ Operator Installation Info
====================================
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
kubectl port-forward svc/$RABBITMQ_SERVICE -n $NAMESPACE 15672:15672
Then open http://localhost:15672

Operator Info:
- Uses official RabbitMQ Docker images
- Managed by RabbitMQ Cluster Operator
- Production-ready and officially supported
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
echo "To cleanup: NAMESPACE=$NAMESPACE ./install-operator.sh -d"
