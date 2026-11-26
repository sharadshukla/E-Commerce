
targetScope = 'resourceGroup'

@description('Name of the existing AKS cluster')
param aksName string

@description('Location of the AKS cluster and monitoring resources')
param location string

@description('Resource ID of the Log Analytics workspace')
param logAnalyticsWorkspaceId string

// Reference the existing cluster without changing its configuration.
resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' existing = {
  name: aksName
}

// Configure the telemetry collected by Container Insights.
resource containerInsightsDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: 'MSCI-${aksName}-${location}'
  location: location
  properties: {
    description: 'AKS Container Insights logging for E-Commerce'

    dataSources: {
      extensions: [
        {
          name: 'ContainerInsightsExtension'
          extensionName: 'ContainerInsights'
          streams: [
            'Microsoft-ContainerLogV2'
            'Microsoft-KubeEvents'
            'Microsoft-KubePodInventory'
          ]
          extensionSettings: {
            dataCollectionSettings: {
              interval: '5m'
              namespaceFilteringMode: 'Exclude'
              namespaces: [
                'kube-system'
              ]
              enableContainerLogV2: true
            }
          }
        }
      ]
    }

    destinations: {
      logAnalytics: [
        {
          name: 'ciworkspace'
          workspaceResourceId: logAnalyticsWorkspaceId
        }
      ]
    }

    dataFlows: [
      {
        streams: [
          'Microsoft-ContainerLogV2'
          'Microsoft-KubeEvents'
          'Microsoft-KubePodInventory'
        ]
        destinations: [
          'ciworkspace'
        ]
      }
    ]
  }
}

// Associate the collection rule with the existing AKS cluster.
resource containerInsightsAssociation 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = {
  name: 'ContainerInsightsExtension'
  scope: aks
  properties: {
    dataCollectionRuleId: containerInsightsDcr.id
    description: 'Connect AKS Container Insights to its collection rule'
  }
}

output dcrId string = containerInsightsDcr.id
