#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StateRoot,
    [int] $HoldSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[System.IO.File]::WriteAllText((Join-Path $StateRoot 'descendant.pid'), [string] $PID)
Write-Output 'pinned-tool pipe-holder descendant owns the inherited output pipe'
Start-Sleep -Seconds $HoldSeconds
