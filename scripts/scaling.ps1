#requires -Version 7.0
param([ValidateSet('local', 'azure')][string]$Target = 'local')
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
$charts = Join-Path $state 'charts'
New-Item -ItemType Directory -Path $charts -Force | Out-Null
$archive = Join-Path $charts "keda-$($versions.keda).tgz"
if (-not (Test-Path -LiteralPath $archive)) {
    Invoke-Tool helm @('pull', 'keda', '--repo', 'https://kedacore.github.io/charts', '--version', $versions.keda, '--destination', $charts) | Write-Host
}
if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant() -cne $versions.kedaChartSha256) { throw 'KEDA chart checksum mismatch.' }
$valuesFile = Join-Path $state 'keda-values.json'
@{
    image = @{
        keda = @{tag = "$($versions.keda)@$($versions.kedaImageDigest)"}
        metricsApiServer = @{tag = "$($versions.keda)@$($versions.kedaMetricsImageDigest)"}
        webhooks = @{tag = "$($versions.keda)@$($versions.kedaWebhookImageDigest)"}
    }
    permissions = @{operator = @{restrict = @{secret = $true}}; metricServer = @{restrict = @{secret = $true}}}
    watchLabelSelector = 'platform.example.com/autoscaling=managed'
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $valuesFile
foreach ($member in @('member-a', 'member-b')) {
    Set-KubeResource $member @{apiVersion = 'v1'; kind = 'Namespace'; metadata = @{name = 'platform-scaling'
        labels = @{'pod-security.kubernetes.io/enforce' = 'restricted'; 'pod-security.kubernetes.io/enforce-version' = 'v1.35'}}}
    Invoke-Tool helm @('upgrade', '--install', 'keda', $archive, '--namespace', 'platform-scaling',
        '--kubeconfig', $kubeconfig, '--kube-context', (Get-Context $member), '--values', $valuesFile,
        '--wait', '--timeout', '5m', '--history-max', '2') | Write-Host
    Invoke-Kube $member @('wait', 'apiservice/v1beta1.external.metrics.k8s.io', '--for=condition=Available', '--timeout=180s') | Write-Host
    $service = Invoke-Kube $member @('get', 'apiservice/v1beta1.external.metrics.k8s.io', '-o', 'json') | ConvertFrom-Json -AsHashtable
    if ($service.spec['insecureSkipTLSVerify'] -or -not $service.spec['caBundle']) { throw 'KEDA metrics API must verify its serving certificate.' }
}
Write-Host 'Request scaling is ready on both members with pinned controllers and verified metrics API TLS.'
