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

setup_https() {
    echo "🚀 Fixing ArgoCD HTTPS (Traefik + Cert-Manager + ArgoCD integration)"
    
    NAMESPACE="argocd"
    DOMAIN="argocd.bareuptime.co"
    ISSUER="letsencrypt-prod"
    SECRET_NAME="argocd-tls-cert"

    echo "🟢 Ensuring cert-manager ClusterIssuer '${ISSUER}' exists..."
    kubectl get clusterissuer "${ISSUER}" >/dev/null

    echo "🟢 Creating Certificate in namespace ${NAMESPACE}..."
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

    echo "⏳ Waiting for certificate issuance..."
    kubectl wait --for=condition=Ready certificate/${SECRET_NAME} -n ${NAMESPACE} --timeout=180s

    echo "🟢 Patching argocd-server service to expose HTTPS port..."
    kubectl patch svc argocd-server -n ${NAMESPACE} \
    --type='json' \
    -p='[{"op":"add","path":"/spec/ports/-","value":{"name":"https","port":443,"targetPort":8080}}]' || true

    echo "🟢 Editing argocd-server deployment to use TLS..."
    kubectl patch deployment argocd-server -n ${NAMESPACE} --type='json' -p='[
    {"op":"remove","path":"/spec/template/spec/containers/0/command/3"},
    {"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--tls-cert"},
    {"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"/app/config/tls/tls.crt"},
    {"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"--tls-key"},
    {"op":"add","path":"/spec/template/spec/containers/0/command/-","value":"/app/config/tls/tls.key"},
    {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"tls-secret","secret":{"secretName":"'${SECRET_NAME}'"}}},
    {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"tls-secret","mountPath":"/app/config/tls"}}
    ]'

    echo "🟢 Updating ingress for Traefik TLS passthrough..."
    kubectl annotate ingress argocd-server-ingress -n ${NAMESPACE} \
    traefik.ingress.kubernetes.io/router.tls=true \
    traefik.ingress.kubernetes.io/router.tls.passthrough=true \
    traefik.ingress.kubernetes.io/service.serversscheme=https --overwrite

    echo "🟢 Pointing ingress TLS section to new certificate secret..."
    kubectl patch ingress argocd-server-ingress -n ${NAMESPACE} --type='json' \
    -p='[{"op":"replace","path":"/spec/tls/0/secretName","value":"'${SECRET_NAME}'"},{"op":"replace","path":"/spec/rules/0/http/paths/0/backend/service/port/number","value":443}]'

    echo "🔁 Restarting argocd-server deployment..."
    kubectl rollout restart deployment argocd-server -n ${NAMESPACE}

    echo "⏳ Waiting for pods to be ready..."
    kubectl rollout status deployment argocd-server -n ${NAMESPACE}

    echo "✅ ArgoCD HTTPS setup completed successfully!"
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

# Setup HTTPS
setup_https

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