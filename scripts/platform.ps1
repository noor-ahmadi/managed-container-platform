#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
& (Join-Path $PSScriptRoot 'local.ps1') up
Invoke-Tool dotnet @('restore', (Join-Path $root 'ManagedContainerPlatform.slnx'), '--locked-mode') | Write-Host
Invoke-Tool dotnet @('build', (Join-Path $root 'ManagedContainerPlatform.slnx'), '--no-restore') | Write-Host
& (Join-Path $PSScriptRoot 'images.ps1')
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json
Invoke-Kube hub @('apply', '--server-side', '--field-manager=managed-platform-local', '-f', (Join-Path $root 'platform/crds.yaml')) | Write-Host
Invoke-Kube hub @('wait', 'crd/servicedefinitions.platform.example.com', 'crd/releases.platform.example.com', '--for=condition=Established', '--timeout=60s') | Write-Host
foreach ($member in @('member-a', 'member-b')) {
    Invoke-Kube $member @('apply', '--server-side', '--field-manager=managed-platform-local', '-f', (Join-Path $root 'platform/member.yaml')) | Write-Host
}
$hubManifest = (Get-Content (Join-Path $root 'platform/hub.yaml') -Raw).Replace('__WORKER_IMAGE__', $images.worker)
$hubManifest | & kubectl --kubeconfig $kubeconfig --context kind-managed-platform-hub apply --server-side --field-manager=managed-platform-local -f -
if ($LASTEXITCODE -ne 0) { throw 'Cannot install the platform worker.' }
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
Write-Host 'Platform is ready. Tenant credentials expire in one hour: .local/tenant-kubeconfig'
