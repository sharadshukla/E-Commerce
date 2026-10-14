targetScope = 'resourceGroup'

@description('Deploy Azure Container Registry')
param deployAcr bool = true

@description('Deploy Azure Kubernetes Service')
param deployAks bool = true

@description('Azure region for the resources')
param location string = resourceGroup().location

@description('Azure Container Registry name')
param acrName string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = if (deployAcr) {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

output acrLoginServer string? = deployAcr ? acr!.properties.loginServer : null

@description('Name of the AKS cluster')
param aksName string = 'ecommerce-aks'

module aks './modules/aks.bicep' = if (deployAks) {
  name: 'aks-deployment'
  params: {
    aksName: aksName
    location: location
    nodeVmSize: 'Standard_D2as_v6'
    minNodeCount: 1
    maxNodeCount: 3
  }
}

output aksClusterName string? = deployAks ? aks!.outputs.aksClusterName : null
