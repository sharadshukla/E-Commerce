# infra/bootstrap/deploy-agent.ps1

$ErrorActionPreference = "Stop"

# Deployment configuration
$resourceGroup = "ecommerce-bootstrap-rg"
$location = "eastus"

$azdoOrgUrl = "https://dev.azure.com/sharadshukla19"
$azdoAgentPool = "ecommerce-linux-pool"
$azdoAgentName = "ecommerce-linux-agent"

$keyVaultResourceGroup = "ecommerce-security-rg"
$keyVaultSecretName = "azdo-agent-registration-pat"

$bootstrapRepoUrl = "https://github.com/sharadshukla/E-Commerce.git"

# Resolve paths relative to this script
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "../..")).Path
$bicepFile = Join-Path $PSScriptRoot "main.bicep"
$sshKeyFile = Join-Path $HOME ".ssh/ecommerce-agent.pub"

Set-Location $repoRoot

# Verify Git branch and commit
$branch = (git branch --show-current).Trim()

if ($LASTEXITCODE -ne 0 -or
    [string]::IsNullOrWhiteSpace($branch)) {
    throw "Unable to determine the current Git branch."
}

Write-Host "Current Git branch: $branch"

$bootstrapCommitSha = (git rev-parse HEAD).Trim()
if ($LASTEXITCODE -ne 0) {
    throw "Unable to resolve the Git commit SHA."
}

$remoteHead = (git ls-remote origin "refs/heads/$branch")
if ($LASTEXITCODE -ne 0 -or -not $remoteHead) {
    throw "Unable to verify the GitHub branch."
}

if (($remoteHead -split '\s+')[0] -ne $bootstrapCommitSha) {
    throw "Local HEAD differs from GitHub branch HEAD. Push the intended commit first."
}

# Verify Git working directory is clean
$workingTreeChanges = @(git status --porcelain --untracked-files=normal)

if ($LASTEXITCODE -ne 0) {
    throw "Unable to check Git working-tree status."
}

if ($workingTreeChanges.Count -gt 0) {
    throw "Git working directory contains uncommitted or untracked changes. Commit and push the intended changes first."
}

Write-Host "Git working directory is clean."

# Retrieve existing Azure resources
$keyVaultName = (az keyvault list `
    --resource-group $keyVaultResourceGroup `
    --query "[0].name" -o tsv).Trim()

if ($LASTEXITCODE -ne 0 -or -not $keyVaultName) {
    throw "Key Vault not found."
}

if (-not (Test-Path $sshKeyFile)) {
    throw "SSH public key not found: $sshKeyFile"
}

$sshPublicKey = (Get-Content $sshKeyFile -Raw).Trim()

Write-Host "Deploying Azure Linux agent..."
Write-Host "Resource group: $resourceGroup"
Write-Host "Location: $location"
Write-Host "Git commit: $bootstrapCommitSha"

# Deploy VM infrastructure
az deployment group create `
    --resource-group $resourceGroup `
    --name "ecommerce-agent-v130" `
    --template-file $bicepFile `
    --parameters `
        location=$location `
        sshPublicKey="$sshPublicKey" `
        azdoOrgUrl="$azdoOrgUrl" `
        azdoAgentPool="$azdoAgentPool" `
        azdoAgentName="$azdoAgentName" `
        keyVaultName="$keyVaultName" `
        keyVaultResourceGroup="$keyVaultResourceGroup" `
        keyVaultSecretName="$keyVaultSecretName" `
        bootstrapRepoUrl="$bootstrapRepoUrl" `
        bootstrapCommitSha="$bootstrapCommitSha" `
    --output none

if ($LASTEXITCODE -ne 0) {
    throw "Bicep bootstrap deployment failed."
}

Write-Host "Bicep deployment succeeded."

# Verify VM infrastructure
az vm show `
    --resource-group $resourceGroup `
    --name ecommerce-agent-vm `
    --show-details `
    --query "{Name:name,PowerState:powerState,ProvisioningState:provisioningState}" `
    -o table

if ($LASTEXITCODE -ne 0) {
    throw "VM verification failed."
}

$vmState = az vm show `
    --resource-group $resourceGroup `
    --name ecommerce-agent-vm `
    --show-details `
    --query "{Power:powerState,Provisioning:provisioningState}" `
    -o json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0 -or
    $vmState.Power -ne "VM running" -or
    $vmState.Provisioning -ne "Succeeded") {
    throw "VM is not running or provisioning did not succeed."
}

Write-Host "VM provisioning check completed."

# Verify cloud-init, Ansible and agent service

Write-Host "Checking Linux agent bootstrap..."

$maxAttempts = 20
$bootstrapComplete = $false

for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {

    $result = az vm run-command invoke `
        --resource-group $resourceGroup `
        --name ecommerce-agent-vm `
        --command-id RunShellScript `
        --scripts "cloud-init status --long" `
        --query "value[0].message" `
        -o tsv

    if ($LASTEXITCODE -ne 0) {
        throw "Unable to check cloud-init status."
    }

    if ($result -match '(?m)^status:\s*error') {
        throw "Cloud-init failed. Check /var/log/cloud-init-output.log."
    }

    if ($result -match '(?m)^status:\s*done' -and
        $result -match '(?m)^errors:\s*\[\]') {

        $bootstrapComplete = $true
        break
    }

    Write-Host "Bootstrap still running. Checking again..."
    Start-Sleep -Seconds 15
}

if (-not $bootstrapComplete) {
    throw "Bootstrap did not complete within the verification window."
}

Write-Host "Cloud-init completed successfully."

# Verify PowerShell Core installation

$pwshCheck = az vm run-command invoke `
    --resource-group $resourceGroup `
    --name ecommerce-agent-vm `
    --command-id RunShellScript `
    --scripts "command -v pwsh && pwsh --version" `
    --query "value[0].message" `
    -o tsv

$pwshExitCode = $LASTEXITCODE
$pwshOutput = $pwshCheck -join "`n"

if ($pwshExitCode -ne 0 -or
    $pwshOutput -notmatch '(?m)^PowerShell\s+\d+\.\d+') {
    throw "PowerShell Core verification failed. Output: $pwshOutput"
}

Write-Host "PowerShell Core verified successfully."

# Verify agent configuration and systemd service

$agentCheck = az vm run-command invoke `
    --resource-group $resourceGroup `
    --name ecommerce-agent-vm `
    --command-id RunShellScript `
    --scripts "test -f /opt/azdo-agent/.agent && test -f /opt/azdo-agent/.service && systemctl is-active `$(cat /opt/azdo-agent/.service)" `
    --query "value[0].message" `
    -o tsv

if ($LASTEXITCODE -ne 0 -or $agentCheck -notmatch '(?m)^active\s*$') {
    throw "Azure DevOps agent configuration or systemd service verification failed."
}

Write-Host "Azure DevOps agent service is active."
Write-Host "Bootstrap verification completed."