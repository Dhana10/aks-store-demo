// Production environment parameters.
// Uses larger SKUs, all Azure services enabled, stricter security settings.
// Values marked <REPLACE> must be set before deploying to production.

using '../bicep/main.bicep'

// ── Identity ─────────────────────────────────────────────────────────────────
// Service principal or managed identity used by the GitHub Actions runner
param currentUserObjectId = '<PROD_DEPLOYER_OBJECT_ID>'

// ── Location ──────────────────────────────────────────────────────────────────
param location = 'eastus'

// ── Naming ────────────────────────────────────────────────────────────────────
param appEnvironment = 'prod'

// ── AKS ───────────────────────────────────────────────────────────────────────
// D4s_v3 = 4 vCPU / 16 GB RAM; user node pool autoscales 2–10
param aksNodePoolVMSize = 'Standard_D4s_v3'
param k8sNamespace = 'store-prod'

// ── Optional Azure services ────────────────────────────────────────────────────
param deployObservabilityTools = true
param deployAzureContainerRegistry = true
param deployAzureServiceBus = true
param deployAzureCosmosDB = true
param cosmosDBAccountKind = 'GlobalDocumentDB'  // SQL API

// ── Azure OpenAI ──────────────────────────────────────────────────────────────
param deployAzureOpenAI = true
param azureOpenAILocation = 'eastus'
param chatCompletionModelName = 'gpt-4o-mini'
param chatCompletionModelVersion = '2024-07-18'
param chatCompletionModelCapacity = 30
param deployImageGenerationModel = true
param imageGenerationModelName = 'dall-e-3'
param imageGenerationModelVersion = '3.0'
param imageGenerationModelCapacity = 1

// ── Network ───────────────────────────────────────────────────────────────────
// GitHub Actions runner IP range or NAT gateway IP for AKS API server ACL
param currentIpAddress = '<GITHUB_RUNNER_IP>/32'

// ── Source registry ───────────────────────────────────────────────────────────
param sourceRegistry = 'ghcr.io/azure-samples'

// ── Tags ──────────────────────────────────────────────────────────────────────
param tags = {
  environment: 'prod'
  project: 'aks-store-demo'
  'managed-by': 'bicep'
  'azd-env-name': 'prod'
}
