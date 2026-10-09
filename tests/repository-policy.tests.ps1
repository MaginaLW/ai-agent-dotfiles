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

foreach ($manifest in @('manifests/managed-skills.claude.txt', 'manifests/managed-skills.codex.txt', 'manifests/managed-skills.reasonix.txt', 'manifests/managed-skills.txt')) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot $manifest) -PathType Leaf) "the per-platform manifest $manifest exists"
}

# -----------------------------------------------------------------------------
# Generated-root boundaries are symmetric across all three platforms
# -----------------------------------------------------------------------------
Write-Host '[generated-root boundaries]'
$gitignoreText = Read-RepoText '.gitignore'
Assert-TestCondition ($gitignoreText.Contains('# Generated skills: build outputs, never committed.')) '.gitignore marks the generated skills block as never committed'
foreach ($generatedRoot in @('claude/skills/', 'codex/skills/', 'reasonix/skills/')) {
    Assert-TestCondition ($gitignoreText.Contains("`n$generatedRoot`n") -or $gitignoreText.StartsWith("$generatedRoot`n")) ".gitignore ignores the generated root $generatedRoot"
}

$buildSkillsText = Read-RepoText 'scripts/build-skills.ps1'
foreach ($rootVariable in @('$ClaudeOutputRoot', '$CodexOutputRoot', '$ReasonixOutputRoot')) {
    Assert-TestCondition ($buildSkillsText.Contains("$rootVariable = Join-Path `$RepoRoot")) "build-skills defaults $rootVariable to its repository generated root"
}
Assert-TestCondition ($buildSkillsText.Contains('Assert-DisjointBuildRoots -Roots @($SourceRoot,$ClaudeOutputRoot,$CodexOutputRoot,$ReasonixOutputRoot,$ManifestOutputRoot)')) 'build-skills enforces disjoint source/manifest/generated build roots for all three platforms'
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
Assert-TestCondition ((Get-LiteralOccurrenceCount -Text $scanSecretsText -Needle "'claude/skills/', 'codex/skills/', 'reasonix/skills/'") -ge 1) 'the secret scan excludes all three generated roots'

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
$allowedScripts = @($allow | ForEach-Object { if ($_ -match 'scripts/([A-Za-z0-9-]+\.ps1)') { $Matches[1] } } | Sort-Object -Unique)
Assert-TestCondition ((@(Compare-Object $allowedScripts @('build-skills.ps1', 'scan-secrets.ps1')).Count -eq 0)) '.claude/settings.json allow-lists only build-skills and scan-secrets'
foreach ($scriptName in $allowedScripts) {
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
$mcpManifestCommentHits = 0
$mcpManifestNonCommentHits = @()
foreach ($file in $policyFiles) {
    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($file.FullName)) {
        $lineNumber++
        if ($line -match '(?i)openclaw|opencode') { $retiredHits += "$($file.FullName):$lineNumber" }
        if ($line -match '(?i)mcp') {
            if ($file.FullName -like "$([System.IO.Path]::GetFullPath((Join-Path $RepoRoot 'scripts')))*") { $mcpScriptHits += "$($file.FullName):$lineNumber" }
            elseif ($line -match '^\s*#') { $mcpManifestCommentHits++ }
            else { $mcpManifestNonCommentHits += "$($file.FullName):$lineNumber" }
        }
    }
}
Assert-TestCondition ($retiredHits.Count -eq 0) 'no OpenClaw or OpenCode reference exists under scripts/ or manifests/'
Assert-TestCondition ($mcpScriptHits.Count -eq 0) 'no MCP reference exists under scripts/'
Assert-TestCondition (($mcpManifestNonCommentHits.Count -eq 0) -and $mcpManifestCommentHits -ge 1) 'MCP appears in manifests/ only as descriptive comments, never as an active operation'

Write-Host 'repository policy tests: PASS'
