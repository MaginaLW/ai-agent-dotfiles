#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

$protected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($path in @(
    '.reasonix/desktop-topic-auto-title-meta.json',
    '.reasonix/desktop-topic-created-at.json',
    '.reasonix/desktop-topic-title-sources.json',
    '.reasonix/desktop-topic-titles.json'
)) { $null = $protected.Add($path) }

$excludedPrefixes = @('claude/skills/', 'codex/skills/', 'reasonix/skills/', 'envs/', 'reports/', 'tmp/', 'imports/')

# Reviewed exemptions for the operator-as-parameter guard below. Each entry is
# a file plus its exact reviewed line numbers. The table is empty: its only
# entry was a self-sealed hard-kill analysis line whose intended three-call
# condition parsed as a single call, retired once that slice landed its
# reviewed re-seal. Keep the mechanism so a future reviewed exemption has a
# declared home rather than an ad-hoc allowlist.
$reviewedOperatorParameterExemptions = @{}

# Reviewed exemptions for the array-statement flattening guard below. Each
# entry is a file plus the exact reviewed line number of the offending @()
# expression. The current entry is the hard-kill suite's sealed mutation-name
# list: one of its source lines lacks a trailing comma, so the list parses as
# two array statements inside @(). The flattening there is value-identical to
# the comma form (the same flat 302-string list, no nesting intent), and
# rewriting sealed test bytes for a cosmetic comma is disproportionate; retire
# the entry in a re-seal window that adds the missing comma instead.
$reviewedArrayStatementFlatteningExemptions = @{
    'tests/canonical-hard-kill.tests.ps1' = @(11788)
}
$paths = @(& git -C $RepoRoot ls-files -co --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate current-worktree files for syntax validation.' }
$errors = [System.Collections.Generic.List[object]]::new()
$parsed = 0
$parsedFiles = [System.Collections.Generic.List[object]]::new()
$functionParameters = @{}
$ambiguousFunctions = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($relative in @($paths | Sort-Object -Unique)) {
    $normalized = ([string]$relative).Replace([char]92, [char]47)
    if ($normalized.StartsWith('./', [System.StringComparison]::Ordinal)) { $normalized = $normalized.Substring(2) }
    if ($protected.Contains($normalized)) { continue }
    if (@($excludedPrefixes | Where-Object { $normalized.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase) }).Count -gt 0) { continue }
    if ([System.IO.Path]::GetExtension($normalized) -notin @('.ps1', '.psm1', '.psd1')) { continue }
    $full = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $normalized))
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { continue }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
    $parsed++
    foreach ($parseError in @($parseErrors)) {
        $errors.Add([pscustomobject]@{ File = $normalized; Line = $parseError.Extent.StartLineNumber; Column = $parseError.Extent.StartColumnNumber; Message = $parseError.Message })
    }
    if ($null -eq $parseErrors -or @($parseErrors).Count -eq 0) {
        $parsedFiles.Add([pscustomobject]@{ Relative = $normalized; Ast = $ast })
        # Named parameters on repository-function calls must exist on the callee.
        # Only production scripts feed the signature map: test files define
        # same-name local helpers and external-tool shims (for example a local
        # `git` stub), which would make resolution wrong rather than strict.
        if (-not $normalized.StartsWith('scripts/', [System.StringComparison]::Ordinal)) { continue }
        foreach ($functionAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))) {
            $functionName = [string] $functionAst.Name
            $parameterNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
            foreach ($commonName in @('ErrorAction', 'ErrorVariable', 'WarningAction', 'WarningVariable', 'InformationAction', 'InformationVariable', 'OutVariable', 'OutBuffer', 'PipelineVariable', 'ProgressAction', 'Verbose', 'Debug')) {
                $null = $parameterNames.Add($commonName)
            }
            $dynamicParameters = $false
            if ($null -ne $functionAst.Body.DynamicParamBlock) { $dynamicParameters = $true }
            elseif ($null -ne $functionAst.Body.ParamBlock) {
                foreach ($parameter in @($functionAst.Body.ParamBlock.Parameters)) {
                    $null = $parameterNames.Add($parameter.Name.VariablePath.UserPath)
                    foreach ($attribute in @($parameter.Attributes)) {
                        if ($attribute -is [System.Management.Automation.Language.AttributeAst] -and [string] $attribute.TypeName.Name -ceq 'Alias') {
                            foreach ($argument in @($attribute.PositionalArguments)) {
                                if ($argument -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $null = $parameterNames.Add([string] $argument.Value) }
                            }
                        }
                    }
                }
            }
            if ($dynamicParameters) { continue }
            if ($functionParameters.ContainsKey($functionName)) {
                $null = $ambiguousFunctions.Add($functionName)
            }
            else {
                $functionParameters[$functionName] = $parameterNames
            }
        }
    }
}

foreach ($parsedFile in @($parsedFiles)) {
    $normalized = [string] $parsedFile.Relative
    $ast = $parsedFile.Ast
    # A bare -and/-or inside a command invocation is a parsed argument, not
    # an operator. What happens next depends on the callee: an advanced
    # function rejects the unknown parameter ("a parameter cannot be found
    # that matches parameter name 'and'"), but a simple function accepts it
    # as one more positional value and the condition silently degrades to
    # the first check alone. The silent form is the one that shipped in
    # tests/canonical-hard-kill.tests.ps1:8256, so treat every hit as fatal.
    # Parenthesise the command call instead.
    foreach ($command in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        foreach ($element in @($command.CommandElements)) {
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            # Case-insensitive on purpose: PowerShell parameter binding is case-insensitive,
            # so `-AND` collapses the same way and must not slip through the gate.
            if ([string] $element.ParameterName -notin @('and', 'or')) { continue }
            $exempt = $false
            if ($reviewedOperatorParameterExemptions.ContainsKey($normalized)) {
                $exempt = ([int] $element.Extent.StartLineNumber) -in $reviewedOperatorParameterExemptions[$normalized]
            }
            if ($exempt) { continue }
            $errors.Add([pscustomobject]@{
                File = $normalized
                Line = $element.Extent.StartLineNumber
                Column = $element.Extent.StartColumnNumber
                Message = "operator '-$($element.ParameterName)' parsed as a command parameter; wrap the command call in parentheses"
            })
        }
    }
}
foreach ($parsedFile in @($parsedFiles)) {
    $normalized = [string] $parsedFile.Relative
    $ast = $parsedFile.Ast
    # A bare array statement inside @() unrolls into the collected output:
    # @(@('a','1'); @('b','2')) evaluates to the flat four-string list
    # @('a','1','b','2'), never the two pairs its shape suggests, and an
    # element expression then reads characters instead of pairs ($_[0] is
    # 'a') with no runtime error to notice. Semicolon, newline, and
    # parenthesised forms all parse and flatten silently (same-line
    # adjacency is already a parse error). That form shipped once as the
    # live-operation token/severity pairing table (2026-09-30, fixed by a
    # hashtable lookup), a repeat of an earlier comma-precedence cousin,
    # so treat every hit as fatal. Comma-nest the arrays or wrap each with
    # a unary comma instead.
    foreach ($array in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.ArrayExpressionAst] }, $true))) {
        $bareArrayStatements = 0
        foreach ($statement in @($array.SubExpression.Statements)) {
            if ($statement -isnot [System.Management.Automation.Language.PipelineAst]) { continue }
            if (@($statement.PipelineElements).Count -ne 1) { continue }
            $element = $statement.PipelineElements[0]
            if ($element -isnot [System.Management.Automation.Language.CommandExpressionAst]) { continue }
            $expression = $element.Expression
            if ($expression -is [System.Management.Automation.Language.ParenExpressionAst]) {
                $parenPipeline = $expression.Pipeline
                if ($parenPipeline -is [System.Management.Automation.Language.PipelineAst] -and
                    @($parenPipeline.PipelineElements).Count -eq 1 -and
                    $parenPipeline.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                    $expression = $parenPipeline.PipelineElements[0].Expression
                }
            }
            if ($expression -is [System.Management.Automation.Language.ArrayExpressionAst] -or $expression -is [System.Management.Automation.Language.ArrayLiteralAst]) { $bareArrayStatements++ }
        }
        if ($bareArrayStatements -lt 2) { continue }
        $exempt = $false
        if ($reviewedArrayStatementFlatteningExemptions.ContainsKey($normalized)) {
            $exempt = ([int] $array.Extent.StartLineNumber) -in $reviewedArrayStatementFlatteningExemptions[$normalized]
        }
        if ($exempt) { continue }
        $errors.Add([pscustomobject]@{
            File = $normalized
            Line = $array.Extent.StartLineNumber
            Column = $array.Extent.StartColumnNumber
            Message = "bare array statements inside @() flatten into one list; comma-nest or wrap each"
        })
    }
}
foreach ($parsedFile in @($parsedFiles)) {
    $normalized = [string] $parsedFile.Relative
    # Production scripts only: test files define same-name local helpers and
    # external-tool shims (for example a local `git` wrapper), which would make
    # name-based resolution ambiguous rather than wrong.
    if (-not $normalized.StartsWith('scripts/', [System.StringComparison]::Ordinal)) { continue }
    foreach ($command in @($parsedFile.Ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
        $commandName = $command.GetCommandName()
        if ([string]::IsNullOrWhiteSpace($commandName)) { continue }
        $targetName = [string] $commandName
        if (-not $functionParameters.ContainsKey($targetName)) { continue }
        if ($ambiguousFunctions.Contains($targetName)) { continue }
        foreach ($element in @($command.CommandElements)) {
            if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
            $parameterName = [string] $element.ParameterName
            if ($parameterName -in @('and', 'or')) { continue }
            if ($functionParameters[$targetName].Contains($parameterName)) { continue }
            $errors.Add([pscustomobject]@{
                File = $normalized
                Line = $element.Extent.StartLineNumber
                Column = $element.Extent.StartColumnNumber
                Message = "unknown parameter '-$parameterName' for repository function '$targetName'"
            })
        }
    }
}

if ($errors.Count -gt 0) {
    $errors | Format-Table -AutoSize | Out-String | Write-Host
    Write-Error "PowerShell syntax validation failed: $($errors.Count) parser error(s)." -ErrorAction Continue
    exit 1
}
Write-Host "PowerShell syntax validation passed: $parsed file(s)."
