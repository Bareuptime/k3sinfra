#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up Vault installation..."

    # Delete ingress and auto-unseal
    kubectl delete -f manifests/ingress.yaml 2>/dev/null || true
    kubectl delete -f manifests/auto-unseal.yaml 2>/dev/null || true

    # Delete Vault secrets
    kubectl delete secret vault-unseal-keys -n vault 2>/dev/null || true

    # Uninstall Vault
    helm uninstall vault -n vault 2>/dev/null || true

    # Delete PVC
    kubectl delete pvc data-vault-0 -n vault 2>/dev/null || true

    # Delete namespace
    kubectl delete namespace vault 2>/dev/null || true

    # Clean local files
    rm -f vault-credentials.txt vault-info.txt

    echo "✅ Vault cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing Vault in K3s..."

# Add HashiCorp Helm repo
helm repo add hashicorp https://helm.releases.hashicorp.com 2>/dev/null || true
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

echo "Waiting for Vault pod to start..."
sleep 10
until kubectl get pod -n vault -l app.kubernetes.io/name=vault 2>/dev/null | grep -q "Running\|0/"; do
  echo "Waiting for Vault pod..."
  sleep 5
done

echo ""
echo "========================================="
echo "✅ Vault installed successfully!"
echo "========================================="
echo ""
echo "Next steps:"
echo ""
echo "1. Initialize Vault:"
echo "   ./init-vault.sh"
echo ""
echo "2. Enable auto-unseal:"
echo "   kubectl apply -f manifests/auto-unseal.yaml"
echo ""
echo "3. Apply ingress:"
echo "   kubectl apply -f manifests/ingress.yaml"
echo ""
echo "To cleanup: ./install.sh -d"
