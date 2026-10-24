#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1') -Target azure
$session = Get-Content (Join-Path $state 'session.json') -Raw | ConvertFrom-Json
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json
$results = @{}
foreach ($member in @('member-a', 'member-b')) {
    Set-KubeResource $member @{apiVersion = 'v1'; kind = 'Namespace'; metadata = @{name = 'platform-identity'
        labels = @{'pod-security.kubernetes.io/enforce' = 'restricted'; 'pod-security.kubernetes.io/enforce-version' = 'v1.35'}}}
    foreach ($account in @('bound', 'unbound')) {
        Set-KubeResource $member @{apiVersion = 'v1'; kind = 'ServiceAccount'; metadata = @{name = $account; namespace = 'platform-identity'
            annotations = @{'azure.workload.identity/client-id' = $session.identityClientId; 'azure.workload.identity/tenant-id' = $session.identityTenantId}}
            automountServiceAccountToken = $false}
        $expected = if ($account -ceq 'bound') { 'allowed' } else { 'denied' }
        Set-KubeResource $member @{apiVersion = 'batch/v1'; kind = 'Job'; metadata = @{name = $account; namespace = 'platform-identity'}
            spec = @{backoffLimit = 0; activeDeadlineSeconds = 240; template = @{
                metadata = @{labels = @{'azure.workload.identity/use' = 'true'}}
                spec = @{serviceAccountName = $account; automountServiceAccountToken = $false; restartPolicy = 'Never'
                    securityContext = @{runAsNonRoot = $true; runAsUser = 1654; seccompProfile = @{type = 'RuntimeDefault'}}
                    containers = @(@{name = 'probe'; image = $images.'sample-api'; args = @('identity-probe', $expected, $session.vaultUri)
                        securityContext = @{allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true; capabilities = @{drop = @('ALL')}}
                        resources = @{requests = @{cpu = '25m'; memory = '64Mi'}; limits = @{cpu = '250m'; memory = '128Mi'}}})
                }
            }}}
        Invoke-Kube $member @('wait', "job/$account", '-n', 'platform-identity', '--for=condition=Complete', '--timeout=260s') | Write-Host
        $log = Invoke-Kube $member @('logs', "job/$account", '-n', 'platform-identity')
        $message = if ($account -ceq 'bound') { 'Bound service account read and verified the sentinel.' } else { 'Unbound service account denied by federation.' }
        if ($log -cne $message) { throw "Unexpected identity probe result on $member." }
        $results["$member/$account"] = @{passed = $true; outcome = $message}
    }
}
@{commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD'); completedAt = [DateTime]::UtcNow.ToString('o'); probes = $results} |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $state 'identity-evidence.json')
Write-Host 'Workload identity passed on both members: bound account allowed; unbound account denied; sentinel value omitted.'
