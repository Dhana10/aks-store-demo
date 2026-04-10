// Per-service managed identity module.
// Creates a single user-assigned managed identity for one microservice and adds
// the federated credential that allows the Kubernetes service account to
// exchange tokens via the AKS OIDC issuer.
//
// Call this module once per service (order-service, makeline-service, ai-service).
// Role assignments (Service Bus Data Sender, Cosmos DB Operator, etc.) are made
// by the caller (main.bicep or the service-specific module) after creation.

@minLength(3)
param nameSuffix string

@description('Short name of the service (e.g., order-service)')
param serviceName string

@description('AKS OIDC issuer URL (output of kubernetes.bicep)')
param oidcIssuerUrl string

@description('Kubernetes namespace where the service account lives')
param k8sNamespace string

@description('Tags to apply to the managed identity')
param tags object = {}

// Reuse the existing workloadidentity.bicep pattern (single identity + federated cred)
module identity 'workloadidentity.bicep' = {
  name: 'identityDeployment-${serviceName}'
  params: {
    nameSuffix: '${nameSuffix}-${serviceName}'
    federatedCredentials: [
      {
        name: serviceName
        audiences: ['api://AzureADTokenExchange']
        issuer: oidcIssuerUrl
        subject: 'system:serviceaccount:${k8sNamespace}:${serviceName}'
      }
    ]
    tags: union(tags, { service: serviceName })
  }
}

output name string = identity.outputs.name
output clientId string = identity.outputs.clientId
output principalId string = identity.outputs.principalId
