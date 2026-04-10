// ============================================================
// infra/main.bicep — AKS Store Demo Infrastructure
// Deploys: AKS, ACR, Key Vault, VNet, Log Analytics, MSI
// ============================================================

@description('Azure region for all resources')
param location string = resourceGroup().location

@description('AKS cluster name')
param aksClusterName string

@description('Azure Container Registry name (globally unique)')
param acrName string

@description('Kubernetes version')
param kubernetesVersion string = '1.34.4'

@description('System node pool VM size')
param systemNodeVmSize string = 'Standard_D2_v3'

@description('User node pool VM size — Karpenter will manage additional nodes')
param userNodeVmSize string = 'Standard_D2_v3'

@description('Key Vault name (globally unique)')
param keyVaultName string

@description('Log Analytics workspace name')
param logAnalyticsName string

// ── Log Analytics ────────────────────────────────────────────
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2022-10-01' = {
  name: logAnalyticsName
  location: location
  properties: {
    sku: { name: 'PerGB2018' }
    retentionInDays: 30
  }
}

// ── Virtual Network ──────────────────────────────────────────
resource vnet 'Microsoft.Network/virtualNetworks@2023-04-01' = {
  name: '${aksClusterName}-vnet'
  location: location
  properties: {
    addressSpace: { addressPrefixes: ['10.0.0.0/8'] }
    subnets: [
      {
        name: 'aks-subnet'
        properties: { addressPrefix: '10.240.0.0/16' }
      }
      {
        name: 'pods-subnet'
        properties: {
          addressPrefix: '10.241.0.0/16'
          delegations: [
            {
              name: 'aks-delegation'
              properties: { serviceName: 'Microsoft.ContainerService/managedClusters' }
            }
          ]
        }
      }
    ]
  }
}

var aksSubnetId = vnet.properties.subnets[0].id

// ── Azure Container Registry ─────────────────────────────────
resource acr 'Microsoft.ContainerRegistry/registries@2023-01-01-preview' = {
  name: acrName
  location: location
  sku: { name: 'Standard' }
  properties: {
    adminUserEnabled: false  // use workload identity, not admin creds
    publicNetworkAccess: 'Enabled'
  }
}

// ── User-Assigned Managed Identity (for AKS workload identity) ─
resource aksIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: '${aksClusterName}-identity'
  location: location
}

// ── AKS Cluster ──────────────────────────────────────────────
resource aksCluster 'Microsoft.ContainerService/managedClusters@2024-01-01' = {
  name: aksClusterName
  location: location
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${aksIdentity.id}': {} }
  }
  properties: {
    kubernetesVersion: kubernetesVersion
    dnsPrefix: aksClusterName
    enableRBAC: true

    // OIDC + Workload Identity — required for ArgoCD, Karpenter, ai-service
    oidcIssuerProfile: { enabled: true }
    securityProfile: {
      workloadIdentity: { enabled: true }
    }

    // System node pool (always-on, runs control plane components)
    agentPoolProfiles: [
      {
        name: 'system'
        count: 1
        vmSize: systemNodeVmSize
        osType: 'Linux'
        mode: 'System'
        vnetSubnetID: aksSubnetId
        enableAutoScaling: false  // system pool is fixed — Karpenter handles scaling
      }
      {
        name: 'userpool'
        count: 1
        vmSize: userNodeVmSize
        osType: 'Linux'
        mode: 'User'
        vnetSubnetID: aksSubnetId
        enableAutoScaling: false  // Karpenter replaces cluster-autoscaler
        nodeTaints: []
      }
    ]

    networkProfile: {
      networkPlugin: 'azure'
      networkPolicy: 'azure'
      serviceCidr: '10.0.0.0/16'
      dnsServiceIP: '10.0.0.10'
    }

    addonProfiles: {
      omsagent: {
        enabled: true
        config: { logAnalyticsWorkspaceResourceID: logAnalytics.id }
      }
    }
  }
}

// ── Key Vault ────────────────────────────────────────────────
resource keyVault 'Microsoft.KeyVault/vaults@2023-02-01' = {
  name: keyVaultName
  location: location
  properties: {
    sku: { family: 'A', name: 'standard' }
    tenantId: subscription().tenantId
    enableRbacAuthorization: true  // use RBAC not access policies
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// ── RBAC: AKS identity → ACR (AcrPull) ──────────────────────
resource acrPullRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aksIdentity.id, 'AcrPull')
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
    principalId: aksCluster.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

// ── Outputs (consumed by subsequent scripts) ─────────────────
output aksClusterName string = aksCluster.name
output acrLoginServer string = acr.properties.loginServer
output aksOidcIssuerUrl string = aksCluster.properties.oidcIssuerProfile.issuerURL
output keyVaultUri string = keyVault.properties.vaultUri
output logAnalyticsId string = logAnalytics.id
output aksIdentityClientId string = aksIdentity.properties.clientId
