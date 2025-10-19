#!/bin/bash
set -euo pipefail

# Setup K3s kubeconfig
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

# Cleanup function
cleanup() {
    echo "Cleaning up ArgoCD installation..."

    # Delete applications first
    kubectl delete -f manifests/application.yaml 2>/dev/null || true
    kubectl delete -f manifests/app-ingress.yaml 2>/dev/null || true

    # Delete ingress
    kubectl delete -f manifests/ingress.yaml 2>/dev/null || true

    # Delete ArgoCD installation
    kubectl delete -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml 2>/dev/null || true

    # Delete namespace
    kubectl delete namespace argocd 2>/dev/null || true

    # Clean local files
    rm -f argocd-info.txt

    echo "✅ ArgoCD cleanup complete!"
    exit 0
}

# Check for cleanup flag
if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "Installing ArgoCD in K3s..."

# Create namespace
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

# Install ArgoCD
echo "Deploying ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD to be ready..."
sleep 20
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

# Apply ingress
echo "Applying ingress..."
kubectl apply -f manifests/ingress.yaml

# Get admin password
echo "Retrieving admin credentials..."
sleep 5
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Save credentials
cat > argocd-info.txt <<EOF
ArgoCD Installation Info
========================
Username: admin
Password: $ARGOCD_PASSWORD

Access: https://argocd.bareuptime.co

CLI Login:
argocd login argocd.bareuptime.co --username admin --password $ARGOCD_PASSWORD

Change password:
argocd account update-password
EOF

echo ""
echo "========================================="
echo "✅ ArgoCD installed successfully!"
echo "========================================="
echo ""
echo "URL:      https://argocd.bareuptime.co"
echo "Username: admin"
echo "Password: $ARGOCD_PASSWORD"
echo ""
echo "Credentials saved to: argocd-info.txt"
echo ""
echo "To cleanup: ./install.sh -d"
