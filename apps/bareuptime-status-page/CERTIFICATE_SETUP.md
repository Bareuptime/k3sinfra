# Wildcard Certificate Setup Guide

## Problem
The original `wildcard-certificate.yaml` had ACME configuration directly in the Certificate spec, which is invalid. The error was:
```
Certificate in version "v1" cannot be handled as a Certificate: strict decoding error: unknown field "spec.acme"
```

## Solution
In cert-manager, ACME configuration belongs in the **ClusterIssuer**, not the Certificate resource:
- **Certificate**: Defines WHAT certificate you want (domains, secret name)
- **ClusterIssuer**: Defines HOW to get the certificate (ACME server, challenge solvers)

## Setup Steps

### 1. Create Cloudflare API Token

For wildcard certificates (`*.bareuptime.online`), DNS-01 challenge is required.

1. Go to https://dash.cloudflare.com/profile/api-tokens
2. Click **"Create Token"**
3. Use template: **"Edit zone DNS"**
4. Configure:
   - **Permissions**: Zone - DNS - Edit
   - **Zone Resources**: Include - Specific zone - `bareuptime.online`
5. Click **"Continue to summary"** → **"Create Token"**
6. Copy the token (you won't see it again!)

### 2. Create Kubernetes Secret

Create the secret in the **cert-manager namespace** (not bareuptime-backend):

```bash
kubectl create secret generic cloudflare-api-token-secret \
  --from-literal=api-token='0Ui7g5AGT1AgQmTopnutaJziNH87nZAinVJeuFLN' \
  -n cert-manager
```

Verify:
```bash
kubectl get secret cloudflare-api-token-secret -n cert-manager
```

### 3. Update ClusterIssuer

Edit the ClusterIssuer to add DNS-01 solver:

```bash
# Edit the file and replace email addresses
vim k3sinfra/infra/k3s/cert-manager/manifests/letsencrypt-prod-cloudflare.yaml
```

Update these values:
- `spec.acme.email`: Your email for Let's Encrypt notifications
- `solvers[1].dns01.cloudflare.email`: Your Cloudflare account email

Apply the ClusterIssuer:
```bash
kubectl apply -f k3sinfra/infra/k3s/cert-manager/manifests/letsencrypt-prod-cloudflare.yaml
```

Verify it's ready:
```bash
kubectl get clusterissuer letsencrypt-prod

# Expected output:
# NAME               READY   AGE
# letsencrypt-prod   True    5s
```

If not ready, check:
```bash
kubectl describe clusterissuer letsencrypt-prod
```

### 4. Apply Certificate

Now apply the wildcard certificate:

```bash
kubectl apply -f k3sinfra/apps/bareuptime-status-page/wildcard-certificate.yaml
```

### 5. Monitor Certificate Issuance

Check certificate status:
```bash
# Watch certificate creation
kubectl get certificate -n bareuptime-backend -w

# Detailed status
kubectl describe certificate bareuptime-online-wildcard-tls -n bareuptime-backend
```

Expected progression:
1. **Issuing** - cert-manager is requesting certificate
2. **Creating DNS record** - Cloudflare DNS challenge being created
3. **Validating** - Let's Encrypt is verifying DNS record
4. **Ready** - Certificate issued successfully

This typically takes 2-5 minutes for DNS propagation.

### 6. Check Certificate Secret

Once ready, verify the TLS secret exists:

```bash
kubectl get secret bareuptime-online-wildcard-tls -n bareuptime-backend

# View certificate details
kubectl get secret bareuptime-online-wildcard-tls -n bareuptime-backend -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -text -noout | grep -A2 "Subject Alternative Name"
```

Expected output should show:
```
X509v3 Subject Alternative Name:
    DNS:*.bareuptime.online, DNS:bareuptime.online
```

## Troubleshooting

### Issue 1: ClusterIssuer Not Ready

**Symptom**: `kubectl get clusterissuer` shows `READY: False`

**Check**:
```bash
kubectl describe clusterissuer letsencrypt-prod
```

**Common causes**:
- Invalid email format
- Missing Cloudflare secret
- ACME account registration failed

**Fix**: Check the error message in the Status section and correct the issue.

### Issue 2: Certificate Stuck in "Issuing"

**Symptom**: Certificate never becomes Ready

**Check logs**:
```bash
# cert-manager controller logs
kubectl logs -n cert-manager deployment/cert-manager --tail=100 -f

# Look for DNS-01 challenge logs
kubectl logs -n cert-manager deployment/cert-manager | grep -i dns01
```

**Common causes**:
- Invalid Cloudflare API token
- Token doesn't have DNS Edit permission for the zone
- DNS propagation taking longer than expected
- Rate limit hit (Let's Encrypt has limits)

**Fix**:
- Verify Cloudflare token permissions
- Wait longer (DNS can take 5-10 minutes in rare cases)
- Check Let's Encrypt rate limits: https://letsencrypt.org/docs/rate-limits/

### Issue 3: Certificate Ready but Ingress Not Using It

**Symptom**: Certificate shows Ready but HTTPS doesn't work

**Check ingress**:
```bash
kubectl get ingressroute -n bareuptime-backend backend-wildcard-subdomains -o yaml
```

**Verify**:
- `spec.tls.secretName` matches certificate secretName
- Secret exists in the same namespace as ingress
- Traefik is configured to use the secret

**Fix**:
```bash
# Restart Traefik to pick up new certificate
kubectl rollout restart deployment/traefik -n kube-system
```

### Issue 4: "Secret not found" Error

**Symptom**: Certificate shows Ready but secret doesn't exist

**This should not happen**, but if it does:

```bash
# Delete and recreate certificate
kubectl delete certificate bareuptime-online-wildcard-tls -n bareuptime-backend
kubectl apply -f k3sinfra/apps/bareuptime-status-page/wildcard-certificate.yaml
```

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│ User visits: https://example.bareuptime.online              │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Traefik Ingress (loads TLS from secret)                     │
│  - IngressRoute: backend-wildcard-subdomains                │
│  - TLS Secret: bareuptime-online-wildcard-tls               │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ cert-manager (manages certificate lifecycle)                │
│  - Certificate: bareuptime-online-wildcard-tls              │
│  - ClusterIssuer: letsencrypt-prod                          │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Let's Encrypt (issues certificate via DNS-01)               │
│  - Validates via Cloudflare DNS TXT record                  │
│  - Issues certificate for *.bareuptime.online               │
└──────────────────────────┬──────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────┐
│ Cloudflare (DNS provider)                                   │
│  - Creates _acme-challenge TXT record                       │
│  - Validates domain ownership                               │
└─────────────────────────────────────────────────────────────┘
```

## Certificate Renewal

cert-manager automatically renews certificates 30 days before expiration:
- Let's Encrypt certificates are valid for 90 days
- Renewal happens automatically at day 60
- No manual intervention needed

Monitor renewal:
```bash
# Check certificate expiry
kubectl get certificate -n bareuptime-backend bareuptime-online-wildcard-tls -o jsonpath='{.status.notAfter}'

# Watch for renewal in logs
kubectl logs -n cert-manager deployment/cert-manager | grep -i renew
```

## Security Notes

1. **Protect Cloudflare API Token**: This token has DNS edit permissions
   - Store as Kubernetes secret (never in Git)
   - Rotate regularly
   - Use minimum required permissions

2. **Certificate Storage**: TLS certificates are stored in Kubernetes secrets
   - Encrypted at rest if cluster encryption is enabled
   - Only accessible within the namespace

3. **ACME Account Key**: Let's Encrypt account key stored in cert-manager namespace
   - Secret name: `letsencrypt-prod`
   - Back this up for disaster recovery

## Quick Reference

```bash
# Check ClusterIssuer
kubectl get clusterissuer

# Check Certificate
kubectl get certificate -n bareuptime-backend

# Check TLS Secret
kubectl get secret bareuptime-online-wildcard-tls -n bareuptime-backend

# View cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager --tail=100

# Force certificate renewal
kubectl delete secret bareuptime-online-wildcard-tls -n bareuptime-backend
# cert-manager will recreate it automatically

# Check certificate expiry
kubectl get certificate -n bareuptime-backend -o json | jq -r '.items[] | "\(.metadata.name): \(.status.notAfter)"'
```

## References

- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Let's Encrypt Rate Limits](https://letsencrypt.org/docs/rate-limits/)
- [Cloudflare API Tokens](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [DNS-01 Challenge](https://letsencrypt.org/docs/challenge-types/#dns-01-challenge)
