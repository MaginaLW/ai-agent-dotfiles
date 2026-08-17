#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('RewriteFile', 'SwapDirectory')]
    [string] $Mode,

    [Parameter(Mandatory)]
    [string] $ReadyMarker,

    [Parameter(Mandatory)]
    [string] $DoneMarker,

    [Parameter(Mandatory)]
    [string] $ResultPath,

    [Parameter(Mandatory)]
    [string] $TargetPath,

    [string] $ReplacementBase64,
    [string] $MovedPath,
    [string] $ReplacementRelativeDirectory,
    [string] $ReplacementLeafName,
    [ValidateRange(1000, 30000)]
    [int] $TimeoutMilliseconds = 15000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-CreateNewUtf8 {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Text
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

$result = [ordered]@{
    Mode = $Mode
    Attempted = $false
    Succeeded = $false
    Blocked = $false
    Error = $null
}

try {
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $ReadyMarker -PathType Leaf)) {
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw 'Timed out waiting for the journal race ready marker.'
        }
        Start-Sleep -Milliseconds 10
    }

    $result.Attempted = $true
    try {
        switch ($Mode) {
            'RewriteFile' {
                if ([string]::IsNullOrWhiteSpace($ReplacementBase64)) {
                    throw 'RewriteFile requires ReplacementBase64.'
                }
                $replacement = [Convert]::FromBase64String($ReplacementBase64)
                $stream = [System.IO.File]::Open($TargetPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                try {
                    $stream.Position = 0
                    $stream.Write($replacement, 0, $replacement.Length)
                    $stream.SetLength($replacement.Length)
                    $stream.Flush($true)
                }
                finally {
                    $stream.Dispose()
                }
            }
            'SwapDirectory' {
                if ([string]::IsNullOrWhiteSpace($MovedPath)) {
                    throw 'SwapDirectory requires MovedPath.'
                }
                [System.IO.Directory]::Move($TargetPath, $MovedPath)
                [System.IO.Directory]::CreateDirectory($TargetPath) | Out-Null
                if (-not [string]::IsNullOrWhiteSpace($ReplacementRelativeDirectory)) {
                    [System.IO.Directory]::CreateDirectory((Join-Path $TargetPath $ReplacementRelativeDirectory)) | Out-Null
                }
                if (-not [string]::IsNullOrWhiteSpace($ReplacementLeafName)) {
                    $leaf = Join-Path $TargetPath $ReplacementLeafName
                    $leafStream = [System.IO.File]::Open($leaf, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
                    try { $leafStream.Flush($true) }
                    finally { $leafStream.Dispose() }
                }
            }
        }
        $result.Succeeded = $true
    }
    catch [System.IO.IOException] {
        $result.Blocked = $true
        $result.Error = $_.Exception.Message
    }
    catch [System.UnauthorizedAccessException] {
        $result.Blocked = $true
        $result.Error = $_.Exception.Message
    }
    catch {
        $result.Error = $_.Exception.Message
    }
}
catch {
    $result.Error = $_.Exception.Message
}
finally {
    try {
        Write-CreateNewUtf8 -Path $ResultPath -Text ($result | ConvertTo-Json -Compress)
    }
    finally {
        Write-CreateNewUtf8 -Path $DoneMarker -Text 'done'
    }
}
