# E-Commerce v1.4.0 - Controlled infrastructure cleanup (v1.4.0 monitoring-aware)
# Execute locally (NOT on ecommerce-agent-vm). Preview by default.
param(
    [Parameter(Mandatory = $true)]
    [string]$SubscriptionId,
    [switch]$Execute
)

$ErrorActionPreference = 'Stop'

$appRg = 'e-commerce-app'
$bootstrapRg = 'ecommerce-bootstrap-rg'
# The manually created restart alert is outside the application RG.
$externalAlertRg = 'NetworkWatcherRG'
$restartAlertName = 'alert-ecommerce-container-restarts'
$actionGroupName = 'ag-ecommerce-monitoring'
$securityRg = 'ecommerce-security-rg'
$aksName = 'ecommerce-aks'
$acrName = 'ecommerceregistrynew'
$logAnalyticsName = 'law-ecommerce-aks'
# Azure can generate either DCR name depending on onboarding/version.
$containerInsightsDcrNames = @('MSCI-ecommerce-aks-eastus', 'MSCI-eastus-ecommerce-aks')
$containerInsightsSolutionName = 'ContainerInsights(law-ecommerce-aks)'
# Managed Prometheus uses a default Azure Monitor workspace outside this app RG.
# Do NOT delete default/shared Azure Monitor workspaces automatically.
$prometheusWorkspaceName = 'defaultazuremonitorworkspace-eus'
$vmName = 'ecommerce-agent-vm'
$keyVaultName = 'kv-ecommerce-agent-26641'
$secretName = 'azdo-agent-registration-pat'
$organization = 'https://dev.azure.com/sharadshukla19'
$poolName = 'ecommerce-linux-pool'
$agentName = 'ecommerce-linux-agent'
$secretUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'

function Get-AzJson {
    param([Parameter(Mandatory)][string[]]$Arguments)

    $lines = & az @Arguments --output json

    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI query failed: az $($Arguments -join ' ')"
    }

    $raw = $lines -join "`n"

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "Empty response from: az $($Arguments -join ' ')"
    }

    $parsed = ConvertFrom-Json -InputObject $raw

    # Emit collection items individually rather than returning
    # the entire JSON array as a single pipeline object.
    if ($parsed -is [array]) {
        foreach ($item in $parsed) {
            Write-Output $item
        }
    }
    else {
        Write-Output $parsed
    }
}

function Invoke-AzChecked {
    param([Parameter(Mandatory)][string[]]$Arguments)
    & az @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Azure CLI command failed: az $($Arguments -join ' ')" }
}

function Find-Resource {
    param([Parameter(Mandatory)][string]$ResourceGroup, [Parameter(Mandatory)][string]$ResourceType, [Parameter(Mandatory)][string]$Name)
    $items = @(Get-AzJson -Arguments @('resource','list','--resource-group',$ResourceGroup))
    return @($items | Where-Object { $_.type -eq $ResourceType -and $_.name -eq $Name }) | Select-Object -First 1
}

Write-Host "`nE-Commerce v1.4.0 Infrastructure Cleanup" -ForegroundColor Cyan
$account = Get-AzJson -Arguments @('account','show')
if ($account.id -ne $SubscriptionId) { throw "Subscription mismatch. Selected: $($account.id); expected: $SubscriptionId" }
Write-Host "Subscription verified: $($account.name) ($SubscriptionId)"

foreach ($rg in @($appRg,$bootstrapRg,$securityRg)) {
    $rgInfo = Get-AzJson -Arguments @('group','show','--name',$rg)
    if ($rgInfo.name -ne $rg) { throw "Resource group missing: $rg" }
}

$kv = Get-AzJson -Arguments @('keyvault','show','--resource-group',$securityRg,'--name',$keyVaultName)
$secret = Get-AzJson -Arguments @('keyvault','secret','show','--vault-name',$keyVaultName,'--name',$secretName,'--query','{id:id}')
if (-not $secret.id) { throw 'Required Key Vault registration secret was not found.' }
# Azure RBAC scope is a secret ARM resource ID (without the secret version).
$secretScope = "$($kv.id)/secrets/$secretName"

$appResources = @(Get-AzJson -Arguments @('resource','list','--resource-group',$appRg))
$bootstrapResources = @(Get-AzJson -Arguments @('resource','list','--resource-group',$bootstrapRg))

$externalAlertResources = @(
    Get-AzJson -Arguments @('monitor', 'scheduled-query', 'list',
        '--resource-group', $externalAlertRg
    ))

$restartAlerts = @(
    $externalAlertResources | Where-Object {$_.name -eq $restartAlertName
    })

$actionGroups = @($appResources | Where-Object {
    $_.type -eq 'Microsoft.Insights/actionGroups' -and $_.name -eq $actionGroupName
})
if ($restartAlerts.Count -gt 1 -or $actionGroups.Count -gt 1) {
    throw 'Duplicate alert or action group resources detected. Refusing cleanup.'
}
$aks = @($appResources | Where-Object { $_.type -eq 'Microsoft.ContainerService/managedClusters' -and $_.name -eq $aksName }) | Select-Object -First 1
$acr = @($appResources | Where-Object { $_.type -eq 'Microsoft.ContainerRegistry/registries' -and $_.name -eq $acrName }) | Select-Object -First 1
$containerInsightsDcrs = @($appResources | Where-Object {
    $_.type -eq 'Microsoft.Insights/dataCollectionRules' -and
    $_.name -in $containerInsightsDcrNames
})
$containerInsightsSolutions = @($appResources | Where-Object {
    $_.type -eq 'Microsoft.OperationsManagement/solutions' -and
    $_.name -eq $containerInsightsSolutionName
})
$logAnalytics = @(
    $appResources | Where-Object {
        $_.type -eq 'Microsoft.OperationalInsights/workspaces' -and
        $_.name -eq $logAnalyticsName
    }
) | Select-Object -First 1

$aksManagedResourceGroup = $null
if ($aks) {
    $aksDetail = Get-AzJson -Arguments @('aks','show','--resource-group',$appRg,'--name',$aksName)
    $aksManagedResourceGroup = $aksDetail.nodeResourceGroup
}
$vmEntry = @($bootstrapResources | Where-Object { $_.type -eq 'Microsoft.Compute/virtualMachines' -and $_.name -eq $vmName }) | Select-Object -First 1

# Exact names are defined in infra/bootstrap/main.bicep.
$networkNames = @(
    @{type='Microsoft.Network/networkInterfaces'; name="$vmName-nic"; action='network nic delete'},
    @{type='Microsoft.Network/publicIPAddresses'; name="$vmName-pip"; action='network public-ip delete'},
    @{type='Microsoft.Network/virtualNetworks'; name="$vmName-vnet"; action='network vnet delete'},
    @{type='Microsoft.Network/networkSecurityGroups'; name="$vmName-nsg"; action='network nsg delete'}
)
$netTargets = foreach ($item in $networkNames) {
    $found = @($bootstrapResources | Where-Object { $_.type -eq $item.type -and $_.name -eq $item.name }) | Select-Object -First 1
    if ($found) { [pscustomobject]@{ Type=$item.type; Name=$item.name; Id=$found.id; Action=$item.action } }
}

$vmPrincipalId = $null
$osDiskId = $null
if ($vmEntry) {
    $vm = Get-AzJson -Arguments @('vm','show','--resource-group',$bootstrapRg,'--name',$vmName)
    $vmPrincipalId = $vm.identity.principalId
    $osDiskId = $vm.storageProfile.osDisk.managedDisk.id
    if (-not $vmPrincipalId -or -not $osDiskId) { throw 'Could not discover VM managed identity and OS disk. Refusing partial cleanup.' }
    if ($osDiskId -notlike "*/resourceGroups/$bootstrapRg/providers/Microsoft.Compute/disks/*") {
        throw "OS disk is outside expected resource group: $osDiskId"
    }
    
    # Verify the VM is attached to the expected bootstrap NIC.
    $expectedNicName = "$vmName-nic"

    $nic = Get-AzJson -Arguments @(
        'network', 'nic', 'show',
        '--resource-group', $bootstrapRg,
        '--name', $expectedNicName
    )

    $attachedNics = @(
        $vm.networkProfile.networkInterfaces |
            ForEach-Object { $_.id }
    )

    if ($attachedNics.Count -ne 1 -or
        [string]::IsNullOrWhiteSpace($attachedNics[0]) -or
        [string]::IsNullOrWhiteSpace($nic.id)) {
        throw 'Expected exactly one valid VM NIC attachment.'
    }

    $attachedNicId = $attachedNics[0].TrimEnd('/')
    $expectedNicId = ([string]$nic.id).TrimEnd('/')

    if ($attachedNicId -ine $expectedNicId) {
        throw 'VM NIC attachment differs from expected bootstrap topology. Refusing cleanup.'
    }

    Write-Host "VM NIC attachment verified: $expectedNicName" -ForegroundColor Green

    }

# The system-assigned VM identity gets only Key Vault Secrets User on the named secret.
$roleTargets = @()
if ($vmPrincipalId) {
    $assignments = @(Get-AzJson -Arguments @('role','assignment','list','--scope',$secretScope))
    $roleTargets = @($assignments | Where-Object {
        $_.principalId -eq $vmPrincipalId -and
        ($_.roleDefinitionId -split '/')[-1] -eq $secretUserRoleId -and
        $_.scope -eq $secretScope
    })
    if ($roleTargets.Count -gt 1) { throw 'Multiple temporary role assignments detected; manual inspection required.' }
}

# Discover the agent pool ID directly using Azure DevOps CLI.
$poolIdText = az pipelines pool list `
    --organization $organization `
    --query "[?name=='$poolName'].id | [0]" `
    -o tsv

if ($LASTEXITCODE -ne 0) {
    throw "Failed to query Azure DevOps agent pool."
}

$poolIdText = ($poolIdText -join "").Trim()

[int]$poolId = 0

if (-not [int]::TryParse($poolIdText, [ref]$poolId) -or
    $poolId -le 0) {
    throw "Invalid agent pool ID returned: [$poolIdText]"
}

Write-Host "Azure DevOps agent pool verified: $poolName (ID: $poolId)"

$agentResponse = @(Get-AzJson -Arguments @(
    'pipelines', 'agent', 'list',
    '--organization', $organization,
    '--pool-id', "$poolId",
    '--agent-name', $agentName,
    '--include-assigned-request', 'true'
))
$agents = @($agentResponse | Where-Object { $_.name -eq $agentName })
if ($agents.Count -gt 1) { throw 'Multiple matching agents found; manual review required.' }
$agent = if ($agents.Count -eq 1) { $agents[0] } else { $null }

Write-Host "`nDELETION PREVIEW (only discovered resources)" -ForegroundColor Yellow
if ($agent) { Write-Host "  Azure DevOps agent: $agentName (pool $poolName; agent ID $($agent.id); status $($agent.status))" }
foreach ($role in $roleTargets) { Write-Host "  Temporary secret role assignment: $($role.id)" }
if ($aks) { Write-Host "  AKS: $($aks.id)" }
if ($acr) { Write-Host "  ACR: $($acr.id)" }
foreach ($alert in $restartAlerts) { Write-Host "  Restart alert ($externalAlertRg): $($alert.id)" }
foreach ($group in $actionGroups) { Write-Host "  Email action group: $($group.id)" }
foreach ($dcr in $containerInsightsDcrs) { Write-Host "  Container Insights DCR: $($dcr.id)" }
foreach ($solution in $containerInsightsSolutions) { Write-Host "  Container Insights solution: $($solution.id)" }
if ($logAnalytics) {
    Write-Host "  Log Analytics workspace: $($logAnalytics.id)"
}
Write-Warning "Default Azure Monitor workspace ($prometheusWorkspaceName) is NOT a cleanup target. Confirm its ownership and usage separately before any deletion."
if ($vmEntry) { Write-Host "  VM: $($vmEntry.id)"; Write-Host "  OS disk: $osDiskId" }
foreach ($target in $netTargets) { Write-Host "  $($target.Type): $($target.Id)" }
Write-Host "`nPRESERVED: all three RGs, $externalAlertRg and its other resources, Key Vault and PAT secret, Azure DevOps agent pool/pipelines/service connections, persistent role grants, and default/shared Azure Monitor workspace." -ForegroundColor Green

# Compare actual Azure resource IDs against the known deployment resources.
# Retrieve inventory IDs as plain text to avoid nested JSON arrays.

$appResourceIds = @(
    az resource list `
        --resource-group $appRg `
        --query "[].id" `
        -o tsv
)

if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve application resource IDs."
}

$bootstrapResourceIds = @(
    az resource list `
        --resource-group $bootstrapRg `
        --query "[].id" `
        -o tsv
)

if ($LASTEXITCODE -ne 0) {
    throw "Failed to retrieve bootstrap resource IDs."
}

# Normalize IDs before comparing.
$knownAppIds = @(
    $aks.id
    $acr.id
    $logAnalytics.id
    $actionGroups | ForEach-Object { $_.id }
    $containerInsightsDcrs | ForEach-Object { $_.id }
    $containerInsightsSolutions | ForEach-Object { $_.id }
) | Where-Object {
    $_ -is [string] -and
    -not [string]::IsNullOrWhiteSpace($_)
} | ForEach-Object {
    $_.TrimEnd('/').ToLowerInvariant()
}

$knownBootstrapIds = @(
    $vmEntry.id
    $osDiskId
    foreach ($target in $netTargets) {
        $target.Id
    }
) | Where-Object {
    $_ -is [string] -and
    -not [string]::IsNullOrWhiteSpace($_)
} | ForEach-Object {
    $_.TrimEnd('/').ToLowerInvariant()
}

$appResourceIds = @(
    $appResourceIds | Where-Object { $_ } |
        ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() }
)

$bootstrapResourceIds = @(
    $bootstrapResourceIds | Where-Object { $_ } |
        ForEach-Object { $_.TrimEnd('/').ToLowerInvariant() }
)

$unknownApp = @(
    $appResourceIds | Where-Object { $_ -notin $knownAppIds }
)

$unknownBootstrap = @(
    $bootstrapResourceIds | Where-Object {
        $_ -notin $knownBootstrapIds
    }
)

Write-Host "Actual application resources: $($appResourceIds.Count)"
Write-Host "Actual bootstrap resources: $($bootstrapResourceIds.Count)"
Write-Host "Unexpected application resources: $($unknownApp.Count)"
Write-Host "Unexpected bootstrap resources: $($unknownBootstrap.Count)"

if ($unknownApp.Count -gt 0 -or $unknownBootstrap.Count -gt 0) {
    Write-Warning "Unexpected resources detected. Cleanup will be blocked."

    $unknownApp | ForEach-Object {
        Write-Host "Unexpected application resource: $_"
    }

    $unknownBootstrap | ForEach-Object {
        Write-Host "Unexpected bootstrap resource: $_"
    }
}
else {
    Write-Host "Resource inventory verified successfully." -ForegroundColor Green
}


if (-not $Execute) {
    Write-Host "`nPREVIEW ONLY. Nothing deleted. Use -Execute after verifying targets." -ForegroundColor Green
    return
}

# Refuse to delete the VM until the agent has no active assignment/job.
if ($unknownApp.Count -gt 0 -or $unknownBootstrap.Count -gt 0) {
    throw 'Unexpected resources remain in scoped RGs. Inspect them before allowing automated cleanup.'
}
if ($agent -and $agent.assignedRequest) {
    throw 'The agent has an assigned job. Wait for the job to finish before cleanup.'
}
$confirmation = Read-Host 'Type DELETE ECOMMERCE INFRA to continue'
if ($confirmation -cne 'DELETE ECOMMERCE INFRA') { throw 'Cleanup cancelled.' }


# Snapshot exact discovered targets for a concise post-confirmation plan and final report.
$cleanupTargets = @(
    if ($agent) { [pscustomobject]@{ Label="Azure DevOps agent: $agentName"; Id=$null; Kind='agent' } }
    foreach ($role in $roleTargets) { [pscustomobject]@{ Label='Temporary Key Vault role assignment'; Id=$role.id; Kind='role' } }
    foreach ($alert in $restartAlerts) { [pscustomobject]@{ Label="Restart alert: $($alert.name)"; Id=$alert.id; Kind='alert' } }
    foreach ($group in $actionGroups) { [pscustomobject]@{ Label="Action group: $($group.name)"; Id=$group.id; Kind='action' } }
    foreach ($item in @($aks,$acr,$logAnalytics)) { if ($item) { [pscustomobject]@{ Label="$($item.name) ($($item.type.Split('/')[-1]))"; Id=$item.id; Kind='app' } } }
    foreach ($item in $containerInsightsSolutions) { [pscustomobject]@{ Label="Container Insights solution: $($item.name)"; Id=$item.id; Kind='app' } }
    foreach ($item in $containerInsightsDcrs) { [pscustomobject]@{ Label="Container Insights DCR: $($item.name)"; Id=$item.id; Kind='app' } }
    if ($vmEntry) { [pscustomobject]@{ Label="Linux agent VM: $vmName"; Id=$vmEntry.id; Kind='bootstrap' } }
    if ($osDiskId) { [pscustomobject]@{ Label='Linux agent OS disk'; Id=$osDiskId; Kind='bootstrap' } }
    foreach ($item in $netTargets) { [pscustomobject]@{ Label="Agent network: $($item.Name)"; Id=$item.Id; Kind='bootstrap' } }
    if ($aksManagedResourceGroup) { [pscustomobject]@{ Label="AKS-managed RG: $aksManagedResourceGroup"; Id=$null; Kind='aksrg' } }
)
Write-Host "`nCLEANUP PLAN ($($cleanupTargets.Count) discovered targets)" -ForegroundColor Cyan
foreach ($target in $cleanupTargets) { Write-Host "  - $($target.Label)" }
Write-Host 'Preserved: shared RGs, Key Vault/secret, DevOps pool/pipelines and default Azure Monitor workspace.'

# Report after success OR the first failed deletion. Never report success from CLI exit codes alone.
try {

if ($agent) {
    Write-Host 'Deregistering the exact Azure DevOps agent (preserving the pool)...'
    # Invoke the Azure DevOps REST agent-delete route *through the authenticated Azure DevOps CLI*.
    # This operation must be tested on the actual organization; stops on errors.
    Invoke-AzChecked -Arguments @('devops','invoke','--organization',$organization,'--area','distributedtask','--resource','agents','--route-parameters',"poolId=$poolId","agentId=$($agent.id)",'--http-method','DELETE','--api-version','7.1','--output','json')
}

foreach ($role in $roleTargets) {
    Write-Host 'Removing only VM managed identity Key Vault Secrets User assignment...'
    Invoke-AzChecked -Arguments @('role','assignment','delete','--ids',$role.id)
}

# Delete only the explicitly identified restart alert and action group.
# Do not delete or otherwise modify the NetworkWatcherRG resource group.
foreach ($alert in $restartAlerts) {
    Write-Host "Deleting restart alert ($externalAlertRg): $($alert.name)"
    Invoke-AzChecked -Arguments @('monitor','scheduled-query','delete','--resource-group',$externalAlertRg,'--name',$alert.name,'--yes')
}
foreach ($group in $actionGroups) {
    Write-Host "Deleting email action group: $($group.name)"
    Invoke-AzChecked -Arguments @('monitor','action-group','delete','--resource-group',$appRg,'--name',$group.name)
}

if ($aks) {
    Write-Host 'Deleting AKS (waiting for completion)...'
    Invoke-AzChecked -Arguments @('aks','delete','--resource-group',$appRg,'--name',$aksName,'--yes')
}
if ($acr) {
    Write-Host 'Deleting ACR...'
    Invoke-AzChecked -Arguments @('acr','delete','--resource-group',$appRg,'--name',$acrName,'--yes')
}
# Do not delete the Log Analytics workspace before dependent solutions and rules.
# The AKS DCR association is scoped to AKS and should disappear with the AKS deletion.
# Each delete is separate, so failure identifies the exact resource.
foreach ($solution in $containerInsightsSolutions) {
    $remaining = Find-Resource -ResourceGroup $appRg -ResourceType $solution.type -Name $solution.name
    if ($remaining) {
        Write-Host "Deleting Container Insights solution: $($solution.name)"
        Invoke-AzChecked -Arguments @('resource','delete','--ids',$remaining.id)
    }
}
foreach ($dcr in $containerInsightsDcrs) {
    $remaining = Find-Resource -ResourceGroup $appRg -ResourceType $dcr.type -Name $dcr.name
    if ($remaining) {
        Write-Host "Deleting Container Insights DCR: $($dcr.name)"
        Invoke-AzChecked -Arguments @('resource','delete','--ids',$remaining.id)
    }
}
if ($logAnalytics) {
    Write-Host "Deleting disposable Log Analytics workspace..."

    Invoke-AzChecked -Arguments @(
        'monitor', 'log-analytics', 'workspace', 'delete',
        '--resource-group', $appRg,
        '--workspace-name', $logAnalyticsName,
        '--yes'
    )
}
if ($vmEntry) {
    Write-Host 'Deleting Linux agent VM (waiting for completion)...'
    Invoke-AzChecked -Arguments @('vm','delete','--resource-group',$bootstrapRg,'--name',$vmName,'--yes')
}

# OS disk may already have been removed by the VM's deleteOption.
if ($osDiskId) {
    $remainingDisks = @(Get-AzJson -Arguments @('disk','list','--resource-group',$bootstrapRg))
    if (@($remainingDisks | Where-Object { $_.id -eq $osDiskId }).Count -gt 0) {
        Write-Host 'Deleting original VM managed OS disk...'
        Invoke-AzChecked -Arguments @('disk','delete','--ids',$osDiskId,'--yes')
    }
}

# Order releases dependencies: NIC -> public IP -> VNet -> NSG.
foreach ($target in $netTargets) {
    $current = Find-Resource -ResourceGroup $bootstrapRg -ResourceType $target.Type -Name $target.Name
    if ($current) {
        Write-Host "Deleting $($target.Name)..."
        $command = @($target.Action.Split(' ')) + @('--resource-group',$bootstrapRg,'--name',$target.Name)
        Invoke-AzChecked -Arguments $command
    }
}

Write-Host "`nFinal verification..." -ForegroundColor Cyan
$leftApp = @(Get-AzJson -Arguments @('resource','list','--resource-group',$appRg))
$leftBootstrap = @(Get-AzJson -Arguments @('resource','list','--resource-group',$bootstrapRg))

$leftExternalAlerts = @(
    Get-AzJson -Arguments @(
        'monitor', 'scheduled-query', 'list',
        '--resource-group', $externalAlertRg
    ) | Where-Object {
        $_.name -eq $restartAlertName
    }
)
$remainingAgents = @(Get-AzJson -Arguments @('pipelines','agent','list','--organization',$organization,'--pool-id',"$poolId"))
$remainingTargetAgent = @($remainingAgents | Where-Object { $_.name -eq $agentName })
$remainingRoles = @()
if ($vmPrincipalId) {
    $remainingRoles = @(Get-AzJson -Arguments @('role','assignment','list','--scope',$secretScope) | Where-Object {
        $_.principalId -eq $vmPrincipalId -and ($_.roleDefinitionId -split '/')[-1] -eq $secretUserRoleId -and $_.scope -eq $secretScope
    })
}
$stillKnownApp = @(
    $leftApp | Where-Object {
        $_.id -and
        ([string]$_.id).TrimEnd('/').ToLowerInvariant() -in $knownAppIds
    }
)

$stillKnownBootstrap = @(
    $leftBootstrap | Where-Object {
        $_.id -and
        ([string]$_.id).TrimEnd('/').ToLowerInvariant() -in $knownBootstrapIds
    }
)
# Fail if any application resources remain, including newly generated monitoring resources.
# The bootstrap RG is intentionally checked for exact known resources separately.
if ($leftApp.Count -gt 0 -or $leftExternalAlerts.Count -gt 0 -or $stillKnownBootstrap.Count -gt 0 -or $remainingTargetAgent.Count -gt 0 -or $remainingRoles.Count -gt 0) {
    Write-Warning 'Some targeted resources or registrations remain. Inspect them before redeploying.'
    @($leftApp + $leftExternalAlerts + $stillKnownBootstrap) | Select-Object name,type,id | Format-Table -AutoSize
    throw 'Infrastructure cleanup verification FAILED.'
}
if ($aksManagedResourceGroup) {
    $mcExists = & az group exists --name $aksManagedResourceGroup -o tsv
    if ($LASTEXITCODE -ne 0) { throw 'Failed to verify AKS-managed resource group deletion.' }
    if ($mcExists -eq 'true') { throw "AKS-managed resource group still exists: $aksManagedResourceGroup" }
}
Write-Host 'App RG empty; external restart alert, targeted bootstrap resources, agent registration, temporary RBAC assignment and AKS-managed RG verified removed.' -ForegroundColor Green
Write-Warning "This does not prove subscription-wide cleanup. Check the default Azure Monitor workspace ($prometheusWorkspaceName), Prometheus DCR/DCRA and recording rule groups, monitoring alerts/action groups, and any other out-of-scope resource groups separately."

}
finally {
    Write-Host "`n========== VERIFIED CLEANUP REPORT ==========" -ForegroundColor Cyan
    $inventoryErrors = @()
    $finalApp = @(); $finalBootstrap = @(); $finalAlerts = @(); $finalAgents = @(); $finalRoles = @()
    $appOk = $false; $bootstrapOk = $false; $alertsOk = $false; $agentsOk = $false; $rolesOk = $false; $aksRgOk = $false
    try { $finalApp = @(Get-AzJson -Arguments @('resource','list','--resource-group',$appRg)); $appOk = $true } catch { $inventoryErrors += "App RG: $_" }
    try { $finalBootstrap = @(Get-AzJson -Arguments @('resource','list','--resource-group',$bootstrapRg)); $bootstrapOk = $true } catch { $inventoryErrors += "Bootstrap RG: $_" }
    try { $finalAlerts = @(Get-AzJson -Arguments @('monitor','scheduled-query','list','--resource-group',$externalAlertRg)); $alertsOk = $true } catch { $inventoryErrors += "Alert RG: $_" }
    try { $finalAgents = @(Get-AzJson -Arguments @('pipelines','agent','list','--organization',$organization,'--pool-id',"$poolId")); $agentsOk = $true } catch { $inventoryErrors += "DevOps agents: $_" }
    try { $finalRoles = @(Get-AzJson -Arguments @('role','assignment','list','--scope',$secretScope)); $rolesOk = $true } catch { $inventoryErrors += "Key Vault RBAC: $_" }
    try {
        if ($aksManagedResourceGroup) {
            $aksRgExists = (& az group exists --name $aksManagedResourceGroup --output tsv) -join ''
            if ($LASTEXITCODE -ne 0) { throw 'AKS-managed RG lookup failed' }
        }
        $aksRgOk = $true
    } catch { $inventoryErrors += "AKS-managed RG: $_" }

    $reportFailed = $false
    foreach ($target in $cleanupTargets) {
        $status = 'UNKNOWN'
        switch ($target.Kind) {
            'app' { if ($appOk) { $status = if (@($finalApp | Where-Object { $_.id -eq $target.Id }).Count) { 'REMAINING' } else { 'REMOVED' } } }
            'bootstrap' { if ($bootstrapOk) { $status = if (@($finalBootstrap | Where-Object { $_.id -eq $target.Id }).Count) { 'REMAINING' } else { 'REMOVED' } } }
            'alert' { if ($alertsOk) { $status = if (@($finalAlerts | Where-Object { $_.id -eq $target.Id }).Count) { 'REMAINING' } else { 'REMOVED' } } }
            'action' { if ($appOk) { $status = if (@($finalApp | Where-Object { $_.id -eq $target.Id }).Count) { 'REMAINING' } else { 'REMOVED' } } }
            'agent' { if ($agentsOk) { $status = if (@($finalAgents | Where-Object { $_.name -eq $agentName }).Count) { 'REMAINING' } else { 'REMOVED' } } }
            'role' { if ($rolesOk) { $status = if (@($finalRoles | Where-Object { $_.id -eq $target.Id }).Count) { 'REMAINING' } else { 'REMOVED' } } }
            'aksrg' { if ($aksRgOk) { $status = if ($aksRgExists -eq 'true') { 'REMAINING' } else { 'REMOVED' } } }
        }
        Write-Host "  [$status] $($target.Label)"
        if ($status -ne 'REMOVED') { $reportFailed = $true }
    }
    if ($appOk -and $finalApp.Count -gt 0) { $reportFailed = $true; Write-Warning "Application RG still contains $($finalApp.Count) resource(s)." }
    if ($bootstrapOk -and @($finalBootstrap | Where-Object { $_.id -and ([string]$_.id).TrimEnd('/').ToLowerInvariant() -in $knownBootstrapIds }).Count -gt 0) { $reportFailed = $true; Write-Warning 'Known bootstrap resources still remain.' }
    foreach ($issue in $inventoryErrors) { Write-Warning "Verification unavailable: $issue" }
    if ($reportFailed -or $inventoryErrors.Count -gt 0) {
        Write-Warning 'CLEANUP INCOMPLETE or not fully verified. Inspect REMAINING/UNKNOWN resources; do not blindly rerun.'
        Write-Host 'Review the failed command and delete only the specific remaining resource after verifying its ownership.'
    }
    else { Write-Host 'All discovered targets verified removed. Shared resources were outside cleanup scope.' -ForegroundColor Green }
    Write-Host '============================================'
}
