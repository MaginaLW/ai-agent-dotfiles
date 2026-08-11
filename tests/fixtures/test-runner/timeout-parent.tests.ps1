#requires -Version 7.0

if ([string]::IsNullOrWhiteSpace($env:AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT)) {
    throw 'AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT is required.'
}
$stateRoot = $env:AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'parent.pid'), [string] $PID)
$child = Join-Path $PSScriptRoot 'timeout-child.ps1'
Start-Process -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1 -ExpandProperty Source) `
    -ArgumentList @('-NoProfile', '-File', $child, '-StateRoot', $stateRoot) -WindowStyle Hidden | Out-Null
while ($true) {
    [System.IO.File]::AppendAllText((Join-Path $stateRoot 'parent.heartbeat'), ([DateTime]::UtcNow.ToString('o') + "`n"))
    Start-Sleep -Milliseconds 150
}
