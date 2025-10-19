#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

echo "Initializing Vault..."

# Wait for Vault pod
echo "Waiting for Vault pod to be running..."
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
    echo "To unseal, run these commands:"
    KEY1=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-1}' | base64 -d)
    KEY2=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-2}' | base64 -d)
    KEY3=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-3}' | base64 -d)

    echo "Unsealing Vault..."
    kubectl exec -n vault $VAULT_POD -- vault operator unseal "$KEY1" || true
    kubectl exec -n vault $VAULT_POD -- vault operator unseal "$KEY2" || true
    kubectl exec -n vault $VAULT_POD -- vault operator unseal "$KEY3" || true

    echo ""
    echo "✅ Vault unsealed!"
    echo "Root Token: $ROOT_TOKEN"
    exit 0
fi

# Initialize Vault
echo "Initializing Vault (this creates unseal keys and root token)..."

# Initialize and save output to file
INIT_FILE="/tmp/vault-init-$$.json"
kubectl exec -n vault $VAULT_POD -- vault operator init -format=json > "$INIT_FILE" 2>&1 || {
    echo "❌ Failed to initialize Vault"
    cat "$INIT_FILE"
    rm -f "$INIT_FILE"
    exit 1
}

echo "Parsing initialization output..."

# Extract keys and token using grep/sed (works without jq)
UNSEAL_KEY_1=$(grep -o '"unseal_keys_b64":\[[^]]*\]' "$INIT_FILE" | sed 's/.*"\([^"]*\)".*/\1/' | sed -n '1p')
UNSEAL_KEY_2=$(grep -o '"unseal_keys_b64":\[[^]]*\]' "$INIT_FILE" | grep -o '"[^"]*"' | sed 's/"//g' | sed -n '2p')
UNSEAL_KEY_3=$(grep -o '"unseal_keys_b64":\[[^]]*\]' "$INIT_FILE" | grep -o '"[^"]*"' | sed 's/"//g' | sed -n '3p')
UNSEAL_KEY_4=$(grep -o '"unseal_keys_b64":\[[^]]*\]' "$INIT_FILE" | grep -o '"[^"]*"' | sed 's/"//g' | sed -n '4p')
UNSEAL_KEY_5=$(grep -o '"unseal_keys_b64":\[[^]]*\]' "$INIT_FILE" | grep -o '"[^"]*"' | sed 's/"//g' | sed -n '5p')
ROOT_TOKEN=$(grep -o '"root_token":"[^"]*"' "$INIT_FILE" | cut -d'"' -f4)

# Remove temp file
rm -f "$INIT_FILE"

# Validate we got the keys
if [ -z "$UNSEAL_KEY_1" ] || [ -z "$ROOT_TOKEN" ]; then
    echo "❌ Failed to parse initialization output"
    exit 1
fi

echo "Keys extracted successfully"

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
echo "✅ Vault initialized and unsealed successfully!"
echo ""
echo "Root Token: $ROOT_TOKEN"
echo ""
echo "Credentials saved to: vault-credentials.txt"
echo ""
echo "Check status:"
echo "  kubectl exec -n vault $VAULT_POD -- vault status"
