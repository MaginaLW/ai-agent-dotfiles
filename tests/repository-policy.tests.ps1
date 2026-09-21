#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository safety-policy suite (Phase 4 Task 4, docs/specs/2026-09-16-phase4-
# schema-ci-release-proposal.md section 5, Steps 1-4 and 6). It pins the tracked
# instruction/doc claims, the symmetric generated-root write deny, the absence
# of retired platforms in scripts/ and manifests/, the preview/event-only
# automation surface, and the "no public Apply bypass" net. The parse-gate
# regression half of Task 4 lives in tests/powershell-syntax-gate.tests.ps1.
#
# Interlocked public contract note: the behavioral pins below are POLICY-STATE-
# AWARE (Phase 4 Task 8 Step 1 preparation). While `ReleaseState=interlocked`
# they pin the hard-stop interlocked contract (`canonical-apply-interlocked` /
# `canonical-recovery-apply-interlocked` with exit 75, the interlock token on
# the public mutation surfaces). Once the reviewed release candidate flips the
# policy, the same committed bytes pin the observed released post-Assert
# contract instead: every surface still exits fail-closed before any production
# write, and the canonical recovery engine runs under its own sealed binding
# checks. The SOURCE pins on the tracked docs, the interlock function's two
# early returns, and the hard-closed runner/backup tokens are policy-
# independent and stay unconditional.

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')

# Policy-state-aware behavioral pins (Phase 4 Task 8 Step 1 preparation): the
# same committed suite bytes assert the interlocked fail-closed contract while
# ReleaseState=interlocked, and each affected surface's observed released
# post-Assert contract once the reviewed release candidate flips the policy.
$policyState = [string] (Get-LiveSafetyPolicy).ReleaseState
$script:IsReleased = ($policyState -eq 'released')

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-repository-policy-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null

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

function Set-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-FixtureSkill {
    param([Parameter(Mandatory)] [string] $Directory, [Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Text)
    Set-TextFile -Path (Join-Path $Directory 'SKILL.md') -Content ("---`nname: $Name`ndescription: test $Name`n---`n`n## Steps`n`n- $Text`n")
}

function Set-CurrentUserOnlyAcl {
    param([Parameter(Mandatory)] [string] $Path)
    $template = Get-CanonicalCurrentUserOnlySecurityTemplate
    $sid = [System.Security.Principal.SecurityIdentifier]::new([string] $template.OwnerSid)
    $security = [System.Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::FullControl, $inherit, [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Initialize-CanonicalReadyFixture {
    # Mirrors the reviewed canonical-ready fixture shape used by the automation
    # safety and canonical suites: ACL'd private roots, setup state, root claim,
    # and the canonical lock file.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $SlotRoot)
    $recovery = Join-Path $SlotRoot 'recovery'; $control = Join-Path $SlotRoot 'control'
    $backup = Join-Path $SlotRoot 'backups'; $probe = Join-Path $SlotRoot 'probe'
    foreach ($directory in @($recovery, $control, $backup, $probe)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
    foreach ($directory in @($recovery, $control, $backup)) { Set-CurrentUserOnlyAcl -Path $directory }
    [System.IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots')) | Out-Null
    $payload = New-CanonicalSetupPlanPayload -RepoRoot $Path -CanonicalRecoveryRoot $recovery -ControlBase $control -BackupRoot $backup -ProbeRoot $probe -ToolchainRoot $RepoRoot
    $finalState = New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $Path
    $git = Get-CanonicalGitContext -RepoRoot $Path
    $paths = Get-CanonicalTransactionContractPaths -GitContext $git
    $lock = Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate
    Exit-CanonicalRepoLock -LockHandle $lock
    [System.IO.File]::WriteAllBytes($paths.SetupStatePath, (ConvertTo-SemanticJsonBytes -InputObject $finalState))
    $claimPath = Join-Path $control (Join-Path 'canonical-roots' ($payload.ExpectedSetupStateProjection.RepoId + '.json'))
    [System.IO.File]::WriteAllBytes($claimPath, (ConvertTo-SemanticJsonBytes -InputObject $payload.ExpectedRootClaim))
    return $git
}

try {
    # -------------------------------------------------------------------------
    # Step 1: tracked instruction and documentation claims
    # -------------------------------------------------------------------------
    Write-Host '[tracked instruction and documentation claims]'
    $agentsText = Read-RepoText 'AGENTS.md'
    $claudeText = Read-RepoText 'CLAUDE.md'
    $readmeText = Read-RepoText 'README.md'
    $docsReadmeText = Read-RepoText 'docs/README.md'

    foreach ($entry in @(
        @{ File = 'AGENTS.md'; Text = $agentsText },
        @{ File = 'CLAUDE.md'; Text = $claudeText },
        @{ File = 'README.md'; Text = $readmeText }
    )) {
        foreach ($platform in @('claude', 'codex', 'reasonix')) {
            Assert-TestCondition ($entry.Text.IndexOf($platform, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) "$($entry.File) mentions $platform"
        }
    }

    Assert-TestCondition ($agentsText.Contains('skills-source/reasonix-only/<name>/')) 'AGENTS.md carries the reasonix-only source root concept'
    Assert-TestCondition ($claudeText.Contains('skills-source/reasonix-only/<name>/')) 'CLAUDE.md carries the reasonix-only source root concept'
    Assert-TestCondition ($claudeText.Contains('`skills-source/reasonix-only/` is the Reasonix-only source.')) 'CLAUDE.md states the Reasonix-only source rule'
    Assert-TestCondition ($docsReadmeText.Contains('skills-source/reasonix-only/')) 'docs/README.md documents the reasonix-only source root'

    foreach ($manifest in @('manifests/managed-skills.claude.txt', 'manifests/managed-skills.codex.txt', 'manifests/managed-skills.reasonix.txt', 'manifests/managed-skills.txt')) {
        Assert-TestCondition (Test-Path -LiteralPath (Join-Path $RepoRoot $manifest) -PathType Leaf) "the per-platform manifest $manifest exists"
    }
    Assert-TestCondition ($agentsText.Contains('manifests/managed-skills.txt`, `manifests/managed-skills.reasonix.txt')) 'AGENTS.md scope trigger names the per-platform manifests'
    Assert-TestCondition ($claudeText.Contains('manifests/managed-skills.txt`, `manifests/managed-skills.reasonix.txt')) 'CLAUDE.md scope trigger names the per-platform manifests'
    Assert-TestCondition ($docsReadmeText.Contains('manifests/managed-skills.txt` | 三平台 union inventory')) 'docs/README.md documents the union manifest and per-platform authority'

    Assert-TestCondition ($agentsText.Contains('hooks remain preview/event-only and never Apply')) 'AGENTS.md pins hooks as preview/event-only that never Apply'
    Assert-TestCondition ($readmeText.Contains('They never create an actionable plan or Apply live changes.')) 'README.md pins hooks to never create actionable plans or Apply'
    Assert-TestCondition ($readmeText.Contains('Internal preview paths are never valid public `-PlanPath` values.')) 'README.md denies internal preview paths as public plan inputs'
    Assert-TestCondition ($docsReadmeText.Contains('preview-only hooks')) 'docs/README.md documents the installed hooks as preview-only'
    Assert-TestCondition ($readmeText.Contains('the pinned JSON Schema validator, pinned gitleaks scanner, then explicit runner approval')) 'README.md documents the pinned bootstrap dependency order'

    Assert-TestCondition ($agentsText.Contains('a released policy value is not deployment authorization or completed lab acceptance')) 'AGENTS.md documents that a released policy value is not deployment authorization'
    Assert-TestCondition ($agentsText.Contains('The public standalone backup entry is retired and exits')) 'AGENTS.md documents the retired standalone backup entry'
    Assert-TestCondition ($claudeText.Contains('`safety-protocol-upgrade-required` before traversal or mutation')) 'CLAUDE.md documents the production interlock token before traversal or mutation'
    Assert-TestCondition ($claudeText.Contains('the public standalone')) 'CLAUDE.md documents the retired standalone backup entry'
    Assert-TestCondition ($readmeText.Contains('policy behavior and release acceptance are separate')) 'README.md documents that policy behavior and release acceptance are separate'
    Assert-TestCondition ($readmeText.Contains('it writes nothing and exits `backup-is-transaction-internal` instead')) 'README.md documents the retired standalone backup entry behavior'
    Assert-TestCondition ($readmeText.Contains('# Invocation shape only; check STATUS.md current state and acceptance before use.')) 'README.md documents the invocation-shape-only external DryRun flow'
    Assert-TestCondition ($agentsText.Contains('The schema 3 sync DryRun runs only inside the internal sandbox with a create-new')) 'AGENTS.md documents the sandbox-hosted create-new DryRun plan'

    Assert-TestCondition ((Get-LiteralOccurrenceCount -Text $readmeText -Needle 'claude/skills/`, `codex/skills/`, and `reasonix/skills/` are generated by `scripts/build-skills.ps1` and ignored by Git.') -eq 1) 'README.md pins all three generated roots as build output ignored by Git'
    Assert-TestCondition ($agentsText.Contains('Never delete, move, overwrite, or modify `~/.codex/skills/.system`.')) 'AGENTS.md states the .system no-delete rule'
    Assert-TestCondition ($claudeText.Contains('Never delete, move, overwrite, or modify `~/.codex/skills/.system`.')) 'CLAUDE.md states the .system no-delete rule'
    Assert-TestCondition ($readmeText.Contains('**Codex `.system` is protected:**')) 'README.md states the .system protection rule'
    Assert-TestCondition ($readmeText.Contains('Never run a bare `robocopy /MIR`')) 'README.md states the no-blanket-mirror rule'
    Assert-TestCondition ($readmeText.Contains('directory remains unknown by default')) 'README.md states unknown live entries are preserved by default'
    Assert-TestCondition ($claudeText.Contains('it never touches unknown live directories, Codex `.system`')) 'CLAUDE.md states rollback never touches unknown live directories or .system'
    Assert-TestCondition ($docsReadmeText.Contains('旧 live 名称默认按 unknown 保留')) 'docs/README.md states old live names are preserved as unknown by default'
    Assert-TestCondition ($docsReadmeText.Contains('它永不触碰 unknown live 目录、Codex `.system`')) 'docs/README.md states the managed surface never touches unknown live directories or .system'

    # -------------------------------------------------------------------------
    # Step 2: generated-root write deny is symmetric across all three platforms
    # -------------------------------------------------------------------------
    Write-Host '[generated-root write deny symmetry]'
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

    $scanInputText = Read-RepoText 'scripts/scan-input-common.ps1'
    $exclusionLiteral = "'claude/skills/', 'codex/skills/', 'reasonix/skills/'"
    Assert-TestCondition ((Get-LiteralOccurrenceCount -Text $scanInputText -Needle $exclusionLiteral) -eq 3) 'the scan-input boundary excludes all three generated roots in every default exclusion list'

    foreach ($instructionsFile in @('AGENTS.md', 'CLAUDE.md')) {
        $text = Read-RepoText $instructionsFile
        Assert-TestCondition ($text.Contains('Never edit generated output directly:')) "$instructionsFile forbids editing generated output directly"
        foreach ($generatedRoot in @('claude/skills/', 'codex/skills/', 'reasonix/skills/')) {
            Assert-TestCondition ($text.Contains("   - ``$generatedRoot``")) "$instructionsFile lists $generatedRoot under the never-edit rule"
        }
    }

    # -------------------------------------------------------------------------
    # Step 3: no MCP / OpenClaw / OpenCode reintroduction in scripts or manifests
    # -------------------------------------------------------------------------
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

    # -------------------------------------------------------------------------
    # Step 4: no hook/bootstrap reachable Apply; the interlock has no bypass
    # -------------------------------------------------------------------------
    Write-Host '[no hook or bootstrap reachable Apply]'
    $autoSyncText = Read-RepoText 'scripts/auto-sync-after-git.ps1'
    Assert-TestCondition ($autoSyncText.Contains("Exit-Diagnostic -Token 'safety-protocol-upgrade-required' -Detail 'Phase 0 automation is preview-only and canonical routing is not released.' -Code 73 }")) 'the manual/Force runner path hard-closes with the interlock token and exit 73'
    foreach ($hookSurface in @('bootstrap.ps1', 'scripts/bootstrap-clone.ps1', 'scripts/auto-sync-after-git.ps1', 'scripts/approved-hook-entry.ps1')) {
        Assert-TestCondition ((Get-LiteralOccurrenceCount -Text (Read-RepoText $hookSurface) -Needle '-Apply') -eq 0) "$hookSurface carries no -Apply usage"
    }
    Assert-TestCondition ((Get-LiteralOccurrenceCount -Text (Read-RepoText 'scripts/activate-harness-env.ps1') -Needle '-SkipBuild/-SkipSecretScan are -DryRun only') -eq 1) 'activation Apply rejects the public skip switches'
    Assert-TestCondition ((Get-LiteralOccurrenceCount -Text (Read-RepoText 'scripts/task-skills.ps1') -Needle 'task previews and applies carry no public skip gates.') -eq 1) 'task-skills previews and applies carry no public skip gates'

    Write-Host '[interlock function has no CLI or env bypass]'
    $interlockPath = Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1'
    $parseTokens = $null
    $parseErrors = $null
    $interlockAst = [System.Management.Automation.Language.Parser]::ParseFile($interlockPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-TestCondition (@($parseErrors).Count -eq 0) 'live-safety-interlock.ps1 parses without errors'
    $assertFunction = @($interlockAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Assert-LiveSafetyMutationAllowed' }, $true))[0]
    Assert-TestCondition ($null -ne $assertFunction) 'Assert-LiveSafetyMutationAllowed is defined in live-safety-interlock.ps1'
    $returnStatements = @($assertFunction.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.ReturnStatementAst] }, $true))
    Assert-TestCondition ($returnStatements.Count -eq 2) 'the interlock assert has exactly two early-return paths'
    $parameterNames = @($assertFunction.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.Extent.Text })
    Assert-TestCondition ((@(Compare-Object $parameterNames @('$Operation', '$Paths')).Count -eq 0)) 'the interlock assert exposes only Operation and Paths (no bypass parameter)'
    $assertBodyText = $assertFunction.Body.Extent.Text
    Assert-TestCondition ($assertBodyText.Contains("-eq 'released') { return }")) 'the first early return is the released policy state'
    Assert-TestCondition ($assertBodyText.Contains('Test-LiveSafetySandboxCapability -Paths $Paths) { return }')) 'the second early return is the held sandbox capability'
    Assert-TestCondition ($assertBodyText -notmatch '\$env:|GetEnvironmentVariable') 'the interlock assert reads no environment variables directly'

    . (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')
    $liveSafetyPolicy = Get-LiveSafetyPolicy
    Assert-TestCondition ([string] $liveSafetyPolicy.InterlockDiagnostic -ceq 'safety-protocol-upgrade-required') 'the tracked policy diagnostic token is safety-protocol-upgrade-required'
    Assert-TestCondition (-not (Test-LiveSafetySandboxCapability -Paths @($work))) 'a plain test process holds no sandbox capability'
    $interlockThrew = $null
    try { Assert-LiveSafetyMutationAllowed -Operation 'repository-policy-self-check' -Paths @($work) } catch { $interlockThrew = $_.Exception.Message }
    if ($script:IsReleased) {
        Assert-TestCondition ($null -eq $interlockThrew) 'the mutation self-check returns without throwing under the released policy (released)'
    }
    else {
        Assert-TestCondition (($null -ne $interlockThrew) -and ($interlockThrew -cmatch 'safety-protocol-upgrade-required')) 'without release or a held capability, a mutation operation throws the interlock token'
    }

    # -------------------------------------------------------------------------
    # Step 6: the no-public-Apply-bypass net
    #
    # Every production mutation entry is one of:
    #   1. Assert-LiveSafetyMutationAllowed on -Apply (policy-state-aware pins:
    #      interlocked token while interlocked, observed released fail-closed
    #      token after the reviewed release):
    #      - sync.ps1 -Apply (plain)            -> pinned by tests/automation-safety.tests.ps1
    #      - sync.ps1 -Apply -RetireManifestPath -> pinned by tests/automation-safety.tests.ps1
    #      - activate-harness-env.ps1 -Apply     -> pinned by tests/automation-safety.tests.ps1
    #      - task-skills.ps1 -Apply ensure-skill -> pinned by tests/automation-safety.tests.ps1
    #      - task-skills.ps1 -Apply sync -Automatic -> pinned by tests/automation-safety.tests.ps1
    #      - task-skills.ps1 -Apply close        -> pinned by tests/automation-safety.tests.ps1
    #      - rollback-harness-env.ps1 -Apply     -> pinned by tests/automation-safety.tests.ps1
    #      - authority-harness-env.ps1 -Apply    -> pinned BELOW (was missing from automation-safety)
    #   2. A named hard-closed token (policy-independent):
    #      - backup.ps1 public standalone: backup-is-transaction-internal, exit 1
    #        before traversal -> pinned by tests/automation-safety.tests.ps1
    #      - auto-sync-after-git manual/Force: safety-protocol-upgrade-required,
    #        exit 73 -> pinned above and behaviorally below
    #      - canonical-transaction.ps1 -Apply and recover-canonical-transaction.ps1
    #        -Apply: policy-state-aware pins BELOW (interlocked exit 75 hard stop;
    #        released post-Assert engine/lock contract per the header note)
    #   3. Classified non-live (profile apply writes only project-local allowlist
    #      output) -> covered by tests/harness-profile.tests.ps1.
    # -------------------------------------------------------------------------
    Write-Host '[relied-on automation-safety coverage]'
    $automationSafetyText = Read-RepoText 'tests/automation-safety.tests.ps1'
    foreach ($reliedOnNeedle in @(
        "@{ Name='sync apply'; Script='sync.ps1'",
        "-RetireManifestPath",
        "@{ Name='environment activate apply'; Script='activate-harness-env.ps1'",
        "@{ Name='task ensure apply'",
        "@{ Name='task sync automatic apply'",
        "@{ Name='task close apply'",
        "@{ Name='environment rollback apply'; Script='rollback-harness-env.ps1'",
        "'backup-is-transaction-internal'"
    )) {
        Assert-TestCondition ($automationSafetyText.Contains($reliedOnNeedle)) "automation-safety still pins the net case: $reliedOnNeedle"
    }

    Write-Host '[authority apply refuses outside the sandbox]'
    $fakeRepo = Join-Path $work 'fake-repo'
    New-Item -ItemType Directory -Path $fakeRepo -Force | Out-Null
    $authorityResult = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/authority-harness-env.ps1') -Arguments @(
        '-Action', 'adopt', '-Name', 'missing', '-RepoRoot', $fakeRepo,
        '-PlanPath', (Join-Path $work 'authority-plan.json'), '-Apply'
    )
    if ($script:IsReleased) {
        # The released Assert returns, so the run reaches the first post-Assert
        # gate: resolving the reviewed plan artifact (the fixture repo is not a
        # Git repository, so the artifact resolution itself fails closed before
        # any traversal or plan consumption).
        Assert-TestCondition (($authorityResult.Code -ne 0) -and ($authorityResult.Out -match 'Resolve-PrivateArtifactPath') -and ($authorityResult.Out -notmatch 'safety-protocol-upgrade-required')) 'authority-harness-env -Apply proceeds past the released Assert and fails closed at the reviewed plan artifact gate (released)'
    }
    else {
        Assert-TestCondition (($authorityResult.Code -ne 0) -and ($authorityResult.Out -match 'safety-protocol-upgrade-required')) 'authority-harness-env -Apply is interlocked before any traversal or plan consumption'
    }

    Write-Host '[live recovery public surface stays fail-closed]'
    # Phase 4 PR-G Step 2 landed: live-recover Apply now calls Assert-
    # LiveSafetyMutationAllowed BEFORE the resolver, and that Assert-first
    # order is pinned behaviorally by tests/live-recovery.tests.ps1 (a public
    # Apply refuses with safety-protocol-upgrade-required while interlocked and
    # writes no plan). Pinned here is the cheap public DryRun fact: outside the
    # internal sandbox it fails closed before any plan derivation and writes no
    # plan at all (zero live writes). While interlocked the resolver itself
    # refuses; on a released commit the shared resolver resolves the real
    # Windows identity and the run fails closed at the released identity
    # authority check (or, on a host with a complete authority, at the next
    # reviewed gate). The sandbox-hosted plan-only derivation is covered by
    # tests/live-recovery.tests.ps1.
    $liveRecoverPlanPath = Join-Path $work 'live-recovery-plan.json'
    $liveRecoverResult = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/recover-live-transaction.ps1') -Arguments @(
        '-Action', 'abandon', '-TransactionId', ([Guid]::NewGuid().ToString('D')),
        '-DryRun', '-PlanPath', $liveRecoverPlanPath, '-RepoRoot', $fakeRepo
    )
    if ($script:IsReleased) {
        Assert-TestCondition (($liveRecoverResult.Code -ne 0) -and ($liveRecoverResult.Out -match 'live-plan-authority-missing|Canonical transaction requires a Git repository')) 'the public live-recovery DryRun fails closed on the released host authority path (released)'
    }
    else {
        Assert-TestCondition (($liveRecoverResult.Code -ne 0) -and ($liveRecoverResult.Out -match 'live-plan-host-resolution-required')) 'the public live-recovery DryRun fails closed without the sandbox capability'
    }
    Assert-TestCondition (-not (Test-Path -LiteralPath $liveRecoverPlanPath)) 'the refused live-recovery DryRun writes no plan file'

    Write-Host '[approved runner manual trigger is hard-closed]'
    $runnerRepo = Join-Path $work 'runner-repo'
    $runnerPolicy = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'scripts/runner-policy.psd1')
    foreach ($relative in @($runnerPolicy.ToolchainPaths | Sort-Object -Unique)) {
        $source = Join-Path $RepoRoot $relative
        $destination = Join-Path $runnerRepo $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [System.IO.File]::Copy($source, $destination, $false)
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $runnerRepo 'harness-source/profiles') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $runnerRepo 'harness-source/components') -Recurse -Force
    foreach ($relative in @('manifests', 'skills-source/shared/fixture-a', '.agent-harness', 'harness-source/envs')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $runnerRepo $relative)) | Out-Null
    }
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        [System.IO.File]::WriteAllText((Join-Path $runnerRepo "manifests/managed-skills.$platform.txt"), "fixture-a`n", [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText((Join-Path $runnerRepo 'skills-source/shared/fixture-a/SKILL.md'), "---`nname: fixture-a`ndescription: repository policy fixture`n---`nfixture`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runnerRepo '.agent-harness/task-skills.psd1'), "@{`n    SchemaVersion = 1`n    BaseEnv = 'full'`n    Skills = @{ Claude = @(); Codex = @(); Reasonix = @() }`n}`n", [System.Text.UTF8Encoding]::new($false))
    [System.IO.File]::WriteAllText((Join-Path $runnerRepo 'harness-source/envs/full.psd1'), "@{`n    SchemaVersion = 1`n    Name = 'full'`n    Description = 'repository policy fixture env'`n    Profile = 'base'`n    Skills = @{ Claude = @('fixture-a'); Codex = @(); Reasonix = @() }`n}`n", [System.Text.UTF8Encoding]::new($false))
    & git -C $runnerRepo init -q
    & git -C $runnerRepo config user.email 'tests@example.invalid'
    & git -C $runnerRepo config user.name 'Repository Policy Tests'
    & git -C $runnerRepo config core.autocrlf false
    & git -C $runnerRepo add -- .
    & git -C $runnerRepo commit -qm 'repository policy runner fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Runner fixture commit failed.' }
    $setupResult = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/setup.ps1') -Arguments @('-RepoRoot', $runnerRepo, '-ApproveRunner')
    Assert-TestCondition ($setupResult.Code -eq 0) 'the runner fixture approves its extended toolchain bundle'
    . (Join-Path $RepoRoot 'scripts/approved-runner-common.ps1')
    . (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
    $runnerState = Get-ApprovedRunnerState -RepoRoot $runnerRepo
    $null = Initialize-CanonicalReadyFixture -Path $runnerRepo -SlotRoot (Join-Path $work 'runner-canonical')
    $manualRun = Invoke-TestProcess -ScriptPath ([string] $runnerState.RunnerEntryPath) -Arguments @('-RepoRoot', $runnerRepo, '-Trigger', 'manual')
    Assert-TestCondition (($manualRun.Code -eq 73) -and ($manualRun.Out -match 'safety-protocol-upgrade-required')) 'the approved runner manual trigger returns the interlock token with exit 73 and zero routing'

    Write-Host '[canonical public apply stays interlocked]'
    # Policy-state-aware pin (see the header note): interlocked hard stop below;
    # released post-Assert contract in the branched assertion.
    $canonicalRepo = Join-Path $work 'canonical-repo'
    foreach ($root in @('skills-source/shared', 'skills-source/claude-only', 'skills-source/codex-only', 'skills-source/reasonix-only', 'claude/skills', 'codex/skills', 'reasonix/skills', 'manifests')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $canonicalRepo $root)) | Out-Null
    }
    New-FixtureSkill -Directory (Join-Path $canonicalRepo 'skills-source/shared/base') -Name 'base' -Text 'base'
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        New-FixtureSkill -Directory (Join-Path $canonicalRepo "$platform/skills/base") -Name 'base' -Text 'base'
    }
    foreach ($manifestName in @('managed-skills.claude.txt', 'managed-skills.codex.txt', 'managed-skills.reasonix.txt', 'managed-skills.txt')) {
        Set-TextFile -Path (Join-Path $canonicalRepo "manifests/$manifestName") -Content "base`n"
    }
    & git -C $canonicalRepo init -q
    & git -C $canonicalRepo config user.email 'tests@example.invalid'
    & git -C $canonicalRepo config user.name 'Repository Policy Tests'
    & git -C $canonicalRepo config core.autocrlf false
    & git -C $canonicalRepo add -- .
    & git -C $canonicalRepo commit -qm 'repository policy canonical fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Canonical fixture commit failed.' }

    $canonicalExternal = Join-Path $work 'canonical-external'
    $candidate = Join-Path $canonicalRepo 'tmp/candidate'
    $null = Copy-SafeTree -SourceRoot (Join-Path $canonicalRepo 'skills-source') -DestinationRoot (Join-Path $candidate 'skills-source')
    $canonicalInput = Join-Path $candidate 'skills-source/shared/new-skill'
    New-FixtureSkill -Directory $canonicalInput -Name 'new-skill' -Text 'candidate'
    $canonicalPlan = Join-Path $canonicalExternal 'repository-policy-plan.json'
    $canonicalPreflight = Join-Path $canonicalExternal 'repository-policy-preflight'
    $canonicalDryRun = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/canonical-transaction.ps1') -Arguments @(
        '-RepoRoot', $canonicalRepo, '-OperationKind', 'normalize', '-DryRun', '-PlanPath', $canonicalPlan,
        '-CandidateWorkspace', $candidate, '-InputPath', $canonicalInput,
        '-RewriteList', 'frontmatter-normalized', '-CanonicalPreflightOutputRoot', $canonicalPreflight
    )
    if ($canonicalDryRun.Code -ne 0) { Write-Host $canonicalDryRun.Out }
    Assert-TestCondition (($canonicalDryRun.Code -eq 0) -and (Test-Path -LiteralPath $canonicalPlan)) 'the canonical fixture publishes one external create-new reviewed plan'
    $canonicalApply = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/canonical-transaction.ps1') -Arguments @(
        '-RepoRoot', $canonicalRepo, '-OperationKind', 'normalize', '-Apply', '-PlanPath', $canonicalPlan
    )
    if ($script:IsReleased) {
        # Observed released contract: the Assert returns, the lock-order
        # acquisition fails closed for a repo without canonical setup
        # (filtered to held=$null), and the skill route refuses with the typed
        # canonical-setup-required WARN result (exit 1) before any mutation.
        Assert-TestCondition (($canonicalApply.Code -eq 1) -and ($canonicalApply.Out -match 'canonical-setup-required')) 'canonical public Apply proceeds past the released Assert and fails closed on the missing canonical setup (released)'
    }
    else {
        Assert-TestCondition (($canonicalApply.Code -eq 75) -and ($canonicalApply.Out -match 'canonical-apply-interlocked')) 'canonical public Apply revalidates the reviewed plan and hard-stops interlocked with exit 75'
    }

    Write-Host '[canonical recovery public apply stays interlocked]'
    # Policy-state-aware pin (see the header note); the released branch pins the
    # observed post-Assert production recovery engine outcome.
    $canonicalGit = Initialize-CanonicalReadyFixture -Path $canonicalRepo -SlotRoot (Join-Path $work 'canonical-slot')
    Assert-TestCondition ((Get-CanonicalSetupStatus -RepoRoot $canonicalRepo -ToolchainRoot $RepoRoot) -ceq 'canonical-ready') 'the canonical recovery fixture reports canonical-ready'
    $transactionId = [Guid]::NewGuid().ToString('D')
    $transactionNamespace = Join-Path (Get-CanonicalTransactionContractPaths -GitContext $canonicalGit).TransactionsRoot (Join-Path $canonicalGit.WorktreeId $transactionId)
    $recoveryTransactionRoot = Join-Path (Join-Path $work 'canonical-slot/recovery') (Join-Path $canonicalGit.WorktreeId $transactionId)
    $journalHeader = [ordered]@{
        SchemaVersion = 1; ArtifactKind = 'canonical-journal-header'; TransactionId = $transactionId
        CanonicalOperationKind = 'normalize'; OriginalDocumentHash = ('1' * 64); OriginalPlanHash = ('2' * 64)
        RepoId = [string] (Get-CanonicalRepoIdentity -GitContext $canonicalGit)
        GitCommonDirHash = [string] $canonicalGit.GitCommonDirHash; WorktreeId = [string] $canonicalGit.WorktreeId
        TransactionNamespace = [System.IO.Path]::GetFullPath($transactionNamespace)
        RecoveryTransactionRoot = [System.IO.Path]::GetFullPath($recoveryTransactionRoot)
        ExpectedPostconditionsHash = ('3' * 64); Targets = @()
    }
    $null = New-CanonicalJournalHeader -Document $journalHeader -TransactionNamespace $transactionNamespace
    $recoveryPlan = Join-Path $work 'repository-policy-recovery-plan.json'
    $recoveryDryRun = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/recover-canonical-transaction.ps1') -Arguments @(
        '-RepoRoot', $canonicalRepo, '-Action', 'abandon', '-TransactionId', $transactionId, '-DryRun', '-PlanPath', $recoveryPlan
    )
    if ($recoveryDryRun.Code -ne 0) { Write-Host $recoveryDryRun.Out }
    Assert-TestCondition (($recoveryDryRun.Code -eq 0) -and (Test-Path -LiteralPath $recoveryPlan)) 'the canonical recovery DryRun derives one reviewed plan from the unfinished journal'
    $recoveryApply = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/recover-canonical-transaction.ps1') -Arguments @(
        '-RepoRoot', $canonicalRepo, '-Action', 'abandon', '-TransactionId', $transactionId, '-Apply', '-PlanPath', $recoveryPlan
    )
    if ($script:IsReleased) {
        # Observed released contract on a host whose home-authority bootstrap
        # is not complete: the Assert returns, the lock order is skipped (the
        # bootstrap gate stays fail-closed), and the production recovery engine
        # runs the reviewed abandon to completion against the fixture's own
        # sealed journal namespace.
        Assert-TestCondition (($recoveryApply.Code -eq 0) -and ($recoveryApply.Out -match 'canonical-recovery-applied')) 'canonical public recovery Apply proceeds past the released Assert and the production engine completes the reviewed abandon (released)'
    }
    else {
        Assert-TestCondition (($recoveryApply.Code -eq 75) -and ($recoveryApply.Out -match 'canonical-recovery-apply-interlocked')) 'canonical public recovery Apply revalidates the reviewed plan and hard-stops interlocked with exit 75'
    }

    Write-Host 'repository policy tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
