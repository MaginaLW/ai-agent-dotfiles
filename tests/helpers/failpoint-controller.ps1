#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'process-tree.ps1')

function New-FailpointController {
    [CmdletBinding()]
    param()

    $name = 'ai-agent-dotfiles-' + [Guid]::NewGuid().ToString('N')
    $server = [System.IO.Pipes.NamedPipeServerStream]::new(
        $name,
        [System.IO.Pipes.PipeDirection]::In,
        1,
        [System.IO.Pipes.PipeTransmissionMode]::Byte,
        [System.IO.Pipes.PipeOptions]::Asynchronous
    )
    return [pscustomobject]@{ Name = $name; Server = $server }
}

function Wait-FailpointController {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Controller,
        [Parameter(Mandatory)] [string] $ExpectedCheckpoint,
        [int] $TimeoutSeconds = 30
    )

    $connection = $Controller.Server.WaitForConnectionAsync()
    if (-not $connection.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        throw "Timed out waiting for failpoint connection: $ExpectedCheckpoint"
    }
    $reader = [System.IO.StreamReader]::new($Controller.Server, [System.Text.UTF8Encoding]::new($false), $false, 1024, $true)
    try {
        $read = $reader.ReadLineAsync()
        if (-not $read.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
            throw "Timed out waiting for failpoint message: $ExpectedCheckpoint"
        }
        if ($read.Result -ne $ExpectedCheckpoint) {
            throw "Unexpected failpoint '$($read.Result)'; expected '$ExpectedCheckpoint'."
        }
    }
    finally {
        $reader.Dispose()
    }
}

function Stop-FailpointProcessTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Diagnostics.Process] $Process)

    if (-not (Stop-ProcessTree -Process $Process)) {
        throw "Failed to stop failpoint process tree rooted at PID $($Process.Id)."
    }
}

function Close-FailpointController {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Controller)

    $Controller.Server.Dispose()
}
