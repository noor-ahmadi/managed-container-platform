#requires -Version 7.0
param([ValidateSet('up', 'down')][string]$Action = 'up')
. (Join-Path $PSScriptRoot 'common.ps1')
$registry = 'managed-platform-registry'
$recordFile = Join-Path $state 'registry.json'
if ($Action -eq 'down' -and -not (Test-Path -LiteralPath $recordFile)) { return }
$id = Invoke-Tool docker @('ps', '-aq', '--filter', "name=^/$registry`$")
$record = if (Test-Path -LiteralPath $recordFile) { Get-Content $recordFile -Raw | ConvertFrom-Json } else { $null }
if ($id) {
    $container = (Invoke-Tool docker @('inspect', $id) | ConvertFrom-Json)[0]
    if ($null -eq $record -or $record.name -cne $registry -or
        ($record.id -and $record.id -cne $container.Id) -or
        $container.Config.Labels.'platform.project' -cne 'managed-container-platform' -or
        $container.Config.Image -cne $versions.registryImage) { throw 'Refusing an unowned or mismatched local registry.' }
}
if ($Action -eq 'down') {
    if ($id) { Invoke-Tool docker @('rm', '--force', '--volumes', $id) | Write-Host }
    Remove-Item -LiteralPath $recordFile
    return
}
if (-not $id) {
    @{ name = $registry; id = $null } | ConvertTo-Json | Set-Content -LiteralPath $recordFile
    $id = Invoke-Tool docker @('run', '-d', '--name', $registry, '--label', 'platform.project=managed-container-platform',
        '--publish', '127.0.0.1:5001:5000', '--network', 'kind', $versions.registryImage)
    @{ name = $registry; id = $id } | ConvertTo-Json | Set-Content -LiteralPath $recordFile
} else {
    Invoke-Tool docker @('start', $id) | Out-Null
}
Wait-Until 'local registry readiness' {
    try { Invoke-WebRequest 'http://localhost:5001/v2/' -TimeoutSec 3 | Out-Null; return $true } catch { return $false }
} 60
foreach ($cluster in @('hub', 'member-a', 'member-b')) {
    $node = "managed-platform-$cluster-control-plane"
    $directory = '/etc/containerd/certs.d/localhost:5001'
    Invoke-Tool docker @('exec', $node, 'mkdir', '-p', $directory) | Out-Null
    '[host."http://managed-platform-registry:5000"]
  capabilities = ["pull", "resolve"]' | & docker exec -i $node tee "$directory/hosts.toml" | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Cannot configure registry on $node." }
}
Write-Host 'Local registry is ready on 127.0.0.1:5001.'
