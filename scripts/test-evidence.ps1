#requires -Version 7.0
param([string]$Directory, [string]$Commit)
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $Directory) { $Directory = $state }
if (-not $Commit) { $Commit = Invoke-Tool git @('-C',$root,'rev-parse','HEAD') }
$deployment = Get-Content (Join-Path $Directory 'deployment-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$safe = Get-Content (Join-Path $Directory 'safe-release-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$scaled = Get-Content (Join-Path $Directory 'autoscaling-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$portal = Get-Content (Join-Path $Directory 'portal-evidence.json') -Raw | ConvertFrom-Json -AsHashtable
$cli = Join-Path $root 'src/Platform/bin/Debug/net10.0/platform.dll'
$temporary = Join-Path $state ('evidence-check-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temporary | Out-Null
$verified = @()
try {
    foreach ($case in @(
        @{release=$deployment.release},
        @{release=$safe.recovered;baseline=$deployment.release},
        @{release=$safe.manualRollback;baseline=$deployment.release},
        @{release=$scaled.baseline},
        @{release=$scaled.underLoad},
        @{release=$scaled.recovered;baseline=$scaled.underLoad},
        @{release=$scaled.manualRollback;baseline=$scaled.underLoad},
        @{release=$portal.deployed},
        @{release=$portal.rollback;baseline=$portal.deployed}
    )) {
        $file = Join-Path $temporary 'release.json'
        $case.release | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath $file
        $arguments = @($cli,'evidence','verify',$file,'--commit',$Commit,'--output','json')
        if ($case.ContainsKey('baseline')) {
            $baselineFile = Join-Path $temporary 'baseline.json'
            $case.baseline | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath $baselineFile
            $arguments += @('--baseline',$baselineFile)
        }
        $result = Invoke-Tool dotnet $arguments | ConvertFrom-Json -AsHashtable
        if ($result.release -cne $case.release.metadata.name -or $result.releaseUID -cne $case.release.metadata.uid -or $result.healthyGates.Count -ne 2 -or $result.workerCommit -cne $Commit) {
            throw 'Offline CLI returned a different release or worker.'
        }
        $verified += $result
    }
    $invalid = Get-Content (Join-Path $temporary 'release.json') -Raw | ConvertFrom-Json -AsHashtable
    $invalid.status.gates.'member-a'.health.values.requests = 99999
    $invalid | ConvertTo-Json -Depth 90 | Set-Content -LiteralPath (Join-Path $temporary 'release.json')
    $errorFile = Join-Path $temporary 'expected-error.txt'
    $output = & dotnet @arguments 2> $errorFile
    if ($LASTEXITCODE -ne 1 -or (Get-Content $errorFile -Raw) -notlike '*Raw metric*') { throw 'Offline CLI accepted altered metrics.' }
} finally {
    foreach ($name in @('release.json','baseline.json','expected-error.txt')) {
        $file = Join-Path $temporary $name
        if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file }
    }
    Remove-Item -LiteralPath $temporary
}
@{commit=$Commit;verifierCommit=Invoke-Tool git @('-C',$root,'rev-parse','HEAD');verifierWorkingTreeDirty=@(Invoke-Tool git @('-C',$root,'status','--porcelain')).Count -gt 0
    completedAt=[DateTimeOffset]::UtcNow.ToString('o');scope='Offline verification of saved release exports';verifiedReleases=$verified;alteredMetricsRejected=$true} |
    ConvertTo-Json -Depth 8 | Set-Content (Join-Path $state 'evidence-verification.json')
Write-Host 'Offline evidence passed: nine release exports, recovered and explicit rollbacks, both scaling profiles, and altered metric rejection.'
