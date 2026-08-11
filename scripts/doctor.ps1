#requires -Version 7.0
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
    [string] $HomeRoot,
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

        $statusPaths = @(
            '.',
            ':(exclude).reasonix/desktop-topic-auto-title-meta.json',
            ':(exclude).reasonix/desktop-topic-created-at.json',
            ':(exclude).reasonix/desktop-topic-title-sources.json',
            ':(exclude).reasonix/desktop-topic-titles.json'
        )
        $statusLines = @(& $gitCommand.Source -C $RepoRoot status --porcelain --untracked-files=all -- @statusPaths 2>$null)
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
if ([string]::IsNullOrWhiteSpace($HomeRoot)) { $HomeRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile) }
if ([string]::IsNullOrWhiteSpace($HomeRoot)) {
    Add-DoctorResult -Level 'FAIL' -Message 'User home directory could not be determined.'
}
else {
    Add-DoctorResult -Level 'INFO' -Message 'Live path probing uses the current user home directory.'
    $codexPreferred = Join-Path $HomeRoot '.codex\skills'
    $codexFallback = Join-Path $HomeRoot '.agents\skills'
    $claudeRoot = Join-Path $HomeRoot '.claude'
    $claudeSkills = Join-Path $HomeRoot '.claude\skills'
    $claudePlugins = Join-Path $HomeRoot '.claude\plugins'
    $reasonixSkills = Join-Path $HomeRoot 'AppData\Roaming\reasonix\skills'

    Test-LivePath -Label 'Codex preferred live skills (~/.codex/skills)' -Path $codexPreferred
    Test-LivePath -Label 'Codex fallback live skills (~/.agents/skills)' -Path $codexFallback
    Test-LivePath -Label 'Claude home (~/.claude)' -Path $claudeRoot
    Test-LivePath -Label 'Claude live skills (~/.claude/skills)' -Path $claudeSkills
    Test-LivePath -Label 'Claude plugins (~/.claude/plugins)' -Path $claudePlugins
    Test-LivePath -Label 'Reasonix live skills (%APPDATA%\reasonix\skills)' -Path $reasonixSkills
}

Write-Section -Name 'Generated output'
Add-DoctorResult -Level 'INFO' -Message 'Expected generated layout: claude/skills, codex/skills, reasonix/skills.'
$generatedOutputs = @(
    @{ Label = 'Claude'; RelativePath = 'claude\skills' },
    @{ Label = 'Codex'; RelativePath = 'codex\skills' },
    @{ Label = 'Reasonix'; RelativePath = 'reasonix\skills' }
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
    @{ Label = 'Live Codex preferred .system'; Path = if ($HomeRoot) { Join-Path $HomeRoot '.codex\skills\.system' } else { $null }; Live = $true },
    @{ Label = 'Live Codex fallback .system'; Path = if ($HomeRoot) { Join-Path $HomeRoot '.agents\skills\.system' } else { $null }; Live = $true },
    @{ Label = 'Generated Codex .system'; Path = Join-Path $RepoRoot 'codex\skills\.system'; Live = $false }
)
$systemFound = 0
. (Join-Path $PSScriptRoot 'scan-input-common.ps1')
foreach ($candidate in $systemCandidates) {
    if ([string]::IsNullOrWhiteSpace($candidate.Path)) {
        continue
    }
    $entry = $null
    try { $entry = [AiAgentDotfiles.NoFollowFile]::Inspect([string]$candidate.Path) } catch { continue }
    if ($null -ne $entry) {
        if ($entry.IsReparsePoint) {
            Add-DoctorResult -Level 'WARN' -Message "$($candidate.Label) root entry is a reparse point; preserved-required and manual review apply."
            continue
        }
        if (-not $entry.IsDirectory) {
            Add-DoctorResult -Level 'WARN' -Message "$($candidate.Label) root entry is not a directory; preserved-required and manual review apply."
            continue
        }
        $systemFound++
        Add-DoctorResult -Level 'PASS' -Message "$($candidate.Label) root entry detected with no content traversal: preserved-required."
        if (-not $candidate.Live) {
            Add-DoctorResult -Level 'WARN' -Message "$($candidate.Label) appears inside generated output; inspect the build layout, but do not remove it with doctor."
        }
    }
}
if ($systemFound -eq 0) {
    Add-DoctorResult -Level 'INFO' -Message 'No .system directory was detected in expected generated or live locations.'
}

Write-Section -Name 'Live safety protocol'
$policyPath = Join-Path $RepoRoot 'scripts/live-safety-policy.psd1'
if (-not (Test-Path -LiteralPath $policyPath -PathType Leaf)) {
    Add-DoctorResult -Level 'FAIL' -Message 'Live safety policy is missing.'
}
else {
    $safetyPolicy = Import-PowerShellDataFile -LiteralPath $policyPath
    Add-DoctorResult -Level 'INFO' -Message "Live safety protocol: version $($safetyPolicy.ProtocolVersion), release state $($safetyPolicy.ReleaseState)."
    if ([string]$safetyPolicy.ReleaseState -eq 'interlocked') { Add-DoctorResult -Level 'WARN' -Message 'safety-protocol-upgrade-required: production Apply remains interlocked.' }
}
try {
    . (Join-Path $PSScriptRoot 'approved-runner-common.ps1')
    $runnerContext = Get-RunnerStorageContext -RepoRoot $RepoRoot
    Add-DoctorResult -Level 'INFO' -Message "Pending preview namespace: $($runnerContext.PendingEventsRoot)"
    $pendingCount = if (Test-Path -LiteralPath $runnerContext.PendingEventsRoot -PathType Container) { @(Get-ChildItem -LiteralPath $runnerContext.PendingEventsRoot -File).Count } else { 0 }
    Add-DoctorResult -Level 'INFO' -Message "Pending registered events: $pendingCount"
    if (Test-Path -LiteralPath $runnerContext.ApprovedStatePath -PathType Leaf) {
        $runnerState = Get-ApprovedRunnerState -RepoRoot $RepoRoot
        Add-DoctorResult -Level 'PASS' -Message "Approved runner hash: $($runnerState.ToolchainPolicyHash)"
        $probe = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-doctor-runner-$([Guid]::NewGuid().ToString('N'))"
        try {
            $checkout = Get-RunnerPolicySnapshot -RepoRoot $RepoRoot -DestinationRoot $probe -BindingCommit ([string]$runnerState.ApprovedCommit) -ToolCacheRoot ([string]$runnerState.ToolCacheRoot)
            if ([string]$checkout.ToolchainPolicyHash -ceq [string]$runnerState.ToolchainPolicyHash) { Add-DoctorResult -Level 'PASS' -Message "Checkout runner hash matches approval: $($checkout.ToolchainPolicyHash)" }
            else { Add-DoctorResult -Level 'WARN' -Message 'runner-review-required: checkout toolchain differs from approved runner.' }
        }
        catch { Add-DoctorResult -Level 'WARN' -Message 'runner-review-required: checkout runner hash could not be validated.' }
        finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force } }
    }
    else { Add-DoctorResult -Level 'WARN' -Message 'runner-review-required: no approved runner state exists.' }
}
catch { Add-DoctorResult -Level 'WARN' -Message 'runner-review-required: approved runner metadata is invalid or unavailable.' }

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
