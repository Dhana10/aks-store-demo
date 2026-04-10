# AKS Store Demo — Production-Grade Deployment Architecture

## 1. Architecture Overview

```
┌──────────────────────────────────────────────────────────────────────────────────┐
│                             GitHub Repository                                     │
│  src/ (8 microservices)  ── push/PR ─────────────────────────────────────────►   │
│  infra/bicep/            ── infra changes ───────────────────────────────────►   │
│  gitops/                 ◄── image tag updates (CD writes back) ──────────────   │
└───────────────────────────────────────────────────────────────────────────────────┘
          │ PR                    │ push main                   │ git tag v*
          ▼                       ▼                             ▼
 .github/workflows/ci.yml  cd-dev.yml (build+push)     cd-prod.yml (promote)
 (lint, test, build only)  updates gitops/dev/          updates gitops/prod/
          │                       │                             │
          │                       ▼                             ▼
          │              Azure Container Registry          (same ACR, new tags)
          │              (Premium, admin disabled)
          │                       │
          └───────────────────────┘
                                  │
                                  ▼
                          AKS Cluster (OIDC + Workload Identity)
                          ├── Node Pool: system  (Standard_D2s_v3 ×2, tainted)
                          └── Node Pool: user    (Standard_D4s_v3, autoscale 2–10)
                               │
              ┌────────────────┼──────────────────┬──────────────────┐
              ▼                ▼                  ▼                  ▼
        Namespace:        Namespace:         Namespace:        Namespace:
        argocd            store-dev          store-prod        monitoring
        ──────────        ──────────         ──────────        ──────────
        ArgoCD            order-svc          order-svc         Prometheus
        (watches          makeline-svc       makeline-svc      Grafana
         gitops/)         product-svc        product-svc
                          ai-svc             ai-svc
                          store-front  ──►   store-front ──► Azure Load Balancer
                          store-admin  ──►   store-admin ──► NGINX Ingress
                          virtual-cust       (no simulators
                          virtual-wrkr        in prod)

Azure Services (all tagged: environment, project=aks-store-demo, managed-by=bicep):
├── Azure Container Registry (Premium)          acr-<suffix>.azurecr.io
├── Azure Service Bus (Standard)                <suffix>.servicebus.windows.net
│     └── Queue: orders
├── Azure CosmosDB (SQL API)                    <suffix>.documents.azure.com
│     └── Database: orderdb / Container: orders
├── Azure Key Vault (RBAC auth)                 kv-<suffix>.vault.azure.net
│     ├── Secret: sb-connection-string
│     ├── Secret: cosmos-endpoint
│     └── Secret: openai-api-key
├── AKS Cluster (Cilium CNI, OIDC)
├── Log Analytics Workspace
├── Application Insights (one per service)
├── Azure Monitor / Grafana Dashboard
└── Managed Identities (3: order-svc, makeline-svc, ai-svc)
      └── Federated credentials → AKS OIDC issuer
```

---

## 2. Azure Infrastructure (Bicep)

All modules use Azure Verified Modules (AVM) from `br/public:avm/...`.

### Existing modules (not modified)
| Module | Purpose |
|--------|---------|
| `infra/bicep/main.bicep` | Subscription-scoped orchestrator |
| `infra/bicep/kubernetes.bicep` | AKS cluster (Cilium, OIDC, Workload Identity) |
| `infra/bicep/cosmosdb.bicep` | CosmosDB SQL API / MongoDB API |
| `infra/bicep/servicebus.bicep` | Azure Service Bus + queue |
| `infra/bicep/openai.bicep` | Azure OpenAI (GPT + DALL-E) |
| `infra/bicep/observability.bicep` | Log Analytics + Azure Monitor + Grafana |
| `infra/bicep/workloadidentity.bicep` | User-assigned managed identity + federated credentials |

### New modules
| Module | Purpose |
|--------|---------|
| `infra/bicep/rg.bicep` | Standalone resource group (subscription scope) |
| `infra/bicep/acr.bicep` | ACR Premium, admin disabled, AcrPull to kubelet identity |
| `infra/bicep/keyvault.bicep` | Key Vault RBAC, secrets, grants to managed identities |
| `infra/bicep/identity.bicep` | Three per-service managed identities + role assignments |

### Parameters
| File | Environment |
|------|-------------|
| `infra/parameters/dev.bicepparam` | dev (smaller SKUs, optional features on) |
| `infra/parameters/prod.bicepparam` | prod (larger SKUs, all features on) |

---

## 3. AKS Cluster Design

| Attribute | Value |
|-----------|-------|
| CNI | Azure CNI overlay + Cilium |
| Network Policy | Cilium |
| OIDC Issuer | Enabled |
| Workload Identity | Enabled |
| Key Vault Secret Provider | Enabled |
| AAD RBAC | Enabled |
| OS Upgrade Channel | SecurityPatch |

### Node Pools
| Pool | SKU | Count | Mode |
|------|-----|-------|------|
| system | Standard_D2s_v3 | 2 (fixed) | System |
| user | Standard_D4s_v3 | 2–10 (autoscale) | User |

### Namespaces
| Namespace | Purpose | Pod Security Standard |
|-----------|---------|----------------------|
| `argocd` | ArgoCD GitOps controller | baseline |
| `store-dev` | Development environment | baseline |
| `store-prod` | Production environment | restricted |
| `monitoring` | Prometheus + Grafana | baseline |

### Ingress
- NGINX Ingress Controller (Helm, `ingress-nginx` namespace)
- cert-manager (Helm, `cert-manager` namespace) + Let's Encrypt ClusterIssuer
- store-front → `store.<domain>`
- store-admin → `admin.<domain>`
- ArgoCD UI → `argocd.<domain>`
- Grafana → `grafana.<domain>`

---

## 4. GitOps with ArgoCD

### App-of-Apps pattern
```
gitops/apps/root-app.yaml          ← Applied manually once (bootstrap)
  └── watches: gitops/apps/dev/    ← Spawns per-service ArgoCD Applications
        ├── order-service.yaml     ← source.path: k8s/overlays/dev
        ├── makeline-service.yaml
        ├── product-service.yaml
        ├── ai-service.yaml
        ├── store-front.yaml
        ├── store-admin.yaml
        ├── virtual-customer.yaml
        └── virtual-worker.yaml
gitops/apps/prod/                  ← Same, points to k8s/overlays/prod
```

### Image tag promotion flow
```
CI (cd-dev.yml) pushes image → updates gitops/dev/values-<svc>.yaml (image.tag)
ArgoCD detects change → syncs k8s/overlays/dev → pods restarted with new image

cd-prod.yml (on git tag v*) → copies dev values to prod values
ArgoCD detects change → syncs k8s/overlays/prod (requires GitHub Environment approval)
```

### Sync policy
- `automated: {prune: true, selfHeal: true}` on all Applications
- `syncOptions: [CreateNamespace=true, ServerSideApply=true]`

---

## 5. Kubernetes Manifests per Service

All base manifests live in `k8s/base/<service>/` with Kustomize.

### Common security context (all containers)
```yaml
securityContext:
  runAsNonRoot: true
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: [ALL]
```

### Service manifest summary
| Service | HPA | PDB | ExternalSecret | Ingress | Workload Identity |
|---------|-----|-----|----------------|---------|-------------------|
| order-service | ✓ (2–10) | ✓ | ✓ (sb-connection-string) | — | ✓ |
| makeline-service | ✓ (2–8) | ✓ | ✓ (cosmos-endpoint) | — | ✓ |
| product-service | — | ✓ | — | — | — |
| ai-service | — | ✓ | ✓ (openai-api-key) | — | ✓ |
| store-front | ✓ (2–10) | ✓ | — | ✓ | — |
| store-admin | ✓ (2–8) | ✓ | — | ✓ | — |
| virtual-customer | — | — | — | — | — |
| virtual-worker | — | — | — | — | — |

### Environment variables (production values)
| Service | Variable | Source |
|---------|----------|--------|
| order-service | `USE_WORKLOAD_IDENTITY_AUTH` | ConfigMap |
| order-service | `AZURE_SERVICEBUS_FULLYQUALIFIEDNAMESPACE` | ConfigMap |
| order-service | `ORDER_QUEUE_NAME` | ConfigMap (orders) |
| makeline-service | `ORDER_DB_API` | ConfigMap (cosmosdbsql) |
| makeline-service | `AZURE_COSMOS_RESOURCEENDPOINT` | ConfigMap |
| makeline-service | `ORDER_DB_NAME` | ConfigMap (orderdb) |
| makeline-service | `ORDER_DB_CONTAINER_NAME` | ConfigMap (orders) |
| makeline-service | `USE_WORKLOAD_IDENTITY_AUTH` | ConfigMap |
| ai-service | `USE_AZURE_OPENAI` | ConfigMap (True) |
| ai-service | `USE_AZURE_AD` | ConfigMap (true) |
| ai-service | `AZURE_OPENAI_ENDPOINT` | ConfigMap |
| ai-service | `AZURE_OPENAI_DEPLOYMENT_NAME` | ConfigMap |
| ai-service | `OPENAI_API_KEY` | ExternalSecret → Key Vault |
| product-service | `AI_SERVICE_URL` | ConfigMap |
| store-front/admin | `APPINSIGHTS_CONNECTIONSTRING` | ConfigMap |
| virtual-customer | `ORDER_SERVICE_URL` | ConfigMap |
| virtual-worker | `MAKELINE_SERVICE_URL` | ConfigMap |

---

## 6. CI/CD with GitHub Actions

### Workflow files
| File | Trigger | Purpose |
|------|---------|---------|
| `.github/workflows/ci.yml` | PR to main (src/**) | Lint, unit-test, docker build (no push) |
| `.github/workflows/cd-dev.yml` | Push to main (src/**) | Build → push ACR → update gitops/dev/ |
| `.github/workflows/cd-prod.yml` | git tag `v*` | Promote dev → prod image tags |
| `.github/workflows/infra.yml` | Push to main (infra/**) | Bicep lint → what-if → deploy |

### Authentication
- All workflows use **OIDC federated credentials** (`azure/login@v2` with `client-id`, `tenant-id`, `subscription-id`)
- No stored service principal passwords
- `cd-prod.yml` uses GitHub **Environment: production** (requires reviewer approval)

### Image tag convention
- Dev: `sha-<8-char-sha>` (e.g., `sha-a1b2c3d4`)
- Prod: git tag version (e.g., `v1.2.3`)

---

## 7. Security Design

| Control | Implementation |
|---------|----------------|
| No secrets in Git | All secrets in Key Vault; synced via External Secrets Operator |
| Workload Identity | order-service, makeline-service, ai-service use federated credentials |
| Network policy | Default-deny baseline in all namespaces; explicit per-service ingress rules |
| Pod Security Standards | `baseline` on store-dev; `restricted` on store-prod |
| Container security | `runAsNonRoot`, `readOnlyRootFilesystem`, `drop: ALL` |
| ACR access | Admin disabled; AcrPull role to kubelet managed identity only |
| Image scanning | Microsoft Defender for Containers (enabled on ACR) |
| Base image patching | ACR Tasks (automated base image rebuild) |
| GitHub Actions | OIDC only; prod requires Environment approval |
| Key Vault | RBAC auth (not access policies); purge protection on |

---

## 8. Observability

| Tool | Deployment | Access |
|------|-----------|--------|
| Azure Monitor | kubernetes.bicep (configureMonitorSettings=true) | Azure Portal |
| Log Analytics | observability.bicep | Azure Portal |
| Application Insights | ConfigMap per service (`APPINSIGHTS_CONNECTIONSTRING`) | Azure Portal |
| Prometheus | kube-prometheus-stack Helm chart (monitoring ns) | Internal |
| Grafana | kube-prometheus-stack + Azure Managed Grafana | `grafana.<domain>` |
| ArgoCD UI | Helm + Ingress | `argocd.<domain>` |

### Application Insights env vars (per service)
```
APPINSIGHTS_CONNECTIONSTRING   — connection string from Key Vault or ConfigMap
APPLICATIONINSIGHTS_ROLE_NAME  — service name (e.g., order-service)
```

---

## 9. Implementation Order

1. Deploy Bicep infrastructure: `az deployment sub create --template-file infra/bicep/main.bicep --parameters infra/parameters/dev.bicepparam`
2. Get AKS credentials: `az aks get-credentials`
3. Install ArgoCD via Helm
4. Apply root ArgoCD Application: `kubectl apply -f gitops/apps/root-app.yaml`
5. Install External Secrets Operator via Helm
6. Install NGINX Ingress Controller via Helm
7. Install cert-manager + apply ClusterIssuer
8. Install kube-prometheus-stack via Helm
9. Add secrets to Key Vault manually (OpenAI key, any override values)
10. ArgoCD syncs all services automatically

Run the one-shot script: `./scripts/bootstrap.sh`

---

## 10. Open Questions / Assumptions

| # | Assumption |
|---|-----------|
| 1 | **OpenAI key** must be manually added to Key Vault after deploy: `az keyvault secret set --vault-name <kv> --name openai-api-key --value <key>` |
| 2 | **Domain name** must be pre-configured in DNS. cert-manager uses Let's Encrypt HTTP-01. For dev, nip.io wildcard works. |
| 3 | **GitHub OIDC**: `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, `AZURE_SUBSCRIPTION_ID` must be set as GitHub repository secrets before first workflow run. |
| 4 | **virtual-customer and virtual-worker** are deployed to store-dev only (load simulators; not needed in prod). |
| 5 | **ai-service** is optional in prod; its ArgoCD Application uses `automated.prune: false` so it can be disabled without removing other services. |
| 6 | **CosmosDB SQL API** (`ORDER_DB_API=cosmosdbsql`) is the default; MongoDB API is supported by setting `cosmosDBAccountKind=MongoDB` in Bicep params. |
| 7 | **ACR** is provisioned by `kubernetes.bicep` when `deployAcr=true`; `infra/bicep/acr.bicep` is a standalone reference module for explicit ACR-only deployments. |
| 8 | **AKS node count**: system pool uses 2 nodes (down from existing default of 3) to fit student/dev subscription quotas. |
