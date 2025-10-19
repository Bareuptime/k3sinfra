# Vault Installation with Auto-Unseal

Simple Vault setup for K3s with automatic unsealing.

## Quick Start

```bash
# 1. Install Vault
./install.sh

# 2. Initialize Vault (stores keys in Kubernetes secret)
./init-vault.sh

# 3. Enable auto-unseal CronJob
kubectl apply -f manifests/auto-unseal.yaml

# 4. (Optional) Apply ingress
kubectl apply -f manifests/ingress.yaml
```

## What is Auto-Unseal?

Vault starts in a "sealed" state and needs to be unsealed with keys before it can be used. Auto-unseal automatically unseals Vault when:
- Vault pod restarts
- Vault gets sealed for any reason
- After initial installation

## How It Works

1. **Initialization** (`init-vault.sh`):
   - Initializes Vault and generates 5 unseal keys
   - Stores keys in Kubernetes secret `vault-unseal-keys`
   - Performs initial unseal
   - Saves credentials to `vault-credentials.txt`

2. **Auto-Unseal CronJob** (`manifests/auto-unseal.yaml`):
   - Runs every 5 minutes
   - Checks if Vault is sealed
   - If sealed, automatically unseals using stored keys
   - No manual intervention needed

## Files

- `install.sh` - Installs Vault using Helm
- `init-vault.sh` - Initializes Vault and stores keys
- `manifests/auto-unseal.yaml` - CronJob for automatic unsealing
- `manifests/ingress.yaml` - Ingress for external access

## Security Notes

**WARNING**: This auto-unseal method stores unseal keys in Kubernetes secrets. This is convenient but less secure than:
- Cloud KMS auto-unseal (AWS, GCP, Azure)
- Hardware Security Module (HSM)
- Manual unsealing

For production, consider using cloud KMS or keeping keys offline.

## Usage After Setup

### Access Vault

```bash
# Port-forward
kubectl port-forward -n vault vault-0 8200:8200

# Open browser
open http://localhost:8200

# Login with root token (from vault-credentials.txt)
```

### Check Status

```bash
kubectl exec -n vault vault-0 -- vault status
```

### Manual Unseal (if needed)

```bash
# Get keys from secret
kubectl get secret vault-unseal-keys -n vault -o jsonpath='{.data.unseal-key-1}' | base64 -d

# Unseal
kubectl exec -n vault vault-0 -- vault operator unseal <key>
```

### Store Secrets

```bash
# Login first
export VAULT_ADDR=http://localhost:8200
vault login <root-token>

# Enable KV v2 secrets engine
vault secrets enable -path=secret kv-v2

# Store a secret
vault kv put secret/myapp username=admin password=secret123

# Read a secret
vault kv get secret/myapp
```

## Monitoring

Check auto-unseal CronJob:

```bash
# View CronJob
kubectl get cronjob vault-auto-unseal -n vault

# View recent jobs
kubectl get jobs -n vault

# View logs
kubectl logs -n vault -l job-name=vault-auto-unseal-<timestamp>
```

## Troubleshooting

### Vault won't unseal

```bash
# Check if keys exist
kubectl get secret vault-unseal-keys -n vault

# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# Check auto-unseal logs
kubectl logs -n vault -l app=cronjob-vault-auto-unseal
```

### Re-initialize Vault

```bash
# Delete the pod and secret (WARNING: deletes all data)
kubectl delete secret vault-unseal-keys -n vault
kubectl delete pod vault-0 -n vault

# Wait for pod to start
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=vault -n vault

# Initialize again
./init-vault.sh
```

## Credentials Location

- Kubernetes Secret: `vault-unseal-keys` (namespace: vault)
- Local File: `vault-credentials.txt` (keep this safe!)
