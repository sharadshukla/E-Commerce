targetScope = 'resourceGroup'

@description('Azure region for the resources')
param location string = resourceGroup().location

@description('Azure Container Registry name')
param acrName string

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    adminUserEnabled: false
  }
}

output acrLoginServer string = acr.properties.loginServer

@description('Name of the AKS cluster')
param aksName string = 'ecommerce-aks'

module aks './modules/aks.bicep' = {
  name: 'aks-deployment'
  params: {
    aksName: aksName
    location: location
    nodeVmSize: 'Standard_D2as_v6'
    minNodeCount: 1
    maxNodeCount: 3
  }
}

output aksClusterName string = aks.outputs.aksClusterName