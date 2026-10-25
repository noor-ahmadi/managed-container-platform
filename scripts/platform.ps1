#requires -Version 7.0
param([ValidateSet('local', 'azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
if ($Target -ceq 'local') { & (Join-Path $PSScriptRoot 'local.ps1') up }
else { & (Join-Path $PSScriptRoot 'fleet.ps1') -Target azure }
Invoke-Tool dotnet @('restore', (Join-Path $root 'ManagedContainerPlatform.slnx'), '--locked-mode') | Write-Host
Invoke-Tool dotnet @('build', (Join-Path $root 'ManagedContainerPlatform.slnx'), '--no-restore') | Write-Host
& (Join-Path $PSScriptRoot 'images.ps1') -Target $Target
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json
$repository = ($images.'sample-api' -split '@')[0]
Invoke-Kube hub @('apply', '--server-side', '--field-manager=managed-platform-local', '-f', (Join-Path $root 'platform/crds.yaml')) | Write-Host
Invoke-Kube hub @('wait', 'crd/servicedefinitions.platform.example.com', 'crd/releases.platform.example.com', '--for=condition=Established', '--timeout=60s') | Write-Host
foreach ($member in @('member-a', 'member-b')) {
    $manifest = (Get-Content (Join-Path $root 'platform/member.yaml') -Raw).Replace('__SAMPLE_REPOSITORY__', $repository)
    $manifest | & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) apply --server-side --field-manager=managed-platform-local -f -
    if ($LASTEXITCODE -ne 0) { throw "Cannot install member policy on $member." }
}
$hubManifest = (Get-Content (Join-Path $root 'platform/hub.yaml') -Raw).Replace('__WORKER_IMAGE__', $images.worker).Replace('__SAMPLE_REPOSITORY__', $repository)
$hubManifest | & kubectl --kubeconfig $kubeconfig --context (Get-Context hub) apply --server-side --field-manager=managed-platform-local -f -
if ($LASTEXITCODE -ne 0) { throw 'Cannot install the platform worker.' }
& (Join-Path $PSScriptRoot 'observers.ps1') -Target $Target
& (Join-Path $PSScriptRoot 'scaling.ps1') -Target $Target
Invoke-Kube hub @('rollout', 'status', 'deployment/platform-worker', '-n', 'platform-system', '--timeout=180s') | Write-Host
$hub = Invoke-Kube hub @('config', 'view', '--minify', '--raw', '-o', 'json') | ConvertFrom-Json
$token = Invoke-Kube hub @('create', 'token', 'developer', '-n', 'tenant-demo', '--duration=1h')
$tenantConfig = Join-Path $state 'tenant-kubeconfig'
@{
    apiVersion = 'v1'; kind = 'Config'; 'current-context' = 'tenant-demo'
    clusters = @(@{ name = 'hub'; cluster = $hub.clusters[0].cluster })
    users = @(@{ name = 'developer'; user = @{ token = $token } })
    contexts = @(@{ name = 'tenant-demo'; context = @{ cluster = 'hub'; user = 'developer'; namespace = 'tenant-demo' } })
} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $tenantConfig
$token = $null
if (-not $IsWindows) { [IO.File]::SetUnixFileMode($tenantConfig, [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite) }
Write-Host "Platform is ready. Tenant credentials expire in one hour: $tenantConfig"
