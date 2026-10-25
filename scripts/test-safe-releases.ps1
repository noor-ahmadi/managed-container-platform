#requires -Version 7.0
param([ValidateSet('local', 'azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
$receipt = Get-Content (Join-Path $state 'deployment-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$baseline = $receipt.release
$serviceName = $baseline.spec.serviceName
$source = $baseline.status.sourceNamespace
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json -AsHashtable
$cli = Join-Path $root 'src/Platform/bin/Debug/net10.0/platform.dll'
$tenantArgs = @('--kubeconfig', (Join-Path $state 'tenant-kubeconfig'), '--context', 'tenant-demo', '--namespace', 'tenant-demo', '--output', 'json')
function Invoke-Platform([string[]]$Arguments) { Invoke-Tool dotnet (@($cli) + $Arguments + $tenantArgs) | ConvertFrom-Json -AsHashtable }
function Get-Release([string]$Name) { Invoke-Kube hub @('get', 'release', $Name, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable }
function Get-TrafficPod([hashtable]$Release) {
    $script:trafficMatch = $null
    Wait-Until 'current traffic pod is ready' {
        $current = Get-Release $Release.metadata.name
        if (-not $current['status'] -or -not $current.status['sourceNamespace']) { return $false }
        $pods = Invoke-Kube member-a @('get', 'pods', '-n', $current.status.sourceNamespace, '-l', 'role=traffic', '-o', 'json') | ConvertFrom-Json -AsHashtable
        $ready = @($pods.items | Where-Object {
            $_.metadata.labels['platform.example.com/release'] -ceq $Release.metadata.name -and
            $_.spec.containers[0].image -ceq $Release.spec.image -and -not $_.metadata['deletionTimestamp'] -and
            @($_.status['conditions'] | Where-Object { $_.type -ceq 'Ready' -and $_.status -ceq 'True' }).Count -gt 0
        })
        if ($ready.Count -eq 1) {
            $script:trafficMatch = @{name = $ready[0].metadata.name; namespace = $current.status.sourceNamespace}
            return $true
        }
        return $false
    } 180
    $script:trafficMatch
}
function Restart-Worker {
    Invoke-Kube hub @('rollout', 'restart', 'deployment/platform-worker', '-n', 'platform-system') | Write-Host
    Invoke-Kube hub @('rollout', 'status', 'deployment/platform-worker', '-n', 'platform-system', '--timeout=90s') | Write-Host
}
function Get-MemberB {
    $deployment = Invoke-Kube member-b @('get', 'deployment', 'application', '-n', $source, '-o', 'json') | ConvertFrom-Json
    $sets = Invoke-Kube member-b @('get', 'replicasets', '-n', $source, '-l', 'role=application', '-o', 'json') | ConvertFrom-Json
    @{ image = $deployment.spec.template.spec.containers[0].image
       template = $deployment.spec.template | ConvertTo-Json -Depth 40 -Compress
       replicaSets = @($sets.items.metadata.uid | Sort-Object) -join ',' }
}
$beforeB = Get-MemberB
function Assert-MemberBUntouched {
    $current = Get-MemberB
    foreach ($key in $beforeB.Keys) { if ($current[$key] -cne $beforeB[$key]) { throw "Member B changed before approval: $key." } }
}
function Assert-NoApproval([hashtable]$Release) {
    $approval = Invoke-Kube hub @('get', 'clusterapprovalrequest', $Release.status.gates.'member-a'.approvalName, '-o', 'json') | ConvertFrom-Json -AsHashtable
    if ($approval['status'] -and @($approval.status['conditions'] | Where-Object { $_.type -ceq 'Approved' -and $_.status -ceq 'True' }).Count -gt 0) {
        throw 'An unhealthy or blocked stage received approval.'
    }
    Assert-MemberBUntouched
}

Wait-Until 'retained health-verified baseline' {
    $service = Invoke-Kube hub @('get', 'servicedefinition', $serviceName, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
    $service.status['lastSuccessfulRelease'] -ceq $baseline.metadata.name -and $service.status['activeRelease'] -ceq ''
} 30
# Management downtime must not interrupt already deployed applications.
Invoke-Kube hub @('scale', 'deployment/platform-worker', '-n', 'platform-system', '--replicas=0') | Write-Host
try {
    Invoke-Kube hub @('wait', 'pod', '-n', 'platform-system', '-l', 'app=platform-worker', '--for=delete', '--timeout=90s') | Write-Host
    foreach ($member in @('member-a', 'member-b')) {
        $response = Invoke-Kube $member @('exec', '-n', 'platform-observers', $serviceName, '--', 'wget', '-T', '5', '-q', '-O', '-', "http://application.${source}.svc.cluster.local:8080/") | ConvertFrom-Json
        if ($response.release -cne $baseline.metadata.name) { throw 'Application changed during management downtime.' }
        foreach ($permission in @(@('create', 'deployments', '-n', $source), @('get', 'secrets', '-n', 'platform-observers'))) {
            $allowed = & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) auth can-i @permission --as=system:serviceaccount:platform-observers:observer
            if ($LASTEXITCODE -ne 1 -or $allowed -cne 'no') { throw 'Observer received workload or secret permissions.' }
        }
    }
} finally { Invoke-Kube hub @('scale', 'deployment/platform-worker', '-n', 'platform-system', '--replicas=1') | Write-Host }
Invoke-Kube hub @('rollout', 'status', 'deployment/platform-worker', '-n', 'platform-system', '--timeout=90s') | Write-Host

$first = Get-Content (Join-Path $root 'samples/service.json') -Raw | ConvertFrom-Json
$first.spec.imageRepository = ($images['sample-api'] -split '@')[0]
$first.name = 'first-error-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$firstFile = Join-Path $state 'first-error.json'
$first | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $firstFile
Invoke-Platform @('service', 'apply', $firstFile) | Out-Null
$firstBad = Invoke-Platform @('release', 'create', $first.name, '--image', $images['sample-api-error'])
$firstTraffic = Get-TrafficPod $firstBad
Invoke-Kube member-a @('exec', '-n', $firstTraffic.namespace, $firstTraffic.name, '--', 'touch', '/tmp/traffic-slow') | Write-Host
try {
    Wait-Until 'insufficient traffic blocks an otherwise fresh completed bake' {
        $current = Get-Release $firstBad.metadata.name
        if (-not $current['status'] -or -not $current.status['gates'] -or -not $current.status.gates['member-a']) { return $false }
        if ($current.status['failure']) { throw $current.status.failure }
        Assert-NoApproval $current
        $gate = $current.status.gates.'member-a'
        $health = $gate['health']
        $health -and $health.decision -ceq 'Blocked' -and $health['values'] -and $null -ne $health.values.requests -and
            $health.values.requests -lt 500 -and $health.values.instances -eq 2 -and $health.values.samples -ge 20 -and
            ([DateTimeOffset]::UtcNow - [DateTimeOffset]$gate.startedAt).TotalSeconds -ge 120 -and
            $null -ne $health.values.oldestRequestSeconds -and
            ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000 - $health.values.oldestRequestSeconds) -lt 15
    } 180
    $insufficient = Get-Release $firstBad.metadata.name
} catch {
    Get-Release $firstBad.metadata.name | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath (Join-Path $state 'fault-failure-evidence.json')
    throw
} finally {
    Invoke-Kube member-a @('exec', '-n', $firstTraffic.namespace, $firstTraffic.name, '--', 'rm', '-f', '/tmp/traffic-slow') | Write-Host
}
$bad = Invoke-Platform @('release', 'create', $serviceName, '--image', $images['sample-api-error'])
$script:baking = $null
Wait-Until 'ready bad image on A' {
    $current = Get-Release $bad.metadata.name
    if ($current['status'] -and $current.status['gates'] -and $current.status.gates['member-a']) { $script:baking = $current; return $true }
    if ($current['status'] -and $current.status['failure']) { throw $current.status.failure }
    return $false
} 180
$badDeployment = Invoke-Kube member-a @('get', 'deployment', 'application', '-n', $source, '-o', 'json') | ConvertFrom-Json
if ($badDeployment.status.readyReplicas -ne 2 -or $badDeployment.spec.template.spec.containers[0].image -cne $images['sample-api-error']) {
    throw 'Failure fixture did not remain Kubernetes-ready.'
}
Assert-NoApproval $baking
# Pause generated traffic while the erroring application remains ready.
$trafficPod = (Get-TrafficPod $bad).name
Invoke-Kube member-a @('exec', '-n', $source, $trafficPod, '--', 'touch', '/tmp/traffic-paused') | Write-Host
try {
    Wait-Until 'stale or absent application telemetry blocks A' {
        $current = Get-Release $bad.metadata.name
        Assert-NoApproval $current
        $health = $current.status.gates.'member-a'['health']
        $health -and $health.decision -ceq 'Blocked' -and
            ((-not $health['values']) -or (-not $health.values['oldestRequestSeconds']) -or
             ([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000 - $health.values.oldestRequestSeconds) -gt 15)
    } 60
    # Invalid credentials exercise the real authenticated service-proxy boundary.
    $observer = Invoke-Kube hub @('get', 'secret', 'observer-member-a', '-n', 'platform-system', '-o', 'json') | ConvertFrom-Json -AsHashtable
    $config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($observer.data.kubeconfig)) | ConvertFrom-Json -AsHashtable
    $config.users[0].user.token = 'invalid-observer-token'
    try {
        Set-KubeResource hub @{ apiVersion = 'v1'; kind = 'Secret'; metadata = @{name = 'observer-member-a'; namespace = 'platform-system'}
            data = @{kubeconfig = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Depth 12))) } }
        Restart-Worker
        Wait-Until 'observer authentication failure blocks approval' {
            $current = Get-Release $bad.metadata.name
            Assert-NoApproval $current
            $current.status.gates.'member-a'['health'] -and $current.status.gates.'member-a'.health.reason -like '*HTTP 401*'
        } 60
        Wait-Until 'full bake still cannot approve without telemetry' {
            $current = Get-Release $bad.metadata.name
            Assert-NoApproval $current
            ([DateTimeOffset]::UtcNow - [DateTimeOffset]$current.status.gates.'member-a'.startedAt).TotalSeconds -gt 125
        } 150
        $blocked = Get-Release $bad.metadata.name
    } finally {
        Set-KubeResource hub @{apiVersion = 'v1'; kind = 'Secret'; metadata = @{name = 'observer-member-a'; namespace = 'platform-system'}; data = $observer.data}
        $observer = $null; $config = $null
        Restart-Worker
    }
} finally { Invoke-Kube member-a @('exec', '-n', $source, $trafficPod, '--', 'rm', '-f', '/tmp/traffic-paused') | Write-Host }
$script:recovering = $null
Wait-Until 'compensating recovery with persisted execution identity' {
    $current = Get-Release $bad.metadata.name
    Assert-MemberBUntouched
    if ($current.status['recoveryFailure']) { throw $current.status.recoveryFailure }
    if ($current.status['recovery'] -and $current.status.recovery['runUID']) { $script:recovering = $current; return $true }
    return $false
} 240
$abandoned = Invoke-Kube hub @('get', 'clusterstagedupdaterun', $recovering.status.runName, '--ignore-not-found', '-o', 'name')
if ($abandoned) { throw 'Recovery started before the failed run was deleted.' }
# A failed recovery must retain its service lock. An operator can request a fresh attempt through status.
$failedRecoveryUID = $recovering.status.recovery.runUID
Invoke-Kube hub @('scale', 'deployment/platform-worker', '-n', 'platform-system', '--replicas=0') | Write-Host
try {
    Invoke-Kube hub @('wait', 'pod', '-n', 'platform-system', '-l', 'app=platform-worker', '--for=delete', '--timeout=90s') | Write-Host
    $recoveryRun = Invoke-Kube hub @('get', 'clusterstagedupdaterun', $recovering.status.recovery.runName, '-o', 'json') | ConvertFrom-Json
    if ($recoveryRun.spec.state -ceq 'Initialize') {
        $runPatch = @{spec = @{state = 'Run'}} | ConvertTo-Json -Compress
        Invoke-Kube hub @('patch', 'clusterstagedupdaterun', $recovering.status.recovery.runName, '--type=merge', '-p', $runPatch) | Write-Host
    }
    $stopPatch = @{spec = @{state = 'Stop'}} | ConvertTo-Json -Compress
    Invoke-Kube hub @('patch', 'clusterstagedupdaterun', $recovering.status.recovery.runName, '--type=merge', '-p', $stopPatch) | Write-Host
} finally { Invoke-Kube hub @('scale', 'deployment/platform-worker', '-n', 'platform-system', '--replicas=1') | Write-Host }
Wait-Until 'failed recovery is blocked and abandoned' {
    $current = Get-Release $bad.metadata.name
    $current.status['recoveryFailure'] -and $current.status.recovery['abandonedAt'] -and $current.status.phase -ceq 'Blocked'
} 150
$failedRecovery = Get-Release $bad.metadata.name
$locked = Invoke-Platform @('rollback', $serviceName, '--to', 'last-successful')
Wait-Until 'new releases are rejected while recovery is blocked' {
    $current = Get-Release $locked.metadata.name
    $current['status'] -and $current.status['phase'] -ceq 'Failed'
} 30
$lockedRequest = Get-Release $locked.metadata.name
if ($lockedRequest.status.failure -cne 'Another release is active for this service.' -or $lockedRequest.status['runUID']) {
    throw 'Failed recovery released the service lock.'
}
$retryPatch = @{status = @{retryRecovery = 2}} | ConvertTo-Json -Compress
Invoke-Kube hub @('patch', 'release', $bad.metadata.name, '-n', 'tenant-demo', '--subresource=status', '--type=merge', '-p', $retryPatch) | Write-Host
Wait-Until 'operator-requested recovery has a fresh persisted identity' {
    $current = Get-Release $bad.metadata.name
    if ($current.status['recoveryAttempt'] -eq 2 -and $current.status.recovery['runUID']) {
        if ($current.status['recoveryFailure']) { throw $current.status.recoveryFailure }
        $script:recovering = $current
        return $true
    }
    return $false
} 180
if ($recovering.status.recovery.runUID -ceq $failedRecoveryUID) { throw 'Recovery retry reused an abandoned run.' }
Restart-Worker
$script:recovered = $null
Wait-Until 'healthy baseline restored on both members after restart' {
    $current = Get-Release $bad.metadata.name
    Assert-MemberBUntouched
    if ($current.status['recoveryFailure']) { throw $current.status.recoveryFailure }
    if ($current.status['phase'] -ceq 'RolledBack') { $script:recovered = $current; return $true }
    return $false
} 720
if ($recovered.status.recovery.runUID -cne $recovering.status.recovery.runUID -or
    $recovered.status.recovery.runUID -ceq $recovered.status.runUID -or
    $recovered.status.gates.'member-a'.health.decision -cne 'Failed' -or
    $recovered.status.gates.'member-a'.health.values.errorRate -lt 0.99 -or
    $recovered.status.recovery.bundleSha256 -cne $baseline.status.bundleSha256 -or
    $recovered.status.recoveryAttempts[0].execution.runUID -cne $failedRecoveryUID) { throw 'Recovery identity or original failure evidence changed.' }
foreach ($member in @('member-a', 'member-b')) {
    $deployment = Invoke-Kube $member @('get', 'deployment', 'application', '-n', $source, '-o', 'json') | ConvertFrom-Json
    if ($deployment.spec.template.spec.containers[0].image -cne $images['sample-api'] -or
        $recovered.status.recovery.gates[$member].health.decision -cne 'Passed') { throw 'Baseline recovery was not verified.' }
}
$envelope = Invoke-Kube hub @('get', 'resourceenvelope', 'application', '-n', $source, '-o', 'json') | ConvertFrom-Json
if ($envelope.data.deployment.spec.template.spec.containers[0].image -cne $images['sample-api']) { throw 'Recovery did not restore source configuration.' }
Wait-Until 'first failed deployment reports no baseline' { (Get-Release $firstBad.metadata.name).status['phase'] -ceq 'Failed' } 90
$noBaseline = Get-Release $firstBad.metadata.name
if ($noBaseline.status.recoveryOutcome -cne 'NoSuccessfulBaseline' -or $noBaseline.status['recovery']) { throw 'First failure invented a recovery baseline.' }
$untouched = Invoke-Kube member-b @('get', 'deployments', '-n', $noBaseline.status.sourceNamespace, '-o', 'json') | ConvertFrom-Json
if (@($untouched.items).Count -ne 0) { throw 'First failed deployment reached member B.' }
Wait-Until 'recovered service is unlocked' {
    $service = Invoke-Kube hub @('get', 'servicedefinition', $serviceName, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
    $service.status['activeRelease'] -ceq ''
} 30
$manual = Invoke-Platform @('rollback', $serviceName, '--to', 'last-successful')
Wait-Until 'explicit rollback request verifies the retained bundle' {
    $current = Get-Release $manual.metadata.name
    if ($current['status'] -and $current.status['failure']) { throw $current.status.failure }
    $current['status'] -and $current.status['phase'] -ceq 'Succeeded'
} 720
$manualRollback = Get-Release $manual.metadata.name
if ($manualRollback.status.bundleSha256 -cne $baseline.status.bundleSha256 -or
    $manualRollback.status.releaseName -cne $baseline.status.releaseName) { throw 'Explicit rollback recompiled the retained configuration.' }
@{commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')
    workingTreeDirty = @(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0
    completedAt = [DateTime]::UtcNow.ToString('o'); versions = $versions
    blocked = $blocked; insufficientTraffic = $insufficient; recovered = $recovered; firstFailure = $noBaseline
    failedRecovery = $failedRecovery; lockedRequest = $lockedRequest; manualRollback = $manualRollback
    readyErrorDeployment = $badDeployment; memberBBefore = $beforeB; memberBAfter = Get-MemberB
    managementDowntimeTrafficPassed = $true; observerPermissionsDenied = $true
    restartDuringObservation = $true; restartDuringRecovery = $true
} | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath (Join-Path $state 'safe-release-evidence.json')
Write-Host 'Safe releases passed: measured gates, stale/absent data, low traffic, observer 401, restart, containment, and retained-bundle recovery.'
