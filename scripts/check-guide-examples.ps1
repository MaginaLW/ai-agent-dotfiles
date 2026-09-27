#requires -Version 7.0
# Static check for the operation guides: every PowerShell fenced block in the selected
# guides must parse, and every invocation of a repository script must name parameters
# that the target script actually declares. Emits a JSON summary and exits 1 on any
# error. CI coverage lives in tests/guide-examples.tests.ps1.
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $OutputPath,
    [string[]] $Guides = @(
        'CLAUDE.md', 'README.md', 'AGENTS.md',
        'docs/README.md', 'docs/ONBOARD_NEW_MACHINE.md', 'docs/RESTORE.md', 'docs/ZCODE.md'
    )
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

# pwsh -File binds a [string[]] parameter from at most one token and silently drops
# extras, so the documented CLI form passes the guide list as one comma-separated
# token; PowerShell-native callers can still pass a real string array.
$Guides = @(
    foreach ($entry in @($Guides)) {
        foreach ($part in ($entry -split ',')) {
            $trimmed = $part.Trim()
            if ($trimmed) { $trimmed }
        }
    }
)

function Get-ScriptParameterNames {
    param([string] $Path)
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { return $null }
    $paramBlock = $ast.ParamBlock
    # The comma wrapper keeps an empty declaration list from unrolling to $null, which
    # the caller would misread as a parse failure; $null is reserved for that failure.
    if ($null -eq $paramBlock) { return ,@() }
    $names = [System.Collections.Generic.List[string]]::new()
    foreach ($parameter in $paramBlock.Parameters) {
        $name = [string]$parameter.Name.VariablePath.UserPath
        if ($name) { $names.Add($name) }
    }
    return ,@($names)
}

$blockPattern = '(?s)```(?:powershell|pwsh|ps1)[ \t]*\r?\n(.*?)```'
# Guides document parameters with <placeholder> spans, which are not PowerShell syntax.
# Replace them with a single-token stand-in so the block can be parsed, and count them.
$placeholderPattern = '<[^<>\r\n]{1,120}>'
$results = [System.Collections.Generic.List[object]]::new()

foreach ($guide in $Guides) {
    $full = Join-Path $RepoRoot $guide
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        # Same shape as a checked row so the totals loop and JSON consumers see one
        # contract; a missing guide is reported, not silently skipped.
        $results.Add([ordered]@{
            Guide = $guide; State = 'missing'; Blocks = 0; Commands = 0
            Placeholders = 0; Invocations = 0; DispatcherInvocations = 0; Errors = @()
        })
        continue
    }
    $text = [IO.File]::ReadAllText($full)
    $blocks = @([regex]::Matches($text, $blockPattern))
    $errors = [System.Collections.Generic.List[string]]::new()
    $invocations = 0
    $blockIndex = 0
    $placeholders = 0
    $commandTotal = 0
    $dispatcherInvocations = 0
    foreach ($block in $blocks) {
        $blockIndex++
        $source = $block.Groups[1].Value
        $placeholderMatches = @([regex]::Matches($source, $placeholderPattern))
        $placeholders += $placeholderMatches.Count
        if ($placeholderMatches.Count -gt 0) { $source = [regex]::Replace($source, $placeholderPattern, 'PLACEHOLDER') }
        $tokens = $null; $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
        foreach ($parseError in @($parseErrors)) {
            $errors.Add(('block {0}: parse error: {1}' -f $blockIndex, $parseError.Message))
        }
        foreach ($commandAst in @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.CommandAst] }, $true))) {
            $commandTotal++
            $elements = @($commandAst.CommandElements)
            if ($elements.Count -eq 0) { continue }
            $names = [System.Collections.Generic.List[string]]::new()
            foreach ($element in $elements) {
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst]) { $names.Add([string]$element.Value) }
            }
            $scriptToken = @($names | Where-Object { $_ -match '\.ps1$' }) | Select-Object -First 1
            if (-not $scriptToken) { continue }
            $candidates = [System.Collections.Generic.List[string]]::new()
            $relative = $scriptToken -replace '\\', '/'
            if ($relative -match '^(?<rel>.+\.ps1)$') {
                $rel = $Matches['rel']
                $candidates.Add((Join-Path $RepoRoot $rel))
                if ($rel -notmatch '/') {
                    foreach ($dir in @('scripts', 'tests', 'tests/helpers')) { $candidates.Add((Join-Path $RepoRoot (Join-Path $dir $rel))) }
                }
            }
            $target = @($candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) | Select-Object -First 1
            if (-not $target) { $errors.Add(('block {0}: referenced script not found: {1}' -f $blockIndex, $scriptToken)); continue }
            $invocations++
            # Only parameters that follow the script path belong to the target script; the
            # host's own switches (pwsh -NoProfile -File) come before it.
            $scriptIndex = -1
            for ($elementIndex = 0; $elementIndex -lt $elements.Count; $elementIndex++) {
                $element = $elements[$elementIndex]
                if ($element -is [System.Management.Automation.Language.StringConstantExpressionAst] -and [string]$element.Value -match '\.ps1$') { $scriptIndex = $elementIndex; break }
            }
            $declared = Get-ScriptParameterNames -Path $target
            if ($null -eq $declared) { $errors.Add(('block {0}: target script does not parse: {1}' -f $blockIndex, $target)); continue }
            # scripts/agent-dotfiles.ps1 is a dispatcher: the guide's parameters belong to the
            # route script it forwards to, not to the dispatcher's own surface. Counted, not
            # parameter-validated here.
            if ([IO.Path]::GetFileName($target) -ceq 'agent-dotfiles.ps1') { $dispatcherInvocations++; continue }
            for ($elementIndex = $scriptIndex + 1; $elementIndex -lt $elements.Count; $elementIndex++) {
                $element = $elements[$elementIndex]
                if ($element -isnot [System.Management.Automation.Language.CommandParameterAst]) { continue }
                $used = [string]$element.ParameterName
                if ($declared -notcontains $used) {
                    $errors.Add(('block {0}: {1} has no parameter -{2}' -f $blockIndex, [IO.Path]::GetFileName($target), $used))
                }
            }
        }
    }
    $results.Add([ordered]@{
        Guide = $guide; State = 'checked'; Blocks = $blocks.Count; Commands = $commandTotal
        Placeholders = $placeholders; Invocations = $invocations; DispatcherInvocations = $dispatcherInvocations; Errors = @($errors)
    })
}

$totalBlocks = 0; $totalInvocations = 0; $errorCount = 0; $totalCommands = 0; $totalPlaceholders = 0; $totalDispatchers = 0
foreach ($row in $results) {
    $totalBlocks += [int]$row.Blocks; $totalInvocations += [int]$row.Invocations
    $totalCommands += [int]$row.Commands; $totalPlaceholders += [int]$row.Placeholders
    $totalDispatchers += [int]$row.DispatcherInvocations
    $errorCount += @($row.Errors).Count
}
$head = 'unavailable'
$gitHead = & git -C $RepoRoot rev-parse HEAD 2>$null
if ($LASTEXITCODE -eq 0 -and $gitHead) { $head = ([string]($gitHead | Select-Object -First 1)).Trim() }
$summary = [ordered]@{
    ArtifactKind = 'guide-example-static-check'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    RepoRoot = $RepoRoot
    Head = $head
    Normalization = 'placeholders matching <...> replaced with the PLACEHOLDER token before parsing'
    Guides = @($results)
    Totals = [ordered]@{
        Blocks = $totalBlocks; Commands = $totalCommands; Placeholders = $totalPlaceholders
        Invocations = $totalInvocations; DispatcherInvocations = $totalDispatchers; Errors = $errorCount
    }
    Result = if ($errorCount -eq 0) { 'PASS' } else { 'FAIL' }
}
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8
Write-Host ('guides={0} blocks={1} commands={2} placeholders={3} scriptInvocations={4} dispatchers={7} errors={5} result={6}' -f @($results).Count, $totalBlocks, $totalCommands, $totalPlaceholders, $totalInvocations, $errorCount, $summary.Result, $totalDispatchers)
if ($errorCount -gt 0) { foreach ($row in $results) { foreach ($e in @($row.Errors)) { Write-Host ('  ' + $row.Guide + ' :: ' + $e) } }; exit 1 }
