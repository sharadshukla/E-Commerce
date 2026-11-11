
# E-Commerce v1.3.0 - Infrastructure Cleanup
# Run locally using PowerShell and Azure CLI.
# Preview by default. Use -Execute to delete resources.

param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,

    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

# Project configuration
$appResourceGroup = 'e-commerce-app'
$bootstrapResourceGroup = 'ecommerce-bootstrap-rg'

$aksName = 'ecommerce-aks'
$acrName = 'ecommerceregistrynew'
$vmName = 'ecommerce-agent-vm'

function Invoke-Az {
    param([string[]]$Arguments)

    & az @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI command failed: az $($Arguments -join ' ')"
    }
}

Write-Host "`nE-Commerce Infrastructure Cleanup" -ForegroundColor Cyan

# Verify Azure authentication and subscription
$currentSubscription = az account show --query id -o tsv

if ($LASTEXITCODE -ne 0 -or
    $currentSubscription -ne $SubscriptionId) {
    throw "Azure subscription mismatch. Check az account show."
}

Write-Host "Subscription verified: $SubscriptionId"

# Verify required resource groups exist
foreach ($rg in @($appResourceGroup, $bootstrapResourceGroup)) {
    $exists = az group exists --name $rg -o tsv

    if ($LASTEXITCODE -ne 0 -or $exists -ne 'true') {
        throw "Required resource group not found: $rg"
    }
}

# Preview targeted resources
$resources = @(
    @{
        Type = 'Microsoft.ContainerService/managedClusters'
        Name = $aksName
        Group = $appResourceGroup
    },
    @{
        Type = 'Microsoft.ContainerRegistry/registries'
        Name = $acrName
        Group = $appResourceGroup
    },
    @{
        Type = 'Microsoft.Compute/virtualMachines'
        Name = $vmName
        Group = $bootstrapResourceGroup
    }
)

Write-Host "`nResources targeted for deletion:" -ForegroundColor Yellow

foreach ($resource in $resources) {
    Write-Host "  $($resource.Type): $($resource.Name)"
}

Write-Host "`nResource groups will be preserved."

if (-not $Execute) {
    Write-Host "`nPREVIEW ONLY. No resources deleted." -ForegroundColor Green
    Write-Host "Use -Execute when ready."
    return
}

# Explicit confirmation
$confirmation = Read-Host "Type DELETE ECOMMERCE INFRA to continue"

if ($confirmation -cne 'DELETE ECOMMERCE INFRA') {
    throw "Cleanup cancelled."
}

# Delete AKS
$aksId = az aks show `
    --resource-group $appResourceGroup `
    --name $aksName `
    --query id -o tsv 2>$null

if ($aksId) {
    Write-Host "Deleting AKS..."
    Invoke-Az @(
        'aks', 'delete',
        '--resource-group', $appResourceGroup,
        '--name', $aksName,
        '--yes'
    )
}

# Delete ACR
$acrId = az acr show `
    --resource-group $appResourceGroup `
    --name $acrName `
    --query id -o tsv 2>$null

if ($acrId) {
    Write-Host "Deleting ACR..."
    Invoke-Az @(
        'acr', 'delete',
        '--resource-group', $appResourceGroup,
        '--name', $acrName,
        '--yes'
    )
}

# Delete Linux agent VM
$vmId = az vm show `
    --resource-group $bootstrapResourceGroup `
    --name $vmName `
    --query id -o tsv 2>$null

if ($vmId) {
    Write-Host "Deleting Linux agent VM..."
    Invoke-Az @(
        'vm', 'delete',
        '--resource-group', $bootstrapResourceGroup,
        '--name', $vmName,
        '--yes'
    )
}

Write-Host "`nPrimary resource deletion completed." -ForegroundColor Green
Write-Host "Check remaining disks, networking and role assignments."
