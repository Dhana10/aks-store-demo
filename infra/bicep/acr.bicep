// Azure Container Registry module.
// Premium SKU enables geo-replication, content trust, and private endpoints.
// Admin access is disabled; images are pulled via AcrPull role assigned to the
// AKS kubelet managed identity.

@minLength(3)
param nameSuffix string

@description('Principal ID of the AKS kubelet managed identity (receives AcrPull)')
param kubeletPrincipalId string

@description('Tags to apply to the registry')
param tags object = {}

@description('Enable geo-replication to a secondary region')
param enableGeoReplication bool = false

@description('Secondary region for geo-replication (only used when enableGeoReplication=true)')
param geoReplicationLocation string = ''

// ACR name must be globally unique, 5–50 alphanumeric chars, no hyphens.
var registryName = 'acr${replace(nameSuffix, '-', '')}${take(uniqueString(nameSuffix), 4)}'

// https://github.com/Azure/bicep-registry-modules/tree/main/avm/res/container-registry/registry
module registry 'br/public:avm/res/container-registry/registry:0.6.0' = {
  name: 'acrDeployment'
  params: {
    name: registryName
    acrSku: 'Premium'
    acrAdminUserEnabled: false
    tags: union(tags, { 'managed-by': 'bicep', project: 'aks-store-demo' })
    roleAssignments: [
      {
        principalId: kubeletPrincipalId
        roleDefinitionIdOrName: 'AcrPull'
        principalType: 'ServicePrincipal'
      }
    ]
    replications: enableGeoReplication && !empty(geoReplicationLocation)
      ? [
          {
            location: geoReplicationLocation
            zoneRedundancy: 'Disabled'
          }
        ]
      : []
  }
}

output name string = registry.outputs.name
output loginServer string = registry.outputs.loginServer
output resourceId string = registry.outputs.resourceId
