#requires -Version 7.0
[CmdletBinding()]
param(
    [switch] $Apply,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $ProjectRoot = (Get-Location).Path,
    [string] $BackupRoot = (Join-Path $ProjectRoot '.agent-harness/backups')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')

function Get-RelativeHarnessPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    return ([System.IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/')
}

function Get-ComponentContentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Component,
        [Parameter(Mandatory)] [string] $FileName
    )

    $path = Join-Path $Component.Directory $FileName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return $path
    }
    return $null
}

function ConvertTo-HarnessPlainObject {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered] @{}
        foreach ($key in $Value.Keys) {
            $result[[string] $key] = ConvertTo-HarnessPlainObject -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered] @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HarnessPlainObject -Value $property.Value
        }
        return $result
    }
    if ($Value -is [array]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-HarnessPlainObject -Value $item))
        }
        return ,$items.ToArray()
    }
    return $Value
}

function Merge-HarnessJsonObject {
    [CmdletBinding()]
    param(
        [AllowNull()] $Base,
        [AllowNull()] $Overlay
    )

    if ($null -eq $Base) { return $Overlay }
    if ($null -eq $Overlay) { return $Base }

    if ($Base -is [System.Collections.IDictionary] -and $Overlay -is [System.Collections.IDictionary]) {
        $merged = [ordered] @{}
        foreach ($key in $Base.Keys) {
            $merged[[string] $key] = $Base[$key]
        }
        foreach ($key in $Overlay.Keys) {
            if ($merged.Contains($key)) {
                $merged[[string] $key] = Merge-HarnessJsonObject -Base $merged[$key] -Overlay $Overlay[$key]
            }
            else {
                $merged[[string] $key] = $Overlay[$key]
            }
        }
        return $merged
    }

    if (($Base -is [array]) -or ($Overlay -is [array])) {
        $items = @(Select-HarnessStableUnique -Values (@($Base) + @($Overlay)))
        return ,$items
    }

    return $Overlay
}

function Get-HarnessJsonDenyList {
    [CmdletBinding()]
    param([AllowNull()] $Settings)

    if ($null -eq $Settings -or -not ($Settings -is [System.Collections.IDictionary])) { return @() }
    if (-not $Settings.Contains('permissions')) { return @() }
    $permissions = $Settings['permissions']
    if ($null -eq $permissions -or -not ($permissions -is [System.Collections.IDictionary])) { return @() }
    if (-not $permissions.Contains('deny')) { return @() }
    return @($permissions['deny'] | ForEach-Object { [string] $_ })
}

function Assert-HarnessDenyNotRemoved {
    [CmdletBinding()]
    param(
        [AllowNull()] $Before,
        [AllowNull()] $After,
        [Parameter(Mandatory)] [string] $Target
    )

    $afterSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($entry in @(Get-HarnessJsonDenyList -Settings $After)) {
        [void] $afterSet.Add($entry)
    }
    foreach ($entry in @(Get-HarnessJsonDenyList -Settings $Before)) {
        if (-not $afterSet.Contains($entry)) {
            throw "StructuredMerge would remove permissions.deny entry '$entry' from $Target."
        }
    }
}

function ConvertTo-HarnessJsonText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $InputObject)

    return (($InputObject | ConvertTo-Json -Depth 50) + "`n")
}

function Get-HarnessText {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $null
    }
    return [System.IO.File]::ReadAllText($Path)
}

function Get-HarnessManagedBlockText {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BlockId,
        [AllowNull()] [string] $Content
    )

    $body = ($Content ?? '').TrimEnd()
    return "<!-- BEGIN AGENT-HARNESS: $BlockId -->`n$body`n<!-- END AGENT-HARNESS: $BlockId -->"
}

function New-HarnessManagedBlockChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Targets,
        [Parameter(Mandatory)] [object[]] $Components,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $FullPath
    )

    if ($Target -notin @('AGENTS.md', 'CLAUDE.md')) {
        throw "ManagedBlock apply is only supported for AGENTS.md and CLAUDE.md in the first version: $Target"
    }

    $existing = Get-HarnessText -Path $FullPath
    $exists = $null -ne $existing
    $content = if ($exists) { $existing } else { '' }
    $blocks = [System.Collections.Generic.List[string]]::new()
    $changedExistingBlock = $false
    $missingBlocks = [System.Collections.Generic.List[string]]::new()

    foreach ($planTarget in $Targets) {
        $component = $Components | Where-Object { $_.Id -eq $planTarget.ComponentId } | Select-Object -First 1
        if (-not $component) {
            throw "Unable to find component '$($planTarget.ComponentId)' for $Target."
        }
        $contentPath = Get-ComponentContentPath -Component $component -FileName 'content.md'
        $componentContent = if ($contentPath) { Get-Content -Raw -LiteralPath $contentPath } else { '' }
        $blockId = if ($planTarget.Output.BlockId) { [string] $planTarget.Output.BlockId } else { [string] $planTarget.ComponentId }
        $blockText = Get-HarnessManagedBlockText -BlockId $blockId -Content $componentContent

        if (-not $exists) {
            $blocks.Add($blockText)
            continue
        }

        $pattern = '(?s)<!--\s*BEGIN AGENT-HARNESS:\s*' + [regex]::Escape($blockId) + '\s*-->.*?<!--\s*END AGENT-HARNESS:\s*' + [regex]::Escape($blockId) + '\s*-->'
        if ([regex]::IsMatch($content, $pattern)) {
            $content = [regex]::Replace($content, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $blockText }, 1)
            $changedExistingBlock = $true
        }
        else {
            $missingBlocks.Add($blockId)
        }
    }

    if (-not $exists) {
        $content = (($blocks.ToArray() -join "`n`n") + "`n")
    }
    elseif (-not $changedExistingBlock) {
        return [pscustomobject] @{
            Target = $Target; FullPath = $FullPath; Mode = 'ManagedBlock'; Action = 'skip'
            Content = $null; Reason = 'existing file has no matching managed block marker'
        }
    }

    if ($exists -and $content -eq $existing) {
        $action = 'noop'
    }
    else {
        $action = if ($exists) { 'update' } else { 'add' }
    }
    $reason = if ($missingBlocks.Count -gt 0) { "missing block(s) skipped: $($missingBlocks -join ', ')" } else { $null }
    return [pscustomobject] @{
        Target = $Target; FullPath = $FullPath; Mode = 'ManagedBlock'; Action = $action
        Content = $content; Reason = $reason
    }
}

function New-HarnessStructuredMergeChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [object[]] $Targets,
        [Parameter(Mandatory)] [object[]] $Components,
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $FullPath
    )

    if ($Target -ine '.claude/settings.json') {
        throw "StructuredMerge apply is only supported for .claude/settings.json in the first version: $Target"
    }

    $exists = Test-Path -LiteralPath $FullPath -PathType Leaf
    $existingText = if ($exists) { Get-Content -Raw -LiteralPath $FullPath } else { $null }
    $existingObject = if ($exists) {
        ConvertTo-HarnessPlainObject -Value ($existingText | ConvertFrom-Json)
    }
    else {
        [ordered] @{}
    }
    $merged = $existingObject

    foreach ($planTarget in $Targets) {
        $component = $Components | Where-Object { $_.Id -eq $planTarget.ComponentId } | Select-Object -First 1
        if (-not $component) {
            throw "Unable to find component '$($planTarget.ComponentId)' for $Target."
        }
        $settingsPath = Get-ComponentContentPath -Component $component -FileName 'settings.json'
        if (-not $settingsPath) {
            throw "StructuredMerge component '$($component.Id)' is missing settings.json."
        }
        $overlay = ConvertTo-HarnessPlainObject -Value (Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json)
        $merged = Merge-HarnessJsonObject -Base $merged -Overlay $overlay
    }

    Assert-HarnessDenyNotRemoved -Before $existingObject -After $merged -Target $Target
    $newText = ConvertTo-HarnessJsonText -InputObject $merged
    $action = if (-not $exists) { 'add' } elseif ($newText -ne $existingText) { 'update' } else { 'noop' }

    return [pscustomobject] @{
        Target = $Target; FullPath = $FullPath; Mode = 'StructuredMerge'; Action = $action
        Content = $newText; Reason = $null
    }
}

function New-HarnessDirectoryFileChange {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Target,
        [Parameter(Mandatory)] [object[]] $Components
    )

    $component = $Components | Where-Object { $_.Id -eq $Target.ComponentId } | Select-Object -First 1
    if (-not $component) {
        throw "Unable to find component '$($Target.ComponentId)' for $($Target.Target)."
    }
    $sourceName = if (($Target.Output.PSObject.Properties.Name -contains 'Source') -and $Target.Output.Source) {
        [string] $Target.Output.Source
    }
    else {
        'content.md'
    }
    $contentPath = Get-ComponentContentPath -Component $component -FileName $sourceName
    if (-not $contentPath) {
        throw "DirectoryFiles component '$($component.Id)' is missing $sourceName."
    }

    $exists = Test-Path -LiteralPath $Target.FullPath -PathType Leaf
    $content = Get-Content -Raw -LiteralPath $contentPath
    $existing = if ($exists) { Get-HarnessText -Path $Target.FullPath } else { $null }
    $action = if (-not $exists) { 'add' } elseif ($content -ne $existing) { 'update' } else { 'noop' }
    return [pscustomobject] @{
        Target = $Target.Target; FullPath = $Target.FullPath; Mode = 'DirectoryFiles'; Action = $action
        Content = $content; Reason = $null
    }
}

function Assert-NoHarnessHomeTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Paths)

    $homeRootPath = $env:USERPROFILE
    if ([string]::IsNullOrWhiteSpace($homeRootPath) -or -not (Test-Path -LiteralPath $homeRootPath)) { return }
    $resolvedHome = (Resolve-Path -LiteralPath $homeRootPath).Path
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    foreach ($path in $Paths) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $resolved = if (Test-Path -LiteralPath $path) {
            (Resolve-Path -LiteralPath $path).Path
        }
        else {
            $path
        }
        if ($resolved.Equals($resolvedHome, $comparison) -or $resolved.StartsWith($resolvedHome.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw "Refusing to write inside the home directory: $resolved"
        }
    }
}

function Resolve-HarnessBackupRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [string] $ProjectRoot
    )

    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $candidate = if ([System.IO.Path]::IsPathFullyQualified($BackupRoot)) {
        $BackupRoot
    }
    elseif (($BackupRoot -replace '\\', '/').StartsWith('.agent-harness/backups', [System.StringComparison]::OrdinalIgnoreCase)) {
        Join-Path $project $BackupRoot
    }
    else {
        Join-Path (Get-Location).Path $BackupRoot
    }
    $backup = Normalize-HarnessCandidatePath -Candidate (Get-RelativeHarnessPath -Root $project -Path $candidate) -AllowedRoot $project -AllowMissingLeaf
    $relative = Get-RelativeHarnessPath -Root $project -Path $backup
    if (-not $relative.StartsWith('.agent-harness/backups/', [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $relative.Equals('.agent-harness/backups', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw 'BackupRoot must resolve under .agent-harness/backups inside the project root.'
    }
    return $backup
}

function Invoke-HarnessSecretScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) {
        throw "Missing secret scan script: $scan"
    }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE."
    }
}

function Assert-NoHarnessMachinePrivateText {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [object[]] $Changes)

    foreach ($change in $Changes) {
        if ($change.Action -in @('add', 'update') -and (Test-HarnessMachinePrivatePathText -Text $change.Content)) {
            throw "Machine-private path scan failed for planned target: $($change.Target)"
        }
    }
}

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Apply
$repo = $plan.RepoRoot
$project = $plan.ProjectRoot

$sourcePathFindings = @(Find-HarnessMachinePrivatePaths -Paths @($plan.SourceFiles | ForEach-Object { $_.Path }))
if ($sourcePathFindings.Count -gt 0) {
    $details = $sourcePathFindings | ForEach-Object { "$($_.File):$($_.Line) $($_.Pattern)" }
    throw "Machine-private path scan failed: $($details -join '; ')"
}

$changes = [System.Collections.Generic.List[object]]::new()

foreach ($group in @($plan.Targets | Where-Object { $_.Mode -eq 'ManagedBlock' } | Group-Object Target)) {
    $first = @($group.Group)[0]
    $changes.Add((New-HarnessManagedBlockChange -Targets @($group.Group) -Components $plan.Components -Target $group.Name -FullPath $first.FullPath))
}

foreach ($group in @($plan.Targets | Where-Object { $_.Mode -eq 'StructuredMerge' } | Group-Object Target)) {
    $first = @($group.Group)[0]
    $changes.Add((New-HarnessStructuredMergeChange -Targets @($group.Group) -Components $plan.Components -Target $group.Name -FullPath $first.FullPath))
}

foreach ($target in @($plan.Targets | Where-Object { $_.Mode -eq 'DirectoryFiles' })) {
    $changes.Add((New-HarnessDirectoryFileChange -Target $target -Components $plan.Components))
}

foreach ($target in @($plan.Targets | Where-Object { $_.Mode -eq 'GeneratedOnly' })) {
    $changes.Add([pscustomobject] @{
        Target = $target.Target; FullPath = $target.FullPath; Mode = 'GeneratedOnly'; Action = 'skip'
        Content = $null; Reason = 'generated-only target is produced by build-harness-profile.ps1'
    })
}

$writeChanges = @($changes | Where-Object { $_.Action -in @('add', 'update') })
Assert-NoHarnessHomeTarget -Paths @($writeChanges | ForEach-Object { $_.FullPath })
Assert-NoHarnessMachinePrivateText -Changes $writeChanges

Write-Output 'Harness profile apply'
Write-Output "Project root: $project"
Write-Output "Repo root: $repo"
Write-Output "Mode: $(if ($Apply) { 'APPLY' } else { 'dry-run' })"
Write-Output ''
Write-Output 'Plan:'
if ($changes.Count -eq 0) {
    Write-Output '  (no targets)'
}
else {
    foreach ($change in $changes) {
        $suffix = if ($change.Reason) { " ($($change.Reason))" } else { '' }
        Write-Output ('  {0,-7} {1} mode={2}{3}' -f $change.Action, $change.Target, $change.Mode, $suffix)
    }
}

if ($writeChanges.Count -eq 0) {
    Write-Output ''
    Write-Output 'Nothing to apply.'
    return
}

if (-not $Apply) {
    Write-Output ''
    Write-Output 'Dry-run only. Re-run with -Apply to write project-local targets.'
    return
}

Invoke-HarnessSecretScan -RepoRoot $repo

$backupRootResolved = Resolve-HarnessBackupRoot -BackupRoot $BackupRoot -ProjectRoot $project
Assert-NoHarnessHomeTarget -Paths @($backupRootResolved)
$stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$backupDir = Join-Path $backupRootResolved "apply-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

$manifestEntries = [System.Collections.Generic.List[object]]::new()
foreach ($change in $writeChanges) {
    $exists = Test-Path -LiteralPath $change.FullPath -PathType Leaf
    $backupPath = $null
    $hash = $null
    if ($exists) {
        $relative = Get-RelativeHarnessPath -Root $project -Path $change.FullPath
        $backupPath = Join-Path $backupDir ($relative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        New-Item -ItemType Directory -Path (Split-Path -Parent $backupPath) -Force | Out-Null
        Copy-Item -LiteralPath $change.FullPath -Destination $backupPath -Force
        $hash = Get-HarnessFileHash -Path $change.FullPath
    }
    $manifestEntries.Add([ordered] @{
            originalPath = $change.FullPath
            backupPath   = $backupPath
            action       = $change.Action
            hash         = $hash
            timestamp    = (Get-Date).ToUniversalTime().ToString('o')
        })
}

$manifest = [ordered] @{
    projectRoot = $project
    profilePath = $plan.ProfilePath
    createdAt = (Get-Date).ToUniversalTime().ToString('o')
    entries = @($manifestEntries)
}
$manifestPath = Join-Path $backupDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $manifestPath -Encoding UTF8

$applied = [System.Collections.Generic.List[object]]::new()
try {
    foreach ($change in $writeChanges) {
        $parent = Split-Path -Parent $change.FullPath
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
        Set-Content -LiteralPath $change.FullPath -Value $change.Content -Encoding UTF8 -NoNewline
        $applied.Add($change)
        Write-Output ('  {0,-7} {1}' -f $change.Action, $change.Target)
    }
}
catch {
    Write-Warning "Apply failed. Attempting best-effort rollback for $($applied.Count) changed file(s)."
    foreach ($change in @($applied | Sort-Object Target -Descending)) {
        $entry = $manifestEntries | Where-Object { $_.originalPath -eq $change.FullPath } | Select-Object -First 1
        try {
            if ($entry.backupPath) {
                Copy-Item -LiteralPath $entry.backupPath -Destination $entry.originalPath -Force
            }
            elseif (Test-Path -LiteralPath $change.FullPath -PathType Leaf) {
                Remove-Item -LiteralPath $change.FullPath -Force
            }
        }
        catch {
            Write-Warning "Rollback could not restore $($change.FullPath): $($_.Exception.Message)"
        }
    }
    throw
}

Write-Output ''
Write-Output "Applied $($writeChanges.Count) change(s)."
Write-Output "Backup manifest: $manifestPath"
