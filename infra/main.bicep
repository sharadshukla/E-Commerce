targetScope = 'resourceGroup'

@description('Deploy Azure Container Registry')
param deployAcr bool = true

@description('Deploy Azure Kubernetes Service')
param deployAks bool = true

@description('Object ID of the Microsoft Entra group for AKS administrators')
param aksAdminGroupObjectId string

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
    aksAdminGroupObjectId: aksAdminGroupObjectId
    location: location
    nodeVmSize: 'Standard_D2as_v6'
    minNodeCount: 1
    maxNodeCount: 3

    logAnalyticsWorkspaceId: logAnalytics!.outputs.workspaceId
  }
}

output aksClusterName string? = deployAks ? aks!.outputs.aksClusterName : null

module acrPullRole './modules/acr-pull-role.bicep' = if (deployAcr && deployAks) {
  name: 'aks-acr-pull-role'
  params: {
    acrName: acrName
    kubeletObjectId: aks!.outputs.aksKubeletObjectId
  }
  dependsOn: [
    acr
  ]
}

@description('Log Analytics workspace for AKS observability')
param logAnalyticsWorkspaceName string = 'law-ecommerce-aks'

// Provision application-scoped monitoring infrastructure.
module logAnalytics './modules/log-analytics.bicep' = if (deployAks) {
  name: 'log-analytics-deployment'
  params: {
    workspaceName: logAnalyticsWorkspaceName
    location: location
    retentionInDays: 30
  }
}

// Return the workspace ID only when monitoring infrastructure is deployed.
output logAnalyticsWorkspaceId string? = deployAks ? logAnalytics!.outputs.workspaceId : null


// Configure Container Insights collection for the AKS application.
// The module creates the DCR and associates it with the cluster.
module containerInsightsDcr './modules/container-insights-dcr.bicep' = if (deployAks) {
  name: 'container-insights-dcr-deployment'
  params: {
    aksName: aksName
    location: location
    logAnalyticsWorkspaceId: logAnalytics!.outputs.workspaceId
  }
  dependsOn: [
    aks
  ]
}

