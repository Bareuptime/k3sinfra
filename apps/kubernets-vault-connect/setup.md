# 🧩 Kubernetes ↔ Vault Connection Setup Guide
*A step-by-step, layman-friendly setup guide for HashiCorp Vault Secrets Webhook integration in K3s or Kubernetes.*

---

## 🧠 Overview

This guide helps you securely connect **HashiCorp Vault** with your **Kubernetes cluster** so that pods can automatically fetch secrets (like database URLs, API keys, etc.) without storing them in plain YAML files.

### 🎯 Goal
Enable your pods to write environment variables like:
```yaml
env:
  - name: DATABASE_URL
    value: vault:secret/data/myapp/database#DATABASE_URL
````

and have the Vault Secrets Webhook replace them with the real values at runtime.

---

## 🧱 Prerequisites

Before starting, make sure:

✅ You already have **K3s or Kubernetes** running
✅ You have **Vault** installed (Helm or manual)
✅ You have **cert-manager** installed
✅ You are logged into Vault (`vault login <token>`) with admin/root access

---

## 🪄 STEP 1: Install Vault Secrets Webhook

Install the webhook that injects secrets into pods:

```bash
helm upgrade --install vault-secrets-webhook \
  oci://ghcr.io/bank-vaults/helm-charts/vault-secrets-webhook \
  --namespace vault \
  --create-namespace \
  --set image.tag=latest \
  --set env.VAULT_ADDR="http://vault.vault.svc.cluster.local:8200" \
  --set env.VAULT_SKIP_VERIFY="true" \
  --set configMapMutation=true \
  --set secretInit.tag=latest \
  --set env.VAULT_ROLE="default" \
  --wait
```

Verify it’s running:

```bash
kubectl get pods -n vault -l app.kubernetes.io/name=vault-secrets-webhook
```

You should see:

```
vault-secrets-webhook-xxxxxx   1/1   Running
vault-secrets-webhook-yyyyyy   1/1   Running
```

Check webhook registration:

```bash
kubectl get mutatingwebhookconfigurations | grep vault
```

---

## 🧩 STEP 2: Configure Vault to Trust Kubernetes

Vault needs to know how to talk to Kubernetes securely.

---

### 🪪 2.1 Create a Permanent ServiceAccount Token

Kubernetes (v1.24+) doesn’t automatically generate long-lived tokens.
We’ll create one manually:

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vault-token
  namespace: vault
  annotations:
    kubernetes.io/service-account.name: vault
type: kubernetes.io/service-account-token
EOF
```

Extract the token:

```bash
TOKEN_REVIEWER_JWT=$(kubectl get secret vault-token -n vault -o jsonpath='{.data.token}' | base64 --decode)
```

---

### 📜 2.2 Get Your Cluster CA Certificate

Fetch the Kubernetes root CA certificate:

```bash
kubectl get configmap -n kube-system kube-root-ca.crt -o jsonpath='{.data.ca\.crt}' > /tmp/ca.crt
```

Verify it:

```bash
cat /tmp/ca.crt
```

You should see something like:

```
-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----
```

---

### 🧰 2.3 Configure Vault Kubernetes Auth

Tell Vault where to find your API server and how to verify tokens:

```bash
vault write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443" \
  kubernetes_ca_cert=@/tmp/ca.crt \
  token_reviewer_jwt="$TOKEN_REVIEWER_JWT"
```

Check:

```bash
vault read auth/kubernetes/config
```

✅ Expected output:

```
kubernetes_ca_cert                   -----BEGIN CERTIFICATE-----
token_reviewer_jwt_set               true
```

---

## 🧩 STEP 3: Create Policy and Role in Vault

### 3.1 Create Policy

Defines which secrets can be read:

```bash
vault policy write bareuptime-backend - <<EOF
path "secret/data/bareuptime/*" {
  capabilities = ["read"]
}
path "secret/data/shared/*" {
  capabilities = ["read"]
}
EOF
```

---

### 3.2 Create Role

Binds the policy to a Kubernetes ServiceAccount:

```bash
vault write auth/kubernetes/role/bareuptime-backend \
  bound_service_account_names=bareuptime-backend \
  bound_service_account_namespaces=bareuptime-backend \
  policies=bareuptime-backend \
  ttl=24h
```

---

## 🧩 STEP 4: Deploy Your Application

Example `Deployment` manifest:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: bareuptime-backend
  namespace: bareuptime-backend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: bareuptime-backend
  template:
    metadata:
      labels:
        app: bareuptime-backend
      annotations:
        vault.security.banzaicloud.io/vault-addr: "http://vault.vault.svc.cluster.local:8200"
        vault.security.banzaicloud.io/vault-role: "bareuptime-backend"
        vault.security.banzaicloud.io/vault-path: "kubernetes"
        vault.security.banzaicloud.io/vault-skip-verify: "true"
    spec:
      serviceAccountName: bareuptime-backend
      containers:
        - name: backend
          image: ghcr.io/bareuptime/backend:latest
          env:
            - name: DATABASE_URL
              value: vault:secret/data/bareuptime/database#DATABASE_URL
```

---

## 🧩 STEP 5: Restart Everything

After configuration:

```bash
kubectl rollout restart deployment vault-secrets-webhook -n vault
kubectl delete pod -n bareuptime-backend -l app=bareuptime-backend
```

Check your pod:

```bash
kubectl get pods -n bareuptime-backend
```

Verify injected secrets:

```bash
kubectl exec -it -n bareuptime-backend <pod-name> -- env | grep DATABASE_URL
```

---

## 🧩 STEP 6: Troubleshooting (in Simple Terms)

| Problem                         | What it Means                       | Fix                                                                                 |
| ------------------------------- | ----------------------------------- | ----------------------------------------------------------------------------------- |
| `vault:secret/...` not replaced | Vault webhook couldn’t fetch secret | Check `vault read auth/kubernetes/config` for `token_reviewer_jwt_set=true`         |
| Pod stuck in `PodInitializing`  | Waiting for Vault to inject secrets | Check logs: `kubectl logs -n vault -l app.kubernetes.io/name=vault-secrets-webhook` |
| “permission denied” in Vault    | Wrong policy or service account     | Check Vault role and policy binding                                                 |

---

## 🔄 Do I Need to Repeat Steps 2.2 or 2.3?

No. Once done correctly:

| Step            | Persistent?                 | Redo When                                          |
| --------------- | --------------------------- | -------------------------------------------------- |
| 2.2 (CA cert)   | ✅ Yes                       | Only if cluster is rebuilt                         |
| 2.3 (JWT token) | ✅ Yes (if long-lived token) | Only if using temporary token or Vault reinstalled |

Temporary (`kubectl create token vault`) tokens expire in 1 hour.
Use a permanent **Secret-based token** as shown above for production.

---

## 🧩 Summary

| Component                  | Purpose                              |
| -------------------------- | ------------------------------------ |
| **Vault Secrets Webhook**  | Injects secrets into pods            |
| **Vault Policy**           | Defines what secrets can be read     |
| **Vault Role**             | Links ServiceAccount to Vault policy |
| **Kubernetes Auth Config** | Connects Vault with the cluster      |
| **Pod Annotations**        | Tell webhook what role to use        |

---

## ✅ Final Verification Commands

```bash
vault read auth/kubernetes/config
vault read auth/kubernetes/role/bareuptime-backend
kubectl get pods -n vault
kubectl logs -n vault -l app.kubernetes.io/name=vault-secrets-webhook
```

If all show healthy, your Vault-Kubernetes integration is complete.

---

**Author:** BareUptime Infrastructure Team
**Last Updated:** October 2025

