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
