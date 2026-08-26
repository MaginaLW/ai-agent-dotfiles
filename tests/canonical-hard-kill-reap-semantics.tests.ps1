#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if(-not $Condition){throw $Message}
}

. (Join-Path $RepoRoot 'tests/helpers/canonical-hard-kill-job-process.ps1')

$identityMethod=[AiAgentDotfilesTests.HardKillJobProcess].GetMethod(
    'OriginalProcessIdentityGone',
    [Reflection.BindingFlags]'Static,NonPublic'
)
Assert-True ($null -ne $identityMethod) 'exact identity probe is unavailable'

$current=[Diagnostics.Process]::GetCurrentProcess()
try{
    $currentCreationFileTime=[long]$current.StartTime.ToUniversalTime().ToFileTimeUtc()
    Assert-True (-not[bool]$identityMethod.Invoke($null,@([int]$current.Id,$currentCreationFileTime))) `
        'a live exact PID/creation identity was incorrectly reported gone'
    Assert-True ([bool]$identityMethod.Invoke($null,@([int]$current.Id,($currentCreationFileTime-1L)))) `
        'a reused PID with a different creation FILETIME was not distinguished'
}finally{$current.Dispose()}

$probe=$null
try{
    $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    $probe=[Diagnostics.Process]::new()
    $probe.StartInfo.FileName=$pwsh
    $probe.StartInfo.UseShellExecute=$false
    $null=$probe.StartInfo.ArgumentList.Add('-NoProfile')
    $null=$probe.StartInfo.ArgumentList.Add('-Command')
    $null=$probe.StartInfo.ArgumentList.Add('[Threading.Thread]::Sleep(60000)')
    Assert-True $probe.Start() 'retained-handle identity probe did not start'
    $probeCreationFileTime=[long]$probe.StartTime.ToUniversalTime().ToFileTimeUtc()
    $null=$probe.Handle
    $probe.Kill($true)
    Assert-True $probe.WaitForExit(10000) 'retained-handle identity probe did not exit'
    Assert-True (-not[bool]$identityMethod.Invoke($null,@([int]$probe.Id,$probeCreationFileTime))) `
        'a signaled exact process retained by an external handle was incorrectly reported gone'
    $probeId=[int]$probe.Id
    $probe.Dispose();$probe=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do{
        $gone=[bool]$identityMethod.Invoke($null,@($probeId,$probeCreationFileTime))
        if(-not $gone){Start-Sleep -Milliseconds 10}
    }until($gone -or [DateTime]::UtcNow -ge $deadline)
    Assert-True $gone 'the exact process identity remained visible after its final test-owned handle closed'
    Write-Host 'Results: 4 passed, 0 failed'
}finally{
    if($probe){try{if(-not $probe.HasExited){$probe.Kill($true);$null=$probe.WaitForExit(10000)}}finally{$probe.Dispose()}}
}
