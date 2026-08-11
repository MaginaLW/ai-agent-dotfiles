#requires -Version 7.0
param([Parameter(Mandatory)] [string] $StateRoot)

$pidPath = Join-Path $StateRoot 'grandchild.pid'
$heartbeatPath = Join-Path $StateRoot 'grandchild.heartbeat'
[System.IO.File]::WriteAllText($pidPath, [string] $PID)
while ($true) {
    [System.IO.File]::AppendAllText($heartbeatPath, ([DateTime]::UtcNow.ToString('o') + "`n"))
    Start-Sleep -Milliseconds 150
}
