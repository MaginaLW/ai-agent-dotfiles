#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $HomeRoot,
    [Parameter(Mandatory)] [string] $MachineId,
    [switch] $IncludeClaude,
    [switch] $IncludeCodex,
    [switch] $IncludeOpenClaw,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skills-common.ps1')

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$HomeRoot = [System.IO.Path]::GetFullPath($HomeRoot)
$safeMachineId = ConvertTo-KebabName -Name $MachineId
if (-not $IncludeClaude -and -not $IncludeCodex -and -not $IncludeOpenClaw) {
    $IncludeClaude = $true
    $IncludeCodex = $true
    $IncludeOpenClaw = $true
}

$inboxMachineRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "imports/skills-inbox/$safeMachineId"
$reportsRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports'
Assert-PathUnderRoot -Root $RepoRoot -Path $inboxMachineRoot
Assert-PathUnderRoot -Root $RepoRoot -Path $reportsRoot

# A machine id identifies one immutable import batch. Re-running the same batch
# must not silently replace the evidence already collected for that machine.
if (-not $DryRun -and (Test-Path -LiteralPath $inboxMachineRoot)) {
    throw "Machine inbox already exists: $inboxMachineRoot. Archive it or choose a new MachineId; refusing to overwrite the prior batch."
}

New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
if (-not $DryRun) {
    New-Item -ItemType Directory -Force -Path $inboxMachineRoot | Out-Null
}

$sources = @(Get-PlatformSkillSources -HomeRoot $HomeRoot -IncludeClaude:$IncludeClaude -IncludeCodex:$IncludeCodex -IncludeOpenClaw:$IncludeOpenClaw)
$records = [System.Collections.Generic.List[object]]::new()
$sourceSummary = [System.Collections.Generic.List[object]]::new()

foreach ($source in $sources) {
    $sourceSummary.Add([pscustomobject] [ordered] @{
        tool = $source.Tool
        selected_path = $source.RelativePath
        selection = $source.Selection
        exists = Test-Path -LiteralPath $source.Path
    })
    if (-not (Test-Path -LiteralPath $source.Path)) {
        Write-Host "Source not found, skipped: $($source.RelativePath)"
        continue
    }

    foreach ($skill in @(Get-SkillDirectories -RootPath $source.Path -ExcludeNames @('.system'))) {
        $target = Join-Path $inboxMachineRoot "$($source.Tool)/$($skill.Name)"
        Assert-PathUnderRoot -Root $RepoRoot -Path $target
        if ($DryRun) {
            Write-Host "DRY-RUN: would copy $($source.RelativePath)/$($skill.Name) -> imports/skills-inbox/$safeMachineId/$($source.Tool)/$($skill.Name)"
            $recordPath = $skill.FullName
        }
        else {
            if (Test-Path -LiteralPath $target) {
                throw "Import collision at $target; refusing to overwrite an existing skill in the new batch."
            }
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $skill.FullName -Destination $target -Recurse
            $recordPath = $target
        }

        $records.Add((Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $recordPath -SourceTool $source.Tool -MachineId $safeMachineId -Collection 'inbox' -PreferredPlatform $source.PreferredPlatform))
    }
}

$safeRecords = @($records | ForEach-Object { ConvertTo-SafeSkillRecord -Record $_ })
$jsonPath = Join-Path $reportsRoot "$safeMachineId-inventory.json"
$mdPath = Join-Path $reportsRoot "$safeMachineId-inventory.md"
$inventory = [pscustomobject] [ordered] @{
    generated_at = (Get-Date).ToString('o')
    machine_id = $safeMachineId
    mode = if ($DryRun) { 'dry-run' } else { 'apply-to-inbox' }
    codex_selection = @($sourceSummary | Where-Object tool -eq 'codex' | Select-Object -First 1)
    sources = @($sourceSummary)
    records = $safeRecords
}
Write-Utf8NoBomFile -Path $jsonPath -Content (($inventory | ConvertTo-Json -Depth 30) + "`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Skills Inventory: $safeMachineId")
$lines.Add('')
$lines.Add("Mode: $($inventory.mode)")
$lines.Add("Total skills: $($records.Count)")
$lines.Add('')
$lines.Add('## Source Selection')
$lines.Add('')
$lines.Add('| Tool | Selected path | Selection | Exists |')
$lines.Add('| --- | --- | --- | --- |')
foreach ($source in $sourceSummary) {
    $lines.Add("| $($source.tool) | $($source.selected_path) | $($source.selection) | $($source.exists) |")
}
$lines.Add('')
$lines.Add('| Tool | Skill | Classification | Scan | Files | Size | Secrets | Paths | Binaries |')
$lines.Add('| --- | --- | --- | --- | ---: | ---: | ---: | ---: | ---: |')
foreach ($record in $safeRecords) {
    $lines.Add("| $($record.source_tool) | $($record.normalized_name) | $($record.classification) | $($record.scan_status) | $($record.file_count) | $($record.total_size) | $(@($record.possible_secret_findings).Count) | $(@($record.possible_local_path_findings).Count) | $(@($record.possible_binary_findings).Count) |")
}
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host "Inventory records: $($records.Count)"
Write-Host "Inventory JSON: $jsonPath"
Write-Host "Inventory report: $mdPath"
