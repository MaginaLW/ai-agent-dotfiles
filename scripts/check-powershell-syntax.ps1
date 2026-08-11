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
$paths = @(& git -C $RepoRoot ls-files -co --exclude-standard)
if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate current-worktree files for syntax validation.' }
$errors = [System.Collections.Generic.List[object]]::new()
$parsed = 0
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
    [void][System.Management.Automation.Language.Parser]::ParseFile($full, [ref]$tokens, [ref]$parseErrors)
    $parsed++
    foreach ($parseError in @($parseErrors)) {
        $errors.Add([pscustomobject]@{ File = $normalized; Line = $parseError.Extent.StartLineNumber; Column = $parseError.Extent.StartColumnNumber; Message = $parseError.Message })
    }
}
if ($errors.Count -gt 0) {
    $errors | Format-Table -AutoSize | Out-String | Write-Host
    Write-Error "PowerShell syntax validation failed: $($errors.Count) parser error(s)." -ErrorAction Continue
    exit 1
}
Write-Host "PowerShell syntax validation passed: $parsed file(s)."
