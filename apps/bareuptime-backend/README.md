# BareUptime Backend - Kubernetes Deployment

Kubernetes deployment configuration for the BareUptime backend service, migrated from Nomad.

## Architecture

- **Deployment**: 3 replicas with rolling updates
- **Secrets Management**: External Secrets Operator (ESO) + Vault
- **Ingress**: Traefik with TLS (cert-manager)
- **Storage**: 1Gi PVC with local-path storage class
- **Domains**:
  - `api1.bareuptime.co` (main API)
  - `mcp.bareuptime.co` (MCP endpoints)

## Prerequisites

Before deploying, ensure you have the following installed in your K3s cluster:

### 1. External Secrets Operator (ESO)

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets \
  external-secrets/external-secrets \
  -n external-secrets-system \
  --create-namespace \
  --set installCRDs=true
```

Verify:
```bash
kubectl get pods -n external-secrets-system
```

### 2. Sealed Secrets Controller

```bash
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update

helm install sealed-secrets \
  sealed-secrets/sealed-secrets \
  -n kube-system \
  --set-string fullnameOverride=sealed-secrets-controller
```

Verify:
```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=sealed-secrets
```

Install kubeseal CLI:
```bash
# macOS
brew install kubeseal

# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/kubeseal-0.24.0-linux-amd64.tar.gz
tar -xvzf kubeseal-0.24.0-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

### 3. Vault Kubernetes Auth Configuration

Configure Vault to allow Kubernetes authentication:

```bash
# Port-forward to Vault
kubectl port-forward -n vault vault-0 8200:8200

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
EOF

# Create Kubernetes role
vault write auth/kubernetes/role/bareuptime-backend \
  bound_service_account_names=bareuptime-backend \
  bound_service_account_namespaces=bareuptime-backend \
  policies=bareuptime-backend \
  ttl=24h
```

### 4. Verify Vault Secrets Exist

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
```

If any secrets are missing, create them using the Nomad configuration as reference.

### 5. cert-manager

Should already be installed from infra setup. Verify:

```bash
kubectl get pods -n cert-manager
kubectl get clusterissuer letsencrypt-prod
```

### 6. Traefik

Traefik should be the default ingress controller in K3s. Verify:

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik
```

## Deployment Steps

### Step 1: Create GHCR Credentials SealedSecret

Create the Docker registry secret for pulling images from GHCR:

```bash
# Create temporary secret
kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=<YOUR_GITHUB_USERNAME> \
  --docker-password=<YOUR_GITHUB_TOKEN> \
  --namespace=bareuptime-backend \
  --dry-run=client -o yaml > /tmp/ghcr-secret.yaml

# Seal it
kubeseal --format=yaml \
  --controller-namespace=kube-system \
  --controller-name=sealed-secrets-controller \
  < /tmp/ghcr-secret.yaml \
  > apps/bareuptime-backend/sealed-secret-ghcr.yaml

# Delete temporary file
rm /tmp/ghcr-secret.yaml

# Uncomment the sealed-secret in kustomization.yaml
# Edit kustomization.yaml and uncomment:
#   - sealed-secret-ghcr.yaml
```

**Alternative (Quick Test):** Create the secret manually:

```bash
kubectl create namespace bareuptime-backend
kubectl create secret docker-registry ghcr-credentials \
  --docker-server=ghcr.io \
  --docker-username=<YOUR_GITHUB_USERNAME> \
  --docker-password=<YOUR_GITHUB_TOKEN> \
  --namespace=bareuptime-backend
```

### Step 2: Deploy with ArgoCD

```bash
# Apply the ArgoCD Application
kubectl apply -f apps/bareuptime-backend/argocd-application.yaml

# Watch the deployment
kubectl get application bareuptime-backend -n argocd -w
```

ArgoCD will automatically:
1. Create the namespace
2. Deploy all resources
3. Sync secrets from Vault via ESO
4. Request TLS certificates via cert-manager
5. Start the backend pods

### Step 3: Verify Deployment

```bash
# Check ArgoCD app status
kubectl get application bareuptime-backend -n argocd

# Check pods
kubectl get pods -n bareuptime-backend

# Check secrets (should be created by ESO)
kubectl get externalsecrets -n bareuptime-backend
kubectl get secrets -n bareuptime-backend

# Check certificates
kubectl get certificate -n bareuptime-backend

# Check ingress
kubectl get ingressroute -n bareuptime-backend

# View logs
kubectl logs -n bareuptime-backend -l app=bareuptime-backend --tail=100 -f
```

### Step 4: Test the Service

```bash
# Check health endpoint
curl -k https://api1.bareuptime.co/health

# Check MCP endpoint
curl -k https://mcp.bareuptime.co/health

# View service details
kubectl describe svc backend -n bareuptime-backend
```

## Migration Notes from Nomad

### Key Differences

| Nomad | Kubernetes |
|-------|-----------|
| `template` blocks | ExternalSecrets + ESO |
| `auth` in config | imagePullSecrets |
| Consul service discovery | K8s Service + DNS |
| Traefik tags | IngressRoute + Middleware CRDs |
| Host volume | PersistentVolumeClaim |
| `constraint` | nodeSelector / affinity |
| `spread` | Pod anti-affinity |
| `update` stanza | Deployment strategy |

### Environment Variables

All environment variables from Nomad templates are now sourced from Kubernetes Secrets created by ESO:

- **database-credentials**: `DATABASE_URL`
- **redis-credentials**: `REDIS_PASSWORD`, `REDIS_SENTINELS`, `REDIS_MASTER_NAME`
- **github-credentials**: `GHC_TOKEN`, `GITHUB_USERNAME`
- **app-config**: All application configuration
- **google-service-account**: Mounted as `/secrets/google-service-account.json`
- **clickhouse-credentials**: `CLICKHOUSE_DATABASE`, `CLICKHOUSE_USERNAME`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_URLS`

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

# Check init container logs
kubectl logs -n bareuptime-backend <pod-name> -c wait-for-database
```

### Secrets Not Syncing

```bash
# Check SecretStore status
kubectl describe secretstore vault-backend -n bareuptime-backend

# Check ExternalSecret status
kubectl get externalsecrets -n bareuptime-backend
kubectl describe externalsecret <secret-name> -n bareuptime-backend

# Check ESO logs
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets
```

Common issues:
- Vault not accessible from cluster
- Kubernetes auth not configured in Vault
- Wrong Vault paths
- ServiceAccount missing

### Image Pull Errors

```bash
# Check if secret exists
kubectl get secret ghcr-credentials -n bareuptime-backend

# Check secret content
kubectl get secret ghcr-credentials -n bareuptime-backend -o yaml

# Manually test image pull
kubectl run test --image=ghcr.io/bareuptime/backend:latest \
  --image-pull-policy=Always \
  -n bareuptime-backend \
  --overrides='{"spec":{"imagePullSecrets":[{"name":"ghcr-credentials"}]}}'
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
# Update image tag in deployment.yaml or via ArgoCD UI
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

1. **Secrets**: All sensitive data in Vault, never in Git
2. **Image Pull**: SealedSecret for GHCR credentials
3. **TLS**: Automatic Let's Encrypt certificates
4. **Rate Limiting**: Traefik middlewares prevent abuse
5. **CORS**: Restricted to bareuptime.co domains
6. **Security Headers**: Enforced via Traefik middleware

## Support

For issues:
1. Check this README troubleshooting section
2. Review ArgoCD application status
3. Check pod logs and events
4. Verify Vault secrets and connectivity
