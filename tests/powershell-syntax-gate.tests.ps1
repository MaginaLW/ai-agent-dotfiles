#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$gateScript = Join-Path $RepoRoot 'scripts/check-powershell-syntax.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$fixtureRoots = [System.Collections.Generic.List[string]]::new()

function Assert-True {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw $Message }
    Write-Host "  PASS  $Message"
}

function New-FixtureRepo {
    param([Parameter(Mandatory)] [hashtable] $Files)
    $root = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-ps-syntax-gate-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    $fixtureRoots.Add($root)
    & git -C $root init --quiet
    if ($LASTEXITCODE -ne 0) { throw "fixture git init failed: $root" }
    foreach ($relative in @($Files.Keys)) {
        $full = [System.IO.Path]::GetFullPath((Join-Path $root ([string]$relative)))
        $parent = [System.IO.Path]::GetDirectoryName($full)
        if (-not [string]::IsNullOrWhiteSpace($parent)) {
            [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        }
        [System.IO.File]::WriteAllText($full, [string]$Files[$relative], $utf8)
    }
    return (Resolve-Path -LiteralPath $root).Path
}

function Invoke-SyntaxGate {
    param([Parameter(Mandatory)] [string] $TargetRoot)
    $pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $pwsh
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.WorkingDirectory = $TargetRoot
    foreach ($argument in @('-NoProfile', '-File', $gateScript, '-RepoRoot', $TargetRoot)) {
        $startInfo.ArgumentList.Add($argument)
    }
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start the syntax-gate child process.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) {
            try { $process.Kill($true) } catch { }
            $null = $process.WaitForExit(5000)
            throw 'syntax-gate child process exceeded 120 seconds.'
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Output = [string]$stdoutTask.GetAwaiter().GetResult() + [string]$stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Test-ConstantBooleanCondition {
    param($ConditionAst)
    if ($null -eq $ConditionAst) { return $false }
    $expression = $null
    if ($ConditionAst -is [System.Management.Automation.Language.PipelineAst]) {
        $elements = @($ConditionAst.PipelineElements)
        if ($elements.Count -ne 1) { return $false }
        if ($elements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) { return $false }
        $expression = $elements[0].Expression
    }
    else {
        $expression = $ConditionAst
    }
    if ($expression -is [System.Management.Automation.Language.VariableExpressionAst]) {
        return ([string]$expression.VariablePath.UserPath) -in @('true', 'false')
    }
    if ($expression -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        return $expression.Value -is [bool]
    }
    return $false
}

function Test-NestedInConstantIf {
    param([Parameter(Mandatory)] [System.Management.Automation.Language.Ast] $Node)
    $cursor = $Node.Parent
    while ($null -ne $cursor) {
        if ($cursor -is [System.Management.Automation.Language.IfStatementAst]) {
            foreach ($clause in @($cursor.Clauses)) {
                if (Test-ConstantBooleanCondition $clause.Item1) { return $true }
            }
        }
        $cursor = $cursor.Parent
    }
    return $false
}

try {
    Write-Host '[operator-as-parameter fixtures]'

    $lowerOrRoot = New-FixtureRepo -Files @{
        'probe-or.ps1' = 'Test-A $x -or Test-B $x' + "`n"
    }
    $lowerOr = Invoke-SyntaxGate -TargetRoot $lowerOrRoot
    Assert-True ($lowerOr.ExitCode -eq 1) "lower-case -or exits 1 (got $($lowerOr.ExitCode))"
    Assert-True ($lowerOr.Output -match "operator '-or' parsed as a command parameter") 'lower-case -or reports the operator-as-parameter message'

    $upperAndRoot = New-FixtureRepo -Files @{
        'probe-and.ps1' = 'Test-A $x -AND Test-B $x' + "`n"
    }
    $upperAnd = Invoke-SyntaxGate -TargetRoot $upperAndRoot
    Assert-True ($upperAnd.ExitCode -eq 1) "upper-case -AND exits 1 (got $($upperAnd.ExitCode))"
    Assert-True ($upperAnd.Output -match "operator '-AND' parsed as a command parameter") 'upper-case -AND reports the operator-as-parameter message'

    $parenRoot = New-FixtureRepo -Files @{
        'probe-paren.ps1' = 'if((Test-A $x) -or (Test-B $x)) { }' + "`n"
    }
    $paren = Invoke-SyntaxGate -TargetRoot $parenRoot
    Assert-True ($paren.ExitCode -eq 0) "parenthesised -or exits 0 (got $($paren.ExitCode))"
    Assert-True ($paren.Output -match 'PowerShell syntax validation passed: 1 file\(s\)\.') 'parenthesised -or is accepted'

    $exprRoot = New-FixtureRepo -Files @{
        'probe-expr.ps1' = 'if ($x -and $y) { }' + "`n"
    }
    $expr = Invoke-SyntaxGate -TargetRoot $exprRoot
    Assert-True ($expr.ExitCode -eq 0) "expression -and exits 0 (got $($expr.ExitCode))"
    Assert-True ($expr.Output -match 'PowerShell syntax validation passed: 1 file\(s\)\.') 'genuine expression operator is accepted'

    Write-Host '[scripts/ unknown-parameter pass does not double-report]'
    $doubleRoot = New-FixtureRepo -Files @{
        'scripts/double-report.ps1' = @(
            'function Test-Foo { param([string] $Value) }'
            "Test-Foo -AND 'x'"
        ) -join "`n"
    }
    $double = Invoke-SyntaxGate -TargetRoot $doubleRoot
    Assert-True ($double.ExitCode -eq 1) "scripts/ bare -AND exits 1 (got $($double.ExitCode))"
    $operatorHits = [regex]::Matches($double.Output, 'parsed as a command parameter').Count
    Assert-True ($operatorHits -eq 1) "scripts/ bare -AND reports the operator message exactly once (got $operatorHits)"
    Assert-True ($double.Output -notmatch "unknown parameter '-AND'") 'scripts/ bare -AND is not also reported as an unknown parameter'

    Write-Host '[array-statement flattening fixtures]'
    $flatRoot = New-FixtureRepo -Files @{
        'probe-flat.ps1' = @(
            '$pairs = @(@(''a'',''1''); @(''b'',''2''))'
            '$flat = @(''x'',''y'''
            '''z'',''w'')'
            '$parenPairs = @((''a'',''1'')'
            '(''b'',''2''))'
        ) -join "`n"
    }
    $flat = Invoke-SyntaxGate -TargetRoot $flatRoot
    Assert-True ($flat.ExitCode -eq 1) "bare array statements in @() exit 1 (got $($flat.ExitCode))"
    $flatHits = [regex]::Matches($flat.Output, 'bare array statements inside @\(\) flatten').Count
    Assert-True ($flatHits -eq 3) "semicolon pairs, the missing-comma list, and parenthesised pairs each report once (got $flatHits)"

    $nestedRoot = New-FixtureRepo -Files @{
        'probe-nested.ps1' = @(
            '$pairs = @(@(''a'',''1''), @(''b'',''2''))'
            '$wrapped = @(,@(''a'',''1'') ,@(''b'',''2''))'
            '$single = @(@(''a'',''1''))'
        ) -join "`n"
    }
    $nested = Invoke-SyntaxGate -TargetRoot $nestedRoot
    Assert-True ($nested.ExitCode -eq 0) "comma-nested pairs, unary-comma wraps, and a single nested array exit 0 (got $($nested.ExitCode))"
    Assert-True ($nested.Output -match 'PowerShell syntax validation passed: 1 file\(s\)\.') 'intended nesting forms are accepted'

    Write-Host '[gate source: parses]'
    $tokens = $null
    $parseErrors = $null
    $gateAst = [System.Management.Automation.Language.Parser]::ParseFile($gateScript, [ref]$tokens, [ref]$parseErrors)
    Assert-True (@($parseErrors).Count -eq 0) 'gate script parses without errors'

    Write-Host '[gate source: operator check is not a constant-if off switch]'
    $operatorLoops = @($gateAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Extent.Text.Contains('parsed as a command parameter')
    }, $true))
    Assert-True ($operatorLoops.Count -gt 0) 'operator-as-parameter foreach is present in the gate AST'
    $disabledLoops = @($operatorLoops | Where-Object { Test-NestedInConstantIf $_ })
    Assert-True ($disabledLoops.Count -eq 0) 'operator-as-parameter foreach is not nested in if ($true)/if ($false)'

    Write-Host '[gate source: array-flattening check is not a constant-if off switch]'
    $flatteningLoops = @($gateAst.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.ForEachStatementAst] -and
        $node.Extent.Text.Contains('bare array statements inside @() flatten')
    }, $true))
    Assert-True ($flatteningLoops.Count -gt 0) 'array-flattening foreach is present in the gate AST'
    $flatteningDisabled = @($flatteningLoops | Where-Object { Test-NestedInConstantIf $_ })
    Assert-True ($flatteningDisabled.Count -eq 0) 'array-flattening foreach is not nested in if ($true)/if ($false)'

    Write-Host '[repository as-is]'
    $repoRun = Invoke-SyntaxGate -TargetRoot $RepoRoot
    Assert-True ($repoRun.ExitCode -eq 0) "worktree gate exits 0 (got $($repoRun.ExitCode))"
    Assert-True ($repoRun.Output -match 'PowerShell syntax validation passed:') 'worktree gate prints the success line'

    Write-Host 'powershell syntax gate tests: PASS'
}
finally {
    foreach ($root in @($fixtureRoots)) {
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }
}
