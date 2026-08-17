#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StateRoot,
    [int] $HoldSeconds = 20
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

[System.IO.File]::WriteAllText((Join-Path $StateRoot 'pipe-holder-child.pid'), [string] $PID)
Write-Output 'pipe-holder child inherited the suite output pipe'
Start-Sleep -Seconds $HoldSeconds
