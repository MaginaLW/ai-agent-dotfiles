#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-arb-$([Guid]::NewGuid().ToString('N'))"
$repo = Join-Path $work 'repo'
$linked = Join-Path $work 'linked'
$approvalRepo = Join-Path $work 'approval-repo'
$missingValidatorRepo = Join-Path $work 'missing-validator-repo'
$missingScannerRepo = Join-Path $work 'missing-scanner-repo'
$cacheRepo = Join-Path $work 'cache-repo'
$dirtyRepo = Join-Path $work 'dirty-repo'
$external = Join-Path $work 'external'
New-Item -ItemType Directory -Path $repo, $approvalRepo, $missingValidatorRepo, $missingScannerRepo, $cacheRepo, $dirtyRepo, $external | Out-Null

function Initialize-PolicyFixtureRepo {
    param([Parameter(Mandatory)] [string] $Path)
    & git -C $Path init -q
    & git -C $Path config user.email 'tests@example.invalid'
    & git -C $Path config user.name 'Approval Tests'
    & git -C $Path config core.autocrlf false
    $fixturePolicy = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'scripts/runner-policy.psd1')
    foreach ($relative in @($fixturePolicy.ToolchainPaths | Sort-Object -Unique)) {
        $source = Join-Path $RepoRoot $relative
        $destination = Join-Path $Path $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [System.IO.File]::Copy($source, $destination, $false)
    }
    return $fixturePolicy
}

function Set-ApprovedFixtureCurrentUserOnlyAcl {
    param([Parameter(Mandatory)][string]$Path)
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$sid=[System.Security.Principal.SecurityIdentifier]::new([string]$template.OwnerSid)
    $security=[System.Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($sid);$security.SetAccessRuleProtection($true,$false)
    $inherit=[System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($sid,[System.Security.AccessControl.FileSystemRights]::FullControl,$inherit,[System.Security.AccessControl.PropagationFlags]::None,[System.Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Initialize-CanonicalReadyFixture {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Name)
    $git=Get-CanonicalGitContext -RepoRoot $Path
    $slot=Join-Path $work ("canonical-ready-$Name")
    $recovery=Join-Path $slot 'recovery';$control=Join-Path $slot 'control';$backup=Join-Path $slot 'backups';$probe=Join-Path $slot 'probe'
    foreach($directory in @($recovery,$control,$backup,$probe)){[System.IO.Directory]::CreateDirectory($directory)|Out-Null}
    foreach($directory in @($recovery,$control,$backup)){Set-ApprovedFixtureCurrentUserOnlyAcl -Path $directory}
    [System.IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots'))|Out-Null
    $payload=New-CanonicalSetupPlanPayload -RepoRoot $Path -CanonicalRecoveryRoot $recovery -ControlBase $control -BackupRoot $backup -ProbeRoot $probe -ToolchainRoot $RepoRoot
    $finalState=New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $Path
    $paths=Get-CanonicalTransactionContractPaths -GitContext $git
    $lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate
    Exit-CanonicalRepoLock -LockHandle $lock
    [System.IO.File]::WriteAllBytes($paths.SetupStatePath,(ConvertTo-SemanticJsonBytes -InputObject $finalState))
    $claimPath=Join-Path $control (Join-Path 'canonical-roots' ($payload.ExpectedSetupStateProjection.RepoId+'.json'))
    [System.IO.File]::WriteAllBytes($claimPath,(ConvertTo-SemanticJsonBytes -InputObject $payload.ExpectedRootClaim))
    if((Get-CanonicalSetupStatus -RepoRoot $Path -ToolchainRoot $RepoRoot) -cne 'canonical-ready'){throw 'Unable to establish isolated canonical-ready fixture.'}
}

try {
    & git -C $repo init -q
    & git -C $repo config user.email 'tests@example.invalid'
    & git -C $repo config user.name 'Approval Tests'
    [System.IO.File]::WriteAllText((Join-Path $repo 'README.md'), "fixture`n", [System.Text.UTF8Encoding]::new($false))
    & git -C $repo add -- README.md
    & git -C $repo commit -qm 'fixture'
    & git -C $repo worktree add -q -b linked-fixture $linked
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create linked-worktree fixture.' }

    . (Join-Path $RepoRoot 'scripts/approved-runner-common.ps1')
    . (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')

    $primary = Get-RunnerStorageContext -RepoRoot $repo -EnsureDirectories
    $secondary = Get-RunnerStorageContext -RepoRoot $linked -EnsureDirectories
    Assert-TestCondition ($primary.GitCommonDir -eq $secondary.GitCommonDir) 'linked worktrees resolve the same Git common directory'
    Assert-TestCondition ($primary.PendingLockPath -eq $secondary.PendingLockPath) 'linked worktrees share one common pending lock'
    Assert-TestCondition ($primary.WorktreePrivateRoot -ne $secondary.WorktreePrivateRoot) 'linked worktrees use distinct pending namespaces'
    Assert-TestCondition ($primary.WorktreePrivateRoot.StartsWith($primary.GitDir, [StringComparison]::OrdinalIgnoreCase)) 'pending storage is confined to the current Git-private directory'
    $broadAclRoot = Join-Path $work 'broad-acl'; [System.IO.Directory]::CreateDirectory($broadAclRoot) | Out-Null
    $broadAcl = Get-Acl -LiteralPath $broadAclRoot
    $everyone = [System.Security.Principal.SecurityIdentifier]::new('S-1-1-0')
    $broadAcl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new($everyone,[System.Security.AccessControl.FileSystemRights]::FullControl,[System.Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $broadAclRoot -AclObject $broadAcl
    $aclRejected = $false
    try { Assert-PrivateRunnerAcl -Path $broadAclRoot } catch { $aclRejected = $true }
    Assert-TestCondition $aclRejected 'runner storage rejects an explicit broad-write ACL'

    $event = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'pending-sync-event'
        EventKind = 'preview'
        WorktreeNamespace = $primary.WorktreeId
        Trigger = 'test'
        ApprovedToolchainHash = ('a' * 64)
        CurrentToolchainHash = ('a' * 64)
        Commit = ('b' * 40)
        ContextHash = ('c' * 64)
        PreviewStatus = 'non-consumable'
        RedactedContext = 'fixture'
        ContentHashes = @()
        ExternalDryRunCommand = 'pwsh -NoProfile -File scripts/sync.ps1 -DryRun -PlanPath <external>'
    }
    $stamp = [DateTimeOffset]::Parse('2026-08-11T00:00:00.123Z')
    $first = Write-ImmutableRunnerArtifact -Directory $primary.PendingEventsRoot -Prefix 'preview' -Document $event -TimestampUtc $stamp -ArtifactId '11111111111111111111111111111111'
    $second = Write-ImmutableRunnerArtifact -Directory $primary.PendingEventsRoot -Prefix 'preview' -Document $event -TimestampUtc $stamp -ArtifactId '22222222222222222222222222222222'
    Assert-TestCondition ($first -ne $second -and (Test-Path -LiteralPath $first) -and (Test-Path -LiteralPath $second)) 'same-millisecond events use collision-resistant create-new names'
    $listed = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1') -Arguments @('plans','list','-RepoRoot',$repo)
    Assert-TestCondition ($listed.Code -eq 0 -and $listed.Out -match [regex]::Escape([IO.Path]::GetFileName($first))) 'unified CLI lists Git-private pending artifacts without making them actionable'
    $collision = $null
    try { Write-ImmutableRunnerArtifact -Directory $primary.PendingEventsRoot -Prefix 'preview' -Document $event -TimestampUtc $stamp -ArtifactId '11111111111111111111111111111111' | Out-Null }
    catch { $collision = $_.Exception.Message }
    Assert-TestCondition ($collision -match 'already exists|collision') 'existing immutable target is rejected instead of overwritten'

    $planPath = Join-Path $external 'prune-plan.json'
    $retired = Join-Path $primary.WorktreePrivateRoot 'retired'
    New-PendingPrunePlan -RepoRoot $repo -ArtifactPaths @($first) -PlanPath $planPath | Out-Null
    $planBefore = [System.IO.File]::ReadAllBytes($planPath)
    $newCandidate = Write-ImmutableRunnerArtifact -Directory $primary.PendingEventsRoot -Prefix 'preview' -Document $event
    Invoke-PendingPrunePlan -RepoRoot $repo -PlanPath $planPath | Out-Null
    Assert-TestCondition (-not (Test-Path -LiteralPath $first)) 'reviewed prune moves the exact selected artifact'
    Assert-TestCondition (Test-Path -LiteralPath $newCandidate) 'reviewed prune does not expand selection to a later candidate'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $retired -File).Count -ge 1) 'reviewed prune retains retired audit material'
    Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual($planBefore, [System.IO.File]::ReadAllBytes($planPath))) 'prune Apply does not rewrite the external reviewed plan'

    $internalRoleRejected = $null
    try { New-PendingPrunePlan -RepoRoot $repo -ArtifactPaths @($second) -PlanPath (Join-Path $primary.WorktreePrivateRoot 'bad-plan.json') | Out-Null }
    catch { $internalRoleRejected = $_.Exception.Message }
    Assert-TestCondition ($internalRoleRejected -match 'External user artifact|disjoint') 'public prune plan rejects Git-private PlanPath role confusion'

    $policy = Initialize-PolicyFixtureRepo -Path $approvalRepo
    & git -C $approvalRepo add -- @($policy.ToolchainPaths)
    & git -C $approvalRepo commit -qm 'approved toolchain fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Failed to commit approval fixture.' }

    $firstBootstrap = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1') -Arguments @('-RepoRoot',$approvalRepo)
    Assert-TestCondition ($firstBootstrap.Code -eq 72 -and $firstBootstrap.Out -match 'runner-review-required') 'clean unapproved bootstrap stops at explicit runner review'
    Assert-TestCondition ($firstBootstrap.Out -match 'setup\.ps1.*-ApproveRunner.*-InstallAutoSync') 'runner review prints the exact approval command'
    $approvalContext = Get-RunnerStorageContext -RepoRoot $approvalRepo
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $approvalContext.PendingEventsRoot -File).Count -eq 1) 'runner review writes one validated diagnostic event'

    $setupResult = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/setup.ps1') -Arguments @('-RepoRoot',$approvalRepo,'-ApproveRunner','-InstallAutoSync')
    Assert-TestCondition ($setupResult.Code -eq 0) 'explicit approval materializes and records the pinned runner'
    $approvedContext = Get-RunnerStorageContext -RepoRoot $approvalRepo
    Assert-TestCondition (Test-Path -LiteralPath $approvedContext.ApprovedStatePath -PathType Leaf) 'approval publishes one Git-private approved state'
    $approvedState = Get-ApprovedRunnerState -RepoRoot $approvalRepo
    Assert-TestCondition (Test-PathInsideRoot -Path ([string]$approvedState.RunnerEntryPath) -Root $approvedContext.ApprovedRunnersRoot) 'approved entry executes from a versioned Git-private runner'
    $mismatchedState = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($approvedContext.ApprovedStatePath, [System.Text.UTF8Encoding]::new($false, $true)))
    $mismatchedState.PointerGeneration = [long]$mismatchedState.PointerGeneration + 1
    Write-AtomicRunnerState -StorageContext $approvedContext -Document $mismatchedState
    $pointerMismatchRejected = $false
    try { Get-ApprovedRunnerState -RepoRoot $approvalRepo | Out-Null } catch { $pointerMismatchRejected = $_.Exception.Message -match 'event/state mismatch' }
    Assert-TestCondition $pointerMismatchRejected 'approval state rejects pointer/event mismatch'
    Write-AtomicRunnerState -StorageContext $approvedContext -Document $approvedState
    $postMergeHook = Join-Path ((& git -C $approvalRepo rev-parse --path-format=absolute --git-path hooks).Trim()) 'post-merge'
    Assert-TestCondition ((Get-Content -LiteralPath $postMergeHook -Raw) -notmatch 'scripts/auto-sync-after-git\.ps1') 'installed hook never invokes checkout runner code'
    foreach ($hookName in @('post-checkout','post-rewrite')) {
        $hookPath = Join-Path (Split-Path -Parent $postMergeHook) $hookName
        Assert-TestCondition ((Get-Content -LiteralPath $hookPath -Raw) -notmatch 'scripts/auto-sync-after-git\.ps1') "$hookName also invokes only the Git-private approved entry"
    }
    $pendingBeforeBootstrap = @(Get-ChildItem -LiteralPath $approvedContext.PendingEventsRoot -File).Count
    $approvedBootstrap = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1') -Arguments @('-RepoRoot',$approvalRepo)
    Assert-TestCondition ($approvedBootstrap.Code -eq 76 -and $approvedBootstrap.Out -match 'canonical-setup-required' -and $approvedBootstrap.Out -match 'canonical setup.*-DryRun.*-PlanPath') 'approved bootstrap invokes canonical status and prints only the external setup DryRun route when setup is missing'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $approvedContext.PendingEventsRoot -File).Count -eq $pendingBeforeBootstrap) 'setup-required bootstrap creates no initial, build, or preview event'
    Initialize-CanonicalReadyFixture -Path $approvalRepo -Name 'approval'
    $readyManual=Invoke-TestProcess -ScriptPath $approvedContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$approvalRepo,'-Trigger','manual')
    Assert-TestCondition ($readyManual.Code -eq 73 -and $readyManual.Out -match 'safety-protocol-upgrade-required') 'canonical-ready approved manual route remains Phase 1 production-interlocked'

    $marker = Join-Path $work 'checkout-runner-marker.txt'
    [System.IO.File]::AppendAllText((Join-Path $approvalRepo 'scripts/auto-sync-after-git.ps1'), "`n[System.IO.File]::WriteAllText('$($marker.Replace("'","''"))','unsafe')`n", [System.Text.UTF8Encoding]::new($false))
    $drift = Invoke-TestProcess -ScriptPath $approvedContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$approvalRepo,'-Trigger','post-merge')
    Assert-TestCondition ($drift.Code -ne 0 -and $drift.Out -match 'runner-review-required|working-tree-review-required') 'toolchain drift fails closed through the approved entry'
    Assert-TestCondition (-not (Test-Path -LiteralPath $marker)) 'changed checkout runner code is never executed'
    & git -C $approvalRepo restore --worktree -- scripts/auto-sync-after-git.ps1

    $oldCommit = ((& git -C $approvalRepo rev-parse HEAD) | Select-Object -First 1).Trim()
    $dataFile = Join-Path $approvalRepo 'skills-source/shared/fixture/SKILL.md'
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dataFile)) | Out-Null
    [System.IO.File]::WriteAllText($dataFile, "---`nname: fixture`ndescription: fixture`n---`n", [System.Text.UTF8Encoding]::new($false))
    & git -C $approvalRepo add -- skills-source/shared/fixture/SKILL.md
    & git -C $approvalRepo commit -qm 'data-only change'
    $newCommit = ((& git -C $approvalRepo rev-parse HEAD) | Select-Object -First 1).Trim()
    $preview = Invoke-TestProcess -ScriptPath $approvedContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$approvalRepo,'-Trigger','post-checkout','-OldRev',$oldCommit,'-NewRev',$newCommit,'-CheckoutFlag','1')
    Assert-TestCondition ($preview.Code -eq 0 -and $preview.Out -match 'pending-preview-only') 'data-only change creates a non-consumable preview event'
    Assert-TestCondition ($preview.Out -match 'External actionable plan requires an explicit command') 'preview prints an explicit external DryRun command'
    Assert-TestCondition (@(Get-ChildItem -LiteralPath $approvedContext.PendingEventsRoot -File).Count -eq ($pendingBeforeBootstrap + 1)) 'source-only hook writes one immutable pending event'
    $previewRepeat = Invoke-TestProcess -ScriptPath $approvedContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$approvalRepo,'-Trigger','post-checkout','-OldRev',$oldCommit,'-NewRev',$newCommit,'-CheckoutFlag','1')
    Assert-TestCondition ($previewRepeat.Code -eq 0 -and @(Get-ChildItem -LiteralPath $approvedContext.PendingEventsRoot -File).Count -eq ($pendingBeforeBootstrap + 1)) 'identical preview context is deduplicated without rewriting the original event'
    $snapshotRoot = Join-Path $external 'data-snapshot'
    $snapshotManifestPath = Join-Path $external 'data-snapshot-manifest.json'
    $snapshotManifest = New-CommittedDataSnapshot -RepoRoot $approvalRepo -DestinationRoot $snapshotRoot -ManifestPath $snapshotManifestPath
    Assert-TestCondition ($snapshotManifest.Files.Count -eq 1 -and $snapshotManifest.Files[0].RelativePath -eq 'skills-source/shared/fixture/SKILL.md') 'committed-data snapshot contains only the explicit policy allowlist content'
    Assert-TestCondition (@($snapshotManifest.Files | Where-Object { $_.RelativePath -like '.reasonix/*' }).Count -eq 0) 'committed-data snapshot never includes protected Reasonix state'
    Assert-TestCondition (Test-Path -LiteralPath $snapshotManifestPath -PathType Leaf) 'committed-data snapshot publishes a validated external manifest'

    $cachePolicy = Initialize-PolicyFixtureRepo -Path $cacheRepo
    & git -C $cacheRepo add -- @($cachePolicy.ToolchainPaths)
    & git -C $cacheRepo commit -qm 'custom cache fixture'
    $customCache = Join-Path $work 'tool-cache'
    Copy-Item -LiteralPath (Get-PinnedToolCacheRoot) -Destination $customCache -Recurse
    $cacheState = Approve-RunnerSnapshot -RepoRoot $cacheRepo -ToolCacheRoot $customCache
    $cacheContext = Get-RunnerStorageContext -RepoRoot $cacheRepo
    Publish-ApprovedHookEntry -RepoRoot $cacheRepo -State $cacheState | Out-Null
    Initialize-CanonicalReadyFixture -Path $cacheRepo -Name 'cache'
    $cacheCommit = ((& git -C $cacheRepo rev-parse HEAD) | Select-Object -First 1).Trim()
    $shadowRoot = Join-Path $work 'path-shadow'; [System.IO.Directory]::CreateDirectory($shadowRoot) | Out-Null
    $shadowMarker = Join-Path $work 'path-shadow-marker.txt'
    [System.IO.File]::WriteAllText((Join-Path $shadowRoot 'gitleaks.cmd'), "@echo off`r`necho shadow>`"$shadowMarker`"`r`nexit /b 0`r`n", [System.Text.ASCIIEncoding]::new())
    $oldPath = $env:PATH
    try {
        $env:PATH = "$shadowRoot;$oldPath"
        $shadow = Invoke-TestProcess -ScriptPath $cacheContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$cacheRepo,'-Trigger','post-checkout','-OldRev',$cacheCommit,'-NewRev',$cacheCommit,'-CheckoutFlag','1')
    }
    finally { $env:PATH = $oldPath }
    Assert-TestCondition ($shadow.Code -eq 0 -and -not (Test-Path -LiteralPath $shadowMarker)) 'approved runner ignores a PATH-shadow scanner'

    $scannerLock = Get-PinnedToolLock -Path (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
    $scannerPaths = Get-PinnedToolPaths -Lock $scannerLock -CacheRoot $customCache
    $missingExe = "$($scannerPaths.Executable).missing"
    [System.IO.File]::Move($scannerPaths.Executable, $missingExe)
    try { $hookMissingScanner = Invoke-TestProcess -ScriptPath $cacheContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$cacheRepo,'-Trigger','post-checkout','-OldRev',$cacheCommit,'-NewRev',$cacheCommit,'-CheckoutFlag','1') }
    finally { [System.IO.File]::Move($missingExe, $scannerPaths.Executable) }
    Assert-TestCondition ($hookMissingScanner.Code -eq 71 -and $hookMissingScanner.Out -match 'scanner-install-required') 'hook emits only scanner-install-required when its approved cache is missing'
    $scannerBackup = Join-Path $work 'gitleaks-backup.exe'; [System.IO.File]::Copy($scannerPaths.Executable, $scannerBackup)
    try {
        [System.IO.File]::WriteAllText($scannerPaths.Executable, 'tampered', [System.Text.ASCIIEncoding]::new())
        $hookTamperedScanner = Invoke-TestProcess -ScriptPath $cacheContext.ApprovedHookEntryPath -Arguments @('-RepoRoot',$cacheRepo,'-Trigger','post-checkout','-OldRev',$cacheCommit,'-NewRev',$cacheCommit,'-CheckoutFlag','1')
    }
    finally { [System.IO.File]::Copy($scannerBackup, $scannerPaths.Executable, $true) }
    Assert-TestCondition ($hookTamperedScanner.Code -eq 71 -and $hookTamperedScanner.Out -match 'scanner-install-required') 'hook emits only scanner-install-required when its approved cache is tampered'

    $missingPolicy = Initialize-PolicyFixtureRepo -Path $missingValidatorRepo
    $validatorLockPath = Join-Path $missingValidatorRepo 'tools/schema-validator/validator.lock.json'
    $validatorLock = Get-Content -LiteralPath $validatorLockPath -Raw | ConvertFrom-Json
    $validatorLock.Version = '99.0.0-missing'
    [System.IO.File]::WriteAllText($validatorLockPath, ($validatorLock | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    & git -C $missingValidatorRepo add -- @($missingPolicy.ToolchainPaths)
    & git -C $missingValidatorRepo commit -qm 'missing validator fixture'
    $missingValidator = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1') -Arguments @('-RepoRoot',$missingValidatorRepo)
    Assert-TestCondition ($missingValidator.Code -eq 70 -and $missingValidator.Out -match 'validator-install-required' -and $missingValidator.Out -match 'install-schema-validator\.ps1') 'bootstrap reports missing validator before any runner artifact'
    $missingValidatorContext = Get-RunnerStorageContext -RepoRoot $missingValidatorRepo
    Assert-TestCondition (-not (Test-Path -LiteralPath $missingValidatorContext.PendingEventsRoot)) 'validator-missing bootstrap writes no pending JSON artifact'

    $missingScannerPolicy = Initialize-PolicyFixtureRepo -Path $missingScannerRepo
    $scannerLockPath = Join-Path $missingScannerRepo 'tools/gitleaks/gitleaks.lock.json'
    $scannerLock = Get-Content -LiteralPath $scannerLockPath -Raw | ConvertFrom-Json
    $scannerLock.Version = '99.0.0-missing'
    [System.IO.File]::WriteAllText($scannerLockPath, ($scannerLock | ConvertTo-Json -Depth 10), [System.Text.UTF8Encoding]::new($false))
    & git -C $missingScannerRepo add -- @($missingScannerPolicy.ToolchainPaths)
    & git -C $missingScannerRepo commit -qm 'missing scanner fixture'
    $missingScanner = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1') -Arguments @('-RepoRoot',$missingScannerRepo)
    Assert-TestCondition ($missingScanner.Code -eq 71 -and $missingScanner.Out -match 'scanner-install-required' -and $missingScanner.Out -match 'install-gitleaks\.ps1') 'bootstrap checks scanner after the validator and emits its exact install command'
    $missingScannerContext = Get-RunnerStorageContext -RepoRoot $missingScannerRepo
    Assert-TestCondition (-not (Test-Path -LiteralPath $missingScannerContext.PendingEventsRoot)) 'scanner-missing bootstrap writes no pending JSON artifact'

    $dirtyPolicy = Initialize-PolicyFixtureRepo -Path $dirtyRepo
    & git -C $dirtyRepo add -- @($dirtyPolicy.ToolchainPaths)
    & git -C $dirtyRepo commit -qm 'dirty data fixture'
    $dirtyData = Join-Path $dirtyRepo 'skills-source/shared/unreviewed/SKILL.md'; [System.IO.Directory]::CreateDirectory((Split-Path -Parent $dirtyData)) | Out-Null
    [System.IO.File]::WriteAllText($dirtyData, "unreviewed`n", [System.Text.UTF8Encoding]::new($false))
    $dirtyBootstrap = Invoke-TestProcess -ScriptPath (Join-Path $RepoRoot 'scripts/bootstrap-clone.ps1') -Arguments @('-RepoRoot',$dirtyRepo)
    Assert-TestCondition ($dirtyBootstrap.Code -eq 74 -and $dirtyBootstrap.Out -match 'working-tree-review-required') 'bootstrap refuses relevant untracked data instead of planning another commit'
    $dirtyContext = Get-RunnerStorageContext -RepoRoot $dirtyRepo
    Assert-TestCondition (-not (Test-Path -LiteralPath $dirtyContext.PendingEventsRoot) -or @(Get-ChildItem -LiteralPath $dirtyContext.PendingEventsRoot -File).Count -eq 0) 'dirty bootstrap writes no review or preview artifact'

    $summary = Join-Path $external 'artifact-summary.json'
    & pwsh -NoProfile -File (Join-Path $RepoRoot 'scripts/validate-json-artifacts.ps1') -All -JsonSummaryPath $summary | Out-Host
    Assert-TestCondition ($LASTEXITCODE -eq 0) 'approval and pending contracts are registered and validate'

    Write-Host 'approved-runner tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $repo) { & git -C $repo worktree remove --force $linked 2>$null | Out-Null }
    if ($env:AI_AGENT_DOTFILES_KEEP_APPROVAL_FIXTURE -eq '1') { Write-Host "Kept fixture: $work" }
    elseif (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
