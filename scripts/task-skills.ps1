#requires -Version 7.0
<##
.SYNOPSIS
    Manage the repository-shared task skill overlay.

.DESCRIPTION
    A task overlay is a small, tracked .agent-harness/task-skills.psd1 file.
    This script validates and stages overlay changes, then delegates every live
    deployment to activate-harness-env.ps1. It never copies or removes a live
    skill directory directly.

    Mutating actions require exactly one explicit -DryRun or -Apply. The
    -Automatic switch is reserved for Git hooks and permits additions only.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [ValidateSet('status', 'ensure-skill', 'sync', 'close')]
    [string] $Action,

    [Parameter(Position = 1)]
    [string] $SkillName,

    [ValidateSet('Claude', 'Codex', 'OpenCode')]
    [string] $Platform = 'Codex',

    [string] $BaseEnv = 'work',
    [switch] $Apply,
    [switch] $DryRun,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [switch] $Automatic,
    [switch] $SkipBuild,
    [switch] $SkipSecretScan,
    [string] $TaskOverlayPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$overlayPath = Get-HarnessTaskSkillOverlayPath -RepoRoot $repo

function Sort-TaskSkillNames {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Values)

    [string[]] $sorted = @($Values | ForEach-Object { [string] $_ })
    [System.Array]::Sort($sorted, [System.StringComparer]::Ordinal)
    return @($sorted)
}

function Quote-TaskPsd1String {
    param([Parameter(Mandatory)] [string] $Value)
    return "'$(($Value -replace "'", "''"))'"
}

function ConvertTo-TaskSkillOverlayText {
    param([Parameter(Mandatory)] [hashtable] $Data)

    $claude = @(Sort-TaskSkillNames -Values @($Data.Skills.Claude))
    $codex = @(Sort-TaskSkillNames -Values @($Data.Skills.Codex))
    $opencode = @(Sort-TaskSkillNames -Values @($Data.Skills.OpenCode))
    $claudeText = if ($claude.Count -eq 0) { '@()' } else { '@(' + (($claude | ForEach-Object { Quote-TaskPsd1String -Value $_ }) -join ', ') + ')' }
    $codexText = if ($codex.Count -eq 0) { '@()' } else { '@(' + (($codex | ForEach-Object { Quote-TaskPsd1String -Value $_ }) -join ', ') + ')' }
    $opencodeText = if ($opencode.Count -eq 0) { '@()' } else { '@(' + (($opencode | ForEach-Object { Quote-TaskPsd1String -Value $_ }) -join ', ') + ')' }
    return @"
@{
    SchemaVersion = 1
    BaseEnv = $(Quote-TaskPsd1String -Value ([string] $Data.BaseEnv))
    Skills = @{
        Claude = $claudeText
        Codex = $codexText
        OpenCode = $opencodeText
    }
}
"@
}

function New-TaskOverlayData {
    param(
        [Parameter(Mandatory)] [string] $BaseEnvName,
        [AllowEmptyCollection()] [object[]] $ClaudeSkills = @(),
        [AllowEmptyCollection()] [object[]] $CodexSkills = @(),
        [AllowEmptyCollection()] [object[]] $OpenCodeSkills = @()
    )

    return @{
        SchemaVersion = 1
        BaseEnv = $BaseEnvName
        Skills = @{
            Claude = @(Sort-TaskSkillNames -Values $ClaudeSkills)
            Codex = @(Sort-TaskSkillNames -Values $CodexSkills)
            OpenCode = @(Sort-TaskSkillNames -Values $OpenCodeSkills)
        }
    }
}

function Write-TaskOverlayAtomicBytes {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [byte[]] $Bytes
    )

    $expected = [System.IO.Path]::GetFullPath($overlayPath)
    $target = [System.IO.Path]::GetFullPath($Path)
    if (-not $target.Equals($expected, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to write outside the tracked task overlay path: $target"
    }
    $parent = Split-Path -Parent $target
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $temporary = Join-Path $parent ".task-skills-$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        [System.IO.File]::WriteAllBytes($temporary, $Bytes)
        [System.IO.File]::Move($temporary, $target, $true)
    }
    finally {
        if (Test-Path -LiteralPath $temporary) {
            Remove-Item -LiteralPath $temporary -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-TaskOverlayAtomic {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [hashtable] $Data
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    Write-TaskOverlayAtomicBytes -Path $Path -Bytes $encoding.GetBytes((ConvertTo-TaskSkillOverlayText -Data $Data))
}

function Get-TaskOverlaySnapshot {
    if (-not (Test-Path -LiteralPath $overlayPath -PathType Leaf)) {
        return [pscustomobject]@{ Exists = $false; Bytes = $null }
    }
    return [pscustomobject]@{
        Exists = $true
        Bytes = [System.IO.File]::ReadAllBytes($overlayPath)
    }
}

function Restore-TaskOverlaySnapshot {
    param([Parameter(Mandatory)] $Snapshot)

    if ($Snapshot.Exists) {
        Write-TaskOverlayAtomicBytes -Path $overlayPath -Bytes ([byte[]] $Snapshot.Bytes)
    }
    elseif (Test-Path -LiteralPath $overlayPath) {
        Remove-Item -LiteralPath $overlayPath -Force
    }
}

function New-TaskOverlayCandidate {
    param([Parameter(Mandatory)] [hashtable] $Data)

    $candidate = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-task-overlay-$([Guid]::NewGuid().ToString('N')).psd1"
    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($candidate, (ConvertTo-TaskSkillOverlayText -Data $Data), $encoding)
    return $candidate
}

function Get-TaskContext {
    $definitionPath = Join-Path (Get-HarnessEnvRoot -RepoRoot $repo) "$BaseEnv.psd1"
    if (-not (Test-Path -LiteralPath $definitionPath -PathType Leaf)) {
        throw "Unknown base environment '$BaseEnv': expected definition at $definitionPath"
    }
    $definition = Read-HarnessEnvDefinition -Path $definitionPath
    $overlay = Read-HarnessTaskSkillOverlay -RepoRoot $repo -Path $TaskOverlayPath
    if ($overlay.Present -and -not [string]::Equals($overlay.BaseEnv, $BaseEnv, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Task overlay targets '$($overlay.BaseEnv)', but this task command targets '$BaseEnv'. Close or replace the overlay before continuing."
    }
    $effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $overlay
    $null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition
    return [pscustomobject]@{
        Definition = $definition
        EffectiveDefinition = $effectiveDefinition
        Overlay = $overlay
        OverlayPath = $overlay.Path
        DefinitionPath = $definitionPath
    }
}

function Get-TaskManagedSkillSet {
    param([Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'OpenCode')] [string] $TargetPlatform)

    $manifestPath = Join-Path $repo "manifests/managed-skills.$($TargetPlatform.ToLowerInvariant()).txt"
    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "Missing managed $TargetPlatform skill manifest: $manifestPath"
    }
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in (Get-Content -LiteralPath $manifestPath)) {
        $name = ([string] $line).Trim()
        if ($name) { [void] $set.Add($name) }
    }
    return $set
}

function Assert-TaskSkillAvailable {
    param(
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'OpenCode')] [string] $TargetPlatform,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Name -ieq '.system') {
        throw "Skill name must be a safe bare identifier: $Name"
    }
    $managed = Get-TaskManagedSkillSet -TargetPlatform $TargetPlatform
    if (-not $managed.Contains($Name)) {
        throw "Skill '$Name' is not managed for $TargetPlatform. Only manifest/source skills may be added."
    }
    $sourceHash = Get-HarnessSkillSourceHash -RepoRoot $repo -Platform $TargetPlatform -Name $Name
    if ($null -eq $sourceHash) {
        throw "Skill '$Name' has no repository source for $TargetPlatform. Quarantined/import-only content cannot be added."
    }
    $generatedRoot = switch ($TargetPlatform) {
        'Claude' { 'claude/skills' }
        'Codex' { 'codex/skills' }
        'OpenCode' { 'opencode/skills' }
    }
    $generatedPath = Join-Path $repo "$generatedRoot/$Name"
    if (-not (Test-Path -LiteralPath $generatedPath -PathType Container)) {
        throw "Skill '$Name' has no generated output at $generatedPath. Run scripts/build-skills.ps1 first."
    }
}

function Invoke-TaskActivation {
    param(
        [Parameter(Mandatory)] [ValidateSet('DryRun', 'Apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $CandidateOverlayPath
    )

    $activateScript = Join-Path $PSScriptRoot 'activate-harness-env.ps1'
    $arguments = @(
        '-Name', $BaseEnv,
        '-RepoRoot', $repo,
        '-HomeRoot', $HomeRoot,
        '-BackupRoot', $BackupRoot,
        '-TaskOverlayPath', $CandidateOverlayPath,
        "-$Mode"
    )
    if ($SkipBuild) { $arguments += '-SkipBuild' }
    if ($SkipSecretScan) { $arguments += '-SkipSecretScan' }
    $lines = @(& pwsh -NoProfile -File $activateScript @arguments 6>&1 2>&1)
    $code = $LASTEXITCODE
    [string[]] $textLines = @($lines | ForEach-Object { [string] $_ })
    return [pscustomobject]@{
        Code = $code
        Output = [string]::Join("`n", $textLines)
    }
}

function Assert-TaskAdditionOnlyPlan {
    param(
        [Parameter(Mandatory)] [string] $Output,
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex', 'OpenCode')] [string] $TargetPlatform,
        [Parameter(Mandatory)] [string] $Name
    )

    if ($Output -match '(?m)^\s*(Claude|Codex|OpenCode)\s*:.*-[1-9][0-9]*\s*$') {
        throw 'Task addition dry-run contains a prune action; no live change was attempted. Review env task sync explicitly.'
    }
    $totalAdds = 0
    $targetSummary = $null
    foreach ($line in ($Output -split "`r?`n")) {
        $match = [regex]::Match($line, '^\s*(Claude|Codex|OpenCode)\s*:\s*\+([0-9]+)')
        if (-not $match.Success) { continue }
        $count = [int] $match.Groups[2].Value
        $totalAdds += $count
        if ($match.Groups[1].Value -ieq $TargetPlatform) { $targetSummary = $count }
    }
    if ($totalAdds -ne 1 -or $targetSummary -ne 1 -or
        $Output -notmatch ('(?m)^\s*would add\s+\(1\)\s*:\s*' + [regex]::Escape($Name) + '\s*$')) {
        throw "Task addition dry-run did not contain exactly one $TargetPlatform/$Name addition. No live change was attempted."
    }
}

function Invoke-TaskStatus {
    $context = Get-TaskContext
    $overlay = $context.Overlay
    Write-Output 'Task skill status'
    Write-Output "  base environment: $BaseEnv"
    Write-Output "  overlay path: $($overlay.Path)"
    Write-Output "  overlay state: $(if ($overlay.Present) { 'present' } else { 'empty/absent' })"
    Write-Output "  overlay hash: $(if ($overlay.Hash) { $overlay.Hash } else { 'empty' })"
    Write-Output "  Claude additions: $(if (@($overlay.Skills.Claude).Count) { (@($overlay.Skills.Claude) -join ', ') } else { '(none)' })"
    Write-Output "  Codex additions: $(if (@($overlay.Skills.Codex).Count) { (@($overlay.Skills.Codex) -join ', ') } else { '(none)' })"
    Write-Output "  OpenCode additions: $(if (@($overlay.Skills.OpenCode).Count) { (@($overlay.Skills.OpenCode) -join ', ') } else { '(none)' })"
    Write-Output "  effective Claude skills: $(@($context.EffectiveDefinition.Skills.Claude) -join ', ')"
    Write-Output "  effective Codex skills: $(@($context.EffectiveDefinition.Skills.Codex) -join ', ')"
    Write-Output "  effective OpenCode skills: $(@($context.EffectiveDefinition.Skills.OpenCode) -join ', ')"

    $state = Read-HarnessEnvState -RepoRoot $repo
    if ($null -eq $state) {
        Write-Output '  live attestation: no active environment state'
    }
    elseif ([string] $state.Name -ine $BaseEnv) {
        Write-Output "  live attestation: active environment is '$([string] $state.Name)', not '$BaseEnv'"
    }
    else {
        $stateHash = if ($state.PSObject.Properties.Name -contains 'TaskOverlayHash') { [string] $state.TaskOverlayHash } else { '' }
        $match = $stateHash -eq ([string] $overlay.Hash)
        Write-Output "  live attestation: $(if ($match) { 'task overlay matches activation' } else { 'task overlay differs from activation' })"
    }
}

function Invoke-TaskEnsureSkill {
    if ([string]::IsNullOrWhiteSpace($SkillName)) {
        throw 'ensure-skill requires a skill name: env task ensure-skill <name> -Platform Codex -DryRun'
    }
    $context = Get-TaskContext
    Assert-TaskSkillAvailable -TargetPlatform $Platform -Name $SkillName

    $baseNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($context.Definition.Skills[$Platform])) { [void] $baseNames.Add([string] $name) }
    if ($baseNames.Contains($SkillName)) {
        Write-Output "Skill '$SkillName' is already part of base environment '$BaseEnv'; no overlay change is needed."
        return
    }
    $overlayNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($context.Overlay.Skills[$Platform])) { [void] $overlayNames.Add([string] $name) }
    if ($overlayNames.Contains($SkillName)) {
        Write-Output "Skill '$SkillName' is already present in the task overlay."
        return
    }

    $claude = @($context.Overlay.Skills.Claude)
    $codex = @($context.Overlay.Skills.Codex)
    $opencode = @($context.Overlay.Skills.OpenCode)
    if ($Platform -eq 'Claude') { $claude += $SkillName }
    elseif ($Platform -eq 'Codex') { $codex += $SkillName }
    else { $opencode += $SkillName }
    $candidateData = New-TaskOverlayData -BaseEnvName $BaseEnv -ClaudeSkills $claude -CodexSkills $codex -OpenCodeSkills $opencode
    $candidatePath = New-TaskOverlayCandidate -Data $candidateData
    try {
        Write-Output "Dry-run candidate: add $Platform/$SkillName to '$BaseEnv'."
        $dry = Invoke-TaskActivation -Mode DryRun -CandidateOverlayPath $candidatePath
        if ($dry.Output) { Write-Output $dry.Output }
        if ($dry.Code -ne 0) {
            throw "Task skill dry-run failed (exit $($dry.Code)); overlay was not changed."
        }
        Assert-TaskAdditionOnlyPlan -Output $dry.Output -TargetPlatform $Platform -Name $SkillName
        if ($DryRun) {
            Write-Output 'Task skill dry-run complete; tracked overlay and live home were not changed.'
            return
        }

        $snapshot = Get-TaskOverlaySnapshot
        $changed = $false
        try {
            Write-TaskOverlayAtomic -Path $overlayPath -Data $candidateData
            $changed = $true
            $apply = Invoke-TaskActivation -Mode Apply -CandidateOverlayPath $overlayPath
            if ($apply.Code -ne 0) {
                throw "Task skill apply failed (exit $($apply.Code)); the tracked overlay will be restored."
            }
            Write-Output "Task skill applied: $Platform/$SkillName. Commit $overlayPath to share it with other computers."
            return
        }
        catch {
            if ($changed) { Restore-TaskOverlaySnapshot -Snapshot $snapshot }
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $candidatePath) {
            Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-StateOverlaySkills {
    param([Parameter(Mandatory)] $State, [Parameter(Mandatory)] [string] $TargetPlatform)

    if ($State.PSObject.Properties.Name -notcontains 'TaskOverlaySkills') {
        return [pscustomobject]@{ Present = $false; Values = @() }
    }
    $platformProperty = $State.TaskOverlaySkills.PSObject.Properties[$TargetPlatform]
    if ($null -eq $platformProperty) {
        return [pscustomobject]@{ Present = $false; Values = @() }
    }
    $platformValues = Get-HarnessJsonProperty -Object $State.TaskOverlaySkills -Name $TargetPlatform
    return [pscustomobject]@{
        Present = $true
        Values = if ($null -eq $platformValues) { @() } else { @($platformValues | ForEach-Object { [string] $_ }) }
    }
}

function Invoke-TaskSync {
    $context = Get-TaskContext
    if ($Automatic) {
        $state = Read-HarnessEnvState -RepoRoot $repo
        if ($null -eq $state -or [string] $state.Name -ine $BaseEnv) {
            Write-Output 'Automatic task sync skipped: this computer has no active matching environment.'
            return
        }
        $oldClaude = Get-StateOverlaySkills -State $state -TargetPlatform Claude
        $oldCodex = Get-StateOverlaySkills -State $state -TargetPlatform Codex
        $oldOpenCode = Get-StateOverlaySkills -State $state -TargetPlatform OpenCode
        if (-not $oldClaude.Present -or -not $oldCodex.Present -or -not $oldOpenCode.Present) {
            Write-Output 'Automatic task sync skipped: activation state has no task-overlay baseline; run env task sync -DryRun explicitly.'
            return
        }
        $currentClaude = @($context.Overlay.Skills.Claude)
        $currentCodex = @($context.Overlay.Skills.Codex)
        $currentOpenCode = @($context.Overlay.Skills.OpenCode)
        $removed = @($oldClaude.Values | Where-Object { $_ -notin $currentClaude }) +
            @($oldCodex.Values | Where-Object { $_ -notin $currentCodex }) +
            @($oldOpenCode.Values | Where-Object { $_ -notin $currentOpenCode })
        if ($removed.Count -gt 0) {
            Write-Output "Automatic task sync skipped: removal requires explicit review ($($removed -join ', '))."
            Write-Output 'Run env task sync -DryRun, inspect the prune plan, then env task sync -Apply.'
            return
        }
        $stateHash = if ($state.PSObject.Properties.Name -contains 'TaskOverlayHash') { [string] $state.TaskOverlayHash } else { '' }
        if ($stateHash -eq ([string] $context.Overlay.Hash)) {
            Write-Output 'Automatic task sync skipped: task overlay is already activated.'
            return
        }
        Write-Output 'Automatic task sync: addition-only overlay change detected; running the guarded apply path.'
    }

    $mode = if ($Apply) { 'Apply' } else { 'DryRun' }
    $result = Invoke-TaskActivation -Mode $mode -CandidateOverlayPath $context.OverlayPath
    if ($result.Output) { Write-Output $result.Output }
    if ($result.Code -ne 0) {
        throw "Task overlay sync failed (exit $($result.Code))."
    }
    return
}

function Invoke-TaskClose {
    $context = Get-TaskContext
    $candidatePath = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-task-overlay-closed-$([Guid]::NewGuid().ToString('N')).psd1"
    $snapshot = Get-TaskOverlaySnapshot
    $quarantinePath = Join-Path (Split-Path -Parent $overlayPath) ".task-skills-close-$([Guid]::NewGuid().ToString('N')).bak"
    try {
        Write-Output "Dry-run candidate: remove task overlay for '$BaseEnv'."
        $dry = Invoke-TaskActivation -Mode DryRun -CandidateOverlayPath $candidatePath
        if ($dry.Output) { Write-Output $dry.Output }
        if ($dry.Code -ne 0) {
            throw "Task close dry-run failed (exit $($dry.Code)); overlay was not changed."
        }
        if ($DryRun) {
            Write-Output 'Task close dry-run complete; tracked overlay and live home were not changed.'
            return
        }

        $moved = $false
        try {
            if (Test-Path -LiteralPath $overlayPath -PathType Leaf) {
                Move-Item -LiteralPath $overlayPath -Destination $quarantinePath
                $moved = $true
            }
            $apply = Invoke-TaskActivation -Mode Apply -CandidateOverlayPath $overlayPath
            if ($apply.Code -ne 0) {
                throw "Task close apply failed (exit $($apply.Code)); the tracked overlay will be restored."
            }
            if (Test-Path -LiteralPath $quarantinePath) {
                Remove-Item -LiteralPath $quarantinePath -Force
            }
            Write-Output "Task overlay closed. Commit the removal of $overlayPath to share task closure with other computers."
            return
        }
        catch {
            if ($moved -and (Test-Path -LiteralPath $quarantinePath) -and -not (Test-Path -LiteralPath $overlayPath)) {
                Move-Item -LiteralPath $quarantinePath -Destination $overlayPath
            }
            elseif (-not $moved -and $snapshot.Exists -and -not (Test-Path -LiteralPath $overlayPath)) {
                Restore-TaskOverlaySnapshot -Snapshot $snapshot
            }
            throw
        }
    }
    finally {
        if (Test-Path -LiteralPath $candidatePath) {
            Remove-Item -LiteralPath $candidatePath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $quarantinePath) {
            Remove-Item -LiteralPath $quarantinePath -Force -ErrorAction SilentlyContinue
        }
    }
}

try {
    if ($Action -eq 'status') {
        if ($Apply -or $DryRun -or $Automatic) { throw 'env task status is read-only and does not accept -DryRun, -Apply, or -Automatic.' }
        Invoke-TaskStatus
        exit 0
    }

    if ($Automatic -and $Action -ne 'sync') {
        throw '-Automatic is only valid for env task sync.'
    }
    $hasMode = $(if ($DryRun) { 1 } else { 0 }) + $(if ($Apply) { 1 } else { 0 })
    if ($hasMode -ne 1) {
        throw "env task $Action requires exactly one explicit -DryRun or -Apply mode."
    }
    if ($Automatic -and -not $Apply) {
        throw 'Automatic task sync requires -Apply; Git hooks never apply removals.'
    }

    switch ($Action) {
        'ensure-skill' { Invoke-TaskEnsureSkill; exit 0 }
        'sync' { Invoke-TaskSync; exit 0 }
        'close' { Invoke-TaskClose; exit 0 }
    }
}
catch {
    Write-Error ([string] $_.Exception.Message) -ErrorAction Continue
    exit 1
}
