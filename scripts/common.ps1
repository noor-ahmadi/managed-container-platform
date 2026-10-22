$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$PSNativeCommandUseErrorActionPreference = $false
$root = Split-Path $PSScriptRoot -Parent
$versions = Get-Content (Join-Path $root 'local/versions.json') -Raw | ConvertFrom-Json
$state = Join-Path $root '.local'
$kubeconfig = Join-Path $state 'kubeconfig'

function Invoke-Tool([string]$Tool, [string[]]$Arguments) {
    $result = & $Tool @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Tool $($Arguments -join ' ') exited with code $LASTEXITCODE."
    }
    $result | ForEach-Object { "$_" }
}

function Invoke-Kube([string]$Cluster, [string[]]$Arguments) {
    Invoke-Tool kubectl (@('--kubeconfig', $kubeconfig, '--context', "kind-managed-platform-$Cluster",
        '--request-timeout=30s') + $Arguments)
}

function Set-KubeResource([string]$Cluster, [hashtable]$Resource) {
    $Resource | ConvertTo-Json -Depth 50 | & kubectl --kubeconfig $kubeconfig `
        --context "kind-managed-platform-$Cluster" --request-timeout=30s apply `
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
