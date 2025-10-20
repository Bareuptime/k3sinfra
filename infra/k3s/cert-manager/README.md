# cert-manager for K3s

Automatic TLS certificate management using Let's Encrypt.

## What is cert-manager?

cert-manager automates the management and issuance of TLS certificates from various sources (Let's Encrypt, HashiCorp Vault, Venafi, etc.). It ensures certificates are valid and up-to-date, and attempts to renew certificates before expiry.

## Quick Start

```bash
./install.sh
```

You'll be prompted for an email address (required by Let's Encrypt for expiry notifications).

## What Gets Installed

1. **cert-manager** (v1.14.0)
   - Controller for managing certificates
   - Webhook for validation
   - CA Injector for CA bundle management

2. **ClusterIssuers**
   - `letsencrypt-prod` - Production Let's Encrypt (use for real domains)
   - `letsencrypt-staging` - Staging Let's Encrypt (use for testing)

## Usage

### Basic Ingress with TLS

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - myapp.example.com
    secretName: myapp-tls-cert
  rules:
  - host: myapp.example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: myapp
            port:
              number: 80
```

**That's it!** cert-manager will:
1. See the annotation and create a Certificate resource
2. Request a certificate from Let's Encrypt
3. Validate domain ownership via HTTP-01 challenge
4. Store the certificate in `myapp-tls-cert` secret
5. Auto-renew before expiry

### Using Staging for Testing

When testing, use the staging issuer to avoid rate limits:

```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-staging"
```

**Note**: Staging certificates will show browser warnings (not trusted). Switch to `letsencrypt-prod` for production.

## How It Works

```
1. Create Ingress with cert-manager annotation
   │
   ▼
2. cert-manager detects annotation
   │
   ▼
3. Creates Certificate resource
   │
   ▼
4. Requests cert from Let's Encrypt (ACME)
   │
   ▼
5. Let's Encrypt issues HTTP-01 challenge
   │  (Creates temporary HTTP endpoint)
   │
   ▼
6. Let's Encrypt validates domain ownership
   │  (Accesses http://domain/.well-known/acme-challenge/...)
   │
   ▼
7. Certificate issued and stored in Secret
   │
   ▼
8. Traefik reads Secret and serves HTTPS
   │
   ▼
9. Auto-renewal ~30 days before expiry
```

## Monitoring

### Check Certificate Status

```bash
# List all certificates
kubectl get certificate -A

# Describe a certificate
kubectl describe certificate myapp-tls-cert -n default

# Check certificate details
kubectl get secret myapp-tls-cert -n default -o yaml
```

### Check cert-manager Logs

```bash
# Controller logs
kubectl logs -n cert-manager deployment/cert-manager -f

# Webhook logs
kubectl logs -n cert-manager deployment/cert-manager-webhook -f
```

### View ClusterIssuers

```bash
kubectl get clusterissuer

# Should show:
# NAME                   READY   AGE
# letsencrypt-prod       True    5m
# letsencrypt-staging    True    5m
```

## Troubleshooting

### Certificate Not Issuing

```bash
# Check Certificate status
kubectl describe certificate myapp-tls-cert -n default

# Check CertificateRequest
kubectl get certificaterequest -n default
kubectl describe certificaterequest <name> -n default

# Check challenges
kubectl get challenge -A
kubectl describe challenge <name> -n default
```

### Common Issues

#### 1. DNS Not Configured
**Error**: Challenge fails with "connection refused"

**Solution**: Ensure DNS points to your cluster's external IP:
```bash
# Check DNS
dig myapp.example.com

# Should return your cluster IP
```

#### 2. Port 80 Not Accessible
**Error**: Challenge fails with "timeout"

**Solution**: Let's Encrypt needs HTTP (port 80) access for validation:
- Check firewall allows port 80
- Ensure Traefik is listening on port 80
- Verify no other service is using port 80

#### 3. Rate Limit Exceeded
**Error**: "too many certificates already issued"

**Solution**: Let's Encrypt has rate limits:
- **50 certs per domain per week**
- **5 duplicate certs per week**

Use staging issuer for testing:
```yaml
annotations:
  cert-manager.io/cluster-issuer: "letsencrypt-staging"
```

#### 4. Invalid Email
**Error**: ClusterIssuer not ready

**Solution**: Verify email in ClusterIssuer:
```bash
kubectl get clusterissuer letsencrypt-prod -o yaml
```

### Force Certificate Renewal

```bash
# Delete certificate and secret
kubectl delete certificate myapp-tls-cert -n default
kubectl delete secret myapp-tls-cert -n default

# cert-manager will recreate automatically
```

## Let's Encrypt Rate Limits

### Production (letsencrypt-prod)
- **50** certificates per registered domain per week
- **5** duplicate certificates per week
- **300** new orders per account per 3 hours
- **10** failed validations per account per hour

### Staging (letsencrypt-staging)
- **No rate limits** - use for testing!
- Certificates show browser warnings (not trusted)

More info: https://letsencrypt.org/docs/rate-limits/

## Advanced Configuration

### Using with Multiple Domains

```yaml
spec:
  tls:
  - hosts:
    - example.com
    - www.example.com
    - api.example.com
    secretName: example-tls-cert
```

### Custom Certificate Duration

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: myapp-cert
spec:
  secretName: myapp-tls-cert
  duration: 2160h # 90 days
  renewBefore: 720h # 30 days
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - myapp.example.com
```

### Wildcard Certificates

**Note**: Wildcard certs require DNS-01 challenge (not supported in this basic setup).

For wildcards, you need:
1. DNS provider integration (Cloudflare, Route53, etc.)
2. DNS-01 solver configuration

Example with Cloudflare:
```yaml
spec:
  acme:
    solvers:
    - dns01:
        cloudflare:
          email: user@example.com
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
```

## Architecture

```
┌─────────────────────────────────────────────────┐
│  cert-manager Namespace                         │
│                                                  │
│  ┌─────────────────┐  ┌──────────────────┐     │
│  │  cert-manager   │  │  cert-manager    │     │
│  │   Controller    │  │    Webhook       │     │
│  │                 │  │                  │     │
│  │  Watches:       │  │  Validates:      │     │
│  │  - Ingress      │  │  - Certificate   │     │
│  │  - Certificate  │  │  - Challenge     │     │
│  └─────────────────┘  └──────────────────┘     │
│                                                  │
│  ┌──────────────────┐                           │
│  │  cert-manager    │                           │
│  │   CAInjector     │                           │
│  │                  │                           │
│  │  Injects CA:     │                           │
│  │  - Webhooks      │                           │
│  │  - APIServices   │                           │
│  └──────────────────┘                           │
└─────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────┐
│  ClusterIssuers (Cluster-wide)                  │
│                                                  │
│  ┌─────────────────────┐  ┌───────────────────┐│
│  │ letsencrypt-prod    │  │ letsencrypt-      ││
│  │                     │  │    staging        ││
│  │ ACME Server:        │  │                   ││
│  │ Let's Encrypt Prod  │  │ ACME Server:      ││
│  │                     │  │ LE Staging        ││
│  │ Solver: HTTP-01     │  │                   ││
│  │ via Traefik         │  │ Solver: HTTP-01   ││
│  └─────────────────────┘  └───────────────────┘│
└─────────────────────────────────────────────────┘

                        ▼

┌─────────────────────────────────────────────────┐
│  Application Namespace (e.g., default)          │
│                                                  │
│  ┌──────────────┐                               │
│  │   Ingress    │◄── User creates              │
│  │   + Annotation   │                           │
│  └──────┬───────┘                               │
│         │                                        │
│         ▼                                        │
│  ┌──────────────┐◄── cert-manager creates      │
│  │ Certificate  │                               │
│  └──────┬───────┘                               │
│         │                                        │
│         ▼                                        │
│  ┌──────────────┐◄── cert-manager creates      │
│  │   Secret     │    (stores TLS cert)          │
│  │  (TLS cert)  │                               │
│  └──────┬───────┘                               │
│         │                                        │
│         ▼                                        │
│  ┌──────────────┐                               │
│  │   Traefik    │◄── Reads secret and serves   │
│  │   (HTTPS)    │    HTTPS                      │
│  └──────────────┘                               │
└─────────────────────────────────────────────────┘
```

## Security Considerations

1. **Private Keys**: cert-manager generates private keys for certificates. Keep the namespace secure.

2. **ACME Account Key**: Stored in secrets `letsencrypt-prod` and `letsencrypt-staging` in cert-manager namespace.

3. **RBAC**: cert-manager requires cluster-wide permissions to watch Ingress and create Secrets.

4. **Email Privacy**: Your email is registered with Let's Encrypt for expiry notifications.

## Backup and Recovery

### Backup ACME Account Keys

```bash
# Backup production account key
kubectl get secret letsencrypt-prod -n cert-manager -o yaml > letsencrypt-prod-backup.yaml

# Backup staging account key
kubectl get secret letsencrypt-staging -n cert-manager -o yaml > letsencrypt-staging-backup.yaml
```

### Restore

```bash
kubectl apply -f letsencrypt-prod-backup.yaml
kubectl apply -f letsencrypt-staging-backup.yaml
```

## Uninstall

```bash
./install.sh -d
```

This will:
- Delete ClusterIssuers
- Uninstall cert-manager
- Delete CRDs
- Delete namespace
- **Note**: Existing certificates in application namespaces are preserved

## References

- **cert-manager docs**: https://cert-manager.io/docs/
- **Let's Encrypt**: https://letsencrypt.org/
- **ACME Protocol**: https://datatracker.ietf.org/doc/html/rfc8555
- **Rate Limits**: https://letsencrypt.org/docs/rate-limits/
- **K3s + cert-manager**: https://cert-manager.io/docs/installation/kubectl/

## Examples

See the `/examples` directory for complete working examples:
- Basic HTTP to HTTPS redirect
- Multiple domains on one certificate
- Custom certificate resources
- Integration with external DNS
