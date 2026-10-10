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
