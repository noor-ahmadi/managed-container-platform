#requires -Version 7.0
param([ValidateRange(1024,65535)][int]$Port = 5280, [ValidateSet('local','azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
$tenantConfig = Join-Path $state 'tenant-kubeconfig'
if (-not (Test-Path -LiteralPath $tenantConfig -PathType Leaf)) { throw 'Bootstrap the platform to create tenant credentials first.' }
Invoke-Tool dotnet @('run', '--project', (Join-Path $root 'src/Portal/Portal.csproj'), '--no-launch-profile', '--',
    '--kubeconfig', $tenantConfig, '--context', 'tenant-demo', '--namespace', 'tenant-demo', '--port', "$Port") | Write-Host
