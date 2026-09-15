#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('manual', 'pre-commit', 'post-merge', 'post-checkout', 'post-rewrite')]
    [string] $Trigger = 'manual',
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $OldRev,
    [string] $NewRev,
    [string] $CheckoutFlag,
    [string] $RewriteCommand,
    [string] $RevisionFile,
    [switch] $Force,
    # Test seam only: a sealed fake-home identity document (the production hook
    # never passes it). It only redirects the read-only shared-authority
    # selection queries; every preview/materialization stays Git-private and
    # non-consumable either way.
    [string] $AuthorityIdentityPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'approved-runner-common.ps1')

function Exit-Diagnostic {
    param([Parameter(Mandatory)] [string] $Token, [Parameter(Mandatory)] [string] $Detail, [int] $Code = 72)
    [Console]::Error.WriteLine("${Token}: $Detail")
    exit $Code
}

function Get-CanonicalAutomationStatusDetail {
    param([Parameter(Mandatory)][string]$Status, [Parameter(Mandatory)][string]$ExecutingRoot)
    if ($Status -ceq 'canonical-setup-required') {
        return "external canonical setup DryRun: pwsh -NoProfile -File `"$((Join-Path $ExecutingRoot 'scripts/agent-dotfiles.ps1'))`" canonical setup -RepoRoot `"$RepoRoot`" -DryRun -PlanPath <external-user-artifact>"
    }
    return 'canonical setup/recovery status is diagnostic-only; approved automation did not build or create a preview.'
}

function Assert-CanonicalAutomationReady {
    param([Parameter(Mandatory)][string]$ExecutingRoot)
    . (Join-Path $ExecutingRoot 'scripts/canonical-transaction-common.ps1')
    $status=Get-CanonicalSetupStatus -RepoRoot $RepoRoot -ToolchainRoot $ExecutingRoot
    if($status -ceq 'canonical-ready'){return}
    Write-Host (Get-CanonicalAutomationStatusDetail -Status $status -ExecutingRoot $ExecutingRoot)
    Exit-Diagnostic -Token $status -Detail 'canonical setup/recovery status is diagnostic-only; approved automation did not build or create a preview.' -Code 76
}

function Get-RelevantChanges {
    param([Parameter(Mandatory)] $Policy)
    $pathspecs = @($Policy.DataPathspecs) + @($Policy.ToolchainPaths)
    $from = $null; $to = $null
    switch ($Trigger) {
        'post-checkout' { if ($CheckoutFlag -ne '1') { return @() }; $from=$OldRev; $to=$NewRev }
        'post-merge' {
            $from = ((& git -C $RepoRoot rev-parse --verify ORIG_HEAD 2>$null) | Select-Object -First 1)
            $to = ((& git -C $RepoRoot rev-parse --verify HEAD 2>$null) | Select-Object -First 1)
        }
        'post-rewrite' {
            if (-not $RevisionFile -or -not (Test-Path -LiteralPath $RevisionFile -PathType Leaf)) { return @('__defensive__') }
            $all = [System.Collections.Generic.List[string]]::new()
            foreach ($line in [System.IO.File]::ReadLines($RevisionFile)) {
                $parts = @($line -split '\s+' | Where-Object { $_ })
                if ($parts.Count -lt 2) { continue }
                $all.AddRange([string[]]@(& git -C $RepoRoot diff --name-only $parts[0] $parts[1] -- @pathspecs))
            }
            return @($all | Where-Object { $_ } | Sort-Object -Unique)
        }
        default { return @('__manual__') }
    }
    if ([string]::IsNullOrWhiteSpace([string]$from) -or [string]::IsNullOrWhiteSpace([string]$to)) { return @('__defensive__') }
    return @(& git -C $RepoRoot diff --name-only ([string]$from).Trim() ([string]$to).Trim() -- @pathspecs | Where-Object { $_ } | Sort-Object -Unique)
}

function Get-RunnerAuthorityIdentity {
    <#
        Resolves the read-only shared-authority selection identity. Production
        hooks run with the current Windows identity; tests may inject the sealed
        fake-home identity through -AuthorityIdentityPath or the
        AI_AGENT_DOTFILES_AUTHORITY_IDENTITY environment variable. The override
        never changes where previews are written or whether anything is applied.
    #>
    param([string] $IdentityPath)
    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        $IdentityPath = [string] $env:AI_AGENT_DOTFILES_AUTHORITY_IDENTITY
    }
    if ([string]::IsNullOrWhiteSpace($IdentityPath)) { return $null }
    if (-not (Test-Path -LiteralPath $IdentityPath -PathType Leaf)) {
        throw 'runner-review-required: the authority identity override file is missing.'
    }
    $identity = [System.IO.File]::ReadAllText($IdentityPath, [System.Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    $expected = @('ResolverVersion', 'TokenSid', 'ProfileRoot', 'RoamingAppDataRoot', 'LocalAppDataRoot')
    if ($null -eq $identity -or @(Compare-Object $expected @($identity.PSObject.Properties.Name)).Count -ne 0 -or
        [string] $identity.ResolverVersion -cne 'sealed-home-authority-test-adapter-v1') {
        throw 'runner-review-required: the authority identity override document is not the sealed test adapter.'
    }
    return $identity
}

function Get-RunnerExternalDryRunCommand {
    <#
        Renders the pinned route command as an external, user-runnable command.
        The route command is the frozen authority next operation (with the
        selected <name> substituted); a DryRun operation without a plan
        placeholder gains the explicit external PlanPath placeholder, and the
        repository root is appended last so the operation text stays verbatim.
    #>
    param([Parameter(Mandatory)] [string] $ExecutingRoot, [Parameter(Mandatory)] [string] $RouteCommand, [string] $Name)
    $agentDotfiles = Join-Path $ExecutingRoot 'scripts/agent-dotfiles.ps1'
    $command = [string] $RouteCommand
    if ($command.Contains('<name>')) {
        if ([string]::IsNullOrWhiteSpace($Name)) { $Name = '<name>' }
        $command = $command.Replace('<name>', $Name)
    }
    if ($command.TrimEnd().EndsWith('-DryRun', [System.StringComparison]::Ordinal)) {
        $command = "$command -PlanPath <external-user-artifact>"
    }
    return "pwsh -NoProfile -File `"$agentDotfiles`" $command -RepoRoot `"$RepoRoot`""
}

function Write-RunnerPreviewArtifacts {
    <#
        Marks prior pending previews/events stale via sidecars after context
        drift (immutable originals stay untouched; a stale sidecar is a
        validated pending-sync-event with EventKind=stale bound to the drifted
        document's own ContextHash), then writes one validated
        non-consumable pending-sync-event into the Git-private per-worktree
        preview namespace.
    #>
    param(
        [Parameter(Mandatory)] $StorageContext,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $CurrentCommit,
        [Parameter(Mandatory)] [string] $CurrentContextHash
    )
    return Invoke-WithPendingLock -StorageContext $StorageContext -Action {
        $staleContextHashes = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $registrations = [System.Collections.Generic.List[object]]::new()
        foreach ($root in @($StorageContext.PendingEventsRoot, $StorageContext.PendingPreviewsRoot)) {
            if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
            foreach ($file in @(Get-ChildItem -LiteralPath $root -File | Sort-Object FullName)) {
                try {
                    $validation = Assert-RunnerArtifactValid -Path $file.FullName -ArtifactKind 'pending-sync-event'
                    $existing = (Assert-ExactJsonArtifactCapture -Capture $validation.ArtifactCapture).Document
                }
                catch { throw "Pending namespace contains an invalid registered event: $($file.FullName)" }
                $registrations.Add([pscustomobject]@{ Path = $file.FullName; Document = $existing }) | Out-Null
                if ([string] (Get-HarnessJsonProperty -Object $existing -Name 'EventKind') -ceq 'stale') {
                    [void] $staleContextHashes.Add([string] (Get-HarnessJsonProperty -Object $existing -Name 'ContextHash'))
                }
            }
        }
        foreach ($registration in $registrations) {
            $existing = $registration.Document
            $existingEventKind = [string] (Get-HarnessJsonProperty -Object $existing -Name 'EventKind')
            $existingContextHash = [string] (Get-HarnessJsonProperty -Object $existing -Name 'ContextHash')
            # Only a prior *preview* is a pending actionable artifact that drifts
            # out of date; a diagnostic event is a historical record and is never
            # retired by a later trigger.
            if ($existingEventKind -cne 'preview') { continue }
            $drifted = [string] (Get-HarnessJsonProperty -Object $existing -Name 'Commit') -cne $CurrentCommit -or $existingContextHash -cne $CurrentContextHash
            if ($drifted -and -not $staleContextHashes.Contains($existingContextHash)) {
                # The sidecar is a full copy of the drifted document with only its
                # lifecycle fields rewritten: the immutable original keeps every
                # byte, and the sidecar binds the same ContextHash it retires.
                $sidecar = [ordered]@{}
                $source = ConvertTo-HarnessEnvDocumentTable -Document $existing
                foreach ($key in @($source.Keys)) { $sidecar[[string] $key] = $source[$key] }
                $sidecar['EventKind'] = 'stale'
                $sidecar['PreviewStatus'] = 'retired'
                Write-ImmutableRunnerArtifact -Directory (Split-Path -Parent $registration.Path) -Prefix "$([System.IO.Path]::GetFileNameWithoutExtension($registration.Path)).stale" -Document $sidecar | Out-Null
            }
        }
        foreach ($registration in $registrations) {
            $existing = $registration.Document
            if ([string] (Get-HarnessJsonProperty -Object $existing -Name 'EventKind') -ceq [string] (Get-HarnessJsonProperty -Object $Document -Name 'EventKind') -and
                [string] (Get-HarnessJsonProperty -Object $existing -Name 'ContextHash') -ceq [string] (Get-HarnessJsonProperty -Object $Document -Name 'ContextHash') -and
                [string] (Get-HarnessJsonProperty -Object $existing -Name 'PreviewStatus') -ceq [string] (Get-HarnessJsonProperty -Object $Document -Name 'PreviewStatus')) {
                return [string] $registration.Path
            }
        }
        return Write-ImmutableRunnerArtifact -Directory $StorageContext.PendingPreviewsRoot -Prefix ([string] $Document.EventKind) -Document $Document
    }
}

function Assert-RunnerMaterializedBuild {
    <#
        The only build-consuming verification: the staged tree must carry a
        schema-3 lock and a schema-3 env-build sidecar whose MaterializationHash
        recomputes exactly (v2/missing/drift refuse the preview). Uses the same
        production readers as activation, so no preview-only check can drift.
    #>
    param([Parameter(Mandatory)] [string] $StagingPath)
    $lock = Read-HarnessEnvLock -StagingPath $StagingPath
    $build = Read-HarnessEnvBuild -StagingPath $StagingPath
    return [pscustomobject][ordered]@{ Lock = $lock; Build = $build }
}

function Invoke-RunnerEnvironmentPreview {
    param(
        [Parameter(Mandatory)] [string] $ExecutingRoot,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $RouteAction,
        [Parameter(Mandatory)] [string] $EnvironmentName,
        [Parameter(Mandatory)] [string] $Trigger,
        [Parameter(Mandatory)] [string] $Head,
        [Parameter(Mandatory)] [string[]] $Changed,
        [Parameter(Mandatory)] [string] $ApprovedToolchainHash,
        [Parameter(Mandatory)] [string] $CurrentToolchainHash
    )
    if ($EnvironmentName -cnotmatch '\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z') {
        throw "runner-review-required: routed environment name is not a bare identifier: $EnvironmentName"
    }
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-runner-preview-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        # The build inputs are the committed data snapshot at the approved
        # commit, never clone-local working tree or clone-local state.
        $snapshotRoot = Join-Path $scratch 'data'
        $snapshotManifestPath = Join-Path $scratch 'data-snapshot-manifest.json'
        $snapshot = New-CommittedDataSnapshot -RepoRoot $RepoRoot -DestinationRoot $snapshotRoot -ManifestPath $snapshotManifestPath -Commit $Head
        # The pinned build runs in its plain (non-preflight) shape: every output
        # or cache override is internal to -CanonicalPreflight, and the plain
        # build already writes only inside the Git-private scratch snapshot.
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $ExecutingRoot 'scripts/build-skills.ps1') -RepoRoot $snapshotRoot
        if ($LASTEXITCODE -ne 0) { throw 'runner-review-required: the pinned build refused the committed data snapshot.' }
        $stagingRoot = Join-Path (Join-Path $scratch 'envs') $EnvironmentName
        Invoke-HarnessEnvMaterialization -RepoRoot $snapshotRoot -Name $EnvironmentName -Destination $stagingRoot | Out-Null
        $materialized = Assert-RunnerMaterializedBuild -StagingPath $stagingRoot

        $lockHash = Get-LowerSha256File -Path (Get-HarnessEnvLockPath -StagingPath $stagingRoot)
        $buildHash = Get-LowerSha256File -Path (Get-HarnessEnvBuildPath -StagingPath $stagingRoot)
        $stagedTreeHashes = Get-HarnessJsonProperty -Object $materialized.Lock -Name 'StagedSkillTreeHashes'
        $skillCounts = [ordered]@{}
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            # An empty platform map is a valid v3 materialization (the root still
            # exists); report it as zero staged skills instead of failing.
            $platformHashes = Get-HarnessJsonProperty -Object $stagedTreeHashes -Name $platform
            $skillCounts[$platform] = if ($null -eq $platformHashes) { 0 } else { @($platformHashes.PSObject.Properties).Count }
        }
        $contextHash = Get-SemanticJsonHash -InputObject ([ordered]@{
            Trigger = $Trigger; Commit = $Head; Changed = @($Changed)
            Route = $script:RunnerRoute; EnvironmentName = $EnvironmentName
            MaterializationHash = [string] (Get-HarnessJsonProperty -Object $materialized.Build -Name 'MaterializationHash')
        })
        $contentHashes = @(
            @($Changed | ForEach-Object { Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $_; Commit = $Head }) })
            $lockHash
            $buildHash
            $contextHash
        ) | Where-Object { $_ } | Sort-Object -Unique
        $command = Get-RunnerExternalDryRunCommand -ExecutingRoot $ExecutingRoot -RouteCommand ([string] (Get-HarnessJsonProperty -Object $RouteAction -Name 'Command')) -Name $EnvironmentName
        $event = [ordered]@{
            SchemaVersion = 1; ArtifactKind = 'pending-sync-event'; EventKind = 'preview'; WorktreeNamespace = $script:RunnerWorktreeId
            Trigger = $Trigger; ApprovedToolchainHash = $ApprovedToolchainHash; CurrentToolchainHash = $CurrentToolchainHash
            Commit = $Head; ContextHash = $contextHash; PreviewStatus = 'non-consumable'
            RedactedContext = "route=$($script:RunnerRoute) env=$EnvironmentName build=env-build-v3-verified skills-claude=$($skillCounts['Claude']) skills-codex=$($skillCounts['Codex']) skills-reasonix=$($skillCounts['Reasonix']) snapshot-files=$(@($snapshot.Files).Count)"
            ContentHashes = @($contentHashes | Where-Object { $_ } | Select-Object -Unique)
            ExternalDryRunCommand = $command
        }
        $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
        $path = Write-RunnerPreviewArtifacts -StorageContext $context -Document $event -CurrentCommit $Head -CurrentContextHash $contextHash
        Write-Host 'pending-preview-only: a non-consumable Git-private preview was recorded.'
        Write-Host "Preview event: $path"
        Write-Host "External actionable plan requires an explicit command: $command"
        exit 0
    }
    finally {
        if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
    }
}

function Invoke-RunnerAuthorityRouting {
    <#
        The frozen selection-aware routing (Phase 3 Task 8 Step 2): the shared
        authority assessment decides one route; runner-policy.psd1's
        PreviewRouteActions decides whether that route may materialize a build
        ('environment-preview', always from the committed data snapshot into
        Git-private scratch) or is diagnostic-only. Unknown routes fail closed.
    #>
    param(
        [Parameter(Mandatory)] [string] $ExecutingRoot,
        [Parameter(Mandatory)] $Policy,
        [Parameter(Mandatory)] [string] $Trigger,
        [Parameter(Mandatory)] [string] $Head,
        [Parameter(Mandatory)] [string[]] $Changed,
        [Parameter(Mandatory)] [string] $ApprovedToolchainHash,
        [Parameter(Mandatory)] [string] $CurrentToolchainHash
    )
    . (Join-Path $ExecutingRoot 'scripts/harness-authority-status-common.ps1')
    $identity = Get-RunnerAuthorityIdentity -IdentityPath $AuthorityIdentityPath
    $assessment = Get-HarnessEnvAuthorityAssessment -RepoRoot $RepoRoot -Identity $identity
    $route = [string] (Get-HarnessJsonProperty -Object $assessment -Name 'Route')
    $script:RunnerRoute = $route
    $routeTable = Get-HarnessJsonProperty -Object $Policy -Name 'PreviewRouteActions'
    $actionRow = $null
    if ($routeTable -is [System.Collections.IDictionary] -and $routeTable.Contains($route)) { $actionRow = $routeTable[$route] }
    if ($null -eq $actionRow) { throw "runner-review-required: runner policy has no preview route action for authority route '$route'." }
    $action = [string] (Get-HarnessJsonProperty -Object $actionRow -Name 'Action')

    if ($action -ceq 'environment-preview') {
        $name = if ($route -ceq 'initial') { 'full' } else { [string] (Get-HarnessJsonProperty -Object (Get-HarnessJsonProperty -Object $assessment -Name 'StateSummary') -Name 'EnvironmentName') }
        Invoke-RunnerEnvironmentPreview -ExecutingRoot $ExecutingRoot -RouteAction $actionRow -EnvironmentName $name `
            -Trigger $Trigger -Head $Head -Changed $Changed `
            -ApprovedToolchainHash $ApprovedToolchainHash -CurrentToolchainHash $CurrentToolchainHash
    }
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $command = Get-RunnerExternalDryRunCommand -ExecutingRoot $ExecutingRoot -RouteCommand ([string] (Get-HarnessJsonProperty -Object $actionRow -Name 'Command'))
    $contextHash = Get-SemanticJsonHash -InputObject ([ordered]@{ Trigger = $Trigger; Commit = $Head; Changed = @($Changed); Route = $route })
    $event = [ordered]@{
        SchemaVersion = 1; ArtifactKind = 'pending-sync-event'; EventKind = 'diagnostic'; WorktreeNamespace = $context.WorktreeId
        Trigger = $Trigger; ApprovedToolchainHash = $ApprovedToolchainHash; CurrentToolchainHash = $CurrentToolchainHash
        Commit = $Head; ContextHash = $contextHash; PreviewStatus = 'diagnostic-only'
        RedactedContext = "route=$route changed-count=$($Changed.Count)"
        ContentHashes = @()
        ExternalDryRunCommand = $command
    }
    $path = Write-RunnerPreviewArtifacts -StorageContext $context -Document $event -CurrentCommit $Head -CurrentContextHash $contextHash
    Write-Host "diagnostic-only: the shared authority routed this trigger to '$route'; no environment was materialized."
    Write-Host "Diagnostic event: $path"
    Write-Host "External actionable operation requires an explicit command: $command"
    Exit-Diagnostic -Token $route -Detail "the shared authority routed this trigger to the '$route' diagnostic; approved automation performed zero live writes." -Code 76
}

$script:RunnerRoute = $null
try {
    $RepoRoot = [System.IO.Path]::GetFullPath($RepoRoot)
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $script:RunnerWorktreeId = [string] $context.WorktreeId
    $state = Get-ApprovedRunnerState -RepoRoot $RepoRoot
    $executingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    if ($executingRoot -cne (Resolve-Path -LiteralPath ([string]$state.RunnerRoot)).Path) { Exit-Diagnostic -Token 'runner-review-required' -Detail 'checkout or unapproved runner code was selected.' }

    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-runner-check-$([Guid]::NewGuid().ToString('N'))"
    try { $current = Get-RunnerPolicySnapshot -RepoRoot $RepoRoot -DestinationRoot $probe -BindingCommit ([string]$state.ApprovedCommit) -ToolCacheRoot ([string]$state.ToolCacheRoot) }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force } }
    if ([string]$current.ToolchainPolicyHash -cne [string]$state.ToolchainPolicyHash -or [string]$current.RunnerTreeHash -cne [string]$state.RunnerTreeHash -or [string]$current.ValidatorIdentityHash -cne [string]$state.ValidatorIdentityHash -or [string]$current.ScannerIdentityHash -cne [string]$state.ScannerIdentityHash) {
        Exit-Diagnostic -Token 'runner-review-required' -Detail 'checkout toolchain differs from the explicitly approved runner.'
    }

    Assert-CanonicalAutomationReady -ExecutingRoot $executingRoot

    if ($Trigger -eq 'pre-commit') {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $executingRoot 'scripts/scan-secrets.ps1') -RepoRoot $RepoRoot
        exit $LASTEXITCODE
    }
    if ($Trigger -eq 'manual' -or $Force) { Exit-Diagnostic -Token 'safety-protocol-upgrade-required' -Detail 'Phase 0 automation is preview-only and canonical routing is not released.' -Code 73 }

    $policy = Get-RunnerPolicy -RepoRoot $RepoRoot
    $changed = @(Get-RelevantChanges -Policy $policy)
    if ($changed.Count -eq 0) { Write-Host 'No policy-relevant changes; preview not created.'; exit 0 }
    $head = ((& git -C $RepoRoot rev-parse HEAD) | Select-Object -First 1).Trim()
    Invoke-RunnerAuthorityRouting -ExecutingRoot $executingRoot -Policy $policy -Trigger $Trigger -Head $head -Changed $changed `
        -ApprovedToolchainHash ([string]$state.ToolchainPolicyHash) -CurrentToolchainHash ([string]$current.ToolchainPolicyHash)
}
catch {
    $message = $_.Exception.Message
    if ($message -match 'json-schema-validator') { Exit-Diagnostic -Token 'validator-install-required' -Detail $message -Code 70 }
    if ($message -match 'secret-scanner|gitleaks') { Exit-Diagnostic -Token 'scanner-install-required' -Detail $message -Code 71 }
    if ($message -match 'working-tree-review-required') { Exit-Diagnostic -Token 'working-tree-review-required' -Detail $message -Code 74 }
    Exit-Diagnostic -Token 'runner-review-required' -Detail $message
}
