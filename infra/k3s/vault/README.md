# Vault Installation with Auto-Unseal

Simple Vault setup for K3s with automatic unsealing.

## Documentation

- **[MANUAL_SETUP.md](MANUAL_SETUP.md)** - Complete step-by-step guide with explanations (recommended for first-time setup)
- **README.md** (this file) - Quick reference and automation scripts

## Quick Start (Automated)

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

**First time setting up Vault?** Read [MANUAL_SETUP.md](MANUAL_SETUP.md) to understand each step.

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

**IMPORTANT SECURITY CONSIDERATIONS:**

This auto-unseal setup stores unseal keys in Kubernetes secrets, which provides convenience at the cost of security:

**Pros:**
- ✅ Automatic recovery from pod restarts
- ✅ No manual intervention needed
- ✅ Keys stored in etcd (encrypted at rest if enabled)

**Cons:**
- ❌ Anyone with cluster admin access can read the keys
- ❌ Keys stored alongside the data they protect
- ❌ Not compliant with many security standards

**For Production Environments:**

Consider these more secure alternatives:

1. **Cloud KMS Auto-Unseal** (Recommended)
   - AWS KMS, GCP Cloud KMS, or Azure Key Vault
   - Keys never leave the cloud provider's HSM
   - Vault unseals automatically but securely
   - [Vault Docs: Auto-Unseal](https://www.vaultproject.io/docs/concepts/seal)

2. **Hardware Security Module (HSM)**
   - FIPS 140-2 compliant
   - Keys stored in tamper-resistant hardware
   - Enterprise-grade security

3. **Manual Unsealing**
   - Store keys offline (password manager, encrypted backup)
   - Manual unseal required after each restart
   - Most secure but least convenient

**For Development/Testing:**
- The Kubernetes secret method is acceptable
- Ensure K8s RBAC is properly configured
- Enable etcd encryption at rest
- Backup the `vault-unseal-keys` secret to a secure location

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
