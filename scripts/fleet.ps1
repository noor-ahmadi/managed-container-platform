#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')

if ((Invoke-Tool helm @('version', '--template', '{{.Version}}')) -cne "v$($versions.helm)") {
    throw "Use Helm $($versions.helm), as pinned in local/versions.json."
}
$charts = Join-Path $state 'charts'
New-Item -ItemType Directory -Path $charts -Force | Out-Null
foreach ($agent in @('hub', 'member')) {
    $archive = Join-Path $charts "$agent-agent-$($versions.fleet).tgz"
    if (-not (Test-Path -LiteralPath $archive)) {
        Invoke-Tool helm @('pull', "oci://ghcr.io/kubefleet-dev/kubefleet/charts/$agent-agent",
            '--version', $versions.fleet, '--destination', $charts) | Write-Host
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $versions."$($agent)ChartSha256") {
        throw "Checksum mismatch for $archive."
    }
}

function Install-Agent([string]$Cluster, [string]$Agent, [hashtable]$Values) {
    $valuesFile = Join-Path $state "$Cluster-values.json"
    $Values | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $valuesFile
    Invoke-Tool helm @('upgrade', '--install', "$Agent-agent", (Join-Path $charts "$Agent-agent-$($versions.fleet).tgz"),
        '--kubeconfig', $kubeconfig, '--kube-context', "kind-managed-platform-$Cluster",
        '--namespace', 'fleet-system', '--create-namespace', '--values', $valuesFile,
        '--wait', '--timeout', '5m', '--history-max', '2') | Write-Host
}

Install-Agent hub hub @{
    enableWorkload = $true
    enablePprof = $false
    # The pinned chart emits this flag even when its default value is unset.
    logFileMaxSize = 1800
    image = @{ tag = "v$($versions.fleet)@$($versions.hubImageDigest)" }
}
$hubCA = Invoke-Kube hub @('config', 'view', '--minify', '--raw', '-o', 'jsonpath={.clusters[0].cluster.certificate-authority-data}')
$hubIP = Invoke-Tool docker @('inspect', '--format', '{{(index .NetworkSettings.Networks "kind").IPAddress}}',
    'managed-platform-hub-control-plane')
$parsedIP = $null
if (-not [Net.IPAddress]::TryParse([string]$hubIP, [ref]$parsedIP)) { throw 'Cannot find the local hub address.' }

foreach ($member in @('member-a', 'member-b')) {
    $account = "$member-hub-access"
    Set-KubeResource hub @{
        apiVersion = 'v1'; kind = 'ServiceAccount'
        metadata = @{ name = $account; namespace = 'fleet-system' }
    }
    # ponytail: local-only service-account tokens; cloud enrollment needs its own credential lifecycle.
    Set-KubeResource hub @{
        apiVersion = 'v1'; kind = 'Secret'; type = 'kubernetes.io/service-account-token'
        metadata = @{ name = $account; namespace = 'fleet-system'
            annotations = @{ 'kubernetes.io/service-account.name' = $account } }
    }
    Invoke-Kube hub @('wait', "secret/$account", '-n', 'fleet-system', '--for=jsonpath={.data.token}', '--timeout=60s') | Write-Host
    $secret = Invoke-Kube hub @('get', 'secret', $account, '-n', 'fleet-system', '-o', 'json') | ConvertFrom-Json
    Set-KubeResource $member @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = 'fleet-system' } }
    # Send the token through stdin, never command-line arguments or a values file.
    Set-KubeResource $member @{
        apiVersion = 'v1'; kind = 'Secret'; type = 'Opaque'
        metadata = @{ name = 'hub-credentials'; namespace = 'fleet-system' }
        data = @{ token = $secret.data.token }
    }
    $secret = $null
    Set-KubeResource hub @{
        apiVersion = 'cluster.kubernetes-fleet.io/v1'; kind = 'MemberCluster'
        metadata = @{ name = $member; labels = @{ 'platform.example.com/region' = $member } }
        spec = @{ identity = @{ kind = 'ServiceAccount'; name = $account; namespace = 'fleet-system' }
            heartbeatPeriodSeconds = 15 }
    }
    Install-Agent $member member @{
        enablePprof = $false
        # Keep mirrored readiness within the worker's 30-second freshness limit.
        workApplierRequeueRateLimiterMaxFastBackoffDelaySeconds = 15
        image = @{ tag = "v$($versions.fleet)@$($versions.memberImageDigest)" }
        refreshtoken = @{ tag = "v$($versions.fleet)@$($versions.refreshTokenImageDigest)" }
        config = @{ hubURL = "https://${hubIP}:6443"; hubCA = $hubCA; memberClusterName = $member }
        secret = @{ name = 'hub-credentials'; namespace = 'fleet-system' }
        tlsClientInsecure = $false
    }
    Invoke-Kube hub @('wait', "membercluster/$member", '--for=condition=Joined', '--timeout=180s') | Write-Host
}
Write-Host 'Fleet is ready: TLS-verified hub and two joined members.'
