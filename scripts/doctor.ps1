#requires -Version 7.0
<#
.SYNOPSIS
    Read-only health checks for the ai-agent-dotfiles repository.

.DESCRIPTION
    Checks PowerShell and Git, the repository layout and required scripts, the live skill
    roots (including the Codex root rule and the Codex .system root entry, which is classified
    without traversal), the pinned gitleaks install, the secret scan and working-tree
    cleanliness. It never repairs, builds, deploys or otherwise modifies anything, and it
    prints no live paths.

.PARAMETER RepoRoot
    Repository root to inspect. Defaults to the parent directory of this script.

.PARAMETER HomeRoot
    Home directory used to probe the live skill roots. Defaults to the user profile.

.PARAMETER SkipSecretsScan
    Skips scripts/scan-secrets.ps1 and records a warning.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $HomeRoot = [Environment]::GetFolderPath('UserProfile'),
    [switch] $SkipSecretsScan
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Counts = [ordered]@{ PASS = 0; WARN = 0; FAIL = 0; INFO = 0 }

function Add-DoctorResult([ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')] [string] $Level, [string] $Message) {
    $script:Counts[$Level]++
    $color = @{ PASS = 'Green'; WARN = 'Yellow'; FAIL = 'Red'; INFO = 'Cyan' }[$Level]
    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Write-Section([string] $Name) { Write-Host ''; Write-Host "=== $Name ===" -ForegroundColor Cyan }

function Test-RequiredPath([string] $RelativePath, [ValidateSet('Leaf', 'Container')] [string] $Type) {
    if (Test-Path -LiteralPath (Join-Path $RepoRoot $RelativePath) -PathType $Type) { Add-DoctorResult PASS "$RelativePath exists." }
    else { Add-DoctorResult FAIL "$RelativePath is missing." }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if ([string]::IsNullOrWhiteSpace($HomeRoot)) { throw 'The user home directory could not be determined; pass -HomeRoot.' }
Write-Host 'ai-agent-dotfiles doctor (read-only)' -ForegroundColor White

Write-Section 'Environment'
Add-DoctorResult PASS "PowerShell $($PSVersionTable.PSVersion) is active."
$git = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $git) { Add-DoctorResult FAIL 'Git is not available on PATH.' }
elseif ((& $git.Source -C $RepoRoot rev-parse --is-inside-work-tree 2>$null) -ne 'true') { Add-DoctorResult FAIL 'RepoRoot is not a Git worktree.' }
else { Add-DoctorResult PASS 'Git is available and RepoRoot is a Git worktree.' }

Write-Section 'Repository structure'
foreach ($file in 'AGENTS.md', 'CLAUDE.md', 'STATUS.md') { Test-RequiredPath $file Leaf }
foreach ($dir in 'docs', 'scripts', 'skills-source', 'status\active') { Test-RequiredPath $dir Container }

Write-Section 'Required scripts'
foreach ($name in 'deploy-skills', 'build-skills', 'scan-secrets') { Test-RequiredPath "scripts\$name.ps1" Leaf }

Write-Section 'Live skill roots'
# Same rule as deploy-skills: ~/.agents/skills only when it is the sole Codex root; both is ambiguous.
$codexPreferred = Join-Path $HomeRoot '.codex\skills'
$codexFallback = Join-Path $HomeRoot '.agents\skills'
$hasPreferred = Test-Path -LiteralPath $codexPreferred
$hasFallback = Test-Path -LiteralPath $codexFallback
if ($hasPreferred -and $hasFallback) { Add-DoctorResult WARN 'Codex live root is ambiguous: both ~/.codex/skills and ~/.agents/skills exist, so deploy-skills refuses Codex.' }
elseif ($hasFallback) { Add-DoctorResult PASS 'Codex live root: ~/.agents/skills (fallback; ~/.codex/skills is absent).' }
elseif ($hasPreferred) { Add-DoctorResult PASS 'Codex live root: ~/.codex/skills.' }
else { Add-DoctorResult WARN 'Codex live root not found; deploy-skills would create ~/.codex/skills.' }
foreach ($root in @(
    @{ Label = 'Claude live root (~/.claude/skills)'; Path = Join-Path $HomeRoot '.claude\skills' },
    @{ Label = 'Reasonix live root (%APPDATA%\reasonix\skills)'; Path = Join-Path $HomeRoot 'AppData\Roaming\reasonix\skills' }
)) {
    if (Test-Path -LiteralPath $root.Path -PathType Container) { Add-DoctorResult PASS "$($root.Label) detected." }
    else { Add-DoctorResult WARN "$($root.Label) not found." }
}

Write-Section 'Codex .system protection'
$systemFound = $false
foreach ($candidate in @(
    @{ Label = 'Codex preferred .system'; Path = Join-Path $codexPreferred '.system' },
    @{ Label = 'Codex fallback .system'; Path = Join-Path $codexFallback '.system' }
)) {
    # Get-Item reads only the root entry's attributes; it never opens, lists or follows children.
    $entry = Get-Item -LiteralPath $candidate.Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $entry) { continue }
    $systemFound = $true
    if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { Add-DoctorResult WARN "$($candidate.Label) root entry is a reparse point; it is preserved, not followed, and needs manual review." }
    elseif (-not $entry.PSIsContainer) { Add-DoctorResult WARN "$($candidate.Label) root entry is not a directory; it is preserved and needs manual review." }
    else { Add-DoctorResult PASS "$($candidate.Label) root entry detected with no content traversal: preserved-required." }
}
if (-not $systemFound) { Add-DoctorResult INFO 'No Codex .system directory was detected.' }

Write-Section 'Secret scanning'
$lockPath = Join-Path $RepoRoot 'tools\gitleaks\gitleaks.lock.json'
if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { Add-DoctorResult FAIL 'tools/gitleaks/gitleaks.lock.json is missing.' }
else {
    . (Join-Path $RepoRoot 'scripts\pinned-tool.ps1')
    try {
        $gitleaks = Get-PinnedToolExecutable -LockPath $lockPath
        Add-DoctorResult PASS "Pinned gitleaks $($gitleaks.Lock.Version) is installed and hash-verified."
    }
    catch {
        Write-Verbose "Pinned gitleaks check: $($_.Exception.Message)"
        Add-DoctorResult WARN 'Pinned gitleaks is not installed or failed verification; run scripts/install-gitleaks.ps1.'
    }
}
if ($SkipSecretsScan) { Add-DoctorResult WARN 'Secrets scan skipped by -SkipSecretsScan.' }
else {
    # Scan output is suppressed so doctor never prints sensitive content.
    $null = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\scan-secrets.ps1') -RepoRoot $RepoRoot 2>&1
    if ($LASTEXITCODE -eq 0) { Add-DoctorResult PASS 'Secrets scan completed successfully.' }
    else { Add-DoctorResult FAIL "Secrets scan failed (exit $LASTEXITCODE). Run scripts/scan-secrets.ps1 directly for redacted details." }
}

Write-Section 'Working tree'
if ($null -ne $git) {
    $statusPaths = @('.') + @('auto-title-meta', 'created-at', 'title-sources', 'titles' | ForEach-Object { ":(exclude).reasonix/desktop-topic-$_.json" })
    $statusLines = @(& $git.Source -C $RepoRoot status --porcelain --untracked-files=all -- @statusPaths 2>$null)
    if ($LASTEXITCODE -ne 0) { Add-DoctorResult FAIL 'Git status could not be read.' }
    elseif ($statusLines.Count -eq 0) { Add-DoctorResult PASS 'Git working tree is clean.' }
    else { Add-DoctorResult WARN "Git working tree is not clean ($($statusLines.Count) entries)." }
}

Write-Section 'Summary'
Write-Host (($script:Counts.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ') -ForegroundColor White
if ($script:Counts.FAIL -gt 0) { Write-Host 'Doctor result: FAIL' -ForegroundColor Red; exit 1 }
if ($script:Counts.WARN -gt 0) { Write-Host 'Doctor result: PASS with warnings' -ForegroundColor Yellow }
else { Write-Host 'Doctor result: PASS' -ForegroundColor Green }
exit 0
