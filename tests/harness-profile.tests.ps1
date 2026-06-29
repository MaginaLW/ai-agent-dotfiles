#requires -Version 7.0
<#
.SYNOPSIS
    Self-contained regression tests for harness profile scripts.

.DESCRIPTION
    No Pester dependency. Runs the real harness profile scripts against isolated
    project and harness-source trees under <repo>/tmp/harness-profile-tests
    (gitignored). The workspace is removed on success and kept on failure.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

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

$work = Join-Path $RepoRoot 'tmp/harness-profile-tests'
function Remove-Work {
    if (($work -like '*tmp*harness-profile-tests*') -and (Test-Path -LiteralPath $work)) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
Remove-Work
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Set-File {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -NoNewline -Encoding UTF8
}

function Invoke-Script {
    param([Parameter(Mandatory)] [string] $Script, [string[]] $ScriptArgs = @())
    $out = & pwsh -NoProfile -File $Script @ScriptArgs 2>&1 | Out-String
    return @{ Out = $out; Code = $LASTEXITCODE }
}

function Escape-Psd1String {
    param([Parameter(Mandatory)] [string] $Value)
    return ($Value -replace "'", "''")
}

function New-ProjectProfileText {
    param(
        [string[]] $TargetPlatforms = @('Claude', 'Codex'),
        [string[]] $Extends = @(),
        [string[]] $Rules = @(),
        [string[]] $Prompts = @(),
        [string[]] $Commands = @(),
        [string[]] $ClaudeSettings = @()
    )

    function Join-Psd1Array([string[]] $Values) {
        if ($Values.Count -eq 0) { return '@()' }
        return '@(' + (($Values | ForEach-Object { "'" + (Escape-Psd1String $_) + "'" }) -join ', ') + ')'
    }

    return @"
@{
    SchemaVersion = 1
    Name = 'harness-profile-test'
    TargetPlatforms = $(Join-Psd1Array $TargetPlatforms)
    Extends = $(Join-Psd1Array $Extends)
    Components = @{
        Rules = $(Join-Psd1Array $Rules)
        Prompts = $(Join-Psd1Array $Prompts)
        Commands = $(Join-Psd1Array $Commands)
        Agents = @()
        ClaudeSettings = $(Join-Psd1Array $ClaudeSettings)
        CodexAgents = @()
        McpTemplates = @()
    }
    Future = @{
        ProjectSkills = @()
    }
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
        [string[]] $Requires = @(),
        [string[]] $Conflicts = @(),
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
    TargetPlatforms = @($(($TargetPlatforms | ForEach-Object { "'" + (Escape-Psd1String $_) + "'" }) -join ', '))
    Requires = @($(($Requires | ForEach-Object { "'" + (Escape-Psd1String $_) + "'" }) -join ', '))
    Conflicts = @($(($Conflicts | ForEach-Object { "'" + (Escape-Psd1String $_) + "'" }) -join ', '))
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
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'scripts/scan-secrets.ps1') -Destination (Join-Path $repo 'scripts/scan-secrets.ps1') -Force
    $gitleaks = Join-Path $RepoRoot '.gitleaks.toml'
    if (Test-Path -LiteralPath $gitleaks) { Copy-Item -LiteralPath $gitleaks -Destination $repo -Force }

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

# ===========================================================================
Write-Host "`n[validation failures]" -ForegroundColor Cyan
# ===========================================================================
$dupeRepo = New-TestHarnessRepo -Name 'duplicate-repo'
Add-Component -HarnessRepo $dupeRepo -Path 'rules/duplicate-safe-file-edits' -Id 'safe-file-edits' -Kind 'Rule' -Target 'AGENTS.md' -Mode 'ManagedBlock' -Content 'duplicate'
$project = New-TestProject -Name 'duplicate-project' -ProfileText (New-ProjectProfileText -Rules @('safe-file-edits'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $dupeRepo, '-ProjectRoot', $project) } -Pattern 'Duplicate harness component' -Message 'validation: duplicate component IDs fail'

$requiresRepo = New-TestHarnessRepo -Name 'requires-repo'
Add-Component -HarnessRepo $requiresRepo -Path 'rules/needs-helper' -Id 'needs-helper' -Kind 'Rule' -Requires @('missing-helper') -Target 'AGENTS.md' -Mode 'ManagedBlock' -Content 'needs helper'
$project = New-TestProject -Name 'requires-project' -ProfileText (New-ProjectProfileText -Rules @('needs-helper'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $requiresRepo, '-ProjectRoot', $project) } -Pattern 'requires' -Message 'validation: Requires are enforced'

$conflictRepo = New-TestHarnessRepo -Name 'conflict-repo'
Add-Component -HarnessRepo $conflictRepo -Path 'rules/left' -Id 'left' -Kind 'Rule' -Conflicts @('right') -Target 'AGENTS.md' -Mode 'ManagedBlock' -Content 'left'
Add-Component -HarnessRepo $conflictRepo -Path 'rules/right' -Id 'right' -Kind 'Rule' -Target 'AGENTS.md' -Mode 'ManagedBlock' -Content 'right'
$project = New-TestProject -Name 'conflict-project' -ProfileText (New-ProjectProfileText -Rules @('left', 'right'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $conflictRepo, '-ProjectRoot', $project) } -Pattern 'conflicts' -Message 'validation: Conflicts are enforced'

$project = New-TestProject -Name 'platform-project' -ProfileText (New-ProjectProfileText -TargetPlatforms @('Plan9') -Rules @('safe-file-edits'))
Assert-Fails -Run { Invoke-Script -Script $statusScript -ScriptArgs @('-RepoRoot', $repo, '-ProjectRoot', $project) } -Pattern 'Unsupported TargetPlatform' -Message 'validation: unsupported target platform is reported'

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
Assert ($r.Code -ne 0 -and $r.Out -match 'secret|gitleaks|scan-secrets') 'safety gate: fake secret fails closed'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/generated'))) 'safety gate: fake secret leaves no generated output'

$pathRepo = New-TestHarnessRepo -Name 'machine-path-repo'
$privatePath = 'C:' + '\Users\example\tool'
Add-Component -HarnessRepo $pathRepo -Path 'prompts/unsafe-path' -Id 'unsafe-path' -Kind 'Prompt' -Target '.agent-harness/generated/prompts/unsafe-path.md' -Mode 'GeneratedOnly' -Content ("Do not emit " + $privatePath + "`n")
$project = New-TestProject -Name 'machine-path-project' -ProfileText (New-ProjectProfileText -Prompts @('unsafe-path'))
$r = Invoke-Script -Script $buildScript -ScriptArgs @('-RepoRoot', $pathRepo, '-ProjectRoot', $project)
Assert ($r.Code -ne 0 -and $r.Out -match 'Machine-private path') 'safety gate: machine-private path fails closed'
Assert (-not (Test-Path -LiteralPath (Join-Path $project '.agent-harness/generated'))) 'safety gate: machine-private path leaves no generated output'

# ===========================================================================
Write-Host ''
Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
if ($script:fail -eq 0) {
    Remove-Work
    exit 0
}
Write-Host "Workspace kept for inspection: $work" -ForegroundColor Yellow
exit 1
