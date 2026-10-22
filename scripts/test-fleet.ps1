#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$namespace = 'platform-foundation-test'
$name = 'foundation-test'
$api = 'placement.kubernetes-fleet.io/v1beta1'
$workAPI = 'works.v1beta1.placement.kubernetes-fleet.io'
$members = @('member-a', 'member-b')
$evidence = @{ startedAt = [DateTime]::UtcNow.ToString('o'); versions = $versions; members = @{}
    commit = Invoke-Tool git @('-C', $root, 'rev-parse', 'HEAD')
    workingTreeDirty = @(Invoke-Tool git @('-C', $root, 'status', '--porcelain')).Count -gt 0 }

function Get-Object([string]$Cluster, [string[]]$Arguments) {
    Invoke-Kube $Cluster (@('get') + $Arguments + @('-o', 'json')) | ConvertFrom-Json -AsHashtable
}

function Assert-NoWorkload([string]$Cluster) {
    $objects = Get-Object $Cluster @('deployments,pods', '-n', $namespace)
    if (@($objects.items).Count -ne 0) { throw "Unexpected application workload on $Cluster." }
}

function Approve-Stage([string]$Stage) {
    $currentRun = Get-Object hub @('clusterstagedupdaterun', $name)
    if ($currentRun.metadata.uid -cne $initialized.metadata.uid) { throw 'Update run was replaced.' }
    $stageStatus = @($currentRun.status.stagesStatus | Where-Object { $_.stageName -ceq $Stage })[0]
    $expectedName = $stageStatus.afterStageTaskStatus[0].approvalRequestName
    $script:approval = $null
    Wait-Until "approval for $Stage" {
        $requests = Get-Object hub @('clusterapprovalrequests')
        $matching = @($requests.items | Where-Object {
            $_.spec.parentStageRollout -ceq $name -and $_.spec.targetStage -ceq $Stage
        })
        if ($matching.Count -gt 1) { throw "Ambiguous approval for $Stage." }
        if ($matching.Count -eq 1) {
            if ($matching[0].metadata.name -cne $expectedName -or
                $matching[0].metadata.labels['kubernetes-fleet.io/isLatestUpdateRunApproval'] -cne 'true') {
                throw 'Approval does not match the initialized stage.'
            }
            $script:approval = $matching[0]; return $true
        }
        return $false
    }
    $patch = @{ metadata = @{ resourceVersion = $approval.metadata.resourceVersion }; status = @{ conditions = @(@{
        type = 'Approved'; status = 'True'; observedGeneration = $approval.metadata.generation
        lastTransitionTime = [DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
        reason = 'FoundationTest'; message = 'Foundation assertions passed.'
    }) } } | ConvertTo-Json -Depth 10 -Compress
    Invoke-Kube hub @('patch', 'clusterapprovalrequest', $approval.metadata.name,
        '--subresource=status', '--type=merge', '-p', $patch) | Write-Host
}

function Probe([string]$Member, [string]$IP) {
    Invoke-Kube $Member @('exec', '-n', $namespace, 'probe', '--', 'sh', '-c',
        'body=$(wget -T 2 -q -O- "$1" 2>/dev/null); if [ "$body" = foundation ]; then echo allowed; else echo denied; fi',
        'probe', "http://${IP}:8080/")
}

# Refuse to overwrite an earlier test or user work in these reserved names.
foreach ($cluster in @('hub') + $members) {
    if (Invoke-Kube $cluster @('get', 'namespace', $namespace, '--ignore-not-found', '-o', 'name')) {
        throw "Namespace $namespace already exists on $cluster."
    }
}
foreach ($resource in @('clusterresourceplacement', 'clusterstagedupdatestrategy', 'clusterstagedupdaterun')) {
    if (Invoke-Kube hub @('get', $resource, $name, '--ignore-not-found', '-o', 'name')) {
        throw "$resource/$name already exists."
    }
}
if (Invoke-Kube hub @('get', 'clusterapprovalrequests', '-l', "kubernetes-fleet.io/targetupdaterun=$name", '-o', 'name')) {
    throw 'Approval requests from an earlier test still exist.'
}

try {
    Set-KubeResource hub @{ apiVersion = 'v1'; kind = 'Namespace'; metadata = @{ name = $namespace } }
    $podSecurity = @{ runAsNonRoot = $true; runAsUser = 10000; fsGroup = 10000
        seccompProfile = @{ type = 'RuntimeDefault' } }
    $containerSecurity = @{ allowPrivilegeEscalation = $false; readOnlyRootFilesystem = $true
        capabilities = @{ drop = @('ALL') } }
    $deployment = @{
        apiVersion = 'apps/v1'; kind = 'Deployment'; metadata = @{ name = 'web'; namespace = $namespace }
        spec = @{ replicas = 1; selector = @{ matchLabels = @{ app = 'foundation' } }
            template = @{ metadata = @{ labels = @{ app = 'foundation' } }; spec = @{
                automountServiceAccountToken = $false; securityContext = $podSecurity
                volumes = @(@{ name = 'tmp'; emptyDir = @{} })
                containers = @(@{ name = 'web'; image = $versions.testImage; securityContext = $containerSecurity
                    command = @('sh', '-c', 'echo foundation > /tmp/index.html; exec httpd -f -p 8080 -h /tmp')
                    volumeMounts = @(@{ name = 'tmp'; mountPath = '/tmp' })
                    resources = @{ requests = @{ cpu = '10m'; memory = '16Mi' }; limits = @{ cpu = '100m'; memory = '32Mi' } }
                    readinessProbe = @{ httpGet = @{ path = '/'; port = 8080 }; periodSeconds = 2 }
                })
            } }
        }
    }
    Set-KubeResource hub @{
        apiVersion = $api; kind = 'ResourceEnvelope'; metadata = @{ name = 'web'; namespace = $namespace }
        data = @{
            deployment = $deployment
            deny = @{ apiVersion = 'networking.k8s.io/v1'; kind = 'NetworkPolicy'
                metadata = @{ name = 'default-deny'; namespace = $namespace }
                spec = @{ podSelector = @{}; policyTypes = @('Ingress', 'Egress') } }
            ingress = @{ apiVersion = 'networking.k8s.io/v1'; kind = 'NetworkPolicy'
                metadata = @{ name = 'allow-probe'; namespace = $namespace }
                spec = @{ podSelector = @{ matchLabels = @{ app = 'foundation' } }; policyTypes = @('Ingress')
                    ingress = @(@{ from = @(@{ podSelector = @{ matchLabels = @{ access = 'allowed' } } })
                        ports = @(@{ protocol = 'TCP'; port = 8080 }) }) } }
            egress = @{ apiVersion = 'networking.k8s.io/v1'; kind = 'NetworkPolicy'
                metadata = @{ name = 'allow-probe-egress'; namespace = $namespace }
                spec = @{ podSelector = @{ matchLabels = @{ role = 'probe' } }; policyTypes = @('Egress')
                    egress = @(@{ to = @(@{ podSelector = @{ matchLabels = @{ app = 'foundation' } } })
                        ports = @(@{ protocol = 'TCP'; port = 8080 }) }) } }
        }
    }
    Set-KubeResource hub @{
        apiVersion = $api; kind = 'ClusterResourcePlacement'; metadata = @{ name = $name }
        spec = @{ resourceSelectors = @(@{ group = ''; version = 'v1'; kind = 'Namespace'; name = $namespace })
            policy = @{ placementType = 'PickFixed'; clusterNames = $members }
            strategy = @{ type = 'External'; reportBackStrategy = @{ type = 'Mirror'; destination = 'WorkAPI' } } }
    }
    Set-KubeResource hub @{
        apiVersion = $api; kind = 'ClusterStagedUpdateStrategy'; metadata = @{ name = $name }
        spec = @{ stages = @(
            @{ name = 'regiona'; labelSelector = @{ matchLabels = @{ 'platform.example.com/region' = 'member-a' } }
                afterStageTasks = @(@{ type = 'Approval' }) },
            @{ name = 'regionb'; labelSelector = @{ matchLabels = @{ 'platform.example.com/region' = 'member-b' } }
                afterStageTasks = @(@{ type = 'Approval' }) }
        ) }
    }
    Set-KubeResource hub @{
        apiVersion = $api; kind = 'ClusterStagedUpdateRun'; metadata = @{ name = $name }
        spec = @{ placementName = $name; stagedRolloutStrategyName = $name; state = 'Initialize' }
    }
    Invoke-Kube hub @('wait', "clusterstagedupdaterun/$name", '--for=condition=Initialized', '--timeout=180s') | Write-Host
    $prepared = Get-Object hub @('clusterstagedupdaterun', $name)
    $snapshot = $prepared.status.resourceSnapshotIndexUsed
    $evidence.preparedRun = $prepared
    foreach ($cluster in @('hub') + $members) { Assert-NoWorkload $cluster }
    # An unspecified index creates a snapshot, but changing state reinitializes the run.
    # Recreate it with that immutable index so execution cannot select a newer bundle.
    Invoke-Kube hub @('delete', 'clusterstagedupdaterun', $name, '--timeout=60s') | Write-Host
    Set-KubeResource hub @{
        apiVersion = $api; kind = 'ClusterStagedUpdateRun'; metadata = @{ name = $name }
        spec = @{ placementName = $name; stagedRolloutStrategyName = $name
            resourceSnapshotIndex = $snapshot; state = 'Initialize' }
    }
    Invoke-Kube hub @('wait', "clusterstagedupdaterun/$name", '--for=condition=Initialized', '--timeout=180s') | Write-Host
    $initialized = Get-Object hub @('clusterstagedupdaterun', $name)
    $targets = @($initialized.status.stagesStatus | ForEach-Object { $_.clusters.clusterName })
    if (($targets -join ',') -cne ($members -join ',') -or $snapshot -notmatch '^\d+$' -or
        $initialized.spec.resourceSnapshotIndex -cne $snapshot -or $initialized.status.resourceSnapshotIndexUsed -cne $snapshot) {
        throw 'Initialization did not resolve the expected snapshot and ordered members.'
    }
    $evidence.initializedRun = $initialized
    foreach ($cluster in @('hub') + $members) { Assert-NoWorkload $cluster }
    Start-Sleep -Seconds 10
    foreach ($cluster in @('hub') + $members) { Assert-NoWorkload $cluster }
    Write-Host 'Initialize created no application Deployments or pods.'

    # A later source edit must not change the bundle selected for this run.
    Invoke-Kube hub @('patch', 'resourceenvelopes.v1beta1.placement.kubernetes-fleet.io', 'web', '-n', $namespace,
        '--type=merge', '-p', '{"data":{"deployment":{"spec":{"template":{"metadata":{"annotations":{"platform.example.com/source-edit":"newer"}}}}}}}') | Write-Host
    Invoke-Kube hub @('patch', 'clusterstagedupdaterun', $name, '--type=merge', '-p', '{"spec":{"state":"Run"}}') | Write-Host
    foreach ($member in $members) {
        Invoke-Kube $member @('wait', '-n', $namespace, 'deployment/web', '--for=create', '--timeout=180s') | Write-Host
        Invoke-Kube $member @('rollout', 'status', '-n', $namespace, 'deployment/web', '--timeout=180s') | Write-Host
        $deployed = Get-Object $member @('deployment', 'web', '-n', $namespace)
        if ($deployed.spec.template.spec.containers[0].image -cne $versions.testImage) { throw 'Unexpected workload image.' }
        if ($deployed.spec.template.metadata.ContainsKey('annotations') -and
            $deployed.spec.template.metadata.annotations.ContainsKey('platform.example.com/source-edit')) {
            throw 'The run deployed the newer source instead of its pinned snapshot.'
        }
        Assert-NoWorkload hub
        if ($member -ceq 'member-a') { Assert-NoWorkload member-b }

        # Fleet 0.3.1 does not forward the placement's reportBackStrategy to generated Works.
        # Configure only this placement's Works through the beta API, which exposes mirroring.
        $workArguments = @($workAPI, '-n', "fleet-member-$member", '-l', "kubernetes-fleet.io/parent-CRP=$name")
        $works = Get-Object hub $workArguments
        if (@($works.items).Count -lt 2) { throw 'Expected namespace and envelope Works.' }
        foreach ($work in $works.items) {
            if ($work.metadata.labels['kubernetes-fleet.io/parent-resource-snapshot-index'] -cne $initialized.status.resourceSnapshotIndexUsed) {
                throw 'Work belongs to a different resource snapshot.'
            }
            Invoke-Kube hub @('patch', $workAPI, $work.metadata.name, '-n', "fleet-member-$member", '--type=merge',
                '-p', '{"spec":{"reportBackStrategy":{"type":"Mirror","destination":"WorkAPI"}}}') | Write-Host
        }
        $script:mirrored = $null
        Wait-Until "mirrored Deployment status from $member" {
            $works = Get-Object hub $workArguments
            foreach ($work in $works.items) {
                if (-not $work.ContainsKey('status') -or -not $work.status.ContainsKey('manifestConditions')) { continue }
                foreach ($manifest in $work.status.manifestConditions) {
                    if ($manifest.identifier.kind -cne 'Deployment' -or $manifest.identifier.name -cne 'web' -or
                        $manifest.identifier.namespace -cne $namespace -or -not $manifest.ContainsKey('backReportedStatus')) { continue }
                    $report = $manifest.backReportedStatus
                    if ($report.observedStatus.status['availableReplicas'] -eq 1 -and
                        $report.observedStatus.status['observedGeneration'] -eq $deployed.metadata.generation -and
                        [DateTimeOffset]::Parse($report.observationTime).UtcDateTime -gt [DateTime]::UtcNow.AddSeconds(-30)) {
                        $script:mirrored = @{ workName = $work.metadata.name; workUID = $work.metadata.uid
                            workGeneration = $work.metadata.generation; manifest = $manifest }
                        return $true
                    }
                }
            }
            return $false
        }

        $pods = Get-Object $member @('pods', '-n', $namespace, '-l', 'app=foundation')
        $ip = $pods.items[0].status.podIP
        Set-KubeResource $member @{
            apiVersion = 'v1'; kind = 'Pod'; metadata = @{ name = 'probe'; namespace = $namespace
                labels = @{ role = 'probe'; access = 'allowed' } }
            spec = @{ automountServiceAccountToken = $false; securityContext = $podSecurity
                containers = @(@{ name = 'probe'; image = $versions.testImage; command = @('sleep', '3600')
                    securityContext = $containerSecurity
                    resources = @{ requests = @{ cpu = '10m'; memory = '16Mi' }; limits = @{ cpu = '100m'; memory = '32Mi' } } }) }
        }
        Invoke-Kube $member @('wait', '-n', $namespace, 'pod/probe', '--for=condition=Ready', '--timeout=120s') | Write-Host
        Wait-Until "allowed traffic on $member" { (Probe $member $ip) -ceq 'allowed' } 30
        Invoke-Kube $member @('label', '-n', $namespace, 'pod/probe', 'access=denied', '--overwrite') | Out-Null
        Wait-Until "denied traffic on $member" { (Probe $member $ip) -ceq 'denied' } 30
        Invoke-Kube $member @('label', '-n', $namespace, 'pod/probe', 'access=allowed', '--overwrite') | Out-Null
        Wait-Until "restored traffic on $member" { (Probe $member $ip) -ceq 'allowed' } 30
        $evidence.members[$member] = @{ deployment = Get-Object $member @('deployment', 'web', '-n', $namespace)
            mirroredStatus = $mirrored; networkPolicy = @('allowed', 'denied', 'allowed') }
        Write-Host "$member passed: mirrored status and allowed/denied/restored network traffic."
        if ($member -ceq 'member-a') { Assert-NoWorkload member-b }
        Approve-Stage $(if ($member -ceq 'member-a') { 'regiona' } else { 'regionb' })
    }
    Invoke-Kube hub @('wait', "clusterstagedupdaterun/$name", '--for=condition=Succeeded', '--timeout=180s') | Write-Host
    $evidence.completedRun = Get-Object hub @('clusterstagedupdaterun', $name)
    if ($evidence.completedRun.status.resourceSnapshotIndexUsed -cne $snapshot) { throw 'The completed run changed snapshots.' }
    $evidence.completedAt = [DateTime]::UtcNow.ToString('o')
    $evidence | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath (Join-Path $state 'foundation-evidence.json')
    Write-Host 'Fleet foundation passed. Evidence: .local/foundation-evidence.json'
} finally {
    Invoke-Kube hub @('delete', 'clusterstagedupdaterun', $name, '--ignore-not-found', '--timeout=60s') | Write-Host
    Invoke-Kube hub @('delete', 'clusterresourceplacement', $name, '--ignore-not-found', '--timeout=120s') | Write-Host
    Invoke-Kube hub @('delete', 'clusterstagedupdatestrategy', $name, '--ignore-not-found', '--timeout=60s') | Write-Host
    foreach ($cluster in @('hub') + $members) {
        Invoke-Kube $cluster @('delete', 'namespace', $namespace, '--ignore-not-found', '--timeout=120s') | Write-Host
    }
}
