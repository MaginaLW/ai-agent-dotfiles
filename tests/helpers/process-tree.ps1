#requires -Version 7.0

Set-StrictMode -Version Latest

function Test-ProcessIdAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [int] $ProcessId)

    return $null -ne (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)
}

function Stop-ProcessTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [int] $WaitMilliseconds = 5000
    )

    if ($Process.HasExited) { return $true }
    try {
        $Process.Kill($true)
        if (-not $Process.WaitForExit($WaitMilliseconds)) { return $false }
        return -not (Test-ProcessIdAlive -ProcessId $Process.Id)
    }
    catch {
        return $false
    }
}
