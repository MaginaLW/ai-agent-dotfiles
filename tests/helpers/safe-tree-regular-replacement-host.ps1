#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TriggerPath,
    [Parameter(Mandatory)] [string] $SourcePath,
    [Parameter(Mandatory)] [string] $OriginalPath,
    [Parameter(Mandatory)] [string] $ReplacementPath,
    [Parameter(Mandatory)] [string] $SentinelRelativePath,
    [Parameter(Mandatory)] [string] $ReadyPath,
    [Parameter(Mandatory)] [string] $AttemptedPath,
    [Parameter(Mandatory)] [string] $SwappedPath,
    [Parameter(Mandatory)] [string] $ReleasePath,
    [Parameter(Mandatory)] [string] $ErrorPath,
    [int] $TimeoutMilliseconds = 30000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$sentinelHandle = $null
$clock = [System.Diagnostics.Stopwatch]::StartNew()
try {
    [System.IO.File]::WriteAllText($ReadyPath, 'ready', $utf8)
    while (-not (Test-Path -LiteralPath $TriggerPath)) {
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw 'Timed out waiting for the destination race trigger.' }
        Start-Sleep -Milliseconds 2
    }
    [System.IO.File]::WriteAllText($AttemptedPath, 'attempted', $utf8)
    Move-Item -LiteralPath $SourcePath -Destination $OriginalPath -ErrorAction Stop
    Move-Item -LiteralPath $ReplacementPath -Destination $SourcePath -ErrorAction Stop
    $sentinel = Join-Path $SourcePath $SentinelRelativePath
    $sentinelHandle = [System.IO.File]::Open($sentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    [System.IO.File]::WriteAllText($SwappedPath, 'swapped-and-locked', $utf8)
    while (-not (Test-Path -LiteralPath $ReleasePath)) {
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { throw 'Timed out waiting to release the replacement sentinel.' }
        Start-Sleep -Milliseconds 2
    }
}
catch {
    [System.IO.File]::WriteAllText($ErrorPath, $_.Exception.Message, $utf8)
}
finally {
    if ($null -ne $sentinelHandle) { $sentinelHandle.Dispose() }
}
