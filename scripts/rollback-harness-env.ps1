#requires -Version 7.0
<#!
.SYNOPSIS
    Restore the managed Claude/Codex skills and previous environment state from
    one explicitly selected harness activation backup.

.DESCRIPTION
    This is an environment rollback, not a whole-home restore. It only touches
    skill directories named by the current Claude/Codex managed manifests. Live
    unknown directories, Codex .system, credentials, sessions, caches, config
    files, and OpenClaw machine state are never touched.

    Dry-run is the default. Apply requires the exact plan produced by a prior
    dry-run. The backup must contain both backup-manifest.json and the
    harness-env-activation.json written by activate-harness-env.ps1.
#>
[CmdletBinding()]
param(
    [string] $BackupPath,
    [string] $RunId,
    [string] $BackupRoot = (Join-Path $env:USERPROFILE '.ai-agent-dotfiles-backups'),
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $HomeRoot = $env:USERPROFILE,
    [switch] $Apply,
    [switch] $DryRun,
    [string] $PlanPath,
    [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

function Write-RollbackSummary {
    param(
        [Parameter(Mandatory)] [string] $Result,
        [Parameter(Mandatory)] [string] $PlanHash,
        [AllowNull()] [object] $Plan,
        [AllowNull()] [string] $Failure = $null
    )

    if ([string]::IsNullOrWhiteSpace($JsonPath)) { return }
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Mode = if ($Apply) { 'apply' } else { 'dry-run' }
        Result = $Result
        PlanHash = $PlanHash
        BackupReference = if ($null -eq $Plan) { $null } else { $Plan.BackupReference }
        PreviousEnvironment = if ($null -eq $Plan) { $null } else { $Plan.PreviousEnvironment }
        Actions = if ($null -eq $Plan) { @() } else { @($Plan.Actions) }
        Failure = $Failure
    }
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 20) + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Assert-SafeSkillName {
    param([Parameter(Mandatory)] [string] $Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $Name -ieq '.system') {
        throw "Refusing unsafe managed skill name: $Name"
    }
}

function Get-LiveRoot {
    param(
        [Parameter(Mandatory)] [string] $HomeRootValue,
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex')] [string] $Platform
    )
    if ($Platform -eq 'Claude') { return Join-Path $HomeRootValue '.claude/skills' }
    $preferred = Join-Path $HomeRootValue '.codex/skills'
    $fallback = Join-Path $HomeRootValue '.agents/skills'
    if (Test-Path -LiteralPath $preferred -PathType Container) { return $preferred }
    if (Test-Path -LiteralPath $fallback -PathType Container) { return $fallback }
    return $preferred
}

function Assert-LiveSkillTarget {
    param(
        [Parameter(Mandatory)] [string] $LiveRoot,
        [Parameter(Mandatory)] [string] $Name
    )
    Assert-SafeSkillName -Name $Name
    $root = [System.IO.Path]::GetFullPath($LiveRoot).TrimEnd('\', '/')
    $target = [System.IO.Path]::GetFullPath((Join-Path $root $Name))
    $prefix = $root + [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing target outside live root: $target"
    }
    if ([System.IO.Path]::GetFullPath((Split-Path -Parent $target)).TrimEnd('\', '/') -ne $root) {
        throw "Refusing non-direct live skill target: $target"
    }
    return $target
}

function Read-ManagedNames {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw "Missing managed manifest: $Path" }
    $set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        $name = $line.Trim()
        if ($name) { Assert-SafeSkillName -Name $name; [void] $set.Add($name) }
    }
    return ,$set
}

function Get-BackupSkillRoot {
    param([Parameter(Mandatory)] [string] $BackupPath, [Parameter(Mandatory)] [string] $Platform)
    return Join-Path $BackupPath $(if ($Platform -eq 'Claude') { 'claude-skills' } else { 'codex-skills' })
}

function Get-RollbackPlan {
    param(
        [Parameter(Mandatory)] [string] $Repo,
        [Parameter(Mandatory)] [string] $HomeRootValue,
        [Parameter(Mandatory)] [string] $Backup
    )

    foreach ($file in @('backup-manifest.json', 'harness-env-activation.json')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Backup $file) -PathType Leaf)) {
            throw "Selected backup is not an environment activation backup: missing $file"
        }
    }
    try {
        $backupManifest = Get-Content -Raw -LiteralPath (Join-Path $Backup 'backup-manifest.json') | ConvertFrom-Json
        $activation = Get-Content -Raw -LiteralPath (Join-Path $Backup 'harness-env-activation.json') | ConvertFrom-Json
    }
    catch {
        throw "Selected backup metadata is corrupt: $($_.Exception.Message)"
    }
    foreach ($required in @('timestamp', 'source_live_paths', 'backup_target_paths', 'claude_dir_existed', 'codex_dir_existed')) {
        if ($null -eq $backupManifest -or $backupManifest.PSObject.Properties.Name -notcontains $required) {
            throw "Selected backup manifest is missing required key '$required'."
        }
    }
    if ([string] $activation.Kind -ne 'harness-env-activation') { throw 'Selected backup has an unsupported activation metadata kind.' }
    if ($null -eq $activation.PreviousState -or $activation.PreviousState.PSObject.Properties.Name -notcontains 'Present') {
        throw 'Activation metadata is missing PreviousState.'
    }

    $actions = [System.Collections.Generic.List[object]]::new()
    foreach ($platform in @('Claude', 'Codex')) {
        $manifestPath = Join-Path $Repo "manifests/managed-skills.$($platform.ToLowerInvariant()).txt"
        $managed = Read-ManagedNames -Path $manifestPath
        $backupRoot = Get-BackupSkillRoot -BackupPath $Backup -Platform $platform
        $missingMarker = "${backupRoot}.MISSING.txt"
        if (-not (Test-Path -LiteralPath $backupRoot -PathType Container) -and
            -not (Test-Path -LiteralPath $missingMarker -PathType Leaf)) {
            throw "Selected backup is incomplete: missing $($platform.ToLowerInvariant()) skill snapshot and its MISSING marker."
        }
        $liveRoot = Get-LiveRoot -HomeRootValue $HomeRootValue -Platform $platform
        foreach ($name in @($managed | Sort-Object)) {
            $backupSkill = Join-Path $backupRoot $name
            $liveSkill = Assert-LiveSkillTarget -LiveRoot $liveRoot -Name $name
            $backupPresent = Test-Path -LiteralPath $backupSkill -PathType Container
            $livePresent = Test-Path -LiteralPath $liveSkill -PathType Container
            $action = if ($backupPresent -and $livePresent) { 'restore' }
                elseif ($backupPresent) { 'restore-add' }
                elseif ($livePresent) { 'remove' }
                else { 'no-op' }
            $actions.Add([pscustomobject] [ordered]@{
                    Platform = $platform
                    Name = $name
                    Action = $action
                    BackupPresent = $backupPresent
                    LivePresent = $livePresent
                })
        }
    }

    $previous = $activation.PreviousState
    $previousName = if ([bool] $previous.Present) { [string] $previous.Name } else { $null }
    [pscustomobject] [ordered]@{
        SchemaVersion = 1
        BackupReference = Split-Path -Leaf ([System.IO.Path]::GetFullPath($Backup))
        ActivatedEnvironment = [string] $activation.ActivatedEnvironment
        PreviousEnvironment = $previousName
        PreviousStatePresent = [bool] $previous.Present
        Actions = @($actions)
        TargetHomeHash = Get-HarnessTextSha256 -Text ([System.IO.Path]::GetFullPath($HomeRootValue).ToLowerInvariant())
        BackupManifestHash = Get-HarnessFileHash -Path (Join-Path $Backup 'backup-manifest.json')
    }
}

function Get-RollbackPlanHash {
    param([Parameter(Mandatory)] [object] $Plan)
    $fingerprint = [ordered]@{
        SchemaVersion = $Plan.SchemaVersion
        BackupReference = $Plan.BackupReference
        ActivatedEnvironment = $Plan.ActivatedEnvironment
        PreviousEnvironment = $Plan.PreviousEnvironment
        PreviousStatePresent = $Plan.PreviousStatePresent
        TargetHomeHash = $Plan.TargetHomeHash
        BackupManifestHash = $Plan.BackupManifestHash
        Actions = @($Plan.Actions | ForEach-Object {
            [ordered]@{ Platform = $_.Platform; Name = $_.Name; Action = $_.Action; BackupPresent = $_.BackupPresent; LivePresent = $_.LivePresent }
        })
    }
    return Get-HarnessTextSha256 -Text (ConvertTo-Json -InputObject $fingerprint -Depth 20 -Compress)
}

function Write-RollbackPlanFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [object] $Plan, [Parameter(Mandatory)] [string] $Hash)
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        PlanHash = $Hash
        BackupReference = $Plan.BackupReference
        TargetHomeHash = $Plan.TargetHomeHash
        Actions = @($Plan.Actions)
    }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 20) + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Assert-RollbackPlanBinding {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $CurrentHash)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { throw 'Rollback Apply requires the external plan from a prior dry-run.' }
    try { $saved = Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json } catch { throw "Rollback plan is not valid JSON: $Path" }
    if ([int] $saved.SchemaVersion -ne 1 -or [string] $saved.PlanHash -ne $CurrentHash) {
        throw "Rollback plan drift detected. Rerun rollback in dry-run mode and review the new plan."
    }
}

function Invoke-RestoreSkill {
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $LiveRoot, [Parameter(Mandatory)] [string] $Name)
    $dest = Assert-LiveSkillTarget -LiveRoot $LiveRoot -Name $Name
    if (-not (Test-Path -LiteralPath $Source -PathType Container)) { throw "Missing backup skill: $Source" }
    New-Item -ItemType Directory -Force -Path $LiveRoot | Out-Null
    $id = [Guid]::NewGuid().ToString('N')
    $stageRoot = Join-Path $LiveRoot ".ai-agent-dotfiles-rollback-stage-$id"
    $oldRoot = Join-Path $LiveRoot ".ai-agent-dotfiles-rollback-old-$id"
    $stageSkill = Join-Path $stageRoot $Name
    $movedOld = $false
    $movedNew = $false
    try {
        New-Item -ItemType Directory -Force -Path $stageRoot | Out-Null
        Copy-Item -LiteralPath $Source -Destination $stageRoot -Recurse -Force
        if ((Get-HarnessTreeHash -Path $Source) -ne (Get-HarnessTreeHash -Path $stageSkill)) { throw "Backup staging verification failed for $Name" }
        if (Test-Path -LiteralPath $dest -PathType Container) { Move-Item -LiteralPath $dest -Destination $oldRoot; $movedOld = $true }
        Move-Item -LiteralPath $stageSkill -Destination $dest; $movedNew = $true
        if ($movedOld -and (Test-Path -LiteralPath $oldRoot)) { Remove-Item -LiteralPath $oldRoot -Recurse -Force }
    }
    catch {
        if ($movedNew -and (Test-Path -LiteralPath $dest)) { Remove-Item -LiteralPath $dest -Recurse -Force }
        if ($movedOld -and (Test-Path -LiteralPath $oldRoot) -and -not (Test-Path -LiteralPath $dest)) { Move-Item -LiteralPath $oldRoot -Destination $dest }
        throw
    }
    finally {
        if (Test-Path -LiteralPath $stageRoot) { Remove-Item -LiteralPath $stageRoot -Recurse -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $oldRoot) { Remove-Item -LiteralPath $oldRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-RemoveSkill {
    param([Parameter(Mandatory)] [string] $LiveRoot, [Parameter(Mandatory)] [string] $Name)
    $dest = Assert-LiveSkillTarget -LiveRoot $LiveRoot -Name $Name
    if (-not (Test-Path -LiteralPath $dest -PathType Container)) { return }
    $id = [Guid]::NewGuid().ToString('N')
    $oldRoot = Join-Path $LiveRoot ".ai-agent-dotfiles-rollback-prune-$id"
    Move-Item -LiteralPath $dest -Destination $oldRoot
    try { Remove-Item -LiteralPath $oldRoot -Recurse -Force }
    catch { if (Test-Path -LiteralPath $oldRoot) { Move-Item -LiteralPath $oldRoot -Destination $dest -ErrorAction SilentlyContinue }; throw }
}

function Copy-RollbackSnapshot {
    param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Destination)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Destination) | Out-Null
    if (Test-Path -LiteralPath $Destination) { Remove-Item -LiteralPath $Destination -Recurse -Force }
    Copy-Item -LiteralPath $Source -Destination $Destination -Recurse -Force
}

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$homeFull = [System.IO.Path]::GetFullPath($HomeRoot)
$repoFull = [System.IO.Path]::GetFullPath($repo)
$repoPrefix = $repoFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($homeFull.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase) -or $homeFull.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'HomeRoot must not be the repository or live inside it.' }
if ($Apply -and $DryRun) { throw 'Specify -DryRun or -Apply, not both.' }
if ([string]::IsNullOrWhiteSpace($BackupPath) -and [string]::IsNullOrWhiteSpace($RunId)) { throw 'Specify exactly one explicit -BackupPath or -RunId.' }
if (-not [string]::IsNullOrWhiteSpace($BackupPath) -and -not [string]::IsNullOrWhiteSpace($RunId)) { throw 'Specify -BackupPath or -RunId, not both.' }
if (-not [string]::IsNullOrWhiteSpace($RunId)) {
    if ($RunId -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$') { throw 'RunId must be a bare backup directory name.' }
    $BackupPath = Join-Path $BackupRoot $RunId
}
$backup = [System.IO.Path]::GetFullPath($BackupPath)
if (-not (Test-Path -LiteralPath $backup -PathType Container)) { throw "Selected backup does not exist: $BackupPath" }
$backupPrefix = $repoFull.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar
if ($backup.Equals($repoFull, [System.StringComparison]::OrdinalIgnoreCase) -or $backup.StartsWith($backupPrefix, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'BackupPath must be outside the repository.' }

$plan = Get-RollbackPlan -Repo $repo -HomeRootValue $homeFull -Backup $backup
$planHash = Get-RollbackPlanHash -Plan $plan
$mode = if ($Apply) { 'APPLY' } else { 'DRY-RUN' }
Write-Host "Harness environment rollback ($mode)"
Write-Host "  backup reference: $($plan.BackupReference)"
Write-Host "  previous environment: $(if ($plan.PreviousEnvironment) { $plan.PreviousEnvironment } else { '<none>' })"
Write-Host "  plan hash: $planHash"
foreach ($action in @($plan.Actions)) { Write-Host ('  {0,-10} {1}/{2}' -f $action.Action, $action.Platform, $action.Name) }

if (-not $Apply) {
    if ($PlanPath) { Write-RollbackPlanFile -Path $PlanPath -Plan $plan -Hash $planHash }
    Write-RollbackSummary -Result 'DRY-RUN' -PlanHash $planHash -Plan $plan
    Write-Host 'DRY-RUN complete. Re-run with -Apply and the same -PlanPath to execute.'
    exit 0
}
if ([string]::IsNullOrWhiteSpace($PlanPath)) { Write-RollbackSummary -Result 'FAIL' -PlanHash $planHash -Plan $plan -Failure 'Apply requires a reviewed -PlanPath.'; throw 'Apply requires -PlanPath from a prior dry-run.' }
Assert-RollbackPlanBinding -Path $PlanPath -CurrentHash $planHash

$activation = Get-Content -Raw -LiteralPath (Join-Path $backup 'harness-env-activation.json') | ConvertFrom-Json
$currentState = $null
try { $currentState = Read-HarnessEnvState -RepoRoot $repo } catch { throw }
if ($null -eq $currentState -or [string] $currentState.Name -ne [string] $activation.ActivatedEnvironment) {
    Write-RollbackSummary -Result 'FAIL' -PlanHash $planHash -Plan $plan -Failure 'Current environment state does not match the selected activation backup.'
    throw 'Current environment state does not match the selected activation backup; refusing rollback.'
}

$rollbackRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-env-rollback-$([Guid]::NewGuid().ToString('N'))"
$completed = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($action in @($plan.Actions | Where-Object { $_.Action -ne 'no-op' })) {
        $liveRoot = Get-LiveRoot -HomeRootValue $homeFull -Platform $action.Platform
        $liveSkill = Assert-LiveSkillTarget -LiveRoot $liveRoot -Name $action.Name
        $snapshot = Join-Path $rollbackRoot "$($action.Platform)/$($action.Name)"
        $hadTarget = Test-Path -LiteralPath $liveSkill -PathType Container
        if ($hadTarget) { Copy-RollbackSnapshot -Source $liveSkill -Destination $snapshot }
        if ($action.Action -in @('restore', 'restore-add')) {
            Invoke-RestoreSkill -Source (Join-Path (Get-BackupSkillRoot -BackupPath $backup -Platform $action.Platform) $action.Name) -LiveRoot $liveRoot -Name $action.Name
        }
        elseif ($action.Action -eq 'remove') {
            Invoke-RemoveSkill -LiveRoot $liveRoot -Name $action.Name
        }
        $completed.Add([pscustomobject]@{ Platform = $action.Platform; Name = $action.Name; LiveRoot = $liveRoot; Snapshot = $snapshot; HadTarget = $hadTarget })
    }

    $previous = $activation.PreviousState
    $statePath = Get-HarnessEnvStatePath -RepoRoot $repo
    if ([bool] $previous.Present) {
        if ([string]::IsNullOrWhiteSpace([string] $previous.Name)) { throw 'Previous environment state has no Name.' }
        $restoredState = [ordered]@{
            SchemaVersion = 2
            Name = [string] $previous.Name
            DefinitionHash = if ($previous.PSObject.Properties.Name -contains 'DefinitionHash') { $previous.DefinitionHash } else { $null }
            LockHash = if ($previous.PSObject.Properties.Name -contains 'LockHash') { $previous.LockHash } else { $null }
            RepositoryCommit = if ($previous.PSObject.Properties.Name -contains 'RepositoryCommit') { $previous.RepositoryCommit } else { $null }
            BackupReference = if ($previous.PSObject.Properties.Name -contains 'BackupReference') { $previous.BackupReference } else { $null }
            RolledBackFrom = [string] $activation.ActivatedEnvironment
            RollbackReference = $plan.BackupReference
            ActivatedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $tempState = "$statePath.rollback-$([Guid]::NewGuid().ToString('N')).tmp"
        Write-HarnessJsonFile -InputObject $restoredState -Path $tempState
        Move-Item -LiteralPath $tempState -Destination $statePath -Force
    }
    elseif (Test-Path -LiteralPath $statePath -PathType Leaf) {
        Remove-Item -LiteralPath $statePath -Force
    }
}
catch {
    $failure = $_.Exception.Message
    $rollbackErrors = [System.Collections.Generic.List[string]]::new()
    for ($i = $completed.Count - 1; $i -ge 0; $i--) {
        $item = $completed[$i]
        try {
            if ($item.HadTarget) {
                Invoke-RestoreSkill -Source $item.Snapshot -LiveRoot $item.LiveRoot -Name $item.Name
            }
            else {
                Invoke-RemoveSkill -LiveRoot $item.LiveRoot -Name $item.Name
            }
        }
        catch { $rollbackErrors.Add("$($item.Platform)/$($item.Name): $($_.Exception.Message)") }
    }
    $detail = if ($rollbackErrors.Count -gt 0) { "$failure; recovery failed: $($rollbackErrors -join '; ')" } else { $failure }
    Write-RollbackSummary -Result 'FAIL' -PlanHash $planHash -Plan $plan -Failure $detail
    throw "Environment rollback failed: $detail"
}
finally {
    if (Test-Path -LiteralPath $rollbackRoot) { Remove-Item -LiteralPath $rollbackRoot -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-RollbackSummary -Result 'PASS' -PlanHash $planHash -Plan $plan
Write-Host "Rollback complete. Restored environment: $(if ($plan.PreviousEnvironment) { $plan.PreviousEnvironment } else { '<none>' })"
exit 0
