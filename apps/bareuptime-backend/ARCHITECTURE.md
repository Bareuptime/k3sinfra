# BareUptime Backend - Kubernetes Architecture

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                         Internet                                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │
                    ┌───────▼────────┐
                    │   DNS Records  │
                    │  *.bareuptime  │
                    │      .co       │
                    └───────┬────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
  ┌─────▼──────┐    ┌──────▼──────┐    ┌──────▼──────┐
  │api.bare    │    │mcp.bare     │    │vault.bare   │
  │uptime.co   │    │uptime.co    │    │uptime.co    │
  └─────┬──────┘    └──────┬──────┘    └──────┬──────┘
        │                   │                   │
        └───────────────────┼───────────────────┘
                            │
                    ┌───────▼────────┐
                    │    Traefik     │
                    │  (K3s Ingress) │
                    │                │
                    │  - TLS Term    │
                    │  - Rate Limit  │
                    │  - CORS        │
                    └───────┬────────┘
                            │
        ┌───────────────────┼───────────────────┐
        │                   │                   │
┌───────▼────────┐  ┌──────▼──────┐    ┌──────▼──────┐
│   IngressRoute │  │  Middlewares│    │ Certificates│
│   (api/mcp)    │  │             │    │             │
│                │  │ -Security   │    │ -cert-mgr   │
│ Priority: 100  │  │ -RateLimit  │    │ -Let's      │
│                │  │ -CORS       │    │  Encrypt    │
└───────┬────────┘  └─────────────┘    └─────────────┘
        │
        │
┌───────▼────────────────────────────────────────────────────────┐
│              bareuptime-backend Namespace                       │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │                   Service (ClusterIP)                     │ │
│  │                   backend:8080                            │ │
│  └────────────────────────┬─────────────────────────────────┘ │
│                            │                                   │
│         ┌──────────────────┼──────────────────┐               │
│         │                  │                  │               │
│  ┌──────▼──────┐    ┌─────▼──────┐    ┌─────▼──────┐        │
│  │  Pod 1      │    │  Pod 2     │    │  Pod 3     │        │
│  │             │    │            │    │            │        │
│  │  Container: │    │ Container: │    │ Container: │        │
│  │  backend    │    │  backend   │    │  backend   │        │
│  │             │    │            │    │            │        │
│  │  Port: 8080 │    │ Port: 8080 │    │ Port: 8080 │        │
│  │             │    │            │    │            │        │
│  │  Resources: │    │ Resources: │    │ Resources: │        │
│  │  150m CPU   │    │ 150m CPU   │    │ 150m CPU   │        │
│  │  365Mi RAM  │    │ 365Mi RAM  │    │ 365Mi RAM  │        │
│  └──────┬──────┘    └─────┬──────┘    └─────┬──────┘        │
│         │                  │                  │               │
│         │    ┌─────────────┼─────────────┐    │               │
│         │    │             │             │    │               │
│  ┌──────▼────▼─────┐ ┌────▼─────┐ ┌────▼────▼─────┐         │
│  │  Env from Secrets│ │   Vault  │ │  Volume Mounts│         │
│  │                  │ │  Secrets │ │               │         │
│  │ -database-creds  │ │   (ESO)  │ │ /opt/bareuptime        │
│  │ -redis-creds     │ │          │ │ /secrets/google.json   │
│  │ -github-creds    │ │          │ │                │         │
│  │ -app-config      │ │          │ │  PVC: backend- │         │
│  │ -clickhouse-creds│ │          │ │  storage (1Gi) │         │
│  │ -google-sa       │ │          │ │                │         │
│  └──────────────────┘ └──────────┘ └────────────────┘         │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│              External Secrets Operator (ESO)                     │
│                                                                 │
│  ┌──────────────┐         ┌──────────────────────────────┐    │
│  │ SecretStore  │────────▶│  ExternalSecret Resources    │    │
│  │              │         │                              │    │
│  │ vault-backend│         │  - database-credentials      │    │
│  │              │         │  - redis-credentials         │    │
│  │ Points to:   │         │  - github-credentials        │    │
│  │ vault:8200   │         │  - app-config                │    │
│  │              │         │  - google-service-account    │    │
│  │ Auth:        │         │  - clickhouse-credentials    │    │
│  │ Kubernetes   │         │                              │    │
│  │ SA: bareup   │         │  Each syncs from Vault       │    │
│  │ time-backend │         │  to K8s Secret               │    │
│  └──────────────┘         └──────────────────────────────┘    │
│                                      │                          │
│                                      ▼                          │
│                            ┌──────────────────┐                │
│                            │  K8s Secrets     │                │
│                            │  (Auto-created)  │                │
│                            └──────────────────┘                │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    Vault Namespace                               │
│                                                                 │
│  ┌──────────────┐         ┌──────────────────────────────┐    │
│  │  vault-0     │         │  Vault Storage               │    │
│  │              │         │                              │    │
│  │  Port: 8200  │────────▶│  Secret Paths:               │    │
│  │              │         │                              │    │
│  │  Status:     │         │  secret/data/bareuptime/     │    │
│  │  Unsealed    │         │    - database                │    │
│  │              │         │    - auth                    │    │
│  │              │         │    - config                  │    │
│  │              │         │    - google-service-account  │    │
│  │              │         │                              │    │
│  │              │         │  secret/data/shared/         │    │
│  │              │         │    - redis                   │    │
│  │              │         │    - clickhouse              │    │
│  └──────────────┘         └──────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                    ArgoCD Integration                            │
│                                                                 │
│  ┌──────────────────────────────────────────────────────────┐ │
│  │  ArgoCD Application                                       │ │
│  │                                                           │ │
│  │  Name: bareuptime-backend                                │ │
│  │  Source: github.com/bareuptime/new-infra                 │ │
│  │  Path: apps/bareuptime-backend                           │ │
│  │  Destination: bareuptime-backend namespace               │ │
│  │                                                           │ │
│  │  Sync Policy:                                            │ │
│  │  - Auto-sync: true                                       │ │
│  │  - Self-heal: true                                       │ │
│  │  - Prune: true                                           │ │
│  │                                                           │ │
│  │  Health Checks:                                          │ │
│  │  - Deployment: Running                                   │ │
│  │  - Service: Healthy                                      │ │
│  │  - IngressRoute: Configured                              │ │
│  │  - ExternalSecrets: Synced                               │ │
│  └──────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                  External Dependencies                           │
│                                                                 │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐    │
│  │  PostgreSQL  │    │  ClickHouse  │    │    Redis     │    │
│  │              │    │              │    │   Sentinel   │    │
│  │ 10.10.85.1   │    │ 10.10.85.1   │    │              │    │
│  │ :5432        │    │ 10.10.85.5   │    │ sentinel.svc │    │
│  │              │    │ :9000        │    │ :26379       │    │
│  └──────────────┘    └──────────────┘    └──────────────┘    │
└─────────────────────────────────────────────────────────────────┘
```

## Data Flow

### 1. Request Flow

```
User Request
  │
  ▼
DNS Resolution (api1.bareuptime.co)
  │
  ▼
Traefik Ingress Controller
  │
  ├─▶ TLS Termination (cert-manager cert)
  ├─▶ Rate Limiting (200 req/min)
  ├─▶ Security Headers
  └─▶ CORS Validation
  │
  ▼
IngressRoute (backend-api)
  │
  ▼
Service (backend:8080)
  │
  ▼
Pod (Load balanced across 3 replicas)
  │
  ▼
Backend Container (port 8080)
  │
  ├─▶ Database Query (PostgreSQL)
  ├─▶ Cache Check (Redis Sentinel)
  ├─▶ Analytics Write (ClickHouse)
  └─▶ Notification (FCM/Brevo)
  │
  ▼
Response to User
```

### 2. Secret Sync Flow

```
Vault (source of truth)
  │
  ▼
ESO Controller (every 1 hour)
  │
  ├─▶ Reads from Vault via Kubernetes auth
  ├─▶ Creates/Updates K8s Secrets
  └─▶ Watches for changes
  │
  ▼
Kubernetes Secrets
  │
  ▼
Mounted in Pods as:
  ├─▶ Environment variables
  └─▶ Files (/secrets/google-service-account.json)
  │
  ▼
Backend Application reads secrets
```

### 3. Deployment Flow

```
Git Push to main branch
  │
  ▼
ArgoCD detects change
  │
  ▼
ArgoCD syncs manifests
  │
  ├─▶ Creates/Updates namespace
  ├─▶ Creates/Updates SecretStore
  ├─▶ Creates/Updates ExternalSecrets
  ├─▶ Creates/Updates PVC
  ├─▶ Creates/Updates Service
  ├─▶ Creates/Updates Deployment
  └─▶ Creates/Updates IngressRoute
  │
  ▼
Kubernetes applies changes
  │
  ├─▶ ESO syncs secrets from Vault
  ├─▶ Deployment creates/updates pods
  ├─▶ cert-manager requests certificates
  └─▶ Traefik configures routes
  │
  ▼
Application running with:
  ├─▶ 3 replicas
  ├─▶ HTTPS enabled
  ├─▶ Secrets loaded
  └─▶ Health checks passing
```

## Component Responsibilities

| Component | Responsibility |
|-----------|----------------|
| **Traefik** | Ingress controller, TLS termination, routing, rate limiting |
| **cert-manager** | Automatic TLS certificate management via Let's Encrypt |
| **ArgoCD** | GitOps continuous deployment, sync from Git to cluster |
| **ESO** | Sync secrets from Vault to Kubernetes Secrets |
| **Vault** | Centralized secret storage and management |
| **Deployment** | Manages pod lifecycle, rolling updates, health checks |
| **Service** | Internal load balancing across pod replicas |
| **PVC** | Persistent storage for application data |
| **IngressRoute** | Traefik-specific routing configuration |
| **Middlewares** | Request processing (security, rate limiting, CORS) |

## Security Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Security Layers                           │
│                                                              │
│  Layer 1: Network                                           │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ - TLS 1.2+ only                                        │ │
│  │ - HSTS headers                                         │ │
│  │ - Rate limiting (200 req/min API, 100 req/min MCP)    │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Layer 2: Authentication & Authorization                    │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ - Vault Kubernetes auth for ESO                       │ │
│  │ - ServiceAccount with minimal permissions             │ │
│  │ - imagePullSecrets for private registry              │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Layer 3: Secrets Management                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ - All secrets in Vault (encrypted at rest)            │ │
│  │ - All secrets synced to K8s via ESO (including GHCR)  │ │
│  │ - No secrets stored in Git                            │ │
│  │ - Secrets mounted as env vars (not in image)          │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Layer 4: Container Security                                │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ - Non-root container execution                        │ │
│  │ - Read-only file mounts where possible                │ │
│  │ - Resource limits enforced                            │ │
│  │ - Health checks (liveness/readiness)                  │ │
│  └────────────────────────────────────────────────────────┘ │
│                                                              │
│  Layer 5: Application Security                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │ - CORS restricted to bareuptime.co                    │ │
│  │ - Security headers (XSS, frame deny, etc.)            │ │
│  │ - Database connections over TLS                       │ │
│  └────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## High Availability

### Pod Distribution

- **3 replicas** across available nodes
- **Anti-affinity** rules prevent colocation on same node
- **Rolling updates** with max 1 unavailable
- **Health checks** ensure only healthy pods receive traffic

### Failure Scenarios

| Scenario | Impact | Recovery |
|----------|--------|----------|
| 1 pod fails | No impact (2 healthy pods) | Auto-restart |
| 1 node fails | Reduced capacity | Pods reschedule to other nodes |
| Database unreachable | Init container blocks startup | Pods wait, retry |
| Vault sealed | Secrets not synced | ESO retries, manual unseal |
| Certificate expired | HTTPS fails | cert-manager auto-renews |
| Ingress controller down | No external access | K3s restarts Traefik |

### Resource Limits

Per pod:
- CPU: 150m (request) / 500m (limit)
- Memory: 365Mi (request) / 512Mi (limit)
- Storage: Shared 1Gi PVC

Total cluster capacity needed:
- CPU: 450m minimum (1.5 cores max)
- Memory: 1095Mi minimum (1.5Gi max)
- Storage: 1Gi PVC

## Monitoring & Observability

### Logs

```bash
# Application logs
kubectl logs -n bareuptime-backend -l app=bareuptime-backend --tail=100 -f

# ArgoCD sync logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller

# ESO logs
kubectl logs -n external-secrets-system -l app.kubernetes.io/name=external-secrets

# Traefik logs
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik
```

### Metrics

```bash
# Pod resource usage
kubectl top pods -n bareuptime-backend

# Node resource usage
kubectl top nodes

# Service endpoints
kubectl get endpoints -n bareuptime-backend
```

### Health Checks

```bash
# Application health
curl https://api1.bareuptime.co/health

# Kubernetes health
kubectl get pods -n bareuptime-backend
kubectl describe deployment bareuptime-backend -n bareuptime-backend

# ArgoCD sync status
kubectl get application bareuptime-backend -n argocd
```

## Scalability

### Horizontal Scaling

```bash
# Manual scaling
kubectl scale deployment bareuptime-backend -n bareuptime-backend --replicas=5

# Auto-scaling (HPA)
kubectl autoscale deployment bareuptime-backend \
  -n bareuptime-backend \
  --cpu-percent=80 \
  --min=3 \
  --max=10
```

### Vertical Scaling

Update resource limits in `deployment.yaml`:

```yaml
resources:
  requests:
    cpu: 300m      # Increase from 150m
    memory: 768Mi  # Increase from 365Mi
  limits:
    cpu: 1000m     # Increase from 500m
    memory: 1Gi    # Increase from 512Mi
```

## Disaster Recovery

### Backup

1. **Vault snapshots**: `vault operator raft snapshot save backup.snap`
2. **Git repository**: All manifests in version control
3. **Database backups**: Regular PostgreSQL/ClickHouse backups
4. **PVC backups**: Snapshot backend-storage PVC if needed

### Restore

1. **Restore Vault** from snapshot
2. **Restore database** from backup
3. **Redeploy application**: ArgoCD sync from Git
4. **Restore PVC data** if needed

## Comparison: Nomad vs Kubernetes

| Feature | Nomad | Kubernetes |
|---------|-------|------------|
| Secrets | Vault templates | ESO + Vault |
| Networking | Consul Connect | Service + Ingress |
| Load Balancing | Consul | Service (iptables) |
| Ingress | Traefik tags | IngressRoute CRD |
| Storage | Host volume | PVC |
| Updates | Canary updates | Rolling updates |
| Health Checks | Consul checks | Liveness/Readiness |
| Service Discovery | Consul DNS | K8s DNS |
| Configuration | HCL | YAML + Kustomize |
| Deployment | `nomad job run` | ArgoCD GitOps |
