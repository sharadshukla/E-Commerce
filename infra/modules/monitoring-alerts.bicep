targetScope = 'resourceGroup'

@description('Azure region for the scheduled query alert')
param location string = resourceGroup().location

@description('Resource ID of the E-Commerce Log Analytics workspace')
param workspaceId string

@description('Email recipient for monitoring alerts')
param alertEmail string

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-ecommerce-monitoring'
  location: 'global'
  properties: {
    enabled: true
    groupShortName: 'ECommerce'
    emailReceivers: [
      {
        name: 'email-platform-alerts'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

resource restartAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: 'alert-ecommerce-container-restarts'
  location: location
  kind: 'LogAlert'
  properties: {
    displayName: 'alert-ecommerce-container-restarts'
    description: 'Detect increases in Robot Shop container restart counts.'
    enabled: true
    severity: 2
    evaluationFrequency: 'PT15M'
    windowSize: 'PT15M'
    scopes: [
      workspaceId
    ]
    criteria: {
      allOf: [
        {
          query: '''
            KubePodInventory
            | where TimeGenerated > ago(15m)
            | where Namespace == "robot-shop"
            | where isnotempty(ContainerName)
            | summarize MinRestarts = min(ContainerRestartCount),
                        MaxRestarts = max(ContainerRestartCount),
                        Samples = count()
                by PodUid, Name, ContainerName
            | extend RestartIncrease = MaxRestarts - MinRestarts
            | where Samples >= 2 and RestartIncrease > 0
            '''
          timeAggregation: 'Count'
          operator: 'GreaterThan'
          threshold: 0
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroup.id
      ]
    }
  }
}

output actionGroupId string = actionGroup.id
output restartAlertId string = restartAlert.id
