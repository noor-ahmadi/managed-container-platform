#requires -Version 7.0
param([ValidateSet('local', 'azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
foreach ($member in @('member-a', 'member-b')) {
    $manifest = (Get-Content (Join-Path $root 'platform/observers.yaml') -Raw).
        Replace('__MEMBER__', $member).Replace('__COLLECTOR_IMAGE__', $versions.collectorImage).
        Replace('__PROMETHEUS_IMAGE__', $versions.prometheusImage)
    $manifest | & kubectl --kubeconfig $kubeconfig --context (Get-Context $member) apply --server-side --field-manager=managed-platform-local -f -
    if ($LASTEXITCODE -ne 0) { throw "Cannot install observers on $member." }
    foreach ($deployment in @('collector', 'prometheus')) {
        Invoke-Kube $member @('rollout', 'status', "deployment/$deployment", '-n', 'platform-observers', '--timeout=180s') | Write-Host
    }
    $connection = Get-ClusterConnection $member
    $token = Invoke-Kube $member @('create', 'token', 'observer', '-n', 'platform-observers', '--duration=1h')
    $config = @{
        apiVersion = 'v1'; kind = 'Config'; 'current-context' = 'observer'
        clusters = @(@{name = $member; cluster = $connection})
        users = @(@{name = 'observer'; user = @{token = $token}})
        contexts = @(@{name = 'observer'; context = @{cluster = $member; user = 'observer'}})
    } | ConvertTo-Json -Depth 12
    Set-KubeResource hub @{
        apiVersion = 'v1'; kind = 'Secret'; metadata = @{name = "observer-$member"; namespace = 'platform-system'}
        type = 'Opaque'; data = @{kubeconfig = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($config))}
    }
    $token = $null; $config = $null
}
Write-Host 'Member telemetry and read-only observer credentials are ready; credentials expire in one hour.'
