#!/bin/bash
set -euo pipefail

NAMESPACE="argocd"
DOMAIN="argocd1.bareuptime.co"
ISSUER="letsencrypt-prod"
SECRET_NAME="argocd-tls-cert"

# Use K3s kubeconfig if present
if [ -z "${KUBECONFIG:-}" ] && [ -f /etc/rancher/k3s/k3s.yaml ]; then
    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
fi

cleanup() {
    echo "🧹 Cleaning up ArgoCD installation..."
    kubectl delete -f manifests/ingress.yaml -n ${NAMESPACE} --ignore-not-found
    kubectl delete namespace ${NAMESPACE} --ignore-not-found
    rm -f argocd-info.txt
    echo "✅ Cleanup complete!"
    exit 0
}

if [ "${1:-}" = "-d" ]; then
    cleanup
fi

echo "🚀 Installing ArgoCD..."

# Create namespace
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -

# Deploy ArgoCD core manifests
kubectl apply -n ${NAMESPACE} -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

echo "⏳ Waiting for ArgoCD server to be ready..."
kubectl wait --for=condition=available deployment/argocd-server -n ${NAMESPACE} --timeout=300s

echo "🟢 Ensuring cert-manager issuer exists..."
kubectl get clusterissuer ${ISSUER} >/dev/null

echo "🔐 Creating certificate ${SECRET_NAME}..."
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
spec:
  secretName: ${SECRET_NAME}
  issuerRef:
    name: ${ISSUER}
    kind: ClusterIssuer
  commonName: ${DOMAIN}
  dnsNames:
  - ${DOMAIN}
EOF

kubectl wait --for=condition=Ready certificate/${SECRET_NAME} -n ${NAMESPACE} --timeout=180s

echo "🌐 Applying ingress..."
kubectl apply -f manifests/ingress.yaml

echo "⚙️ Patching argocd-cm to set external URL..."
kubectl patch configmap argocd-cm -n ${NAMESPACE} \
  --type merge \
  -p "{\"data\":{\"url\":\"https://${DOMAIN}\"}}"

echo "🔁 Restarting argocd-server..."
kubectl rollout restart deployment argocd-server -n ${NAMESPACE}
kubectl rollout status deployment argocd-server -n ${NAMESPACE}

echo "🔑 Retrieving admin credentials..."
ARGOCD_PASSWORD=$(kubectl -n ${NAMESPACE} get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

cat > argocd-info.txt <<EOF
ArgoCD Installation Info
========================
URL: https://${DOMAIN}
Username: admin
Password: ${ARGOCD_PASSWORD}

CLI Login:
argocd login ${DOMAIN} --username admin --password ${ARGOCD_PASSWORD} --grpc-web
EOF

echo ""
echo "========================================="
echo "✅ ArgoCD installed successfully!"
echo "========================================="
echo "URL:      https://${DOMAIN}"
echo "Username: admin"
echo "Password: ${ARGOCD_PASSWORD}"
echo ""
echo "Credentials saved to: argocd-info.txt"
echo ""
echo "To cleanup: ./install.sh -d"
