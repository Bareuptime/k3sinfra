#!/bin/bash
set -euo pipefail

# Vault Secrets Webhook Installation Script
# This installs Bank-Vaults (Banzai Cloud) webhook for injecting Vault secrets into pods

echo "🔐 Installing Vault Secrets Webhook..."

# Configuration
NAMESPACE="${NAMESPACE:-vault}"
VAULT_ADDR="${VAULT_ADDR:-http://vault.vault.svc.cluster.local:8200}"
VAULT_ROLE="${VAULT_ROLE:-default}"

# Check if kubectl is configured
if ! kubectl cluster-info &>/dev/null; then
    echo "❌ kubectl is not configured properly"
    exit 1
fi

# Add Banzai Cloud Helm repository
echo "📦 Adding Banzai Cloud Helm repository..."
helm repo add banzaicloud-stable https://kubernetes-charts.banzaicloud.com 2>/dev/null || true
helm repo update

# Install Vault Secrets Webhook
echo "🚀 Installing Vault Secrets Webhook..."
helm upgrade --install vault-secrets-webhook banzaicloud-stable/vault-secrets-webhook \
  --namespace ${NAMESPACE} \
  --create-namespace \
  --set image.tag=latest \
  --set env.VAULT_ADDR="${VAULT_ADDR}" \
  --set env.VAULT_SKIP_VERIFY="true" \
  --set configMapMutation=true \
  --set secretInit.tag=latest \
  --set env.VAULT_ROLE="${VAULT_ROLE}" \
  --wait

# Verify installation
echo ""
echo "✅ Verifying installation..."
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=vault-secrets-webhook

echo ""
echo "========================================="
echo "✅ Vault Secrets Webhook installed!"
echo "========================================="
echo ""
echo "Configuration:"
echo "  Namespace: ${NAMESPACE}"
echo "  Vault Address: ${VAULT_ADDR}"
echo "  Default Role: ${VAULT_ROLE}"
echo ""
echo "Usage in pod annotations:"
echo "  vault.security.banzaicloud.io/vault-addr: \"${VAULT_ADDR}\""
echo "  vault.security.banzaicloud.io/vault-role: \"${VAULT_ROLE}\""
echo "  vault.security.banzaicloud.io/vault-skip-verify: \"true\""
echo ""
echo "Environment variables:"
echo "  - name: MY_SECRET"
echo "    value: vault:secret/data/path#KEY"
echo ""
