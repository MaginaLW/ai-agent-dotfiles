#requires -Version 7.0
<#
.SYNOPSIS
    Build the staging output for one harness environment under envs/<name>/.

.DESCRIPTION
    Resolves the named env definition (harness-source/envs/<name>.psd1), verifies
    that every referenced skill already exists in the generated output roots
     (claude/skills/, codex/skills/, opencode/skills/ — run scripts/build-skills.ps1 first), then
    materializes a disposable staging tree at envs/<name>/:

        claude/skills/<skill>/   copied from claude/skills/<skill>/
        codex/skills/<skill>/    copied from codex/skills/<skill>/
         opencode/skills/<skill>/ copied from opencode/skills/<skill>/
        manifest.claude.txt      env's Claude skill names, one per line, sorted
        manifest.codex.txt       env's Codex skill names, one per line, sorted
        manifests/managed-skills.claude.txt   FULL repo manifest copy
        manifests/managed-skills.codex.txt    FULL repo manifest copy
        manifests/managed-skills.opencode.txt FULL repo manifest copy
        profile/                 rendered profile component outputs
        mcp/templates/<id>/      selected MCP templates (placeholders only)
        env.lock.json            { source provenance, staged hashes, BuiltFiles }

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

# Local helper (kept out of harness-env-common.ps1 on purpose: that file is
# frozen for this change). Ordinal sort keeps manifests and lock keys stable
# across cultures.
function Sort-HarnessOrdinal {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Values)

    $sorted = [string[]] @($Values)
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$staging = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $Name

$definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$Name.psd1"
if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
    throw "Unknown env '$Name': expected definition at $definitionPath"
}
$definition = Read-HarnessEnvDefinition -Path $definitionPath
$taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $Name -Path $TaskOverlayPath
$effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $taskOverlay
$resolved = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition
$mcpTemplates = @($resolved.McpTemplates)

# --- Collect skill lists (stable sorted, deduplicated) -----------------------
$skillsByPlatform = @{}
foreach ($platform in @('Claude', 'Codex', 'OpenCode')) {
    $names = @()
    if ($effectiveDefinition.Skills.ContainsKey($platform)) {
        $names = @($effectiveDefinition.Skills[$platform] | ForEach-Object { [string] $_ })
    }
    foreach ($skill in $names) {
        if ($skill -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Env '$Name' $platform skill name must be a bare identifier, not a path: $skill"
        }
    }
    $skillsByPlatform[$platform] = @(Sort-HarnessOrdinal -Values $names | Select-Object -Unique)
}

# --- Precondition: generated skill output must already exist -----------------
$generatedRoots = @{ Claude = 'claude/skills'; Codex = 'codex/skills'; OpenCode = 'opencode/skills' }
$missingSkills = [System.Collections.Generic.List[string]]::new()
foreach ($platform in @('Claude', 'Codex', 'OpenCode')) {
    foreach ($skill in $skillsByPlatform[$platform]) {
        $skillDir = Join-Path $repo "$($generatedRoots[$platform])/$skill"
        if (-not (Test-Path -LiteralPath $skillDir -PathType Container)) {
            $missingSkills.Add("$($generatedRoots[$platform])/$skill")
        }
    }
}
if ($missingSkills.Count -gt 0) {
    throw "Env '$Name' references skills with no generated output: $($missingSkills -join ', '). Run scripts/build-skills.ps1 first."
}

# --- Resolve profile chain into concrete component outputs -------------------
$mergedProfile = @{}
foreach ($chainProfile in @($resolved.ResolvedProfiles)) {
    $mergedProfile = Merge-HarnessProfileObject -Base $mergedProfile -Overlay $chainProfile.Data
}

$components = @(Get-HarnessComponents -RepoRoot $repo)
[void] (Test-HarnessUniqueComponentIds -Components $components)
$componentIndex = @{}
foreach ($component in $components) {
    $componentIndex[$component.Id] = $component
}

$componentIds = @(Get-HarnessProfileComponentIds -Profile $mergedProfile)
$selected = [System.Collections.Generic.List[object]]::new()
foreach ($id in $componentIds) {
    $safeId = Normalize-HarnessCandidatePath -Candidate $id -AllowedRoot (Join-Path $repo 'harness-source/components') -LeafOnly
    if (-not $componentIndex.ContainsKey($safeId)) {
        throw "Env '$Name' profile chain references unknown component '$id'."
    }
    $selected.Add($componentIndex[$safeId])
}
$targetPlatforms = @($mergedProfile.TargetPlatforms)
[void] (Test-HarnessTargetPlatforms -TargetPlatforms $targetPlatforms -SelectedComponents $selected.ToArray())
[void] (Test-HarnessRequiresAndConflicts -SelectedComponents $selected.ToArray() -ComponentIndex $componentIndex)

$componentOutputs = [System.Collections.Generic.List[object]]::new()
foreach ($component in $selected) {
    if (-not $component.Data.ContainsKey('Outputs')) { continue }
    foreach ($output in @($component.Data.Outputs)) {
        if (-not ($output -is [hashtable]) -or -not $output.ContainsKey('Target') -or -not $output.ContainsKey('Mode')) {
            throw "Component '$($component.Id)' has an output without Target/Mode."
        }
        $componentOutputs.Add([pscustomobject] @{
                Component = $component
                Target    = [string] $output.Target
                Mode      = [string] $output.Mode
                Output    = $output
            })
    }
}

# --- Build the full write plan in memory (write nothing on failure) ----------
# Entries: Kind = Text (Content) | Json (Object) | CopyFile (Source) | CopyDir (Source)
$plan = [System.Collections.Generic.List[object]]::new()

foreach ($platform in @('Claude', 'Codex', 'OpenCode')) {
    foreach ($skill in $skillsByPlatform[$platform]) {
        $plan.Add([pscustomobject] @{
                Kind         = 'CopyDir'
                RelativePath = "$($generatedRoots[$platform])/$skill"
                Source       = Join-Path $repo "$($generatedRoots[$platform])/$skill"
            })
    }
}

$plan.Add([pscustomobject] @{
        Kind         = 'Text'
        RelativePath = 'manifest.claude.txt'
        Content      = ($skillsByPlatform['Claude'] -join "`n")
    })
$plan.Add([pscustomobject] @{
        Kind         = 'Text'
        RelativePath = 'manifest.codex.txt'
        Content      = ($skillsByPlatform['Codex'] -join "`n")
    })

# Full repo manifest copies: sync.ps1 reads <RepoRoot>/manifests/* and prunes
# managed-but-absent skills, which implements env switching (see help above).
foreach ($manifestName in @('managed-skills.claude.txt', 'managed-skills.codex.txt', 'managed-skills.opencode.txt')) {
    $manifestSource = Join-Path $repo "manifests/$manifestName"
    if (-not (Test-Path -LiteralPath $manifestSource -PathType Leaf)) {
        throw "Missing repo manifest required for staging: $manifestSource"
    }
    $plan.Add([pscustomobject] @{
            Kind         = 'CopyFile'
            RelativePath = "manifests/$manifestName"
            Source       = $manifestSource
        })
}

foreach ($template in $mcpTemplates) {
    $plan.Add([pscustomobject] @{
            Kind = 'CopyFile'
            RelativePath = "mcp/templates/$($template.Id)/template.psd1"
            Source = $template.Path
        })
}

# profile/: same rendering rules as build-harness-profile.ps1.
foreach ($group in @($componentOutputs | Where-Object { $_.Mode -eq 'ManagedBlock' } | Group-Object Target)) {
    $outputName = if ($group.Name -ieq 'AGENTS.md') {
        'AGENTS.generated.md'
    }
    elseif ($group.Name -ieq 'CLAUDE.md') {
        'CLAUDE.generated.md'
    }
    else {
        ((Split-Path -Leaf $group.Name) -replace '\.md$', '') + '.generated.md'
    }

    $blocks = [System.Collections.Generic.List[string]]::new()
    foreach ($entry in @($group.Group)) {
        $contentPath = Get-HarnessComponentContentPath -Component $entry.Component -FileName 'content.md'
        $content = if ($contentPath) { (Get-Content -Raw -LiteralPath $contentPath).TrimEnd() } else { '' }
        $blockId = if ($entry.Output.ContainsKey('BlockId') -and $entry.Output.BlockId) {
            [string] $entry.Output.BlockId
        }
        else {
            [string] $entry.Component.Id
        }
        $blocks.Add("<!-- BEGIN AGENT-HARNESS: $blockId -->`n$content`n<!-- END AGENT-HARNESS: $blockId -->")
    }
    $plan.Add([pscustomobject] @{
            Kind         = 'Text'
            RelativePath = "profile/$outputName"
            Content      = (($blocks.ToArray() -join "`n`n") + "`n")
        })
}

foreach ($group in @($componentOutputs | Where-Object { $_.Mode -eq 'StructuredMerge' } | Group-Object Target)) {
    $merged = [ordered] @{}
    foreach ($entry in @($group.Group)) {
        $settingsPath = Get-HarnessComponentContentPath -Component $entry.Component -FileName 'settings.json'
        if (-not $settingsPath) {
            throw "StructuredMerge component '$($entry.Component.Id)' is missing settings.json."
        }
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        $merged = Merge-HarnessJsonObject -Base $merged -Overlay (ConvertTo-HarnessPlainObject -Value $settings)
    }

    $outputName = if ($group.Name -ieq '.claude/settings.json') {
        'claude-settings.generated.json'
    }
    else {
        ((Split-Path -Leaf $group.Name) -replace '\.json$', '') + '.generated.json'
    }
    $plan.Add([pscustomobject] @{
            Kind         = 'Json'
            RelativePath = "profile/$outputName"
            Object       = $merged
        })
}

foreach ($entry in @($componentOutputs | Where-Object { $_.Mode -eq 'GeneratedOnly' })) {
    $contentPath = Get-HarnessComponentContentPath -Component $entry.Component -FileName 'content.md'
    if (-not $contentPath) {
        throw "GeneratedOnly component '$($entry.Component.Id)' is missing content.md."
    }
    $targetRelative = $entry.Target -replace '\\', '/'
    if (-not $targetRelative.StartsWith('.agent-harness/generated/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "GeneratedOnly target must be under .agent-harness/generated/: $($entry.Target)"
    }
    $generatedRelative = $targetRelative.Substring('.agent-harness/generated/'.Length)
    foreach ($part in ($generatedRelative -split '/')) {
        if ($part -in @('', '.', '..')) {
            throw "GeneratedOnly target contains unsafe path segments: $($entry.Target)"
        }
    }
    $plan.Add([pscustomobject] @{
            Kind         = 'CopyFile'
            RelativePath = "profile/$generatedRelative"
            Source       = $contentPath
        })
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

# --- Execute the plan ---------------------------------------------------------
foreach ($item in $plan) {
    $destination = Join-Path $stagingFull ($item.RelativePath -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    switch ($item.Kind) {
        'Text' {
            Write-HarnessTextFile -Path $destination -Content $item.Content
        }
        'Json' {
            Write-HarnessJsonFile -InputObject $item.Object -Path $destination
        }
        'CopyFile' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $item.Source -Destination $destination -Force
        }
        'CopyDir' {
            New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
            Copy-Item -LiteralPath $item.Source -Destination $destination -Recurse -Force
        }
        default {
            throw "Unknown plan entry kind: $($item.Kind)"
        }
    }
}

# Keep all three platform roots present so the staging tree can be passed
# directly to sync.ps1, including when an environment selects zero skills.
New-Item -ItemType Directory -Path (Join-Path $stagingFull 'opencode/skills') -Force | Out-Null

# --- env.lock.json ------------------------------------------------------------
# The lock contains both the materialized staging evidence and the source
# evidence needed to reject activation after a source/definition drift.  A
# fake repository used by regression tests may not contain skills-source or a
# Git checkout; those fields are recorded as not-collected rather than guessed.
$skillSourceEvidence = Get-HarnessSkillSourceEvidenceStatus -RepoRoot $repo
$skillSourceHashes = [ordered]@{}
foreach ($platform in @('Claude', 'Codex', 'OpenCode')) {
    $platformHashes = [ordered]@{}
    foreach ($skill in $skillsByPlatform[$platform]) {
        $sourceHash = if ($skillSourceEvidence -eq 'available') {
            Get-HarnessSkillSourceHash -RepoRoot $repo -Platform $platform -Name $skill
        }
        else {
            $null
        }
        if ($skillSourceEvidence -eq 'available' -and $null -eq $sourceHash) {
            throw "Env '$Name' cannot record source provenance for $platform skill '$skill'. Source directory is missing."
        }
        $platformHashes[$skill] = $sourceHash
    }
    $skillSourceHashes[$platform] = $platformHashes
}

$stagedSkillTreeHashes = [ordered]@{}
foreach ($platform in @('Claude', 'Codex', 'OpenCode')) {
    $platformHashes = [ordered]@{}
    foreach ($skill in $skillsByPlatform[$platform]) {
        $platformHashes[$skill] = Get-HarnessTreeHash -Path (Join-Path $stagingFull "$($generatedRoots[$platform])/$skill")
    }
    $stagedSkillTreeHashes[$platform] = $platformHashes
}

$builtFiles = @(Get-ChildItem -LiteralPath $stagingFull -File -Recurse -Force)
$relativeToFull = @{}
foreach ($file in $builtFiles) {
    $relativeToFull[(Get-HarnessRelativePath -Root $stagingFull -Path $file.FullName)] = $file.FullName
}
$builtHashes = [ordered] @{}
foreach ($relative in (Sort-HarnessOrdinal -Values @($relativeToFull.Keys))) {
    $builtHashes[$relative] = Get-HarnessFileHash -Path $relativeToFull[$relative]
}
$mcpTemplateHashes = [ordered]@{}
foreach ($template in $mcpTemplates) {
    $mcpTemplateHashes[$template.Id] = $template.Hash
}

$lock = [ordered] @{
    SchemaVersion             = 2
    Name                      = $resolved.Name
    DefinitionHash            = Get-HarnessEnvDefinitionHash -Path $definitionPath
    TaskOverlayHash           = $taskOverlay.Hash
    TaskOverlaySkills         = [ordered]@{
        Claude = @($taskOverlay.Skills.Claude)
        Codex = @($taskOverlay.Skills.Codex)
        OpenCode = @($taskOverlay.Skills.OpenCode)
    }
    RepositoryCommit          = Get-HarnessRepositoryCommit -RepoRoot $repo
    ManifestHashes            = Get-HarnessManifestHashes -RepoRoot $repo
    SkillSourceEvidence       = $skillSourceEvidence
    McpTemplateHashes         = $mcpTemplateHashes
    SkillSourceHashes         = $skillSourceHashes
    StagedSkillTreeHashes     = $stagedSkillTreeHashes
    ProfileSourceHash         = Get-HarnessProfileSourceHash -RepoRoot $repo
    ProfileOutputHash         = Get-HarnessTreeHash -Path (Join-Path $stagingFull 'profile')
    BuiltFiles                = $builtHashes
}
Write-HarnessJsonFile -InputObject $lock -Path (Join-Path $stagingFull 'env.lock.json')

Write-Output 'Harness env build complete'
Write-Output "Environment: $($resolved.Name)"
if ($taskOverlay.Present) {
    Write-Output "Task overlay: $($taskOverlay.Path) (+$(@($taskOverlay.Skills.Claude).Count) Claude, +$(@($taskOverlay.Skills.Codex).Count) Codex, +$(@($taskOverlay.Skills.OpenCode).Count) OpenCode)"
}
Write-Output "Files: $($builtHashes.Count) (+ env.lock.json)"
Write-Output "Staging: $stagingFull"
if ($JsonPath) {
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Name = $resolved.Name
        Result = 'PASS'
        DefinitionHash = $lock.DefinitionHash
        TaskOverlayHash = $lock.TaskOverlayHash
        TaskOverlaySkills = $lock.TaskOverlaySkills
        LockHash = Get-HarnessFileHash -Path (Join-Path $stagingFull 'env.lock.json')
        RepositoryCommit = $lock.RepositoryCommit
        SkillSourceEvidence = $lock.SkillSourceEvidence
        McpTemplateCount = $mcpTemplates.Count
        FileCount = $builtHashes.Count
    }
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
}
exit 0
