#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
& (Join-Path $PSScriptRoot 'registry.ps1') up
$images = @{}
$revision = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')
$dirty = (@(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0).ToString().ToLowerInvariant()
foreach ($image in @(
    @{ Name = 'worker'; Repository = 'worker'; Tag = 'dev'; Dockerfile = 'src/Platform/Dockerfile'; Errors = 'false' },
    @{ Name = 'sample-api'; Repository = 'sample-api'; Tag = 'dev'; Dockerfile = 'samples/HttpApi/Dockerfile'; Errors = 'false' },
    @{ Name = 'sample-api-error'; Repository = 'sample-api'; Tag = 'error'; Dockerfile = 'samples/HttpApi/Dockerfile'; Errors = 'true' }
)) {
    $tag = "localhost:5001/$($image.Repository):$($image.Tag)"
    Invoke-Tool docker @('build', '--file', (Join-Path $root $image.Dockerfile), '--build-arg', "DEMO_ERRORS=$($image.Errors)",
        '--build-arg', "SOURCE_REVISION=$revision", '--build-arg', "SOURCE_DIRTY=$dirty", '--tag', $tag, $root) | Write-Host
    Invoke-Tool docker @('push', $tag) | Write-Host
    $manifest = Invoke-WebRequest "http://localhost:5001/v2/$($image.Repository)/manifests/$($image.Tag)" -Method Head `
        -Headers @{ Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' }
    $digest = [string]$manifest.Headers['Docker-Content-Digest'][0]
    if ($digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Registry returned an invalid image digest.' }
    $images[$image.Name] = "localhost:5001/$($image.Repository)@$digest"
}
$images | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state 'images.json')
Write-Host 'Built and pushed immutable local images. References: .local/images.json'
