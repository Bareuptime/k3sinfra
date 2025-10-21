#!/bin/bash
set -euo pipefail

# Installation script for Kubernetes prerequisites for bareuptime-backend
# Run this before deploying the backend application

echo "🚀 Installing prerequisites for bareuptime-backend..."

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# 1. Install External Secrets Operator
echo ""
echo "📦 Installing External Secrets Operator..."
if ! kubectl get namespace external-secrets-system &>/dev/null; then
    helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
    helm repo update

    helm install external-secrets \
      external-secrets/external-secrets \
      -n external-secrets-system \
      --create-namespace \
      --set installCRDs=true \
      --wait

    echo "✅ External Secrets Operator installed"
else
    echo "✅ External Secrets Operator already installed"
fi

# 2. Verify cert-manager
echo ""
echo "📜 Verifying cert-manager..."
if kubectl get namespace cert-manager &>/dev/null; then
    echo "✅ cert-manager is installed"
else
    echo "❌ cert-manager not found. Install it first:"
    echo "   cd infra/k3s/cert-manager && ./install.sh"
    exit 1
fi

# 3. Verify Vault
echo ""
echo "🔒 Verifying Vault..."
if kubectl get namespace vault &>/dev/null; then
    echo "✅ Vault is installed"

    # Check if Vault is unsealed
    if kubectl exec -n vault vault-0 -- vault status &>/dev/null; then
        echo "✅ Vault is unsealed"
    else
        echo "⚠️  Vault may be sealed. Check with: kubectl exec -n vault vault-0 -- vault status"
    fi
else
    echo "❌ Vault not found. Install it first:"
    echo "   cd infra/k3s/vault && ./install.sh"
    exit 1
fi

# 4. Configure Vault Kubernetes Auth
echo ""
echo "🔧 Configuring Vault Kubernetes authentication..."
echo ""
echo "Please run these commands to configure Vault:"
echo ""
cat <<'EOF'
# Port-forward to Vault
kubectl port-forward -n vault vault-0 8200:8200 & VAULT_PF_PID=$!
sleep 2

# Configure Vault
export VAULT_ADDR=http://localhost:8200
vault login <your-root-token>

# Enable Kubernetes auth
vault auth enable kubernetes 2>/dev/null || echo "Kubernetes auth already enabled"

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create policy
vault policy write bareuptime-backend - <<POLICY
path "secret/data/bareuptime/database" {
  capabilities = ["read"]
}
path "secret/data/shared/redis" {
  capabilities = ["read"]
}
path "secret/data/bareuptime/auth" {
  capabilities = ["read"]
}
path "secret/data/bareuptime/config" {
  capabilities = ["read"]
}
path "secret/data/bareuptime/google-service-account" {
  capabilities = ["read"]
}
path "secret/data/shared/clickhouse" {
  capabilities = ["read"]
}
path "secret/data/shared/ghcr" {
  capabilities = ["read"]
}
POLICY

# Create Kubernetes role
vault write auth/kubernetes/role/bareuptime-backend \
  bound_service_account_names=bareuptime-backend \
  bound_service_account_namespaces=bareuptime-backend \
  policies=bareuptime-backend \
  ttl=24h

# Stop port-forward
kill $VAULT_PF_PID
EOF

echo ""
echo "========================================="
echo "✅ Prerequisites installation complete!"
echo "========================================="
echo ""
echo "Next steps:"
echo "1. Configure Vault (see commands above)"
echo "2. Add GHCR credentials to Vault:"
echo "   vault kv put secret/shared/ghcr username=<github-username> password=<github-token>"
echo "3. Deploy the application:"
echo "   kubectl apply -f apps/bareuptime-backend/argocd-application.yaml"
echo ""
