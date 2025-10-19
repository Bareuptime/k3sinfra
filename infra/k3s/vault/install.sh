#!/bin/bash
set -euo pipefail

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
echo "Next steps:"
echo "1. Initialize Vault:"
echo "   kubectl exec -it vault-0 -n vault -- vault operator init"
echo ""
echo "2. Save the unseal keys and root token!"
echo ""
echo "3. Unseal Vault (use 3 of 5 keys):"
echo "   kubectl exec -it vault-0 -n vault -- vault operator unseal"
echo ""
echo "4. Check status:"
echo "   kubectl exec -it vault-0 -n vault -- vault status"
echo ""
echo "5. Port-forward to access UI:"
echo "   kubectl port-forward -n vault vault-0 8200:8200"
echo "   Open http://localhost:8200"
