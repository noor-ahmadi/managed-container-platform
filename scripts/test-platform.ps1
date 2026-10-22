#requires -Version 7.0
param([switch]$SkipBootstrap)
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $SkipBootstrap) { & (Join-Path $PSScriptRoot 'platform.ps1') }
$registryRecord = Join-Path $state 'registry.json'
$originalRecord = Get-Content -LiteralPath $registryRecord -Raw
try {
    $mismatched = $originalRecord | ConvertFrom-Json
    $mismatched.id = 'unrelated-container'
    $mismatched | ConvertTo-Json | Set-Content -LiteralPath $registryRecord
    $refused = $false
    try { & (Join-Path $PSScriptRoot 'registry.ps1') down }
    catch { if ($_.Exception.Message -like '*unowned or mismatched*') { $refused = $true } else { throw } }
    if (-not $refused) { throw 'Registry teardown accepted a different container identity.' }
} finally { Set-Content -LiteralPath $registryRecord -Value $originalRecord }
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json
$cli = Join-Path $root 'src/Platform/bin/Debug/net10.0/platform.dll'
$tenantConfig = Join-Path $state 'tenant-kubeconfig'
$tenantArgs = @('--kubeconfig', $tenantConfig, '--context', 'tenant-demo', '--namespace', 'tenant-demo', '--output', 'json')
function Invoke-Platform([string[]]$Arguments) {
    Invoke-Tool dotnet (@($cli) + $Arguments + $tenantArgs) | ConvertFrom-Json -AsHashtable
}
function Get-Release([string]$Name) {
    Invoke-Kube hub @('get', 'release', $Name, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
}
function Assert-Denied([string]$Member, [string[]]$Arguments, [string]$Message) {
    $log = Join-Path $state 'expected-denial.txt'
    $output = & kubectl --kubeconfig $kubeconfig --context "kind-managed-platform-$Member" @Arguments 2> $log
    $exitCode = $LASTEXITCODE
    $detail = Get-Content $log -Raw
    if ($exitCode -eq 0 -or $detail -notlike "*$Message*") {
        throw "Expected admission rejection '$Message'; exit $exitCode. $detail $output"
    }
}

foreach ($permission in @(
    @('get', 'secrets', '-n', 'fleet-system'),
    @('patch', 'clusterapprovalrequests/status'),
    @('create', 'clusterresourceplacements'),
    @('update', 'releases/status', '-n', 'tenant-demo'),
    @('get', 'servicedefinitions', '-n', 'other-tenant')
)) {
    $allowed = & kubectl --kubeconfig $tenantConfig --context tenant-demo auth can-i @permission
    if ($LASTEXITCODE -ne 1 -or $allowed -cne 'no') { throw 'Tenant received an operator permission.' }
}
$service = Get-Content (Join-Path $root 'samples/service.json') -Raw | ConvertFrom-Json
$service.name = 'hello-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$serviceFile = Join-Path $state 'test-service.json'
$service | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $serviceFile
$plan = Invoke-Platform @('service', 'plan', $serviceFile)
if ($plan.kind -cne 'ServiceDefinition') { throw 'Service plan returned the wrong contract.' }
Invoke-Platform @('service', 'apply', $serviceFile) | Out-Null
$release = Invoke-Platform @('release', 'create', $service.name, '--image', $images.'sample-api')
$releaseName = $release.metadata.name
$script:running = $null
Wait-Until 'persisted execution run' {
    $current = Get-Release $releaseName
    if ($current.ContainsKey('status') -and $current.status.ContainsKey('runUID')) { $script:running = $current; return $true }
    if ($current.ContainsKey('status') -and $current.status['phase'] -ceq 'Failed') { throw $current.status.failure }
    return $false
} 180
$duplicate = Invoke-Platform @('release', 'create', $service.name, '--image', $images.'sample-api')
Invoke-Kube hub @('rollout', 'restart', 'deployment/platform-worker', '-n', 'platform-system') | Write-Host
Invoke-Kube hub @('rollout', 'status', 'deployment/platform-worker', '-n', 'platform-system', '--timeout=120s') | Write-Host
$script:completed = $null
Wait-Until 'self-service release success after worker restart' {
    $current = Get-Release $releaseName
    if ($current.status['phase'] -ceq 'Failed') { throw $current.status.failure }
    if ($current.status['phase'] -ceq 'Succeeded') { $script:completed = $current; return $true }
    return $false
} 300
if ($completed.status.runUID -cne $running.status.runUID -or $completed.status.gatePolicy -cne 'readiness-only') {
    throw 'Worker restart changed the run or its gate policy.'
}
if (($completed.status.observations.Keys | Sort-Object) -join ',' -cne 'member-a,member-b') {
    throw 'Readiness evidence was not persisted for both members.'
}
Wait-Until 'duplicate release rejection' { (Get-Release $duplicate.metadata.name).status['phase'] -ceq 'Failed' } 30
$source = $completed.status.sourceNamespace
$hubPods = Invoke-Kube hub @('get', 'deployments,pods', '-n', $source, '-o', 'json') | ConvertFrom-Json
if (@($hubPods.items).Count -ne 0) { throw 'Application executed on the hub.' }
$members = @{}
foreach ($member in @('member-a', 'member-b')) {
    $deployment = Invoke-Kube $member @('get', 'deployment', 'application', '-n', $source, '-o', 'json') | ConvertFrom-Json
    if ($deployment.status.availableReplicas -ne 2 -or $deployment.spec.template.spec.containers[0].image -cne $images.'sample-api') {
        throw "Wrong image or replica count on $member."
    }
    Set-KubeResource $member @{
        apiVersion = 'v1'; kind = 'Pod'; metadata = @{ name = $service.name; namespace = 'platform-observers'; labels = @{ role = 'traffic' } }
        spec = @{ automountServiceAccountToken = $false; securityContext = @{ runAsNonRoot = $true; runAsUser = 10000
            seccompProfile = @{ type = 'RuntimeDefault' } }
            containers = @(@{ name = 'probe'; image = $versions.testImage; command = @('sleep', '3600')
                securityContext = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{ drop = @('ALL') } }
                resources = @{ requests = @{ cpu = '10m'; memory = '16Mi' }; limits = @{ cpu = '100m'; memory = '32Mi' } } }) }
    }
    Invoke-Kube $member @('wait', ('pod/' + $service.name), '-n', 'platform-observers', '--for=condition=Ready', '--timeout=90s') | Write-Host
    $response = Invoke-Kube $member @('exec', '-n', 'platform-observers', $service.name, '--', 'wget', '-T', '5', '-q', '-O', '-', "http://application.${source}.svc.cluster.local:8080/") | ConvertFrom-Json
    if ($response.service -cne $service.name -or $response.release -cne $releaseName) { throw 'Application returned a different release identity.' }
    $members[$member] = @{ deployment = $deployment; response = $response }
    $imagePatch = @(@{ op = 'replace'; path = '/spec/template/spec/containers/0/image'; value = 'localhost:5001/sample-api:latest' }) | ConvertTo-Json -AsArray -Compress
    Assert-Denied $member @('patch', 'deployment', 'application', '-n', $source, '--type=json', '-p', $imagePatch, '--dry-run=server') 'approved immutable image'
    $privilegedSpec = $deployment.spec.template.spec | ConvertTo-Json -Depth 40 | ConvertFrom-Json
    $privilegedSpec.containers[0].securityContext | Add-Member -NotePropertyName privileged -NotePropertyValue $true -Force
    $privilegedSpec.containers[0].securityContext.allowPrivilegeEscalation = $true
    $privilegedFile = Join-Path $state 'privileged-pod.json'
    @{ apiVersion = 'v1'; kind = 'Pod'; metadata = @{ name = 'admission-probe'; namespace = $source }; spec = $privilegedSpec } |
        ConvertTo-Json -Depth 50 | Set-Content -LiteralPath $privilegedFile
    Assert-Denied $member @('create', '-f', $privilegedFile, '--dry-run=server') 'violates PodSecurity'
}
$releasePatch = @{ spec = @{ image = 'localhost:5001/sample-api@sha256:' + ('a' * 64) } } | ConvertTo-Json -Compress
Assert-Denied hub @('patch', 'release', $releaseName, '-n', 'tenant-demo', '--type=merge', '-p', $releasePatch, '--dry-run=server') 'immutable'
$export = Invoke-Platform @('evidence', 'export', $releaseName)
@{ commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')
    workingTreeDirty = @(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0
    completedAt = [DateTime]::UtcNow.ToString('o'); release = $export; members = $members
    duplicateRelease = Get-Release $duplicate.metadata.name; workerRestartPreservedRun = $true
    tenantOperatorPermissionsDenied = $true; mutableImageDenied = $true; privilegedPodDenied = $true; immutableReleaseSpec = $true
} | ConvertTo-Json -Depth 70 | Set-Content -LiteralPath (Join-Path $state 'deployment-evidence.json')
Write-Host 'Self-service passed: tenant CLI, two members, application responses, restart, duplicate rejection, and admission checks.'
