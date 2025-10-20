# BareUptime Infrastructure Setup

Simple and straightforward infrastructure setup for BareUptime application.

## Structure

```
infra/
├── baremetal/              # Baremetal installations
│   ├── postgres/          # PostgreSQL with pgvector
│   └── clickhouse/        # ClickHouse analytics DB
└── k3s/                   # Kubernetes (K3s) deployments
    ├── cert-manager/      # TLS certificate management
    ├── vault/             # HashiCorp Vault
    ├── argocd/            # ArgoCD GitOps
    ├── redis/             # Redis cache
    └── rabbitmq/          # RabbitMQ message broker
```

## Installation Order

### 1. Baremetal Components

Install these directly on your servers:

#### PostgreSQL with pgvector
```bash
cd baremetal/postgres
./install.sh
```

Features:
- PostgreSQL latest version
- pgvector extension for vector search
- Persistent storage
- Credentials saved to `postgres-info.txt`

#### ClickHouse
```bash
cd baremetal/clickhouse
./install.sh
```

Features:
- ClickHouse analytics database
- Optimized for time-series and analytics
- Credentials saved to `clickhouse-info.txt`

### 2. K3s Components

#### k3s install
```bash
sudo apt update && sudo apt upgrade -y
sudo apt install curl -y
```

```bash
curl -sfL https://get.k3s.io | sh -
sudo systemctl status k3s
```

##### Verify
```bash
sudo k3s kubectl get nodes
```

To use `kubectl` without `sudo`:
```bash
sudo cp /etc/rancher/k3s/k3s.yaml ~/.kube/config
sudo chown $USER:$USER ~/.kube/config
```

Install these in your Kubernetes cluster:

#### cert-manager (Required First)
```bash
cd k3s/cert-manager
./install.sh
```

**Important**: Install cert-manager before other K3s services that need TLS certificates.

Features:
- Automatic TLS certificate management
- Let's Encrypt integration (production + staging)
- Auto-renewal before expiry
- HTTP-01 challenge validation via Traefik

#### Vault (HashiCorp)
```bash
cd k3s/vault
./install.sh
```

After installation:
1. Initialize with auto-unseal: `./init-vault.sh`
2. Enable auto-unseal CronJob: `kubectl apply -f manifests/auto-unseal.yaml`
3. Apply ingress: `kubectl apply -f manifests/ingress.yaml`
4. Access at: https://vault.bareuptime.co

Features:
- Auto-unseal: Vault automatically unseals on restart
- Credentials saved to `vault-credentials.txt`
- Unseal keys stored in Kubernetes secret
- CronJob checks every 5 minutes and unseals if needed

#### ArgoCD
```bash
cd k3s/argocd
./install.sh
```

After installation:
1. Initial credentials saved to `argocd-info.txt`
2. Apply ingress: `kubectl apply -f manifests/ingress.yaml`
3. Access at: https://argocd.bareuptime.co
4. Deploy app: `kubectl apply -f manifests/application.yaml`

#### Redis
```bash
cd k3s/redis
./install.sh
```

Features:
- Redis with authentication
- Master-replica setup
- Persistent storage
- Connection info saved to `redis-info.txt`

#### RabbitMQ
```bash
cd k3s/rabbitmq
./install.sh
```

Features:
- RabbitMQ message broker
- Management UI enabled
- Persistent storage
- Connection info saved to `rabbitmq-info.txt`

## Domain Configuration

All services use `bareuptime.co` domain:

- **API**: api.bareuptime.co
- **ArgoCD**: argocd.bareuptime.co
- **Vault**: vault.bareuptime.co

Make sure you have:
1. DNS records pointing to your cluster (A records to cluster IP)
2. cert-manager installed in K3s (see above)
3. Port 80 accessible (for Let's Encrypt HTTP-01 validation)

## Prerequisites

### Baremetal
- Ubuntu/Debian or CentOS/RHEL server
- Root or sudo access
- Git installed

### K3s
- K3s cluster running
- kubectl configured
- Helm 3 installed
- cert-manager installed (for TLS)

**Note**: If running as root, the installation scripts will automatically use `/etc/rancher/k3s/k3s.yaml` for kubeconfig. Alternatively, you can set:
```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
```

## Quick Start

```bash
# 1. Install baremetal components
cd infra/baremetal/postgres && ./install.sh
cd ../clickhouse && ./install.sh

# 2. Install cert-manager (required for TLS)
cd ../../k3s/cert-manager && ./install.sh

# 3. Install Vault
cd ../vault && ./install.sh

# 4. Initialize Vault with auto-unseal
./init-vault.sh
kubectl apply -f manifests/auto-unseal.yaml

# 5. Install other K3s services
cd ../argocd && ./install.sh
cd ../redis && ./install.sh
cd ../rabbitmq && ./install.sh

# 6. Apply ingress configurations
cd ../../
kubectl apply -f k3s/vault/manifests/ingress.yaml
kubectl apply -f k3s/argocd/manifests/ingress.yaml
kubectl apply -f k3s/argocd/manifests/app-ingress.yaml
```

## Security Notes

1. All installation scripts prompt for passwords
2. Credentials are saved to local `*-info.txt` files
3. Store credentials in Vault after installation
4. Change default passwords immediately
5. Use TLS for all external access
6. **Vault auto-unseal**: Unseal keys are stored in Kubernetes secrets for convenience. For production, consider using cloud KMS (AWS, GCP, Azure) for better security.

## Storing Secrets in Vault

After Vault is initialized and unsealed:

```bash
# Login to Vault
kubectl exec -it vault-0 -n vault -- sh
export VAULT_TOKEN=<your-root-token>

# Store PostgreSQL credentials
vault kv put secret/postgres \
  url="postgresql://user:pass@host:5432/db" \
  username="..." \
  password="..."

# Store Redis credentials
vault kv put secret/redis \
  url="redis://user:pass@host:6379" \
  password="..."

# Store RabbitMQ credentials
vault kv put secret/rabbitmq \
  url="amqp://user:pass@host:5672" \
  username="..." \
  password="..."

# Store ClickHouse credentials
vault kv put secret/clickhouse \
  url="clickhouse://user:pass@host:9000/db" \
  username="..." \
  password="..."
```

## Troubleshooting

### Check pod status
```bash
kubectl get pods -n vault
kubectl get pods -n argocd
kubectl get pods -n default
```

### Check logs
```bash
kubectl logs -n vault vault-0
kubectl logs -n argocd deployment/argocd-server
```

### Port-forward for local access
```bash
# Vault
kubectl port-forward -n vault vault-0 8200:8200

# ArgoCD
kubectl port-forward svc/argocd-server -n argocd 8080:443

# RabbitMQ Management
kubectl port-forward svc/rabbitmq -n default 15672:15672
```

## Maintenance

### Backup PostgreSQL
```bash
pg_dump -U username -h localhost dbname > backup.sql
```

### Backup Vault
```bash
kubectl exec -it vault-0 -n vault -- vault operator raft snapshot save backup.snap
```

### Backup ClickHouse
```bash
clickhouse-client --query "BACKUP DATABASE bareuptime TO Disk('backups', 'backup.zip')"
```

## Support

For issues or questions, check:
- PostgreSQL: https://www.postgresql.org/docs/
- ClickHouse: https://clickhouse.com/docs
- Vault: https://www.vaultproject.io/docs
- ArgoCD: https://argo-cd.readthedocs.io/
- Redis: https://redis.io/documentation
- RabbitMQ: https://www.rabbitmq.com/documentation.html
