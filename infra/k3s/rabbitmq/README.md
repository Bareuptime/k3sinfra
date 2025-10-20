# RabbitMQ Installation Options

Two installation methods available:

## 🏆 Recommended: Official RabbitMQ Operator (Permanent Solution)

**Use**: `install-operator.sh`

**Pros:**
- ✅ Official RabbitMQ project
- ✅ Uses official `rabbitmq:3.13-management` Docker image
- ✅ Production-ready and maintained
- ✅ No Bitnami dependency issues
- ✅ Regular updates and security patches

**Install:**
```bash
./install-operator.sh
```

**Cleanup:**
```bash
NAMESPACE=common ./install-operator.sh -d
```

---

## ⚠️ Legacy: Bitnami Helm Chart (Temporary Workaround)

**Use**: `install.sh`

**Pros:**
- Quick setup
- Familiar Helm workflow

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
NAMESPACE=common ./install.sh -d
```

---

## Quick Decision Guide

**For Production**: Use `install-operator.sh` ✅

**For Quick Testing**: Either works, but operator is still preferred

**Bitnami Issues**: Bitnami changed their image strategy in August 2025:
- Versioned images moved to `bitnamilegacy` repository
- Legacy images get no security updates
- Official recommendation is to migrate away from Bitnami

## Migration Path

If you're currently using Bitnami:

```bash
# 1. Backup data
# 2. Cleanup Bitnami installation
./install.sh -d

# 3. Install with operator
./install-operator.sh
```

## More Information

- [RabbitMQ Cluster Operator Docs](https://www.rabbitmq.com/kubernetes/operator/install-operator)
- [Official RabbitMQ Docker Image](https://hub.docker.com/_/rabbitmq)
- [Bitnami Catalog Changes](https://github.com/bitnami/charts/issues/35164)
