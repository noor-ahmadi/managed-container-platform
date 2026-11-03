#requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$images = Get-Content (Join-Path $state 'images.json') -Raw | ConvertFrom-Json -AsHashtable
$image = $images['sample-api']
$repository = ($image -split '@')[0]
$id = [guid]::NewGuid().ToString('N').Substring(0,8)
$serviceName = "portal-$id"
$otherNamespace = "other-portal-$id"
$servers = [Collections.Generic.List[object]]::new()
$invalidConfig = Join-Path $state 'portal-invalid-kubeconfig'
$otherUID = $null
$handler = [Net.Http.HttpClientHandler]::new()
$handler.AllowAutoRedirect = $false
$http = [Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(15)
function Assert($Condition,[string]$Message) { if (-not $Condition) { throw $Message } }
function Start-Portal([string]$Config) {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,0)
    $listener.Start(); $port = $listener.LocalEndpoint.Port; $listener.Stop()
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Command dotnet -CommandType Application | Select-Object -First 1).Source)
    $info.WorkingDirectory = Join-Path $root 'src/Portal'
    $info.UseShellExecute = $false; $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    foreach ($arg in @((Join-Path $root 'src/Portal/bin/Debug/net10.0/Portal.dll'), '--kubeconfig',$Config,'--context','tenant-demo','--namespace','tenant-demo','--port',"$port")) { $info.ArgumentList.Add($arg) }
    $process = [Diagnostics.Process]::Start($info)
    $server = @{process=$process;port=$port;url="http://127.0.0.1:$port";stdout=$process.StandardOutput.ReadToEndAsync();stderr=$process.StandardError.ReadToEndAsync()}
    $servers.Add($server)
    Wait-Until 'local portal ready' {
        if ($process.HasExited) { throw 'Portal exited during startup.' }
        try { $response=$http.GetAsync($server.url+'/healthz').GetAwaiter().GetResult(); $ready=[int]$response.StatusCode -eq 200; $response.Dispose(); return $ready } catch { return $false }
    } 30
    $bound = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() | Where-Object Port -eq $port)
    Assert ($bound.Count -eq 1 -and [Net.IPAddress]::IsLoopback($bound[0].Address)) 'Portal opened a non-loopback listener.'
    $server
}
function Request([string]$Method,[string]$Url,$Fields=$null,[string]$Origin='') {
    $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::new($Method),$Url)
    try {
        if ($Fields) { $values=[Collections.Generic.Dictionary[string,string]]::new(); foreach($key in $Fields.Keys){$values[$key]=[string]$Fields[$key]}; $request.Content=[Net.Http.FormUrlEncodedContent]::new($values) }
        if ($Origin) { $request.Headers.Add('Origin',$Origin) }
        $response=$http.SendAsync($request).GetAwaiter().GetResult()
        try {
            $location=''
            if($response.Headers.Location){$redirect=[Uri]::new([Uri]$Url,$response.Headers.Location);Assert ($redirect.Authority -ceq ([Uri]$Url).Authority) 'Portal redirected outside its origin.';$location=$redirect.PathAndQuery}
            @{status=[int]$response.StatusCode;body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();location=$location;cache=[string]$response.Headers.CacheControl;contentType=[string]$response.Content.Headers.ContentType;disposition=[string]$response.Content.Headers.ContentDisposition}
        }
        finally { $response.Dispose() }
    } finally { $request.Dispose() }
}
function Form([string]$Url,[string]$Name) {
    $page = Request GET $Url
    Assert ($page.status -eq 200) 'Cannot read portal form.'
    foreach($match in [regex]::Matches($page.body,'(?s)<form\b.*?</form>')) {
        $fields=@{}
        foreach($input in [regex]::Matches($match.Value,'<input\b[^>]*>')) {
            $nameMatch=[regex]::Match($input.Value,'\bname="([^"]+)"'); $valueMatch=[regex]::Match($input.Value,'\bvalue="([^"]*)"')
            if($input.Value -match '\btype="hidden"' -and $nameMatch.Success){$fields[[Net.WebUtility]::HtmlDecode($nameMatch.Groups[1].Value)]=[Net.WebUtility]::HtmlDecode($valueMatch.Groups[1].Value)}
        }
        if($fields['_handler'] -ceq $Name){Assert ($fields.ContainsKey('__RequestVerificationToken')) 'Form lacks antiforgery protection.';return $fields}
    }
    throw "Portal form $Name was not found."
}
function Read-Release([string]$Name) {
    $response=Request GET ($base+"/api/releases/$Name/evidence")
    Assert ($response.status -eq 200 -and $response.contentType -like 'application/json*' -and $response.disposition -like '*attachment*') 'Evidence export failed.'
    $response.body|ConvertFrom-Json -AsHashtable
}
function Wait-Succeeded([string]$Name) {
    $script:completed = $null
    Wait-Until "portal release $Name succeeds" {
        $current=Read-Release $Name
        if($current['status'] -and $current.status['failure']){throw $current.status.failure}
        if($current['status'] -and $current.status['phase'] -ceq 'Succeeded'){$script:completed=$current;return $true}
        return $false
    } 720
    foreach($gate in $completed.status.gates.Values){Assert ($gate.health.decision -ceq 'Passed' -and $gate.health.values.requests -ge 500 -and $gate.health.values.errorRate -lt .01 -and $gate.health.values.p95Seconds -lt .5 -and ([DateTimeOffset]$gate.approvedAt-[DateTimeOffset]$gate.startedAt).TotalSeconds -ge 120) 'Portal release bypassed application gates.'}
    Wait-Until 'portal service publication completes' {
        $current=Invoke-Kube hub @('get','servicedefinition',$serviceName,'-n','tenant-demo','-o','json')|ConvertFrom-Json -AsHashtable
        $current.status['activeRelease'] -ceq '' -and $current.status['lastSuccessfulRelease'] -ceq $Name
    } 30
    $completed
}
try {
    $server = Start-Portal (Join-Path $state 'tenant-kubeconfig')
    $base = $server.url
    $catalog=Request GET ($base+'/')
    Assert ($catalog.status -eq 200 -and $catalog.body.Contains('Services') -and $catalog.cache.Contains('no-store')) 'Portal catalogue did not load safely.'
    $hostRequest=[Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get,$base+'/')
    $hostRequest.Headers.Host='foreign.invalid'
    $hostResponse=$null
    try { $hostResponse=$http.SendAsync($hostRequest).GetAwaiter().GetResult(); Assert ([int]$hostResponse.StatusCode -eq 400) 'Portal accepted a foreign Host header.' }
    finally { if($hostResponse){$hostResponse.Dispose()}; $hostRequest.Dispose() }
    $noToken=Request POST ($base+'/new-service') @{_handler='service';'Input.Name'=$serviceName}
    Assert ($noToken.status -eq 400) 'Portal accepted a form without an antiforgery token.'
    $fields=Form ($base+'/new-service') service
    $fields['Input.Name']=$serviceName; $fields['Input.Repository']=$repository; $fields['Input.Port']='8080';$fields['Input.ReadinessPath']='/healthz';$fields['Input.ScalingProfile']='fixed';$fields['Input.Namespace']=$otherNamespace
    $foreign=Request POST ($base+'/new-service') $fields 'https://foreign.invalid'
    Assert ($foreign.status -eq 403) 'Portal accepted a foreign-origin form.'
    $created=Request POST ($base+'/new-service') $fields $base
    Assert ($created.status -in @(302,303) -and $created.location -ceq "/services/$serviceName") "Portal service creation failed: HTTP $($created.status), location $($created.location)."
    $service=Invoke-Kube hub @('get','servicedefinition',$serviceName,'-n','tenant-demo','-o','json')|ConvertFrom-Json -AsHashtable
    Assert ($service.metadata.namespace -ceq 'tenant-demo' -and $service.spec.imageRepository -ceq $repository) 'Browser changed the portal tenant scope.'
    $originalGeneration=$service.metadata.generation
    foreach($profile in @('http-requests','fixed')) {
        $fields=Form ($base+"/services/$serviceName/edit") service
        $fields['Input.Name']='ignored-rename';$fields['Input.Repository']=$repository;$fields['Input.Port']='8080';$fields['Input.ReadinessPath']='/healthz';$fields['Input.ScalingProfile']=$profile
        $saved=Request POST ($base+"/services/$serviceName/edit") $fields $base
        Assert ($saved.status -in @(302,303) -and $saved.location -ceq "/services/$serviceName") 'Portal settings did not save.'
        $current=Invoke-Kube hub @('get','servicedefinition',$serviceName,'-n','tenant-demo','-o','json')|ConvertFrom-Json -AsHashtable
        Assert ($current.metadata.uid -ceq $service.metadata.uid -and $current.spec.scalingProfile -ceq $profile -and $current.metadata.generation -gt $service.metadata.generation) 'Portal settings changed identity or failed to update the definition.'
        if($profile -ceq 'http-requests'){$updatedService=$current}
        $service=$current
    }
    Set-KubeResource hub @{apiVersion='v1';kind='Namespace';metadata=@{name=$otherNamespace;labels=@{'platform.example.com/test'=$id}}}
    $otherUID=(Invoke-Kube hub @('get','namespace',$otherNamespace,'-o','json')|ConvertFrom-Json -AsHashtable).metadata.uid
    Set-KubeResource hub @{apiVersion='platform.example.com/v1alpha1';kind='ServiceDefinition';metadata=@{name='hidden-service';namespace=$otherNamespace};spec=$service.spec}
    $scoped=Request GET ($base+'/api/services?namespace='+$otherNamespace)
    $listed=$scoped.body|ConvertFrom-Json -AsHashtable
    Assert ($scoped.status -eq 200 -and @($listed|Where-Object { $_.metadata.namespace -cne 'tenant-demo' }).Count -eq 0 -and @($listed|Where-Object { $_.metadata.name -ceq 'hidden-service' }).Count -eq 0) 'Portal exposed another tenant.'
    $hidden=Request GET ($base+'/services/hidden-service?namespace='+$otherNamespace)
    Assert ($hidden.status -eq 200 -and $hidden.body.Contains('Service was not found.')) 'Portal read a cross-tenant service.'
    $fields=Form ($base+"/services/$serviceName") release
    $fields['Input.Image']=$repository+':latest'
    $invalid=Request POST ($base+"/services/$serviceName") $fields $base
    Assert ($invalid.status -eq 200 -and $invalid.body.Contains('sha256 digest')) 'Portal did not reject a mutable image.'
    $before=Invoke-Kube hub @('get','releases','-n','tenant-demo','-o','json')|ConvertFrom-Json -AsHashtable
    Assert (@($before.items|Where-Object { $_.spec.serviceUID -ceq $service.metadata.uid }).Count -eq 0) 'Invalid image created a release request.'
    $fields=Form ($base+"/services/$serviceName") release
    $fields['Input.Image']=$image
    $requested=Request POST ($base+"/services/$serviceName") $fields $base
    Assert ($requested.status -in @(302,303) -and $requested.location -cmatch '^/releases/[a-z0-9-]+$') 'Portal did not create the release.'
    $releaseName=($requested.location -split '/')[-1]
    $pending=Request GET ($base+$requested.location)
    Assert ($pending.body.Contains('member-a') -and $pending.body.Contains('member-b') -and $pending.body.Contains('http-equiv="refresh"')) 'Portal did not show live member rollout status.'
    $deployed=Wait-Succeeded $releaseName
    $success=Request GET ($base+"/releases/$releaseName")
    Assert ($success.status -eq 200 -and $success.body.Contains('Both members passed') -and -not $success.body.Contains('http-equiv="refresh"')) 'Portal did not show the terminal published state.'
    $actual=Invoke-Kube hub @('get','release',$releaseName,'-n','tenant-demo','-o','json')|ConvertFrom-Json -AsHashtable
    Assert ($actual.metadata.uid -ceq $deployed.metadata.uid -and $deployed.spec.serviceUID -ceq $service.metadata.uid -and $deployed.spec.image -ceq $image) 'Evidence export returned a different release.'
    $fields=Form ($base+"/services/$serviceName") rollback
    $unchecked=Request POST ($base+"/services/$serviceName") $fields $base
    Assert ($unchecked.status -eq 200 -and $unchecked.body.Contains('Confirm that you want')) 'Rollback did not require confirmation.'
    $fields=Form ($base+"/services/$serviceName") rollback
    $fields['RollbackInput.Confirm']='true'
    $rollbackRequest=Request POST ($base+"/services/$serviceName") $fields $base
    Assert ($rollbackRequest.status -in @(302,303)) 'Portal rollback request failed.'
    $rollbackName=($rollbackRequest.location -split '/')[-1]
    $rollback=Wait-Succeeded $rollbackName
    Assert ($rollback.spec.restoreRelease -ceq $releaseName -and $rollback.status.bundleSha256 -ceq $deployed.status.bundleSha256 -and $rollback.status.releaseName -ceq $deployed.status.releaseName) 'Portal rollback did not restore the retained bundle.'
    $expired=Get-Content (Join-Path $state 'tenant-kubeconfig') -Raw|ConvertFrom-Json -AsHashtable
    $expired.users[0].user.token='portal-expired-test'
    $expired|ConvertTo-Json -Depth 15|Set-Content -LiteralPath $invalidConfig
    $expired=$null
    $invalidServer=Start-Portal $invalidConfig
    $denied=Request GET ($invalidServer.url+'/api/services')
    $expiredPage=Request GET ($invalidServer.url+'/')
    Assert ($denied.status -eq 401 -and $expiredPage.status -eq 200 -and $expiredPage.body.Contains('Tenant credentials expired') -and -not $expiredPage.body.Contains('portal-expired-test')) 'Portal credential failure leaked data or lacked a recovery message.'
    $result=@{commit=Invoke-Tool git @('-C',$root,'rev-parse','HEAD');workingTreeDirty=@(Invoke-Tool git @('-C',$root,'status','--porcelain')).Count -gt 0
        completedAt=[DateTimeOffset]::UtcNow.ToString('o');scope='Loopback-only tenant portal using shared CLI contracts and real Kubernetes requests';versions=$versions
        service=$service;settingsUpdate=@{originalGeneration=$originalGeneration;updated=$updatedService};deployed=$deployed;rollback=$rollback;portalNamespace='tenant-demo';otherTenantProbe=@{namespace=$otherNamespace;uid=$otherUID;name='hidden-service'}
        listedNamespaces=@($listed|ForEach-Object{$_.metadata.namespace}|Sort-Object -Unique);loopbackOnly=$true;hostHeaderDenied=$true;antiforgeryDenied=$true;foreignOriginDenied=$true
        browserNamespaceIgnored=$true;serviceSettingsUpdated=$true;crossTenantReadDenied=$true;mutableImageDenied=$true;rollbackConfirmationRequired=$true;expiredCredentialsHandled=$true;rawEvidenceMatchesRelease=$true;pendingAndTerminalViewsPassed=$true}
} finally {
    foreach($server in $servers){if(-not $server.process.HasExited){$server.process.Kill($true);Assert ($server.process.WaitForExit(10000)) 'Portal process did not stop.'};$server.stdout.GetAwaiter().GetResult()|Set-Content -LiteralPath (Join-Path $state "portal-$($server.port)-stdout.log");$server.stderr.GetAwaiter().GetResult()|Set-Content -LiteralPath (Join-Path $state "portal-$($server.port)-stderr.log")}
    $http.Dispose();$handler.Dispose()
    if(Test-Path -LiteralPath $invalidConfig){Remove-Item -LiteralPath $invalidConfig}
    if($otherUID){$actual=Invoke-Kube hub @('get','namespace',$otherNamespace,'-o','json')|ConvertFrom-Json -AsHashtable;Assert ($actual.metadata.uid -ceq $otherUID) 'Refusing to delete a replaced test namespace.';Invoke-Kube hub @('delete','namespace',$otherNamespace,'--wait=true','--timeout=60s')|Write-Host}
}
$result.serverProcessesStopped=$true;$result.temporaryCredentialRemoved=$true
$result|ConvertTo-Json -Depth 90|Set-Content -LiteralPath (Join-Path $state 'portal-evidence.json')
Write-Host 'Portal passed: tenant forms, measured release and rollback, evidence export, CSRF/origin checks, namespace boundaries, expired credentials, and server cleanup.'
