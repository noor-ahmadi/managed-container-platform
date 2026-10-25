#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$local = Join-Path $PSScriptRoot 'local.ps1'
$state = Join-Path $root '.local'
$kubeconfig = Join-Path $state 'kubeconfig'
$ownership = Join-Path $state 'clusters.json'
$names = @('managed-platform-hub', 'managed-platform-member-a', 'managed-platform-member-b')
$env:PATH = (Join-Path $state 'bin') + [IO.Path]::PathSeparator + $env:PATH

& $local check
$before = @(kind get clusters)
if ($LASTEXITCODE -ne 0) { throw 'Cannot list existing clusters.' }
if (@($before | Where-Object { $_ -cin $names }).Count -gt 0) {
    throw 'Lifecycle check requires the project clusters to be absent. Run local.ps1 down first.'
}
if ((Test-Path -LiteralPath $ownership) -and @(Get-Content $ownership -Raw | ConvertFrom-Json).Count -gt 0) {
    throw 'Lifecycle check requires an empty ownership record.'
}

New-Item -ItemType Directory -Path $state -Force | Out-Null
foreach ($receipt in @('foundation-evidence.json', 'deployment-evidence.json', 'safe-release-evidence.json', 'autoscaling-evidence.json')) {
    $receiptPath = Join-Path $state $receipt
    if (Test-Path -LiteralPath $receiptPath -PathType Leaf) { Remove-Item -LiteralPath $receiptPath }
}
$sentinel = Join-Path $state 'test-default-kubeconfig'
Set-Content -LiteralPath $sentinel -Value 'apiVersion: v1
kind: Config
clusters: []
contexts: []
users: []
current-context: ""'
$sentinelHash = (Get-FileHash -LiteralPath $sentinel).Hash
$originalConfig = $env:KUBECONFIG
try {
    $env:KUBECONFIG = $sentinel
    & $local up
    $identities = @{}
    foreach ($name in $names) {
        $node = kubectl --kubeconfig $kubeconfig --context "kind-$name" get nodes -o json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0) { throw "Cannot query $name." }
        $identities[$name] = $node.items[0].metadata.uid
    }
    $record = Get-Content -LiteralPath $ownership -Raw
    try {
        foreach ($case in @(
            @{ Record = '[]'; Action = 'up'; Error = '*without an ownership record*' },
            @{ Record = '["unrelated-cluster"]'; Action = 'down'; Error = '*unknown cluster*' }
        )) {
            Set-Content -LiteralPath $ownership -Value $case.Record
            try {
                & $local $case.Action
                throw 'Expected an ownership check to refuse the operation.'
            } catch {
                if ($_.Exception.Message -notlike $case.Error) { throw }
            }
        }
    } finally {
        Set-Content -LiteralPath $ownership -Value $record
    }
    & $local up
    foreach ($name in $names) {
        $node = kubectl --kubeconfig $kubeconfig --context "kind-$name" get nodes -o json | ConvertFrom-Json
        if ($LASTEXITCODE -ne 0 -or $identities[$name] -cne $node.items[0].metadata.uid) {
            throw "Repeated startup replaced $name."
        }
    }
    & (Join-Path $PSScriptRoot 'test-fleet.ps1')
    & (Join-Path $PSScriptRoot 'test-platform.ps1')
    & (Join-Path $PSScriptRoot 'test-safe-releases.ps1')
    & (Join-Path $PSScriptRoot 'test-autoscaling.ps1')
    & $local down
    & $local down
    if ((Test-Path (Join-Path $state 'registry.json')) -or
        (docker ps -aq --filter 'name=^/managed-platform-registry$')) { throw 'Teardown left the project registry behind.' }
    $after = @(kind get clusters)
    if ($LASTEXITCODE -ne 0 -or @($names | Where-Object { $_ -cin $after }).Count -gt 0) {
        throw 'Teardown left project clusters behind.'
    }
    if ((($before | Sort-Object) -join "`n") -cne (($after | Sort-Object) -join "`n")) {
        throw 'Unrelated cluster names changed.'
    }
    if ((Get-FileHash -LiteralPath $sentinel).Hash -cne $sentinelHash) {
        throw 'The default kubeconfig changed.'
    }
    Write-Host 'Lifecycle check passed: pinned nodes, ownership checks, repeated startup and teardown, isolated kubeconfig.'
} finally {
    try { & $local down } finally { $env:KUBECONFIG = $originalConfig }
}
