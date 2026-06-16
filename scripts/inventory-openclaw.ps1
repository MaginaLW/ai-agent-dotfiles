#requires -Version 7.0
<#
.SYNOPSIS
  Read-only inventory of OpenClaw skills and plugins state.
.DESCRIPTION
  Inspects only path names, directory names, file sizes, hashes, frontmatter
  metadata, plugin ids, plugin origins, plugin source specs, and enablement
  booleans.  Does NOT record file contents from identity/, credentials/,
  devices/, auth-profiles.json, exec-approvals.json, node.json, logs,
  sessions, caches, or plugins/installs.json package metadata beyond
  plugin id/source/origin/enabled.
.PARAMETER RepoRoot
  Root of the ai-agent-dotfiles repository (default: resolved from script location).
.PARAMETER HomeRoot
  User profile root for OpenClaw state (default: $env:USERPROFILE).
.PARAMETER MachineId
  Machine identifier for report filenames (default: hostname via ConvertTo-KebabName).
.PARAMETER OpenClawHomeRoot
  Explicit OpenClaw home directory (default: $HomeRoot\.openclaw).
.OUTPUTS
  imports/skills-reports/openclaw-inventory.json
  imports/skills-reports/openclaw-inventory.md
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $MachineId,
    [string] $OpenClawHomeRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

# ---- dot-source helpers ----
. (Join-Path $PSScriptRoot 'skills-common.ps1')

# Safely compute tree hash, skipping node_modules and inaccessible files
function Get-SafeTreeHash {
    param([string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $basePath = $Path
        $rows = Get-ChildItem -LiteralPath $Path -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $relPath = $_.FullName.Substring($basePath.Length).TrimStart('\')
                $relPath -notmatch '^node_modules[\\/]'
            } |
            Sort-Object FullName |
            ForEach-Object {
                try {
                    $relative = [System.IO.Path]::GetRelativePath($Path, $_.FullName) -replace '\\', '/'
                    $hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
                    "$relative|$($_.Length)|$hash"
                } catch {
                    $relative = [System.IO.Path]::GetRelativePath($Path, $_.FullName) -replace '\\', '/'
                    "$relative|$($_.Length)|(inaccessible)"
                }
            }
        return Get-StringSha256 -Text (($rows -join "`n") + "`n")
    } catch {
        return '(error)'
    }
}

$RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
$HomeRoot = (Resolve-Path -LiteralPath $HomeRoot).Path
if (-not $OpenClawHomeRoot) {
    $OpenClawHomeRoot = Join-Path $HomeRoot '.openclaw'
}
if (-not $MachineId) {
    $MachineId = ConvertTo-KebabName -Name ([System.Net.Dns]::GetHostName())
}

$reportsRoot = Join-RepoPath -RepoRoot $RepoRoot -RelativePath 'imports/skills-reports'
New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null

# ---- sensitive paths to skip entirely ----
$sensitiveNames = @(
    'identity', 'credentials', 'devices',
    'auth-profiles.json', 'exec-approvals.json', 'node.json',
    'logs', 'sessions', 'caches', 'cache'
)

$sensitivePathSuffixes = @(
    [IO.Path]::DirectorySeparatorChar + 'logs',
    [IO.Path]::DirectorySeparatorChar + 'sessions',
    (Join-Path $OpenClawHomeRoot 'npm')
)

function Test-IsSensitivePath {
    param([string] $Path)
    $leaf = Split-Path -Leaf $Path
    if ($leaf -in $sensitiveNames) { return $true }
    foreach ($suffix in $sensitivePathSuffixes) {
        if ($Path.EndsWith($suffix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [object] $Default = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Convert-ToPortablePath {
    param([string] $Path)
    if (-not $Path) { return $Path }

    $normalized = $Path -replace '\\', '/'
    $homeNormalized = $HomeRoot -replace '\\', '/'
    $openClawNormalized = $OpenClawHomeRoot -replace '\\', '/'

    if ($normalized -match '/node_modules/openclaw/') {
        return '<OpenClawPackage>/' + ($normalized -replace '^.*?/node_modules/openclaw/', '')
    }
    if ($normalized.StartsWith($openClawNormalized, [StringComparison]::OrdinalIgnoreCase)) {
        return '<OpenClawHome>' + $normalized.Substring($openClawNormalized.Length)
    }
    if ($normalized.StartsWith($homeNormalized, [StringComparison]::OrdinalIgnoreCase)) {
        return '<HomeRoot>' + $normalized.Substring($homeNormalized.Length)
    }
    return $normalized
}

function Convert-ToPortablePluginSource {
    param(
        [string] $Source,
        [string] $PluginId,
        [string] $Origin
    )
    if (-not $Source) { return '' }

    $normalized = $Source -replace '\\', '/'
    $isLocalPath = $normalized -match '^[A-Za-z]:/' -or $normalized.StartsWith('/') -or $normalized.StartsWith('..')
    if (-not $isLocalPath) { return $Source }
    if ($Origin -eq 'bundled' -or $normalized -match '/dist/extensions/') {
        return "bundled:$PluginId"
    }
    return '<local-path-redacted>'
}

# ===================================================================
# STEP 2: Inventory skill roots
# ===================================================================
$skillRoots = @(
    [pscustomobject]@{ Label = 'openclaw-default';  Path = Join-Path $OpenClawHomeRoot 'skills' },
    [pscustomobject]@{ Label = 'openclaw-workspace'; Path = Join-Path $OpenClawHomeRoot 'workspace\skills' },
    [pscustomobject]@{ Label = 'openclaw-agents';    Path = Join-Path $OpenClawHomeRoot 'workspace\.agents\skills' },
    [pscustomobject]@{ Label = 'dot-agents';         Path = Join-Path $HomeRoot '.agents\skills' }
)

# Also try bundled npm skills
$bundledSkillRoot = $null
$openclawExe = Get-Command openclaw -ErrorAction SilentlyContinue
if ($openclawExe) {
    $openclawDir = Split-Path -Parent $openclawExe.Source
    $candidate = Join-Path $openclawDir 'node_modules\openclaw\skills'
    if (Test-Path -LiteralPath $candidate) {
        $bundledSkillRoot = $candidate
        $skillRoots += [pscustomobject]@{ Label = 'bundled-npm'; Path = $bundledSkillRoot }
    }
}

$skillRecords = [System.Collections.Generic.List[object]]::new()

foreach ($root in $skillRoots) {
    if (-not (Test-Path -LiteralPath $root.Path)) {
        $skillRecords.Add([pscustomobject]@{
            source_root_label = $root.Label
            source_root_path  = Convert-ToPortablePath -Path $root.Path
            source_root_exists = $false
            skill_name        = $null
            has_skill_md      = $false
            has_clawhub       = $false
            file_count        = 0
            total_size        = [int64]0
            tree_hash         = $null
            frontmatter_name  = $null
            frontmatter_description = $null
            classification    = 'missing-root'
        })
        continue
    }

    $skillDirs = @(Get-ChildItem -LiteralPath $root.Path -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { -not (Test-IsSensitivePath $_.FullName) })

    if ($skillDirs.Count -eq 0) {
        $skillRecords.Add([pscustomobject]@{
            source_root_label = $root.Label
            source_root_path  = Convert-ToPortablePath -Path $root.Path
            source_root_exists = $true
            skill_name        = $null
            has_skill_md      = $false
            has_clawhub       = $false
            file_count        = 0
            total_size        = [int64]0
            tree_hash         = $null
            frontmatter_name  = $null
            frontmatter_description = $null
            classification    = 'empty-root'
        })
        continue
    }

    foreach ($dir in $skillDirs) {
        $skillMd = Join-Path $dir.FullName 'SKILL.md'
        $hasSkillMd = Test-Path -LiteralPath $skillMd
        $clawhubDir = Join-Path $dir.FullName '.clawhub'
        $hasClawhub = Test-Path -LiteralPath $clawhubDir

        $skillDirFull = $dir.FullName
        $files = @(Get-ChildItem -LiteralPath $skillDirFull -File -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object {
                -not (Test-IsSensitivePath $_.FullName)
            } |
            Where-Object {
                $relPath = $_.FullName.Substring($skillDirFull.Length).TrimStart('\')
                $relPath -notmatch '^node_modules[\\/]'
            })
        $fileCount = $files.Count
        $totalSize = [int64]0
        if ($files.Count -gt 0) {
            $measureResult = $files | Measure-Object -Property Length -Sum
            if ($measureResult -and $null -ne $measureResult.Sum) { $totalSize = [int64]$measureResult.Sum }
        }
        $treeHash = Get-SafeTreeHash -Path $dir.FullName

        # frontmatter
        $fm = $null
        $fmName = $null
        $fmDesc = $null
        if ($hasSkillMd) {
            $fm = Get-SkillFrontMatter -SkillPath $dir.FullName
            $fmName = $fm.Name
            $fmDesc = $fm.Description
        }

        # signals (lightweight, no secret scanning for bundled)
        $signals = $null
        $class = 'unknown'
        if ($hasSkillMd -and $root.Label -ne 'bundled-npm') {
            try {
                $signals = Get-SkillSignals -RepoRoot $RepoRoot -SkillPath $dir.FullName
                $class = Get-SkillClassification -Signals $signals
            } catch {
                Write-Host "WARN: Signal scan failed for $($dir.FullName): $_"
                $class = 'scan-error'
            }
        }
        elseif ($root.Label -eq 'bundled-npm') {
            $class = 'bundled'
        }
        else {
            $class = 'no-skill-md'
        }

        $skillRecords.Add([pscustomobject]@{
            source_root_label = $root.Label
            source_root_path  = Convert-ToPortablePath -Path $root.Path
            source_root_exists = $true
            skill_name        = Split-Path -Leaf $dir.FullName
            has_skill_md      = $hasSkillMd
            has_clawhub       = $hasClawhub
            file_count        = $fileCount
            total_size        = $totalSize
            tree_hash         = $treeHash
            frontmatter_name  = $fmName
            frontmatter_description = $fmDesc
            classification    = $class
        })
    }
}

# ===================================================================
# STEP 3: Inventory plugins
# ===================================================================
$pluginRecords = [System.Collections.Generic.List[object]]::new()
$pluginSource = 'none'

# Read only the live installs.json fallback. Do not record package cache metadata.
$cliPlugins = $null
$installJsons = @(
    Join-Path $OpenClawHomeRoot 'plugins\installs.json'
)

foreach ($candidatePath in $installJsons) {
    if ($cliPlugins) { break }
    if (-not (Test-Path -LiteralPath $candidatePath)) { continue }
    Write-Host "Reading plugin state from: $candidatePath"
    try {
        $raw = Get-Content -LiteralPath $candidatePath -Raw | ConvertFrom-Json
        if ($raw -and $raw.plugins) {
            $cliPlugins = $raw
            $pluginSource = if ($candidatePath -match 'legacy') { 'installs.json.legacy' } else { 'installs.json' }
        }
    }
    catch {
        Write-Host "Failed to parse $candidatePath : $_"
    }
}

if ($cliPlugins -and $cliPlugins.plugins) {
    $pluginIndex = 0
    foreach ($p in $cliPlugins.plugins) {
        $pluginIndex++
        try {
            $pluginId = if ($p -is [string]) { $p } else { Get-ObjectPropertyValue -Object $p -Name 'pluginId' -Default (Get-ObjectPropertyValue -Object $p -Name 'id' -Default '') }
            if (-not $pluginId) { $pluginId = '' }
            $origin = if ($p -is [string]) { 'unknown' } else { Get-ObjectPropertyValue -Object $p -Name 'origin' -Default '' }
            if (-not $origin) { $origin = '' }
            $enabled = if ($p -is [string]) { $null } else { Get-ObjectPropertyValue -Object $p -Name 'enabled' }
            if ($null -eq $enabled) { $enabled = $false }
        } catch {
            Write-Host "WARN: Plugin at index $pluginIndex has no expected fields: $_"
            continue
        }

        $source = ''
        if ($p -isnot [string]) {
            $source = Get-ObjectPropertyValue -Object $p -Name 'source' -Default ''
        }
        $source = Convert-ToPortablePluginSource -Source $source -PluginId $pluginId -Origin $origin

        # Classify
        $class = 'unknown-or-broken'
        if ($origin -eq 'bundled') {
            $class = 'bundled'
        }
        elseif ($origin -in @('global', 'npm', 'managed') -and $source) {
            $class = 'managed-install'
        }
        elseif ($source -match '\.\./|^[A-Za-z]:' -and $source -notmatch 'node_modules') {
            $class = 'linked-local'
        }
        elseif ($source) {
            $class = 'managed-install'
        }

        $pluginRecords.Add([pscustomobject]@{
            plugin_id        = $pluginId
            origin           = $origin
            enabled          = $enabled
            source_spec      = $source
            classification   = $class
        })
    }
}

# Also discover bundled plugins from npm package if CLI/installs.json didn't cover them
if ($pluginRecords.Count -eq 0 -and $openclawExe) {
    $pluginOpenclawDir = Split-Path -Parent $openclawExe.Source
    $extDir = Join-Path $pluginOpenclawDir 'node_modules\openclaw\dist\extensions'
    if (Test-Path -LiteralPath $extDir) {
        $extDirs = @(Get-ChildItem -LiteralPath $extDir -Directory -ErrorAction SilentlyContinue)
        foreach ($ed in $extDirs) {
            $manifestPath = Join-Path $ed.FullName 'openclaw.plugin.json'
            $enabled = 'unknown'
            if (Test-Path -LiteralPath $manifestPath) {
                try {
                    $manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
                    $enabled = if ($manifest.enabledByDefault) { 'default' } else { 'unknown' }
                } catch {}
            }
            $pluginRecords.Add([pscustomobject]@{
                plugin_id        = $ed.Name
                origin           = 'bundled'
                enabled          = $enabled
                source_spec      = "bundled:$($ed.Name)"
                classification   = 'bundled'
            })
        }
        $pluginSource = 'bundled-discovery'
    }
}

# ===================================================================
# STEP 4: Assemble inventory and write reports
# ===================================================================
$skillSummary = $skillRecords | Where-Object { $_.skill_name } | Group-Object source_root_label | ForEach-Object {
    $groupItems = @($_.Group)
    $sumFiles = 0; $sumSize = 0L
    foreach ($item in $groupItems) { $sumFiles += $item.file_count; $sumSize += $item.total_size }
    [pscustomobject]@{
        source_root = $_.Name
        skill_count = $_.Count
        with_clawhub = @($groupItems | Where-Object { $_.has_clawhub }).Count
        total_file_count = $sumFiles
        total_size_bytes = $sumSize
    }
}

$pluginSummary = $pluginRecords | Group-Object classification | ForEach-Object {
    [pscustomobject]@{
        classification = $_.Name
        count = $_.Count
        enabled_count = @($_.Group | Where-Object { $_.enabled -eq $true }).Count
        disabled_count = @($_.Group | Where-Object { $_.enabled -eq $false }).Count
    }
}

$inventory = [pscustomobject]@{
    generated_at        = (Get-Date -Format 'o')
    machine_id          = $MachineId
    openclaw_home_root  = Convert-ToPortablePath -Path $OpenClawHomeRoot
    plugin_source       = $pluginSource
    summary = [pscustomobject]@{
        total_skill_roots_scanned = @($skillRecords | Where-Object { $_.source_root_exists } | Select-Object -ExpandProperty source_root_label -Unique).Count
        total_skills_found        = ($skillRecords | Where-Object { $_.skill_name }).Count
        total_plugins_found       = $pluginRecords.Count
        skill_summary             = @($skillSummary)
        plugin_summary            = @($pluginSummary)
    }
    skills  = @($skillRecords)
    plugins = @($pluginRecords)
}

# Write JSON
$jsonPath = Join-Path $reportsRoot 'openclaw-inventory.json'
$json = $inventory | ConvertTo-Json -Depth 10
Write-Utf8NoBomFile -Path $jsonPath -Content ($json + "`n")

# Write human-readable markdown
$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add("# OpenClaw Inventory Report")
$lines.Add('')
$lines.Add("**Generated:** $($inventory.generated_at)")
$lines.Add("**Machine:** $MachineId")
$lines.Add("**Plugin source method:** $pluginSource")
$lines.Add("**OpenClaw home:** ``$(Convert-ToPortablePath -Path $OpenClawHomeRoot)``")
$lines.Add('')

# --- Skill Summary ---
$lines.Add('## Skills Summary')
$lines.Add('')
$lines.Add('| Source Root | Skills | With .clawhub | Total Files | Total Size |')
$lines.Add('| --- | ---: | ---: | ---: | ---: |')
foreach ($s in $skillSummary) {
    $sizeDisplay = if ($s.total_size_bytes -gt 1MB) { "$([math]::Round($s.total_size_bytes / 1MB, 2)) MB" } elseif ($s.total_size_bytes -gt 1KB) { "$([math]::Round($s.total_size_bytes / 1KB, 2)) KB" } else { "$($s.total_size_bytes) B" }
    $lines.Add("| $($s.source_root) | $($s.skill_count) | $($s.with_clawhub) | $($s.total_file_count) | $sizeDisplay |")
}
$lines.Add('')

# --- Plugin Summary ---
$lines.Add('## Plugins Summary')
$lines.Add('')
$lines.Add('| Classification | Count | Enabled | Disabled |')
$lines.Add('| --- | ---: | ---: | ---: |')
foreach ($p in $pluginSummary) {
    $lines.Add("| $($p.classification) | $($p.count) | $($p.enabled_count) | $($p.disabled_count) |")
}
$lines.Add('')

# --- Skill Details ---
$lines.Add('## Skill Details')
$lines.Add('')

# Group by root
$grouped = $skillRecords | Where-Object { $_.skill_name } | Group-Object source_root_label
foreach ($g in $grouped) {
    $lines.Add("### $($g.Name) ($($g.Count) skills)")
    $lines.Add('')
    $lines.Add('| Skill Name | Has SKILL.md | .clawhub | Files | Size | Classification | Frontmatter Name |')
    $lines.Add('| --- | --- | --- | ---: | ---: | --- | --- |')
    foreach ($r in $g.Group) {
        $sizeDisplay = if ($r.total_size -gt 1MB) { "$([math]::Round($r.total_size / 1MB, 2)) MB" } elseif ($r.total_size -gt 1KB) { "$([math]::Round($r.total_size / 1KB, 2)) KB" } else { "$($r.total_size) B" }
        $lines.Add("| $($r.skill_name) | $($r.has_skill_md) | $($r.has_clawhub) | $($r.file_count) | $sizeDisplay | $($r.classification) | $($r.frontmatter_name) |")
    }
    $lines.Add('')
}

# --- Plugin Details ---
$lines.Add('## Plugin Details')
$lines.Add('')
$groupedPlugins = $pluginRecords | Group-Object classification
foreach ($g in $groupedPlugins) {
    $lines.Add("### $($g.Name) ($($g.Count) plugins)")
    $lines.Add('')
    $lines.Add('| Plugin ID | Origin | Enabled | Source | Classification |')
    $lines.Add('| --- | --- | --- | --- | --- |')
    foreach ($r in $g.Group) {
        $lines.Add("| $($r.plugin_id) | $($r.origin) | $($r.enabled) | $($r.source_spec) | $($r.classification) |")
    }
    $lines.Add('')
}

# Report missing roots
$missing = $skillRecords | Where-Object { -not $_.source_root_exists }
if ($missing) {
    $lines.Add('## Missing Skill Roots')
    $lines.Add('')
    foreach ($m in $missing) {
        $lines.Add("- **$($m.source_root_label):** ``$($m.source_root_path)`` (not found)")
    }
    $lines.Add('')
}

$mdPath = Join-Path $reportsRoot 'openclaw-inventory.md'
Write-Utf8NoBomFile -Path $mdPath -Content (($lines -join "`n") + "`n")

Write-Host "Inventory complete."
Write-Host "  Skills found : $(($skillRecords | Where-Object { $_.skill_name }).Count)"
Write-Host "  Plugins found: $($pluginRecords.Count)"
Write-Host "  JSON report  : $jsonPath"
Write-Host "  MD report    : $mdPath"
