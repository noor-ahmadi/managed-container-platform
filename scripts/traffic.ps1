#requires -Version 7.0
param([ValidateSet('up', 'down')][string]$Action = 'up', [string]$ServiceName)
. (Join-Path $PSScriptRoot 'common.ps1')
$name = 'managed-platform-edge'
$recordFile = Join-Path $state 'edge.json'
$configDirectory = Join-Path $state 'traffic'
$members = @('member-a', 'member-b')
$record = if (Test-Path -LiteralPath $recordFile) { Get-Content $recordFile -Raw | ConvertFrom-Json -AsHashtable } else { $null }
$id = Invoke-Tool docker @('ps', '-aq', '--filter', "name=^/$name`$")
function Save-Route { $record | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $recordFile }
function Get-RouteResource([string]$Member, [string]$Kind, [string]$ResourceName) {
    $raw = Invoke-Kube $Member @('get', "$Kind/$ResourceName", '-n', $record.sourceNamespace, '--ignore-not-found', '-o', 'json')
    if ($raw) { $raw | ConvertFrom-Json -AsHashtable }
}
function Wait-Route {
    Wait-Until 'route returns the verified workload' {
        try {
            $response = Invoke-WebRequest $record.url -TimeoutSec 2
            $body = $response.Content | ConvertFrom-Json
            $response.StatusCode -eq 200 -and [string]$response.Headers['X-Platform-Member'] -cin $members -and
                $body.service -ceq $record.serviceName -and $body.release -ceq $record.release
        } catch { return $false }
    } 60
}
if ($record -and ($record.name -cne $name -or $record.runId -cnotmatch '^[a-f0-9]{32}$' -or
    $record.sourceNamespace -cnotmatch '^workload-[a-f0-9]{16}$' -or $record.image -cnotmatch '^haproxy:[0-9.]+-alpine@sha256:[a-f0-9]{64}$')) {
    throw 'Invalid local route ownership record.'
}
if ($id) {
    $container = Get-DockerContainer $id
    if (-not $record -or ($record['id'] -and $record.id -cne $container.Id) -or
        $container.Config.Image -cne $record.image -or $container.Config.Labels['platform.project'] -cne 'managed-container-platform' -or
        $container.Config.Labels['platform.edge.run'] -cne $record.runId) { throw 'Refusing an unowned or mismatched local route.' }
    $id = $container.Id
}
if ($Action -ceq 'down') {
    if (-not $record) { return }
    $existing = @(Invoke-Tool kind @('get', 'clusters'))
    $owned = @(Get-Content (Join-Path $state 'clusters.json') -Raw | ConvertFrom-Json)
    $remove = @()
    # Validate every identity before deleting anything, including the proxy.
    foreach ($member in $members) {
        $cluster = "managed-platform-$member"
        if ($cluster -cnotin $existing) { continue }
        if ($cluster -cnotin $owned) { throw 'Refusing route cleanup on an unowned cluster.' }
        foreach ($resource in @(@('service', 'application-edge', 'serviceUID'), @('networkpolicy', 'allow-edge-proxy', 'policyUID'))) {
            $actual = Get-RouteResource $member $resource[0] $resource[1]
            if (-not $actual) { continue }
            $expectedUID = $record.backends[$member][$resource[2]]
            if ($actual.metadata.labels['platform.example.com/edge-run'] -cne $record.runId -or
                ($expectedUID -and $actual.metadata.uid -cne $expectedUID)) { throw 'Refusing an unowned route resource.' }
            $remove += @{member = $member; kind = $resource[0]; name = $resource[1]}
        }
    }
    if ($id) { Invoke-Tool docker @('rm', '--force', $id) | Out-Null }
    foreach ($resource in $remove) {
        Invoke-Kube $resource.member @('delete', "$($resource.kind)/$($resource.name)", '-n', $record.sourceNamespace, '--wait=true', '--timeout=60s') | Out-Null
    }
    Remove-Item -LiteralPath $recordFile
    Write-Host 'Local route and its member resources are removed.'
    return
}
if (-not $ServiceName -or $ServiceName -cnotmatch '^[a-z][a-z0-9-]{0,39}$') { throw 'Pass -ServiceName with a service in tenant-demo.' }
$service = Invoke-Kube hub @('get', 'servicedefinition', $ServiceName, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
if ($service.status['activeRelease']) { throw 'Wait for the active release before creating a route.' }
$baseline = Invoke-Kube hub @('get', 'release', $service.status.lastSuccessfulRelease, '-n', 'tenant-demo', '-o', 'json') | ConvertFrom-Json -AsHashtable
if ($baseline.status.phase -cne 'Succeeded' -or $baseline.spec.serviceUID -cne $service.metadata.uid -or
    $baseline.status.gatePolicy -cnotin @('http-health-v1', 'http-health-scaled-v1')) { throw 'Route requires a health-verified baseline for this service.' }
if ($record) {
    if (-not $id -or -not $record['url'] -or $record.serviceUID -cne $service.metadata.uid -or
        $record.release -cne $baseline.status.releaseName -or $record.sourceNamespace -cne $baseline.status.sourceNamespace -or
        $record.applicationImage -cne $baseline.spec.image -or -not $container.State.Running) { throw 'Remove the existing route before changing or repairing it.' }
    $binding = $container.NetworkSettings.Ports['8080/tcp'][0]
    $configFile = Join-Path $configDirectory "$($record.runId).cfg"
    if ($binding.HostIp -cne '127.0.0.1' -or $record.url -cne "http://127.0.0.1:$($binding.HostPort)/" -or
        $record.proxyAddress -cne $container.NetworkSettings.Networks.kind.IPAddress -or
        (Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $record.configSha256) { throw 'Existing route configuration changed.' }
    Wait-Route
    Write-Host "Local route is ready: $($record.url)"
    return
}
$source = $baseline.status.sourceNamespace
$owned = @(Get-Content (Join-Path $state 'clusters.json') -Raw | ConvertFrom-Json)
$backends = @{}
foreach ($member in $members) {
    if ("managed-platform-$member" -cnotin $owned) { throw 'Route requires both owned local members.' }
    $node = Get-DockerContainer "managed-platform-$member-control-plane"
    if ($node.Config.Labels['io.x-k8s.kind.cluster'] -cne "managed-platform-$member" -or -not $node.State.Running -or $node.State.Paused) { throw 'Member node identity or state changed.' }
    $address = [Net.IPAddress]::Parse($node.NetworkSettings.Networks.kind.IPAddress)
    if ($address.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Local route requires IPv4 member addresses.' }
    foreach ($resource in @('service/application-edge', 'networkpolicy/allow-edge-proxy')) {
        if (Invoke-Kube $member @('get', $resource, '-n', $source, '--ignore-not-found', '-o', 'name')) { throw 'Refusing to replace an existing member route resource.' }
    }
    $application = Invoke-Kube $member @('get', 'deployment/application', '-n', $source, '-o', 'json') | ConvertFrom-Json -AsHashtable
    if ($application.spec.template.spec.containers[0].image -cne $baseline.spec.image -or
        $application.spec.template.metadata.labels['platform.example.com/release'] -cne $baseline.status.releaseName) { throw 'Member does not match the routing baseline.' }
    $backends[$member] = @{nodeID = $node.Id; address = $address.ToString(); selector = $application.spec.selector.matchLabels
        nodePort = 0; serviceUID = ''; policyUID = ''}
}
New-Item -ItemType Directory -Path $configDirectory -Force | Out-Null
$record = @{name = $name; id = ''; runId = [Guid]::NewGuid().ToString('N'); image = $versions.edgeImage
    serviceName = $ServiceName; serviceUID = $service.metadata.uid; sourceNamespace = $source
    release = $baseline.status.releaseName; applicationImage = $baseline.spec.image; port = $baseline.status.resolvedService.port; backends = $backends}
Save-Route
foreach ($member in $members) {
    Set-KubeResource $member @{apiVersion = 'v1'; kind = 'Service'; metadata = @{name = 'application-edge'; namespace = $source
        labels = @{'platform.example.com/edge-run' = $record.runId}}
        spec = @{type = 'NodePort'; externalTrafficPolicy = 'Local'; selector = $backends[$member].selector
            ports = @(@{port = $record.port; targetPort = $record.port; protocol = 'TCP'})}}
    $actual = Get-RouteResource $member 'service' 'application-edge'
    $backends[$member].serviceUID = $actual.metadata.uid
    $backends[$member].nodePort = [int]$actual.spec.ports[0].nodePort
    if ($backends[$member].nodePort -lt 30000 -or $backends[$member].nodePort -gt 32767) { throw 'Unexpected local NodePort.' }
    Save-Route
}
$config = @(
    'global', '  maxconn 64', '  log stdout format raw local0',
    'defaults', '  mode http', '  log global', '  option httplog', '  timeout connect 500ms',
    '  timeout client 2s', '  timeout server 1s', '  timeout check 500ms', '  retries 0',
    'frontend ingress', '  bind :8080', '  default_backend members',
    'backend members', '  option httpchk', '  http-check send meth GET uri / ver HTTP/1.1 hdr Host application',
    '  http-check expect status 200', '  http-response set-header X-Platform-Member %[srv_name]',
    '  default-server inter 1s fall 3 rise 2',
    "  server member-a $($backends['member-a'].address):$($backends['member-a'].nodePort) check",
    "  server member-b $($backends['member-b'].address):$($backends['member-b'].nodePort) check backup"
) -join "`n"
$config += "`n"
$configFile = Join-Path $configDirectory "$($record.runId).cfg"
Set-Content -LiteralPath $configFile -Value $config -NoNewline
$record.configSha256 = (Get-FileHash -LiteralPath $configFile -Algorithm SHA256).Hash.ToLowerInvariant()
Save-Route
$record.id = Invoke-Tool docker @('run', '-d', '--name', $name, '--label', 'platform.project=managed-container-platform',
    '--label', "platform.edge.run=$($record.runId)", '--network', 'kind', '--publish', '127.0.0.1::8080',
    '--user', 'haproxy', '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges:true', '--read-only',
    '--memory', '128m', '--cpus', '0.5', '--pids-limit', '64',
    '--mount', "type=bind,source=$configFile,target=/usr/local/etc/haproxy/haproxy.cfg,readonly",
    $record.image, 'haproxy', '-W', '-db', '-f', '/usr/local/etc/haproxy/haproxy.cfg')
Save-Route
$container = Get-DockerContainer $record.id
$proxyAddress = [Net.IPAddress]::Parse($container.NetworkSettings.Networks.kind.IPAddress)
if ($proxyAddress.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'Proxy requires an IPv4 address.' }
foreach ($member in $members) {
    Set-KubeResource $member @{apiVersion = 'networking.k8s.io/v1'; kind = 'NetworkPolicy'; metadata = @{name = 'allow-edge-proxy'; namespace = $source
        labels = @{'platform.example.com/edge-run' = $record.runId}}
        spec = @{podSelector = @{matchLabels = $backends[$member].selector}; policyTypes = @('Ingress')
            ingress = @(@{from = @(@{ipBlock = @{cidr = "$proxyAddress/32"}}); ports = @(@{protocol = 'TCP'; port = $record.port})})}}
    $backends[$member].policyUID = (Get-RouteResource $member 'networkpolicy' 'allow-edge-proxy').metadata.uid
    Save-Route
}
$binding = $container.NetworkSettings.Ports['8080/tcp'][0]
if ($binding.HostIp -cne '127.0.0.1') { throw 'Local proxy must bind only to loopback.' }
$record.url = "http://127.0.0.1:$($binding.HostPort)/"
$record.proxyAddress = $proxyAddress.ToString()
Save-Route
Wait-Route
Write-Host "Local route is ready: $($record.url)"
