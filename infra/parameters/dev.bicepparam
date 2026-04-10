// Development environment parameters.
// Uses smaller SKUs and enables all optional Azure services for full integration testing.
// Replace placeholder values with your actual subscription details.

using '../bicep/main.bicep'

// ── Identity ─────────────────────────────────────────────────────────────────
// az ad signed-in-user show --query id -o tsv
param currentUserObjectId = 'c73aea21-f7b0-441d-b0ea-4b855bc50a29'

// ── Location ──────────────────────────────────────────────────────────────────
param location = 'eastus'

// ── Naming ────────────────────────────────────────────────────────────────────
// 3–10 chars; becomes prefix for all resource names
param appEnvironment = 'dev'

// ── AKS ───────────────────────────────────────────────────────────────────────
// D2s_v3 = 2 vCPU / 8 GB RAM; fits student/dev subscription quotas
param aksNodePoolVMSize = 'Standard_D2s_v3'
param k8sNamespace = 'store-dev'

// ── Optional Azure services ────────────────────────────────────────────────────
param deployObservabilityTools = false  // Azure for Students restricts Log Analytics/Grafana; use in-cluster kube-prometheus-stack instead
param deployAzureContainerRegistry = true
param deployAzureServiceBus = true
param deployAzureCosmosDB = true
param cosmosDBAccountKind = 'GlobalDocumentDB'  // SQL API

// ── Azure OpenAI ──────────────────────────────────────────────────────────────
// Set to true only if your subscription has Azure OpenAI access.
// The OpenAI API key must be added to Key Vault manually after deploy.
param deployAzureOpenAI = false
param azureOpenAILocation = 'eastus'
param chatCompletionModelName = 'gpt-4o-mini'
param chatCompletionModelVersion = '2024-07-18'
param chatCompletionModelCapacity = 8
param deployImageGenerationModel = false
param imageGenerationModelName = 'dall-e-3'
param imageGenerationModelVersion = '3.0'
param imageGenerationModelCapacity = 1

// ── Network ───────────────────────────────────────────────────────────────────
// Your public IP — run: curl -s https://api.ipify.org
param currentIpAddress = '98.172.128.197/32'

// ── Source registry ───────────────────────────────────────────────────────────
// Used when deployAzureContainerRegistry=false; keep default for local dev
param sourceRegistry = 'ghcr.io/azure-samples'

// ── Tags ──────────────────────────────────────────────────────────────────────
param tags = {
  environment: 'dev'
  project: 'aks-store-demo'
  'managed-by': 'bicep'
  'azd-env-name': 'dev'
}
