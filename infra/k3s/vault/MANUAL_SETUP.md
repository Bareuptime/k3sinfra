# Vault Manual Setup Guide

This guide walks you through setting up HashiCorp Vault in K3s step-by-step, with explanations for each stage. While scripts are provided for convenience, this guide ensures you understand what's happening at each step.

## Overview

Vault stores secrets securely but starts in a "sealed" state. You must:
1. **Install** Vault on Kubernetes
2. **Initialize** Vault (generates unseal keys and root token)
3. **Unseal** Vault (provide 3 of 5 keys to unlock it)
4. **Configure** auto-unseal to handle restarts
5. **(Optional)** Setup ingress for external access

## Prerequisites

- K3s cluster running
- `kubectl` configured
- `helm` installed
- **cert-manager installed** (required for TLS)
- Domain DNS configured (for ingress)

### Install cert-manager First

If you haven't installed cert-manager yet:

```bash
cd infra/k3s/cert-manager
./install.sh
```

See `infra/k3s/cert-manager/README.md` for details.

## Step 1: Install Vault

### Using the Script (Recommended)

```bash
cd infra/k3s/vault
./install.sh
```

### Manual Installation

```bash
# Add HashiCorp Helm repository
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update

# Create namespace
kubectl create namespace vault

# Install Vault
helm upgrade --install vault hashicorp/vault \
  --namespace vault \
  --set "server.ha.enabled=false" \
  --set "server.dataStorage.enabled=true" \
  --set "server.dataStorage.size=10Gi" \
  --set "server.dataStorage.storageClass=local-path" \
  --set "ui.enabled=true" \
  --set "injector.enabled=false"

# Wait for pod to be running
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault --timeout=300s
```

**What this does:**
- Single Vault instance (not HA)
- 10Gi persistent storage
- Web UI enabled
- Sidecar injector disabled (we won't use automatic injection)

### Verify Installation

```bash
# Check pod status
kubectl get pods -n vault

# Should show: vault-0   0/1   Running   0   30s
# Note: 0/1 is normal - Vault starts sealed
```

## Step 2: Initialize Vault

**CRITICAL**: This step generates the unseal keys and root token. You only do this ONCE. If you lose the keys, you cannot recover your Vault data.

### Option A: Using the Script

```bash
./init-vault.sh
```

The script will:
- Initialize Vault and generate 5 unseal keys + root token
- Store keys in Kubernetes secret `vault-unseal-keys`
- Perform initial unseal (needs 3 keys)
- Save credentials to `vault-credentials.txt`

### Option B: Manual Initialization

```bash
# Get the vault pod name
VAULT_POD=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}')

# Initialize Vault
kubectl exec -n vault $VAULT_POD -- vault operator init -format=json > /tmp/vault-init.json

# View the output
cat /tmp/vault-init.json
```

**Sample output:**
```json
{
  "unseal_keys_b64": [
    "key1-base64-encoded...",
    "key2-base64-encoded...",
    "key3-base64-encoded...",
    "key4-base64-encoded...",
    "key5-base64-encoded..."
  ],
  "unseal_keys_hex": [...],
  "unseal_shares": 5,
  "unseal_threshold": 3,
  "root_token": "hvs.XXXXXXXXXXXXXXXXXXXX"
}
```

**Save these immediately!** Write them to a secure file:

```bash
# Extract the keys and token (requires jq)
UNSEAL_KEY_1=$(jq -r '.unseal_keys_b64[0]' /tmp/vault-init.json)
UNSEAL_KEY_2=$(jq -r '.unseal_keys_b64[1]' /tmp/vault-init.json)
UNSEAL_KEY_3=$(jq -r '.unseal_keys_b64[2]' /tmp/vault-init.json)
UNSEAL_KEY_4=$(jq -r '.unseal_keys_b64[3]' /tmp/vault-init.json)
UNSEAL_KEY_5=$(jq -r '.unseal_keys_b64[4]' /tmp/vault-init.json)
ROOT_TOKEN=$(jq -r '.root_token' /tmp/vault-init.json)

# Save to file
cat > vault-credentials.txt <<EOF
Vault Credentials
==================
Root Token: $ROOT_TOKEN

Unseal Keys (need 3 of 5 to unseal):
1. $UNSEAL_KEY_1
2. $UNSEAL_KEY_2
3. $UNSEAL_KEY_3
4. $UNSEAL_KEY_4
5. $UNSEAL_KEY_5

IMPORTANT: Store these securely!
EOF

chmod 600 vault-credentials.txt

# Also store in Kubernetes secret (for auto-unseal)
kubectl create secret generic vault-unseal-keys -n vault \
    --from-literal=unseal-key-1="$UNSEAL_KEY_1" \
    --from-literal=unseal-key-2="$UNSEAL_KEY_2" \
    --from-literal=unseal-key-3="$UNSEAL_KEY_3" \
    --from-literal=unseal-key-4="$UNSEAL_KEY_4" \
    --from-literal=unseal-key-5="$UNSEAL_KEY_5" \
    --from-literal=root-token="$ROOT_TOKEN"
```

## Step 3: Unseal Vault

Vault requires 3 of the 5 unseal keys to become operational.

### Manual Unseal

```bash
# Check Vault status
kubectl exec -n vault $VAULT_POD -- vault status

# Should show: Sealed: true

# Unseal with 3 keys
kubectl exec -n vault $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_1"
# Progress: 1/3

kubectl exec -n vault $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_2"
# Progress: 2/3

kubectl exec -n vault $VAULT_POD -- vault operator unseal "$UNSEAL_KEY_3"
# Sealed: false - Vault is now unsealed!

# Verify
kubectl exec -n vault $VAULT_POD -- vault status
```

**Expected output when unsealed:**
```
Sealed          false
Total Shares    5
Threshold       3
Version         1.15.0
```

## Step 4: Configure Auto-Unseal

Vault re-seals when the pod restarts. Auto-unseal handles this automatically.

### What is Auto-Unseal?

A Kubernetes CronJob that:
- Runs every 5 minutes
- Checks if Vault is sealed
- If sealed, uses stored keys to unseal it
- No manual intervention needed

### Deploy Auto-Unseal

```bash
kubectl apply -f manifests/auto-unseal.yaml
```

**What this creates:**
- `ServiceAccount`: Permissions for the unseal job
- `Role` + `RoleBinding`: Grants access to read secrets and execute commands in pods
- `CronJob`: Runs unseal check every 5 minutes

### Verify Auto-Unseal

```bash
# Check CronJob exists
kubectl get cronjob vault-auto-unseal -n vault

# View recent jobs
kubectl get jobs -n vault

# Check logs (wait for first job to run)
kubectl logs -n vault -l job-name=vault-auto-unseal-<timestamp>
```

### Test Auto-Unseal

```bash
# Manually seal Vault
kubectl exec -n vault $VAULT_POD -- vault operator seal

# Check status (should be sealed)
kubectl exec -n vault $VAULT_POD -- vault status

# Wait 5 minutes for CronJob to run, or manually trigger:
kubectl create job -n vault vault-manual-unseal --from=cronjob/vault-auto-unseal

# Check status again (should be unsealed)
kubectl exec -n vault $VAULT_POD -- vault status
```

## Step 5: Access Vault UI

### Port-Forward (Local Access)

```bash
kubectl port-forward -n vault vault-0 8200:8200
```

Open browser to: http://localhost:8200

Login with the root token from `vault-credentials.txt`

### Ingress (External Access)

**Prerequisites:**
- Domain DNS pointing to your K3s cluster
- cert-manager installed for TLS certificates (see Prerequisites section above)

The ingress manifest uses cert-manager to automatically obtain a Let's Encrypt certificate:

```bash
# Apply ingress
kubectl apply -f manifests/ingress.yaml

# Wait for certificate (cert-manager will request it automatically)
kubectl get certificate -n vault

# Check certificate status
kubectl describe certificate vault-tls-cert -n vault

# Once ready, access at: https://vault.bareuptime.co
```

**How it works:**
1. Ingress has annotation: `cert-manager.io/cluster-issuer: "letsencrypt-prod"`
2. cert-manager sees this and creates a Certificate resource
3. Certificate requests TLS cert from Let's Encrypt
4. Let's Encrypt validates domain via HTTP-01 challenge
5. Certificate is issued and stored in `vault-tls-cert` secret
6. Traefik uses the certificate for HTTPS

## Step 6: Configure Vault for Use

### Enable KV Secrets Engine

```bash
# Port-forward first
kubectl port-forward -n vault vault-0 8200:8200

# In another terminal:
export VAULT_ADDR=http://localhost:8200
vault login $ROOT_TOKEN

# Enable Key-Value v2 secrets engine
vault secrets enable -path=secret kv-v2

# Test storing a secret
vault kv put secret/test password="hello-world"

# Read it back
vault kv get secret/test
```

### Create Application Policy

```bash
# Create a policy for applications to read secrets
vault policy write app-readonly - <<EOF
path "secret/data/myapp/*" {
  capabilities = ["read", "list"]
}
EOF

# Create a token with this policy
vault token create -policy=app-readonly -ttl=24h
```

## Common Operations

### Check Vault Status

```bash
kubectl exec -n vault vault-0 -- vault status
```

### Manually Unseal

```bash
# Get keys from secret
KEY1=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-1}' | base64 -d)
KEY2=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-2}' | base64 -d)
KEY3=$(kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-3}' | base64 -d)

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal "$KEY1"
kubectl exec -n vault vault-0 -- vault operator unseal "$KEY2"
kubectl exec -n vault vault-0 -- vault operator unseal "$KEY3"
```

### View Auto-Unseal Logs

```bash
# List recent jobs
kubectl get jobs -n vault -l app=cronjob-vault-auto-unseal

# View logs from most recent job
kubectl logs -n vault -l job-name=$(kubectl get jobs -n vault -l app=cronjob-vault-auto-unseal --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
```

### Restart Vault Pod

```bash
# Delete pod (will be recreated by StatefulSet)
kubectl delete pod vault-0 -n vault

# Wait for it to come back
kubectl wait --for=condition=ready pod vault-0 -n vault --timeout=300s

# Auto-unseal will unseal it within 5 minutes
# Or manually unseal immediately using keys above
```

## Troubleshooting

### Vault Won't Unseal

**Check keys exist:**
```bash
kubectl get secret vault-unseal-keys -n vault
```

**Verify keys are correct:**
```bash
# Get first key
kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-1}' | base64 -d
# Should be a long base64 string
```

**Check auto-unseal CronJob:**
```bash
kubectl get cronjob vault-auto-unseal -n vault
kubectl describe cronjob vault-auto-unseal -n vault
```

### Lost Root Token

If you lose the root token but still have unseal keys:

```bash
# Generate a new root token (requires unseal keys)
kubectl exec -n vault vault-0 -- vault operator generate-root -init

# Follow the prompts to use unseal keys
# This is an advanced procedure - see Vault docs
```

### Need to Re-Initialize (Data Loss!)

**WARNING**: This deletes all data in Vault!

```bash
# Delete secret and pod
kubectl delete secret vault-unseal-keys -n vault
kubectl delete pod vault-0 -n vault

# Wait for pod to restart
kubectl wait --for=condition=ready pod vault-0 -n vault --timeout=300s

# Initialize again
./init-vault.sh
```

## Security Best Practices

1. **Backup Keys Offline**: Store unseal keys in a password manager or encrypted backup
2. **Rotate Root Token**: Don't use root token for daily operations
3. **Use Policies**: Create specific policies for applications
4. **Enable Audit Log**: Track all Vault operations
5. **Consider Cloud KMS**: For production, use AWS/GCP/Azure KMS for auto-unseal instead of K8s secrets

### Enable Audit Logging

```bash
vault audit enable file file_path=/vault/logs/audit.log
```

## Reference

- **Vault Docs**: https://www.vaultproject.io/docs
- **Helm Chart**: https://github.com/hashicorp/vault-helm
- **Auto-Unseal Options**: https://www.vaultproject.io/docs/concepts/seal

## Quick Command Reference

```bash
# Status
kubectl exec -n vault vault-0 -- vault status

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal <key>

# Seal (locks Vault)
kubectl exec -n vault vault-0 -- vault operator seal

# Port-forward
kubectl port-forward -n vault vault-0 8200:8200

# Login via CLI
export VAULT_ADDR=http://localhost:8200
vault login <root-token>

# Store secret
vault kv put secret/myapp password=secret123

# Read secret
vault kv get secret/myapp

# View auto-unseal jobs
kubectl get jobs -n vault

# Check CronJob schedule
kubectl get cronjob vault-auto-unseal -n vault
```

## Cleanup

To completely remove Vault:

```bash
./install.sh -d
```

Or manually:
```bash
kubectl delete -f manifests/ingress.yaml
kubectl delete -f manifests/auto-unseal.yaml
kubectl delete secret vault-unseal-keys -n vault
helm uninstall vault -n vault
kubectl delete pvc data-vault-0 -n vault
kubectl delete namespace vault
rm -f vault-credentials.txt vault-info.txt
```
