#!/usr/bin/env bash
# bootstrap.sh — One-shot idempotent setup script for AKS Store Demo.
# Run this once after cloning the repo to provision all infrastructure and
# install all cluster add-ons.
#
# Prerequisites:
#   - az CLI (logged in: az login)
#   - kubectl
#   - helm (v3+)
#   - envsubst (gettext)
#
# Usage:
#   export AZURE_SUBSCRIPTION_ID=<sub-id>
#   export LOCATION=eastus
#   export APP_ENV=dev          # or prod
#   export CURRENT_USER_OID=$(az ad signed-in-user show --query id -o tsv)
#   export CURRENT_IP=$(curl -s https://api.ipify.org)/32
#   ./scripts/bootstrap.sh
#
# Optional flags:
#   --dry-run    Print az what-if instead of deploying infra
#   --skip-infra Skip Bicep deployment (useful when infra already exists)

set -euo pipefail

# ── Colour output ──────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${BLUE}[bootstrap]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
fail() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# ── Parse flags ────────────────────────────────────────────────────────────────
DRY_RUN=false
SKIP_INFRA=false
for arg in "$@"; do
  case $arg in
    --dry-run)    DRY_RUN=true ;;
    --skip-infra) SKIP_INFRA=true ;;
  esac
done

# ── Required env vars ──────────────────────────────────────────────────────────
: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID}"
: "${LOCATION:=eastus}"
: "${APP_ENV:=dev}"
: "${CURRENT_USER_OID:=$(az ad signed-in-user show --query id -o tsv 2>/dev/null || echo "")}"
: "${CURRENT_IP:=$(curl -s https://api.ipify.org 2>/dev/null)/32}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

log "Starting AKS Store Demo bootstrap"
log "  Subscription : $AZURE_SUBSCRIPTION_ID"
log "  Location     : $LOCATION"
log "  Environment  : $APP_ENV"
log "  Deployer OID : $CURRENT_USER_OID"
log "  Allowed IP   : $CURRENT_IP"

# ── Step 1: Set subscription ───────────────────────────────────────────────────
log "Setting active subscription..."
az account set --subscription "$AZURE_SUBSCRIPTION_ID"
ok "Subscription set"

# ── Step 2: Deploy Bicep infrastructure ───────────────────────────────────────
if [ "$SKIP_INFRA" = "true" ]; then
  warn "Skipping infrastructure deployment (--skip-infra)"
else
  PARAM_FILE="$REPO_ROOT/infra/parameters/${APP_ENV}.bicepparam"
  [ -f "$PARAM_FILE" ] || fail "Parameter file not found: $PARAM_FILE"

  if [ "$DRY_RUN" = "true" ]; then
    log "What-if preview (--dry-run)..."
    az deployment sub what-if \
      --location "$LOCATION" \
      --template-file "$REPO_ROOT/infra/bicep/main.bicep" \
      --parameters "$PARAM_FILE" \
      --parameters "currentUserObjectId=$CURRENT_USER_OID" \
                   "currentIpAddress=$CURRENT_IP"
    warn "--dry-run: no resources created"
    exit 0
  fi

  log "Deploying infrastructure (this takes ~15 minutes)..."
  DEPLOY_NAME="aks-store-demo-${APP_ENV}-$(date +%Y%m%d-%H%M%S)"
  DEPLOY_OUTPUT=$(az deployment sub create \
    --name "$DEPLOY_NAME" \
    --location "$LOCATION" \
    --template-file "$REPO_ROOT/infra/bicep/main.bicep" \
    --parameters "$PARAM_FILE" \
    --parameters "currentUserObjectId=$CURRENT_USER_OID" \
                 "currentIpAddress=$CURRENT_IP" \
    --query "properties.outputs" \
    --output json)

  AKS_NAME=$(echo "$DEPLOY_OUTPUT"    | jq -r '.AZURE_AKS_CLUSTER_NAME.value')
  RG_NAME=$(echo "$DEPLOY_OUTPUT"     | jq -r '.AZURE_RESOURCE_GROUP.value')
  ACR_NAME=$(echo "$DEPLOY_OUTPUT"    | jq -r '.AZURE_CONTAINER_REGISTRY_NAME.value')
  KV_NAME=$(echo "$DEPLOY_OUTPUT"     | jq -r '.AZURE_RESOURCENAME_SUFFIX.value' | sed 's/^/kv-/' | cut -c1-24)
  SB_HOST=$(echo "$DEPLOY_OUTPUT"     | jq -r '.AZURE_SERVICE_BUS_HOST.value')
  COSMOS_URI=$(echo "$DEPLOY_OUTPUT"  | jq -r '.AZURE_COSMOS_DATABASE_URI.value')

  ok "Infrastructure deployed"
  log "  AKS         : $AKS_NAME"
  log "  Resource RG : $RG_NAME"
  log "  ACR         : $ACR_NAME"
fi

# ── Step 3: Get AKS credentials ───────────────────────────────────────────────
log "Getting AKS credentials..."
AKS_NAME="${AKS_NAME:-$(az aks list --resource-group "$RG_NAME" --query "[0].name" -o tsv)}"
RG_NAME="${RG_NAME:-$(az group list --query "[?contains(name,'rg-')].name" -o tsv | head -1)}"
az aks get-credentials \
  --resource-group "$RG_NAME" \
  --name "$AKS_NAME" \
  --overwrite-existing
ok "kubectl context set to $AKS_NAME"

# ── Step 4: Create namespaces ─────────────────────────────────────────────────
log "Creating namespaces..."
for ns in argocd store-dev store-prod monitoring external-secrets ingress-nginx cert-manager; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done
# Apply Pod Security Standards labels
kubectl label namespace store-dev \
  pod-security.kubernetes.io/enforce=baseline \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite
kubectl label namespace store-prod \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite
ok "Namespaces created"

# ── Step 5: Install ArgoCD ────────────────────────────────────────────────────
log "Installing ArgoCD..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server\.insecure"=true \
  --wait --timeout 10m
ok "ArgoCD installed"

# ── Step 6: Install External Secrets Operator ─────────────────────────────────
log "Installing External Secrets Operator..."
helm repo add external-secrets https://charts.external-secrets.io 2>/dev/null || true
helm repo update external-secrets
helm upgrade --install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --set installCRDs=true \
  --wait --timeout 5m
ok "External Secrets Operator installed"

# ── Step 7: Install NGINX Ingress Controller ──────────────────────────────────
log "Installing NGINX Ingress Controller..."
helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx 2>/dev/null || true
helm repo update ingress-nginx
helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx \
  --set controller.replicaCount=2 \
  --set controller.nodeSelector."kubernetes\.io/os"=linux \
  --wait --timeout 5m
ok "NGINX Ingress Controller installed"

# ── Step 8: Install cert-manager ──────────────────────────────────────────────
log "Installing cert-manager..."
helm repo add jetstack https://charts.jetstack.io 2>/dev/null || true
helm repo update jetstack
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --set installCRDs=true \
  --wait --timeout 5m

# Apply Let's Encrypt ClusterIssuer
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-http
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: admin@example.com
    privateKeySecretRef:
      name: letsencrypt-http-issuer-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: nginx
EOF
ok "cert-manager installed + ClusterIssuer created"

# ── Step 9: Install kube-prometheus-stack ────────────────────────────────────
log "Installing kube-prometheus-stack (Prometheus + Grafana)..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set grafana.adminPassword=changeme \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 10m
ok "kube-prometheus-stack installed"

# ── Step 10: Apply ArgoCD root Application ────────────────────────────────────
log "Applying ArgoCD root Application..."
kubectl apply -f "$REPO_ROOT/gitops/apps/root-app.yaml" -n argocd
ok "ArgoCD root-app applied — ArgoCD will now sync all services"

# ── Step 11: Print summary ────────────────────────────────────────────────────
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d 2>/dev/null || echo "<not available yet>")

INGRESS_IP=$(kubectl get svc ingress-nginx-controller \
  -n ingress-nginx \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "<pending>")

echo ""
echo "═══════════════════════════════════════════════════"
echo "  AKS Store Demo — Bootstrap Complete!"
echo "═══════════════════════════════════════════════════"
echo "  Cluster     : $AKS_NAME"
echo "  Ingress IP  : $INGRESS_IP"
echo ""
echo "  ArgoCD:"
echo "    kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "    User: admin"
echo "    Pass: $ARGOCD_PASSWORD"
echo ""
echo "  Grafana:"
echo "    kubectl port-forward svc/kube-prometheus-stack-grafana -n monitoring 3000:80"
echo "    User: admin  Pass: changeme"
echo ""
if [ -n "${ACR_NAME:-}" ]; then
echo "  ACR         : ${ACR_NAME}.azurecr.io"
fi
if [ -n "${SB_HOST:-}" ]; then
echo "  Service Bus : ${SB_HOST}"
fi
echo ""
echo "  Next steps:"
echo "  1. Add DNS A record: store.<domain> → $INGRESS_IP"
echo "  2. Add OpenAI key: az keyvault secret set --vault-name $KV_NAME --name openai-api-key --value <key>"
echo "  3. Update k8s/overlays/dev/kustomization.yaml: replace <ACR_NAME> with $ACR_NAME"
echo "  4. Watch ArgoCD sync: kubectl get applications -n argocd -w"
echo "═══════════════════════════════════════════════════"
