
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

@description('Azure DevOps organization URL')
param azdoOrgUrl string

@description('Azure DevOps self-hosted agent pool')
param azdoAgentPool string

@description('Name assigned to the Linux agent')
param azdoAgentName string = 'ecommerce-linux-agent'

@description('Resource group containing the existing Key Vault')
param keyVaultResourceGroup string

@description('Name of the Key Vault secret containing the registration PAT')
param keyVaultSecretName string = 'azdo-agent-registration-pat'

@description('Public Git repository containing the bootstrap playbook')
param bootstrapRepoUrl string

var bootstrapConfig = {
  azdo_org_url: azdoOrgUrl
  azdo_agent_pool: azdoAgentPool
  azdo_agent_name: azdoAgentName
  keyvault_name: keyVaultName
  keyvault_secret_name: keyVaultSecretName
  bootstrap_repo_url: bootstrapRepoUrl
  bootstrap_commit_sha: bootstrapCommitSha
}

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
          '__BOOTSTRAP_CONFIG_BASE64__',
          base64(string(bootstrapConfig))
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
  scope: resourceGroup(keyVaultResourceGroup)
  params: {
    keyVaultName: keyVaultName
    principalId: vm.identity.principalId
    secretName: keyVaultSecretName
  }
}

output vmName string = vm.name
output vmResourceId string = vm.id
output vmPrincipalId string = vm.identity.principalId
