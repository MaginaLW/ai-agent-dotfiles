#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT)) {
    throw 'AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT is required.'
}

$stateRoot = [System.IO.Path]::GetFullPath($env:AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT)
[System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'pipe-holder-parent.pid'), [string] $PID)
$childScript = Join-Path $PSScriptRoot 'pipe-holder-child.ps1'
$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$startInfo.UseShellExecute = $false
$startInfo.CreateNoWindow = $true
$null = $startInfo.ArgumentList.Add('-NoProfile')
$null = $startInfo.ArgumentList.Add('-File')
$null = $startInfo.ArgumentList.Add($childScript)
$null = $startInfo.ArgumentList.Add('-StateRoot')
$null = $startInfo.ArgumentList.Add($stateRoot)
$child = [System.Diagnostics.Process]::Start($startInfo)
if ($null -eq $child) { throw 'Unable to start pipe-holder child.' }

$pidPath = Join-Path $stateRoot 'pipe-holder-child.pid'
$deadline = [DateTime]::UtcNow.AddSeconds(10)
while (-not (Test-Path -LiteralPath $pidPath -PathType Leaf)) {
    if ([DateTime]::UtcNow -ge $deadline) { throw 'Pipe-holder child did not publish its PID.' }
    Start-Sleep -Milliseconds 25
}

Write-Output 'pipe-holder fixture parent exits while its child keeps the inherited pipe open'
exit 0
