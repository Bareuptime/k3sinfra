# BareUptime Backend - Kubernetes Deployment

Kubernetes deployment configuration for the BareUptime backend service, migrated from Nomad.

## Architecture

- **Deployment**: 3 replicas with rolling updates
- **Secrets Management**: Vault Secrets Webhook (like Nomad templates!)
- **Ingress**: Traefik with TLS (cert-manager)
- **Storage**: 1Gi PVC with local-path storage class
- **Domains**:
  - `api.bareuptime.co` (main API)
  - `mcp.bareuptime.co` (MCP endpoints)

## Manifest Structure

This deployment uses **2 manifest files** (managed via Kustomize):

1. **`manifests.yaml`** - Everything (6 resources)
   - Namespace
   - ServiceAccount (for Vault authentication)
   - PersistentVolumeClaim (1Gi storage)
   - Service (ClusterIP on port 8080)
   - GHCR credentials secret (with Vault injection)
   - Deployment (3 replicas with Vault annotations)

2. **`ingress.yaml`** - Networking
   - IngressRoutes (api.bareuptime.co, mcp.bareuptime.co)
   - Certificates (Let's Encrypt)
   - Middlewares (CORS, rate limiting, security headers)

**Simple like Nomad!** Secrets use `vault:` prefix just like Nomad templates.

## Prerequisites

Before deploying, ensure you have the following installed in your K3s cluster:

### 1. Vault Secrets Webhook

```bash
# Install via our script (recommended)
cd apps/bareuptime-backend
chmod +x install-prerequisites.sh
./install-prerequisites.sh
```

Or manually:
```bash
cd infra/k3s/vault-webhook
chmod +x install.sh
./install.sh
```

Verify:
```bash
kubectl get pods -n vault -l app.kubernetes.io/name=vault-secrets-webhook
```

### 2. Vault Kubernetes Auth Configuration

Configure Vault to allow Kubernetes authentication:

```bash
# Port-forward to Vault
kubectl port-forward -n vault vault-0 8200:8200 &

# In another terminal, login to Vault
export VAULT_ADDR=http://localhost:8200
vault login <root-token>

# Enable Kubernetes auth method
vault auth enable kubernetes

# Configure Kubernetes auth
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Create policy for bareuptime-backend
vault policy write bareuptime-backend - <<EOF
# Database credentials
path "secret/data/bareuptime/database" {
  capabilities = ["read"]
}

# Redis credentials
path "secret/data/shared/redis" {
  capabilities = ["read"]
}

# GitHub/Auth credentials
path "secret/data/bareuptime/auth" {
  capabilities = ["read"]
}

# Application config
path "secret/data/bareuptime/config" {
  capabilities = ["read"]
}

# Google service account
path "secret/data/bareuptime/google-service-account" {
  capabilities = ["read"]
}

# ClickHouse credentials
path "secret/data/shared/clickhouse" {
  capabilities = ["read"]
}

# GHCR credentials
path "secret/data/shared/ghcr" {
  capabilities = ["read"]
}
EOF

# Create Kubernetes role
vault write auth/kubernetes/role/bareuptime-backend \
  bound_service_account_names=bareuptime-backend \
  bound_service_account_namespaces=bareuptime-backend \
  policies=bareuptime-backend \
  ttl=24h
```

### 3. Verify Vault Secrets Exist

Ensure all required secrets are in Vault at the correct paths:

```bash
# Check database credentials
vault kv get secret/bareuptime/database

# Check Redis credentials
vault kv get secret/shared/redis

# Check auth credentials
vault kv get secret/bareuptime/auth

# Check app config
vault kv get secret/bareuptime/config

# Check Google service account
vault kv get secret/bareuptime/google-service-account

# Check ClickHouse credentials
vault kv get secret/shared/clickhouse

# Check GHCR credentials
vault kv get secret/shared/ghcr
```

If any secrets are missing, create them using the Nomad configuration as reference.

**Create GHCR credentials in Vault:**
```bash
vault kv put secret/shared/ghcr \
  username="<your-github-username>" \
  password="<your-github-token>"
```

### 4. cert-manager

Should already be installed from infra setup. Verify:

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer letsencrypt-prod
```

### 5. Traefik

Traefik should be the default ingress controller in K3s. Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
```

## Deployment Steps

### Step 1: Deploy with ArgoCD

```bash
# Apply the ArgoCD Application
kubectl apply -f apps/bareuptime-backend/argocd-application.yaml

# Watch the deployment
kubectl get application bareuptime-backend -n argocd -w
```

ArgoCD will automatically:
1. Create the namespace
2. Deploy all resources
3. Inject secrets from Vault via webhook (on pod startup)
4. Request TLS certificates via cert-manager
5. Start the backend pods

### Step 2: Verify Deployment

```bash
# Check ArgoCD app status
kubectl get application bareuptime-backend -n argocd

# Check pods
kubectl get pods -n bareuptime-backend

# Check certificates
kubectl get certificate -n bareuptime-backend

# Check ingress
kubectl get ingressroute -n bareuptime-backend

# View logs
kubectl logs -n bareuptime-backend -l app=bareuptime-backend --tail=100 -f
```

### Step 3: Test the Service

```bash
# Check health endpoint
curl -k https://api.bareuptime.co/health

# Check MCP endpoint
curl -k https://mcp.bareuptime.co/health

# View service details
kubectl describe svc backend -n bareuptime-backend
```

## Migration Notes from Nomad

### Key Differences

| Nomad | Kubernetes |
|-------|-----------|
| `template` blocks | Vault annotations + `vault:` env vars |
| `auth` in config | imagePullSecrets with `vault:` |
| Consul service discovery | K8s Service + DNS |
| Traefik tags | IngressRoute + Middleware CRDs |
| Host volume | PersistentVolumeClaim |
| `constraint` | nodeSelector / affinity |
| `spread` | Pod anti-affinity |
| `update` stanza | Deployment strategy |

### Secrets Injection

**Nomad:**
```hcl
template {
  data = <<EOH
{{- with secret "secret/data/bareuptime/database" -}}
DATABASE_URL={{ .Data.data.DATABASE_URL }}
{{- end }}
EOH
  env = true
}
```

**Kubernetes (this deployment):**
```yaml
annotations:
  vault.security.banzaicloud.io/vault-role: "bareuptime-backend"

env:
  - name: DATABASE_URL
    value: "vault:secret/data/bareuptime/database#DATABASE_URL"
```

**Same concept, different syntax!**

### Environment Variables

All environment variables from Nomad templates are now injected via Vault Secrets Webhook:

- **Database**: `DATABASE_URL`
- **Redis**: `REDIS_PASSWORD`, `REDIS_SENTINELS`, `REDIS_MASTER_NAME`
- **GitHub**: `GHC_TOKEN`, `GITHUB_USERNAME`
- **App config**: 20+ configuration values
- **Google SA**: Mounted as `/secrets/google-service-account.json`
- **ClickHouse**: `CLICKHOUSE_DATABASE`, `CLICKHOUSE_USERNAME`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_URLS`
- **GHCR**: Used in imagePullSecrets

### Resource Allocation

Maintained same resources as Nomad:
- CPU: 150m (requests) / 500m (limits)
- Memory: 365Mi (requests) / 512Mi (limits)

### Health Checks

Converted Nomad health checks to Kubernetes probes:
- **Liveness**: HTTP GET `/health` every 60s
- **Readiness**: HTTP GET `/health` every 10s

## Troubleshooting

### Pods Not Starting

```bash
# Check pod status
kubectl describe pod -n bareuptime-backend -l app=bareuptime-backend

# Check events
kubectl get events -n bareuptime-backend --sort-by='.lastTimestamp'

# Check init container logs (vault-env)
kubectl logs -n bareuptime-backend <pod-name> -c vault-env

# Check main container logs
kubectl logs -n bareuptime-backend <pod-name> -c backend
```

### Secrets Not Injecting

```bash
# Check webhook logs
kubectl logs -n vault -l app.kubernetes.io/name=vault-secrets-webhook

# Check vault-env init container
kubectl logs <pod-name> -n bareuptime-backend -c vault-env

# Verify Vault is accessible
kubectl run -it --rm debug --image=curlimages/curl --restart=Never -- \
  curl http://vault.vault.svc.cluster.local:8200/v1/sys/health

# Check ServiceAccount exists
kubectl get sa bareuptime-backend -n bareuptime-backend

# Verify Vault role
vault read auth/kubernetes/role/bareuptime-backend
```

Common issues:
- Vault not accessible from cluster
- Kubernetes auth not configured in Vault
- Wrong Vault paths
- ServiceAccount missing
- Webhook not installed

### Image Pull Errors

```bash
# Check if secret exists and has vault: values
kubectl get secret ghcr-credentials -n bareuptime-backend -o yaml

# Check pod events
kubectl get events -n bareuptime-backend --sort-by='.lastTimestamp' | grep Pull
```

### Certificate Not Issuing

```bash
# Check certificate status
kubectl describe certificate api-bareuptime-tls -n bareuptime-backend

# Check certificate request
kubectl get certificaterequest -n bareuptime-backend

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager
```

### Ingress Not Working

```bash
# Check IngressRoute
kubectl describe ingressroute backend-api -n bareuptime-backend

# Check Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik

# Test service directly (port-forward)
kubectl port-forward -n bareuptime-backend svc/backend 8080:8080
curl http://localhost:8080/health
```

## Updating the Application

### Manual Update

```bash
# Update image tag in manifests.yaml (Deployment section) or via ArgoCD UI
# ArgoCD will automatically sync if auto-sync is enabled

# Force sync
kubectl -n argocd argocd app sync bareuptime-backend

# Rollback
kubectl rollout undo deployment/bareuptime-backend -n bareuptime-backend
```

### Image Updater (Optional)

ArgoCD Image Updater can automatically update images:

```bash
# Add annotations to ArgoCD Application
kubectl annotate application bareuptime-backend \
  -n argocd \
  argocd-image-updater.argoproj.io/image-list=backend=ghcr.io/bareuptime/backend \
  argocd-image-updater.argoproj.io/backend.update-strategy=latest
```

## Scaling

```bash
# Scale up/down
kubectl scale deployment bareuptime-backend -n bareuptime-backend --replicas=5

# Auto-scaling (HPA)
kubectl autoscale deployment bareuptime-backend \
  -n bareuptime-backend \
  --cpu-percent=80 \
  --min=3 \
  --max=10
```

## Monitoring

```bash
# Resource usage
kubectl top pods -n bareuptime-backend

# Logs
kubectl logs -n bareuptime-backend -l app=bareuptime-backend --tail=100 -f

# Follow specific pod
kubectl logs -n bareuptime-backend <pod-name> -f

# Get pod metrics
kubectl get --raw /apis/metrics.k8s.io/v1beta1/namespaces/bareuptime-backend/pods
```

## Cleanup

```bash
# Delete via ArgoCD
kubectl delete application bareuptime-backend -n argocd

# Or manually
kubectl delete namespace bareuptime-backend
```

## Security Considerations

1. **Secrets**: All sensitive data in Vault, injected at runtime (never in Git or etcd)
2. **Image Pull**: GHCR credentials injected from Vault
3. **TLS**: Automatic Let's Encrypt certificates
4. **Rate Limiting**: Traefik middlewares prevent abuse
5. **CORS**: Restricted to bareuptime.co domains
6. **Security Headers**: Enforced via Traefik middleware

## Advantages vs ESO/Sealed Secrets

| Feature | ESO Approach | Vault Webhook (This) |
|---------|--------------|---------------------|
| Complexity | High (SecretStore + 7 ExternalSecrets) | Low (pod annotations) |
| Syntax | Complex YAML | Like Nomad templates |
| Secrets in K8s etcd | Yes (creates Secrets) | No (runtime injection) |
| Auto-refresh | Yes (1h interval) | On pod restart |
| Migration from Nomad | Different syntax | Similar syntax |
| Simplicity | ❌ | ✅ |

## Support

For issues:
1. Check this README troubleshooting section
2. Review ArgoCD application status
3. Check pod logs and events (including vault-env init container)
4. Verify Vault secrets and connectivity
