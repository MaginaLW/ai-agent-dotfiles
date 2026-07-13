#requires -Version 5.1
<#
.SYNOPSIS
    Performs read-only health checks for the ai-agent-dotfiles repository.

.DESCRIPTION
    Reports environment, repository structure, required scripts, live skill paths,
    generated output, Codex .system protection, and the repository secret scan.
    This script does not repair, copy, delete, build, sync, or otherwise modify files.

.PARAMETER RepoRoot
    Repository root to inspect. Defaults to the parent directory of this script.

.PARAMETER SkipSecretsScan
    Skips scripts/scan-secrets.ps1 and records a warning.

.PARAMETER JsonPath
    Optional path for a safe machine-readable summary. The JSON contains counts
    and result status, but no live paths or diagnostic message contents.

.NOTES
    Designed for PowerShell 7 and intentionally written with Windows PowerShell 5.1
    compatible syntax. The repository secret scanner itself requires PowerShell 7;
    when doctor runs under Windows PowerShell 5.1 it launches pwsh for that check.
    The standard -Verbose common parameter enables extra non-sensitive diagnostics.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [switch] $SkipSecretsScan,
    [string] $JsonPath
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:PassCount = 0
$script:WarnCount = 0
$script:FailCount = 0
$script:InfoCount = 0

function Write-DoctorJson {
    param([Parameter(Mandatory = $true)] [string] $Path)

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $result = if ($script:FailCount -gt 0) { 'FAIL' } elseif ($script:WarnCount -gt 0) { 'WARN' } else { 'PASS' }
    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Result = $result
        Counts = [ordered]@{
            Pass = $script:PassCount
            Warn = $script:WarnCount
            Fail = $script:FailCount
            Info = $script:InfoCount
        }
        SecretsScanSkipped = [bool] $SkipSecretsScan
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
}

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
}

function Write-Section {
    param([Parameter(Mandatory = $true)] [string] $Name)

    Write-Host ''
    Write-Host "=== $Name ===" -ForegroundColor Cyan
}

function Add-DoctorResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string] $Level,

        [Parameter(Mandatory = $true)]
        [string] $Message
    )

    $color = 'Gray'
    switch ($Level) {
        'PASS' { $script:PassCount++; $color = 'Green' }
        'WARN' { $script:WarnCount++; $color = 'Yellow' }
        'FAIL' { $script:FailCount++; $color = 'Red' }
        'INFO' { $script:InfoCount++; $color = 'Cyan' }
    }

    Write-Host "[$Level] $Message" -ForegroundColor $color
}

function Test-RequiredPath {
    param(
        [Parameter(Mandatory = $true)] [string] $RelativePath,
        [Parameter(Mandatory = $true)] [ValidateSet('File', 'Directory')] [string] $ExpectedType,
        [ValidateSet('WARN', 'FAIL')] [string] $MissingLevel = 'FAIL'
    )

    $fullPath = Join-Path $RepoRoot $RelativePath
    $pathType = if ($ExpectedType -eq 'File') { 'Leaf' } else { 'Container' }
    if (Test-Path -LiteralPath $fullPath -PathType $pathType) {
        Add-DoctorResult -Level 'PASS' -Message "$RelativePath exists ($ExpectedType)."
        Write-Verbose "Resolved path: $fullPath"
    }
    else {
        Add-DoctorResult -Level $MissingLevel -Message "$RelativePath is missing or is not a $ExpectedType."
    }
}

function Test-LivePath {
    param(
        [Parameter(Mandatory = $true)] [string] $Label,
        [Parameter(Mandatory = $true)] [string] $Path
    )

    if (Test-Path -LiteralPath $Path -PathType Container) {
        Add-DoctorResult -Level 'PASS' -Message "$Label detected."
        Write-Verbose "$Label path: $Path"
    }
    else {
        Add-DoctorResult -Level 'WARN' -Message "$Label not found."
        Write-Verbose "$Label expected path: $Path"
    }
}

try {
    $resolvedRepoRoot = Resolve-Path -LiteralPath $RepoRoot -ErrorAction Stop
    $RepoRoot = $resolvedRepoRoot.Path
}
catch {
    Add-DoctorResult -Level 'FAIL' -Message "Repository root cannot be resolved: $RepoRoot"
    Write-Section -Name 'Summary'
    Add-DoctorResult -Level 'INFO' -Message "PASS=$script:PassCount WARN=$script:WarnCount FAIL=$script:FailCount INFO=$script:InfoCount"
    exit 1
}

Write-Host 'ai-agent-dotfiles doctor (read-only)' -ForegroundColor White
Write-Verbose "Repository root: $RepoRoot"

Write-Section -Name 'Basic environment'
$osDescription = [System.Environment]::OSVersion.VersionString
Add-DoctorResult -Level 'INFO' -Message "Operating system: $osDescription"
Add-DoctorResult -Level 'INFO' -Message "Current username: $([System.Environment]::UserName)"

$computerName = $env:COMPUTERNAME
if ([string]::IsNullOrWhiteSpace($computerName)) {
    $computerName = [System.Environment]::MachineName
}
Add-DoctorResult -Level 'INFO' -Message "COMPUTERNAME: $computerName"
Add-DoctorResult -Level 'INFO' -Message "Current working directory: $((Get-Location).Path)"
Add-DoctorResult -Level 'INFO' -Message "PowerShell version: $($PSVersionTable.PSVersion)"

if ($PSVersionTable.PSVersion.Major -ge 7) {
    Add-DoctorResult -Level 'PASS' -Message 'PowerShell 7+ is active.'
}
else {
    Add-DoctorResult -Level 'WARN' -Message 'Windows PowerShell 5.1 compatibility mode is active; repository scripts may require pwsh.'
}

$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($null -eq $gitCommand) {
    Add-DoctorResult -Level 'FAIL' -Message 'Git is not available on PATH.'
}
else {
    Add-DoctorResult -Level 'PASS' -Message "Git is available: $($gitCommand.Source)"
    $insideWorkTree = & $gitCommand.Source -C $RepoRoot rev-parse --is-inside-work-tree 2>$null
    $insideWorkTreeExit = $LASTEXITCODE
    if ($insideWorkTreeExit -ne 0 -or ($insideWorkTree -join '').Trim() -ne 'true') {
        Add-DoctorResult -Level 'FAIL' -Message 'RepoRoot is not a Git worktree.'
    }
    else {
        $branch = & $gitCommand.Source -C $RepoRoot rev-parse --abbrev-ref HEAD 2>$null
        $branchExit = $LASTEXITCODE
        if ($branchExit -ne 0) {
            Add-DoctorResult -Level 'FAIL' -Message 'Current Git branch could not be determined.'
        }
        elseif (($branch -join '').Trim() -eq 'HEAD') {
            Add-DoctorResult -Level 'WARN' -Message 'Git is in detached HEAD state.'
        }
        else {
            Add-DoctorResult -Level 'INFO' -Message "Current Git branch: $(($branch -join '').Trim())"
        }

        $statusLines = @(& $gitCommand.Source -C $RepoRoot status --porcelain --untracked-files=all 2>$null)
        $statusExit = $LASTEXITCODE
        if ($statusExit -ne 0) {
            Add-DoctorResult -Level 'FAIL' -Message 'Git status could not be read.'
        }
        elseif ($statusLines.Count -eq 0) {
            Add-DoctorResult -Level 'PASS' -Message 'Git working tree is clean.'
        }
        else {
            Add-DoctorResult -Level 'WARN' -Message "Git working tree is not clean ($($statusLines.Count) entries)."
            Write-Verbose 'Git status entries are intentionally not printed by doctor.'
        }
    }
}

Write-Section -Name 'Repository structure'
$requiredStructure = @(
    @{ Path = 'AGENTS.md'; Type = 'File'; Missing = 'FAIL' },
    @{ Path = 'CLAUDE.md'; Type = 'File'; Missing = 'FAIL' },
    @{ Path = 'STATUS.md'; Type = 'File'; Missing = 'FAIL' },
    @{ Path = 'docs'; Type = 'Directory'; Missing = 'FAIL' },
    @{ Path = 'scripts'; Type = 'Directory'; Missing = 'FAIL' },
    @{ Path = 'skills-source'; Type = 'Directory'; Missing = 'FAIL' },
    @{ Path = 'imports'; Type = 'Directory'; Missing = 'FAIL' },
    @{ Path = 'status'; Type = 'Directory'; Missing = 'FAIL' },
    @{ Path = 'status\active'; Type = 'Directory'; Missing = 'FAIL' },
    @{ Path = 'status\archived'; Type = 'Directory'; Missing = 'FAIL' }
)
foreach ($item in $requiredStructure) {
    Test-RequiredPath -RelativePath $item.Path -ExpectedType $item.Type -MissingLevel $item.Missing
}

Write-Section -Name 'Required scripts'
foreach ($scriptPath in @(
    'scripts\backup.ps1',
    'scripts\sync.ps1',
    'scripts\build-skills.ps1',
    'scripts\scan-secrets.ps1'
)) {
    Test-RequiredPath -RelativePath $scriptPath -ExpectedType 'File' -MissingLevel 'FAIL'
}

Write-Section -Name 'Live skills path detection'
$homeRoot = $HOME
if ([string]::IsNullOrWhiteSpace($homeRoot)) {
    $homeRoot = $env:USERPROFILE
}
if ([string]::IsNullOrWhiteSpace($homeRoot)) {
    Add-DoctorResult -Level 'FAIL' -Message 'User home directory could not be determined.'
}
else {
    Add-DoctorResult -Level 'INFO' -Message 'Live path probing uses the current user home directory.'
    $codexPreferred = Join-Path $homeRoot '.codex\skills'
    $codexFallback = Join-Path $homeRoot '.agents\skills'
    $claudeRoot = Join-Path $homeRoot '.claude'
    $claudeSkills = Join-Path $homeRoot '.claude\skills'
    $claudePlugins = Join-Path $homeRoot '.claude\plugins'
    $openclawSkills = Join-Path $homeRoot '.openclaw\skills'
    $openclawWorkspaceSkills = Join-Path $homeRoot '.openclaw\workspace\skills'

    Test-LivePath -Label 'Codex preferred live skills (~/.codex/skills)' -Path $codexPreferred
    Test-LivePath -Label 'Codex fallback live skills (~/.agents/skills)' -Path $codexFallback
    Test-LivePath -Label 'Claude home (~/.claude)' -Path $claudeRoot
    Test-LivePath -Label 'Claude live skills (~/.claude/skills)' -Path $claudeSkills
    Test-LivePath -Label 'Claude plugins (~/.claude/plugins)' -Path $claudePlugins
    Test-LivePath -Label 'OpenClaw live skills (~/.openclaw/skills)' -Path $openclawSkills
    Test-LivePath -Label 'OpenClaw workspace skills (~/.openclaw/workspace/skills)' -Path $openclawWorkspaceSkills
}

Write-Section -Name 'Generated output'
Add-DoctorResult -Level 'INFO' -Message 'Expected generated layout: claude/skills, codex/skills, openclaw/skills.'
$generatedOutputs = @(
    @{ Label = 'Claude'; RelativePath = 'claude\skills' },
    @{ Label = 'Codex'; RelativePath = 'codex\skills' },
    @{ Label = 'OpenClaw'; RelativePath = 'openclaw\skills' }
)
foreach ($output in $generatedOutputs) {
    $generatedPath = Join-Path $RepoRoot $output.RelativePath
    if (Test-Path -LiteralPath $generatedPath -PathType Container) {
        Add-DoctorResult -Level 'PASS' -Message "$($output.Label) generated output detected at $($output.RelativePath)."
        Write-Verbose "$($output.Label) generated output: $generatedPath"
    }
    else {
        Add-DoctorResult -Level 'WARN' -Message "$($output.Label) generated output is missing at $($output.RelativePath); run scripts/build-skills.ps1."
    }
}

Write-Section -Name '.system protection'
$systemCandidates = @(
    @{ Label = 'Live Codex preferred .system'; Path = if ($homeRoot) { Join-Path $homeRoot '.codex\skills\.system' } else { $null }; MarkerExpected = $true },
    @{ Label = 'Live Codex fallback .system'; Path = if ($homeRoot) { Join-Path $homeRoot '.agents\skills\.system' } else { $null }; MarkerExpected = $true },
    @{ Label = 'Generated Codex .system'; Path = Join-Path $RepoRoot 'codex\skills\.system'; MarkerExpected = $false }
)
$systemFound = 0
foreach ($candidate in $systemCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate.Path)) {
        continue
    }
    if (Test-Path -LiteralPath $candidate.Path -PathType Container) {
        $systemFound++
        Add-DoctorResult -Level 'PASS' -Message "$($candidate.Label) detected: preserved-required; doctor did not modify it."
        if ($candidate.MarkerExpected) {
            $marker = Join-Path $candidate.Path '.codex-system-skills.marker'
            if (Test-Path -LiteralPath $marker -PathType Leaf) {
                Add-DoctorResult -Level 'PASS' -Message "$($candidate.Label) marker is present."
            }
            else {
                Add-DoctorResult -Level 'WARN' -Message "$($candidate.Label) exists but its platform marker is missing; preserved-required still applies."
            }
        }
        else {
            Add-DoctorResult -Level 'WARN' -Message "$($candidate.Label) appears inside generated output; inspect the build layout, but do not remove it with doctor."
        }
    }
}
if ($systemFound -eq 0) {
    Add-DoctorResult -Level 'INFO' -Message 'No .system directory was detected in expected generated or live locations.'
}

Write-Section -Name 'Secrets scan'
$scanScript = Join-Path $RepoRoot 'scripts\scan-secrets.ps1'
if ($SkipSecretsScan) {
    Add-DoctorResult -Level 'WARN' -Message 'Secrets scan skipped by -SkipSecretsScan.'
}
elseif (-not (Test-Path -LiteralPath $scanScript -PathType Leaf)) {
    Add-DoctorResult -Level 'FAIL' -Message 'Secrets scan script is missing; scan could not run.'
}
else {
    $scanOutput = @()
    $scanExitCode = 1
    $pwshCommand = Get-Command pwsh -ErrorAction SilentlyContinue
    try {
        if ($null -ne $pwshCommand) {
            $scanOutput = @(& $pwshCommand.Source -NoProfile -File $scanScript -RepoRoot $RepoRoot 2>&1)
            $scanExitCode = $LASTEXITCODE
        }
        elseif ($PSVersionTable.PSVersion.Major -ge 7) {
            $scanOutput = @(& $scanScript -RepoRoot $RepoRoot 2>&1)
            $scanExitCode = if ($?) { 0 } else { 1 }
        }
        else {
            Add-DoctorResult -Level 'FAIL' -Message 'Secrets scan requires PowerShell 7, but pwsh is not available.'
            $scanExitCode = 1
        }
    }
    catch {
        $scanOutput = @()
        $scanExitCode = 1
        Write-Verbose "Secrets scan invocation failed: $($_.Exception.Message)"
    }

    Write-Verbose "Secrets scan output was captured and suppressed ($($scanOutput.Count) lines) to avoid printing sensitive content."
    if ($scanExitCode -eq 0) {
        Add-DoctorResult -Level 'PASS' -Message 'Secrets scan completed successfully.'
    }
    else {
        Add-DoctorResult -Level 'FAIL' -Message "Secrets scan failed (exit $scanExitCode). Run scripts/scan-secrets.ps1 directly for redacted diagnostic details."
    }
}

Write-Section -Name 'Summary'
Write-Host "PASS=$script:PassCount WARN=$script:WarnCount FAIL=$script:FailCount INFO=$script:InfoCount" -ForegroundColor White
if ($script:FailCount -gt 0) {
    Write-Host 'Doctor result: FAIL' -ForegroundColor Red
    if ($JsonPath) { Write-DoctorJson -Path $JsonPath }
    exit 1
}

if ($script:WarnCount -gt 0) {
    Write-Host 'Doctor result: PASS with warnings' -ForegroundColor Yellow
}
else {
    Write-Host 'Doctor result: PASS' -ForegroundColor Green
}
if ($JsonPath) { Write-DoctorJson -Path $JsonPath }
exit 0
