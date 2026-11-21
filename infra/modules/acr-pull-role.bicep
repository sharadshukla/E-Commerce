targetScope = 'resourceGroup'

@description('Name of the Azure Container Registry')
param acrName string

@description('Object ID of the AKS kubelet managed identity')
param kubeletObjectId string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: acrName
}

// Built-in Azure RBAC role: AcrPull
var acrPullRoleDefinitionId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '7f951dda-4ed3-4680-a7ca-43fe172d538d'
)

// Allow the AKS kubelet managed identity to pull images from ACR
resource acrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, kubeletObjectId, acrPullRoleDefinitionId)
  scope: acr
  properties: {
    roleDefinitionId: acrPullRoleDefinitionId
    principalId: kubeletObjectId
    principalType: 'ServicePrincipal'
  }
}
