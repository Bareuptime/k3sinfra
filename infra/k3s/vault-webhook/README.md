# Vault Secrets Webhook

Bank-Vaults (Banzai Cloud) Vault Secrets Webhook for injecting Vault secrets directly into Kubernetes pods via annotations.

## What It Does

The webhook **mutates pod specs** at creation time to:
1. Inject an init container that fetches secrets from Vault
2. Replace `vault:` prefixed environment variables with actual secret values
3. Use Kubernetes auth to authenticate with Vault

**This is exactly like Nomad's Vault templates** - simple and clean!

## Installation

```bash
chmod +x install.sh
./install.sh
```

Custom Vault address:
```bash
VAULT_ADDR="http://vault.vault.svc.cluster.local:8200" ./install.sh
```

## Verification

```bash
# Check webhook is running
kubectl get pods -n vault -l app.kubernetes.io/name=vault-secrets-webhook

# Check webhook configuration
kubectl get mutatingwebhookconfigurations
```

## Usage in Deployments

### 1. Add Pod Annotations

```yaml
apiVersion: apps/v1
kind: Deployment
spec:
  template:
    metadata:
      annotations:
        vault.security.banzaicloud.io/vault-addr: "http://vault.vault.svc.cluster.local:8200"
        vault.security.banzaicloud.io/vault-role: "bareuptime-backend"
        vault.security.banzaicloud.io/vault-skip-verify: "true"
```

### 2. Reference Secrets in Environment Variables

```yaml
env:
  - name: DATABASE_URL
    value: "vault:secret/data/bareuptime/database#DATABASE_URL"

  - name: REDIS_PASSWORD
    value: "vault:secret/data/shared/redis#REDIS_PASSWORD"
```

**Format:** `vault:<vault-path>#<key>`

### 3. Vault Kubernetes Auth Setup

The webhook uses Kubernetes auth, so you need:

```bash
# Enable Kubernetes auth
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create policy
vault policy write bareuptime-backend - <<EOF
path "secret/data/bareuptime/*" {
  capabilities = ["read"]
}
path "secret/data/shared/*" {
  capabilities = ["read"]
}
EOF

# Create role
vault write auth/kubernetes/role/bareuptime-backend \
  bound_service_account_names=bareuptime-backend \
  bound_service_account_namespaces=bareuptime-backend \
  policies=bareuptime-backend \
  ttl=24h
```

## How It Works

```
┌──────────────────────────────────────────────────────┐
│ 1. Pod Creation Request                               │
│    (with vault: env vars)                            │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│ 2. Webhook Intercepts                                │
│    - Adds init container (vault-env)                 │
│    - Mounts service account token                    │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│ 3. Init Container Runs                               │
│    - Authenticates with Vault (K8s auth)             │
│    - Fetches secrets                                 │
│    - Writes to shared volume                         │
└────────────────┬─────────────────────────────────────┘
                 │
                 ▼
┌──────────────────────────────────────────────────────┐
│ 4. Main Container Starts                             │
│    - Reads secrets from shared volume                │
│    - Env vars have actual secret values              │
└──────────────────────────────────────────────────────┘
```

## Advantages vs ESO

| Feature | ESO | Vault Webhook |
|---------|-----|---------------|
| Setup | Complex (SecretStore + 7 ExternalSecrets) | Simple (pod annotations) |
| Syntax | YAML resources | Like Nomad templates |
| Secrets in K8s | Yes (creates Secrets) | No (direct injection) |
| Auto-refresh | Yes (1h interval) | No (pod restart needed) |
| Simplicity | ❌ Complex | ✅ Simple |

## Troubleshooting

### Secrets not injecting

```bash
# Check webhook logs
kubectl logs -n vault -l app.kubernetes.io/name=vault-secrets-webhook

# Check pod events
kubectl describe pod <pod-name> -n <namespace>

# Check init container logs
kubectl logs <pod-name> -n <namespace> -c vault-env
```

### Vault authentication failing

```bash
# Verify Vault is accessible from pod
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://vault.vault.svc.cluster.local:8200/v1/sys/health

# Check ServiceAccount exists
kubectl get sa bareuptime-backend -n bareuptime-backend

# Verify Vault role
vault read auth/kubernetes/role/bareuptime-backend
```

## Uninstall

```bash
helm uninstall vault-secrets-webhook -n vault
```
