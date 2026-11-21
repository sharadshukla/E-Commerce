targetScope = 'resourceGroup'

@description('Existing Key Vault name')
param keyVaultName string

@description('Name of the Azure DevOps agent registration PAT secret')
param secretName string = 'azdo-agent-registration-pat'

@description('Principal ID of the Linux VM managed identity')
param principalId string

resource keyVaultSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' existing = {
  parent: keyVault
  name: secretName
}

resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: keyVaultName
}

resource keyVaultSecretReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(keyVaultSecret.id, principalId, 'Key Vault Secrets User')
  scope: keyVaultSecret
  properties: {
    roleDefinitionId: subscriptionResourceId(
      'Microsoft.Authorization/roleDefinitions',
      '4633458b-17de-408a-b874-0445c86b69e6'
    )
    principalId: principalId
    principalType: 'ServicePrincipal'
  }
}
