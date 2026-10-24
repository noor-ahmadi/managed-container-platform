#requires -Version 7.0
param([ValidateSet('local', 'azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
$registry = 'localhost:5001'
if ($Target -ceq 'local') { & (Join-Path $PSScriptRoot 'registry.ps1') up }
else {
    $session = Get-Content (Join-Path $state 'session.json') -Raw | ConvertFrom-Json
    $registry = $session.registryServer
    Invoke-Tool az @('acr', 'login', '--name', $session.registry) | Write-Host
}
$images = @{}
$revision = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')
$dirty = (@(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0).ToString().ToLowerInvariant()
foreach ($image in @(
    @{ Name = 'worker'; Repository = 'worker'; Tag = 'dev'; Dockerfile = 'src/Platform/Dockerfile'; Errors = 'false' },
    @{ Name = 'sample-api'; Repository = 'sample-api'; Tag = 'dev'; Dockerfile = 'samples/HttpApi/Dockerfile'; Errors = 'false' },
    @{ Name = 'sample-api-error'; Repository = 'sample-api'; Tag = 'error'; Dockerfile = 'samples/HttpApi/Dockerfile'; Errors = 'true' }
)) {
    $repository = "$registry/$($image.Repository)"
    $tag = "$($repository):$($image.Tag)"
    Invoke-Tool docker @('build', '--file', (Join-Path $root $image.Dockerfile), '--build-arg', "DEMO_ERRORS=$($image.Errors)",
        '--build-arg', "SOURCE_REVISION=$revision", '--build-arg', "SOURCE_DIRTY=$dirty", '--tag', $tag, $root) | Write-Host
    Invoke-Tool docker @('push', $tag) | Write-Host
    $digests = Invoke-Tool docker @('image', 'inspect', $tag, '--format', '{{json .RepoDigests}}') | ConvertFrom-Json
    $matching = @($digests | Where-Object { $_.StartsWith($repository + '@', [StringComparison]::Ordinal) })
    if ($matching.Count -ne 1 -or ($matching[0] -split '@')[1] -cnotmatch '^sha256:[a-f0-9]{64}$') {
        throw 'Pushed image has no unambiguous immutable registry reference.'
    }
    $images[$image.Name] = $matching[0]
}
$images | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state 'images.json')
Write-Host "Built and pushed immutable images. References: $state/images.json"
