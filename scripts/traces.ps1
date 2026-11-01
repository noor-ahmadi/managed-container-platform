#requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateSet('member-a', 'member-b')][string]$Member,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{32}$')][string]$TraceId,
    [ValidateSet('local', 'azure')][string]$Target = 'local'
)
. (Join-Path $PSScriptRoot 'common.ps1') -Target $Target
Invoke-Kube $Member @('get', '--raw', "/api/v1/namespaces/platform-observers/services/http:jaeger:16686/proxy/api/v3/traces/$TraceId")
