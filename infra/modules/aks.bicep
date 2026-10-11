targetScope = 'resourceGroup'

@description('Name of the AKS cluster')
param aksName string

@description('Azure region')
param location string

@description('VM size for AKS worker nodes')
param nodeVmSize string = 'Standard_D2as_v6'

@description('Minimum number of worker nodes')
param minNodeCount int = 1

@description('Maximum number of worker nodes')
param maxNodeCount int = 3

resource aks 'Microsoft.ContainerService/managedClusters@2024-09-01' = {
  name: aksName
  location: location

  identity: {
    type: 'SystemAssigned'
  }

  properties: {
    dnsPrefix: aksName

    agentPoolProfiles: [
      {
        name: 'systempool'
        count: minNodeCount
        enableAutoScaling: true
        minCount: minNodeCount
        maxCount: maxNodeCount
        vmSize: nodeVmSize
        mode: 'System'
        osType: 'Linux'
        type: 'VirtualMachineScaleSets'
      }
    ]
  }
}

output aksClusterName string = aks.name
output aksPrincipalId string = aks.identity.principalId
