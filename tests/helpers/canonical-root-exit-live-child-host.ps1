#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('root','child')][string]$Mode,
    [Parameter(Mandatory)][string]$ChildMarkerPath,
    [string]$ChildEvidencePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'canonical-hard-kill-job-process.ps1')

if(-not [AiAgentDotfilesTests.HardKillJobProcess]::CurrentProcessIsInJob()){
    throw 'root-exit live-child fixture requires inherited Job containment'
}

if($Mode -ceq 'child'){
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ChildMarkerPath),'alive',[Text.UTF8Encoding]::new($false))
    [Threading.ManualResetEventSlim]::new($false).Wait()
    exit 0
}

if([string]::IsNullOrWhiteSpace($ChildEvidencePath)){throw 'root mode requires ChildEvidencePath'}
$child=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @(
    '-NoProfile','-File',$PSCommandPath,'-Mode','child','-ChildMarkerPath',([IO.Path]::GetFullPath($ChildMarkerPath))
) -PassThru -WindowStyle Hidden
$childStartTimeUtcTicks=[long]$child.StartTime.ToUniversalTime().Ticks
$deadline=[DateTime]::UtcNow.AddSeconds(10)
while(-not(Test-Path -LiteralPath $ChildMarkerPath -PathType Leaf) -and -not $child.HasExited -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 20}
if(-not(Test-Path -LiteralPath $ChildMarkerPath -PathType Leaf) -or $child.HasExited){throw 'live-child fixture failed to reach its child boundary'}
$evidence=[ordered]@{ProcessId=[int]$child.Id;StartTimeUtcTicks=$childStartTimeUtcTicks}
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ChildEvidencePath),($evidence|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
