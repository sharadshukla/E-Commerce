targetScope = 'resourceGroup'

@description('Name of the Log Analytics workspace')
param workspaceName string

@description('Azure region for the workspace')
param location string = resourceGroup().location

@description('Log retention period in days')
param retentionInDays int = 30

// Dedicated Log Analytics workspace for AKS application and operational logs.
// Lifecycle: disposable with the E-Commerce application infrastructure.
resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: workspaceName
  location: location

  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: retentionInDays
  }
}

output workspaceId string = logAnalytics.id
output workspaceName string = logAnalytics.name
