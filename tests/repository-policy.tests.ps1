#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository policy suite. It checks functional repository guard rails, not documentation
# wording: the CLAUDE.md import of AGENTS.md, the per-platform manifests, the generated-root
# boundaries (ignore rules, build defaults, scan exclusions), the Claude Code harness permission
# rules, and the absence of retired platforms in scripts/ and manifests/.

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
# CLAUDE.md import and manifests
# -----------------------------------------------------------------------------
Write-Host '[CLAUDE.md import and manifests]'
# Claude Code reads AGENTS.md only through this import, and it does not expand imports inside
# code fences, so the import must sit on its own line outside one.
$claudeText = Read-RepoText 'CLAUDE.md'
$claudeOutsideFences = $claudeText -replace '(?ms)^(```|~~~).*?^\1[ \t]*\r?$', ''
Assert-TestCondition ($claudeOutsideFences -cmatch '(?m)^@AGENTS\.md[ \t]*\r?$') 'CLAUDE.md imports AGENTS.md on its own line outside code fences'

foreach ($manifest in @('manifests/managed-skills.claude.txt', 'manifests/managed-skills.codex.txt')) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot $manifest) -PathType Leaf) "the per-platform manifest $manifest exists"
}

# full is documented as selecting every managed skill, so its per-platform lists must equal the
# corresponding manifests, and the Zcode projection list must equal Claude's.
$fullSelection = (Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'harness-source/envs/full.psd1')).Skills
foreach ($pair in @(@('Claude', 'claude'), @('Codex', 'codex'))) {
    $manifestNames = @(Get-Content -LiteralPath (Join-Path $RepoRoot "manifests/managed-skills.$($pair[1]).txt") | Where-Object { $_ })
    Assert-TestCondition (@(Compare-Object @($fullSelection[$pair[0]]) $manifestNames).Count -eq 0) "the full environment's $($pair[0]) selection equals the managed-skills manifest"
}
Assert-TestCondition (@(Compare-Object @($fullSelection['Zcode']) @($fullSelection['Claude'])).Count -eq 0) "the full environment's Zcode selection equals Claude (projection)"

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
foreach ($generatedRoot in @('claude/skills/', 'codex/skills/', 'reasonix/skills/')) {
    Assert-TestCondition ($gitignoreText.Contains("`n$generatedRoot`n") -or $gitignoreText.StartsWith("$generatedRoot`n")) ".gitignore ignores the generated root $generatedRoot"
}

$buildSkillsText = Read-RepoText 'scripts/build-skills.ps1'
foreach ($rootVariable in @('$ClaudeOutputRoot', '$CodexOutputRoot')) {
    Assert-TestCondition ($buildSkillsText.Contains("$rootVariable = Join-Path `$RepoRoot")) "build-skills defaults $rootVariable to its repository generated root"
}
Assert-TestCondition ($buildSkillsText.Contains('Assert-DisjointBuildRoots -Roots @($SourceRoot,$ClaudeOutputRoot,$CodexOutputRoot,$ManifestOutputRoot)')) 'build-skills enforces disjoint source/manifest/generated build roots'
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
Assert-TestCondition ((Get-LiteralOccurrenceCount -Text $scanSecretsText -Needle "'claude/skills/', 'codex/skills/', 'reasonix/skills/'") -ge 1) 'the secret scan excludes active generated roots and protects the legacy root'

# -----------------------------------------------------------------------------
# Claude Code harness guard rails
# -----------------------------------------------------------------------------
Write-Host '[Claude Code harness guard rails]'
$settings = (Read-RepoText '.claude/settings.json') | ConvertFrom-Json
$deny = @($settings.permissions.deny)
$allow = @($settings.permissions.allow)
foreach ($rule in @('Edit(claude/skills/**)', 'Write(claude/skills/**)', 'Edit(codex/skills/**)', 'Write(codex/skills/**)', 'Edit(reasonix/skills/**)', 'Write(reasonix/skills/**)', 'Edit(~/.codex/skills/.system/**)', 'Write(~/.codex/skills/.system/**)', 'Edit(**/.codex/skills/.system/**)', 'Write(**/.codex/skills/.system/**)', 'Bash(robocopy *)', 'PowerShell(robocopy *)')) {
    Assert-TestCondition ($deny -ccontains $rule) ".claude/settings.json denies $rule"
}
$expectedAllow = @(
    'PowerShell(pwsh -NoProfile -File scripts/build-skills.ps1*)'
    'PowerShell(pwsh -NoProfile -File scripts/scan-secrets.ps1*)'
    'Bash(pwsh -NoProfile -File scripts/build-skills.ps1*)'
    'Bash(pwsh -NoProfile -File scripts/scan-secrets.ps1*)'
)
Assert-TestCondition ((@(Compare-Object @($allow | Sort-Object) @($expectedAllow | Sort-Object)).Count -eq 0)) '.claude/settings.json allow-lists exactly the build-skills and scan-secrets entries and nothing else'
foreach ($scriptName in @('build-skills.ps1', 'scan-secrets.ps1')) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot "scripts/$scriptName") -PathType Leaf) "allow-listed scripts/$scriptName exists"
}
Assert-TestCondition ((Get-LiteralOccurrenceCount -Text (Read-RepoText 'bootstrap.ps1') -Needle '-Apply') -eq 0) 'bootstrap.ps1 carries no -Apply usage'

# -----------------------------------------------------------------------------
# No MCP / OpenClaw / OpenCode reintroduction in scripts or manifests
# -----------------------------------------------------------------------------
Write-Host '[retired platform absence]'
$policyFiles = @(Get-ChildItem -LiteralPath (Join-Path $RepoRoot 'scripts'), (Join-Path $RepoRoot 'manifests') -Recurse -File)
$retiredHits = @()
$mcpScriptHits = @()
$mcpManifestNonCommentHits = @()
foreach ($file in $policyFiles) {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNumber++
        if ($line -match '(?i)openclaw|opencode') { $retiredHits += "$($file.FullName):$lineNumber" }
        if ($line -match '(?i)mcp') {
            if ($file.FullName -like "$([System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts')))*") { $mcpScriptHits += "$($file.FullName):$lineNumber" }
            elseif ($line -notmatch '^\s*#') { $mcpManifestNonCommentHits += "$($file.FullName):$lineNumber" }
        }
    }
}
Assert-TestCondition ($retiredHits.Count -eq 0) 'no OpenClaw or OpenCode reference exists under scripts/ or manifests/'
Assert-TestCondition ($mcpScriptHits.Count -eq 0) 'no MCP reference exists under scripts/'
Assert-TestCondition ($mcpManifestNonCommentHits.Count -eq 0) 'MCP appears in manifests/ only as descriptive comments, never as an active operation'
$codexConfig = (Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'manifests/whitelist.psd1')).Codex
Assert-TestCondition (@($codexConfig.ExcludedItems) -contains 'config.toml') 'Codex config.toml is excluded from sync'
Assert-TestCondition ((@($codexConfig.PushItems) -notcontains 'config.toml') -and (@($codexConfig.PullItems) -notcontains 'config.toml')) 'Codex config.toml is not selected for push or pull'

Write-Host 'repository policy tests: PASS'
