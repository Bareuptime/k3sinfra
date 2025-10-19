#!/bin/bash
set -euo pipefail

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
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Create namespace
kubectl create namespace $NAMESPACE --dry-run=client -o yaml | kubectl apply -f -

# Install RabbitMQ
helm upgrade --install rabbitmq bitnami/rabbitmq \
  --namespace $NAMESPACE \
  --set auth.username=$RABBITMQ_USER \
  --set auth.password=$RABBITMQ_PASS \
  --set persistence.size=8Gi \
  --set replicaCount=1

echo "Waiting for RabbitMQ to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=rabbitmq --namespace $NAMESPACE --timeout=300s

# Connection info
RABBITMQ_URL="amqp://$RABBITMQ_USER:$RABBITMQ_PASS@rabbitmq.$NAMESPACE.svc.cluster.local:5672"
RABBITMQ_MGMT_URL="http://rabbitmq.$NAMESPACE.svc.cluster.local:15672"

echo ""
echo "RabbitMQ installed successfully!"
echo ""
echo "Connection info:"
echo "  AMQP URL: $RABBITMQ_URL"
echo "  Management URL: $RABBITMQ_MGMT_URL"
echo "  Username: $RABBITMQ_USER"
echo "  Password: $RABBITMQ_PASS"
echo ""
echo "Access Management UI:"
echo "  kubectl port-forward svc/rabbitmq -n $NAMESPACE 15672:15672"
echo "  Open http://localhost:15672"

# Save connection info
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

echo "Connection info saved to rabbitmq-info.txt"
