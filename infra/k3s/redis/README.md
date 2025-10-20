# Redis High Availability Installation

Two installation methods with Sentinel support:

## 🏆 Recommended: Redis Operator with Sentinel (Production)

**Use**: `install-operator.sh`

**Architecture:**
- 1 Master + 2 Replicas
- 3 Sentinel instances for automatic failover
- Official Redis Docker images (redis:7.4.1)
- Managed by OT-Container-Kit Redis Operator

**Pros:**
- ✅ Official Redis images (always updated)
- ✅ Automatic master failover with Sentinel
- ✅ Production-ready and actively maintained
- ✅ No Bitnami dependency issues
- ✅ Regular security updates
- ✅ Full HA setup out of the box

**Install:**
```bash
./install-operator.sh
```

**Cleanup:**
```bash
NAMESPACE=default ./install-operator.sh -d
```

---

## ⚠️ Alternative: Bitnami Helm with Sentinel (Legacy)

**Use**: `install.sh`

**Architecture:**
- 1 Master + 2 Replicas
- 3 Sentinel instances
- Bitnami Legacy images

**Pros:**
- Quick Helm-based setup
- Familiar Bitnami workflow
- Sentinel HA enabled

**Cons:**
- ❌ Uses `bitnamilegacy` repository (no security updates)
- ❌ Requires security bypass flag
- ❌ Will be deprecated eventually
- ❌ Not recommended for production

**Install:**
```bash
./install.sh
```

**Cleanup:**
```bash
NAMESPACE=default ./install.sh -d
```

---

## Redis Sentinel Overview

Both installations provide:

**High Availability Features:**
- **Automatic Failover**: If master fails, Sentinel promotes a replica
- **Monitoring**: Sentinels continuously monitor master and replicas
- **Notifications**: Apps are notified of topology changes
- **Configuration Provider**: Apps discover current master via Sentinel

**Architecture:**
```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│  Sentinel 1 │     │  Sentinel 2 │     │  Sentinel 3 │
└──────┬──────┘     └──────┬──────┘     └──────┬──────┘
       │                   │                   │
       └───────────────────┼───────────────────┘
                           │
       ┌───────────────────┼───────────────────┐
       │                   │                   │
┌──────▼──────┐     ┌──────▼──────┐     ┌──────▼──────┐
│   Master    │────▶│  Replica 1  │────▶│  Replica 2  │
└─────────────┘     └─────────────┘     └─────────────┘
```

---

## Connection Examples

### Using Master Directly (Simple)
```bash
# Environment variables
REDIS_HOST=redis-master.default.svc.cluster.local
REDIS_PORT=6379
REDIS_PASSWORD=your-password

# Connection string
redis://:your-password@redis-master.default.svc.cluster.local:6379
```

### Using Sentinel (Recommended for HA)
```bash
# Environment variables
REDIS_SENTINEL_HOSTS=redis-sentinel.default.svc.cluster.local:26379
REDIS_SENTINEL_MASTER=mymaster
REDIS_PASSWORD=your-password

# Your app queries Sentinel to get current master
```

### Application Code Example (Node.js)
```javascript
const Redis = require('ioredis');

// With Sentinel (recommended)
const redis = new Redis({
  sentinels: [
    { host: 'redis-sentinel.default.svc.cluster.local', port: 26379 }
  ],
  name: 'mymaster',
  password: process.env.REDIS_PASSWORD
});

// Direct connection (simpler, no automatic failover)
const redis = new Redis({
  host: 'redis-master.default.svc.cluster.local',
  port: 6379,
  password: process.env.REDIS_PASSWORD
});
```

---

## Quick Decision Guide

**For Production**: Use `install-operator.sh` ✅
- Official images
- Better long-term support
- Regular security updates

**For Quick Testing**: Either works
- Bitnami is faster to set up
- Operator is more robust

**Migration Path**: If using Bitnami currently:
```bash
# 1. Cleanup Bitnami
./install.sh -d

# 2. Install with operator
./install-operator.sh
```

---

## Bitnami Legacy Issue

**What happened (August 2025):**
- Bitnami moved versioned images to `bitnamilegacy` repository
- Legacy images receive **no security updates**
- Bitnami officially recommends migrating away

**Impact:**
- `docker.io/bitnami/redis:X.Y.Z` → Not found
- `docker.io/bitnamilegacy/redis:X.Y.Z` → Works but no updates

**Solution**: Use operator with official Redis images

---

## Testing Your Installation

```bash
# Test direct connection
kubectl run redis-client --rm -it --restart=Never \
  --image=redis:7.4.1 -n default -- \
  redis-cli -h redis-master -a your-password ping

# Check Sentinel status
kubectl run redis-client --rm -it --restart=Never \
  --image=redis:7.4.1 -n default -- \
  redis-cli -h redis-sentinel -p 26379 sentinel masters

# Monitor replication
kubectl run redis-client --rm -it --restart=Never \
  --image=redis:7.4.1 -n default -- \
  redis-cli -h redis-master -a your-password info replication
```

---

## More Information

- [Redis Sentinel Documentation](https://redis.io/docs/management/sentinel/)
- [OT-Container-Kit Redis Operator](https://github.com/OT-CONTAINER-KIT/redis-operator)
- [Official Redis Docker Image](https://hub.docker.com/_/redis)
- [Bitnami Catalog Changes](https://github.com/bitnami/charts/issues/35164)
