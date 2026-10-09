#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository policy suite. It pins the tracked instruction and doc claims, the generated-root
# boundaries (ignore rules, build defaults, scan exclusions, the never-edit rule), the Claude
# Code harness guard rails, and the absence of retired platforms in scripts/ and manifests/.
# Phrase pins on AGENTS.md, README.md and docs/README.md match whitespace-collapsed text, so
# Markdown line wrapping cannot split a pinned sentence.

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
# Tracked instruction and documentation claims
# -----------------------------------------------------------------------------
Write-Host '[tracked instruction and documentation claims]'
# AGENTS.md is the single rule entry (Codex and ZCode read it directly; Claude Code reads it
# through the CLAUDE.md import), so the rule pins live on AGENTS.md and CLAUDE.md is pinned
# only as an import of it.
$agentsText = Read-RepoText 'AGENTS.md'
$claudeText = Read-RepoText 'CLAUDE.md'
$readmeText = Read-RepoText 'README.md'
$docsReadmeText = Read-RepoText 'docs/README.md'
$agentsFlat = $agentsText -replace '\s+', ' '
$readmeFlat = $readmeText -replace '\s+', ' '
$docsReadmeFlat = $docsReadmeText -replace '\s+', ' '

foreach ($entry in @(
    @{ File = 'AGENTS.md'; Text = $agentsText },
    @{ File = 'CLAUDE.md'; Text = $claudeText },
    @{ File = 'README.md'; Text = $readmeText }
)) {
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        Assert-TestCondition ($entry.Text.IndexOf($platform, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "$($entry.File) mentions $platform"
    }
}
# Claude Code does not expand imports inside code fences, so the import must sit outside one.
$claudeOutsideFences = $claudeText -replace '(?ms)^(```|~~~).*?^\1[ \t]*\r?$', ''
Assert-TestCondition ($claudeOutsideFences -cmatch '(?m)^@AGENTS\.md[ \t]*\r?$') 'CLAUDE.md imports AGENTS.md on its own line outside code fences'

Assert-TestCondition ($agentsFlat.Contains("On every task, push, merge, any live Apply, destructive actions, credential export and additional paid model calls each need the owner's explicit authorization.")) 'AGENTS.md requires owner authorization for push, merge, live Apply and other high-impact actions on every task'
Assert-TestCondition ($agentsText.Contains('skills-source/reasonix-only/<name>/')) 'AGENTS.md carries the reasonix-only source root concept'
Assert-TestCondition ($docsReadmeText.Contains('skills-source/reasonix-only/')) 'docs/README.md documents the reasonix-only source root'

foreach ($manifest in @('manifests/managed-skills.claude.txt', 'manifests/managed-skills.codex.txt', 'manifests/managed-skills.reasonix.txt', 'manifests/managed-skills.txt')) {
    Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot $manifest) -PathType Leaf) "the per-platform manifest $manifest exists"
}
Assert-TestCondition ($agentsText.Contains('`manifests/`')) 'AGENTS.md skill-rule scope names the manifests directory'
Assert-TestCondition ($docsReadmeText.Contains('`manifests/managed-skills.txt` | 三平台 union inventory')) 'docs/README.md documents the union manifest'

Assert-TestCondition ($agentsFlat.Contains('Change live skills roots only through `scripts/deploy-skills.ps1`') -and $agentsFlat.Contains('Never copy into or delete from a live root by hand.')) 'AGENTS.md routes every live root change through deploy-skills'
Assert-TestCondition ($agentsFlat.Contains('Run the dry run first (no `-Apply`)') -and $agentsFlat.Contains('Rerun with `-Apply` only after the owner authorizes it.')) 'AGENTS.md requires the deploy-skills dry run first and -Apply only with owner authorization'
Assert-TestCondition ($agentsFlat.Contains('pass `-Retire <name>` to both the dry run and the Apply') -and $agentsFlat.Contains('Never pass `.system` or a selected skill to `-Retire`.')) 'AGENTS.md binds retirement to one -Retire name on both runs that never names .system or a selected skill'
Assert-TestCondition ($agentsFlat.Contains('It never changes a live root, and the repository installs no Git hooks.')) 'AGENTS.md pins bootstrap as never changing a live root and the repository as hook-free'
Assert-TestCondition ($readmeFlat.Contains('It never changes a live skills directory, and the repository installs no Git hooks.')) 'README.md pins bootstrap as never changing a live skills directory and the repository as hook-free'
Assert-TestCondition ($agentsFlat.Contains('Never commit a `config-push` capture until a human has reviewed its `git diff`.')) 'AGENTS.md requires human review of a config-push capture before commit'
Assert-TestCondition ($agentsFlat.Contains('Never weaken, bypass, or whitelist `scripts/scan-secrets.ps1` or `.gitleaks.toml` without explicit user approval.')) 'AGENTS.md forbids weakening or whitelisting the secret scan without approval'
Assert-TestCondition ($agentsFlat.Contains('Never delete or weaken a suite, gate, timeout budget or the secret scan to get a green run.')) 'AGENTS.md forbids weakening a suite, gate or budget to get CI green'

Assert-TestCondition ((Get-LiteralOccurrenceCount -Text $readmeFlat -Needle 'claude/skills/`, `codex/skills/`, and `reasonix/skills/` are generated by `scripts/build-skills.ps1` and ignored by Git.') -eq 1) 'README.md pins all three generated roots as build output ignored by Git'
Assert-TestCondition ($agentsFlat.Contains('Never delete, move, overwrite, or modify `~/.codex/skills/.system`.')) 'AGENTS.md states the .system no-delete rule'
Assert-TestCondition ($agentsFlat.Contains('Never use `robocopy /MIR`')) 'AGENTS.md states the no-blanket-mirror rule'
Assert-TestCondition ($readmeFlat.Contains('**Codex `.system` is protected:**')) 'README.md states the .system protection rule'
Assert-TestCondition ($readmeFlat.Contains('Never run a bare `robocopy /MIR`')) 'README.md states the no-blanket-mirror rule'
Assert-TestCondition ($readmeFlat.Contains('directory remains unknown by default')) 'README.md states unknown live entries are preserved by default'
Assert-TestCondition ($docsReadmeFlat.Contains('旧 live 名称默认按 unknown 保留')) 'docs/README.md states old live names are preserved as unknown by default'
Assert-TestCondition ($docsReadmeFlat.Contains('其余 live 目录是 unknown：只报告不碰。Codex `.system` 永不触碰')) 'docs/README.md states deploy-skills never touches unknown live directories or .system'
Assert-TestCondition ($docsReadmeFlat.Contains('`-Apply` 会写真实 home：先审查 dry-run 的每一行，取得所有者授权后再执行。')) 'docs/README.md requires review and owner authorization before deploy-skills -Apply'

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
Assert-TestCondition ($buildSkillsText.Contains('.system is not a build source or generated skill.')) 'build-skills preserves .system by exclusion: it is never a build source or generated skill'

$scanSecretsText = Read-RepoText 'scripts/scan-secrets.ps1'
Assert-TestCondition ((Get-LiteralOccurrenceCount -Text $scanSecretsText -Needle "'claude/skills/', 'codex/skills/', 'reasonix/skills/'") -ge 1) 'the secret scan excludes all three generated roots'

# The roots also appear in the skill-rule scope, so the pin is scoped to the text of rule 2 itself.
$generatedRule = [regex]::Match($agentsFlat, '2\. \*\*Generated output\.\*\* (.*?) 3\. \*\*Live roots only through deploy-skills\.\*\*').Groups[1].Value
Assert-TestCondition ($generatedRule.StartsWith('Never edit generated output directly:')) 'AGENTS.md rule 2 forbids editing generated output directly'
foreach ($generatedRoot in @('claude/skills/', 'codex/skills/', 'reasonix/skills/')) {
    Assert-TestCondition ($generatedRule.Contains("``$generatedRoot``")) "AGENTS.md rule 2 lists $generatedRoot under the never-edit rule"
}

# -----------------------------------------------------------------------------
# Claude Code harness guard rails
# -----------------------------------------------------------------------------
Write-Host '[Claude Code harness guard rails]'
$settings = (Read-RepoText '.claude/settings.json') | ConvertFrom-Json
$deny = @($settings.permissions.deny)
$allow = @($settings.permissions.allow)
foreach ($rule in @('Edit(claude/skills/**)', 'Write(claude/skills/**)', 'Edit(codex/skills/**)', 'Write(codex/skills/**)', 'Edit(**/.codex/skills/.system/**)', 'Write(**/.codex/skills/.system/**)', 'Bash(robocopy *)', 'PowerShell(robocopy *)')) {
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
