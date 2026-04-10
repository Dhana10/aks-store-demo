// Standalone resource group module.
// targetScope = subscription so callers can deploy this from a subscription-scoped deployment.
// Used when you want to create a resource group independently of main.bicep.
targetScope = 'subscription'

@minLength(1)
@description('Azure region for the resource group')
param location string

@minLength(1)
@maxLength(90)
@description('Resource group name')
param name string

@description('Tags to apply to the resource group and all child resources')
param tags object = {}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: name
  location: location
  tags: tags
}

output id string = resourceGroup.id
output name string = resourceGroup.name
output location string = resourceGroup.location
