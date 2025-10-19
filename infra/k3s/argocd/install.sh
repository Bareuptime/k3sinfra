#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    echo "Using K3s kubeconfig: $KUBECONFIG"
fi

echo "Installing ArgoCD in K3s..."

# Create namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server --namespace argocd --timeout=300s

# Get initial admin password
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "ArgoCD installed successfully!"
echo ""
echo "Initial credentials:"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASSWORD"
echo ""
echo "Access ArgoCD:"
echo "1. Port-forward:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "   Open https://localhost:8080"
echo ""
echo "2. Or apply ingress:"
echo "   kubectl apply -f manifests/ingress.yaml"
echo "   Access at https://argocd.bareuptime.co"
echo ""
echo "Change password after first login!"

# Save credentials
cat > argocd-info.txt <<EOF
ArgoCD Installation Info
========================
Username: admin
Password: $ARGOCD_PASSWORD

Access:
- Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443
- Ingress URL: https://argocd.bareuptime.co

CLI Login:
argocd login argocd.bareuptime.co --username admin --password $ARGOCD_PASSWORD

Change password:
argocd account update-password
EOF

echo "Credentials saved to argocd-info.txt"
