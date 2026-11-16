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

# Azure DevOps CLI - Agent Availability Verification
function Wait-AzureDevOpsAgentOnline {
    param(
        [string]$Organization = 'sharadshukla19',
        [string]$PoolName = 'ecommerce-linux-pool',
        [string]$AgentName = 'ecommerce-linux-agent',
        [int]$MaxAttempts = 12,
        [int]$DelaySeconds = 10
    )

    $orgUrl = "https://dev.azure.com/$Organization"

    # Discover the agent pool through Azure DevOps CLI.
    $poolJson = az pipelines pool list `
        --organization $orgUrl `
        --query "[?name=='$PoolName']" `
        -o json

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query Azure DevOps agent pools."
    }

    $pools = @($poolJson | ConvertFrom-Json)
    $pool = $pools | Select-Object -First 1

    if (-not $pool) {
        throw "Azure DevOps agent pool '$PoolName' not found."
    }

    # Poll until the agent is online and enabled.
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {

        $agentJson = az pipelines agent list `
            --organization $orgUrl `
            --pool-id $pool.id `
            --agent-name $AgentName `
            -o json

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to query Azure DevOps agents."
        }

        $agents = @($agentJson | ConvertFrom-Json)
        $agent = $agents |
            Where-Object { $_.name -eq $AgentName } |
            Select-Object -First 1

        if ($agent -and $agent.status -eq 'online' -and $agent.enabled) {
            Write-Host "Azure DevOps agent '$AgentName' is Online."
            return
        }

        Write-Host "Waiting for Azure DevOps agent ($attempt/$MaxAttempts)..."
        Start-Sleep -Seconds $DelaySeconds
    }

    throw "Azure DevOps agent '$AgentName' did not become Online."
}


# Azure DevOps CLI - Master Pipeline Orchestration
function Invoke-EcommerceMasterPipeline {
    param(
        [Parameter(Mandatory)]
        [string]$Branch,

        [Parameter(Mandatory)]
        [string]$CommitSha,

        [switch]$PreviewOnly
    )

    $organization = 'https://dev.azure.com/sharadshukla19'
    $project = 'e-commerce-app'
    $pipelineName = 'ecommerce-master-deployment'

    # The standard CLI run command does not provide a YAML preview.
    if ($PreviewOnly) {
        throw "PreviewOnly is not supported by this CLI-based function. No pipeline was queued."
    }

    if ($CommitSha -notmatch '^[0-9a-fA-F]{40}$') {
        throw "Invalid Git commit SHA: expected 40 hexadecimal characters."
    }

    # Locate the registered master pipeline.
    $pipelineJson = az pipelines list `
        --organization $organization `
        --project $project `
        --name $pipelineName `
        -o json

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to query Azure DevOps pipelines."
    }

    $pipelines = @(($pipelineJson -join "`n") | ConvertFrom-Json)

    $matches = @(
        $pipelines | Where-Object {
            $_.name -eq $pipelineName
        }
    )

    if ($matches.Count -ne 1) {
        throw "Expected exactly one master pipeline named '$pipelineName'; found $($matches.Count)."
    }

    $pipelineId = $matches[0].id

    Write-Host "Master pipeline found: $pipelineName (ID: $pipelineId)"
    Write-Host "Target branch: $Branch"
    Write-Host "Target commit: $CommitSha"

    # Queue the pipeline at the explicitly verified Git revision.
    $runJson = az pipelines run `
        --organization $organization `
        --project $project `
        --id $pipelineId `
        --branch "refs/heads/$Branch" `
        --commit-id $CommitSha `
        -o json

    if ($LASTEXITCODE -ne 0) {
        throw "Failed to queue the master pipeline."
    }

    $result = ($runJson -join "`n") | ConvertFrom-Json

    if (-not $result.id) {
        throw "Azure DevOps did not return a pipeline run ID."
    }

    # Verify the revision reported for the queued run.
    if ($result.sourceVersion -and
        $result.sourceVersion -ne $CommitSha) {
        throw "Queued pipeline revision does not match the requested commit. Run ID: $($result.id). Inspect or cancel this run."
    }

    Write-Host "Master pipeline queued successfully."
    Write-Host "Run ID: $($result.id)"

    return [int]$result.id
}

# Azure DevOps CLI - Master Pipeline Run Monitoring

function Wait-EcommerceMasterPipeline {
    param(
        [Parameter(Mandatory)]
        [int]$RunId,

        [int]$TimeoutMinutes = 90,
        [int]$PollSeconds = 20
    )

    $organization = 'https://dev.azure.com/sharadshukla19'
    $project = 'e-commerce-app'

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)

    while ((Get-Date) -lt $deadline) {

        $runJson = az pipelines runs show `
            --organization $organization `
            --project $project `
            --id $RunId `
            -o json

        if ($LASTEXITCODE -ne 0) {
            throw "Failed to retrieve master pipeline run $RunId."
        }

        $run = ($runJson -join "`n") | ConvertFrom-Json

        if (-not $run -or -not $run.status) {
            throw "Invalid response for master pipeline run $RunId."
        }

        Write-Host "Master pipeline run $RunId - Status: $($run.status), Result: $($run.result)"

        if ($run.status -eq 'completed') {
            if ($run.result -eq 'succeeded') {
                Write-Host "Master pipeline completed successfully."
                return
            }

            throw "Master pipeline run $RunId completed with result: $($run.result)"
        }

        Start-Sleep -Seconds $PollSeconds
    }

    throw "Master pipeline run $RunId did not complete within $TimeoutMinutes minutes. Check Azure DevOps before retrying."
}

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
$agentCheckScript = @'
#!/bin/bash
set -eu

test -f /opt/azdo-agent/.agent
test -f /opt/azdo-agent/.service

service_name=$(cat /opt/azdo-agent/.service)
systemctl is-active --quiet "$service_name"

echo "AGENT_SERVICE_ACTIVE"
'@

# Pass the multiline shell script to Azure CLI through a temporary file.
$agentCheckFile = Join-Path ([System.IO.Path]::GetTempPath()) `
    "ecommerce-agent-check-$([guid]::NewGuid().ToString('N')).sh"

try {
    # Write UTF-8 without BOM for Linux shell compatibility.
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText(
        $agentCheckFile,
        ($agentCheckScript -replace "`r`n", "`n"),
        $utf8NoBom
    )

    $agentCheckJson = az vm run-command invoke `
        --resource-group $resourceGroup `
        --name ecommerce-agent-vm `
        --command-id RunShellScript `
        --scripts "@$agentCheckFile" `
        --output json

    $agentCheckExitCode = $LASTEXITCODE
}
finally {
    Remove-Item -LiteralPath $agentCheckFile `
        -Force -ErrorAction SilentlyContinue
}

if ($agentCheckExitCode -ne 0) {
    throw "Azure VM Run Command failed. Azure CLI exit code: $agentCheckExitCode"
}

$agentCheckResponse = (
    $agentCheckJson -join "`n"
) | ConvertFrom-Json

$agentCheckStatus = $agentCheckResponse.value[0]

if ($agentCheckStatus.code -ne "ProvisioningState/succeeded" -or
    $agentCheckStatus.message -notmatch "AGENT_SERVICE_ACTIVE") {
    throw "Azure DevOps agent configuration or systemd service verification failed. Status: $($agentCheckStatus.code). Output: $($agentCheckStatus.message)"
}

Write-Host "Azure DevOps agent service is active."
Write-Host "Bootstrap verification completed."

Write-Host "Checking Azure DevOps agent availability..."

Wait-AzureDevOpsAgentOnline

Write-Host "Starting E-Commerce master pipeline..."

$masterRunId = Invoke-EcommerceMasterPipeline `
    -Branch $branch `
    -CommitSha $bootstrapCommitSha

Write-Host "Monitoring E-Commerce master pipeline..."

Wait-EcommerceMasterPipeline -RunId $masterRunId
