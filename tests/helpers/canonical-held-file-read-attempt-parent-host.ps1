#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$HelperPath,
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$OpenedMarkerPath,
    [Parameter(Mandatory)][string]$ChildEvidencePath,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$DeadlineUtcTicks
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'canonical-hard-kill-job-process.ps1')

if(-not [AiAgentDotfilesTests.HardKillJobProcess]::CurrentProcessIsInJob()){
    throw 'held-file read-attempt parent host requires inherited Job containment'
}

$child=$null;$childStartTimeUtcTicks=$null
try{
    $self=[Diagnostics.Process]::GetCurrentProcess()
    $child=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @(
        '-NoProfile','-File',([IO.Path]::GetFullPath($HelperPath)),
        '-Path',([IO.Path]::GetFullPath($Path)),
        '-OpenedMarkerPath',([IO.Path]::GetFullPath($OpenedMarkerPath)),
        '-ParentProcessId',$PID,
        '-ParentStartTimeUtcTicks',$self.StartTime.ToUniversalTime().Ticks,
        '-DeadlineUtcTicks',$DeadlineUtcTicks
    ) -PassThru -WindowStyle Hidden
    $childStartTimeUtcTicks=[long]$child.StartTime.ToUniversalTime().Ticks
    $openedDeadline=[DateTime]::UtcNow.AddSeconds(10)
    while(-not(Test-Path -LiteralPath $OpenedMarkerPath -PathType Leaf) -and -not $child.HasExited -and [DateTime]::UtcNow -lt $openedDeadline){Start-Sleep -Milliseconds 20}
    if(-not(Test-Path -LiteralPath $OpenedMarkerPath -PathType Leaf) -or $child.HasExited){throw 'held-file child did not reach its opened boundary while its parent was alive'}
    $evidence=[ordered]@{ProcessId=[int]$child.Id;StartTimeUtcTicks=[long]$child.StartTime.ToUniversalTime().Ticks}
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ChildEvidencePath),($evidence|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}catch{throw}
