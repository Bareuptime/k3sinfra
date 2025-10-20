#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up cert-manager installation..."

    # Delete ClusterIssuers
    kubectl delete -f manifests/letsencrypt-prod.yaml 2>/dev/null || true
    kubectl delete -f manifests/letsencrypt-staging.yaml 2>/dev/null || true

    # Uninstall cert-manager
    helm uninstall cert-manager -n cert-manager 2>/dev/null || true

    # Delete CRDs
    kubectl delete -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.crds.yaml 2>/dev/null || true

    # Delete namespace
    kubectl delete namespace cert-manager 2>/dev/null || true

    # Clean local files
    rm -f cert-manager-info.txt

    echo "✅ cert-manager cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing cert-manager in K3s..."

# Prompt for email (required for Let's Encrypt)
read -p "Enter email for Let's Encrypt notifications: " LETSENCRYPT_EMAIL

if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
  echo "Email cannot be empty"
  exit 1
fi

# Validate email format (basic check)
if ! [[ "$LETSENCRYPT_EMAIL" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
    echo "Invalid email format"
    exit 1
fi

# Add Jetstack Helm repo
echo "Adding Jetstack Helm repository..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update

# Create namespace
kubectl create namespace cert-manager --dry-run=client -o yaml | kubectl apply -f -

# Install cert-manager CRDs
echo "Installing cert-manager CRDs..."
kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.14.0/cert-manager.crds.yaml

# Install cert-manager
echo "Installing cert-manager via Helm..."
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --version v1.14.0 \
  --set installCRDs=false \
  --set global.leaderElection.namespace=cert-manager

echo "Waiting for cert-manager to be ready..."
kubectl wait --for=condition=available deployment/cert-manager -n cert-manager --timeout=300s
kubectl wait --for=condition=available deployment/cert-manager-webhook -n cert-manager --timeout=300s
kubectl wait --for=condition=available deployment/cert-manager-cainjector -n cert-manager --timeout=300s

# Create ClusterIssuer manifests
echo "Creating ClusterIssuer manifests..."

# Production Let's Encrypt ClusterIssuer
cat > manifests/letsencrypt-prod.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    # Let's Encrypt production server
    server: https://acme-v02.api.letsencrypt.org/directory
    email: $LETSENCRYPT_EMAIL
    # Secret to store the account private key
    privateKeySecretRef:
      name: letsencrypt-prod
    # Enable HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

# Staging Let's Encrypt ClusterIssuer (for testing)
cat > manifests/letsencrypt-staging.yaml <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    # Let's Encrypt staging server (for testing)
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: $LETSENCRYPT_EMAIL
    # Secret to store the account private key
    privateKeySecretRef:
      name: letsencrypt-staging
    # Enable HTTP-01 challenge provider
    solvers:
    - http01:
        ingress:
          class: traefik
EOF

# Apply ClusterIssuers
echo "Applying ClusterIssuers..."
kubectl apply -f manifests/letsencrypt-prod.yaml
kubectl apply -f manifests/letsencrypt-staging.yaml

# Wait a moment for ClusterIssuers to be created
sleep 5

# Check ClusterIssuer status
echo "Checking ClusterIssuer status..."
kubectl get clusterissuer

# Save info
cat > cert-manager-info.txt <<EOF
cert-manager Installation Info
==============================

Version: v1.14.0
Namespace: cert-manager
Email: $LETSENCRYPT_EMAIL

ClusterIssuers Created:
- letsencrypt-prod (Production - use for real domains)
- letsencrypt-staging (Staging - use for testing)

Usage in Ingress:
-----------------
Add this annotation to your Ingress resources:

  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"

Example Ingress:
----------------
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: example
  annotations:
    cert-manager.io/cluster-issuer: "letsencrypt-prod"
spec:
  tls:
  - hosts:
    - example.com
    secretName: example-tls-cert
  rules:
  - host: example.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: example-service
            port:
              number: 80

How It Works:
-------------
1. Create an Ingress with cert-manager annotation
2. cert-manager sees the annotation and creates a Certificate resource
3. Certificate requests a TLS cert from Let's Encrypt via ACME protocol
4. Let's Encrypt validates domain ownership using HTTP-01 challenge
5. Certificate is issued and stored in the secretName specified
6. Traefik uses the certificate for HTTPS

Commands:
---------
# Check cert-manager pods
kubectl get pods -n cert-manager

# View ClusterIssuers
kubectl get clusterissuer

# View Certificates
kubectl get certificate -A

# Check Certificate details
kubectl describe certificate <name> -n <namespace>

# View certificate request status
kubectl get certificaterequest -A

# Check cert-manager logs
kubectl logs -n cert-manager deployment/cert-manager

Troubleshooting:
----------------
# If certificate issuance fails, check:
kubectl describe certificate <name> -n <namespace>
kubectl describe certificaterequest <name> -n <namespace>
kubectl logs -n cert-manager deployment/cert-manager

# Common issues:
- DNS not pointing to cluster
- Firewall blocking port 80 (needed for HTTP-01 challenge)
- Rate limits (use staging issuer for testing)

Let's Encrypt Rate Limits:
---------------------------
Production:
- 50 certificates per registered domain per week
- 5 duplicate certificates per week

Staging: No rate limits (use for testing)

More Info:
----------
- cert-manager docs: https://cert-manager.io/docs/
- Let's Encrypt: https://letsencrypt.org/docs/
- Rate limits: https://letsencrypt.org/docs/rate-limits/

To cleanup: ./install.sh -d
EOF

echo ""
echo "========================================="
echo "✅ cert-manager installed successfully!"
echo "========================================="
echo ""
echo "Email: $LETSENCRYPT_EMAIL"
echo ""
echo "ClusterIssuers created:"
echo "  - letsencrypt-prod (Production)"
echo "  - letsencrypt-staging (Staging/Testing)"
echo ""
echo "Info saved to: cert-manager-info.txt"
echo ""
echo "Next steps:"
echo "1. Add cert-manager annotations to your Ingress resources"
echo "2. Certificates will be automatically requested and renewed"
echo ""
echo "To cleanup: ./install.sh -d"
