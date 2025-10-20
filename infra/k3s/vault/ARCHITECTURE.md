# Vault Architecture Overview

## System Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                       K3s Cluster                            │
│                                                              │
│  ┌────────────────────────────────────────────────────────┐ │
│  │                 Vault Namespace                         │ │
│  │                                                         │ │
│  │  ┌──────────────────┐        ┌──────────────────┐     │ │
│  │  │   vault-0 Pod    │        │  Auto-Unseal     │     │ │
│  │  │  ┌────────────┐  │        │    CronJob       │     │ │
│  │  │  │   Vault    │  │        │                  │     │ │
│  │  │  │  Server    │  │        │  Runs every      │     │ │
│  │  │  │            │  │◄───────┤  5 minutes       │     │ │
│  │  │  │ Port: 8200 │  │        │                  │     │ │
│  │  │  │            │  │        │  Checks sealed?  │     │ │
│  │  │  │ Status:    │  │        │  → Unseals it    │     │ │
│  │  │  │ Sealed/    │  │        └──────────────────┘     │ │
│  │  │  │ Unsealed   │  │                 │               │ │
│  │  │  └────────────┘  │                 │               │ │
│  │  │        │         │                 │               │ │
│  │  │        │         │                 ▼               │ │
│  │  │        │         │        ┌──────────────────┐     │ │
│  │  │        ▼         │        │  K8s Secret      │     │ │
│  │  │  ┌────────────┐  │        │  vault-unseal-   │     │ │
│  │  │  │    PVC     │  │        │      keys        │     │ │
│  │  │  │  (10Gi)    │  │        │                  │     │ │
│  │  │  │            │  │        │  - unseal-key-1  │     │ │
│  │  │  │ Stores:    │  │        │  - unseal-key-2  │     │ │
│  │  │  │ - Secrets  │  │        │  - unseal-key-3  │     │ │
│  │  │  │ - Policies │  │        │  - unseal-key-4  │     │ │
│  │  │  │ - Audit    │  │        │  - unseal-key-5  │     │ │
│  │  │  └────────────┘  │        │  - root-token    │     │ │
│  │  └──────────────────┘        └──────────────────┘     │ │
│  │                                                         │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                              │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │               Ingress (Optional)                         │ │
│  │                                                          │ │
│  │  vault.bareuptime.co  ──►  Traefik  ──►  Vault:8200    │ │
│  │       (HTTPS)                                            │ │
│  └──────────────────────────────────────────────────────────┘ │
│                                                              │
└──────────────────────────────────────────────────────────────┘

External Access:
  • kubectl port-forward (localhost:8200)
  • Ingress (vault.bareuptime.co)
```

## Component Breakdown

### 1. Vault Server Pod

**Purpose**: The main Vault application

**Configuration:**
- Single instance (not HA)
- Runs on port 8200
- Stores data in PersistentVolume
- Starts in "sealed" state

**States:**
- **Sealed**: Encrypted, cannot read/write secrets
- **Unsealed**: Operational, can process requests

**Storage:**
- 10Gi PVC (local-path storage class)
- Contains: encrypted secrets, policies, audit logs, configuration

### 2. Auto-Unseal CronJob

**Purpose**: Automatically unseal Vault after restarts

**How it works:**
```
Every 5 minutes:
  1. Check if Vault pod exists
  2. Query Vault status
  3. If sealed:
     - Read unseal keys from K8s secret
     - Execute 3 unseal operations
     - Vault becomes operational
  4. If unsealed:
     - Exit (nothing to do)
```

**RBAC Permissions:**
- ServiceAccount: `vault-unseal`
- Can: read secrets, list pods, exec into pods

### 3. Unseal Keys Secret

**Purpose**: Store the keys needed to unseal Vault

**Contents:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vault-unseal-keys
  namespace: vault
data:
  unseal-key-1: <base64>
  unseal-key-2: <base64>
  unseal-key-3: <base64>
  unseal-key-4: <base64>
  unseal-key-5: <base64>
  root-token: <base64>
```

**Security:**
- Stored in etcd
- Accessible to cluster admins
- Used by auto-unseal CronJob

### 4. Ingress (Optional)

**Purpose**: External HTTPS access to Vault UI

**Configuration:**
- Domain: vault.bareuptime.co
- TLS: Let's Encrypt certificate via cert-manager
- Routes to: vault:8200

## Vault Lifecycle

### Initial Setup Flow

```
1. helm install vault
   └─► Pod starts in SEALED state
       └─► Cannot serve requests

2. vault operator init
   ├─► Generates 5 unseal keys
   ├─► Generates root token
   └─► Saves to vault-unseal-keys secret

3. vault operator unseal (3 times)
   ├─► Use 3 of 5 keys
   └─► Vault becomes UNSEALED

4. kubectl apply auto-unseal.yaml
   └─► CronJob monitors Vault status
       └─► Auto-unseals if sealed
```

### Normal Operation

```
Application Request:
  ┌──────────┐
  │   App    │
  └────┬─────┘
       │ HTTP Request
       │ POST /v1/secret/data/myapp
       │ X-Vault-Token: <token>
       ▼
  ┌────────────┐
  │   Vault    │──── Checks Token ────► Valid?
  │  (Unsealed)│                          │
  └────┬───────┘                          │
       │                                  ▼
       │                            ┌──────────┐
       │                            │ Decrypt  │
       │                            │ Secret   │
       │                            └────┬─────┘
       │                                 │
       │◄────────────────────────────────┘
       │
       ▼
  ┌──────────┐
  │   App    │
  └──────────┘
  Receives secret
```

### Pod Restart Flow

```
1. Pod restarts
   └─► Vault starts SEALED

2. Within 5 minutes:
   └─► CronJob runs
       ├─► Detects sealed state
       ├─► Retrieves unseal keys from secret
       └─► Executes 3 unseal commands

3. Vault becomes UNSEALED
   └─► Applications can access secrets again
```

## Security Model

### Vault's Security Layers

```
┌────────────────────────────────────────────┐
│  Layer 1: Physical/Network Security        │
│  - K8s RBAC                                 │
│  - Network policies                         │
│  - Ingress authentication                   │
└─────────────────┬──────────────────────────┘
                  │
┌─────────────────▼──────────────────────────┐
│  Layer 2: Vault Seal/Unseal                │
│  - Vault starts sealed (encrypted)          │
│  - Requires 3 of 5 keys to unseal          │
│  - Keys stored in K8s secret               │
└─────────────────┬──────────────────────────┘
                  │
┌─────────────────▼──────────────────────────┐
│  Layer 3: Vault Authentication             │
│  - Root token (full access)                 │
│  - Policy-based tokens (limited access)     │
│  - AppRole, K8s auth, etc.                 │
└─────────────────┬──────────────────────────┘
                  │
┌─────────────────▼──────────────────────────┐
│  Layer 4: Vault Policies                   │
│  - Path-based access control                │
│  - Read/write/delete permissions            │
│  - Principle of least privilege             │
└─────────────────┬──────────────────────────┘
                  │
┌─────────────────▼──────────────────────────┐
│  Layer 5: Data Encryption                  │
│  - All data encrypted at rest               │
│  - Encrypted in transit (TLS)              │
│  - Audit logging enabled                    │
└────────────────────────────────────────────┘
```

### Trust Boundaries

**Trusted:**
- Kubernetes cluster admins (can read unseal keys)
- Auto-unseal CronJob service account
- Vault root token holder

**Untrusted:**
- Applications (must authenticate)
- External users (must go through authentication)
- Network traffic (must use TLS)

## Unseal Key Management

### Shamir's Secret Sharing

Vault uses Shamir's Secret Sharing algorithm:

```
Master Key (encrypts all data)
         │
         ▼
Split into 5 shares (unseal keys)
         │
         ├─► Key 1
         ├─► Key 2
         ├─► Key 3
         ├─► Key 4
         └─► Key 5

To reconstruct master key:
- Need any 3 of 5 keys (threshold)
- Each individual key is useless alone
- No single person can unseal Vault
```

### Key Distribution Best Practices

**For Production:**
```
Key 1 → Person A (CEO)
Key 2 → Person B (CTO)
Key 3 → Person C (Security Lead)
Key 4 → Secure backup location
Key 5 → Emergency access (locked safe)
```

**For Our Setup:**
```
All keys → K8s secret (auto-unseal)
Backup  → vault-credentials.txt (server)
Backup  → Secure password manager
```

## High Availability Architecture (Future)

For production, consider upgrading to HA:

```
┌────────────────────────────────────────────────┐
│  Load Balancer / Service                       │
└─────────┬──────────────────────────────────────┘
          │
    ┌─────┴─────┬──────────┬──────────┐
    ▼           ▼          ▼          ▼
┌────────┐ ┌────────┐ ┌────────┐ ┌────────┐
│ Vault  │ │ Vault  │ │ Vault  │ │ Vault  │
│ Node 1 │ │ Node 2 │ │ Node 3 │ │ Node N │
│(Active)│ │(Standby│ │(Standby│ │(Standby│
└────┬───┘ └────┬───┘ └────┬───┘ └────┬───┘
     │          │          │          │
     └──────────┴──────────┴──────────┘
                │
                ▼
        ┌──────────────┐
        │  Raft Storage│
        │  (Integrated)│
        └──────────────┘
```

**Benefits:**
- No single point of failure
- Automatic leader election
- Seamless failover
- Horizontal scaling

**Configuration:**
```bash
helm upgrade --install vault hashicorp/vault \
  --set "server.ha.enabled=true" \
  --set "server.ha.replicas=3" \
  --set "server.ha.raft.enabled=true"
```

## Monitoring & Observability

### Key Metrics to Monitor

```
Vault Health:
  ├─ Sealed/Unsealed status
  ├─ Active/Standby status (HA)
  ├─ Token count
  └─ Secret operations/sec

Auto-Unseal:
  ├─ CronJob success rate
  ├─ Time to unseal
  └─ Unseal failures

Storage:
  ├─ PVC usage
  ├─ Write latency
  └─ Read latency
```

### Useful Commands

```bash
# Check Vault status
kubectl exec -n vault vault-0 -- vault status

# View metrics
kubectl exec -n vault vault-0 -- vault read sys/metrics

# Check auto-unseal history
kubectl get jobs -n vault -l app=cronjob-vault-auto-unseal

# View audit logs
kubectl exec -n vault vault-0 -- cat /vault/logs/audit.log
```

## References

- [Vault Architecture](https://www.vaultproject.io/docs/internals/architecture)
- [Seal/Unseal Concepts](https://www.vaultproject.io/docs/concepts/seal)
- [Shamir's Secret Sharing](https://en.wikipedia.org/wiki/Shamir%27s_Secret_Sharing)
- [Vault on Kubernetes](https://www.vaultproject.io/docs/platform/k8s)
