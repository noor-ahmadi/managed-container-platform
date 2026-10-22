#requires -Version 7.0
param([ValidateSet('check', 'up', 'down')][string]$Action = 'check')

. (Join-Path $PSScriptRoot 'common.ps1')
$ownership = Join-Path $state 'clusters.json'
$names = @('managed-platform-hub', 'managed-platform-member-a', 'managed-platform-member-b')

$provider = $env:KIND_EXPERIMENTAL_PROVIDER
$originalPath = $env:PATH
try {
    $env:PATH = (Join-Path $state 'bin') + [IO.Path]::PathSeparator + $env:PATH
    $env:KIND_EXPERIMENTAL_PROVIDER = 'docker'
    foreach ($tool in @('docker', 'kind')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "Install $tool and add it to PATH. See README.md."
        }
    }
    if ((Invoke-Tool kind @('version', '-q')) -cne $versions.kind) {
        throw "Use kind $($versions.kind), as pinned in local/versions.json."
    }
    if ((Invoke-Tool docker @('info', '--format', '{{.OSType}}')) -cne 'linux') {
        throw "Start Docker's Linux engine."
    }
    if ($Action -ne 'down') {
        if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
            throw 'Install kubectl and add it to PATH. See README.md.'
        }
        if (-not (Get-Command helm -ErrorAction SilentlyContinue) -or
            (Invoke-Tool helm @('version', '--template', '{{.Version}}')) -cne "v$($versions.helm)") {
            throw "Install Helm $($versions.helm) and add it to PATH."
        }
        $client = Invoke-Tool kubectl @('version', '--client', '-o', 'json') | ConvertFrom-Json
        $clientVersion = [version](($client.clientVersion.gitVersion.TrimStart('v') -split '[-+]')[0])
        $serverVersion = [version]$versions.kubernetes
        if ($clientVersion.Major -ne $serverVersion.Major -or [Math]::Abs($clientVersion.Minor - $serverVersion.Minor) -gt 1) {
            throw "kubectl must be within one minor of Kubernetes $serverVersion."
        }
    }
    if ($Action -eq 'check') {
        Write-Host "Ready: kind $($versions.kind), Helm $($versions.helm), kubectl $clientVersion, Docker Linux engine."
        return
    }

    New-Item -ItemType Directory -Path $state -Force | Out-Null
    # ponytail: one local command at a time; add a file lock if concurrent use is needed.
    $owned = @()
    if (Test-Path -LiteralPath $ownership) {
        $owned = @(Get-Content -LiteralPath $ownership -Raw | ConvertFrom-Json)
    }
    foreach ($name in $owned) {
        if ($name -cnotin $names) { throw "Refusing unknown cluster in ownership file: $name" }
    }
    $existing = @(Invoke-Tool kind @('get', 'clusters'))

    if ($Action -eq 'down') {
        foreach ($name in @($owned)) {
            Invoke-Tool kind @('delete', 'cluster', '--name', $name, '--kubeconfig', $kubeconfig) | Write-Host
            if ($name -cin @(Invoke-Tool kind @('get', 'clusters'))) {
                throw "Cluster $name still exists; keeping its ownership record."
            }
            $owned = @($owned | Where-Object { $_ -cne $name })
            ConvertTo-Json -InputObject $owned | Set-Content -LiteralPath $ownership
        }
        Write-Host 'No project-owned clusters remain.'
        return
    }

    foreach ($name in $names) {
        if ($name -cin $existing -and $name -cnotin $owned) {
            throw "Cluster $name already exists without an ownership record. Refusing to adopt it."
        }
    }
    $config = Join-Path $state 'kind.json'
    @{
        kind = 'Cluster'
        apiVersion = 'kind.x-k8s.io/v1alpha4'
        networking = @{ apiServerAddress = '127.0.0.1' }
        nodes = @(@{ role = 'control-plane' })
    } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $config

    foreach ($name in $names) {
        if ($name -cnotin $existing) {
            if ($name -cnotin $owned) {
                $owned += $name
                ConvertTo-Json -InputObject $owned | Set-Content -LiteralPath $ownership
            }
            Invoke-Tool kind @('create', 'cluster', '--name', $name, '--config', $config,
                '--image', $versions.nodeImage, '--kubeconfig', $kubeconfig, '--wait', '180s') | Write-Host
        } else {
            Invoke-Tool kind @('export', 'kubeconfig', '--name', $name, '--kubeconfig', $kubeconfig) | Write-Host
        }
        foreach ($node in @(Invoke-Tool kind @('get', 'nodes', '--name', $name))) {
            if ((Invoke-Tool docker @('inspect', '--format', '{{.Config.Image}}', $node)) -cne $versions.nodeImage) {
                throw "Cluster $name does not use the pinned node image."
            }
        }
        $context = @('--kubeconfig', $kubeconfig, '--context', "kind-$name")
        Invoke-Tool kubectl ($context + @('wait', '--for=condition=Ready', 'nodes', '--all', '--timeout=180s')) | Write-Host
        $nodes = Invoke-Tool kubectl ($context + @('get', 'nodes', '-o', 'json')) | ConvertFrom-Json
        if (@($nodes.items).Count -ne 1 -or $nodes.items[0].status.nodeInfo.kubeletVersion -cne "v$($versions.kubernetes)") {
            throw "Cluster $name does not match the pinned single-node configuration."
        }
        Write-Host "$name is ready."
    }
    & (Join-Path $PSScriptRoot 'fleet.ps1')
    Write-Host "Kubeconfig: $kubeconfig"
} finally {
    $env:KIND_EXPERIMENTAL_PROVIDER = $provider
    $env:PATH = $originalPath
}
