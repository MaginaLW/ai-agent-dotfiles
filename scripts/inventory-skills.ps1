#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $HomeRoot,
    [Parameter(Mandatory)] [string] $MachineId,
    [switch] $IncludeClaude,
    [switch] $IncludeCodex,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'skills-common.ps1')

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$HomeRoot = (Resolve-Path -LiteralPath $HomeRoot).Path
$safeMachineId = ConvertTo-KebabName -Name $MachineId
if (-not $IncludeClaude -and -not $IncludeCodex) {
    $IncludeClaude = $true
    $IncludeCodex = $true
}

$inboxMachineRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "imports/skills-inbox/$safeMachineId"
$reportsRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports'
Assert-PathUnderRoot -Root $RepoRoot -Path $inboxMachineRoot
Assert-PathUnderRoot -Root $RepoRoot -Path $reportsRoot
New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null

if (-not $DryRun) {
    if (Test-Path -LiteralPath $inboxMachineRoot) {
        Remove-Item -LiteralPath $inboxMachineRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $inboxMachineRoot | Out-Null
}

$sources = @()
if ($IncludeClaude) {
    $sources += [pscustomobject] @{
        Tool = 'claude'
        Path = Join-Path $HomeRoot '.claude/skills'
    }
}
if ($IncludeCodex) {
    $sources += [pscustomobject] @{
        Tool = 'codex'
        Path = Join-Path $HomeRoot '.agents/skills'
    }
}

$records = [System.Collections.Generic.List[object]]::new()
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source.Path)) {
        Write-Host "Source not found, skipped: $($source.Path)"
        continue
    }

    $skills = @(Get-ChildItem -LiteralPath $source.Path -Directory -Force | Where-Object {
        Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md')
    })

    foreach ($skill in $skills) {
        $target = Join-Path $inboxMachineRoot "$($source.Tool)/$($skill.Name)"
        Assert-PathUnderRoot -Root $RepoRoot -Path $target
        if ($DryRun) {
            Write-Host "DRY-RUN: would copy $($skill.FullName) -> $target"
            $recordPath = $skill.FullName
        }
        else {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
            Copy-Item -LiteralPath $skill.FullName -Destination $target -Recurse
            $recordPath = $target
        }

        $records.Add((Get-SkillRecord -RepoRoot $RepoRoot -SkillPath $recordPath -SourceTool $source.Tool -MachineId $safeMachineId -Collection 'inbox'))
    }
}

$jsonPath = Join-Path $reportsRoot "$safeMachineId-inventory.json"
$mdPath = Join-Path $reportsRoot "$safeMachineId-inventory.md"
$json = $records | ConvertTo-Json -Depth 20
Write-Utf8NoBomFile -Path $jsonPath -Content ($json + "`n")

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# Skills Inventory: $safeMachineId")
$lines.Add('')
$lines.Add("Dry run: $DryRun")
$lines.Add("Total skills: $($records.Count)")
$lines.Add('')
$lines.Add('| Tool | Skill | Classification | Files | Size | Risk Findings | Local Paths |')
$lines.Add('| --- | --- | --- | ---: | ---: | ---: | ---: |')
foreach ($record in $records) {
    $lines.Add("| $($record.source_tool) | $($record.normalized_name) | $($record.classification) | $($record.file_count) | $($record.total_size) | $(@($record.possible_secret_findings).Count) | $(@($record.possible_local_path_findings).Count) |")
}
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host "Inventory records: $($records.Count)"
Write-Host "Inventory JSON: $jsonPath"
Write-Host "Inventory report: $mdPath"
