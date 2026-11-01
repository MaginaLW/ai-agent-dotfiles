#requires -Version 7.0
<#
.SYNOPSIS
    Self-contained regression tests for harness profile scripts.

.DESCRIPTION
    No Pester dependency. Runs the real harness profile scripts against isolated
    project and harness-source trees under the repository's ignored tmp directory.
    A checkout inside the user home is refused before fixtures are created, matching
    the production home-write boundary. The workspace is removed on success and
    kept on failure.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$statusScript = Join-Path $RepoRoot 'scripts/status-harness-profile.ps1'
$buildScript = Join-Path $RepoRoot 'scripts/build-harness-profile.ps1'
$applyScript = Join-Path $RepoRoot 'scripts/apply-harness-profile.ps1'
$fixtureProject = Join-Path $RepoRoot 'tests/fixtures/harness-profile/project'

$script:pass = 0
$script:fail = 0
function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

# Keep every fixture inside the checkout without weakening the product's home guard.
if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
    $profile = [IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')
    if ($RepoRoot -ieq $profile -or $RepoRoot.StartsWith($profile + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Harness profile tests require a checkout outside the user home; fixtures stay under the repository tmp directory.'
    }
}
$workBase = Join-Path $RepoRoot 'tmp/tests/harness-profile'
. (Join-Path $PSScriptRoot '../scripts/harness-profile-common.ps1')
Assert-HarnessNoReparsePath -Paths @($workBase)
$work = Join-Path $workBase ([Guid]::NewGuid().ToString('N'))
function Remove-Work {
    if ((Split-Path -Parent $work) -ne $workBase -or (Split-Path -Leaf $work) -notmatch '^[a-f0-9]{32}$') {
        throw 'Refusing to clean an unowned harness profile test workspace.'
    }
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { $_.Delete() }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Remove-Work
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    Set-TestFile -Path $Path -Content ($Content ?? '')
}

function Invoke-Script {
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    Invoke-TestProcess -ScriptPath $Script -Arguments $ScriptArgs
}

function Escape-Psd1String {
    param([Parameter(Mandatory)] [string] $Value)
    return ($Value -replace "'", "''")
}

function Join-Psd1Array([string[]] $Values) {
    return '@(' + (($Values | ForEach-Object { "'" + (Escape-Psd1String $_) + "'" }) -join ', ') + ')'
}

# Writes only the Components buckets that are given; a profile without any bucket has no
# Components key at all.
function New-ProjectProfileText {
    param(
        [string[]] $TargetPlatforms = @('Claude', 'Codex'),
        [string[]] $Extends = @(),
        [string[]] $Rules = @(),
        [string[]] $Prompts = @(),
        [string[]] $Commands = @(),
        [string[]] $Agents = @(),
        [string[]] $ClaudeSettings = @(),
        [string[]] $CodexAgents = @(),
        [string] $ExtraComponentLine = '',
        [string] $ExtraLine = ''
    )

    $buckets = [ordered] @{ Rules = $Rules; Prompts = $Prompts; Commands = $Commands; Agents = $Agents; ClaudeSettings = $ClaudeSettings; CodexAgents = $CodexAgents }
    $lines = @(foreach ($bucket in $buckets.Keys) {
            if ($buckets[$bucket].Count -gt 0) { "        $bucket = $(Join-Psd1Array $buckets[$bucket])" }
        }) + @($ExtraComponentLine | Where-Object { $_ })
    $components = if ($lines.Count -gt 0) { "    Components = @{`n$($lines -join "`n")`n    }`n" } else { '' }
    return @"
@{
    SchemaVersion = 1
    Name = 'harness-profile-test'
    TargetPlatforms = $(Join-Psd1Array $TargetPlatforms)
    Extends = $(Join-Psd1Array $Extends)
$components$ExtraLine
}
"@
}

function New-TestProject {
    param(
        [Parameter(Mandatory)] [string] $Name,
        [string] $ProfileText = (New-ProjectProfileText -Rules @('safe-file-edits', 'no-generated-output-edits') -Prompts @('commit-summary') -Commands @('command-helper') -ClaudeSettings @('project-guards'))
    )
    $project = Join-Path $work $Name
    if (Test-Path -LiteralPath $project) { Remove-Item -LiteralPath $project -Recurse -Force }
    Copy-Item -LiteralPath $fixtureProject -Destination $project -Recurse -Force
    Set-File -Path (Join-Path $project '.agent-harness/profile.psd1') -Content $ProfileText
    return $project
}

function Add-Component {
    param(
        [Parameter(Mandatory)] [string] $HarnessRepo,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Id,
        [string] $Kind = 'Rule',
        [string[]] $TargetPlatforms = @('Claude', 'Codex'),
        [Parameter(Mandatory)] [string] $Target,
        [Parameter(Mandatory)] [string] $Mode,
        [string] $BlockId,
        [string] $Content,
        [string] $SettingsJson,
        [string] $Source
    )
    $dir = Join-Path (Join-Path $HarnessRepo 'harness-source/components') $Path
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $extra = if ($BlockId) { "            BlockId = '$(Escape-Psd1String $BlockId)'`n" } else { '' }
    $extra += if ($Source) { "            Source = '$(Escape-Psd1String $Source)'`n" } else { '' }
    $component = @"
@{
    SchemaVersion = 1
    Id = '$(Escape-Psd1String $Id)'
    Kind = '$(Escape-Psd1String $Kind)'
    TargetPlatforms = $(Join-Psd1Array $TargetPlatforms)
    Outputs = @(
        @{
            Target = '$(Escape-Psd1String $Target)'
            Mode = '$(Escape-Psd1String $Mode)'
$extra        }
    )
}
"@
    Set-File -Path (Join-Path $dir 'component.psd1') -Content $component
    if ($PSBoundParameters.ContainsKey('Content')) {
        $contentName = if ([string]::IsNullOrWhiteSpace($Source)) { 'content.md' } else { $Source }
        Set-File -Path (Join-Path $dir $contentName) -Content $Content
    }
    if ($PSBoundParameters.ContainsKey('SettingsJson')) { Set-File -Path (Join-Path $dir 'settings.json') -Content $SettingsJson }
}

function New-TestHarnessRepo {
    param([Parameter(Mandatory)] [string] $Name)
    $repo = Join-Path $work $Name
    New-Item -ItemType Directory -Path (Join-Path $repo 'scripts') -Force | Out-Null
    New-Item -ItemType Directory -Path (Join-Path $repo 'harness-source/profiles') -Force | Out-Null
    foreach ($name in @(
        'scan-secrets.ps1',
        'pinned-tool.ps1',
        'repo-common.ps1'
    )) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "scripts/$name") -Destination (Join-Path $repo "scripts/$name") -Force
    }
    New-Item -ItemType Directory -Path (Join-Path $repo 'tools/gitleaks') -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $repo 'tools/gitleaks/gitleaks.lock.json') -Force
    $gitleaks = Join-Path $RepoRoot '.gitleaks.toml'
    if (Test-Path -LiteralPath $gitleaks) { Copy-Item -LiteralPath $gitleaks -Destination $repo -Force }
    & git -C $repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize harness fixture repository: $repo" }

    Set-File -Path (Join-Path $repo 'harness-source/profiles/base.psd1') -Content (New-ProjectProfileText -TargetPlatforms @('Claude', 'Codex'))
    Add-Component -HarnessRepo $repo -Path 'rules/safe-file-edits' -Id 'safe-file-edits' -Kind 'Rule' -Target 'AGENTS.md' -Mode 'ManagedBlock' -BlockId 'safe-file-edits' -Content "Safe file edit rule.`n"
    Add-Component -HarnessRepo $repo -Path 'rules/no-generated-output-edits' -Id 'no-generated-output-edits' -Kind 'Rule' -Target 'AGENTS.md' -Mode 'ManagedBlock' -BlockId 'no-generated-output-edits' -Content "Generated output rule.`n"
    Add-Component -HarnessRepo $repo -Path 'prompts/commit-summary' -Id 'commit-summary' -Kind 'Prompt' -Target '.agent-harness/generated/prompts/commit-summary.md' -Mode 'GeneratedOnly' -Content "Summarize commits clearly.`n"
    Add-Component -HarnessRepo $repo -Path 'commands/command-helper' -Id 'command-helper' -Kind 'Command' -Target '.claude/commands/harness-helper.md' -Mode 'DirectoryFiles' -Content "Run the harness helper.`n"
    Add-Component -HarnessRepo $repo -Path 'claude-settings/project-guards' -Id 'project-guards' -Kind 'ClaudeSettings' -Target '.claude/settings.json' -Mode 'StructuredMerge' -SettingsJson @'
{
  "permissions": {
    "deny": [
      "Bash(git reset --hard:*)",
      "Bash(robocopy /MIR:*)"
    ],
    "allow": [
      "Read(*)"
    ]
  },
  "env": {
    "harnessProfile": "enabled"
  }
}
'@
    return $repo
}

function Get-FileSnapshot {
    param([Parameter(Mandatory)] [string] $Root)
    $snapshot = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $snapshot }
    foreach ($file in Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName) {
        $relative = [System.IO.Path]::GetRelativePath($Root, $file.FullName) -replace '\\', '/'
        $snapshot[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
    }
    return $snapshot
}

function Compare-FileSnapshot {
    param([hashtable] $Before, [hashtable] $After)
    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $Before.Keys) {
        if (-not $After.ContainsKey($key)) {
            $changes.Add([pscustomobject] @{ Path = $key; Kind = 'deleted' })
        }
        elseif ($Before[$key] -ne $After[$key]) {
            $changes.Add([pscustomobject] @{ Path = $key; Kind = 'changed' })
        }
    }
    foreach ($key in $After.Keys) {
        if (-not $Before.ContainsKey($key)) {
            $changes.Add([pscustomobject] @{ Path = $key; Kind = 'added' })
        }
    }
    return @($changes | Sort-Object Path, Kind)
}

function Get-NormalizedGeneratedMetadata {
    param([Parameter(Mandatory)] [string] $ProjectRoot)
    function ConvertTo-SortedObject {
        param([AllowNull()] $Value)
        if ($null -eq $Value) { return $null }
        if ($Value -is [array]) {
            return ,@($Value | ForEach-Object { ConvertTo-SortedObject $_ })
        }
        if ($Value -is [System.Collections.IDictionary]) {
            $result = [ordered] @{}
            foreach ($key in @($Value.Keys | Sort-Object)) {
                $result[[string] $key] = ConvertTo-SortedObject $Value[$key]
            }
            return $result
        }
        if ($Value -is [pscustomobject]) {
            $result = [ordered] @{}
            foreach ($property in @($Value.PSObject.Properties | Sort-Object Name)) {
                $result[$property.Name] = ConvertTo-SortedObject $property.Value
            }
            return $result
        }
        return $Value
    }

    $generated = Join-Path $ProjectRoot '.agent-harness/generated'
    $plan = Get-Content -Raw -LiteralPath (Join-Path $generated 'plan.json') | ConvertFrom-Json
    $manifest = Get-Content -Raw -LiteralPath (Join-Path $generated 'manifest.json') | ConvertFrom-Json
    $manifest.PSObject.Properties.Remove('generatedAt')
    $manifest.generatedFiles = @($manifest.generatedFiles | Where-Object { $_.path -notin @('plan.json', 'manifest.json') })
    return (ConvertTo-SortedObject ([pscustomobject] @{
        Plan = $plan
        Manifest = $manifest
    })) | ConvertTo-Json -Depth 50 -Compress
}

function Assert-Fails {
    param([scriptblock] $Run, [string] $Pattern, [string] $Message)
    $result = & $Run
    Assert (($result.Code -ne 0) -and ($result.Out -match $Pattern)) $Message
}

# ===========================================================================
Write-Host "`n[harness profile basics]" -ForegroundColor Cyan
# ===========================================================================
$repo = New-TestHarnessRepo -Name 'normal-repo'

$project = New-TestProject -Name 'status-project'
$before = Get-FileSnapshot -Root $project
$r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project, '-Json')
$after = Get-FileSnapshot -Root $project
Assert ($r.Code -eq 0) 'status: exits successfully'
Assert (@(Compare-FileSnapshot -Before $before -After $after).Count -eq 0) 'status: read-only'

$project = New-TestProject -Name 'build-project'
$before = Get-FileSnapshot -Root $project
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
$after = Get-FileSnapshot -Root $project
$changes = @(Compare-FileSnapshot -Before $before -After $after)
Assert ($r.Code -eq 0) 'build: exits successfully'
Assert (($changes.Count -gt 0) -and (@($changes | Where-Object { $_.Path -notlike '.agent-harness/generated/*' }).Count -eq 0)) 'build: writes only .agent-harness/generated/'

$metadata1 = Get-NormalizedGeneratedMetadata -ProjectRoot $project
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
$metadata2 = Get-NormalizedGeneratedMetadata -ProjectRoot $project
Assert ($r.Code -eq 0 -and $metadata1 -eq $metadata2) 'build: repeated build is idempotent except generatedAt'

$project = New-TestProject -Name 'replace-project'
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
Assert ($r.Code -eq 0) 'build: baseline build succeeds'
Set-File -Path (Join-Path $project '.agent-harness/generated/stale-extra.md') 'stale'
Set-File -Path (Join-Path $project '.agent-harness/profile.psd1') -Content (New-ProjectProfileText -Rules @('safe-file-edits') -Commands @('command-helper'))
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
Assert ($r.Code -eq 0) 'build: rebuild after a profile change succeeds'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/generated/stale-extra.md'))) 'a rebuild without -Clean removes stale generated files'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/generated/prompts/commit-summary.md'))) 'a rebuild removes files the new profile no longer generates'
$replaceManifest = Get-Content -Raw -LiteralPath (Join-Path $project '.agent-harness/generated/manifest.json') | ConvertFrom-Json
Assert (@($replaceManifest.generatedFiles | Where-Object { $_.path -in @('stale-extra.md', 'prompts/commit-summary.md') }).Count -eq 0) 'the manifest lists no stale generated files'

$project = New-TestProject -Name 'dry-run-project'
$before = Get-FileSnapshot -Root $project
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
$after = Get-FileSnapshot -Root $project
Assert ($r.Code -eq 0 -and $r.Out -match 'Dry-run only') 'apply dry-run: reports dry-run'
Assert (@(Compare-FileSnapshot -Before $before -After $after).Count -eq 0) 'apply dry-run: writes nothing'

$project = New-TestProject -Name 'apply-project'
$before = Get-FileSnapshot -Root $project
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project, '-Apply')
$after = Get-FileSnapshot -Root $project
$changes = @(Compare-FileSnapshot -Before $before -After $after)
$allowedWrites = @(
    'AGENTS.md',
    '.claude/settings.json',
    '.claude/commands/harness-helper.md'
)
$unexpected = @($changes | Where-Object {
    ($_.Path -notin $allowedWrites) -and
    ($_.Path -notlike '.agent-harness/backups/*')
})
Assert ($r.Code -eq 0) 'apply: exits successfully'
Assert ($unexpected.Count -eq 0) 'apply: writes only allowlisted project targets and backups'

$before = Get-FileSnapshot -Root $project
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
$after = Get-FileSnapshot -Root $project
Assert ($r.Code -eq 0 -and $r.Out -match 'noop\s+AGENTS.md' -and $r.Out -match 'noop\s+\.claude/settings.json') 'repeat dry-run: reports no-op for applied targets'
Assert ($r.Out -notmatch '(?m)^\s+(add|update)\s+(AGENTS\.md|\.claude/settings\.json|\.claude/commands/harness-helper\.md)') 'repeat dry-run: no add/update for applied targets'
Assert (@(Compare-FileSnapshot -Before $before -After $after).Count -eq 0) 'repeat dry-run: writes nothing'
$r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project, '-Json')
$status = $r.Out | ConvertFrom-Json
$statusWritable = @($status.Targets | Where-Object { $_.Mode -ne 'GeneratedOnly' })
Assert ($r.Code -eq 0 -and @($statusWritable | Where-Object { $_.Action -ne 'noop' }).Count -eq 0) 'status after apply: writable targets report no-op'

# ===========================================================================
Write-Host "`n[managed blocks and settings]" -ForegroundColor Cyan
# ===========================================================================
$ruleOnlyProfile = New-ProjectProfileText -Rules @('safe-file-edits')
$project = New-TestProject -Name 'no-marker-project' -ProfileText $ruleOnlyProfile
$agentsPath = Join-Path $project 'AGENTS.md'
Set-File -Path $agentsPath -Content "Existing project instructions without harness markers.`n"
$beforeText = Get-Content -Raw -LiteralPath $agentsPath
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project, '-Apply')
$afterText = Get-Content -Raw -LiteralPath $agentsPath
Assert ($r.Code -eq 0 -and $r.Out -match 'skip\s+AGENTS.md') 'managed block: existing file without markers is skipped'
Assert ($beforeText -eq $afterText) 'managed block: existing AGENTS.md without markers is not modified'

$project = New-TestProject -Name 'marker-project' -ProfileText $ruleOnlyProfile
$agentsPath = Join-Path $project 'AGENTS.md'
Set-File -Path $agentsPath -Content @'
Before
<!-- BEGIN AGENT-HARNESS: safe-file-edits -->
old managed text
<!-- END AGENT-HARNESS: safe-file-edits -->
After
'@
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project, '-Apply')
$afterText = Get-Content -Raw -LiteralPath $agentsPath
Assert ($r.Code -eq 0 -and $afterText -match 'Safe file edit rule' -and $afterText -notmatch 'old managed text') 'managed block: marker block replacement works'

$settingsOnlyProfile = New-ProjectProfileText -ClaudeSettings @('project-guards')
$project = New-TestProject -Name 'settings-project' -ProfileText $settingsOnlyProfile
Set-File -Path (Join-Path $project '.claude/settings.json') -Content @'
{
  "theme": "dark",
  "nested": {
    "keep": true
  },
  "permissions": {
    "deny": [
      "Bash(rm -rf:*)"
    ],
    "allow": [
      "Write(*)"
    ]
  }
}
'@
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project, '-Apply')
$settings = Get-Content -Raw -LiteralPath (Join-Path $project '.claude/settings.json') | ConvertFrom-Json
Assert ($r.Code -eq 0 -and $settings.theme -eq 'dark' -and $settings.nested.keep -eq $true) '.claude/settings.json: preserves unmanaged keys'
Assert (@($settings.permissions.deny) -contains 'Bash(rm -rf:*)') '.claude/settings.json: preserves existing permissions.deny entries'

$denyRepo = New-TestHarnessRepo -Name 'deny-removal-repo'
Add-Component -HarnessRepo $denyRepo -Path 'claude-settings/bad-permissions' -Id 'bad-permissions' -Kind 'ClaudeSettings' -Target '.claude/settings.json' -Mode 'StructuredMerge' -SettingsJson '{"permissions":"replace"}'
$project = New-TestProject -Name 'deny-removal-project' -ProfileText (New-ProjectProfileText -ClaudeSettings @('bad-permissions'))
Set-File -Path (Join-Path $project '.claude/settings.json') -Content '{"permissions":{"deny":["Bash(rm -rf:*)"]}}'
$before = Get-FileSnapshot -Root $project
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $denyRepo, '-ProjectRoot', $project, '-Apply')
$after = Get-FileSnapshot -Root $project
Assert ($r.Code -ne 0 -and $r.Out -match 'permissions\.deny') 'permissions.deny: removal is rejected'
Assert (@(Compare-FileSnapshot -Before $before -After $after).Count -eq 0) 'permissions.deny: failed apply writes nothing'

$sourceRepo = New-TestHarnessRepo -Name 'named-source-repo'
Add-Component -HarnessRepo $sourceRepo -Path 'commands/named-source' -Id 'named-source' -Kind 'Command' -Target '.claude/commands/named.md' -Mode 'DirectoryFiles' -Source 'body.md' -Content "Named source body.`n"
$project = New-TestProject -Name 'named-source-project' -ProfileText (New-ProjectProfileText -Commands @('named-source'))
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $sourceRepo, '-ProjectRoot', $project, '-Apply')
$written = Join-Path $project '.claude/commands/named.md'
Assert ($r.Code -eq 0 -and (Test-Path -LiteralPath $written) -and ((Get-Content -Raw -LiteralPath $written) -ceq "Named source body.`n")) 'DirectoryFiles: apply writes the declared Source file'

# ===========================================================================
Write-Host "`n[Claude and Codex directory outputs]" -ForegroundColor Cyan
# ===========================================================================
# The project extends a library profile that extends base and selects one DirectoryFiles
# component of every Kind, Claude-only and Codex-only.
$platformRepo = New-TestHarnessRepo -Name 'platform-repo'
Add-Component -HarnessRepo $platformRepo -Path 'agents/claude-reviewer' -Id 'claude-reviewer' -Kind 'ClaudeAgent' -TargetPlatforms @('Claude') -Target '.claude/agents/reviewer.md' -Mode 'DirectoryFiles' -Content "Claude reviewer.`n"
Add-Component -HarnessRepo $platformRepo -Path 'codex-prompts/review-prompt' -Id 'review-prompt' -Kind 'CodexPrompt' -TargetPlatforms @('Codex') -Target '.codex/prompts/review.md' -Mode 'DirectoryFiles' -Content "Codex review prompt.`n"
Add-Component -HarnessRepo $platformRepo -Path 'codex-agents/reviewer' -Id 'codex-reviewer' -Kind 'CodexAgent' -TargetPlatforms @('Codex') -Target '.codex/agents/reviewer.md' -Mode 'DirectoryFiles' -Content "Codex reviewer.`n"
Set-File -Path (Join-Path $platformRepo 'harness-source/profiles/reviewers.psd1') -Content (New-ProjectProfileText -Extends @('base') -Commands @('command-helper') -Agents @('claude-reviewer') -CodexAgents @('review-prompt', 'codex-reviewer'))
$platformProfile = New-ProjectProfileText -Extends @('reviewers')
$directoryTargets = @('.claude/commands/harness-helper.md', '.claude/agents/reviewer.md', '.codex/prompts/review.md', '.codex/agents/reviewer.md')

$project = New-TestProject -Name 'platform-build-project' -ProfileText $platformProfile
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $platformRepo, '-ProjectRoot', $project)
$generated = Join-Path $project '.agent-harness/generated'
Assert ($r.Code -eq 0) 'directory outputs: build exits successfully'
Assert (@($directoryTargets | Where-Object { -not (Test-Path -LiteralPath (Join-Path $generated "files/$_") -PathType Leaf) }).Count -eq 0) 'directory outputs: build emits every target under files/'
$plan = Get-Content -Raw -LiteralPath (Join-Path $generated 'plan.json') | ConvertFrom-Json
Assert ((@($plan.resolvedProfiles.name) -join ',') -eq 'base,reviewers') 'directory outputs: Extends resolves parent-first'
Assert ((@($plan.componentIds) -join ',') -eq 'command-helper,claude-reviewer,review-prompt,codex-reviewer') 'directory outputs: component ids follow bucket order'

$project = New-TestProject -Name 'platform-apply-project' -ProfileText $platformProfile
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $platformRepo, '-ProjectRoot', $project, '-Apply')
Assert ($r.Code -eq 0) 'directory outputs: apply exits successfully'
Assert (@($directoryTargets | Where-Object { -not (Test-Path -LiteralPath (Join-Path $project $_) -PathType Leaf) }).Count -eq 0) 'directory outputs: apply writes every target'
Assert (@(Get-ChildItem -LiteralPath (Join-Path $project '.agent-harness/backups') -Filter 'manifest.json' -File -Recurse -ErrorAction SilentlyContinue).Count -eq 1) 'directory outputs: apply writes a project-local backup manifest'
$r = Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $platformRepo, '-ProjectRoot', $project, '-Json')
$status = $r.Out | ConvertFrom-Json
Assert ($r.Code -eq 0 -and @($status.Targets).Count -eq 4 -and @($status.Targets | Where-Object Action -NE 'noop').Count -eq 0) 'directory outputs: status after apply reports no-op'

# A directory in place of the last target makes its write fail after the first three.
$project = New-TestProject -Name 'platform-rollback-project' -ProfileText $platformProfile
New-Item -ItemType Directory -Path (Join-Path $project '.codex/agents/reviewer.md') -Force | Out-Null
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $platformRepo, '-ProjectRoot', $project, '-Apply')
Assert ($r.Code -ne 0 -and $r.Out -match 'best-effort rollback for 4 attempted file') 'rollback: failed apply is reported'
Assert (@($directoryTargets[0..2] | Where-Object { Test-Path -LiteralPath (Join-Path $project $_) }).Count -eq 0) 'rollback: earlier writes are removed'
Assert (Test-Path -LiteralPath (Join-Path $project $directoryTargets[3]) -PathType Container) 'rollback: the pre-existing blocker directory is preserved'

foreach ($existing in @($false, $true)) {
    $project = New-TestProject -Name "partial-write-$existing" -ProfileText (New-ProjectProfileText -Commands @('command-helper'))
    $target = Join-Path $project '.claude/commands/harness-helper.md'
    if ($existing) { Set-File -Path $target -Content 'original command' }
    $wrapper = Join-Path $work "partial-write-$existing.ps1"
    Set-File -Path $wrapper -Content @'
param([string]$ScriptPath,[string]$HarnessRepo,[string]$Project,[string]$FaultTarget)
$ErrorActionPreference = 'Stop'
$env:HARNESS_TEST_FAULT_TARGET = $FaultTarget
function Set-Content {
    [CmdletBinding()]
    param([Parameter(ValueFromPipeline=$true)]$Value,[string]$LiteralPath,[string]$Encoding,[switch]$NoNewline)
    process {
        if ($LiteralPath -eq $env:HARNESS_TEST_FAULT_TARGET) {
            [IO.File]::WriteAllText($LiteralPath, 'partial write')
            throw 'injected profile write failure'
        }
        Microsoft.PowerShell.Management\Set-Content @PSBoundParameters
    }
}
& $ScriptPath -RepoRoot $HarnessRepo -ProjectRoot $Project -Apply
'@
    $r = Invoke-Script -Script $wrapper -ScriptArgs @('-ScriptPath', $applyScript, '-HarnessRepo', $repo, '-Project', $project, '-FaultTarget', $target)
    Assert ($r.Code -ne 0 -and $r.Out -match 'injected profile write failure') "rollback: partial write is reported (existing=$existing)"
    if ($existing) {
        Assert ((Get-Content -Raw -LiteralPath $target) -ceq 'original command') 'rollback: the partially overwritten current file is restored'
    }
    else { Assert (-not (Test-Path -LiteralPath $target)) 'rollback: the partially created current file is removed' }
}

$project = New-TestProject -Name 'platform-mismatch-project' -ProfileText (New-ProjectProfileText -TargetPlatforms @('Codex') -Agents @('claude-reviewer'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $platformRepo, '-ProjectRoot', $project) } -Pattern 'does not support any selected target platform' -Message 'validation: component without a selected target platform fails'

# ===========================================================================
Write-Host "`n[validation failures]" -ForegroundColor Cyan
# ===========================================================================
$dupeRepo = New-TestHarnessRepo -Name 'duplicate-repo'
Add-Component -HarnessRepo $dupeRepo -Path 'rules/duplicate-safe-file-edits' -Id 'safe-file-edits' -Kind 'Rule' -Target 'AGENTS.md' -Mode 'ManagedBlock' -Content 'duplicate'
$project = New-TestProject -Name 'duplicate-project' -ProfileText (New-ProjectProfileText -Rules @('safe-file-edits'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $dupeRepo, '-ProjectRoot', $project) } -Pattern 'Duplicate harness component' -Message 'validation: duplicate component IDs fail'

foreach ($retiredKey in @('Future', 'RequiredEnv')) {
    $project = New-TestProject -Name "unknown-$retiredKey-project" -ProfileText (New-ProjectProfileText -Rules @('safe-file-edits') -ExtraLine "    $retiredKey = 'unused'")
    Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project) } -Pattern "unknown key '$retiredKey'" -Message "validation: retired top-level key $retiredKey is rejected"
}

$componentKeyRepo = New-TestHarnessRepo -Name 'component-key-repo'
$keyComponent = Join-Path $componentKeyRepo 'harness-source/components/rules/safe-file-edits/component.psd1'
Set-File -Path $keyComponent -Content ((Get-Content -Raw -LiteralPath $keyComponent) -replace "(?m)^(\s*Kind = 'Rule')", "`$1`n    Requires = @()")
$project = New-TestProject -Name 'component-key-project' -ProfileText (New-ProjectProfileText -Rules @('safe-file-edits'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $componentKeyRepo, '-ProjectRoot', $project) } -Pattern "unknown key 'Requires'" -Message 'validation: unknown component key is rejected'

$allowlistRepo = New-TestHarnessRepo -Name 'allowlist-repo'
Add-Component -HarnessRepo $allowlistRepo -Path 'commands/misplaced' -Id 'misplaced' -Kind 'Command' -Target '.claude/agents/misplaced.md' -Mode 'DirectoryFiles' -Content "Misplaced.`n"
$project = New-TestProject -Name 'allowlist-project' -ProfileText (New-ProjectProfileText -Commands @('misplaced'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $allowlistRepo, '-ProjectRoot', $project) } -Pattern 'outside the Command allowlist' -Message 'validation: target outside the Kind allowlist fails'

$project = New-TestProject -Name 'platform-project' -ProfileText (New-ProjectProfileText -TargetPlatforms @('Plan9') -Rules @('safe-file-edits'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project) } -Pattern 'Unsupported TargetPlatform' -Message 'validation: unsupported target platform is reported'

$project = New-TestProject -Name 'retired-mcp-bucket-project' -ProfileText (New-ProjectProfileText -Rules @('safe-file-edits') -ExtraComponentLine '        McpTemplates = @()')
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project) } -Pattern "unknown key 'McpTemplates'" -Message 'validation: retired MCP template bucket is rejected'

$invalidTargets = @(
    @{ Name = 'dotdot'; Target = '../outside.md'; Pattern = 'Path escapes' },
    @{ Name = 'absolute'; Target = (Join-Path ([System.IO.Path]::GetPathRoot($RepoRoot)) 'outside.md'); Pattern = 'Absolute|UNC' },
    @{ Name = 'unc'; Target = ('\\' + 'server\share\file.md'); Pattern = 'Absolute|UNC' },
    @{ Name = 'url'; Target = ('https://' + 'example.invalid/file.md'); Pattern = 'URL references' },
    @{ Name = 'home'; Target = '~/.codex/file.md'; Pattern = 'Home-rooted' }
)
foreach ($case in $invalidTargets) {
    $badRepo = New-TestHarnessRepo -Name "invalid-target-$($case.Name)"
    Add-Component -HarnessRepo $badRepo -Path 'rules/bad-target' -Id 'bad-target' -Kind 'Rule' -Target $case.Target -Mode 'ManagedBlock' -Content 'bad target'
    $project = New-TestProject -Name "invalid-target-$($case.Name)-project" -ProfileText (New-ProjectProfileText -Rules @('bad-target'))
    Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $badRepo, '-ProjectRoot', $project) } -Pattern $case.Pattern -Message "validation: $($case.Name) target reference fails"
}

# ===========================================================================
Write-Host "`n[safety gates]" -ForegroundColor Cyan
# ===========================================================================
$secretRepo = New-TestHarnessRepo -Name 'secret-repo'
$fakeToken = 'sk-' + ('TESTTOKEN' * 3)
Add-Component -HarnessRepo $secretRepo -Path 'prompts/unsafe-secret' -Id 'unsafe-secret' -Kind 'Prompt' -Target '.agent-harness/generated/prompts/unsafe-secret.md' -Mode 'GeneratedOnly' -Content ("Do not emit " + $fakeToken + "`n")
$project = New-TestProject -Name 'secret-project' -ProfileText (New-ProjectProfileText -Prompts @('unsafe-secret'))
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $secretRepo, '-ProjectRoot', $project)
Assert ($r.Code -ne 0 -and $r.Out -match 'scan-secrets\.ps1 failed with exit code') 'safety gate: fake secret fails closed'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/generated'))) 'safety gate: fake secret leaves no generated output'

# Apply must scan the source repository before creating any target or backup.
# GeneratedOnly would skip the apply write path, so use a real DirectoryFiles output.
$applySecretRepo = New-TestHarnessRepo -Name 'apply-secret-repo'
Add-Component -HarnessRepo $applySecretRepo -Path 'commands/unsafe-secret' -Id 'unsafe-secret' -Kind 'Command' -Target '.claude/commands/unsafe-secret.md' -Mode 'DirectoryFiles' -Content ("Do not emit " + $fakeToken + "`n")
$project = New-TestProject -Name 'apply-secret-project' -ProfileText (New-ProjectProfileText -Commands @('unsafe-secret'))
$r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $applySecretRepo, '-ProjectRoot', $project, '-Apply')
Assert ($r.Code -ne 0 -and $r.Out -match 'scan-secrets\.ps1 failed with exit code') 'safety gate: apply rejects a source secret'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.claude/commands/unsafe-secret.md'))) 'safety gate: rejected apply writes no target'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/backups'))) 'safety gate: rejected apply creates no backup'

$pathRepo = New-TestHarnessRepo -Name 'machine-path-repo'
$privatePath = 'C:' + '\Users\example\tool'
Add-Component -HarnessRepo $pathRepo -Path 'prompts/unsafe-path' -Id 'unsafe-path' -Kind 'Prompt' -Target '.agent-harness/generated/prompts/unsafe-path.md' -Mode 'GeneratedOnly' -Content ("Do not emit " + $privatePath + "`n")
$project = New-TestProject -Name 'machine-path-project' -ProfileText (New-ProjectProfileText -Prompts @('unsafe-path'))
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $pathRepo, '-ProjectRoot', $project)
Assert ($r.Code -ne 0 -and $r.Out -match 'Machine-private path') 'safety gate: machine-private path fails closed'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/generated'))) 'safety gate: machine-private path leaves no generated output'

$project = New-TestProject -Name 'junction-root-project'
$outside = Join-Path $work 'junction-root-target'
Set-File -Path (Join-Path $outside 'sentinel.txt') 'keep'
New-Item -ItemType Junction -Path (Join-Path $project '.agent-harness/generated') -Target $outside | Out-Null
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $pathRepo, '-ProjectRoot', $project)
Assert ($r.Code -ne 0 -and $r.Out -match 'Harness path contains a reparse point') 'safety gate: build refuses a generated root that is a junction'
Assert ((Get-Content -Raw (Join-Path $outside 'sentinel.txt')) -eq 'keep' -and @(Get-ChildItem $outside).Count -eq 1) 'safety gate: the junction target is untouched'

$project = New-TestProject -Name 'junction-ancestor-project'
$outside = Join-Path $work 'junction-ancestor-target'
New-Item -ItemType Directory $outside -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $project '.agent-harness/profile.psd1') -Destination $outside
Remove-Item -LiteralPath (Join-Path $project '.agent-harness/profile.psd1')
Remove-Item -LiteralPath (Join-Path $project '.agent-harness')
Set-File -Path (Join-Path $outside 'generated/sentinel.txt') 'keep'
New-Item -ItemType Junction -Path (Join-Path $project '.agent-harness') -Target $outside | Out-Null
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project)
Assert ($r.Code -ne 0 -and $r.Out -match 'reparse point') 'safety gate: build refuses a junction above the generated root'
Assert ((Test-Path -LiteralPath (Join-Path $outside 'generated/sentinel.txt')) -and -not (Test-Path -LiteralPath (Join-Path $outside 'generated/plan.json'))) 'safety gate: ancestor junction target is not rebuilt'

foreach ($linkedPath in @('.claude', '.agent-harness/backups')) {
    $case = $linkedPath -replace '[./]', '-'
    $project = New-TestProject -Name "apply-junction-$case"
    $outside = Join-Path $work "apply-junction-target-$case"
    Set-File -Path (Join-Path $outside 'settings.json') -Content '{"personal":true}'
    $before = Get-FileSnapshot -Root $outside
    New-Item -ItemType Junction -Path (Join-Path $project $linkedPath) -Target $outside | Out-Null
    foreach ($mode in @('dry-run', 'apply')) {
        $extra = @()
        if ($mode -eq 'apply') { $extra = @('-Apply') }
        $r = Invoke-Script -Script $applyScript -ScriptArgs (@('-RepoRoot', $repo, '-ProjectRoot', $project) + $extra)
        Assert ($r.Code -ne 0 -and $r.Out -match 'reparse point') "safety gate: $mode refuses linked $linkedPath"
        Assert (@(Compare-FileSnapshot -Before $before -After (Get-FileSnapshot -Root $outside)).Count -eq 0) "safety gate: $mode leaves linked $linkedPath target untouched"
        Assert (-not (Test-Path -LiteralPath (Join-Path $project 'AGENTS.md'))) "safety gate: $mode rejects all writes before linked $linkedPath"
    }
}

# The home-write guard runs before the dry-run return, so a plain dry-run with pending
# adds proves it. The guard skips an empty or non-existing USERPROFILE, so the fake home
# must be a real directory.
$fakeHome = Join-Path $work 'fake-home'
New-Item -ItemType Directory -Path $fakeHome -Force | Out-Null
$homeProject = Join-Path $fakeHome 'home-project'
Copy-Item -LiteralPath $fixtureProject -Destination $homeProject -Recurse -Force
Set-File -Path (Join-Path $homeProject '.agent-harness/profile.psd1') -Content (New-ProjectProfileText -Rules @('safe-file-edits'))
$previousUserProfile = $env:USERPROFILE
try {
    $env:USERPROFILE = $fakeHome
    $r = Invoke-Script -Script $applyScript -ScriptArgs @('-RepoRoot', $pathRepo, '-ProjectRoot', $homeProject)
    Assert ($r.Code -ne 0 -and $r.Out -match 'Refusing to write inside the home directory') 'safety gate: apply refuses to write inside the user home'
    Assert (-not (Test-Path -LiteralPath (Join-Path $homeProject 'AGENTS.md'))) 'safety gate: the refused apply writes nothing'
    $r = Invoke-Script -Script $PSCommandPath -ScriptArgs @('-RepoRoot', $homeProject)
    Assert ($r.Code -ne 0 -and $r.Out -match 'checkout outside the user home') 'test workspace: a home checkout is refused before fixture creation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $homeProject 'tmp'))) 'test workspace: no fixture or external fallback is created for a home checkout'
}
finally {
    $env:USERPROFILE = $previousUserProfile
}

# ===========================================================================
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -eq 0) {
    Remove-Work
    exit 0
}
Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
exit 1
