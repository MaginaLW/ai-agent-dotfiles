#requires -Version 7.0
<#
.SYNOPSIS
    Build the staging output for one harness environment under envs/<name>/.

.DESCRIPTION
    Resolves the named env definition (harness-source/envs/<name>.psd1), verifies
    that every referenced skill already exists in the generated output roots
     (claude/skills/, codex/skills/, reasonix/skills/ — run scripts/build-skills.ps1 first), then
    materializes a disposable staging tree at envs/<name>/:

        claude/skills/<skill>/   copied from claude/skills/<skill>/
        codex/skills/<skill>/    copied from codex/skills/<skill>/
        reasonix/skills/<skill>/ copied from reasonix/skills/<skill>/
        manifest.claude.txt      env's Claude skill names, one per line, sorted
        manifest.codex.txt       env's Codex skill names, one per line, sorted
        manifest.reasonix.txt     env's Reasonix skill names, one per line, sorted
        manifests/managed-skills.claude.txt   FULL repo manifest copy
        manifests/managed-skills.codex.txt    FULL repo manifest copy
        manifests/managed-skills.reasonix.txt FULL repo manifest copy
        profile/                 rendered profile component outputs
        env.lock.json            { source provenance, staged hashes, BuiltFiles }
        env-build.json           schema-3 sidecar (MaterializationHash; not in the lock)

    The manifests/ copies are deliberately the FULL repo manifests, not the env
    subset: when sync.ps1 runs with -RepoRoot pointed at this staging tree, its
    manifest-scoped prune then removes live skills that are repo-managed but not
    part of this env — that is what makes switching to a smaller env shed the
    larger env's skills while unknown live dirs and Codex .system stay untouched.

    The profile/ tree is rendered directly from the env's resolved profile chain
    (Resolve-HarnessEnvDefinition), mirroring build-harness-profile.ps1's output
    rules: ManagedBlock targets become <name>.generated.md files of managed-block
    text, StructuredMerge targets become merged .generated.json files, and
    GeneratedOnly targets are copied under profile/ minus their
    .agent-harness/generated/ prefix. New-HarnessProfilePlan is not used because
    it requires a project profile (.agent-harness/profile.psd1), which env builds
    do not have.

    All validation happens before any write: on failure nothing is created or
    deleted. The staging directory envs/<name>/ is cleared and recreated on each
    build; a defensive assertion refuses to delete anything outside <repo>\envs\.
    This script never writes outside envs/<name>/ — no home files, no state/.

.PARAMETER Name
    Env name (bare identifier, matches harness-source/envs/<Name>.psd1).

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER JsonPath
    Optional machine-readable build summary path. The summary contains hashes
    and counts only; it never contains staged file contents or full paths.

.PARAMETER TaskOverlayPath
    Optional task skill overlay path. Defaults to
    .agent-harness/task-skills.psd1 under the repository. An overlay targeting a
    different environment is ignored for this build.

.OUTPUTS
    Summary lines (env name, file count, staging path). Non-zero exit on any
    validation or build failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $JsonPath,
    [string] $TaskOverlayPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$staging = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $Name

$definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$Name.psd1"
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
    throw "Unknown env '$Name': expected definition at $definitionPath"
}
$definition = Read-HarnessEnvDefinition -Path $definitionPath
$taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $Name -Path $TaskOverlayPath
$effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $taskOverlay
$null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition

$generatedRoots = @{ Claude = 'claude/skills'; Codex = 'codex/skills'; Reasonix = 'reasonix/skills' }
$missingSkills = [System.Collections.Generic.List[string]]::new()
foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
    $names = @()
    if ($effectiveDefinition.Skills.ContainsKey($platform)) {
        $names = @($effectiveDefinition.Skills[$platform] | ForEach-Object { [string] $_ })
    }
    foreach ($skill in $names) {
        if ($skill -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Env '$Name' $platform skill name must be a bare identifier, not a path: $skill"
        }
        $skillDir = Join-Path $repo "$($generatedRoots[$platform])/$skill"
        if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) {
            $missingSkills.Add("$($generatedRoots[$platform])/$skill")
        }
    }
}
if ($missingSkills.Count -gt 0) {
    throw "Env '$Name' references skills with no generated output: $($missingSkills -join ', '). Run scripts/build-skills.ps1 first."
}

# --- Clear and recreate staging (defensive: must live under <repo>\envs\) ----
$envsRoot = [System.IO.Path]::GetFullPath((Join-Path $repo 'envs'))
$stagingFull = [System.IO.Path]::GetFullPath($staging)
$comparison = [System.StringComparison]::OrdinalIgnoreCase
$expectedPrefix = $envsRoot.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if (-not $stagingFull.StartsWith($expectedPrefix, $comparison) -or $stagingFull.Equals($envsRoot, $comparison)) {
    throw "Refusing to clear staging path outside $expectedPrefix : $stagingFull"
}
if (Test-Path -LiteralPath $stagingFull) {
    Remove-Item -LiteralPath $stagingFull -Recurse -Force
}
New-Item -ItemType Directory -Path $stagingFull -Force | Out-Null

$result = Invoke-HarnessEnvMaterialization -Name $Name -Destination $stagingFull -RepoRoot $repo -TaskOverlayPath $TaskOverlayPath

Write-Output 'Harness env build complete'
Write-Output "Environment: $($result.Name)"
if ($result.TaskOverlay.Present) {
    Write-Output "Task overlay: $($result.TaskOverlay.Path) (+$(@($result.TaskOverlay.Skills.Claude).Count) Claude, +$(@($result.TaskOverlay.Skills.Codex).Count) Codex, +$(@($result.TaskOverlay.Skills.Reasonix).Count) Reasonix)"
}
Write-Output "Files: $($result.BuiltFileCount) (+ env.lock.json, env-build.json)"
Write-Output "Staging: $stagingFull"
if ($JsonPath) {
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    Copy-Item -LiteralPath $result.BuildPath -Destination $JsonPath -Force
}
exit 0
