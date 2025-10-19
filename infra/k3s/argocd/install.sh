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
echo "Deploying ArgoCD..."
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "Waiting for ArgoCD pods to start..."
sleep 15

# Wait for ArgoCD server deployment to be available
kubectl wait --for=condition=available deployment/argocd-server -n argocd --timeout=300s

echo "Configuring ArgoCD for ingress access..."

# Configure ArgoCD to run in insecure mode (HTTP internally, Traefik handles HTTPS)
kubectl apply -f manifests/argocd-server-insecure.yaml

# Restart ArgoCD server to apply configuration
echo "Restarting ArgoCD server..."
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=300s

# Apply ingress configuration
echo "Applying ingress configuration..."
kubectl apply -f manifests/ingress.yaml

# Get initial admin password
echo "Retrieving admin credentials..."
sleep 5
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo ""
echo "========================================="
echo "ArgoCD installed successfully!"
echo "========================================="
echo ""
echo "Access ArgoCD at: https://argocd.bareuptime.co"
echo ""
echo "Initial credentials:"
echo "  Username: admin"
echo "  Password: $ARGOCD_PASSWORD"
echo ""
echo "Note: It may take 1-2 minutes for:"
echo "  - DNS to propagate"
echo "  - Let's Encrypt certificate to be issued"
echo ""
echo "Change password after first login!"
echo ""

# Save credentials
cat > argocd-info.txt <<EOF
ArgoCD Installation Info
========================
Username: admin
Password: $ARGOCD_PASSWORD

Access:
- URL: https://argocd.bareuptime.co
- Port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:80

CLI Login:
argocd login argocd.bareuptime.co --username admin --password $ARGOCD_PASSWORD

Change password:
argocd account update-password

Deployed applications:
kubectl apply -f manifests/application.yaml
EOF

echo "Credentials saved to argocd-info.txt"
echo ""
echo "To deploy your application:"
echo "  kubectl apply -f manifests/application.yaml"
