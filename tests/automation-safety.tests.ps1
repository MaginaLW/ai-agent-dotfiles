#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
. (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')

# Policy-state-aware behavioral pins (Phase 4 Task 8 Step 1 preparation): the
# same committed suite bytes assert the interlocked fail-closed contract while
# ReleaseState=interlocked, and each affected surface's observed released
# post-Assert contract once the reviewed release candidate flips the policy.
$policyState = [string] (Get-LiveSafetyPolicy).ReleaseState
$script:IsReleased = ($policyState -eq 'released')

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-automation-safety-$([Guid]::NewGuid().ToString('N'))"
$fakeRepo = Join-Path $work 'repo'
$fakeHome = Join-Path $work 'home'
$backupRoot = Join-Path $work 'backups'
$sandboxRoot = Join-Path $work 'sandbox'
New-Item -ItemType Directory -Path $fakeRepo, $sandboxRoot, (Join-Path $fakeHome '.codex/skills/.system') -Force | Out-Null
$systemSentinel = Join-Path $fakeHome '.codex/skills/.system/locked-sentinel.txt'
[System.IO.File]::WriteAllText($systemSentinel, 'do-not-open', [System.Text.UTF8Encoding]::new($false))
$beforeHash = (Get-FileHash -LiteralPath $systemSentinel -Algorithm SHA256).Hash

try {
    # ReleasedPattern names the observed released-mode fail-closed token for
    # each surface (Task 8 Step 1 preparation): after the released Assert
    # returns, every case below still exits non-zero before any production
    # write. The rollback case resolves the real identity authority, so its
    # released token set covers the incomplete-authority and missing-receipt
    # fail-closed outcomes of the released public route. The task-skills
    # patterns pin the unique suffix of their typed tokens (the full
    # task-overlay-... literals would trip the secret scanner's generic sk-
    # API-key heuristic on the task- prefix; the suffix identifies the same
    # token in the script output).
    $cases = @(
        @{ Name='sync apply'; Script='sync.ps1'; Args=@('-RepoRoot',$fakeRepo,'-Apply','-SkipBuild','-SkipSecretScan'); ReleasedPattern='requires a reviewed -PlanPath' },
        @{ Name='retirement sync apply'; Script='sync.ps1'; Args=@('-RepoRoot',$fakeRepo,'-Apply','-SkipBuild','-SkipSecretScan','-RetireManifestPath',(Join-Path $work 'retire.json')); ReleasedPattern='requires a reviewed -PlanPath' },
        @{ Name='environment activate apply'; Script='activate-harness-env.ps1'; Args=@('-Name','missing','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan'); ReleasedPattern='activation-plan-path-required' },
        @{ Name='task ensure apply'; Script='task-skills.ps1'; Args=@('-Action','ensure-skill','missing','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan'); ReleasedPattern='overlay-skip-switch-forbidden' },
        @{ Name='task sync automatic apply'; Script='task-skills.ps1'; Args=@('-Action','sync','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-Automatic','-SkipBuild','-SkipSecretScan'); ReleasedPattern='overlay-automatic-removed' },
        @{ Name='task close apply'; Script='task-skills.ps1'; Args=@('-Action','close','-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot,'-Apply','-SkipBuild','-SkipSecretScan'); ReleasedPattern='overlay-skip-switch-forbidden' },
        @{ Name='environment rollback apply'; Script='rollback-harness-env.ps1'; Args=@('-ReceiptPath',(Join-Path $work 'missing-receipt'),'-RepoRoot',$fakeRepo,'-PlanPath',(Join-Path $work 'plan.json'),'-Apply'); ReleasedPattern='live-plan-authority-missing|rollback-receipt-missing' }
    )
    foreach ($case in $cases) {
        $result = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot "scripts/$($case.Script)") -Arguments $case.Args
        if ($script:IsReleased) {
            Assert-TestCondition ($result.Code -ne 0 -and $result.Out -match $case.ReleasedPattern) "$($case.Name) proceeds past the released Assert and fails closed before production work (released)"
        }
        else {
            Assert-TestCondition ($result.Code -ne 0 -and $result.Out -match 'safety-protocol-upgrade-required') "$($case.Name) is interlocked before production work"
        }
    }

    $lock = [System.IO.File]::Open($systemSentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
    try {
        $result = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/backup.ps1') -Arguments @('-RepoRoot',$fakeRepo,'-HomeRoot',$fakeHome,'-BackupRoot',$backupRoot)
    }
    finally { $lock.Dispose() }
    Assert-TestCondition ($result.Code -ne 0 -and $result.Out -match 'backup-is-transaction-internal') 'standalone backup is retired to the zero-write transaction-internal diagnostic'
    Assert-TestCondition (-not (Test-Path -LiteralPath $backupRoot)) 'the refused apply cases create no backup root'
    Assert-TestCondition ((Get-FileHash -LiteralPath $systemSentinel -Algorithm SHA256).Hash -eq $beforeHash) 'protected .system sentinel remains byte-identical'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $fakeRepo 'state'))) 'the refused apply cases create no state path'

    $escaped = Invoke-SafetySandboxScript -SandboxRoot $sandboxRoot -ScriptPath (Join-Path $RepoRoot 'scripts/sync.ps1') -Arguments @(
        '-RepoRoot', $fakeRepo,
        '-Apply',
        '-SkipBuild',
        '-SkipSecretScan'
    )
    if ($script:IsReleased) {
        # The released Assert returns before its sandbox-path containment
        # check, so the escaped mutation run reaches sync's reviewed-plan
        # requirement and still exits non-zero before any production write.
        Assert-TestCondition ($escaped.Code -ne 0 -and $escaped.Out -match 'requires a reviewed -PlanPath') 'the escaped mutation run proceeds past the released Assert and fails closed at the reviewed plan requirement (released)'
    }
    else {
        Assert-TestCondition ($escaped.Code -ne 0 -and $escaped.Out -match 'safety-protocol-upgrade-required') 'internal capability refuses mutation paths outside its sandbox'
    }
    Assert-TestCondition (-not (Test-Path -LiteralPath $backupRoot)) 'rejected internal capability creates no backup root'

    # ---------------------------------------------------------------------
    # Phase 3 Task 8: the pinned runner routes triggers from the shared
    # authority (selection-aware preview routing). Every route stays
    # preview/event-only: at most one validated non-consumable artifact in the
    # Git-private pending namespace plus an explicit external DryRun command,
    # and zero live writes in any branch.
    # ---------------------------------------------------------------------
    $task8 = Join-Path $work 'task8'
    $task8Repo = Join-Path $task8 'repo'
    $task8Linked = Join-Path $task8 'linked'
    $task8Home = Join-Path $task8 'home'
    $task8External = Join-Path $task8 'external'
    New-Item -ItemType Directory -Path $task8Repo, $task8Home, $task8External, (Join-Path $task8Home 'AppData/Local'), (Join-Path $task8Home 'AppData/Roaming') -Force | Out-Null

    function Initialize-Task8PolicyRepo {
        param([Parameter(Mandatory)] [string] $Path)
        & git -C $Path init -q
        & git -C $Path config user.email 'tests@example.invalid'
        & git -C $Path config user.name 'Automation Safety Tests'
        & git -C $Path config core.autocrlf false
        $policy = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'scripts/runner-policy.psd1')
        foreach ($relative in @($policy.ToolchainPaths | Sort-Object -Unique)) {
            $source = Join-Path $RepoRoot $relative
            $destination = Join-Path $Path $relative
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            [System.IO.File]::Copy($source, $destination, $false)
        }
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $Path 'harness-source/profiles') -Recurse -Force
        Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $Path 'harness-source/components') -Recurse -Force
        foreach ($relative in @('manifests', 'skills-source/shared/fixture-a', '.agent-harness', 'harness-source/envs')) {
            [System.IO.Directory]::CreateDirectory((Join-Path $Path $relative)) | Out-Null
        }
        foreach ($platform in @('claude', 'codex', 'reasonix')) {
            [System.IO.File]::WriteAllText((Join-Path $Path "manifests/managed-skills.$platform.txt"), "fixture-a`n", [System.Text.UTF8Encoding]::new($false))
        }
        [System.IO.File]::WriteAllText((Join-Path $Path 'skills-source/shared/fixture-a/SKILL.md'), "---`nname: fixture-a`ndescription: task8 fixture`n---`nfixture`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $Path '.agent-harness/task-skills.psd1'), "@{`n    SchemaVersion = 1`n    BaseEnv = 'full'`n    Skills = @{ Claude = @(); Codex = @(); Reasonix = @() }`n}`n", [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText((Join-Path $Path 'harness-source/envs/full.psd1'), "@{`n    SchemaVersion = 1`n    Name = 'full'`n    Description = 'task8 fixture env'`n    Profile = 'base'`n    Skills = @{ Claude = @('fixture-a'); Codex = @(); Reasonix = @() }`n}`n", [System.Text.UTF8Encoding]::new($false))
        return $policy
    }

    function Set-Task8CurrentUserOnlyAcl {
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

    function Initialize-Task8CanonicalReady {
        param([Parameter(Mandatory)] [string] $Path)
        $git = Get-CanonicalGitContext -RepoRoot $Path
        $slot = Join-Path $task8 'canonical-ready'
        $recovery = Join-Path $slot 'recovery'; $control = Join-Path $slot 'control'; $backup = Join-Path $slot 'backups'; $probe = Join-Path $slot 'probe'
        foreach ($directory in @($recovery, $control, $backup, $probe)) { [System.IO.Directory]::CreateDirectory($directory) | Out-Null }
        foreach ($directory in @($recovery, $control, $backup)) { Set-Task8CurrentUserOnlyAcl -Path $directory }
        [System.IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots')) | Out-Null
        $payload = New-CanonicalSetupPlanPayload -RepoRoot $Path -CanonicalRecoveryRoot $recovery -ControlBase $control -BackupRoot $backup -ProbeRoot $probe -ToolchainRoot $RepoRoot
        $finalState = New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $Path
        $paths = Get-CanonicalTransactionContractPaths -GitContext $git
        $lock = Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate
        Exit-CanonicalRepoLock -LockHandle $lock
        [System.IO.File]::WriteAllBytes($paths.SetupStatePath, (ConvertTo-SemanticJsonBytes -InputObject $finalState))
        $claimPath = Join-Path $control (Join-Path 'canonical-roots' ($payload.ExpectedSetupStateProjection.RepoId + '.json'))
        [System.IO.File]::WriteAllBytes($claimPath, (ConvertTo-SemanticJsonBytes -InputObject $payload.ExpectedRootClaim))
        if ((Get-CanonicalSetupStatus -RepoRoot $Path -ToolchainRoot $RepoRoot) -cne 'canonical-ready') { throw 'Task 8 canonical-ready fixture failed.' }
    }

    $task8Policy = Initialize-Task8PolicyRepo -Path $task8Repo
    & git -C $task8Repo add -- .
    & git -C $task8Repo commit -qm 'task8 fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Task 8 fixture commit failed.' }
    & git -C $task8Repo worktree add -q -b task8-linked $task8Linked
    . (Join-Path $RepoRoot 'scripts/approved-runner-common.ps1')
    . (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
    $setupResult = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/setup.ps1') -Arguments @('-RepoRoot', $task8Repo, '-ApproveRunner')
    Assert-TestCondition ($setupResult.Code -eq 0) 'explicit setup approves the extended toolchain bundle and pins the preview route table'
    $task8State = Get-ApprovedRunnerState -RepoRoot $task8Repo
    Initialize-Task8CanonicalReady -Path $task8Repo

    # Explicit setup is the only route that pins the routing contract: a
    # checkout whose route table no longer matches the frozen authority route
    # set (or whose rows stop being the pinned diagnostic/environment-preview
    # rows) is refused, and no approved state is published.
    $task8BadRepo = Join-Path $task8 'bad-policy-repo'
    New-Item -ItemType Directory -Path $task8BadRepo -Force | Out-Null
    Initialize-Task8PolicyRepo -Path $task8BadRepo | Out-Null
    $badPolicyPath = Join-Path $task8BadRepo 'scripts/runner-policy.psd1'
    $goodPolicyText = [System.IO.File]::ReadAllText($badPolicyPath)
    [System.IO.File]::WriteAllText($badPolicyPath, ($goodPolicyText -replace "(?m)^\s*'takeover'\s*=.*\r?\n", ''), [System.Text.UTF8Encoding]::new($false))
    $shortTable = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/setup.ps1') -Arguments @('-RepoRoot', $task8BadRepo, '-ApproveRunner')
    Assert-TestCondition ($shortTable.Code -ne 0 -and $shortTable.Out -match 'runner-review-required' -and $shortTable.Out -match 'route table does not match the frozen authority route set') 'setup refuses a route table missing a frozen authority route'
    $flippedAction = $goodPolicyText -replace "Action = 'diagnostic'; Command = 'env authority adopt", "Action = 'environment-preview'; Command = 'env authority adopt"
    Assert-TestCondition ($flippedAction -cne $goodPolicyText) 'the route-table mutation fixture applied'
    [System.IO.File]::WriteAllText($badPolicyPath, $flippedAction, [System.Text.UTF8Encoding]::new($false))
    $flippedTable = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/setup.ps1') -Arguments @('-RepoRoot', $task8BadRepo, '-ApproveRunner')
    Assert-TestCondition ($flippedTable.Code -ne 0 -and $flippedTable.Out -match 'runner-review-required' -and $flippedTable.Out -match "preview route action for 'adopt' is not a pinned row") 'setup refuses a route row that would materialize a build for a diagnostic route'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $task8BadRepo '.git/ai-agent-dotfiles/approved-runner-state.json'))) 'a refused route table publishes no approved runner state'

    $identityPath = Join-Path $task8External 'authority-identity.json'
    $identityDocument = [ordered]@{
        ResolverVersion = 'sealed-home-authority-test-adapter-v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $task8Home
        RoamingAppDataRoot = (Join-Path $task8Home 'AppData/Roaming')
        LocalAppDataRoot = (Join-Path $task8Home 'AppData/Local')
    }
    [System.IO.File]::WriteAllText($identityPath, [System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $identityDocument)), [System.Text.UTF8Encoding]::new($false))
    $env:AI_AGENT_DOTFILES_AUTHORITY_IDENTITY = $identityPath

    function Get-Task8HomeFingerprint {
        $lines = foreach ($file in @(Get-ChildItem -LiteralPath $task8Home -File -Recurse -Force | Sort-Object FullName)) {
            '{0}|{1}' -f $file.FullName, (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash
        }
        return ($lines -join "`n")
    }

    function New-Task8DataCommit {
        param([Parameter(Mandatory)] [string] $Marker)
        $target = Join-Path $task8Repo 'skills-source/shared/fixture-a/notes.md'
        [System.IO.File]::WriteAllText($target, "$Marker`n", [System.Text.UTF8Encoding]::new($false))
        & git -C $task8Repo add -- skills-source
        & git -C $task8Repo commit -qm "task8 $Marker"
        return ((& git -C $task8Repo rev-parse HEAD) | Select-Object -First 1).Trim()
    }

    function Invoke-Task8Runner {
        param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $OldRev, [Parameter(Mandatory)] [string] $NewRev)
        return Invoke-TestProcess -ScriptPath ([string] $task8State.RunnerEntryPath) -Arguments @('-RepoRoot', $Repo, '-Trigger', 'post-checkout', '-OldRev', $OldRev, '-NewRev', $NewRev, '-CheckoutFlag', '1')
    }

    $task8Context = Get-RunnerStorageContext -RepoRoot $task8Repo -EnsureDirectories
    $firstCommit = ((& git -C $task8Repo rev-parse HEAD) | Select-Object -First 1).Trim()
    $secondCommit = New-Task8DataCommit -Marker 'r1'
    $homeBefore = Get-Task8HomeFingerprint

    # A drifted prior preview is marked stale via a sidecar, never rewritten.
    $staleEvent = [ordered]@{
        SchemaVersion = 1; ArtifactKind = 'pending-sync-event'; EventKind = 'preview'; WorktreeNamespace = $task8Context.WorktreeId
        Trigger = 'post-checkout'; ApprovedToolchainHash = ('a' * 64); CurrentToolchainHash = ('a' * 64)
        Commit = ('b' * 40); ContextHash = ('c' * 64); PreviewStatus = 'non-consumable'
        RedactedContext = 'route=initial stale-seed'; ContentHashes = @()
        ExternalDryRunCommand = 'pwsh -NoProfile -File scripts/agent-dotfiles.ps1 env activate full -DryRun -PlanPath <external-user-artifact>'
    }
    $stalePath = Write-ImmutableRunnerArtifact -Directory $task8Context.PendingPreviewsRoot -Prefix 'stale-seed' -Document $staleEvent
    $staleBytes = [System.IO.File]::ReadAllBytes($stalePath)

    $previewRun = Invoke-Task8Runner -Repo $task8Repo -OldRev $firstCommit -NewRev $secondCommit
    Assert-TestCondition ($previewRun.Code -eq 0 -and $previewRun.Out -match 'pending-preview-only') 'a pristine home routes post-checkout to the initial environment preview'
    Assert-TestCondition ($previewRun.Out -match 'env activate full' -and $previewRun.Out -match '-DryRun -PlanPath <external-user-artifact>') 'the initial preview prints the exact external activation DryRun command'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $task8Repo 'envs'))) 'the initial preview materializes nothing into the repository'
    Assert-TestCondition ((Get-Task8HomeFingerprint) -eq $homeBefore) 'the initial preview performs zero home writes'

    $previews = @(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File | Sort-Object Name)
    $staleSidecars = @($previews | Where-Object { $_.Name -like "$([System.IO.Path]::GetFileNameWithoutExtension($stalePath)).stale*" })
    Assert-TestCondition ($staleSidecars.Count -eq 1) 'the drifted prior preview gained exactly one stale sidecar'
    Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual($staleBytes, [System.IO.File]::ReadAllBytes($stalePath))) 'the drifted prior preview itself stays byte-identical'
    $newPreview = @($previews | Where-Object { $_.Name -notlike '*.stale*' -and $_.FullName -ne $stalePath })
    Assert-TestCondition ($newPreview.Count -eq 1) 'the routing wrote exactly one new pending preview'
    $previewDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($newPreview[0].FullName)))
    Assert-TestCondition ([string] $previewDocument.RedactedContext -match 'route=initial env=full build=env-build-v3-verified') 'the initial preview binds the named full environment and a verified env-build v3 materialization'
    Assert-TestCondition (@($previewDocument.ContentHashes).Count -ge 3 -and @($previewDocument.ContentHashes | Where-Object { $_ -cnotmatch '\A[0-9a-f]{64}\z' }).Count -eq 0) 'the preview content hashes bind the changed data and the verified build artifacts'
    Assert-TestCondition ([string] $previewDocument.PreviewStatus -ceq 'non-consumable') 'the routed preview stays non-consumable'
    Assert-TestCondition ([string] $previewDocument.ExternalDryRunCommand -notmatch '(?:^|\s)-Apply(?:\s|$)' -and [string] $previewDocument.ExternalDryRunCommand -match '-PlanPath <external-user-artifact>') 'the recorded preview command is DryRun-only and never an internal Apply PlanPath'

    # A non-pristine home routes to the adoption diagnostic: zero
    # materialization, one diagnostic-only event, one new stale sidecar for the
    # drifted preview, nonzero exit.
    [System.IO.Directory]::CreateDirectory((Join-Path $task8Home '.claude/skills/unknown-skill')) | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $task8Home '.claude/skills/unknown-skill/SKILL.md'), "unknown`n", [System.Text.UTF8Encoding]::new($false))
    $homeBefore = Get-Task8HomeFingerprint
    $thirdCommit = New-Task8DataCommit -Marker 'r2'
    $adoptRun = Invoke-Task8Runner -Repo $task8Repo -OldRev $secondCommit -NewRev $thirdCommit
    Assert-TestCondition ($adoptRun.Code -eq 76 -and $adoptRun.Out -match "routed this trigger to the 'adopt' diagnostic") 'a non-pristine home routes to the adoption diagnostic'
    Assert-TestCondition ($adoptRun.Out -match 'env authority adopt <name> -DryRun') 'the adoption diagnostic keeps the explicit user-selected name placeholder'
    Assert-TestCondition ((Get-Task8HomeFingerprint) -eq $homeBefore) 'the adoption diagnostic performs zero home writes'
    $previewsAfterAdopt = @(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File)
    $diagnosticEvents = @($previewsAfterAdopt | Where-Object { $_.Name -like 'diagnostic-*' -and $_.Name -notlike '*.stale*' })
    Assert-TestCondition ($previewsAfterAdopt.Count -eq $previews.Count + 2 -and $diagnosticEvents.Count -eq 1) 'the adoption diagnostic adds exactly one diagnostic event plus one stale sidecar and materializes no environment'
    $adoptDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($diagnosticEvents[0].FullName)))
    Assert-TestCondition ([string] $adoptDocument.RedactedContext -match '\Aroute=adopt changed-count=\d+\z') 'the adoption diagnostic records no build or environment materialization'
    Assert-TestCondition ([string] $adoptDocument.PreviewStatus -ceq 'diagnostic-only' -and [string] $adoptDocument.EventKind -ceq 'diagnostic') 'the adoption route writes a diagnostic-only event'

    # A linked worktree reads the same selection and writes to its own
    # per-worktree pending namespace.
    $linkedContext = Get-RunnerStorageContext -RepoRoot $task8Linked -EnsureDirectories
    Assert-TestCondition ($linkedContext.WorktreePrivateRoot -ne $task8Context.WorktreePrivateRoot) 'the linked worktree uses its own pending namespace'
    $linkedRun = Invoke-Task8Runner -Repo $task8Linked -OldRev $secondCommit -NewRev $thirdCommit
    Assert-TestCondition ($linkedRun.Code -eq 76 -and $linkedRun.Out -match "routed this trigger to the 'adopt' diagnostic") 'the linked worktree reads the same shared-authority selection'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $linkedContext.PendingPreviewsRoot -File).Count -eq 1) 'the linked worktree writes its diagnostic into its own pending namespace'

    # An unfinished live journal under the shared home authority outranks every
    # other fact in the frozen decision order: the trigger must emit only the
    # recovery diagnostic (its pinned "live recover status" command) with no
    # environment materialization and no home write.
    $liveTransactionsRoot = Join-Path $task8Home 'AppData/Local/ai-agent-dotfiles/control/live-transactions'
    [System.IO.Directory]::CreateDirectory((Join-Path $liveTransactionsRoot '00000000000000000000000000000001')) | Out-Null
    $homeBefore = Get-Task8HomeFingerprint
    $previewsBeforeRecovery = @(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File).Count
    $recoveryRun = Invoke-Task8Runner -Repo $task8Repo -OldRev $secondCommit -NewRev $thirdCommit
    Assert-TestCondition ($recoveryRun.Code -eq 76 -and $recoveryRun.Out -match "routed this trigger to the 'recovery' diagnostic") 'an unfinished live journal routes to the recovery diagnostic before any other branch'
    Assert-TestCondition ($recoveryRun.Out -match 'live recover status') 'the recovery diagnostic prints the pinned recovery status command'
    $recoveryPreviews = @(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File | Where-Object { $_.Name -like 'diagnostic-*' -and $_.Name -notlike '*.stale*' } | Sort-Object Name)
    $recoveryDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([System.IO.File]::ReadAllBytes($recoveryPreviews[-1].FullName)))
    Assert-TestCondition ([string] $recoveryDocument.ExternalDryRunCommand -match 'live recover status' -and [string] $recoveryDocument.PreviewStatus -ceq 'diagnostic-only') 'the recovery diagnostic records the pinned command and stays non-consumable'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File).Count -eq $previewsBeforeRecovery + 1 -and (Get-Task8HomeFingerprint) -eq $homeBefore) 'the recovery diagnostic materializes nothing and performs zero home writes'

    # A stale approval over the extended bundle fails closed before any
    # routing: hooks never self-approve the new bundle. A checkout whose
    # toolchain bytes diverge from the approved commit is reported by the
    # pre-existing more precise "working-tree-review-required" token (exit 74);
    # a committed-but-unapproved toolchain reports "runner-review-required"
    # (exit 72). Both are the same fail-closed, zero-routing outcome.
    $toolchainFile = Join-Path $task8Repo 'scripts/auto-sync-after-git.ps1'
    $previewsBeforeDrift = @(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File).Count
    $homeBeforeDrift = Get-Task8HomeFingerprint
    [System.IO.File]::AppendAllText($toolchainFile, "`n# drift`n", [System.Text.UTF8Encoding]::new($false))
    $driftRun = Invoke-Task8Runner -Repo $task8Repo -OldRev $secondCommit -NewRev $thirdCommit
    Assert-TestCondition ($driftRun.Code -in @(72, 74) -and $driftRun.Out -match 'runner-review-required|working-tree-review-required') 'toolchain drift over the extended bundle fails closed before any routing'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $task8Context.PendingPreviewsRoot -File).Count -eq $previewsBeforeDrift -and (Get-Task8HomeFingerprint) -eq $homeBeforeDrift) 'the drifting checkout writes no preview and no home state'

    $env:AI_AGENT_DOTFILES_AUTHORITY_IDENTITY = $null
    Remove-Item -LiteralPath $task8Repo, $task8Linked, $task8BadRepo, $task8Home, $task8External -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host 'automation safety tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
