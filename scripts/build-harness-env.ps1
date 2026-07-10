#requires -Version 7.0
<#
.SYNOPSIS
    Build the staging output for one harness environment under envs/<name>/.

.DESCRIPTION
    Resolves the named env definition (harness-source/envs/<name>.psd1), verifies
    that every referenced skill already exists in the generated output roots
    (claude/skills/, codex/skills/ — run scripts/build-skills.ps1 first), then
    materializes a disposable staging tree at envs/<name>/:

        claude/skills/<skill>/   copied from claude/skills/<skill>/
        codex/skills/<skill>/    copied from codex/skills/<skill>/
        manifest.claude.txt      env's Claude skill names, one per line, sorted
        manifest.codex.txt       env's Codex skill names, one per line, sorted
        profile/                 rendered profile component outputs
        env.lock.json            { Name, DefinitionHash, BuiltFiles }

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

.OUTPUTS
    Summary lines (env name, file count, staging path). Non-zero exit on any
    validation or build failure.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Name,
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..')
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
$resolved = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $definition

# --- Collect skill lists (stable sorted, deduplicated) -----------------------
$skillsByPlatform = @{}
foreach ($platform in @('Claude', 'Codex')) {
    $names = @()
    if ($definition.Skills.ContainsKey($platform)) {
        $names = @($definition.Skills[$platform] | ForEach-Object { [string] $_ })
    }
    foreach ($skill in $names) {
        if ($skill -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') {
            throw "Env '$Name' $platform skill name must be a bare identifier, not a path: $skill"
        }
    }
    $skillsByPlatform[$platform] = @(Sort-HarnessOrdinal -Values $names | Select-Object -Unique)
}

# --- Precondition: generated skill output must already exist -----------------
$generatedRoots = @{ Claude = 'claude/skills'; Codex = 'codex/skills' }
$missingSkills = [System.Collections.Generic.List[string]]::new()
foreach ($platform in @('Claude', 'Codex')) {
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

foreach ($platform in @('Claude', 'Codex')) {
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

# --- env.lock.json ------------------------------------------------------------
$builtFiles = @(Get-ChildItem -LiteralPath $stagingFull -File -Recurse -Force)
$relativeToFull = @{}
foreach ($file in $builtFiles) {
    $relativeToFull[(Get-HarnessRelativePath -Root $stagingFull -Path $file.FullName)] = $file.FullName
}
$builtHashes = [ordered] @{}
foreach ($relative in (Sort-HarnessOrdinal -Values @($relativeToFull.Keys))) {
    $builtHashes[$relative] = Get-HarnessFileHash -Path $relativeToFull[$relative]
}

$lock = [ordered] @{
    Name           = $resolved.Name
    DefinitionHash = Get-HarnessEnvDefinitionHash -Path $definitionPath
    BuiltFiles     = $builtHashes
}
Write-HarnessJsonFile -InputObject $lock -Path (Join-Path $stagingFull 'env.lock.json')

Write-Output 'Harness env build complete'
Write-Output "Environment: $($resolved.Name)"
Write-Output "Files: $($builtHashes.Count) (+ env.lock.json)"
Write-Output "Staging: $stagingFull"
exit 0
