
targetScope = 'resourceGroup'

@description('Azure region for bootstrap infrastructure')
param location string = 'eastus'

@description('Name of the Linux CI/CD agent VM')
param vmName string = 'ecommerce-agent-vm'

@description('VM size for Docker CI and Helm CD workloads')
param vmSize string = 'Standard_D2s_v4'

@description('Administrator username')
param adminUsername string = 'azureagent'

@description('SSH public key for administrator access')
@secure()
param sshPublicKey string

@description('Name of the existing Key Vault containing the Azure DevOps agent registration PAT')
param keyVaultName string

@description('Git commit SHA containing the agent bootstrap configuration')
@minLength(40)
@maxLength(40)
param bootstrapCommitSha string

var vnetName = '${vmName}-vnet'
var subnetName = 'agent-subnet'
var nsgName = '${vmName}-nsg'
var nicName = '${vmName}-nic'

resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: nsgName
  location: location
  properties: {
    securityRules: [
      {
        name: 'DenyInboundInternet'
        properties: {
          priority: 100
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourcePortRange: '*'
          destinationPortRange: '*'
          sourceAddressPrefix: 'Internet'
          destinationAddressPrefix: '*'
        }
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.50.0.0/16'
      ]
    }
    subnets: [
      {
        name: subnetName
        properties: {
          addressPrefix: '10.50.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource publicIp 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vmName}-pip'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: nicName
  location: location
  properties: {
    ipConfigurations: [
      {
        name: 'primary'
        properties: {
          primary: true

          privateIPAllocationMethod: 'Dynamic'
          publicIPAddress: {
            id: publicIp.id
          }
          subnet: {
            id: vnet.properties.subnets[0].id
          }
        }
      }
    ]
  }
}

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = {
  name: vmName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername

      customData: base64(
        replace(
          loadTextContent('./cloud-init.yaml'),
          '__BOOTSTRAP_COMMIT_SHA__',
          bootstrapCommitSha
        )
      )

      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'Canonical'
        offer: 'ubuntu-24_04-lts'
        sku: 'server'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 64
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            primary: true
          }
        }
      ]
    }
  }
}

module keyVaultRbac '../modules/keyvault-rbac.bicep' = {
  name: 'keyvault-agent-rbac'
  scope: resourceGroup('ecommerce-security-rg')
  params: {
    keyVaultName: keyVaultName
    principalId: vm.identity.principalId
  }
}

output vmName string = vm.name
output vmResourceId string = vm.id
output vmPrincipalId string = vm.identity.principalId
