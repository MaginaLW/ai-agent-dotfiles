#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository policy suite. It checks functional repository guard rails, not documentation
# wording: retired local entry points, per-platform manifests, generated-root boundaries
# (ignore rules, build defaults, scan exclusions), and retired platform exclusions in
# scripts/, manifests/, harness-source/, and dashboard/.

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

function Read-RepoText {
    param([Parameter(Mandatory)] [string] $RelativePath)
    return [System.IO.File]::ReadAllText((Join-Path $RepoRoot $RelativePath))
}

function Get-LiteralOccurrenceCount {
    param([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $Needle)
    $count = 0
    $index = 0
    while (($index = $Text.IndexOf($Needle, $index, [System.StringComparison]::Ordinal)) -ge 0) {
        $count++
        $index += $Needle.Length
    }
    return $count
}

# -----------------------------------------------------------------------------
# Retired local entry points and manifests
# -----------------------------------------------------------------------------
Write-Host '[Retired local entry points and manifests]'
foreach ($entry in 'CLAUDE.md', '.claude/settings.json', 'claude/CLAUDE.md', 'claude/settings.json', 'manifests/managed-skills.claude.txt', 'zcode/AGENTS.md', 'docs/ZCODE.md', 'manifests/managed-skills.zcode.txt', 'skills-source/claude-only', 'skills-source/zcode-only', 'skills-source/reasonix-only') {
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $RepoRoot $entry))) "retired platform entry $entry is absent"
}

# Validate all Codex environment selections against the canonical manifest.
$codexManifestNames = @(Get-Content -LiteralPath (Join-Path $RepoRoot 'manifests/managed-skills.codex.txt') | Where-Object { $_ })
foreach ($envName in @('full', 'work', 'minimal')) {
    $envData = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot "harness-source/envs/$envName.psd1")
    Assert-TestCondition ($envData.ContainsKey('SchemaVersion') -and ($envData.SchemaVersion -is [int]) -and ($envData.SchemaVersion -eq 1)) "environment $envName declares SchemaVersion = 1"
    Assert-TestCondition ($envData.ContainsKey('Skills') -and ($envData.Skills -is [hashtable]) -and ($envData.Skills.Count -eq 1) -and $envData.Skills.ContainsKey('Codex')) "environment $envName has one skill platform (Codex)"
    $rawCodexSkills = $envData.Skills.Codex
    Assert-TestCondition ($rawCodexSkills -is [array]) "environment $envName declares Skills.Codex as an array"
    $codexSkills = @($rawCodexSkills | ForEach-Object { [string] $_ })
    Assert-TestCondition (($codexSkills.Count -ge 1) -and (@($codexSkills | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)) "environment $envName has non-empty Skills.Codex entries"
    $seenSkills = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $duplicateSkills = @($codexSkills | Where-Object { -not $seenSkills.Add($_) })
    Assert-TestCondition ($duplicateSkills.Count -eq 0) "environment $envName has zero duplicate Skills.Codex entries"
    $unknownSkills = @($codexSkills | Where-Object { $_ -cnotin $codexManifestNames })
    Assert-TestCondition ($unknownSkills.Count -eq 0) "all Skills.Codex entries in environment $envName exist in manifests/managed-skills.codex.txt"
    if ($codexSkills -ccontains 'teamwork') {
        Assert-TestCondition ($codexSkills -ccontains 'swarm') "environment $envName selects swarm whenever it selects teamwork"
    }
    if ($envName -eq 'full') {
        Assert-TestCondition (@(Compare-Object $codexSkills $codexManifestNames).Count -eq 0) 'the full environment codex selection equals manifests/managed-skills.codex.txt'
    }
}

# -----------------------------------------------------------------------------
# Dangerous tracked paths
# -----------------------------------------------------------------------------
Write-Host '[dangerous tracked paths]'
. (Join-Path $RepoRoot 'scripts/repo-common.ps1')
# Git quoted/octally escaped paths are outside this predicate's contract; the caller's
# Get-GitLines decoding and core.quotepath behavior remain unchanged.
$dangerousPathCases = @(
    @{ Path = 'x.pem'; Expected = $true }
    @{ Path = 'id_ed25519'; Expected = $true }
    @{ Path = '.env'; Expected = $true }
    @{ Path = '.env.local'; Expected = $true }
    @{ Path = '.env.md'; Expected = $true }
    @{ Path = 'tokens.yaml'; Expected = $true }
    @{ Path = 'app.token'; Expected = $true }
    @{ Path = 'auth.json'; Expected = $true }
    @{ Path = 'backup/a/b'; Expected = $true }
    @{ Path = '.ssh/config'; Expected = $true }
    @{ Path = 'pem.md'; Expected = $false }
    @{ Path = 'tokens.md'; Expected = $false }
    @{ Path = 'mytokens.txt'; Expected = $false }
    @{ Path = 'nested/PRIVATE.KEY'; Expected = $true }
    @{ Path = 'nested/certificate.p12'; Expected = $true }
    @{ Path = 'nested/certificate.PFX'; Expected = $true }
    @{ Path = 'nested/ID_RSA'; Expected = $true }
    @{ Path = 'nested/.ENV.LOCAL'; Expected = $true }
    @{ Path = 'nested/token'; Expected = $true }
    @{ Path = 'nested/.tokens'; Expected = $true }
    @{ Path = 'nested/.TOKEN.TXT'; Expected = $true }
    @{ Path = 'nested/tokens.json'; Expected = $true }
    @{ Path = 'nested/token.yml'; Expected = $true }
    @{ Path = 'nested/app.TOKENS'; Expected = $true }
    @{ Path = 'nested/.CREDENTIALS.JSON'; Expected = $true }
    @{ Path = 'nested/AUTH.JSON'; Expected = $true }
    @{ Path = 'nested/BACKUPS/a'; Expected = $true }
    @{ Path = 'nested/backup'; Expected = $true }
    @{ Path = 'nested/.SSH'; Expected = $true }
    @{ Path = 'nested\.ssh\config'; Expected = $true }
    @{ Path = 'nested\BACKUP\a'; Expected = $true }
    @{ Path = 'nested\private.PEM'; Expected = $true }
    @{ Path = 'nested\id_ed25519'; Expected = $true }
    @{ Path = 'nested\.env'; Expected = $true }
    @{ Path = 'nested\auth.json'; Expected = $true }
    @{ Path = 'nested/id_rsa.pub'; Expected = $false }
    @{ Path = 'nested/.env.'; Expected = $false }
    @{ Path = 'nested/my.env'; Expected = $false }
    @{ Path = 'nested/credentials.json'; Expected = $false }
    @{ Path = 'nested/auth.json.md'; Expected = $false }
    @{ Path = 'nested/backup-notes/a'; Expected = $false }
    @{ Path = 'nested/mybackups/a'; Expected = $false }
    @{ Path = 'nested/.ssh-notes/config'; Expected = $false }
    @{ Path = 'nested/ssh/config'; Expected = $false }
    @{ Path = 'nested\mytokens.txt'; Expected = $false }
    @{ Path = 'nested\backups.md'; Expected = $false }
    @{ Path = 'nested\.ssh-notes\config'; Expected = $false }
)
foreach ($case in $dangerousPathCases) {
    $result = @(Test-IsDangerousTrackedPath -RelativePath $case.Path)
    Assert-TestCondition (($result.Count -eq 1) -and ($result[0] -is [bool]) -and ($result[0] -eq $case.Expected)) "dangerous path '$($case.Path)' returns only bool $($case.Expected)"
}

# -----------------------------------------------------------------------------
# Generated-root boundaries and legacy output protection
# -----------------------------------------------------------------------------
Write-Host '[generated-root boundaries]'
$gitignoreText = Read-RepoText '.gitignore'
$generatedSkillRoots = @(Get-GeneratedSkillRoots)
foreach ($generatedRoot in $generatedSkillRoots) {
    $ignored = "$generatedRoot/"
    Assert-TestCondition ($gitignoreText.Contains("`n$ignored`n") -or $gitignoreText.StartsWith("$ignored`n")) ".gitignore ignores the generated root $ignored"
}
$scanPrefixes = @(Get-ScanExcludedPrefixes)
foreach ($generatedRoot in $generatedSkillRoots) {
    Assert-TestCondition ($scanPrefixes -contains "$generatedRoot/") "the shared scan policy covers $generatedRoot/"
}
Assert-TestCondition ($scanPrefixes -ccontains '.git/' -and $scanPrefixes -ccontains 'tmp/') 'the shared scan policy covers Git and temporary inputs'

$buildSkillsText = Read-RepoText 'scripts/build-skills.ps1'
foreach ($rootVariable in @('$CodexOutputRoot')) {
    Assert-TestCondition ($buildSkillsText.Contains("$rootVariable = Join-Path `$RepoRoot")) "build-skills defaults $rootVariable to its repository generated root"
}
Assert-TestCondition ($buildSkillsText.Contains('Assert-DisjointBuildRoots -Roots @($SourceRoot,$CodexOutputRoot,$ManifestOutputRoot)')) 'build-skills enforces disjoint source/manifest/generated build roots'
# build-skills discovers source and generated skills through Get-SkillDirectories, which must
# never treat .system as a skill.
. (Join-Path $RepoRoot 'scripts/skills-common.ps1')
$skillProbeRoot = Join-Path ([System.IO.Path]::GetTempPath()) "repository-policy-skills-$([Guid]::NewGuid().ToString('N'))"
try {
    foreach ($probeSkill in @('.system', 'probe-skill')) {
        New-Item -ItemType Directory -Path (Join-Path $skillProbeRoot $probeSkill) -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $skillProbeRoot "$probeSkill/SKILL.md"), "# $probeSkill`n")
    }
    $probeNames = @(Get-SkillDirectories -RootPath $skillProbeRoot | ForEach-Object Name)
    Assert-TestCondition (($probeNames.Count -eq 1) -and ($probeNames[0] -ceq 'probe-skill')) 'build-skills skill discovery never treats .system as a skill'
}
finally {
    Remove-Item -LiteralPath $skillProbeRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$scanSecretsText = Read-RepoText 'scripts/scan-secrets.ps1'
Assert-TestCondition ($scanSecretsText.Contains('Get-ScanExcludedPrefixes')) 'the secret scan consumes the shared prefix policy'
$syntaxGateText = Read-RepoText 'scripts/check-powershell-syntax.ps1'
Assert-TestCondition ($syntaxGateText.Contains('Get-ScanExcludedPrefixes')) 'the syntax gate consumes the shared prefix policy'
$validationText = Read-RepoText 'scripts/run-repository-validation.ps1'
Assert-TestCondition ($validationText.Contains('Get-GeneratedSkillRoots')) 'repository validation consumes the shared generated-root policy'
$deploySkillsText = Read-RepoText 'scripts/deploy-skills.ps1'
$doctorText = Read-RepoText 'scripts/doctor.ps1'
Assert-TestCondition ($deploySkillsText.Contains('Get-CodexLiveSkillRoots') -and $doctorText.Contains('Get-CodexLiveSkillRoots')) 'deploy and doctor consume the shared Codex live-root policy'
$skillsCommonText = Read-RepoText 'scripts/skills-common.ps1'
Assert-TestCondition (-not $skillsCommonText.Contains('-ErrorAction SilentlyContinue')) 'skill discovery does not suppress enumeration errors'
$configCommonText = Read-RepoText 'scripts/config-common.ps1'
$configEnumerationMatch = [regex]::Match($configCommonText, '(?s)function\s+Get-ConfigFiles\s*\{.*?\r?\n\}')
Assert-TestCondition ($configEnumerationMatch.Success -and (-not $configEnumerationMatch.Value.Contains('-ErrorAction SilentlyContinue'))) 'config discovery does not suppress enumeration errors'
Assert-TestCondition (-not ($configCommonText -match '(?i)Get-ChildItem[^\r\n]*-ErrorAction\s+SilentlyContinue')) 'config enumeration never uses -ErrorAction SilentlyContinue'

# -----------------------------------------------------------------------------
# Required local checks
# -----------------------------------------------------------------------------
Write-Host '[Required local checks]'
foreach ($scriptName in @('build-skills.ps1', 'scan-secrets.ps1')) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/$scriptName") -PathType Leaf) "required scripts/$scriptName exists"
}
Assert-TestCondition ((Get-LiteralOccurrenceCount -Text (Read-RepoText 'bootstrap.ps1') -Needle '-Apply') -eq 0) 'bootstrap.ps1 carries no -Apply usage'

# -----------------------------------------------------------------------------
# Retired platforms and managed MCP projection boundaries
# -----------------------------------------------------------------------------
Write-Host '[retired platform absence and MCP boundaries]'
$policyFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts'), (Join-Path $RepoRoot 'manifests'), (Join-Path $RepoRoot 'harness-source'), (Join-Path $RepoRoot 'dashboard') -Recurse -File)
$scriptsRootFull = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts'))
$manifestsRootFull = [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'manifests'))
$allowedMcpScripts = @(
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts/mcp-sync.ps1')),
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1')),
    [System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts/doctor.ps1'))
)
$retiredHits = @()
$mcpScriptHits = @()
$mcpManifestNonCommentHits = @()
foreach ($file in $policyFiles) {
    $full = [System.IO.Path]::GetFullPath($file.FullName)
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNumber++
        if ($line -match '(?i)claude|openclaw|opencode|reasonix|zcode') { $retiredHits += "$($file.FullName):$lineNumber" }
        if ($line -match '(?i)mcp') {
            if ($full.StartsWith($scriptsRootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                if ($full -notin $allowedMcpScripts) { $mcpScriptHits += "$($file.FullName):$lineNumber" }
            }
            elseif ($full.StartsWith($manifestsRootFull, [System.StringComparison]::OrdinalIgnoreCase) -and ($line -notmatch '^\s*#')) {
                $mcpManifestNonCommentHits += "$($file.FullName):$lineNumber"
            }
        }
    }
}
Assert-TestCondition ($retiredHits.Count -eq 0) 'no Claude, OpenClaw, OpenCode, Reasonix, or ZCode reference exists under scripts/, manifests/, harness-source/, or dashboard/'
Assert-TestCondition ($mcpScriptHits.Count -eq 0) 'MCP references under scripts/ are confined to mcp-sync.ps1, agent-dotfiles.ps1, and doctor.ps1'
Assert-TestCondition ($mcpManifestNonCommentHits.Count -eq 0) 'MCP appears in manifests/ only as descriptive comments, never as an active operation'
$whitelistData = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1')
$codexConfig = $whitelistData.Codex
Assert-TestCondition (@($codexConfig.ExcludedItems) -contains 'config.toml') 'Codex config.toml is excluded from sync'
Assert-TestCondition ((@($codexConfig.PushItems) -notcontains 'config.toml') -and (@($codexConfig.PullItems) -notcontains 'config.toml')) 'Codex config.toml is not selected for push or pull'
$antigravityConfig = $whitelistData.Antigravity
Assert-TestCondition ((@($antigravityConfig.PushItems) -notcontains 'mcp_config.json') -and (@($antigravityConfig.PullItems) -notcontains 'mcp_config.json')) 'Antigravity mcp_config.json is not selected for push or pull'
$hermesConfig = $whitelistData.Hermes
Assert-TestCondition ($null -ne $hermesConfig) 'manifests/whitelist.psd1 declares Hermes'
Assert-TestCondition (@($hermesConfig.ExcludedItems) -contains 'config.yaml') 'Hermes config.yaml is excluded from sync'
Assert-TestCondition ((@($hermesConfig.PushItems) -notcontains 'config.yaml') -and (@($hermesConfig.PullItems) -notcontains 'config.yaml')) 'Hermes config.yaml is not selected for push or pull'
Assert-TestCondition (-not $whitelistData.ContainsKey('ZCode')) 'retired ZCode platform is absent from manifests/whitelist.psd1'
Assert-TestCondition (-not (Read-RepoText 'scripts/deploy.ps1').Contains('mcp-sync')) 'combined deploy.ps1 does not automatically project MCP servers'
Assert-TestCondition (-not (Read-RepoText 'scripts/deploy.ps1').Contains('hermes-skills')) 'combined deploy.ps1 does not automatically deploy Hermes skills'

. (Join-Path $RepoRoot 'scripts/mcp-sync.ps1')
$mcpRegistry = Read-McpServerRegistry -RepoRoot $RepoRoot
$blenderEntries = @($mcpRegistry.Servers | Where-Object { $_.Name -ceq 'blender' -and $_.Command -ceq 'uvx' })
Assert-TestCondition ($blenderEntries.Count -eq 1) 'harness-source/mcp/servers.psd1 passes schema validation and declares blender'
Assert-TestCondition ((@($blenderEntries[0].Platforms) -ccontains 'Antigravity') -and (@($blenderEntries[0].Platforms) -ccontains 'Codex') -and (@($blenderEntries[0].Platforms) -ccontains 'Hermes')) 'blender MCP server targets Antigravity, Codex, and Hermes'

# -----------------------------------------------------------------------------
# Multi-host AGENTS.md / SOUL.md shared-core parity, Antigravity plugin, and Hermes skills
# -----------------------------------------------------------------------------
Write-Host '[multi-host AGENTS.md / SOUL.md parity, Antigravity plugin, and Hermes skills]'
$codexAgentsText = Read-RepoText 'codex/AGENTS.md'
$antigravityAgentsText = Read-RepoText 'antigravity/AGENTS.md'
$hermesSoulText = Read-RepoText 'hermes/SOUL.md'
$sharedAgentsMarkers = @(
    '## 编码与验证',
    '## 执行与沟通',
    '## 修改、验证与提交',
    '## 工作区与安全',
    '停止条件',
    '小步提交',
    '密钥与凭据永不入库',
    '严禁静默降级'
)
foreach ($marker in $sharedAgentsMarkers) {
    Assert-TestCondition ($codexAgentsText.Contains($marker)) "codex/AGENTS.md contains shared guardrail '$marker'"
    Assert-TestCondition ($antigravityAgentsText.Contains($marker)) "antigravity/AGENTS.md contains shared guardrail '$marker'"
    Assert-TestCondition ($hermesSoulText.Contains($marker)) "hermes/SOUL.md contains shared guardrail '$marker'"
}

$hermesSkillsData = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'harness-source/hermes/skills.psd1')
Assert-TestCondition ($hermesSkillsData.ContainsKey('SchemaVersion') -and ($hermesSkillsData.SchemaVersion -is [int]) -and ($hermesSkillsData.SchemaVersion -eq 1)) 'hermes/skills.psd1 declares SchemaVersion = 1'
Assert-TestCondition ($hermesSkillsData.ContainsKey('Category') -and ($hermesSkillsData.Category -ceq 'ai-agent-dotfiles')) 'hermes/skills.psd1 declares Category = ai-agent-dotfiles'
$rawHermesSkills = $hermesSkillsData.Skills
Assert-TestCondition ($rawHermesSkills -is [array]) 'hermes/skills.psd1 declares Skills as an array'
$hermesSkills = @($rawHermesSkills | ForEach-Object { [string] $_ })
Assert-TestCondition (($hermesSkills.Count -ge 1) -and (@($hermesSkills | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)) 'hermes/skills.psd1 Skills has non-empty entries'
$seenHermesSkills = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$duplicateHermesSkills = @($hermesSkills | Where-Object { -not $seenHermesSkills.Add($_) })
Assert-TestCondition ($duplicateHermesSkills.Count -eq 0) 'hermes/skills.psd1 Skills has zero duplicates'
foreach ($hermesSkill in $hermesSkills) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot "skills-source/shared/$hermesSkill/SKILL.md") -PathType Leaf) "hermes/skills.psd1 skill '$hermesSkill' exists under skills-source/shared/"
}
Assert-TestCondition (($hermesSkills -notcontains 'systematic-debugging') -and ($hermesSkills -notcontains 'tool-scope')) 'hermes/skills.psd1 excludes systematic-debugging and tool-scope'

$pluginsData = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'harness-source/antigravity/plugins.psd1')
Assert-TestCondition ($pluginsData.ContainsKey('ManagedPlugin') -and ($pluginsData.ManagedPlugin -is [hashtable])) 'plugins.psd1 declares ManagedPlugin hashtable'
$rawPluginSkills = $pluginsData.ManagedPlugin.Skills
Assert-TestCondition ($rawPluginSkills -is [array]) 'plugins.psd1 declares ManagedPlugin.Skills as an array'
$pluginSkills = @($rawPluginSkills | ForEach-Object { [string] $_ })
Assert-TestCondition (($pluginSkills.Count -ge 1) -and (@($pluginSkills | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0)) 'plugins.psd1 ManagedPlugin.Skills has non-empty entries'
$seenPluginSkills = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$duplicatePluginSkills = @($pluginSkills | Where-Object { -not $seenPluginSkills.Add($_) })
Assert-TestCondition ($duplicatePluginSkills.Count -eq 0) 'plugins.psd1 ManagedPlugin.Skills has zero duplicates'
foreach ($pluginSkill in $pluginSkills) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot "skills-source/shared/$pluginSkill/SKILL.md") -PathType Leaf) "plugins.psd1 ManagedPlugin skill '$pluginSkill' exists under skills-source/shared/"
}

Write-Host 'repository policy tests: PASS'
