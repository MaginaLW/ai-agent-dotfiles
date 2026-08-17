#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path

$script:pass=0
$script:fail=0
function Assert-TestCondition {
    param([bool]$Condition,[string]$Message)
    if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}
    else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red}
}

$productionFiles=@(
    'scripts/canonical-mutation-common.ps1'
    'scripts/canonical-skill-adapter-common.ps1'
    'scripts/canonical-transaction-common.ps1'
    'scripts/canonical-recovery-common.ps1'
    'scripts/transaction-journal-common.ps1'
    'scripts/json-artifact-common.ps1'
)

foreach($relativePath in $productionFiles){
    $path=Join-Path $RepoRoot $relativePath
    $tokens=$null
    $parseErrors=$null
    $ast=[System.Management.Automation.Language.Parser]::ParseFile($path,[ref]$tokens,[ref]$parseErrors)
    Assert-TestCondition (@($parseErrors).Count -eq 0) "$relativePath parses for production-seam inspection"
    if(@($parseErrors).Count -ne 0){continue}

    $scriptBlockParameters=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ParameterAst] -and
            $node.StaticType -eq [scriptblock]
    },$true))
    Assert-TestCondition ($scriptBlockParameters.Count -eq 0) "$relativePath exposes no ScriptBlock parameter seam"

    $injectionParameters=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ParameterAst] -and
            $node.Name.VariablePath.UserPath -match '^(FailpointProvider|Internal[A-Za-z0-9_]*Hook)$'
    },$true))
    Assert-TestCondition ($injectionParameters.Count -eq 0) "$relativePath exposes no failpoint or Internal*Hook parameter"

    $injectionArguments=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandParameterAst] -and
            $node.ParameterName -match '^(FailpointProvider|Internal[A-Za-z0-9_]*Hook)$'
    },$true))
    Assert-TestCondition ($injectionArguments.Count -eq 0) "$relativePath passes no failpoint or Internal*Hook argument"

    $failpointCalls=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'Invoke-CanonicalMutationFailpoint'
    },$true))
    Assert-TestCondition ($failpointCalls.Count -eq 0) "$relativePath invokes no production failpoint dispatcher"

    $dynamicCallbackCalls=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -and
            $node.InvocationOperator -eq [System.Management.Automation.Language.TokenKind]::Ampersand -and
            $node.CommandElements.Count -gt 0 -and
            $node.CommandElements[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]
    },$true))
    $testHelperReferences=@($ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.StringConstantExpressionAst] -and
            $node.Value -match '(?i)(?:^|[/\\])tests[/\\]helpers(?:[/\\]|$)|canonical-reviewed-(?:transaction|recovery)-engine'
    },$true))
    Assert-TestCondition (
        $dynamicCallbackCalls.Count -eq 0 -and $testHelperReferences.Count -eq 0
    ) "$relativePath cannot dynamically invoke a callback or load a sealed test helper"
}

Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan
if($script:fail -ne 0){exit 1}
