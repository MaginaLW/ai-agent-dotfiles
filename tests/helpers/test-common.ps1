#requires -Version 7.0

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
