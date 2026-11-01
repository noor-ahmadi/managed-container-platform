#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$seed = Get-Content (Join-Path $state 'deployment-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$release = $seed.release
$service = $release.spec.serviceName
$source = $release.status.sourceNamespace
$image = $release.spec.image
$current = Invoke-Kube hub @('get', 'servicedefinition', $service, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
if ($current.metadata.uid -cne $release.spec.serviceUID -or $current.status.lastSuccessfulRelease -cne $release.metadata.name -or $current.status['activeRelease']) {
    throw 'Tracing requires the current successful, idle self-service baseline.'
}
$owned = @(Get-Content (Join-Path $state 'clusters.json') -Raw | ConvertFrom-Json)
foreach ($member in @('member-a', 'member-b')) {
    if ("managed-platform-$member" -cnotin $owned) { throw 'Refusing trace faults on an unowned cluster.' }
}
$probeName = 'trace-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$probes = @{}
$backends = @{}
$observers = @{}
$pods = @{}
$faulted = $false
$backendStopped = $false
$cases = @{}
function Get-AppPods([string]$Member) {
    $result = Invoke-Kube $Member @('get', 'pods', '-n', $source, '-l', 'role=application', '-o', 'json') | ConvertFrom-Json -AsHashtable
    if ($result.items.Count -ne 2) { throw 'Tracing fixture requires two application replicas.' }
    foreach ($pod in $result.items) {
        if ($pod.metadata.labels['platform.example.com/release'] -cne $release.metadata.name -or $pod.spec.containers[0].image -cne $image -or
            @($pod.status.conditions | Where-Object { $_.type -ceq 'Ready' -and $_.status -ceq 'True' }).Count -ne 1) { throw 'Unexpected application identity or readiness.' }
    }
    $result.items
}
function Assert-PodIdentity([string]$Member) {
    $actual = @(Get-AppPods $Member)
    if ((@($actual.metadata.uid | Sort-Object) -join ',') -cne (@($pods[$Member].metadata.uid | Sort-Object) -join ',')) { throw 'Application pods changed during trace faults.' }
}
function Restore-Http {
    if (-not $script:faulted) { return }
    Assert-PodIdentity 'member-a'
    foreach ($pod in $pods.'member-a') { Invoke-Kube member-a @('exec', '-n', $source, $pod.metadata.name, '--', 'rm', '-f', '/tmp/requests-failed') | Out-Null }
    $script:faulted = $false
}
function Set-BackendReplicas([int]$Count) {
    $actual = Invoke-Kube member-a @('get', 'deployment/jaeger', '-n', 'platform-observers', '-o', 'json') | ConvertFrom-Json -AsHashtable
    if ($actual.metadata.uid -cne $backends.'member-a'.metadata.uid) { throw 'Refusing to scale a replaced trace backend.' }
    Invoke-Kube member-a @('scale', 'deployment/jaeger', '-n', 'platform-observers', "--replicas=$Count") | Write-Host
    if ($Count -eq 1) { Invoke-Kube member-a @('rollout', 'status', 'deployment/jaeger', '-n', 'platform-observers', '--timeout=120s') | Write-Host }
}
function Send-Request([string]$Member, [int]$Status = 200, [switch]$InvalidParent) {
    $traceId = [guid]::NewGuid().ToString('N')
    $parentId = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $parent = if ($InvalidParent) { 'invalid-parent' } else { "00-$traceId-$parentId-01" }
    $output = & kubectl --kubeconfig $kubeconfig --context (Get-Context $Member) --request-timeout=15s exec -n platform-observers $probeName -- wget -T 3 -S -O - `
        "--header=traceparent: $parent" '--header=Authorization: Bearer trace-private-check' '--header=Cookie: trace-private-check' `
        "http://application.${source}.svc.cluster.local:8080/?private=trace-private-check" 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    $code = [regex]::Match($output, 'HTTP/1\.[01] (\d{3})')
    $header = [regex]::Match($output, '(?im)^\s*X-Platform-Trace:\s*([a-f0-9]{32})')
    if (-not $code.Success -or [int]$code.Groups[1].Value -ne $Status -or ($Status -eq 200 -and ($exitCode -ne 0 -or -not $header.Success))) {
        throw "Unexpected traced HTTP response on ${Member}: $output"
    }
    if ($InvalidParent) { $traceId = $header.Groups[1].Value; $parentId = '' }
    elseif ($header.Success -and $header.Groups[1].Value -cne $traceId) { throw 'Response did not preserve the incoming W3C trace ID.' }
    @{member=$Member; traceId=$traceId; parentId=$parentId; status=$Status; checkedAt=[DateTimeOffset]::UtcNow.ToString('o')}
}
function Decode-Id([string]$Value) {
    if ($Value -cmatch '^(?:[a-f0-9]{16}|[a-f0-9]{32})$') { return $Value }
    [Convert]::ToHexString([Convert]::FromBase64String($Value)).ToLowerInvariant()
}
function Attributes($Rows) {
    $map = @{}
    foreach ($row in $Rows) { $map[$row.key] = @($row.value.Values)[0] }
    $map
}
function Read-Trace($Request) {
    $script:traceResult = $null
    Wait-Until "stored trace $($Request.traceId)" {
        try {
            $raw = (& (Join-Path $PSScriptRoot 'traces.ps1') -Member $Request.member -TraceId $Request.traceId) -join "`n"
            $data = $raw | ConvertFrom-Json -AsHashtable
            if (-not $data['result'] -or -not $data.result['resourceSpans']) { return $false }
        } catch { return $false }
        if ($raw.Contains('trace-private-check')) { throw 'Tracing captured private headers or query values.' }
        $found = @()
        foreach ($resource in $data.result.resourceSpans) {
            foreach ($scope in $resource.scopeSpans) {
                foreach ($span in $scope.spans) {
                    if ((Decode-Id $span.traceId) -cne $Request.traceId) { throw 'Backend returned a different trace ID.' }
                    $identity = Attributes $resource.resource.attributes
                    $attributes = Attributes $span.attributes
                    foreach ($pair in @{ 'service.name'=$service; platform_service=$service; platform_namespace=$source; platform_release=$release.metadata.name; platform_image=$image; platform_member=$Request.member }.GetEnumerator()) {
                        if ($identity[$pair.Key] -cne $pair.Value) { throw "Wrong trace resource: $($pair.Key)" }
                    }
                    if ($identity['platform_pod'] -cnotin @($pods[$Request.member].metadata.uid)) { throw 'Trace came from an unexpected application pod.' }
                    $spanParent = if ($span['parentSpanId']) { Decode-Id $span.parentSpanId } else { '' }
                    if ($spanParent -cne $Request.parentId -or $span.name -cne 'GET /' -or $span.kind -cnotin @('SPAN_KIND_SERVER', 2) -or
                        $attributes['http.request.method'] -cne 'GET' -or $attributes['http.route'] -cne '/' -or [int]$attributes['http.response.status_code'] -ne $Request.status -or
                        [ulong]$span.endTimeUnixNano -le [ulong]$span.startTimeUnixNano) { throw 'Stored span lost its parent, HTTP outcome, or timing.' }
                    if ($Request.status -eq 503 -and $span.status.code -cnotin @('STATUS_CODE_ERROR', 2)) { throw 'HTTP failure was not marked as a trace error.' }
                    $found += $span
                }
            }
        }
        if ($found.Count -ne 1) { throw 'Expected exactly one sample endpoint span.' }
        $script:traceResult = @{request=$Request; response=$data; privateHeadersOmitted=$true}
        return $true
    } 60
    $script:traceResult
}
function Read-Metric([string]$Query) {
    $path = '/api/v1/namespaces/platform-observers/services/http:prometheus:9090/proxy/api/v1/query?query=' + [Uri]::EscapeDataString($Query)
    $data = Invoke-Kube member-a @('get', '--raw', $path) | ConvertFrom-Json -AsHashtable
    if ($data.status -cne 'success' -or $data.data.result.Count -ne 1) { throw 'Expected one live metric value.' }
    @{query=$Query; response=$data; value=[double]::Parse($data.data.result[0].value[1], [Globalization.CultureInfo]::InvariantCulture); checkedAt=[DateTimeOffset]::UtcNow.ToString('o')}
}
try {
    foreach ($member in @('member-a', 'member-b')) {
        $pods[$member] = @(Get-AppPods $member)
        foreach ($pod in $pods[$member]) { Invoke-Kube $member @('exec', '-n', $source, $pod.metadata.name, '--', 'sh', '-c', 'test ! -e /tmp/requests-failed') | Out-Null }
        $backend = Invoke-Kube $member @('get', 'deployment/jaeger', '-n', 'platform-observers', '-o', 'json') | ConvertFrom-Json -AsHashtable
        if ($backend.spec.replicas -ne 1 -or $backend.spec.template.spec.containers[0].image -cne $versions.jaegerImage -or $backend.status.readyReplicas -ne 1) { throw 'Unexpected trace backend.' }
        $backends[$member] = $backend
        $observers[$member] = @{
            configuration = (Invoke-Kube $member @('get', 'configmap/observer-config', '-n', 'platform-observers', '-o', 'json') | ConvertFrom-Json -AsHashtable).data
            collector = Invoke-Kube $member @('get', 'deployment/collector', '-n', 'platform-observers', '-o', 'json') | ConvertFrom-Json -AsHashtable
        }
        foreach ($account in @('observer','default')) {
            $allowed = & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) auth can-i get services/http:jaeger:16686 --subresource=proxy -n platform-observers "--as=system:serviceaccount:platform-observers:$account"
            if ($LASTEXITCODE -ne 1 -or $allowed -cne 'no') { throw 'Non-operator account can query traces.' }
        }
        Set-KubeResource $member @{apiVersion='v1';kind='Pod';metadata=@{name=$probeName;namespace='platform-observers';labels=@{role='traffic'}}
            spec=@{automountServiceAccountToken=$false;terminationGracePeriodSeconds=1;securityContext=@{runAsNonRoot=$true;runAsUser=10000;seccompProfile=@{type='RuntimeDefault'}}
                containers=@(@{name='probe';image=$versions.testImage;command=@('sleep','600');securityContext=@{allowPrivilegeEscalation=$false;readOnlyRootFilesystem=$true;capabilities=@{drop=@('ALL')}}
                    resources=@{requests=@{cpu='10m';memory='16Mi'};limits=@{cpu='100m';memory='32Mi'}}})}}
        $probes[$member] = (Invoke-Kube $member @('get', 'pod', $probeName, '-n', 'platform-observers', '-o', 'json') | ConvertFrom-Json -AsHashtable).metadata.uid
        Invoke-Kube $member @('wait', "pod/$probeName", '-n', 'platform-observers', '--for=condition=Ready', '--timeout=90s') | Write-Host
        Invoke-Kube $member @('exec', '-n', 'platform-observers', $probeName, '--', 'nslookup', 'jaeger.platform-observers.svc.cluster.local') | Out-Null
        foreach ($port in @(4318,16686)) {
            $denial = & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) exec -n platform-observers $probeName -- wget -T 3 -q -O - "http://jaeger:$port/" 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0 -or $denial -notmatch 'timed out') { throw "Trace network isolation did not deny port ${port}: $denial" }
        }
        $cases[$member] = Read-Trace (Send-Request $member)
    }
    $tenantAllowed = & kubectl --kubeconfig (Join-Path $state 'tenant-kubeconfig') --context tenant-demo auth can-i get services/http:jaeger:16686 --subresource=proxy -n platform-observers
    if ($LASTEXITCODE -ne 1 -or $tenantAllowed -cne 'no') { throw 'Tenant can query the trace backend.' }
    $cases.invalidParent = Read-Trace (Send-Request member-a -InvalidParent)
    $faulted = $true
    foreach ($pod in $pods.'member-a') { Invoke-Kube member-a @('exec', '-n', $source, $pod.metadata.name, '--', 'touch', '/tmp/requests-failed') | Out-Null }
    $cases.httpFailure = Read-Trace (Send-Request member-a 503)
    Assert-PodIdentity member-a
    $readyDuringFailure = @(Get-AppPods member-a | ForEach-Object { @{uid=$_.metadata.uid;ready=$true} })
    Restore-Http
    $selector = '{platform_service="' + $service + '",platform_release="' + $release.metadata.name + '",platform_namespace="' + $source + '",platform_image="' + $image + '",member="member-a"}'
    $before = Read-Metric "sum(platform_requests_total$selector)"
    $backendStopped = $true
    Set-BackendReplicas 0
    Wait-Until 'trace backend stopped' { (Invoke-Kube member-a @('get', 'pods', '-n', 'platform-observers', '-l', 'role=jaeger', '-o', 'json') | ConvertFrom-Json -AsHashtable).items.Count -eq 0 } 60
    $stoppedAt = [DateTimeOffset]::UtcNow.ToString('o')
    $outageRequest = Send-Request member-a
    $outage = @{deploymentUID=$backends.'member-a'.metadata.uid;zeroPodsObserved=$true;stoppedAt=$stoppedAt;request=$outageRequest;before=$before}
    $collectorPod = (Invoke-Kube member-a @('get', 'pods', '-n', 'platform-observers', '-l', 'role=collector', '-o', 'json') | ConvertFrom-Json -AsHashtable).items[0]
    Wait-Until 'collector has queued traces while Jaeger is stopped' {
        $metrics = Invoke-Kube member-a @('get', '--raw', "/api/v1/namespaces/platform-observers/pods/$($collectorPod.metadata.name):8888/proxy/metrics")
        $script:queueLines = @($metrics -split "`n" | Where-Object { $_ -cmatch '^otelcol_exporter_queue_size\{' -and $_.Contains('exporter="otlp_http/jaeger"') })
        if ($queueLines.Count -ne 1) { return $false }
        $script:queueSize = [double]::Parse(($queueLines[0] -split '\s+')[-1], [Globalization.CultureInfo]::InvariantCulture)
        return $queueSize -gt 0
    } 30
    $outage.collectorPodUID=$collectorPod.metadata.uid; $outage.queueMetric=$queueLines[0]; $outage.queuedBatches=$queueSize; $outage.queueObservedAt=[DateTimeOffset]::UtcNow.ToString('o')
    Wait-Until 'fresh metrics while tracing is unavailable' {
        $script:after = Read-Metric "sum(platform_requests_total$selector)"
        $script:freshness = Read-Metric "min(platform_last_request_time_seconds$selector)"
        $script:metricAge = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000d - $freshness.value
        return $after.value -gt $before.value -and $metricAge -ge 0 -and $metricAge -le 15
    } 30
    Assert-PodIdentity member-a
    $outage.after=$after; $outage.freshness=$freshness; $outage.ageSeconds=$metricAge
    Set-BackendReplicas 1
    $outage.recoveredAt=[DateTimeOffset]::UtcNow.ToString('o')
    $backendStopped = $false
    $cases.queuedDuringOutage = Read-Trace $outageRequest
    $cases.recovered = Read-Trace (Send-Request member-a)
} finally {
    try {
        try { Restore-Http } finally { if ($backendStopped) { Set-BackendReplicas 1 } }
    } finally {
        foreach ($member in $probes.Keys) {
            $actual = Invoke-Kube $member @('get', 'pod', $probeName, '-n', 'platform-observers', '-o', 'json') | ConvertFrom-Json -AsHashtable
            if ($actual.metadata.uid -cne $probes[$member]) { throw 'Refusing cleanup of a replaced trace probe.' }
            Invoke-Kube $member @('delete', 'pod', $probeName, '-n', 'platform-observers', '--wait=true', '--timeout=45s') | Write-Host
        }
    }
}
@{commit=Invoke-Tool git @('-C',$root,'rev-parse','HEAD');workingTreeDirty=@(Invoke-Tool git @('-C',$root,'status','--porcelain')).Count -gt 0
    completedAt=[DateTimeOffset]::UtcNow.ToString('o');versions=$versions;scope='Local sample endpoint traces through the member collector into bounded volatile Jaeger storage'
    serviceUID=$release.spec.serviceUID;service=$service;release=$release.metadata.name;image=$image;sourceNamespace=$source
    seedProvenance=$release.status.provenance;backends=$backends;observers=$observers;cases=$cases;readyDuringHttpFailure=$readyDuringFailure;backendOutage=$outage
    tenantTraceAccessDenied=$true;observerTraceAccessDenied=$true;nonCollectorNetworkAccessDenied=$true;faultsRestored=$true;probeCleanupPassed=$true
} | ConvertTo-Json -Depth 70 | Set-Content -LiteralPath (Join-Path $state 'tracing-evidence.json')
Write-Host 'Tracing passed: W3C parents, exact release identities, HTTP error spans, access boundaries, queued recovery, and live metrics during backend downtime.'
