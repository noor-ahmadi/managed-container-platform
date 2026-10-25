#requires -Version 7.0
param([ValidateSet('local', 'azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
# Renew the one-hour tenant and observer credentials after the core fault suite.
& (Join-Path $PSScriptRoot 'platform.ps1') -Target $Target
$receipt = Get-Content (Join-Path $state 'deployment-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$serviceName = $receipt.release.spec.serviceName
$source = $receipt.release.status.sourceNamespace
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json -AsHashtable
$cli = Join-Path $root 'src/Platform/bin/Debug/net10.0/platform.dll'
$tenantArgs = @('--kubeconfig', (Join-Path $state 'tenant-kubeconfig'), '--context', 'tenant-demo', '--namespace', 'tenant-demo', '--output', 'json')
function Invoke-Platform([string[]]$Arguments) { Invoke-Tool dotnet (@($cli) + $Arguments + $tenantArgs) | ConvertFrom-Json -AsHashtable }
function Get-Release([string]$Name) { Invoke-Kube hub @('get', 'release', $Name, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable }
function Wait-Succeeded([string]$Name) {
    $script:completedRelease = $null
    Wait-Until "successful scaled release $Name" {
        $current = Get-Release $Name
        if (-not $current['status']) { return $false }
        if ($current.status['failure']) { throw $current.status.failure }
        if ($current.status.phase -ceq 'Succeeded') { $script:completedRelease = $current; return $true }
        return $false
    } 900
    $script:completedRelease
}
function Get-Deployment([string]$Member) { Invoke-Kube $Member @('get', 'deployment/application', '-n', $source, '-o', 'json') | ConvertFrom-Json -AsHashtable }
function Wait-Replicas([int]$Count) {
    Wait-Until "$Count ready replicas on both members" {
        foreach ($member in @('member-a', 'member-b')) {
            $deployment = Get-Deployment $member
            if ($deployment.spec.replicas -ne $Count -or $deployment.status['readyReplicas'] -ne $Count -or
                $deployment.status['updatedReplicas'] -ne $Count -or $deployment.status.observedGeneration -ne $deployment.metadata.generation) { return $false }
        }
        return $true
    } 240
}
function Get-MemberB {
    $deployment = Get-Deployment member-b
    $sets = Invoke-Kube member-b @('get', 'replicasets', '-n', $source, '-l', 'role=application', '-o', 'json') | ConvertFrom-Json
    @{image = $deployment.spec.template.spec.containers[0].image
      template = $deployment.spec.template | ConvertTo-Json -Depth 40 -Compress
      replicaSets = @($sets.items.metadata.uid | Sort-Object) -join ','}
}
function Get-ScalingState {
    $result = @{}
    foreach ($member in @('member-a', 'member-b')) {
        $deployment = Get-Deployment $member
        $scaler = Invoke-Kube $member @('get', 'scaledobject/application', '-n', $source, '-o', 'json') | ConvertFrom-Json -AsHashtable
        $hpa = Invoke-Kube $member @('get', 'hpa/keda-hpa-application', '-n', $source, '-o', 'json') | ConvertFrom-Json -AsHashtable
        if ($scaler.spec.minReplicaCount -ne 2 -or $scaler.spec.maxReplicaCount -ne 6 -or $hpa.spec.minReplicas -ne 2 -or $hpa.spec.maxReplicas -ne 6) { throw 'Replica bounds changed.' }
        $works = Invoke-Kube hub @('get', 'works.v1beta1.placement.kubernetes-fleet.io', '-n', "fleet-member-$member", '-l', "kubernetes-fleet.io/parent-CRP=$source", '-o', 'json') | ConvertFrom-Json -AsHashtable
        $applications = @($works.items.spec.workload.manifests | Where-Object { $_.kind -ceq 'Deployment' -and $_.metadata.name -ceq 'application' })
        if ($applications.Count -ne 1 -or $applications[0].spec.ContainsKey('replicas')) { throw 'Fleet still owns application replicas.' }
        $result[$member] = @{deployment = $deployment; scaler = $scaler; hpa = $hpa; fleetReplicaFieldAbsent = $true}
    }
    $result
}

$service = Get-Content (Join-Path $root 'samples/autoscaling.json') -Raw | ConvertFrom-Json
$service.name = $serviceName
$service.spec.imageRepository = ($images['sample-api'] -split '@')[0]
$serviceFile = Join-Path $state 'autoscaling-service.json'
$service | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $serviceFile
Invoke-Platform @('service', 'apply', $serviceFile) | Out-Null
$request = Invoke-Platform @('release', 'create', $serviceName, '--image', $images['sample-api'])
$baseline = Wait-Succeeded $request.metadata.name
if ($baseline.status.gatePolicy -cne 'http-health-scaled-v1') { throw 'Scaled release did not select its health policy.' }
Wait-Replicas 2
$atTwo = Get-ScalingState
$createdLoads = @()
try {
    foreach ($member in @('member-a', 'member-b')) {
        if (Invoke-Kube $member @('get', 'deployment/autoscale-load', '-n', 'platform-observers', '--ignore-not-found', '-o', 'name')) { throw 'Refusing to replace an existing load fixture.' }
        $traffic = Invoke-Kube $member @('get', 'deployment/traffic', '-n', $source, '-o', 'json') | ConvertFrom-Json -AsHashtable
        foreach ($field in @('serviceAccountName', 'serviceAccount')) { $traffic.spec.template.spec.Remove($field) }
        $traffic.spec.template.spec.containers[0].args = @('traffic', "http://application.${source}.svc.cluster.local:8080/")
        Set-KubeResource $member @{apiVersion = 'apps/v1'; kind = 'Deployment'; metadata = @{name = 'autoscale-load'; namespace = 'platform-observers'}
            spec = @{replicas = 6; selector = $traffic.spec.selector; template = $traffic.spec.template}}
        $createdLoads += $member
        Invoke-Kube $member @('rollout', 'status', 'deployment/autoscale-load', '-n', 'platform-observers', '--timeout=180s') | Write-Host
        $load = Invoke-Kube $member @('get', 'pods', '-n', 'platform-observers', '-l', "platform.example.com/service=$serviceName,role=traffic", '-o', 'json') | ConvertFrom-Json -AsHashtable
        if ($load.items.Count -ne 6 -or @($load.items | Where-Object { $_.spec.serviceAccountName -cne 'default' -or $_.spec.automountServiceAccountToken -cne $false }).Count -ne 0) { throw 'Load pods did not use their namespace account without a token mount.' }
        $account = Invoke-Kube $member @('get', 'deployment/keda-operator', '-n', 'platform-scaling', '-o', 'jsonpath={.spec.template.spec.serviceAccountName}')
        $permission = & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) auth can-i get secrets -n $source "--as=system:serviceaccount:platform-scaling:$account"
        if ($LASTEXITCODE -ne 1 -or $permission -cne 'no') { throw 'Scaling operator can read workload secrets.' }
    }
    Wait-Replicas 6
    $atSix = Get-ScalingState
    Invoke-Kube hub @('rollout', 'restart', 'deployment/platform-worker', '-n', 'platform-system') | Write-Host
    Invoke-Kube hub @('rollout', 'status', 'deployment/platform-worker', '-n', 'platform-system', '--timeout=90s') | Write-Host
    $until = [DateTime]::UtcNow.AddSeconds(45)
    do {
        foreach ($member in @('member-a', 'member-b')) { if ((Get-Deployment $member).spec.replicas -ne 6) { throw 'Fleet or the worker reset autoscaled replicas.' } }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $until)
    $request = Invoke-Platform @('release', 'create', $serviceName, '--image', $images['sample-api'])
    $underLoad = Wait-Succeeded $request.metadata.name
    foreach ($member in @('member-a', 'member-b')) {
        if ($underLoad.status.gates[$member].expectedInstances -ne 6 -or $underLoad.status.gates[$member].health.values.instances -ne 6) { throw 'A scaled rollout skipped an instance.' }
    }
    $beforeB = Get-MemberB
    $request = Invoke-Platform @('release', 'create', $serviceName, '--image', $images['sample-api-error'])
    $script:recovered = $null
    Wait-Until 'scaled failure is contained and its retained bundle is restored' {
        $current = Get-Release $request.metadata.name
        $currentB = Get-MemberB
        foreach ($key in $beforeB.Keys) { if ($currentB[$key] -cne $beforeB[$key]) { throw 'Scaled failure changed member B.' } }
        if ($current['status'] -and $current.status['recoveryFailure']) { throw $current.status.recoveryFailure }
        if ($current['status'] -and $current.status.phase -ceq 'RolledBack') { $script:recovered = $current; return $true }
        return $false
    } 900
    if ($recovered.status.gates.'member-a'.health.decision -cne 'Failed' -or $recovered.status.gates.'member-a'.health.values.errorRate -lt .99 -or
        $recovered.status.recovery.bundleSha256 -cne $underLoad.status.bundleSha256) { throw 'Scaled recovery lost the original failure or retained bundle.' }
    foreach ($member in @('member-a', 'member-b')) {
        if ($recovered.status.recovery.gates[$member].expectedInstances -ne 6) { throw 'Scaled recovery did not verify six instances.' }
        Invoke-Kube $member @('scale', 'deployment/prometheus', '-n', 'platform-observers', '--replicas=0') | Write-Host
    }
    Wait-Until 'missing metrics block scaling decisions' {
        foreach ($member in @('member-a', 'member-b')) {
            $hpa = Invoke-Kube $member @('get', 'hpa/keda-hpa-application', '-n', $source, '-o', 'json') | ConvertFrom-Json -AsHashtable
            if (@($hpa.status.conditions | Where-Object { $_.type -ceq 'ScalingActive' -and $_.status -ceq 'False' }).Count -ne 1) { return $false }
        }
        return $true
    } 90
    $until = [DateTime]::UtcNow.AddSeconds(60)
    do {
        foreach ($member in @('member-a', 'member-b')) { if ((Get-Deployment $member).spec.replicas -ne 6) { throw 'Missing metrics caused a scale down.' } }
        Start-Sleep -Seconds 5
    } while ([DateTime]::UtcNow -lt $until)
    $missingMetrics = Get-ScalingState
} finally {
    foreach ($member in @('member-a', 'member-b')) {
        Invoke-Kube $member @('scale', 'deployment/prometheus', '-n', 'platform-observers', '--replicas=1') | Write-Host
        Invoke-Kube $member @('rollout', 'status', 'deployment/prometheus', '-n', 'platform-observers', '--timeout=180s') | Write-Host
    }
    foreach ($member in $createdLoads) {
        Invoke-Kube $member @('delete', 'deployment/autoscale-load', '-n', 'platform-observers', '--cascade=foreground', '--timeout=90s') | Write-Host
    }
}
Wait-Replicas 2
$afterLoad = Get-ScalingState
Wait-Until 'scaled recovery releases its service claim' {
    $service = Invoke-Kube hub @('get', 'servicedefinition', $serviceName, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
    $service.status['activeRelease'] -ceq ''
} 30
$request = Invoke-Platform @('rollback', $serviceName, '--to', 'last-successful')
$manualRollback = Wait-Succeeded $request.metadata.name
if ($manualRollback.status.bundleSha256 -cne $underLoad.status.bundleSha256) { throw 'Scaled explicit rollback changed the retained bundle.' }
@{commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')
    workingTreeDirty = @(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0
    completedAt = [DateTime]::UtcNow.ToString('o'); versions = $versions
    baseline = $baseline; atTwo = $atTwo; atSix = $atSix; underLoad = $underLoad; recovered = $recovered
    memberBBeforeFailure = $beforeB; memberBAfterFailure = Get-MemberB
    missingMetrics = $missingMetrics; afterLoad = $afterLoad; manualRollback = $manualRollback
    workerRestartPreservedScaling = $true; missingMetricsHeldReplicas = $true; operatorSecretAccessDenied = $true; loadAccountIsNamespaceDefault = $true
} | ConvertTo-Json -Depth 95 | Set-Content -LiteralPath (Join-Path $state 'autoscaling-evidence.json')
Write-Host 'Autoscaling passed: 2 to 6 to 2 replicas, releases and recovery under load, ownership, missing metrics, and explicit rollback.'
