#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

echo "Initializing Vault..."

# Wait for Vault pod
echo "Waiting for Vault pod to be running..."
# Don't wait for 'ready' - Vault won't be ready until initialized/unsealed
sleep 5
until kubectl get pod -n vault -l app.kubernetes.io/name=vault 2>/dev/null | grep -q "Running\|0/"; do
  echo "Waiting for Vault pod..."
  sleep 5
done
echo "Vault pod found"

VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

# Check if already initialized
if kubectl get secret vault-unseal-keys -n vault &>/dev/null; then
    echo "Vault already initialized. Unseal keys found in secret."
    ROOT_TOKEN=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.root-token}' | base64 -d)
    echo ""
    echo "Root Token: $ROOT_TOKEN"
    echo ""
    echo "To unseal manually:"
    echo "  kubectl exec -n vault $VAULT_POD -- vault operator unseal"
    exit 0
fi

# Initialize Vault
echo "Initializing Vault (this creates unseal keys and root token)..."
INIT_OUTPUT=$(kubectl exec -n vault $VAULT_POD -- vault operator init -format=json)

# Parse the output
UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | grep -o '"unseal_keys_b64":\["[^"]*"' | cut -d'"' -f4)
UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | grep -o '"unseal_keys_b64":\["[^"]*","[^"]*"' | cut -d'"' -f6)
UNSEAL_KEY_3=$(echo "$INIT_OUTPUT" | grep -o '"unseal_keys_b64":\["[^"]*","[^"]*","[^"]*"' | cut -d'"' -f8)
UNSEAL_KEY_4=$(echo "$INIT_OUTPUT" | grep -o '"unseal_keys_b64":\["[^"]*","[^"]*","[^"]*","[^"]*"' | cut -d'"' -f10)
UNSEAL_KEY_5=$(echo "$INIT_OUTPUT" | grep -o '"unseal_keys_b64":\["[^"]*","[^"]*","[^"]*","[^"]*","[^"]*"' | cut -d'"' -f12)
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | grep -o '"root_token":"[^"]*"' | cut -d'"' -f4)

# Store in Kubernetes secret
echo "Storing unseal keys in Kubernetes secret..."
kubectl create secret generic vault-unseal-keys -n vault \
    --from-literal=unseal-key-1="$UNSEAL_KEY_1" \
    --from-literal=unseal-key-2="$UNSEAL_KEY_2" \
    --from-literal=unseal-key-3="$UNSEAL_KEY_3" \
    --from-literal=unseal-key-4="$UNSEAL_KEY_4" \
    --from-literal=unseal-key-5="$UNSEAL_KEY_5" \
    --from-literal=root-token="$ROOT_TOKEN"

# Initial unseal
echo "Performing initial unseal..."
kubectl exec -n vault $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_1"
kubectl exec -n vault $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_2"
kubectl exec -n vault $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_3"

# Save to local file
cat > vault-credentials.txt <<EOF
Vault Initialization Complete
==============================

Root Token: $ROOT_TOKEN

Unseal Keys (5 total, need 3 to unseal):
1. $UNSEAL_KEY_1
2. $UNSEAL_KEY_2
3. $UNSEAL_KEY_3
4. $UNSEAL_KEY_4
5. $UNSEAL_KEY_5

IMPORTANT: Keep these credentials safe!
The keys are also stored in Kubernetes secret: vault-unseal-keys

Auto-unseal is configured via CronJob.
Vault will automatically unseal if it gets sealed.

Access Vault:
- Port-forward: kubectl port-forward -n vault $VAULT_POD 8200:8200
- Ingress: Apply manifests/ingress.yaml for https://vault.bareuptime.co

Login to Vault:
export VAULT_ADDR=http://localhost:8200
vault login $ROOT_TOKEN
EOF

echo ""
echo "✅ Vault initialized successfully!"
echo ""
echo "Root Token: $ROOT_TOKEN"
echo ""
echo "Credentials saved to: vault-credentials.txt"
echo ""
echo "Auto-unseal CronJob will keep Vault unsealed automatically."
echo "To deploy auto-unseal: kubectl apply -f manifests/auto-unseal.yaml"
