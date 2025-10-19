#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "Using K3s kubeconfig: $KUBECONFIG"
fi

echo "Installing Vault in K3s..."

# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create namespace
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -

# Install Vault
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --set "server.ha.enabled=false" \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=10Gi" \
  --set "server.dataStorage.storageClass=local-path" \
  --set "ui.enabled=true" \
  --set "injector.enabled=false"

echo "Waiting for Vault pod to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault --namespace vault --timeout=300s

echo "Vault installed successfully!"
echo ""
echo "========================================="
echo "Next steps:"
echo "========================================="
echo ""
echo "1. Initialize Vault with auto-unseal (RECOMMENDED):"
echo "   ./init-vault.sh"
echo "   This will:"
echo "   - Initialize Vault"
echo "   - Store unseal keys in Kubernetes secret"
echo "   - Perform initial unseal"
echo "   - Save credentials to vault-credentials.txt"
echo ""
echo "2. Enable auto-unseal CronJob:"
echo "   kubectl apply -f manifests/auto-unseal.yaml"
echo "   This will automatically unseal Vault if it gets sealed"
echo ""
echo "3. Apply ingress (optional):"
echo "   kubectl apply -f manifests/ingress.yaml"
echo "   Access at: https://vault.bareuptime.co"
echo ""
echo "OR Manual initialization:"
echo "   kubectl exec -it vault-0 -n vault -- vault operator init"
echo "   kubectl exec -it vault-0 -n vault -- vault operator unseal"
echo ""
echo "========================================="
