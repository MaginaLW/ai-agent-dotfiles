#requires -Version 7.0

[CmdletBinding()]
param([Parameter(Mandatory)] [string] $StateRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[System.IO.Directory]::CreateDirectory($StateRoot) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $StateRoot 'parent.pid'), [string] $PID)

$start = [System.Diagnostics.ProcessStartInfo]::new()
$start.FileName = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
foreach ($argument in @(
    '-NoProfile',
    '-File',
    (Join-Path $PSScriptRoot 'pinned-tool-pipe-holder-child.ps1'),
    '-StateRoot',
    $StateRoot
)) {
    $null = $start.ArgumentList.Add([string] $argument)
}

$descendant = [System.Diagnostics.Process]::Start($start)
if ($null -eq $descendant) { throw 'Unable to start the pipe-holder descendant.' }
$descendant.Dispose()

$pidPath = Join-Path $StateRoot 'descendant.pid'
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not [System.IO.File]::Exists($pidPath)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Pipe-holder descendant did not publish its PID.' }
    Start-Sleep -Milliseconds 25
}

exit 0
