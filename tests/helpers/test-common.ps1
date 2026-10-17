#requires -Version 7.0

function Set-TestFile([string] $Path, [string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}

function Assert-TestCondition {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Invoke-TestProcess {
    param([Parameter(Mandatory)] [string] $ScriptPath, [string[]] $Arguments = @())
    $output = @(& pwsh -NoProfile -File $ScriptPath @Arguments 2>&1)
    return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
}
