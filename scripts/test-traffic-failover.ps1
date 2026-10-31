#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$receipt = Get-Content (Join-Path $state 'deployment-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$serviceName = $receipt.release.spec.serviceName
$source = $receipt.release.status.sourceNamespace
$routeScript = Join-Path $PSScriptRoot 'traffic.ps1'
$paused = @{}
$httpFaulted = @{}
$nodeFaults = [Collections.Generic.List[object]]::new()
$nodes = @{}
$initialPods = @{}
$owned = @(Get-Content (Join-Path $state 'clusters.json') -Raw | ConvertFrom-Json)
foreach ($cluster in @('hub', 'member-a', 'member-b')) {
    if ("managed-platform-$cluster" -cnotin $owned) { throw 'Refusing a fault on an unowned cluster.' }
    $node = Get-DockerContainer "managed-platform-$cluster-control-plane"
    if ($node.Config.Labels['io.x-k8s.kind.cluster'] -cne "managed-platform-$cluster" -or -not $node.State.Running -or $node.State.Paused) { throw 'Refusing a fault on an unexpected or already paused node.' }
    $nodes[$cluster] = $node.Id
}
function Get-ApplicationPods([string]$Member) {
    $pods = Invoke-Kube $Member @('get', 'pods', '-n', $source, '-l', 'role=application', '-o', 'json') | ConvertFrom-Json -AsHashtable
    if ($pods.items.Count -ne 2) { throw 'The traffic fault fixture requires a fixed two-replica service.' }
    foreach ($pod in $pods.items) {
        if (@($pod.status.conditions | Where-Object { $_.type -ceq 'Ready' -and $_.status -ceq 'True' }).Count -ne 1) { throw 'Application is not Kubernetes-ready.' }
    }
    $pods.items
}
function Set-HttpFault([string[]]$Members, [bool]$Enabled) {
    foreach ($member in $Members) {
        if (-not $Enabled -and -not $httpFaulted.ContainsKey($member)) { continue }
        $pods = @(Get-ApplicationPods $member)
        if ((@($pods.metadata.uid | Sort-Object) -join ',') -cne $initialPods[$member]) { throw 'Application pod identities changed during the fault.' }
        if ($Enabled) { $httpFaulted[$member] = $true }
        foreach ($pod in $pods) {
            $command = if ($Enabled) { @('touch', '/tmp/requests-failed') } else { @('rm', '-f', '/tmp/requests-failed') }
            Invoke-Kube $member (@('exec', '-n', $source, $pod.metadata.name, '--') + $command) | Out-Null
        }
        if (-not $Enabled) { $httpFaulted.Remove($member) }
    }
}
function Pause-Node([string]$Cluster) {
    $current = Get-DockerContainer $nodes[$Cluster]
    if ($current.State.Paused -or $current.Config.Labels['io.x-k8s.kind.cluster'] -cne "managed-platform-$Cluster") { throw 'Node pause ownership or state changed.' }
    $paused[$Cluster] = $nodes[$Cluster]
    Invoke-Tool docker @('pause', $nodes[$Cluster]) | Out-Null
    $actual = Get-DockerContainer $nodes[$Cluster]
    if (-not $actual.State.Paused) { throw 'Node did not pause.' }
    $nodeFaults.Add(@{cluster = $Cluster; id = $actual.Id; paused = $true; checkedAt = [DateTime]::UtcNow.ToString('o')})
}
function Restore-Nodes {
    foreach ($cluster in @($paused.Keys)) {
        $current = Get-DockerContainer $paused[$cluster]
        if ($current.State.Paused) { Invoke-Tool docker @('unpause', $paused[$cluster]) | Out-Null }
        $actual = Get-DockerContainer $paused[$cluster]
        if ($actual.State.Paused -or -not $actual.State.Running) { throw 'Node did not resume.' }
        $nodeFaults.Add(@{cluster = $cluster; id = $actual.Id; paused = $false; checkedAt = [DateTime]::UtcNow.ToString('o')})
        $paused.Remove($cluster)
    }
}
function Measure-Traffic([string]$Name, [scriptblock]$Fault, [string]$ExpectedMember) {
    $queue = [Collections.Concurrent.ConcurrentQueue[object]]::new()
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $cancel = [Threading.CancellationTokenSource]::new()
    $job = Start-ThreadJob -ArgumentList $queue, $clock, $cancel, $route.url, $route.serviceName, $route.release -ScriptBlock {
        param($Queue, $Clock, $Cancel, $Url, $ServiceName, $Release)
        $ErrorActionPreference = 'Stop'
        $client = [Net.Http.HttpClient]::new()
        $client.Timeout = [TimeSpan]::FromMilliseconds(1500)
        $client.DefaultRequestHeaders.ConnectionClose = $true
        try {
            while (-not $Cancel.IsCancellationRequested) {
                $row = [ordered]@{startedMilliseconds = $Clock.Elapsed.TotalMilliseconds; completedMilliseconds = 0; status = 0
                    member = ''; workloadMatches = $false; error = ''}
                $response = $null
                try {
                    $response = $client.GetAsync($Url).GetAwaiter().GetResult()
                    $row.status = [int]$response.StatusCode
                    if ($response.Headers.Contains('X-Platform-Member')) { $row.member = $response.Headers.GetValues('X-Platform-Member') -join '' }
                    if ($row.status -eq 200) {
                        $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable
                        $row.workloadMatches = $body['service'] -ceq $ServiceName -and $body['release'] -ceq $Release -and $row.member -cin @('member-a', 'member-b')
                    }
                } catch { $row.error = $_.Exception.GetType().Name }
                finally { if ($response) { $response.Dispose() } }
                $row.completedMilliseconds = $Clock.Elapsed.TotalMilliseconds
                $Queue.Enqueue([pscustomobject]$row)
                Start-Sleep -Milliseconds 200
            }
        } finally { $client.Dispose() }
    }
    try {
        Wait-Until 'client sampler starts before fault injection' { $queue.Count -ge 3 -or $job.State -eq 'Failed' } 20
        if ($job.State -eq 'Failed') { Receive-Job $job -ErrorAction Stop; throw 'Client sampler failed.' }
        $faultAt = $clock.Elapsed.TotalMilliseconds
        & $Fault
        $faultCompletedAt = $clock.Elapsed.TotalMilliseconds
        while ($clock.Elapsed.TotalMilliseconds - $faultAt -lt 12000) { Start-Sleep -Milliseconds 100 }
        $cancel.Cancel()
        Wait-Job $job -Timeout 5 | Out-Null
        if ($job.State -cne 'Completed') { throw 'Client sampler did not stop.' }
        Receive-Job $job -ErrorAction Stop | Out-Null
        $requests = @($queue.ToArray())
        $after = @($requests | Where-Object startedMilliseconds -ge $faultAt)
        $desired = if ($ExpectedMember -ceq 'unavailable') {
            @($after | Where-Object status -eq 503)
        } else { @($after | Where-Object { $_.status -eq 200 -and $_.workloadMatches -and $_.member -ceq $ExpectedMember }) }
        $tail = @($after | Select-Object -Last 10)
        $settled = if ($ExpectedMember -ceq 'unavailable') { @($tail | Where-Object status -ne 503).Count -eq 0 }
            else { @($tail | Where-Object { $_.status -ne 200 -or -not $_.workloadMatches -or $_.member -cne $ExpectedMember }).Count -eq 0 }
        if ($desired.Count -eq 0 -or $tail.Count -ne 10 -or -not $settled -or $desired[0].completedMilliseconds - $faultAt -gt 10000) {
            throw "Traffic did not settle on $ExpectedMember within ten seconds in $Name."
        }
        $result = @{name = $Name; expectedMember = $ExpectedMember; faultAtMilliseconds = $faultAt; faultCompletedAtMilliseconds = $faultCompletedAt
            firstTargetMilliseconds = $desired[0].completedMilliseconds - $faultAt; requests = $requests
            sampledAfterFault = $after.Count; failedAfterFault = @($after | Where-Object { $_.status -ne 200 -or -not $_.workloadMatches }).Count
            finalTenMatched = $true}
        Write-Host "$Name passed: $($after.Count) sampled requests, $($result.failedAfterFault) failures, target in $([Math]::Round($result.firstTargetMilliseconds)) ms."
        $result
    } finally {
        $cancel.Cancel()
        if ($job.State -notin @('Completed', 'Failed', 'Stopped')) { Stop-Job $job }
        Remove-Job $job -Force
        $cancel.Dispose()
        $clock.Stop()
    }
}

foreach ($member in @('member-a', 'member-b')) {
    $pods = @(Get-ApplicationPods $member)
    $initialPods[$member] = @($pods.metadata.uid | Sort-Object) -join ','
    foreach ($pod in $pods) {
        & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) exec -n $source $pod.metadata.name -- test -e /tmp/requests-failed
        if ($LASTEXITCODE -ne 1) { throw 'Refusing a pre-existing or unreadable HTTP fault flag.' }
    }
}
$cases = @{}
$hubUnavailableObserved = $false
try {
    & $routeScript up -ServiceName $serviceName
    $route = Get-Content (Join-Path $state 'edge.json') -Raw | ConvertFrom-Json -AsHashtable
    if ($route.serviceUID -cne $receipt.release.spec.serviceUID -or $route.sourceNamespace -cne $source) { throw 'Routing and fault targets differ.' }
    $saved = Get-Content (Join-Path $state 'edge.json') -Raw
    try {
        $mismatch = $saved | ConvertFrom-Json -AsHashtable
        $mismatch.id = 'unrelated-container'
        $mismatch | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $state 'edge.json')
        $refused = $false
        try { & $routeScript down } catch { if ($_.Exception.Message -like '*unowned or mismatched*') { $refused = $true } else { throw } }
        if (-not $refused) { throw 'Route cleanup accepted an unrelated container identity.' }
    } finally { Set-Content (Join-Path $state 'edge.json') -Value $saved }
    & $routeScript up -ServiceName $serviceName
    if ((Get-Content (Join-Path $state 'edge.json') -Raw | ConvertFrom-Json).id -cne $route.id) { throw 'Repeated startup replaced the proxy.' }
    $cases.baseline = Measure-Traffic 'primary' {} 'member-a'
    $cases.httpFailure = Measure-Traffic 'ready application returns HTTP errors' { Set-HttpFault @('member-a') $true } 'member-b'
    $readyDuringHttpFailure = @(Get-ApplicationPods member-a | ForEach-Object { @{uid = $_.metadata.uid; ready = $true} })
    $cases.httpRecovery = Measure-Traffic 'application recovers' { Set-HttpFault @('member-a') $false } 'member-a'
    $cases.memberOutage = Measure-Traffic 'primary member pauses' { Pause-Node member-a } 'member-b'
    $cases.managementOutage = Measure-Traffic 'hub pauses while primary member is down' {
        Pause-Node hub
        & kubectl --kubeconfig $kubeconfig --context (Get-Context hub) --request-timeout=2s get namespace kube-system *> (Join-Path $state 'expected-hub-outage.log')
        if ($LASTEXITCODE -eq 0) { throw 'Hub API was still reachable during its outage.' }
        $script:hubUnavailableObserved = $true
    } 'member-b'
    if ($cases.managementOutage.failedAfterFault -ne 0) { throw 'Management downtime interrupted healthy backup traffic.' }
    $cases.memberRecovery = Measure-Traffic 'members and hub recover' { Restore-Nodes } 'member-a'
    $cases.bothUnavailable = Measure-Traffic 'both ready applications return errors' { Set-HttpFault @('member-a', 'member-b') $true } 'unavailable'
    $cases.finalRecovery = Measure-Traffic 'both applications recover' { Set-HttpFault @('member-a', 'member-b') $false } 'member-a'
    $proxy = Get-DockerContainer $route.id
    if (-not $proxy.HostConfig.ReadonlyRootfs -or $proxy.Config.User -cne 'haproxy' -or 'ALL' -cnotin $proxy.HostConfig.CapDrop -or
        @($proxy.HostConfig.SecurityOpt | Where-Object { $_ -cmatch '^no-new-privileges(?::true)?$' }).Count -ne 1 -or
        [string]$proxy.NetworkSettings.Ports['8080/tcp'][0].HostIp -cne '127.0.0.1') { throw 'Proxy security settings changed.' }
    $configuration = Get-Content (Join-Path $state "traffic/$($route.runId).cfg") -Raw
    @{commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD'); workingTreeDirty = @(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0
        completedAt = [DateTime]::UtcNow.ToString('o'); versions = $versions; scope = 'Local member outages and application HTTP faults'
        route = $route; configuration = $configuration; cases = $cases; podsReadyDuringHttpFailure = $readyDuringHttpFailure; nodeFaults = $nodeFaults.ToArray()
        hubApiUnavailableObserved = $hubUnavailableObserved; proxyRestarted = $false; repeatedStartupPreservedProxy = $true
        unownedCleanupDenied = $true; proxyReadOnly = $true; loopbackOnly = $true
    } | ConvertTo-Json -Depth 35 | Set-Content (Join-Path $state 'traffic-evidence.json')
} finally {
    Restore-Nodes
    foreach ($member in @($httpFaulted.Keys)) { Set-HttpFault @($member) $false }
    & $routeScript down
}
& $routeScript down
if ((Test-Path (Join-Path $state 'edge.json')) -or (Invoke-Tool docker @('ps', '-aq', '--filter', 'name=^/managed-platform-edge$'))) { throw 'Route teardown left a proxy behind.' }
Write-Host 'Traffic failover passed: HTTP health, member outage, management independence, failback, fail-closed behavior, and owned cleanup.'
