#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [switch] $CanonicalPreflight,
    [string] $CandidateWorkspace,
    [string] $SourceRoot,
    [string] $ClaudeOutputRoot,
    [string] $CodexOutputRoot,
    [string] $ReasonixOutputRoot,
    [string] $ManifestOutputRoot,
    [string] $CanonicalPreflightOutputRoot,
    [string] $JsonPath,
    [string] $ValidatorCacheRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$preflightHelper = Join-Path $PSScriptRoot 'canonical-preflight-common.ps1'
$reportHelper = Join-Path $PSScriptRoot 'report-common.ps1'
. $preflightHelper
if (Test-Path -LiteralPath $reportHelper) { . $reportHelper }
else { Write-Warning "Report helper missing: $reportHelper" }

function Test-SameOrDescendant {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Root)
    return Test-PathInsideRoot -Path ([System.IO.Path]::GetFullPath($Path)) -Root ([System.IO.Path]::GetFullPath($Root))
}

function Assert-DisjointBuildRoots {
    param([Parameter(Mandatory)][string[]]$Roots)
    for ($i = 0; $i -lt $Roots.Count; $i++) {
        for ($j = $i + 1; $j -lt $Roots.Count; $j++) {
            if ((Test-SameOrDescendant -Path $Roots[$i] -Root $Roots[$j]) -or (Test-SameOrDescendant -Path $Roots[$j] -Root $Roots[$i])) {
                throw "Canonical preflight build roots overlap: $($Roots[$i]) and $($Roots[$j])"
            }
        }
    }
}

$customNames = @('CandidateWorkspace','SourceRoot','ClaudeOutputRoot','CodexOutputRoot','ReasonixOutputRoot','ManifestOutputRoot','CanonicalPreflightOutputRoot','JsonPath','ValidatorCacheRoot')
if (-not $CanonicalPreflight) {
    foreach ($name in $customNames) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "$name is internal to -CanonicalPreflight." }
    }
    $SourceRoot = Join-Path $RepoRoot 'skills-source'
    $ClaudeOutputRoot = Join-Path $RepoRoot 'claude/skills'
    $CodexOutputRoot = Join-Path $RepoRoot 'codex/skills'
    $ReasonixOutputRoot = Join-Path $RepoRoot 'reasonix/skills'
    $ManifestOutputRoot = Join-Path $RepoRoot 'manifests'
}
else {
    foreach ($name in @('CandidateWorkspace','SourceRoot','ClaudeOutputRoot','CodexOutputRoot','ReasonixOutputRoot','ManifestOutputRoot','CanonicalPreflightOutputRoot','JsonPath')) {
        if (-not $PSBoundParameters.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) {
            throw "-CanonicalPreflight requires -$name."
        }
    }
    $CandidateWorkspace = (Resolve-Path -LiteralPath $CandidateWorkspace).Path
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
    $ClaudeOutputRoot = [System.IO.Path]::GetFullPath($ClaudeOutputRoot)
    $CodexOutputRoot = [System.IO.Path]::GetFullPath($CodexOutputRoot)
    $ReasonixOutputRoot = [System.IO.Path]::GetFullPath($ReasonixOutputRoot)
    $ManifestOutputRoot = [System.IO.Path]::GetFullPath($ManifestOutputRoot)
    $CanonicalPreflightOutputRoot = [System.IO.Path]::GetFullPath($CanonicalPreflightOutputRoot)
    $JsonPath = [System.IO.Path]::GetFullPath($JsonPath)

    foreach ($root in @($SourceRoot,$ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot,$ManifestOutputRoot)) {
        if (-not (Test-SameOrDescendant -Path $root -Root $CandidateWorkspace) -or $root -ceq $CandidateWorkspace) {
            throw "Canonical preflight build root is outside CandidateWorkspace: $root"
        }
    }
    Assert-DisjointBuildRoots -Roots @($SourceRoot,$ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot,$ManifestOutputRoot)
    if ((Test-SameOrDescendant -Path $CanonicalPreflightOutputRoot -Root $CandidateWorkspace) -or (Test-SameOrDescendant -Path $CandidateWorkspace -Root $CanonicalPreflightOutputRoot)) {
        throw 'CanonicalPreflightOutputRoot and CandidateWorkspace must be disjoint.'
    }
    $null = Resolve-CanonicalPreflightArtifactPath -Path $JsonPath -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -RepoRoot $RepoRoot -ForbiddenRoots @($CandidateWorkspace) -AllowMissingLeaf
    foreach ($root in @($ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot,$ManifestOutputRoot)) {
        if (Test-Path -LiteralPath $root) { throw "Canonical preflight build output must be create-new: $root" }
    }
    $null = Get-SafeTreeSnapshot -Root $SourceRoot
}

$script:BuildResultWritten = $false
function Write-BuildRunReport {
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [string] $NextAction,
        [string[]] $Conflicts = @(),
        [string[]] $ClaudeSkills = @(),
        [string[]] $CodexSkills = @(),
        [string[]] $ReasonixSkills = @()
    )

    $summary = [ordered]@{
        Added = 'Not available (build recreates isolated output)'
        Modified = 'Not available (build recreates isolated output)'
        Removed = 'Not available (build recreates isolated output)'
        Skipped = 'Not available'
        Conflicts = $Conflicts.Count
        Quarantined = 'Not available'
        'Unknown live skills' = 'Not applicable'
        '.system status' = 'preserved by exclusion; build does not manage .system'
        'Secrets scan result' = 'Not run by build-skills.ps1'
    }
    $details = [ordered]@{
        'Claude generated skill set' = @($ClaudeSkills | Sort-Object)
        'Codex generated skill set' = @($CodexSkills | Sort-Object)
        'Reasonix generated skill set' = @($ReasonixSkills | Sort-Object)
        Conflicts = @($Conflicts | Sort-Object)
        'Removed items' = @('Not available; generated roots are recreated and no previous snapshot is compared.')
        '.system' = @('PRESERVED: .system is not a build source or generated skill.')
    }

    if ($CanonicalPreflight) {
        if ($script:BuildResultWritten) { throw 'Canonical preflight build result may only be published once.' }
        $document = [ordered]@{
            SchemaVersion = 1
            ReportKind = 'build'
            GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
            Machine = 'redacted'
            Git = [ordered]@{ Branch='Not available'; Commit='Not available' }
            ScriptName = 'scripts/build-skills.ps1'
            Mode = 'canonical-preflight'
            Summary = $summary
            Details = $details
            Result = $Result
            NextAction = $NextAction
        }
        $null = Publish-ValidatedPreflightJson -Document $document -Path $JsonPath -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
        $script:BuildResultWritten = $true
        Write-Host "Build result: $JsonPath"
        return
    }

    if (-not (Get-Command Write-RunReport -ErrorAction SilentlyContinue)) { return }
    try {
        $reportPath = Write-RunReport -RepoRoot $RepoRoot -ReportKind build -ScriptName 'scripts/build-skills.ps1' -Mode build -Summary $summary -Details $details -Result $Result -NextAction $NextAction
        Write-Host "Build report: $reportPath"
    }
    catch { Write-Warning "Build completed its original flow, but report creation failed: $($_.Exception.Message)" }
}

function Get-SkillDirectories {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') })
}

$script:RuntimeExcludePatterns = @('MERGE_NOTES.md', 'CREATION-LOG.md', '*.magina-laptop.*')
function Copy-SkillDirectory {
    param([Parameter(Mandatory)] [System.IO.DirectoryInfo] $Source, [Parameter(Mandatory)] [string] $DestinationRoot)
    $destination = Join-Path $DestinationRoot $Source.Name
    $null = Copy-SafeTree -SourceRoot $Source.FullName -DestinationRoot $destination
    $snapshot = Get-SafeTreeSnapshot -Root $destination
    foreach ($row in @($snapshot.ContentTreeRows | Where-Object Type -eq 'File')) {
        $leaf = [System.IO.Path]::GetFileName([string]$row.RelativePath)
        if (@($script:RuntimeExcludePatterns | Where-Object { $leaf -like $_ }).Count -gt 0) {
            Remove-Item -LiteralPath (Join-Path $destination ([string]$row.RelativePath)) -Force
        }
    }
}

function Write-ManifestFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Names)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { [System.IO.Directory]::CreateDirectory($dir) | Out-Null }
    $sorted = @($Names | Sort-Object -Unique)
    $content = if ($sorted.Count -gt 0) { ($sorted -join "`n") + "`n" } else { '' }
    [System.IO.File]::WriteAllText($Path, $content, [System.Text.UTF8Encoding]::new($false))
}

$sharedSource = Join-Path $SourceRoot 'shared'
$claudeOnlySource = Join-Path $SourceRoot 'claude-only'
$codexOnlySource = Join-Path $SourceRoot 'codex-only'
$reasonixOnlySource = Join-Path $SourceRoot 'reasonix-only'
$sharedSkills = Get-SkillDirectories -Path $sharedSource
$claudeOnlySkills = Get-SkillDirectories -Path $claudeOnlySource
$codexOnlySkills = Get-SkillDirectories -Path $codexOnlySource
$reasonixOnlySkills = Get-SkillDirectories -Path $reasonixOnlySource
$sharedNames = @($sharedSkills | ForEach-Object Name)
$claudeOnlyNames = @($claudeOnlySkills | ForEach-Object Name)
$codexOnlyNames = @($codexOnlySkills | ForEach-Object Name)
$reasonixOnlyNames = @($reasonixOnlySkills | ForEach-Object Name)

$sharedConflicts = @(
    @($claudeOnlyNames | Where-Object { $_ -in $sharedNames }) +
    @($codexOnlyNames | Where-Object { $_ -in $sharedNames }) +
    @($reasonixOnlyNames | Where-Object { $_ -in $sharedNames }) |
        Sort-Object -Unique
)
if ($sharedConflicts.Count -gt 0) {
    Write-Host 'ERROR: Skill name conflict between shared and platform-only sources.'
    $sharedConflicts | ForEach-Object { Write-Host "Conflict: $_ (in shared and platform-only)" }
    Write-BuildRunReport -Result FAIL -NextAction 'Resolve shared/platform-only name conflicts, then rerun the build.' -Conflicts $sharedConflicts
    exit 1
}

$platformOnlyAll = @{}
foreach ($n in $claudeOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n]=@() }; $platformOnlyAll[$n]+='claude-only' }
foreach ($n in $codexOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n]=@() }; $platformOnlyAll[$n]+='codex-only' }
foreach ($n in $reasonixOnlyNames) { if (-not $platformOnlyAll.ContainsKey($n)) { $platformOnlyAll[$n]=@() }; $platformOnlyAll[$n]+='reasonix-only' }
$crossPlatformConflicts = @($platformOnlyAll.GetEnumerator() | Where-Object { $_.Value.Count -gt 1 })
if ($crossPlatformConflicts.Count -gt 0) {
    $conflictNames = @($crossPlatformConflicts | ForEach-Object Key | Sort-Object)
    Write-Host 'ERROR: Skill name appears in more than one platform-only source.'
    $crossPlatformConflicts | ForEach-Object { Write-Host "Conflict: $($_.Key) in [$($_.Value -join ', ')]" }
    Write-BuildRunReport -Result FAIL -NextAction 'Resolve cross-platform-only name conflicts, then rerun the build.' -Conflicts $conflictNames
    exit 1
}

$claudeSet = @($sharedNames + $claudeOnlyNames | Sort-Object -Unique)
$codexSet = @($sharedNames + $codexOnlyNames | Sort-Object -Unique)
$reasonixSet = @($sharedNames + $reasonixOnlyNames | Sort-Object -Unique)
$unionSet = @($claudeSet + $codexSet + $reasonixSet | Sort-Object -Unique)

foreach ($target in @($ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot)) {
    if (Test-Path -LiteralPath $target) {
        if ($CanonicalPreflight) { throw "Canonical preflight output unexpectedly exists: $target" }
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    [System.IO.Directory]::CreateDirectory($target) | Out-Null
}
if ($CanonicalPreflight -and (Test-Path -LiteralPath $ManifestOutputRoot)) { throw "Canonical preflight manifest root unexpectedly exists: $ManifestOutputRoot" }
if (-not (Test-Path -LiteralPath $ManifestOutputRoot)) { [System.IO.Directory]::CreateDirectory($ManifestOutputRoot) | Out-Null }

foreach ($skill in $sharedSkills) {
    Copy-SkillDirectory -Source $skill -DestinationRoot $ClaudeOutputRoot
    Copy-SkillDirectory -Source $skill -DestinationRoot $CodexOutputRoot
    Copy-SkillDirectory -Source $skill -DestinationRoot $ReasonixOutputRoot
}
foreach ($skill in $claudeOnlySkills) { Copy-SkillDirectory -Source $skill -DestinationRoot $ClaudeOutputRoot }
foreach ($skill in $codexOnlySkills) { Copy-SkillDirectory -Source $skill -DestinationRoot $CodexOutputRoot }
foreach ($skill in $reasonixOnlySkills) { Copy-SkillDirectory -Source $skill -DestinationRoot $ReasonixOutputRoot }

Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.claude.txt') -Names $claudeSet
Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.codex.txt') -Names $codexSet
Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.reasonix.txt') -Names $reasonixSet
Write-ManifestFile -Path (Join-Path $ManifestOutputRoot 'managed-skills.txt') -Names $unionSet

$builtClaudeSkills = @(Get-SkillDirectories -Path $ClaudeOutputRoot)
$builtCodexSkills = @(Get-SkillDirectories -Path $CodexOutputRoot)
$builtReasonixSkills = @(Get-SkillDirectories -Path $ReasonixOutputRoot)
Write-Host "Built Claude skills: $($builtClaudeSkills.Count)"
Write-Host "Built Codex skills: $($builtCodexSkills.Count)"
Write-Host "Built Reasonix skills: $($builtReasonixSkills.Count)"
Write-Host "Updated manifests: $ManifestOutputRoot"
Write-BuildRunReport -Result PASS -NextAction 'Run scripts/scan-secrets.ps1, then review the canonical transaction plan.' `
    -ClaudeSkills @($builtClaudeSkills | ForEach-Object Name) `
    -CodexSkills @($builtCodexSkills | ForEach-Object Name) `
    -ReasonixSkills @($builtReasonixSkills | ForEach-Object Name)
