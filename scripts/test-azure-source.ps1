#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = Split-Path $PSScriptRoot -Parent
$scratch = Join-Path $root '.local/azure-source-check'
New-Item -ItemType Directory -Path $scratch -Force | Out-Null
foreach ($file in Get-ChildItem $PSScriptRoot -Filter '*.ps1') {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count) { throw ($errors | Out-String) }
}
az bicep build --file (Join-Path $root 'azure/main.bicep') --outfile (Join-Path $scratch 'main.json')
if ($LASTEXITCODE -ne 0) { throw 'Azure template compilation failed.' }
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'azure.ps1'), [ref]$tokens, [ref]$errors)
$cleanup = $ast.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Remove-Demo'}, $true)
if (-not $cleanup) { throw 'Azure cleanup entry point is missing.' }
# Exercise the real cleanup function with an in-memory Azure boundary; never contact a subscription.
& {
    $state = $scratch
    $sessionFile = Join-Path $state 'session.json'
    $kubeconfig = Join-Path $state 'kubeconfig'
    $runId = '0123456789abcdef0123456789abcdef'
    $testGroup = 'rg-managed-platform-0123456789'
    $subscription = '00000000-0000-0000-0000-000000000001'
    $script:deletions = 0
    $script:present = $true
    function Save-Session([hashtable]$Session) { $Session | ConvertTo-Json | Set-Content $sessionFile }
    function Invoke-Tool([string]$Tool, [string[]]$Arguments) {
        if ($Tool -cne 'az') { throw 'Unexpected external command.' }
        if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'exists') { return $script:present.ToString().ToLowerInvariant() }
        if ($Arguments[0] -ceq 'group' -and $Arguments[1] -ceq 'delete') {
            $script:deletions++
            $script:present = $false
            return
        }
        throw 'Unexpected Azure operation.'
    }
    function Invoke-AzJson([string[]]$Arguments) {
        $name = $Arguments[[Array]::IndexOf($Arguments, '--name') + 1]
        if ($name -ceq $testGroup) { return @{tags = @{project = $script:ownerProject; runId = $runId}} }
        $role = $name.Substring(($testGroup + '-nodes-').Length)
        $owner = "/subscriptions/$subscription/resourceGroups/$testGroup/providers/Microsoft.ContainerService/managedClusters/platform-$role"
        if ($script:badNodeOwner) { $owner += '-unrelated' }
        @{managedBy = $owner}
    }
    . ([scriptblock]::Create($cleanup.Extent.Text))
    foreach ($case in @('invalid-record', 'unowned-group', 'unrelated-node-group', 'owned')) {
        $script:present = $true
        $script:ownerProject = if ($case -ceq 'unowned-group') { 'another-project' } else { 'managed-container-platform' }
        $script:badNodeOwner = $case -ceq 'unrelated-node-group'
        Save-Session @{runId = $runId; group = $(if ($case -ceq 'invalid-record') { 'unrelated-group' } else { $testGroup }); subscription = $subscription}
        if ($case -ceq 'owned') {
            Set-Content $kubeconfig 'disposable test credential'
            Remove-Demo
            Remove-Demo
            if ($script:deletions -ne 1 -or (Test-Path $kubeconfig)) { throw 'Owned cleanup was not idempotent.' }
        } else {
            try { Remove-Demo; throw 'Unsafe cleanup was accepted.' }
            catch {
                if ($_.Exception.Message -notmatch '^Invalid Azure ownership record|^Refusing unowned resource group|^Refusing unrelated node resource group') { throw }
            }
            if ($script:deletions -ne 0) { throw 'Cleanup deleted a resource before verifying every owner.' }
        }
    }
}
Write-Host 'Azure source passed: template compilation, script parsing, ownership refusal, and idempotent cleanup.'
