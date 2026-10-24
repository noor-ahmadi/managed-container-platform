param([ValidateSet('local', 'azure')][string]$Target = 'local')
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
$versions = Get-Content (Join-Path $root 'local/versions.json') -Raw | ConvertFrom-Json
$state = Join-Path $root '.local'
if ($Target -ceq 'azure') { $state = Join-Path $state 'azure' }
$kubeconfig = Join-Path $state 'kubeconfig'
$contextPrefix = if ($Target -ceq 'azure') { 'managed-platform-azure' } else { 'kind-managed-platform' }

function Invoke-Tool([string]$Tool, [string[]]$Arguments) {
    # Avoid cmd.exe interpreting JSON, URLs, or JMESPath operators in az.cmd arguments.
    if ($IsWindows -and $Tool -ceq 'az') {
        $launcher = (Get-Command az -CommandType Application).Source
        $python = Join-Path (Split-Path (Split-Path $launcher -Parent) -Parent) 'python.exe'
        if (-not (Test-Path -LiteralPath $python)) { throw 'Cannot find Azure CLI bundled Python.' }
        $result = & $python -IBm azure.cli @Arguments
    } else { $result = & $Tool @Arguments }
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool $($Arguments -join ' ') exited with code $LASTEXITCODE."
    }
    $result | ForEach-Object { "$_" }
}

function Invoke-Kube([string]$Cluster, [string[]]$Arguments) {
    Invoke-Tool kubectl (@('--kubeconfig', $kubeconfig, '--context', (Get-Context $Cluster),
        '--request-timeout=30s') + $Arguments)
}

function Get-Context([string]$Cluster) { "$contextPrefix-$Cluster" }

function Get-ClusterConnection([string]$Cluster) {
    $config = Invoke-Kube $Cluster @('config', 'view', '--minify', '--raw', '-o', 'json') | ConvertFrom-Json -AsHashtable
    $connection = $config.clusters[0].cluster
    if ($Target -ceq 'local') {
        $ip = Invoke-Tool docker @('inspect', '--format', '{{(index .NetworkSettings.Networks "kind").IPAddress}}', "managed-platform-$Cluster-control-plane")
        $parsed = $null
        if (-not [Net.IPAddress]::TryParse([string]$ip, [ref]$parsed)) { throw 'Cannot find the local cluster address.' }
        $connection.server = "https://${ip}:6443"
    }
    if (-not $connection['certificate-authority-data'] -or $connection['insecure-skip-tls-verify'] -or
        ([Uri]$connection.server).Scheme -cne 'https') { throw 'Cluster connection must verify TLS.' }
    $connection
}

function Set-KubeResource([string]$Cluster, [hashtable]$Resource) {
    $Resource | ConvertTo-Json -Depth 50 | & kubectl --kubeconfig $kubeconfig `
        --context (Get-Context $Cluster) --request-timeout=30s apply `
        --server-side --field-manager=managed-platform-local -f - | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Cannot apply $($Resource.kind) on $Cluster." }
}

function Wait-Until([string]$Description, [scriptblock]$Check, [int]$Seconds = 180) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (& $Check) { return }
        Start-Sleep -Seconds 2
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $Description"
}
