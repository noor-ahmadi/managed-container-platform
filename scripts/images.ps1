#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
& (Join-Path $PSScriptRoot 'registry.ps1') up
$images = @{}
foreach ($image in @(
    @{ Name = 'worker'; Dockerfile = 'src/Platform/Dockerfile' },
    @{ Name = 'sample-api'; Dockerfile = 'samples/HttpApi/Dockerfile' }
)) {
    $tag = "localhost:5001/$($image.Name):dev"
    Invoke-Tool docker @('build', '--file', (Join-Path $root $image.Dockerfile), '--tag', $tag, $root) | Write-Host
    Invoke-Tool docker @('push', $tag) | Write-Host
    $manifest = Invoke-WebRequest "http://localhost:5001/v2/$($image.Name)/manifests/dev" -Method Head `
        -Headers @{ Accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' }
    $digest = [string]$manifest.Headers['Docker-Content-Digest'][0]
    if ($digest -cnotmatch '^sha256:[a-f0-9]{64}$') { throw 'Registry returned an invalid image digest.' }
    $images[$image.Name] = "localhost:5001/$($image.Name)@$digest"
}
$images | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $state 'images.json')
Write-Host 'Built and pushed immutable local images. References: .local/images.json'
