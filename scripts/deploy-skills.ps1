#requires -Version 7.0
<#
.SYNOPSIS
    Deploys the skills selected by one environment (harness-source/envs/<name>.psd1) to the
    live Codex skill directory from its build output. Dry-run unless -Apply.

.DESCRIPTION
    Builds the generated skills (scripts/build-skills.ps1) and scans for secrets
    (scripts/scan-secrets.ps1), then plans each live skill directory one at a time:
      install    selected, missing live
      update     selected, live content differs (old copy is backed up first)
      unchanged  selected, live content identical
      prune      deployed by this tool before but no longer selected, or named in -Retire
      unknown    unselected live directory absent from recorded state and -Retire: reported, not touched
    Codex .system, reparse points and whole-directory mirrors are never touched or used.
    The previously deployed set is kept in a machine-private state file, so pruning only
    ever removes directories this tool put there (or that -Retire names explicitly).
#>
[CmdletBinding()]
param(
    [string] $Environment = 'work',
    [switch] $Apply,
    [string[]] $Retire = @(),
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = [Environment]::GetFolderPath('UserProfile'),
    [string] $StateRoot = (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'ai-agent-dotfiles.deploy'),
    [switch] $SkipBuild,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'repo-common.ps1')

if ($Json -and $Apply) {
    throw '-Json cannot be combined with -Apply.'
}

$platforms = @('Codex')
$statePath = Join-Path $StateRoot 'deployed-skills.json'
$backupRoot = Join-Path $StateRoot ('skill-backups\' + (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
$script:CodexLiveRootLabel = '~/.codex/skills'

function Get-DeploySkillsLiveRoot([string] $Platform) {
    switch ($Platform) {
        'Codex' {
            Assert-PlainPathNoReparse -Path (Join-Path $HomeRoot '.codex\skills') -AllowMissing
            Assert-PlainPathNoReparse -Path (Join-Path $HomeRoot '.agents\skills') -AllowMissing
            $roots = Get-CodexLiveSkillRoots -HomeRoot $HomeRoot
            if ($roots.Ambiguous) { throw "codex-live-root-ambiguous: both $($roots.Preferred) and $($roots.Fallback) exist" }
            $script:CodexLiveRootLabel = if ($roots.FallbackExists) { '~/.agents/skills' } else { '~/.codex/skills' }
            if (-not $Json) {
                if ($roots.FallbackExists) { Write-Host 'Codex live root: ~/.agents/skills (fallback; ~/.codex/skills is absent)' }
                else { Write-Host 'Codex live root: ~/.codex/skills' }
            }
            return $roots.Selected
        }
    }
}

function Get-DeploySkillsTreeState([string] $Path) {
    # One walk replaces the separate plain-tree assert plus file-only hash walk: it refuses
    # any reparse point at or below the root (including ancestors) and retains relative
    # file hashes for the preview without another tree walk.
    Assert-PlainPathNoReparse -Path $Path -AllowMissing
    $files = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]@{ Hash = $null; Files = $files } }
    $rows = @(Get-ChildItem -LiteralPath $Path -Recurse -Force | Sort-Object FullName | ForEach-Object {
        if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "reparse-point-refused: $($_.FullName)" }
        if ($_.PSIsContainer) { return }
        $relativePath = [IO.Path]::GetRelativePath($Path, $_.FullName).Replace('\', '/')
        $fileHash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        $files.Add($relativePath, $fileHash)
        $relativePath + ':' + $fileHash
    })
    return [pscustomobject]@{ Hash = ($rows -join "`n"); Files = $files }
}

if ($Environment -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]*\z') {
    throw "invalid environment name: '$Environment'"
}
$retireList = [System.Collections.Generic.List[string]]::new()
$retireSeen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($rawRetire in @($Retire)) {
    foreach ($token in ([string]$rawRetire -split ',')) {
        $trimmed = $token.Trim()
        if ([string]::IsNullOrEmpty($trimmed)) {
            throw "invalid skill name for Retire: '$rawRetire'"
        }
        if ($retireSeen.Add($trimmed)) { $retireList.Add($trimmed) }
    }
}
$Retire = $retireList.ToArray()

$envPath = Join-Path $RepoRoot "harness-source\envs\$Environment.psd1"
if (-not (Test-Path -LiteralPath $envPath -PathType Leaf)) { throw "unknown environment: $Environment ($envPath)" }
$envData = Import-PowerShellDataFile -LiteralPath $envPath
if ($envData -isnot [hashtable] -or -not $envData.ContainsKey('Skills')) {
    throw "env $Environment must define Skills with exactly the key Codex (use @() for none)"
}
$selection = $envData['Skills']
# A missing or misspelled platform key would read as an empty selection and prune everything.
if ($selection -isnot [hashtable] -or @($platforms | Where-Object { -not $selection.ContainsKey($_) }).Count -or @($selection.Keys | Where-Object { $_ -notin $platforms }).Count) {
    throw "env $Environment must define Skills with exactly the key Codex (use @() for none)"
}
foreach ($platform in $platforms) {
    $seenSkills = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in @($selection[$platform])) {
        # Only an empty selection means none. A blank name or trailing dot is invalid on Windows.
        if (-not (Test-DeploySkillName $name)) {
            throw "invalid skill name for ${platform}: '$name'"
        }
        if (-not $seenSkills.Add($name)) {
            throw "duplicate skill name for ${platform}: '$name'"
        }
    }
    foreach ($name in @($Retire)) {
        if (-not (Test-DeploySkillName $name)) {
            throw "invalid skill name for ${platform}: '$name'"
        }
    }
    foreach ($name in @($Retire | Where-Object { $_ -in @($selection[$platform]) })) {
        throw "retire-selected-skill: -Retire names '$name', which the environment '$Environment' still selects for ${platform}. Remove it from the environment selection instead of retiring it."
    }
}

Assert-PlainPathNoReparse -Path $StateRoot -AllowMissing
Assert-PlainPathNoReparse -Path $statePath -AllowMissing
# One shared read of the deploy-state record, before any build or plan: a present
# unreadable or invalid record cannot authorize any prune or write, while a genuinely
# missing record is the normal fresh condition. Legacy records without an Environment
# entry or with retired platform keys remain usable when the Codex ownership shape is sound.
$stateRecord = Get-DeploySkillsStateRecord -StateRoot $StateRoot
switch ($stateRecord.Reason) {
    'state-root-not-directory' { throw "state-root-not-directory: choose a directory for -StateRoot. Found a file at $StateRoot" }
    'state-path-is-directory' { throw "state-path-is-directory: expected a deployment state file at $($stateRecord.StatePath)" }
    'read-error' { throw "deploy-state-read-error: cannot read the deployment state file at $($stateRecord.StatePath). A present unreadable record cannot authorize pruning or writing; inspect it before retrying." }
    'invalid-json' { throw "deploy-state-invalid-json: inspect the JSON in $statePath before retrying." }
    'invalid-state' { throw "deploy-state-invalid-state: inspect $statePath. Expected a JSON object with a Codex array of skill names and an optional environment name." }
}

if (-not $SkipBuild) {
    if ($Json) {
        $null = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\build-skills.ps1') -RepoRoot $RepoRoot *>&1
        if ($LASTEXITCODE -ne 0) { throw "build-skills failed with exit code $LASTEXITCODE" }
        $null = & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\scan-secrets.ps1') -RepoRoot $RepoRoot *>&1
        if ($LASTEXITCODE -ne 0) { throw "scan-secrets failed with exit code $LASTEXITCODE" }
    }
    else {
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\build-skills.ps1') -RepoRoot $RepoRoot
        if ($LASTEXITCODE -ne 0) { throw "build-skills failed with exit code $LASTEXITCODE" }
        & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts\scan-secrets.ps1') -RepoRoot $RepoRoot
        if ($LASTEXITCODE -ne 0) { throw "scan-secrets failed with exit code $LASTEXITCODE" }
    }
}

$state = $stateRecord.Ownership
$previousEnvironment = if ($null -ne $stateRecord.RecordedEnvironment) { $stateRecord.RecordedEnvironment } else { 'unavailable' }

$interrupted = [System.Collections.Generic.List[object]]::new()
$plan = foreach ($platform in $platforms) {
    $liveRoot = Get-DeploySkillsLiveRoot $platform
    $sourceRoot = Join-Path $RepoRoot ($platform.ToLowerInvariant() + '\skills')
    $selected = @($selection[$platform])
    Assert-PlainPathNoReparse -Path $liveRoot -AllowMissing
    $liveNames = if (Test-Path -LiteralPath $liveRoot) { @(Get-ChildItem -LiteralPath $liveRoot -Directory -Force | ForEach-Object Name) } else { @() }
    foreach ($name in @($liveNames | Where-Object { $_.StartsWith('.deploying-') })) {
        $interrupted.Add([pscustomobject]@{ Platform = $platform; Path = (Join-Path $liveRoot $name) })
    }

    foreach ($name in $selected) {
        $source = Join-Path $sourceRoot $name
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { throw "selected skill '$name' has no generated output for $platform at $source" }
        $target = Join-Path $liveRoot $name
        if ((Test-Path -LiteralPath $target) -and -not (Get-Item -LiteralPath $target -Force).PSIsContainer) {
            throw "live-skill-target-not-directory: $target"
        }
        $sourceState = Get-DeploySkillsTreeState $source
        $targetState = Get-DeploySkillsTreeState $target
        $action = if ($name -notin $liveNames) { 'install' }
            elseif ($sourceState.Hash -ceq $targetState.Hash) { 'unchanged' }
            else { 'update' }
        $fileChanges = @(if ($action -in @('install', 'update')) {
            foreach ($path in @($sourceState.Files.Keys | Sort-Object -CaseSensitive)) {
                if (-not $targetState.Files.ContainsKey($path)) { [pscustomobject]@{ Action = 'add'; Path = $path } }
                elseif ($sourceState.Files[$path] -cne $targetState.Files[$path]) { [pscustomobject]@{ Action = 'change'; Path = $path } }
            }
            foreach ($path in @($targetState.Files.Keys | Sort-Object -CaseSensitive)) {
                if (-not $sourceState.Files.ContainsKey($path)) { [pscustomobject]@{ Action = 'remove'; Path = $path } }
            }
        })
        [pscustomobject]@{ Platform = $platform; Action = $action; Name = $name; Source = $source; Target = $target; FileChanges = $fileChanges }
    }
    $prunable = @($state[$platform]) + @($Retire)
    foreach ($name in $liveNames) {
        if ($name -in $selected -or $name -eq '.system' -or $name.StartsWith('.deploying-')) { continue }
        $action = if ($name -in $prunable) { 'prune' } else { 'unknown' }
        if ($action -eq 'prune') { Assert-TreeNoReparse -Root (Join-Path $liveRoot $name) }
        $reason = if ($name -in $Retire) { 'explicit -Retire' } else { 'previously managed; not selected in target environment' }
        [pscustomobject]@{ Platform = $platform; Action = $action; Name = $name; Source = $null; Target = (Join-Path $liveRoot $name); Reason = $reason }
    }
}

if ($Json) {
    $summaryCounts = [ordered]@{ install = 0; update = 0; unchanged = 0; prune = 0; unknown = 0 }
    $sortedPlan = @($plan | Where-Object { $null -ne $_ } | Sort-Object Platform, Action, Name)
    $jsonItems = [System.Collections.Generic.List[object]]::new()
    foreach ($step in $sortedPlan) {
        if ($summaryCounts.Contains($step.Action)) {
            $summaryCounts[$step.Action]++
        }
        $reason = if ($step.PSObject.Properties['Reason']) { $step.Reason } else { $null }
        $changes = @()
        if ($step.PSObject.Properties['FileChanges'] -and $null -ne $step.FileChanges) {
            $changes = @($step.FileChanges | ForEach-Object {
                [ordered]@{ Action = [string]$_.Action; Path = [string]$_.Path }
            })
        }
        $jsonItems.Add([ordered]@{
            Platform        = [string] $step.Platform
            Name            = [string] $step.Name
            Action          = [string] $step.Action
            Reason          = $reason
            RecordedInState = [bool]($step.Name -in @($state[$step.Platform]))
            FileChanges     = $changes
        })
    }
    $unrecordedUpdates = @($sortedPlan | Where-Object { $_.Action -eq 'update' -and ($_.Name -notin @($state[$_.Platform])) } | ForEach-Object { "$($_.Platform)/$($_.Name)" })
    $remnants = @($interrupted | ForEach-Object {
        [ordered]@{
            Platform = [string] $_.Platform
            Name     = [string] (Split-Path -Leaf $_.Path)
        }
    })
    $jsonReport = [ordered]@{
        SchemaVersion       = 1
        Mode                = 'dry-run'
        Environment         = [string] $Environment
        PreviousEnvironment = [string] $previousEnvironment
        LiveRoot            = [string] $script:CodexLiveRootLabel
        Summary             = $summaryCounts
        Items               = $jsonItems.ToArray()
        UnrecordedUpdates   = $unrecordedUpdates
        InterruptedRemnants = $remnants
    }
    ConvertTo-Json -InputObject $jsonReport -Depth 10
    return
}

Write-Host "Environment: last recorded '$previousEnvironment' -> target '$Environment' (record only; live contents may differ)."
$plan | Sort-Object Platform, Action, Name | Format-Table Platform, Action, Name -AutoSize | Out-String | Write-Host
$summary = foreach ($action in 'install', 'update', 'unchanged', 'prune', 'unknown') {
    $count = @($plan | Where-Object { $null -ne $_ -and $_.Action -eq $action }).Count
    "${action}=$count"
}
Write-Host ("Plan summary: " + ($summary -join '  '))
foreach ($step in @($plan | Where-Object { $null -ne $_ -and $_.Action -in @('install', 'update') })) {
    Write-Host "File changes for $($step.Platform)/$($step.Name):"
    foreach ($change in $step.FileChanges) { Write-Host ('  {0,-7} {1}' -f $change.Action, $change.Path) }
}
foreach ($step in @($plan | Where-Object { $null -ne $_ -and $_.Action -eq 'prune' })) {
    Write-Host "Prune reason for $($step.Platform)/$($step.Name): $($step.Reason)."
}
foreach ($step in @($plan | Where-Object Action -eq 'update')) {
    if ($step.Name -notin @($state[$step.Platform])) {
        Write-Host "Update not recorded in deploy state: $($step.Platform)/$($step.Name). Existing content will be backed up and overwritten; ownership is unknown."
    }
}
if ($interrupted.Count -gt 0) {
    Write-Host 'Possible interrupted deployment remnants (inspect before applying):'
    foreach ($item in $interrupted) { Write-Host "  $($item.Platform): $($item.Path)" }
    Write-Host "Prior backups, if any: $(Join-Path $StateRoot 'skill-backups')"
}
if (-not $Apply) { Write-Host "Dry run for environment '$Environment'. Re-run with -Apply to make these changes."; return }

try {
Assert-PlainPathNoReparse -Path $backupRoot -AllowMissing
Assert-PlainPathNoReparse -Path $statePath -AllowMissing
foreach ($step in @($plan | Where-Object Action -in 'install', 'update', 'prune')) {
    $liveRoot = Split-Path -Parent $step.Target
    if ($step.Action -ne 'install') {
        Assert-TreeNoReparse -Root $step.Target
        $backup = Join-Path $backupRoot "$($step.Platform)\$($step.Name)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
        Copy-Item -LiteralPath $step.Target -Destination $backup -Recurse -Force
    }
    # Both names can contain interrupted data: .deploying-old-alpha is also the staging
    # name for the valid skill old-alpha. Preserve either leftover before deleting it.
    New-Item -ItemType Directory -Path $liveRoot -Force | Out-Null
    $staging = Join-Path $liveRoot ".deploying-$($step.Name)"
    $retired = Join-Path $liveRoot ".deploying-old-$($step.Name)"
    if (Test-Path -LiteralPath $staging) {
        Assert-TreeNoReparse -Root $staging
        $stagingBackup = Join-Path $backupRoot "interrupted-staging\$($step.Platform)\$($step.Name)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $stagingBackup) -Force | Out-Null
        Copy-Item -LiteralPath $staging -Destination $stagingBackup -Recurse -Force
        Write-Host "Preserved interrupted directory: $staging -> $stagingBackup"
    }
    if (Test-Path -LiteralPath $retired) {
        Assert-TreeNoReparse -Root $retired
        $interruptedBackup = Join-Path $backupRoot "interrupted\$($step.Platform)\$($step.Name)"
        New-Item -ItemType Directory -Path (Split-Path -Parent $interruptedBackup) -Force | Out-Null
        Copy-Item -LiteralPath $retired -Destination $interruptedBackup -Recurse -Force
        Write-Host "Preserved interrupted directory: $retired -> $interruptedBackup"
    }
    foreach ($leftover in $staging, $retired) { if (Test-Path -LiteralPath $leftover) { Assert-TreeNoReparse -Root $leftover; Remove-Item -LiteralPath $leftover -Recurse -Force } }
    if ($step.Action -ne 'prune') { Copy-Item -LiteralPath $step.Source -Destination $staging -Recurse }
    if (Test-Path -LiteralPath $step.Target) { Rename-Item -LiteralPath $step.Target -NewName (Split-Path -Leaf $retired) }
    if ($step.Action -ne 'prune') { Rename-Item -LiteralPath $staging -NewName $step.Name }
    if (Test-Path -LiteralPath $retired) { Remove-Item -LiteralPath $retired -Recurse -Force }
    Write-Host "$($step.Action) $($step.Platform)/$($step.Name)"
}

# Matching a selected skill does not establish ownership of a pre-existing directory.
$deployed = [ordered]@{ Environment = $Environment }
foreach ($platform in $platforms) {
    $deployed[$platform] = @($plan | Where-Object Platform -eq $platform | Where-Object {
        $_.Action -in 'install', 'update' -or ($_.Action -eq 'unchanged' -and $_.Name -in $state[$platform])
    } | Select-Object -ExpandProperty Name | Sort-Object -Unique)
}
$tempStatePath = Join-Path $StateRoot ('deployed-skills.' + [guid]::NewGuid().ToString('N') + '.tmp')
$ownsTempState = $false
try {
    New-Item -ItemType Directory -Path $StateRoot -Force | Out-Null
    $tempStream = [IO.File]::Open($tempStatePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $ownsTempState = $true
    $tempStream.Dispose()
    $deployed | ConvertTo-Json | Set-Content -LiteralPath $tempStatePath -Encoding utf8
    # PowerShell binds $null to an empty string for this overload; NullString supplies a true null backup path.
    if ([IO.File]::Exists($statePath)) { [IO.File]::Replace($tempStatePath, $statePath, [NullString]::Value) }
    else { [IO.File]::Move($tempStatePath, $statePath) }
    $ownsTempState = $false
}
catch {
    Write-Warning 'Deployment state update failed. Live changes may already have occurred; inspect live directories and backups, then review a new dry run before retrying.'
    throw
}
finally {
    if ($ownsTempState -and (Test-Path -LiteralPath $tempStatePath)) {
        try { Remove-Item -LiteralPath $tempStatePath -Force -ErrorAction Stop }
        catch { Write-Warning "Could not remove this run's temporary state file: $tempStatePath" }
    }
}
Write-Host "Applied environment '$Environment'. State: $statePath"
if (Test-Path -LiteralPath $backupRoot) { Write-Host "Backups: $backupRoot" }
}
catch {
    if (Test-Path -LiteralPath $backupRoot) { Write-Warning "Apply failed; backups created so far: $backupRoot" }
    throw
}
