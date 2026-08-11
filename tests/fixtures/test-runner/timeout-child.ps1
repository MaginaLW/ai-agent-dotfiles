#requires -Version 7.0
param([Parameter(Mandatory)] [string] $StateRoot)

$pidPath = Join-Path $StateRoot 'child.pid'
$heartbeatPath = Join-Path $StateRoot 'child.heartbeat'
[System.IO.File]::WriteAllText($pidPath, [string] $PID)
$grandchild = Join-Path $PSScriptRoot 'timeout-grandchild.ps1'
Start-Process -FilePath (Get-Command pwsh -CommandType Application | Select-Object -First 1 -ExpandProperty Source) `
    -ArgumentList @('-NoProfile', '-File', $grandchild, '-StateRoot', $StateRoot) -WindowStyle Hidden | Out-Null
while ($true) {
    [System.IO.File]::AppendAllText($heartbeatPath, ([DateTime]::UtcNow.ToString('o') + "`n"))
    Start-Sleep -Milliseconds 150
}
