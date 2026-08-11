#requires -Version 7.0

function Invoke-SafetySandboxScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SandboxRoot,
        [Parameter(Mandatory)] [string] $ScriptPath,
        [AllowEmptyCollection()] [string[]] $Arguments = @(),
        [string] $AuthorityRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    )

    $json = ConvertTo-Json -InputObject @($Arguments) -Compress
    $encoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($json))
    $hostScript = Join-Path $AuthorityRepoRoot 'scripts/internal/live-transaction-host.ps1'
    $output = @(& pwsh -NoProfile -File $hostScript -SandboxRoot $SandboxRoot -ScriptPath $ScriptPath -ArgumentsBase64 $encoded 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
}
