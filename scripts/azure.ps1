#requires -Version 7.0
param([ValidateSet('plan', 'run', 'down')][string]$Action = 'plan', [ValidateRange(1, 200)][decimal]$BudgetUsd = 200)
. (Join-Path $PSScriptRoot 'common.ps1') -Target azure
$profile = Get-Content (Join-Path $root 'azure/profile.json') -Raw | ConvertFrom-Json -AsHashtable
$sessionFile = Join-Path $state 'session.json'
New-Item -ItemType Directory -Path $state -Force | Out-Null

function Invoke-AzJson([string[]]$Arguments) { Invoke-Tool az ($Arguments + @('--output', 'json')) | ConvertFrom-Json -AsHashtable }
function Save-Session([hashtable]$Session) { $Session | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $sessionFile }
function Remove-Demo {
    if (-not (Test-Path -LiteralPath $sessionFile)) { Write-Host 'No recorded Azure demo to remove.'; return }
    $owned = Get-Content $sessionFile -Raw | ConvertFrom-Json -AsHashtable
    if ($owned.runId -cnotmatch '^[a-f0-9]{32}$' -or $owned.group -cne ('rg-managed-platform-' + $owned.runId.Substring(0, 10)) -or
        $owned.subscription -cnotmatch '^[a-f0-9-]{36}$') { throw 'Invalid Azure ownership record.' }
    $groups = @($owned.group) + @('hub', 'member-a', 'member-b' | ForEach-Object { "$($owned.group)-nodes-$_" })
    # Check every identity before starting any deletion. Never adopt a similarly named group.
    foreach ($group in $groups) {
        if ((Invoke-Tool az @('group', 'exists', '--name', $group, '--subscription', $owned.subscription)) -ceq 'false') { continue }
        $actual = Invoke-AzJson @('group', 'show', '--name', $group, '--subscription', $owned.subscription)
        if ($group -ceq $owned.group) {
            if ($actual.tags['project'] -cne 'managed-container-platform' -or $actual.tags['runId'] -cne $owned.runId) { throw "Refusing unowned resource group: $group" }
        } else {
            $role = $group.Substring(($owned.group + '-nodes-').Length)
            $clusterId = "/subscriptions/$($owned.subscription)/resourceGroups/$($owned.group)/providers/Microsoft.ContainerService/managedClusters/platform-$role"
            if ($actual['managedBy'] -ine $clusterId) { throw "Refusing unrelated node resource group: $group" }
        }
    }
    foreach ($group in $groups) {
        if ((Invoke-Tool az @('group', 'exists', '--name', $group, '--subscription', $owned.subscription)) -ceq 'false') { continue }
        Invoke-Tool az @('group', 'delete', '--name', $group, '--subscription', $owned.subscription, '--yes', '--no-wait', '--output', 'none') | Out-Null
        $deadline = [DateTime]::UtcNow.AddMinutes(25)
        while ((Invoke-Tool az @('group', 'exists', '--name', $group, '--subscription', $owned.subscription)) -cne 'false') {
            if ([DateTime]::UtcNow -gt $deadline) { throw "Deletion is still pending: $group. Ownership record retained." }
            Start-Sleep -Seconds 10
        }
    }
    $owned['cleanedAt'] = [DateTime]::UtcNow.ToString('o')
    Save-Session $owned
    @{runId = $owned.runId; completedAt = $owned.cleanedAt; removedGroups = $groups
      activeResourcesRemoved = $true; keyVaultSoftDeleteRetentionDays = 7} |
        ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $state 'teardown-evidence.json')
    foreach ($file in @($kubeconfig, (Join-Path $state 'tenant-kubeconfig'), (Join-Path $state 'sentinel.txt'))) {
        if (Test-Path -LiteralPath $file -PathType Leaf) { Remove-Item -LiteralPath $file }
    }
    Write-Host 'Azure demo and its node resource groups are gone. Key Vault keeps its nonbillable seven-day soft-delete record.'
}

if ($Action -ceq 'down') { Remove-Demo; return }
$account = Invoke-AzJson @('account', 'show')
$subscription = Invoke-AzJson @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/$($account.id)?api-version=2022-12-01")
if ($subscription.state -cne 'Enabled' -or $subscription.subscriptionPolicies.spendingLimit -cne 'On' -or
    $subscription.subscriptionPolicies.quotaId -notlike 'FreeTrial*') { throw 'This demo profile requires an enabled free trial with its spending limit on.' }
$billingAccounts = Invoke-AzJson @('billing', 'account', 'list')
$credits = @()
foreach ($billing in $billingAccounts) {
    if ($billing.agreementType -cne 'MicrosoftCustomerAgreement') { continue }
    foreach ($billingProfile in (Invoke-AzJson @('billing', 'profile', 'list', '--account-name', $billing.name))) {
        $uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$($billing.name)/billingProfiles/$($billingProfile.name)/providers/Microsoft.Consumption/lots?api-version=2023-03-01"
        $lots = Invoke-AzJson @('rest', '--method', 'get', '--url', $uri)
        $credits += @($lots.value.properties | Where-Object {
            $_.source -ceq 'Azure sign-up credit' -and $_.closedBalance.currency -ceq 'USD' -and
            [DateTimeOffset]$_.startDate -le [DateTimeOffset]::UtcNow -and
            [DateTimeOffset]$_.expirationDate -gt [DateTimeOffset]::UtcNow.AddHours($profile.demoHours)
        })
    }
}
if ($credits.Count -ne 1) { throw 'Cannot verify one active USD trial credit lot for this demo.' }
$credit = $credits[0]
$checks = @()
foreach ($cluster in $profile.clusters) {
    $usage = Invoke-AzJson @('vm', 'list-usage', '--location', $cluster.location)
    foreach ($quota in @('cores', $cluster.vmFamily)) {
        $item = @($usage | Where-Object { $_.name.value -ieq $quota })
        if ($item.Count -ne 1 -or ([int]$item[0].limit - [int]$item[0].currentValue) -lt 4) { throw "Insufficient $quota quota in $($cluster.location)." }
    }
    $uri = "https://management.azure.com/subscriptions/$($account.id)/providers/Microsoft.Compute/skus?api-version=2021-07-01&%24filter=location%20eq%20%27$($cluster.location)%27"
    $catalog = Invoke-AzJson @('rest', '--method', 'get', '--url', $uri)
    $sku = @($catalog.value | Where-Object { $_.name -ceq $cluster.vmSize -and $_.resourceType -ceq 'virtualMachines' })
    if ($sku.Count -ne 1 -or $catalog['nextLink'] -or @($sku[0].restrictions | Where-Object type -ceq Location).Count -gt 0) { throw "VM size is unavailable in $($cluster.location)." }
    $available = Invoke-AzJson @('aks', 'get-versions', '--location', $cluster.location)
    $minor = @($available.values | Where-Object { $_.version -ceq (([version]$versions.kubernetes).ToString(2)) })
    if ($minor.Count -ne 1 -or -not $minor[0].patchVersions.ContainsKey($versions.kubernetes)) { throw "Pinned AKS version unavailable in $($cluster.location)." }
    $filter = "serviceName eq 'Virtual Machines' and armSkuName eq '$($cluster.vmSize)' and armRegionName eq '$($cluster.location)' and priceType eq 'Consumption'"
    $prices = Invoke-RestMethod ('https://prices.azure.com/api/retail/prices?$filter=' + [Uri]::EscapeDataString($filter))
    $rates = @($prices.Items | Where-Object { $_.productName -like 'Virtual Machines *' -and $_.productName -notlike '*Windows*' -and $_.skuName -notmatch 'Spot|Low Priority' -and $_.unitOfMeasure -ceq '1 Hour' })
    if ($rates.Count -ne 1 -or $prices.NextPageLink) { throw 'Cannot identify one current Linux VM price.' }
    $checks += @{name = $cluster.name; location = $cluster.location; vmSize = $cluster.vmSize
        vmHourlyUsd = $rates[0].retailPrice; nodes = 1; quotaPassed = $true; version = $versions.kubernetes}
}
# Reserve twice the VM estimate plus $5 for disks, networking, ACR and small demo traffic.
$reserve = [Math]::Ceiling(($checks.vmHourlyUsd | Measure-Object -Sum).Sum * $profile.demoHours * 2 + 5)
if ($reserve -gt $BudgetUsd -or $reserve -gt $credit.closedBalance.value) { throw 'Estimated reserve exceeds the allowed budget or available trial balance.' }
$plan = @{checkedAt = [DateTime]::UtcNow.ToString('o'); creditUsd = $credit.closedBalance.value
    creditExpiresAt = $credit.expirationDate; spendingLimit = 'On'; budgetUsd = $BudgetUsd
    reservedEstimateUsd = $reserve; demoHours = $profile.demoHours; clusters = $checks; versions = $versions}
$plan | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $state 'preflight-evidence.json')
Invoke-Tool az @('bicep', 'build', '--file', (Join-Path $root 'azure/main.bicep'), '--outfile', (Join-Path $state 'main.json')) | Out-Null
Write-Host "Azure preflight passed. Four-hour reserve: USD $reserve; reported trial balance: USD $($credit.closedBalance.value)."
if ($Action -ceq 'plan') { return }
if (Test-Path -LiteralPath $sessionFile) {
    $previous = Get-Content $sessionFile -Raw | ConvertFrom-Json -AsHashtable
    if (-not $previous['cleanedAt']) { throw 'A previous Azure demo is still recorded. Run azure.ps1 down first.' }
}
if (@(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0) { throw 'Commit the demo source before running so image and evidence provenance are clean.' }
$runId = [guid]::NewGuid().ToString('N')
$group = 'rg-managed-platform-' + $runId.Substring(0, 10)
foreach ($name in @($group) + @($profile.clusters | ForEach-Object { "$group-nodes-$($_.name)" })) {
    if ((Invoke-Tool az @('group', 'exists', '--name', $name, '--subscription', $account.id)) -cne 'false') { throw 'Refusing to adopt an existing demo or node resource group.' }
}
$session = @{runId = $runId; group = $group; subscription = $account.id; startedAt = [DateTime]::UtcNow.ToString('o')
    expiresAt = [DateTime]::UtcNow.AddHours($profile.demoHours).ToString('o'); commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')}
Save-Session $session
try {
    $operatorIp = (Invoke-RestMethod 'https://api.ipify.org').Trim()
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($operatorIp, [ref]$parsed) -or $parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Cannot identify the operator public IPv4 address.' }
    $operatorId = Invoke-Tool az @('ad', 'signed-in-user', 'show', '--query', 'id', '--output', 'tsv')
    Invoke-Tool az @('group', 'create', '--name', $group, '--location', $profile.clusters[0].location, '--subscription', $account.id,
        '--tags', 'project=managed-container-platform', "runId=$runId", "expiresAt=$($session.expiresAt)", '--output', 'none') | Out-Null
    $values = @{clusters = $profile.clusters; kubernetesVersion = $versions.kubernetes; operatorCidr = "$operatorIp/32"
        operatorObjectId = $operatorId; runId = $runId; expiresAt = $session.expiresAt}
    $parameters = @{}
    foreach ($key in $values.Keys) { $parameters[$key] = @{value = $values[$key]} }
    $parametersFile = Join-Path $state 'parameters.json'
    @{parameters = $parameters} | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $parametersFile
    $deployArgs = @('deployment', 'group', 'validate', '--resource-group', $group, '--subscription', $account.id,
        '--template-file', (Join-Path $state 'main.json'), '--parameters', "@$parametersFile", '--output', 'none')
    Invoke-Tool az $deployArgs | Out-Null
    $deployArgs[2] = 'create'
    Invoke-Tool az ($deployArgs + @('--name', 'platform-demo', '--no-wait')) | Out-Null
    $deadline = [DateTime]::UtcNow.AddMinutes(35)
    do {
        $deployment = Invoke-AzJson @('deployment', 'group', 'show', '--resource-group', $group, '--name', 'platform-demo', '--subscription', $account.id)
        $phase = $deployment.properties.provisioningState
        if ($phase -cin @('Failed', 'Canceled')) { throw "Azure deployment $phase. Inspect its deployment operations; cleanup will run." }
        if ($phase -ceq 'Succeeded') { break }
        if ([DateTime]::UtcNow -gt $deadline) { throw 'Azure provisioning exceeded thirty-five minutes.' }
        Start-Sleep -Seconds 15
    } while ($true)
    $outputs = $deployment.properties.outputs
    foreach ($key in @('registryName', 'registryServer', 'vaultName', 'vaultUri', 'identityClientId', 'identityTenantId', 'clusterIds')) { $session[$key] = $outputs[$key].value }
    $session['registry'] = $session.registryName
    Save-Session $session
    foreach ($cluster in $profile.clusters) {
        $context = Get-Context $cluster.name
        Invoke-Tool az @('aks', 'get-credentials', '--resource-group', $group, '--name', "platform-$($cluster.name)", '--subscription', $account.id,
            '--admin', '--file', $kubeconfig, '--context', $context, '--overwrite-existing', '--output', 'none') | Out-Null
        $received = Invoke-Tool kubectl @('--kubeconfig', $kubeconfig, 'config', 'current-context')
        if ($received -cne $context) {
            if ($received -cne "$context-admin") { throw 'Azure CLI returned an unexpected context identity.' }
            Invoke-Tool kubectl @('--kubeconfig', $kubeconfig, 'config', 'rename-context', $received, $context) | Out-Null
        }
        if (-not $IsWindows) { [IO.File]::SetUnixFileMode($kubeconfig, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
        Invoke-Kube $cluster.name @('wait', 'nodes', '--all', '--for=condition=Ready', '--timeout=300s') | Write-Host
    }
    & (Join-Path $PSScriptRoot 'fleet.ps1') -Target azure
    & (Join-Path $PSScriptRoot 'test-fleet.ps1') -Target azure
    & (Join-Path $PSScriptRoot 'platform.ps1') -Target azure
    Set-Content -LiteralPath (Join-Path $state 'sentinel.txt') -Value 'managed-platform-demo' -NoNewline
    Wait-Until 'Key Vault bootstrap role propagation' {
        try {
            Invoke-Tool az @('keyvault', 'secret', 'set', '--vault-name', $session.vaultName, '--name', 'platform-sentinel',
                '--file', (Join-Path $state 'sentinel.txt'), '--output', 'none') 2> (Join-Path $state 'vault-bootstrap-error.txt') | Out-Null
            return $true
        } catch { return $false }
    } 180
    & (Join-Path $PSScriptRoot 'test-identity.ps1')
    & (Join-Path $PSScriptRoot 'test-platform.ps1') -Target azure -SkipBootstrap
    & (Join-Path $PSScriptRoot 'test-safe-releases.ps1') -Target azure
    @{commit = $session.commit; workingTreeDirty = $false; runId = $runId; completedAt = [DateTime]::UtcNow.ToString('o')
        infrastructure = $checks; preflight = $plan; azureReleaseSuitePassed = $true; workloadIdentityPassed = $true} |
        ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $state 'azure-evidence.json')
    Write-Host 'Azure proof passed. Removing the temporary resources now.'
} finally { Remove-Demo }
