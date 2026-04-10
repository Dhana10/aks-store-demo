// Azure Key Vault module.
// Uses RBAC authorization (not legacy access policies).
// Soft-delete and purge protection are always enabled for production safety.
// Secrets are created as child resources so their values are passed as secure params
// and never appear in deployment outputs.

@minLength(3)
param nameSuffix string

@description('Object ID of the current deployer (receives Key Vault Administrator role)')
param currentUserObjectId string

@description('Array of managed identity principal IDs that need Key Vault Secrets User access')
param secretsReaderPrincipalIds array = []

@description('Azure Service Bus fully-qualified namespace (e.g., sb-xxx.servicebus.windows.net)')
@secure()
param sbConnectionString string = ''

@description('CosmosDB resource endpoint (e.g., https://cosmos-xxx.documents.azure.com:443/)')
param cosmosEndpoint string = ''

@description('Azure OpenAI API key (leave empty if using Workload Identity)')
@secure()
param openAiApiKey string = ''

@description('Application Insights connection string')
@secure()
param appInsightsConnectionString string = ''

@description('Tags to apply to the Key Vault')
param tags object = {}

var kvName = 'kv-${take(nameSuffix, 21)}'

// Build role assignments array using a variable (for-expressions work in var scope)
var readerRoleAssignments = [
  for principalId in secretsReaderPrincipalIds: {
    principalId: principalId
    roleDefinitionIdOrName: 'Key Vault Secrets User'
    principalType: 'ServicePrincipal'
  }
]

var allRoleAssignments = concat(
  [
    {
      principalId: currentUserObjectId
      roleDefinitionIdOrName: 'Key Vault Administrator'
      principalType: 'User'
    }
  ],
  readerRoleAssignments
)

// Build secrets array using variables
var sbSecret = !empty(sbConnectionString) ? [{ name: 'sb-connection-string', value: sbConnectionString }] : []
var cosmosSecret = !empty(cosmosEndpoint) ? [{ name: 'cosmos-endpoint', value: cosmosEndpoint }] : []
var openAiSecret = !empty(openAiApiKey) ? [{ name: 'openai-api-key', value: openAiApiKey }] : []
var appInsightsSecret = !empty(appInsightsConnectionString)
  ? [{ name: 'appinsights-connection-string', value: appInsightsConnectionString }]
  : []
var allSecrets = concat(sbSecret, cosmosSecret, openAiSecret, appInsightsSecret)

// https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/key-vault/vault
module keyVault 'br/public:avm/res/key-vault/vault:0.11.0' = {
  name: 'keyVaultDeployment'
  params: {
    name: kvName
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 90
    enablePurgeProtection: true
    publicNetworkAccess: 'Enabled'
    tags: union(tags, { 'managed-by': 'bicep', project: 'aks-store-demo' })
    roleAssignments: allRoleAssignments
    secrets: allSecrets
  }
}

output name string = keyVault.outputs.name
output uri string = keyVault.outputs.uri
output resourceId string = keyVault.outputs.resourceId
