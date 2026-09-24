#requires -Version 7.0

param([ValidateSet('all', 'rollback-staging')] [string] $Section = 'all')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$sourceRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-backup-recovery-$([Guid]::NewGuid().ToString('N'))"
$RepoRoot = Join-Path $work 'repo'
$workOwned = $false
$script:pass = 0

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:pass++
    Write-Host "  PASS  $Message"
}

function Write-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Assert-RollbackFixtureNoReparse {
    param([Parameter(Mandatory)] [string] $Path, [switch] $AncestorsOnly)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    # Check each ancestor and walk children without following reparse points.
    $cursor = $resolved
    while (-not [string]::IsNullOrEmpty($cursor)) {
        if ((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'rollback fixture cleanup refuses a reparse point' }
        $cursor = Split-Path -Parent $cursor
    }
    if ($AncestorsOnly) { return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($resolved)
    while ($pending.Count -gt 0) {
        $entry = Get-Item -LiteralPath $pending.Pop() -Force
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'rollback fixture cleanup refuses a reparse point' }
        if ($entry.PSIsContainer) { foreach ($child in @(Get-ChildItem -LiteralPath $entry.FullName -Force)) { $pending.Push($child.FullName) } }
    }
}

function Remove-RollbackFixturePath {
    param([Parameter(Mandatory)] [string] $Path)
    $resolved = [System.IO.Path]::GetFullPath($Path)
    $owned = [System.IO.Path]::GetFullPath($work)
    if (-not $workOwned -or -not ($resolved.Equals($owned, [StringComparison]::OrdinalIgnoreCase) -or
        $resolved.StartsWith($owned + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase))) {
        throw 'rollback fixture cleanup escaped its owned root'
    }
    if (-not (Test-Path -LiteralPath $resolved)) { return }
    Assert-RollbackFixtureNoReparse -Path $resolved
    Remove-Item -LiteralPath $resolved -Recurse -Force
}

try {
    # All origin locks and test writes belong to this invocation, including the
    # public rollback child's Git-private canonical and worktree-overlay locks.
    Assert-RollbackFixtureNoReparse -Path (Split-Path -Parent $work) -AncestorsOnly
    New-Item -ItemType Directory -Path $work | Out-Null
    $workOwned = $true
    Write-Host ('ROLLBACK_FIXTURE_ROOT ' + $work)
    New-Item -ItemType Directory -Path $RepoRoot | Out-Null
    foreach ($name in @('scripts', 'schemas', 'tools', 'tests', '.gitleaks.toml', 'bootstrap.ps1')) {
        Assert-RollbackFixtureNoReparse -Path (Join-Path $sourceRepoRoot $name)
        Copy-Item -LiteralPath (Join-Path $sourceRepoRoot $name) -Destination $RepoRoot -Recurse
    }
    & git -C $RepoRoot init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'rollback fixture git initialization failed' }
    & git -C $RepoRoot -c "core.hooksPath=$work/inert-hooks" -c user.name=Fixture -c user.email=fixture@example.invalid commit --allow-empty --quiet -m 'Initialize rollback fixture'
    if ($LASTEXITCODE -ne 0) { throw 'rollback fixture commit initialization failed' }
    # No fallback to the real Windows identity is allowed, even if a sandbox
    # capability is missing or invalid. Only the copied locator is adapted; the
    # released resolver, lock order and transaction engines remain unchanged.
    $identityPath = Join-Path $RepoRoot 'scripts/home-authority-common.ps1'
    $identityText = [System.IO.File]::ReadAllText($identityPath)
    $identityAst = [System.Management.Automation.Language.Parser]::ParseInput($identityText, [ref] $null, [ref] $null)
    $identityFunctions = @($identityAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Get-WindowsHomeAuthorityIdentity' }, $true))
    if ($identityFunctions.Count -ne 1) { throw 'rollback fixture identity adapter requires one locator' }
    $identityExtent = $identityFunctions[0].Extent
    $identityText = $identityText.Substring(0, $identityExtent.StartOffset) + "function Get-WindowsHomeAuthorityIdentity { throw 'rollback-test-real-identity-forbidden' }" + $identityText.Substring($identityExtent.EndOffset)
    [System.IO.File]::WriteAllText($identityPath, $identityText, [System.Text.UTF8Encoding]::new($false))
    . (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
    . (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
    . (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
    . (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
    . (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')
    . (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')
    . (Join-Path $RepoRoot 'tests/helpers/safety-sandbox.ps1')

    Write-Host '[environment rollback surface]'
    $rollbackScript = Join-Path $RepoRoot 'scripts/rollback-harness-env.ps1'
    $cliScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
    $rollbackSource = [System.IO.File]::ReadAllText($rollbackScript)

    # The legacy selection surface is removed: only the receipt selects a
    # rollback, and the legacy switches must not reappear as parameters.
    $rollbackAst = [System.Management.Automation.Language.Parser]::ParseFile($rollbackScript, [ref] $null, [ref] $null)
    $rollbackParameters = @($rollbackAst.ParamBlock.Parameters | ForEach-Object { [string] $_.Name.VariablePath.UserPath })
    foreach ($name in @('ReceiptPath', 'DryRun', 'Apply', 'PlanPath', 'RepoRoot', 'JsonPath')) {
        Assert ($rollbackParameters -ccontains $name) "the rollback entry exposes the reviewed '$name' parameter"
    }
    foreach ($legacy in @('RunId', 'BackupPath', 'BackupRoot', 'HomeRoot')) {
        Assert (-not ($rollbackParameters -ccontains $legacy)) "the legacy '$legacy' selection is removed from the rollback entry"
    }
    $reviewedTokens = @(
        'rollback-receipt-missing', 'rollback-receipt-not-complete', 'rollback-receipt-tampered',
        'rollback-source-kind-unsupported', 'rollback-home-authority-mismatch', 'rollback-origin-mismatch',
        'rollback-backup-drift', 'rollback-preimage-missing', 'rollback-preimage-tampered',
        'rollback-claims-drift', 'rollback-source-transaction-missing', 'rollback-source-transaction-tampered',
        'rollback-source-transaction-unfinished', 'rollback-source-outcome-unsupported',
        'rollback-source-receipt-mismatch', 'rollback-state-drift', 'rollback-overlay-drift',
        'rollback-live-root-drift', 'rollback-plan-missing', 'rollback-plan-mismatch'
    )
    foreach ($token in $reviewedTokens) {
        Assert ($rollbackSource.Contains($token)) "the rollback entry pins the reviewed '$token' failure token"
    }

    # The wrapper keeps its mode gate before any forwarded work.
    function Invoke-CliArguments {
        param([Parameter(Mandatory)] [string] $ScriptPath, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments)
        $output = @(& pwsh -NoProfile -File $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
    }
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('env')
    Assert ($r.Code -ne 0 -and $r.Out -match 'requires a sub-action') 'the env group requires a sub-action'
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('env', 'rollback', '-ReceiptPath', (Join-Path $work 'absent'), '-PlanPath', (Join-Path $work 'plan.json'))
    Assert ($r.Code -ne 0 -and $r.Out -match 'requires an explicit -DryRun or -Apply') 'env rollback requires an explicit mode'

    New-Item -ItemType Directory -Force -Path $work | Out-Null
    function Invoke-RollbackDispatch {
        param([AllowEmptyCollection()] [string[]] $Arguments)
        return Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $rollbackScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    }

    # Sandbox gates: the authority gate precedes every receipt read.
    $absentReceipt = Join-Path $work 'absent-receipt'
    $absentPlan = Join-Path $work 'gated-plan.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $absentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-plan-authority-missing') 'the rollback route fails closed without a complete authority'
    Assert (-not (Test-Path -LiteralPath $absentPlan)) 'the authority gate writes no plan file'

    # Bootstrap the sandbox authority in its own process, mirroring the sync
    # and live-recovery parity fixtures.
    $setupScript = Join-Path $work 'setup-authority.ps1'
    Write-TextFile -Path $setupScript -Content @'
#requires -Version 7.0
param([string] $AuthorityRepo)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $AuthorityRepo 'scripts/json-artifact-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/root-claims-registry-common.ps1')
$injectedHome = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
foreach ($folder in @((Join-Path $injectedHome 'AppData\Roaming'), (Join-Path $injectedHome 'AppData\Local'))) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
}
$identity = [pscustomobject][ordered]@{
    ResolverVersion = 'windows-token-sid-known-folder-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $injectedHome
    RoamingAppDataRoot = (Join-Path $injectedHome 'AppData\Roaming')
    LocalAppDataRoot = (Join-Path $injectedHome 'AppData\Local')
}
$context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
$intent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)
$lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $intent
try { if ($null -eq $lock) { throw 'bootstrap returned no lock' } }
finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
Write-Host 'rollback sandbox authority bootstrap complete'
'@
    $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $setupScript -Arguments @('-AuthorityRepo', $RepoRoot) -AuthorityRepoRoot $RepoRoot
    if ($r.Code -ne 0) { Write-Host '----- rollback sandbox setup output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0) 'the rollback sandbox authority bootstrap succeeds'

    $controlBase = Join-Path (Join-Path $work 'home') 'AppData\Local\ai-agent-dotfiles\control'
    $backupRoot = Join-Path (Join-Path $work 'home') 'AppData\Local\ai-agent-dotfiles\backups'
    $authorityHome = Join-Path $work 'home'
    $authorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/home-authority/v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        HomeRootLocationKey = (ConvertTo-HomeAuthorityLocationKey -Path $authorityHome)
    })
    $claimsPath = Join-Path (Join-Path (Join-Path $controlBase 'homes') $authorityKey) 'root-claims.json'
    $statePath = Join-Path (Join-Path (Join-Path $controlBase 'homes') $authorityKey) 'current-env.json'

    # Receipt preflight: missing and partial receipt slots fail closed with
    # their reviewed tokens before the receipt document is interpreted.
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $absentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-missing') 'a missing receipt slot fails closed'

    $partialReceipt = Join-Path $work 'partial-receipt'
    New-Item -ItemType Directory -Force -Path (Join-Path $partialReceipt '_meta') | Out-Null
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $partialReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-not-complete.*PARTIAL') 'a partial receipt slot fails closed'

    function New-PreflightReceipt {
        param(
            [Parameter(Mandatory)] [string] $SourceOperationKind,
            [Parameter(Mandatory)] [string] $Label,
            [switch] $WithAuthorityStatePreimage
        )
        $root = Join-Path $work "preflight-$Label"
        $liveClaude = Join-Path $root 'live/claude/skills'
        foreach ($dir in @($liveClaude, (Join-Path $root 'live/codex/skills'), (Join-Path $root 'live/reasonix/skills'))) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Write-TextFile -Path (Join-Path $liveClaude 'kept/SKILL.md') -Content 'preflight-kept'
        if (-not (Test-Path -LiteralPath $claimsPath)) {
            Write-TextFile -Path $claimsPath -Content '{"artifact":"root-claims","fixture":"preflight"}'
        }
        $transactionId = [Guid]::NewGuid().ToString()
        $receiptId = [Guid]::NewGuid().ToString()
        $receiptPath = Join-Path $backupRoot $receiptId
        $platforms = @(
            [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude; Targets = @([ordered]@{ Name = 'kept'; LivePath = (Join-Path $liveClaude 'kept'); PlannedTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'kept')).TreeHash }) },
            [ordered]@{ Platform = 'Codex'; LiveRoot = (Join-Path $root 'live/codex/skills'); Targets = @() },
            [ordered]@{ Platform = 'Reasonix'; LiveRoot = (Join-Path $root 'live/reasonix/skills'); Targets = @() }
        )
        $receiptArguments = @{
            ReservationIntent = [ordered]@{
                TransactionId = $transactionId
                ReceiptId = $receiptId
                ReceiptPath = $receiptPath
            }
            SourceOperationKind = $SourceOperationKind
            PlanHash = ('1' * 64)
            DocumentHash = ('2' * 64)
            ExecutionContextHash = ('3' * 64)
            ControlBaseHash = ('4' * 64)
            FilesystemCapabilityHash = ('5' * 64)
            HomeAuthorityKey = $authorityKey
            BackupRoot = $backupRoot
            Platforms = $platforms
            ForbiddenRoots = @()
            RootClaimsPath = $claimsPath
        }
        if ($WithAuthorityStatePreimage) {
            $stateBytesPath = Join-Path $work "preflight-state-bytes-$Label.json"
            Write-TextFile -Path $stateBytesPath -Content '{"artifact":"current-env-state","fixture":"preflight"}'
            $receiptArguments['AuthorityStatePath'] = $stateBytesPath
        }
        $receipt = Invoke-SealedManagedBackupReceipt @receiptArguments
        return [string] $receipt['ReceiptPath']
    }

    $retirementReceipt = New-PreflightReceipt -SourceOperationKind 'retirement' -Label 'retirement'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath $retirementReceipt) -ceq 'COMPLETE') 'the preflight fixture produces a complete receipt'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $retirementReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-kind-unsupported \(source=retirement\)') 'a retirement receipt cannot start an ordinary rollback'
    Assert (-not (Test-Path -LiteralPath $absentPlan)) 'a rejected source kind writes no plan'

    $initialReceipt = New-PreflightReceipt -SourceOperationKind 'initial' -Label 'initial'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $initialReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-kind-unsupported \(source=initial\)') 'an initial receipt cannot start an ordinary rollback'

    # A valid sandbox capability admits this owned repository on either policy
    # state; Apply still requires a previously reviewed plan.
    $environmentReceipt = New-PreflightReceipt -SourceOperationKind 'environment' -Label 'environment'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-Apply', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'Artifact or evidence path is missing') 'sandbox rollback Apply fails closed on the missing reviewed plan'

    # A complete environment receipt without a captured authority preimage
    # cannot name a rollback destination even though its own marker is valid.
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-preimage-missing \(AuthorityStatePreimage\)') 'a receipt with a missing authority preimage fails closed'

    # The shared private-artifact-path table rejects output paths inside the
    # repository before any receipt evidence is interpreted.
    $insideRepoPlan = Join-Path $RepoRoot 'rollback-plan-inside-repo.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $insideRepoPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'must be disjoint from worktree') 'a plan path inside the repository is rejected by the shared artifact-path table'
    Assert (-not (Test-Path -LiteralPath $insideRepoPlan)) 'the rejected plan path is never written'
    $insideRepoJson = Join-Path $RepoRoot 'rollback-report-inside-repo.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $absentPlan, '-JsonPath', $insideRepoJson)
    Assert ($r.Code -ne 0 -and $r.Out -match 'must be disjoint from worktree') 'a report path inside the repository is rejected by the shared artifact-path table'
    Assert (-not (Test-Path -LiteralPath $insideRepoJson)) 'the rejected report path is never written'

    # A plan path that already exists is a DryRun collision before the
    # source-graph evidence is interpreted.
    $existingPlan = Join-Path $work 'existing-plan.json'
    Write-TextFile -Path $existingPlan -Content '{"placeholder":true}'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $existingPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-plan-path-collision') 'an existing DryRun plan path fails with the collision token'

    Write-Host '[environment source graph]'
    $builderScript = Join-Path $work 'new-environment-source-graph.ps1'
    Write-TextFile -Path $builderScript -Content @'
#requires -Version 7.0
param(
    [Parameter(Mandatory)] [string] $AuthorityRepo,
    [Parameter(Mandatory)] [string] $SpecPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $AuthorityRepo 'scripts/json-artifact-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/home-authority-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/target-context-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/live-plan-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/live-transaction-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/backup-receipt-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/canonical-transaction-common.ps1')
. (Join-Path $AuthorityRepo 'tests/helpers/sealed-live-plan-fixture.ps1')

function Write-GraphTextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

$spec = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($SpecPath, [System.Text.UTF8Encoding]::new($false, $true)))
$label = [string] $spec['Label']
$failMode = [string] $spec['FailMode']
if ([string]::IsNullOrWhiteSpace($failMode)) { $failMode = 'commit' }
$customReasonix = [bool] $spec['CustomReasonix']
$wrongReasonixRoot = -not [string]::IsNullOrEmpty([string] $spec['WrongReasonixLiveRoot'])
$missingAuthorityPreimage = [bool] $spec['MissingAuthorityPreimage']
$overlayDrift = [bool] $spec['OverlayDrift']
$reserveOnly = [bool] $spec['ReserveOnly']
$rootTransition = [bool] $spec['RootTransitionReasonix']
if ($rootTransition) { $failMode = 'failed-restored' }
$rollbackTargetCount = if ($spec.Contains('RollbackTargetCount')) { [int] $spec['RollbackTargetCount'] } else { 3 }

$injectedHome = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
$controlBase = $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE
$backupRoot = $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT
foreach ($folder in @((Join-Path $injectedHome 'AppData\Roaming'), (Join-Path $injectedHome 'AppData\Local'))) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
}
$identity = [pscustomobject][ordered]@{
    ResolverVersion = 'windows-token-sid-known-folder-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $injectedHome
    RoamingAppDataRoot = (Join-Path $injectedHome 'AppData\Roaming')
    LocalAppDataRoot = (Join-Path $injectedHome 'AppData\Local')
}
$context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
$authorityKey = [string] $context.HomeAuthorityKey
$claimsPath = [string] $context.RootClaimsPath
$statePath = [string] $context.CurrentEnvStatePath
$graphRoot = Join-Path $injectedHome ("source-graph-" + $label)

# An environment activation always operates on the currently claimed live
# roots. Only the first graph in the sandbox creates them (with the optional
# custom Reasonix root); every later graph reuses the roots the current
# authority state resolves.
$stateExistedBeforeRoots = Test-Path -LiteralPath $statePath -PathType Leaf
$liveRoots = [ordered]@{}
if ($stateExistedBeforeRoots) {
    $currentDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false, $true)))
    foreach ($identityRow in @([object[]] $currentDocument['FinalResolvedIdentities'])) {
        $liveRoots[[string] $identityRow['Platform']] = [string] $identityRow['ResolvedPath']
    }
}
else {
    $liveRoots['Claude'] = Join-Path $graphRoot 'live/claude/skills'
    $liveRoots['Codex'] = Join-Path $graphRoot 'live/codex/skills'
    $liveRoots['Reasonix'] = Join-Path $graphRoot 'live/reasonix/skills'
    if ($customReasonix) { $liveRoots['Reasonix'] = Join-Path $injectedHome 'custom-reasonix/skills' }
}
foreach ($root in @($liveRoots.Values)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
Write-GraphTextFile -Path (Join-Path $liveRoots['Claude'] 'kept/SKILL.md') -Content "kept-old-$label"
Write-GraphTextFile -Path (Join-Path $liveRoots['Reasonix'] "pruned-$label/SKILL.md") -Content "pruned-old-$label"

$sourceRoots = [ordered]@{
    Claude = Join-Path $graphRoot 'source/claude/skills'
    Codex = Join-Path $graphRoot 'source/codex/skills'
    Reasonix = Join-Path $graphRoot 'source/reasonix/skills'
}
foreach ($root in @($sourceRoots.Values)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
Write-GraphTextFile -Path (Join-Path $sourceRoots['Claude'] 'kept/SKILL.md') -Content $(if ($rollbackTargetCount -eq 0) { "kept-old-$label" } else { "kept-new-$label" })
Write-GraphTextFile -Path (Join-Path $sourceRoots['Codex'] "added-$label/SKILL.md") -Content "added-new-$label"

$stagingRoots = [ordered]@{
    Claude = Join-Path $graphRoot 'staging/claude'
    Codex = Join-Path $graphRoot 'staging/codex'
    Reasonix = Join-Path $graphRoot 'staging/reasonix'
}
foreach ($root in @($stagingRoots.Values)) { New-Item -ItemType Directory -Force -Path $root | Out-Null }
$stateRecoveryDirectory = Join-Path $graphRoot 'staging/state-recovery'

$capabilityHashes = [ordered]@{ Claude = ('9' * 64); Codex = ('8' * 64); Reasonix = ('7' * 64) }

if (-not (Test-Path -LiteralPath $claimsPath -PathType Leaf)) {
    $claimRows = @()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $meta = Get-TargetMetadataContext -Path ([string] $liveRoots[$platform])
        $claimRows += [ordered]@{
            Platform = $platform
            LocationKey = [string] $meta.LocationKey
            RequestedPath = [string] $meta.RequestedPath
            InitialState = 'EXISTS'
            VolumeId = [string] $meta.VolumeId
            DeepestExistingParentPath = [string] $meta.DeepestExistingParentPath
            DeepestExistingParentIdentity = [string] $meta.DeepestExistingParentIdentity
            MissingRemainder = @([string[]] $meta.MissingRemainder)
            InitialDirectoryIdentity = [string] $meta.Ancestors[-1].Identity
            ExpectedPostState = 'EXISTS'
        }
    }
    $claimsDocument = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'root-claims'
        HomeAuthorityKey = $authorityKey
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ResolverVersion = 'windows-token-sid-known-folder-v1'
        HomeRootLocationKey = (ConvertTo-HomeAuthorityLocationKey -Path $injectedHome)
        LiveRootClaims = @($claimRows)
    }
    Test-RootClaimsSemantics -Document $claimsDocument
    $claimsBytes = ConvertTo-SemanticJsonBytes -InputObject $claimsDocument
    $claimsParent = Split-Path -Parent $claimsPath
    New-Item -ItemType Directory -Force -Path $claimsParent | Out-Null
    [System.IO.File]::WriteAllBytes($claimsPath, [byte[]] $claimsBytes)
}
$claimsBytes = [System.IO.File]::ReadAllBytes($claimsPath)
$claimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($claimsBytes)).ToLowerInvariant()

$stateExisted = Test-Path -LiteralPath $statePath -PathType Leaf
if ($stateExisted) {
    $preimageBytes = [System.IO.File]::ReadAllBytes($statePath)
    $preimageDocument = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $preimageBytes))
    $preimageGeneration = [long] $preimageDocument['AuthorityGeneration']
}
else {
    $identityRows = @()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $meta = Get-TargetMetadataContext -Path ([string] $liveRoots[$platform])
        $identityRows += [ordered]@{
            Platform = $platform
            LocationKey = [string] $meta.LocationKey
            ResolvedPath = [string] $meta.RequestedPath
            VolumeId = [string] $meta.VolumeId
            DirectoryIdentity = [string] $meta.Ancestors[-1].Identity
            FilesystemCapabilityHash = [string] $capabilityHashes[$platform]
        }
    }
    $overlayHash = ('7' * 64)
    $preimageDocument = [ordered]@{
        SchemaVersion = 3
        ArtifactKind = 'current-env-state'
        HomeAuthorityKey = $authorityKey
        AuthorityGeneration = 1
        RootClaimsHash = $claimsHash
        SelectionKind = 'environment'
        EnvironmentName = 'full'
        EnvironmentLockHash = ('6' * 64)
        TaskOverlayHash = $overlayHash
        TaskOverlaySkills = @(
            [ordered]@{ Platform = 'Claude'; Skills = @() },
            [ordered]@{ Platform = 'Codex'; Skills = @() },
            [ordered]@{ Platform = 'Reasonix'; Skills = @() }
        )
        ManifestHashes = @(
            [ordered]@{ Platform = 'Claude'; Hash = ('b' * 64) },
            [ordered]@{ Platform = 'Codex'; Hash = ('c' * 64) },
            [ordered]@{ Platform = 'Reasonix'; Hash = ('d' * 64) }
        )
        FinalManagedHashes = @(
            [ordered]@{ Platform = 'Claude'; Hash = ('1' * 64) },
            [ordered]@{ Platform = 'Codex'; Hash = ('2' * 64) },
            [ordered]@{ Platform = 'Reasonix'; Hash = ('3' * 64) }
        )
        ControllerRepoFingerprint = ('5' * 64)
        ApprovedToolchainHash = ('4' * 64)
        PlanHash = ('1' * 64)
        DocumentHash = ('2' * 64)
        LastOperationKind = 'initial'
        ReceiptId = [Guid]::NewGuid().ToString()
        ReceiptHash = ('e' * 64)
        JournalId = [Guid]::NewGuid().ToString()
        PreStatePhaseHash = ('0' * 64)
        FinalResolvedIdentities = @($identityRows)
        FinalTargetContextHash = (Get-SemanticJsonHash -InputObject @($identityRows))
    }
    Test-CurrentEnvStateSemantics -Document $preimageDocument
    $preimageBytes = [byte[]] (ConvertTo-SemanticJsonBytes -InputObject $preimageDocument)
    $stateParent = Split-Path -Parent $statePath
    New-Item -ItemType Directory -Force -Path $stateParent | Out-Null
    [System.IO.File]::WriteAllBytes($statePath, $preimageBytes)
    $preimageGeneration = 1
}

$planDocument = New-SealedLivePlanDocument -OperationKind 'environment'
$transactionId = [Guid]::NewGuid().ToString()
$receiptId = [Guid]::NewGuid().ToString()
$receiptPath = Join-Path $backupRoot $receiptId
$receiptHomeKey = $authorityKey
if (-not [string]::IsNullOrEmpty([string] $spec['ReceiptHomeAuthorityKey'])) {
    $receiptHomeKey = [string] $spec['ReceiptHomeAuthorityKey']
}
$headerClaimsHash = $claimsHash
$rootTransition = [bool] $spec['RootTransitionReasonix']
if ($rootTransition) {
    # A forged root transition: the header binds the claims of a DIFFERENT
    # (custom) Reasonix root while the immutable on-disk claims still bind
    # the claimed one. The proposed document is semantically valid (the
    # fixed Claude/Codex home paths plus the proposed custom Reasonix root)
    # but is never installed; the engine's claims proof rejects the hash.
    $transitionReasonix = Join-Path $graphRoot 'transition-reasonix/skills'
    New-Item -ItemType Directory -Force -Path $transitionReasonix | Out-Null
    $transitionRows = @()
    $transitionIndex = 1
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $transitionPath = if ($platform -ceq 'Claude') { Join-Path $injectedHome '.claude/skills' }
        elseif ($platform -ceq 'Codex') { Join-Path $injectedHome '.codex/skills' }
        else { $transitionReasonix }
        $meta = Get-TargetMetadataContext -Path $transitionPath
        $identity = [string] $meta.VolumeId + ':' + ('{0:x16}' -f $transitionIndex)
        $transitionIndex++
        $transitionRows += [ordered]@{
            Platform = $platform
            LocationKey = [string] $meta.LocationKey
            RequestedPath = [string] $meta.RequestedPath
            InitialState = 'EXISTS'
            VolumeId = [string] $meta.VolumeId
            DeepestExistingParentPath = [string] $meta.RequestedPath
            DeepestExistingParentIdentity = $identity
            MissingRemainder = @()
            InitialDirectoryIdentity = $identity
            ExpectedPostState = 'EXISTS'
        }
    }
    $transitionClaims = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'root-claims'
        HomeAuthorityKey = $authorityKey
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ResolverVersion = 'windows-token-sid-known-folder-v1'
        HomeRootLocationKey = (ConvertTo-HomeAuthorityLocationKey -Path $injectedHome)
        LiveRootClaims = @($transitionRows)
    }
    Test-RootClaimsSemantics -Document $transitionClaims
    $headerClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]] (ConvertTo-SemanticJsonBytes -InputObject $transitionClaims))).ToLowerInvariant()
}

# The source header binds the calling repository's canonical origin identity
# exactly like a production activation, so the rollback derivation's origin
# matching is exercised against real values.
$gitContext = Get-CanonicalGitContext -RepoRoot $AuthorityRepo
$contractPaths = Get-CanonicalTransactionContractPaths -GitContext $gitContext
$repoId = Get-CanonicalRepoIdentity -GitContext $gitContext
$canonicalLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $contractPaths.LockPath })
$headerOriginRepoId = $repoId
if ([bool] $spec['OriginOverride']) { $headerOriginRepoId = ('9' * 64) }

$reasonixReceiptRoot = [string] $liveRoots['Reasonix']
if ($wrongReasonixRoot) {
    $reasonixReceiptRoot = Join-Path $graphRoot 'wrong-reasonix/skills'
    New-Item -ItemType Directory -Force -Path $reasonixReceiptRoot | Out-Null
}
$reasonixReceiptTargets = @()
if (-not $wrongReasonixRoot) {
    $reasonixReceiptTargets = @([ordered]@{
        Name = "pruned-$label"
        LivePath = (Join-Path $liveRoots['Reasonix'] "pruned-$label")
        PlannedTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveRoots['Reasonix'] "pruned-$label")).TreeHash
    })
}
$receiptPlatforms = @(
    [ordered]@{
        Platform = 'Claude'
        LiveRoot = [string] $liveRoots['Claude']
        Targets = @([ordered]@{
            Name = 'kept'
            LivePath = (Join-Path $liveRoots['Claude'] 'kept')
            PlannedTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveRoots['Claude'] 'kept')).TreeHash
        })
    },
    [ordered]@{
        Platform = 'Codex'
        LiveRoot = [string] $liveRoots['Codex']
        Targets = @(if ($rollbackTargetCount -eq 3) { [ordered]@{ Name = "added-$label"; LivePath = (Join-Path $liveRoots['Codex'] "added-$label"); PlannedTreeHash = $null } })
    },
    [ordered]@{
        Platform = 'Reasonix'
        LiveRoot = $reasonixReceiptRoot
        Targets = @(if ($rollbackTargetCount -eq 3) { $reasonixReceiptTargets })
    }
)
$receiptSplat = @{
    ReservationIntent = [ordered]@{
        TransactionId = $transactionId
        ReceiptId = $receiptId
        ReceiptPath = $receiptPath
    }
    SourceOperationKind = 'environment'
    PlanHash = [string] $planDocument['PlanHash']
    DocumentHash = [string] $planDocument['DocumentHash']
    ExecutionContextHash = ('3' * 64)
    ControlBaseHash = ('4' * 64)
    FilesystemCapabilityHash = ('5' * 64)
    HomeAuthorityKey = $receiptHomeKey
    BackupRoot = $backupRoot
    Platforms = $receiptPlatforms
    ForbiddenRoots = @()
    RootClaimsPath = $claimsPath
}
if (-not $missingAuthorityPreimage) { $receiptSplat['AuthorityStatePath'] = $statePath }
$receipt = Invoke-SealedManagedBackupReceipt @receiptSplat

$header = [ordered]@{
    SchemaVersion = 1
    ArtifactKind = 'live-journal-header'
    TransactionId = $transactionId
    OperationKind = 'environment'
    TransactionMode = 'receipt-backed'
    OriginalDocumentHash = [string] $planDocument['DocumentHash']
    OriginalPlanHash = [string] $planDocument['PlanHash']
    HomeAuthorityKey = $authorityKey
    OriginRepoId = $headerOriginRepoId
    GitCommonDirHash = [string] $gitContext.GitCommonDirHash
    CanonicalLockKey = $canonicalLockKey
    RootClaimsHash = $headerClaimsHash
    ReceiptIntent = [ordered]@{ Id = $receiptId; Path = $receiptPath }
    Targets = @()
}
if ([bool] $spec['OverlayLockHeader']) { $header['WorktreeOverlayLockKey'] = ('8' * 64) }
elseif ([bool] $spec['OverlayLockHeaderOrigin']) {
    # Bind the exact worktree overlay identity this repository derives, so the
    # rollback dispatch (running against the same -RepoRoot) can acquire it.
    $header['WorktreeOverlayLockKey'] = Get-WorktreeOverlayLockKey -LockPath (Get-WorktreeOverlayLockPath -GitContext $gitContext)
}
$transactionDirectory = Join-Path (Join-Path $controlBase 'live-transactions') $transactionId
New-SealedLiveJournalHeader -Document $header -TransactionDirectory $transactionDirectory | Out-Null

$graphOutcome = 'reserved'
if (-not $reserveOnly) {
    $keptOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveRoots['Claude'] 'kept')).TreeHash
    $keptNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceRoots['Claude'] 'kept')).TreeHash
    $addedNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceRoots['Codex'] "added-$label")).TreeHash
    $actions = @([ordered]@{ Platform = 'Claude'; Action = 'update'; Name = 'kept'; SourceHash = $keptNewHash; LiveHash = $keptOldHash })
    if ($rollbackTargetCount -eq 3) { $actions += [ordered]@{ Platform = 'Codex'; Action = 'add'; Name = "added-$label"; SourceHash = $addedNewHash; LiveHash = $null } }
    if (-not $wrongReasonixRoot -and $rollbackTargetCount -eq 3) {
        $prunedOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveRoots['Reasonix'] "pruned-$label")).TreeHash
        $actions += [ordered]@{ Platform = 'Reasonix'; Action = 'prune'; Name = "pruned-$label"; SourceHash = $null; LiveHash = $prunedOldHash }
    }
    $liveRootContexts = @()
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $liveRootContexts += [ordered]@{
            Platform = $platform
            LiveRoot = [string] $liveRoots[$platform]
            DeepestExistingParentPath = [string] $liveRoots[$platform]
            MissingRemainder = @()
            StagingRoot = [string] $stagingRoots[$platform]
        }
    }
    $targets = New-SealedLiveTransactionTargetPlan -BackupRoot $backupRoot -ReceiptIntent $header['ReceiptIntent'] -Platforms $receiptPlatforms -Actions $actions -LiveRootContexts $liveRootContexts

    $contextRows = @()
    foreach ($identityRow in @([object[]] $preimageDocument['FinalResolvedIdentities'])) {
        $contextRows += [ordered]@{
            Platform = [string] $identityRow['Platform']
            LocationKey = [string] $identityRow['LocationKey']
            RequestedPath = [string] $identityRow['ResolvedPath']
            InitialState = 'EXISTS'
            VolumeId = [string] $identityRow['VolumeId']
            DeepestExistingParentPath = [string] $identityRow['ResolvedPath']
            DeepestExistingParentIdentity = [string] $identityRow['DirectoryIdentity']
            MissingRemainder = @()
            InitialDirectoryIdentity = [string] $identityRow['DirectoryIdentity']
            ExpectedPostState = 'EXISTS'
        }
    }
    $stateIntent = [ordered]@{}
    foreach ($name in @('SchemaVersion', 'ArtifactKind', 'HomeAuthorityKey', 'RootClaimsHash', 'SelectionKind', 'EnvironmentName', 'EnvironmentLockHash', 'TaskOverlayHash', 'TaskOverlaySkills', 'ManifestHashes', 'FinalManagedHashes', 'ControllerRepoFingerprint', 'ApprovedToolchainHash')) {
        $stateIntent[$name] = $preimageDocument[$name]
    }
    $stateIntent['AuthorityGeneration'] = $preimageGeneration + 1
    if ($overlayDrift) {
        # The drift variant models an environment transaction whose terminal
        # poststate records a different tracked overlay baseline than its
        # activation preimage, which must make the receipt ineligible.
        $stateIntent['TaskOverlayHash'] = ('8' * 64)
    }
    $stateIntent['PlanHash'] = [string] $planDocument['PlanHash']
    $stateIntent['DocumentHash'] = [string] $planDocument['DocumentHash']
    $stateIntent['LastOperationKind'] = 'environment'

    if ($failMode -ceq 'failed-restored') {
        $sourceRoots['Claude'] = Join-Path $graphRoot 'source/claude/missing'
    }
    $producerArguments = [ordered]@{
        TransactionDirectory = $transactionDirectory
        Header = $header
        Receipt = $receipt
        Targets = @($targets)
        SourceRootsByPlatform = $sourceRoots
        AuthorityStateIntent = $stateIntent
        TargetContextIntent = [ordered]@{ HomeAuthorityKey = $authorityKey; Rows = @($contextRows) }
        FinalCapabilityHashesByPlatform = $capabilityHashes
        ControlBase = $controlBase
        StateRecoveryDirectory = $stateRecoveryDirectory
    }
    $producerJson = ConvertTo-Json -InputObject $producerArguments -Depth 40 -Compress
    $produceOutput = @(& pwsh -NoProfile -File (Join-Path $AuthorityRepo 'tests/helpers/live-transaction-host.ps1') -Mode 'produce' -ProducerArgsJson $producerJson -RepoRoot $AuthorityRepo 2>&1)
    $produceExit = $LASTEXITCODE
    $produceText = ($produceOutput | ForEach-Object { [string] $_ }) -join "`n"
    if ($failMode -ceq 'commit' -and $produceExit -ne 0) {
        Write-Host "----- produce output ($label) -----"
        Write-Host $produceText
        throw "the produce engine failed for $label with exit $produceExit"
    }

    $chain = Get-SealedLiveJournalChain -TransactionDirectory $transactionDirectory
    $terminalEntries = @(@($chain.Records) | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'COMPLETE' })
    if (@($terminalEntries).Count -ne 1) { throw "the produced transaction $label has no single terminal record" }
    $graphOutcome = [string] ([System.Collections.IDictionary] ([System.Collections.IDictionary] $terminalEntries[0]['Document'])['Data'])['Outcome']
    if ($failMode -ceq 'commit') {
        if ($graphOutcome -cne 'committed') { throw "the produced transaction $label closed with $graphOutcome" }
        $stateBytes = [System.IO.File]::ReadAllBytes($statePath)
        $stateHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stateBytes)).ToLowerInvariant()
        if ($stateHash -cne [string] $chain.Result['StateHash']) { throw "the produced transaction $label left a drifted state" }
    }
    else {
        if ($graphOutcome -cne 'failed-restored') { throw "the failing produce run for $label closed with $graphOutcome" }
    }
}

$graph = [ordered]@{
    Label = $label
    Outcome = $graphOutcome
    TransactionId = $transactionId
    ReceiptId = $receiptId
    ReceiptPath = $receiptPath
    ReceiptHash = [string] $receipt['ReceiptHash']
    PlanHash = [string] $planDocument['PlanHash']
    DocumentHash = [string] $planDocument['DocumentHash']
    ClaimsPath = $claimsPath
    StatePath = $statePath
    ReasonixLiveRoot = [string] $liveRoots['Reasonix']
}
Write-Host ('SOURCE_GRAPH ' + (ConvertTo-Json -InputObject $graph -Depth 6 -Compress))
'@

    function New-SourceGraph {
        param([Parameter(Mandatory)] [System.Collections.IDictionary] $Spec)
        $specPath = Join-Path $work ("source-graph-spec-" + [string] $Spec['Label'] + ".json")
        Write-TextFile -Path $specPath -Content ((ConvertTo-Json -InputObject $Spec -Depth 6) + "`n")
        $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $builderScript -Arguments @('-AuthorityRepo', $RepoRoot, '-SpecPath', $specPath) -AuthorityRepoRoot $RepoRoot
        if ($r.Code -ne 0) { Write-Host "----- source graph $($Spec['Label']) output -----"; Write-Host $r.Out }
        Assert ($r.Code -eq 0) "the source graph '$($Spec['Label'])' builds"
        $markerLine = @($r.Out.Split("`n")) | Where-Object { $_.StartsWith('SOURCE_GRAPH ', [System.StringComparison]::Ordinal) } | Select-Object -First 1
        if ($null -eq $markerLine) { throw "FAIL: source graph '$($Spec['Label'])' printed no SOURCE_GRAPH line" }
        return ConvertFrom-Json -InputObject ([string] $markerLine.Substring('SOURCE_GRAPH '.Length))
    }

    function Invoke-GraphRollback {
        param([Parameter(Mandatory)] $Graph, [Parameter(Mandatory)] [string] $PlanPath, [string] $JsonPath)
        $arguments = @('-ReceiptPath', [string] $Graph.ReceiptPath, '-DryRun', '-PlanPath', $PlanPath)
        if (-not [string]::IsNullOrEmpty($JsonPath)) { $arguments += @('-JsonPath', $JsonPath) }
        return Invoke-RollbackDispatch -Arguments $arguments
    }

    # The first graph claims a custom Reasonix root and every later graph
    # reuses the roots the current authority state resolves, so the whole
    # eligibility surface is exercised on an already-claimed custom root.
    $eligibleGraph = New-SourceGraph ([ordered]@{ Label = 'custom-reasonix'; CustomReasonix = $true })
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $eligibleGraph.ReceiptPath)) -ceq 'COMPLETE') 'the source-graph fixture produces a complete environment receipt'
    Assert ([string] $eligibleGraph.Outcome -ceq 'committed') 'the source-graph fixture commits through the produce engine'

    Write-Host '[environment rollback plan derivation]'
    $eligiblePlan = Join-Path $work 'eligible-plan.json'
    $r = Invoke-GraphRollback -Graph $eligibleGraph -PlanPath $eligiblePlan
    if ($r.Code -ne 0) { Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'environment rollback plan created') 'the eligible graph derives and writes the reviewed rollback plan on DryRun'
    Assert (Test-Path -LiteralPath $eligiblePlan -PathType Leaf) 'the derived plan file exists'
    $rollbackSchemaPath = Join-Path $RepoRoot 'schemas/rollback-plan.schema.json'
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $rollbackSchemaPath -InstancePath $eligiblePlan
    Assert $true 'the derived plan passes the pinned schema 1'
    $derivedPlan = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($eligiblePlan, [System.Text.UTF8Encoding]::new($false, $true)))
    Test-RollbackPlanSemantics -Document $derivedPlan
    Assert $true 'the derived plan passes the reviewed semantic layer'
    $derivedPayload = [System.Collections.IDictionary] $derivedPlan['PlanPayload']
    Assert ([string] $derivedPayload['PlanKind'] -ceq 'environment-rollback') 'the derived plan kind is environment-rollback'
    Assert ([string] $derivedPayload['SourceTransactionId'] -ceq [string] $eligibleGraph.TransactionId) 'the plan binds the source transaction'
    Assert ([string] $derivedPayload['ReceiptId'] -ceq [string] $eligibleGraph.ReceiptId -and
        [string] $derivedPayload['ReceiptHash'] -ceq [string] $eligibleGraph.ReceiptHash) 'the plan binds the exact source receipt identity'
    Assert ([string] $derivedPayload['OriginalPlanHash'] -ceq [string] $eligibleGraph.PlanHash -and
        [string] $derivedPayload['OriginalDocumentHash'] -ceq [string] $eligibleGraph.DocumentHash) 'the plan binds the source plan references'
    Assert ([string] $derivedPayload['HomeAuthorityKey'] -ceq $authorityKey) 'the plan binds the current authority key'
    $derivedGit = Get-CanonicalGitContext -RepoRoot $RepoRoot
    $derivedContractPaths = Get-CanonicalTransactionContractPaths -GitContext $derivedGit
    $derivedRepoId = Get-CanonicalRepoIdentity -GitContext $derivedGit
    $derivedLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $derivedContractPaths.LockPath })
    Assert ([string] $derivedPayload['OriginRepoId'] -ceq $derivedRepoId -and
        [string] $derivedPayload['GitCommonDirHash'] -ceq [string] $derivedGit.GitCommonDirHash -and
        [string] $derivedPayload['CanonicalLockKey'] -ceq $derivedLockKey) 'the plan binds the calling repository origin identity'
    foreach ($forbidden in @('TransactionId', 'OriginalOperationKind', 'Action', 'ReceiptRef', 'ReceiptState', 'HeaderHash', 'DerivedJournalHeadHash', 'ChainRecords', 'ExpectedOutcome', 'ExpectedTerminalProjection')) {
        Assert (-not $derivedPayload.Contains($forbidden)) "the derived plan omits the forbidden '$forbidden' field"
    }
    $derivedIntent = [System.Collections.IDictionary] $derivedPayload['RollbackStateIntent']
    Assert ([string] $derivedIntent['LastOperationKind'] -ceq 'environment-rollback') 'the rollback intent restores under the rollback operation kind'
    Assert ([string] $derivedIntent['HomeAuthorityKey'] -ceq [string] $derivedPayload['HomeAuthorityKey']) 'the rollback intent carries the payload authority key'
    $receiptDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path ([string] $eligibleGraph.ReceiptPath) '_meta/receipt.json'), [System.Text.UTF8Encoding]::new($false, $true)))
    $preimageState = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path (Join-Path ([string] $eligibleGraph.ReceiptPath) 'authority-preimage') 'current-env.json'), [System.Text.UTF8Encoding]::new($false, $true)))
    foreach ($carried in @('RootClaimsHash', 'SelectionKind', 'EnvironmentName', 'EnvironmentLockHash', 'TaskOverlayHash', 'ManifestHashes', 'FinalManagedHashes', 'ControllerRepoFingerprint', 'ApprovedToolchainHash')) {
        Assert ((Get-SemanticJsonHash -InputObject $derivedIntent[$carried]) -ceq (Get-SemanticJsonHash -InputObject $preimageState[$carried])) "the rollback intent carries the preimage '$carried'"
    }
    $installedState = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText([string] $eligibleGraph.StatePath, [System.Text.UTF8Encoding]::new($false, $true)))
    Assert ([long] $derivedIntent['AuthorityGeneration'] -eq ([long] $installedState['AuthorityGeneration'] + 1)) 'the rollback intent advances the authority generation'
    $derivedTargets = @([object[]] $derivedPayload['Targets'])
    Assert (@($derivedTargets).Count -eq 3) 'the plan binds one restore row per receipt snapshot target'
    $rowsByName = @{}
    foreach ($row in $derivedTargets) { $rowsByName[[string] $row['Name']] = $row }
    $keptRow = [System.Collections.IDictionary] $rowsByName['kept']
    $addedRow = [System.Collections.IDictionary] $rowsByName['added-custom-reasonix']
    $prunedRow = [System.Collections.IDictionary] $rowsByName['pruned-custom-reasonix']
    Assert ($null -ne $keptRow -and $null -ne $addedRow -and $null -ne $prunedRow) 'the restore rows cover the update, add, and prune source targets'
    Assert ([string] $keptRow['Current']['State'] -ceq 'PRESENT' -and [string] $keptRow['Candidate']['State'] -ceq 'PRESENT') 'the kept target is bound for restoration over its installed bytes'
    Assert ([string] $keptRow['Candidate']['Hash'] -ceq [string] ([System.Collections.IDictionary] ([System.Collections.IDictionary] $receiptDocument['ManagedSnapshots'][0])['Targets'][0])['SnapshotTreeHash']) 'the kept restore row candidates the exact snapshot bytes'
    Assert ([string] $addedRow['Current']['State'] -ceq 'PRESENT' -and [string] $addedRow['Candidate']['State'] -ceq 'MISSING') 'the installed add target is bound for removal'
    Assert ([string] $prunedRow['Current']['State'] -ceq 'MISSING' -and [string] $prunedRow['Candidate']['State'] -ceq 'PRESENT') 'the pruned target is bound for restoration from its snapshot'
    Assert (@($derivedTargets | ForEach-Object { [string] (([System.Collections.IDictionary] $_)['TargetId']) } | Sort-Object -Unique).Count -eq 3) 'the restore rows carry unique target identities'

    Write-Host '[environment rollback execution]'
    # The execution runs as a directly invoked reviewed composition (the
    # entry's Apply tail stays fail-closed on the worktree overlay lock until
    # the Phase 3 primitive). The eligible plan is executed immediately after
    # its derivation, while the current surface still matches its bindings.
    $executionScript = Join-Path $work 'invoke-environment-rollback.ps1'
    Write-TextFile -Path $executionScript -Content @'
#requires -Version 7.0
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $PlanPath,
    [Parameter(Mandatory)] [string] $SourceReceiptPath,
    [Parameter(Mandatory)] [string] $ControlBase,
    [Parameter(Mandatory)] [string] $BackupRoot,
    [Parameter(Mandatory)] [string] $HomeRoot,
    [Parameter(Mandatory)] [string] $ClaimsPath,
    [Parameter(Mandatory)] [string] $StatePath,
    [Parameter(Mandatory)] [string] $LiveTransactionsRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
$planDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($PlanPath, [System.Text.UTF8Encoding]::new($false, $true)))
$sourceReceipt = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path $SourceReceiptPath '_meta/receipt.json'), [System.Text.UTF8Encoding]::new($false, $true)))
$gitContext = Get-CanonicalGitContext -RepoRoot $RepoRoot
$contractPaths = Get-CanonicalTransactionContractPaths -GitContext $gitContext
$repoId = Get-CanonicalRepoIdentity -GitContext $gitContext
$canonicalLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $contractPaths.LockPath })
$result = Invoke-SealedEnvironmentRollbackTransaction -PlanDocument $planDocument -SourceReceiptDocument $sourceReceipt -SourceReceiptPath $SourceReceiptPath -ControlBase $ControlBase -BackupRoot $BackupRoot -HomeRoot $HomeRoot -ClaimsPath $ClaimsPath -StatePath $StatePath -LiveTransactionsRoot $LiveTransactionsRoot -GitContext $gitContext -RepoId $repoId -CanonicalLockKey $canonicalLockKey
Write-Host ('ROLLBACK_RESULT ' + (ConvertTo-Json -InputObject $result -Depth 6 -Compress))
'@
    function Invoke-RollbackExecution {
        param([Parameter(Mandatory)] [string] $PlanPath, [Parameter(Mandatory)] [string] $SourceReceiptPath)
        return Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $executionScript -Arguments @(
            '-RepoRoot', $RepoRoot,
            '-PlanPath', $PlanPath,
            '-SourceReceiptPath', $SourceReceiptPath,
            '-ControlBase', $controlBase,
            '-BackupRoot', $backupRoot,
            '-HomeRoot', $authorityHome,
            '-ClaimsPath', $claimsPath,
            '-StatePath', $statePath,
            '-LiveTransactionsRoot', (Join-Path $controlBase 'live-transactions')
        ) -AuthorityRepoRoot $RepoRoot
    }

    function Get-RollbackTransactionStagingRoot {
        param([Parameter(Mandatory)] $Chain)
        $transactionId = [string] $Chain.Header['TransactionId']
        if ($transactionId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
            throw 'FAIL: rollback staging requires the journal transaction identity'
        }
        $root = [IO.Path]::GetFullPath((Join-Path (Join-Path $authorityHome '.ai-agent-dotfiles-staging') ('rollback-' + $transactionId)))
        if (-not $workOwned -or -not $root.StartsWith(([IO.Path]::GetFullPath($work) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'FAIL: rollback staging escaped the owned fixture'
        }
        Assert-RollbackFixtureNoReparse -Path $root
        $scratchPaths = @($Chain.Records | ForEach-Object {
            $data = [System.Collections.IDictionary] $_['Document']['Data']
            foreach ($name in @('StagedPath', 'SwapOldPath')) {
                if ((Test-LiveTransactionMapHasName -Map $data -Name $name) -and -not [string]::IsNullOrWhiteSpace([string] $data[$name])) {
                    [string] $data[$name]
                }
            }
        } | Sort-Object -Unique)
        Assert ($scratchPaths.Count -gt 0) 'the rollback journal binds its transaction staging paths'
        foreach ($path in $scratchPaths) {
            $full = [IO.Path]::GetFullPath($path)
            Assert ($full.StartsWith(($root + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) 'every rollback journal scratch path belongs to its transaction namespace'
            $relative = [IO.Path]::GetRelativePath($root, $full).Replace('\', '/')
            Assert ($relative -cmatch '^(Claude|Codex|Reasonix)/(staged|swap|state-recovery)/[^/]+$') 'the rollback scratch path retains its platform and purpose below the transaction namespace'
        }
        return $root
    }

    $preExecutionState = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false, $true)))
    $r = Invoke-RollbackExecution -PlanPath $eligiblePlan -SourceReceiptPath ([string] $eligibleGraph.ReceiptPath)
    if ($r.Code -ne 0) { Write-Host '----- rollback execution output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0) 'the derived rollback plan executes end to end'
    $resultLine = @($r.Out.Split("`n")) | Where-Object { $_.StartsWith('ROLLBACK_RESULT ', [System.StringComparison]::Ordinal) } | Select-Object -First 1
    if ($null -eq $resultLine) { throw 'FAIL: the rollback execution printed no result line' }
    $rollbackResult = ConvertFrom-Json -InputObject ([string] $resultLine.Substring('ROLLBACK_RESULT '.Length))

    $graphLiveRoot = Join-Path $authorityHome 'source-graph-custom-reasonix/live'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $graphLiveRoot 'claude/skills/kept/SKILL.md')) -eq 'kept-old-custom-reasonix') 'the update target restores the pre-activation bytes'
    Assert (-not (Test-Path -LiteralPath (Join-Path $graphLiveRoot 'codex/skills/added-custom-reasonix'))) 'the installed add target is removed from live'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path ([string] $eligibleGraph.ReasonixLiveRoot) 'pruned-custom-reasonix/SKILL.md')) -eq 'pruned-old-custom-reasonix') 'the pruned target is restored from the activation snapshot'
    $rollbackReceipt = [string] $rollbackResult.ReceiptPath
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath $rollbackReceipt) -ceq 'COMPLETE') 'the pre-rollback receipt publishes a complete slot'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $rollbackReceipt 'snapshot/claude/kept/SKILL.md')) -eq 'kept-new-custom-reasonix') 'the pre-rollback receipt snapshots the pre-rollback live bytes'
    Assert (Test-Path -LiteralPath (Join-Path $rollbackReceipt 'snapshot/codex/added-custom-reasonix/SKILL.md') -PathType Leaf) 'the pre-rollback receipt snapshots the target that is about to be removed'
    $postState = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false, $true)))
    $stateBytesHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($statePath))).ToLowerInvariant()
    Assert ($stateBytesHash -ceq [string] $rollbackResult.StateHash) 'the installed state bytes match the returned StateHash'
    Assert ([long] $postState['AuthorityGeneration'] -eq ([long] $preExecutionState['AuthorityGeneration'] + 1)) 'the rollback advances the authority generation'
    Assert ([string] $postState['LastOperationKind'] -ceq 'environment-rollback') 'the restored state carries the rollback operation kind'
    Assert ((Get-SemanticJsonHash -InputObject $postState['TaskOverlayHash']) -ceq (Get-SemanticJsonHash -InputObject $preExecutionState['TaskOverlayHash'])) 'the restored state keeps the tracked overlay baseline'
    $rollbackChain = Get-SealedLiveJournalChain -TransactionDirectory ([string] $rollbackResult.JournalDirectory)
    $null = Test-SealedLiveJournalChain -Header $rollbackChain.Header -Records $rollbackChain.Records -Result $rollbackChain.Result -ResultFileHash $rollbackChain.ResultFileHash
    Assert $true 'the rollback journal chain validates end to end'
    Assert ([string] $rollbackChain.Result['Outcome'] -ceq 'committed') 'the rollback transaction publishes a committed result'
    $rollbackTerminal = @(@($rollbackChain.Records) | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'COMPLETE' })[0]
    Assert ([string] ([System.Collections.IDictionary] ([System.Collections.IDictionary] $rollbackTerminal['Document'])['Data'])['ClosingKind'] -ceq 'original') 'the rollback closes as a new original transaction'

    # Step 4 cleanup contract: the proven committed terminal reclaims exactly
    # this composition's own scratch -- the staged/swap-old entries of its
    # target ladder and the pre-rollback state-recovery copy -- and nothing
    # else. The journal, the rollback's own pre-rollback receipt, the source
    # activation receipt and the source receipt's snapshot trees are durable
    # evidence and survive.
    $stagingBase = Join-Path $authorityHome '.ai-agent-dotfiles-staging'
    $committedStaging = Get-RollbackTransactionStagingRoot -Chain $rollbackChain
    Assert (-not (Test-Path -LiteralPath (Join-Path $committedStaging 'Claude/swap/kept'))) 'the committed rollback reclaims the swap-old entry of its update target'
    Assert (-not (Test-Path -LiteralPath (Join-Path $committedStaging 'Codex/swap/added-custom-reasonix'))) 'the committed rollback reclaims the swap-old entry of its prune target'
    Assert (-not (Test-Path -LiteralPath (Join-Path $committedStaging 'Claude/state-recovery/current-env.preimage.json'))) 'the committed rollback reclaims the pre-rollback state-recovery copy'
    Assert (@(Get-ChildItem -LiteralPath $committedStaging -Recurse -Force -File).Count -eq 0) 'no staging file of the committed rollback survives under its transaction namespace'
    $rollbackJournal = [string] $rollbackResult.JournalDirectory
    Assert (Test-Path -LiteralPath (Join-Path $rollbackJournal 'header.json') -PathType Leaf) 'the committed rollback keeps its journal header'
    Assert (Test-Path -LiteralPath (Join-Path $rollbackJournal 'result.json') -PathType Leaf) 'the committed rollback keeps its published result'
    Assert (Test-Path -LiteralPath (Join-Path $rollbackReceipt 'authority-preimage/current-env.json') -PathType Leaf) 'the committed rollback keeps its own pre-rollback state preimage'
    $sourceReceiptPath = [string] $eligibleGraph.ReceiptPath
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath $sourceReceiptPath) -ceq 'COMPLETE') 'the committed rollback keeps the source activation receipt complete'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $sourceReceiptPath 'snapshot/claude/kept/SKILL.md')) -eq 'kept-old-custom-reasonix') 'the committed rollback never removes the source snapshot bytes it staged from'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $sourceReceiptPath 'snapshot/reasonix/pruned-custom-reasonix/SKILL.md')) -eq 'pruned-old-custom-reasonix') 'the committed rollback keeps the source snapshot of its add target'

    $stalePlan = Join-Path $work 'after-rollback-plan.json'
    $r = Invoke-GraphRollback -Graph $eligibleGraph -PlanPath $stalePlan
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-state-drift \(state hash\)') 'the executed source receipt is stale after its own rollback'
    Assert (-not (Test-Path -LiteralPath $stalePlan)) 'the post-rollback staleness rejection writes no plan'

    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $eligibleGraph.ReceiptPath, '-DryRun', '-PlanPath', $insideRepoPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'must be disjoint from worktree') 'a plan path inside the repository is rejected even for an eligible graph'
    Assert (-not (Test-Path -LiteralPath $insideRepoPlan)) 'the eligible-graph rejection writes no plan'

    Write-Host '[zero and single-target public rollback closure]'
    # Earlier activation/recovery evidence may still occupy the historical
    # shared names. Both a state-only rollback and a changed live target must
    # use their own namespace without deleting or replacing those entries.
    $legacyStagingEvidence = [ordered]@{}
    foreach ($relative in @('Claude/state-recovery/current-env.preimage.json', 'Claude/staged/kept/SKILL.md', 'Claude/swap/kept/SKILL.md')) {
        $path = [IO.Path]::GetFullPath((Join-Path $stagingBase $relative))
        if (-not $workOwned -or -not $path.StartsWith(([IO.Path]::GetFullPath($work) + [IO.Path]::DirectorySeparatorChar), [StringComparison]::OrdinalIgnoreCase)) {
            throw 'FAIL: legacy staging sentinel escaped the owned fixture'
        }
        $parent = Split-Path -Parent $path
        $cursor = $parent
        while (-not [string]::IsNullOrEmpty($cursor)) {
            try {
                if ([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) {
                    throw 'FAIL: legacy staging sentinel refuses a reparse ancestor'
                }
            }
            catch [IO.FileNotFoundException] { }
            catch [IO.DirectoryNotFoundException] { }
            $cursor = Split-Path -Parent $cursor
        }
        [IO.Directory]::CreateDirectory($parent) | Out-Null
        Assert-RollbackFixtureNoReparse -Path $parent -AncestorsOnly
        $bytes = [Text.Encoding]::UTF8.GetBytes('retained legacy staging evidence: ' + $relative)
        $stream = [IO.File]::Open($path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $legacyStagingEvidence[$path] = Get-SemanticJsonHash -InputObject (Get-SealedLiveObservableFileState -Path $path)
    }
    foreach ($targetCount in @(0, 1)) {
        $countGraph = New-SourceGraph ([ordered]@{ Label = "targets-$targetCount"; RollbackTargetCount = $targetCount })
        $countPlan = Join-Path $work "targets-$targetCount-plan.json"
        $r = Invoke-GraphRollback -Graph $countGraph -PlanPath $countPlan
        Assert ($r.Code -eq 0) "the $targetCount-target source produces a public rollback plan"
        $beforeCountState = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($statePath))
        $liveBeforeCount = @($beforeCountState['FinalResolvedIdentities'] | ForEach-Object { (Get-SafeTreeSnapshot -Root ([string] $_['ResolvedPath'])).TreeHash })
        $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $countGraph.ReceiptPath, '-Apply', '-PlanPath', $countPlan)
        if ($r.Code -ne 0) { Write-Host $r.Out }
        Assert ($r.Code -eq 0 -and $r.Out -match 'environment rollback applied:') "the public $targetCount-target rollback Apply exits zero"
        $afterCountState = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($statePath))
        Assert ([long] $afterCountState['AuthorityGeneration'] -eq ([long] $beforeCountState['AuthorityGeneration'] + 1)) "the $targetCount-target rollback advances the generation"
        Assert ([string] $afterCountState['LastOperationKind'] -ceq 'environment-rollback') "the $targetCount-target rollback publishes its authority state"
        $countJournal = Join-Path (Join-Path $controlBase 'live-transactions') ([string] $afterCountState['JournalId'])
        $countChain = Get-SealedLiveJournalChain -TransactionDirectory $countJournal
        Test-SealedLiveJournalChain -Header $countChain.Header -Records @($countChain.Records) -Result $countChain.Result -ResultFileHash $countChain.ResultFileHash
        $countTerminals = @($countChain.Records | Where-Object { $_['Document']['Phase'] -ceq 'COMPLETE' })
        Assert ($countTerminals.Count -eq 1 -and $countChain.Result['Outcome'] -ceq 'committed') "the $targetCount-target rollback has exactly one committed terminal"
        Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $countChain.Header['ReceiptIntent']['Path'])) -ceq 'COMPLETE') "the $targetCount-target rollback receipt is complete"
        $preparedTargets = @($countChain.Records | Where-Object { $_['Document']['Phase'] -ceq 'PREPARED' })
        Assert ($preparedTargets.Count -eq $targetCount) "the $targetCount-target rollback mutates the expected number of live targets"
        Assert (@(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot (Join-Path $controlBase 'live-transactions')).Count -eq 0) "the $targetCount-target rollback leaves no unfinished transaction"
        $countStaging = Get-RollbackTransactionStagingRoot -Chain $countChain
        Assert (@(Get-ChildItem -LiteralPath $countStaging -Recurse -Force -File).Count -eq 0) "the $targetCount-target rollback reclaims only its transaction scratch"
        foreach ($path in $legacyStagingEvidence.Keys) {
            Assert ((Get-SemanticJsonHash -InputObject (Get-SealedLiveObservableFileState -Path $path)) -ceq [string] $legacyStagingEvidence[$path]) "the $targetCount-target rollback preserves legacy staging bytes and entry identity"
        }
        if ($targetCount -eq 0) {
            $liveAfterCount = @($afterCountState['FinalResolvedIdentities'] | ForEach-Object { (Get-SafeTreeSnapshot -Root ([string] $_['ResolvedPath'])).TreeHash })
            Assert ((Get-SemanticJsonHash -InputObject $liveBeforeCount) -ceq (Get-SemanticJsonHash -InputObject $liveAfterCount)) 'zero-target rollback preserves all live tree bytes'
        }
    }

    Write-Host '[unfinished sibling transaction gate]'
    $guardGraph = New-SourceGraph ([ordered]@{ Label = 'sibling-guard'; RollbackTargetCount = 1 })
    $guardPlan = Join-Path $work 'sibling-guard-plan.json'
    $r = Invoke-GraphRollback -Graph $guardGraph -PlanPath $guardPlan
    Assert ($r.Code -eq 0) 'the sibling-gate source remains eligible and has a reviewed plan'
    $siblingFiles = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $rollbackJournal -File)) { $siblingFiles[$file.Name] = [IO.File]::ReadAllBytes($file.FullName) }
    $siblingRecords = @($siblingFiles.Keys | Where-Object { $_ -cmatch '^\d{6}\.json$' } | Sort-Object)
    foreach ($incompleteKind in @('header-only', 'receipt-complete', 'result-without-terminal', 'corrupt', 'unreadable', 'missing-header', 'hash-chain', 'terminal-hash', 'terminal-outcome', 'terminal-document', 'duplicate-terminal', 'unknown-entry')) {
        $keep = @('header.json')
        if ($incompleteKind -ceq 'receipt-complete') { $keep += $siblingRecords[0] }
        if ($incompleteKind -cnotin @('header-only', 'receipt-complete')) { $keep = @($siblingFiles.Keys) }
        if ($incompleteKind -ceq 'result-without-terminal') { $keep = @($keep | Where-Object { $_ -cne $siblingRecords[-1] }) }
        if ($incompleteKind -ceq 'missing-header') { $keep = @($keep | Where-Object { $_ -cne 'header.json' }) }
        foreach ($name in @($siblingFiles.Keys)) {
            $path = Join-Path $rollbackJournal $name
            if ($name -cin $keep) { [IO.File]::WriteAllBytes($path, [byte[]] $siblingFiles[$name]) }
            else { Remove-RollbackFixturePath -Path $path }
        }
        if ($incompleteKind -ceq 'corrupt') { Write-TextFile -Path (Join-Path $rollbackJournal 'header.json') -Content '{invalid-json' }
        if ($incompleteKind -cin @('hash-chain', 'terminal-hash', 'terminal-outcome', 'terminal-document')) {
            $changedName = if ($incompleteKind -ceq 'hash-chain') { $siblingRecords[0] } else { $siblingRecords[-1] }
            $changedRecord = ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString([byte[]] $siblingFiles[$changedName]))
            if ($incompleteKind -ceq 'hash-chain') { $changedRecord['PreviousHash'] = ('0' * 64) }
            elseif ($incompleteKind -ceq 'terminal-hash') { $changedRecord['Data']['ResultHash'] = ('0' * 64) }
            elseif ($incompleteKind -ceq 'terminal-outcome') { $changedRecord['Data']['Outcome'] = 'abandoned' }
            else {
                $changedRecord['Data']['OriginalDocumentHash'] = ('0' * 64)
                $changedRecord['Data']['ClosingDocumentHash'] = ('0' * 64)
            }
            Write-TextFile -Path (Join-Path $rollbackJournal $changedName) -Content (ConvertTo-Json -InputObject $changedRecord -Depth 64)
        }
        $extraSiblingPath = $null
        if ($incompleteKind -ceq 'duplicate-terminal') {
            $extraSiblingPath = Join-Path $rollbackJournal ('{0:d6}.json' -f ($siblingRecords.Count + 1))
            [IO.File]::WriteAllBytes($extraSiblingPath, [byte[]] $siblingFiles[$siblingRecords[-1]])
        }
        if ($incompleteKind -ceq 'unknown-entry') {
            $extraSiblingPath = Join-Path $rollbackJournal 'unknown.bin'
            Write-TextFile -Path $extraSiblingPath -Content 'unknown journal evidence'
        }
        $guardBefore = (Get-SafeTreeSnapshot -Root $authorityHome).TreeHash
        $unreadableHandle = $null
        try {
            if ($incompleteKind -ceq 'unreadable') { $unreadableHandle = [IO.File]::Open((Join-Path $rollbackJournal 'header.json'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None) }
            Assert (@(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot (Join-Path $controlBase 'live-transactions')) -ccontains ([string] $rollbackResult.TransactionId)) "the namespace scan treats the $incompleteKind sibling as unfinished"
            $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $guardGraph.ReceiptPath, '-Apply', '-PlanPath', $guardPlan)
        }
        finally { if ($null -ne $unreadableHandle) { $unreadableHandle.Dispose() } }
        if ($r.Code -eq 0 -or $r.Out -notmatch 'live-recovery-required: unfinished live transaction') { Write-Host $r.Out }
        Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-required: unfinished live transaction') "rollback refuses a $incompleteKind sibling while its selected source stays valid"
        Assert ((Get-SafeTreeSnapshot -Root $authorityHome).TreeHash -ceq $guardBefore) "the $incompleteKind refusal preserves live, state, journals, receipts and staging bytes"
        if ($null -ne $extraSiblingPath) { Remove-RollbackFixturePath -Path $extraSiblingPath }
    }
    # These cases temporarily changed only a test-owned completed journal.
    # Restore its captured bytes; actual recovery is exercised separately below.
    foreach ($name in @($siblingFiles.Keys)) { [IO.File]::WriteAllBytes((Join-Path $rollbackJournal $name), [byte[]] $siblingFiles[$name]) }
    Assert (@(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot (Join-Path $controlBase 'live-transactions')).Count -eq 0) 'closed sibling journals do not block rollback'

    $abandonId = [Guid]::NewGuid().ToString()
    $abandonReceiptId = [Guid]::NewGuid().ToString()
    $abandonHeader = ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString([byte[]] $siblingFiles['header.json']))
    $abandonHeader['TransactionId'] = $abandonId
    $abandonHeader['ReceiptIntent'] = [ordered]@{ Id = $abandonReceiptId; Path = (Join-Path $backupRoot $abandonReceiptId) }
    New-SealedLiveJournalHeader -Document $abandonHeader -TransactionDirectory (Join-Path (Join-Path $controlBase 'live-transactions') $abandonId) | Out-Null
    $abandonPlan = Join-Path $work 'sibling-abandon-plan.json'
    $recoveryScript = Join-Path $RepoRoot 'scripts/recover-live-transaction.ps1'
    foreach ($mode in @('-DryRun', '-Apply')) {
        $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $recoveryScript -Arguments @('-Action', 'abandon', '-TransactionId', $abandonId, $mode, '-PlanPath', $abandonPlan, '-RepoRoot', $RepoRoot) -AuthorityRepoRoot $RepoRoot
        if ($r.Code -ne 0) { Write-Host $r.Out }
        Assert ($r.Code -eq 0) "reviewed sibling abandonment succeeds on $mode"
    }
    Assert (@(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot (Join-Path $controlBase 'live-transactions')).Count -eq 0) 'reviewed recovery clears the unfinished sibling'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $guardGraph.ReceiptPath, '-Apply', '-PlanPath', $guardPlan)
    if ($r.Code -ne 0) { Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'environment rollback applied:') 'a normal public rollback succeeds after the sibling recovery closes'

    Write-Host '[rollback failure preservation]'
    function Get-RollbackTransactionChain {
        param([Parameter(Mandatory)] [string] $PlanPath)
        $planDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($PlanPath, [System.Text.UTF8Encoding]::new($false, $true)))
        foreach ($directory in @(Get-ChildItem -LiteralPath (Join-Path $controlBase 'live-transactions') -Directory -Force)) {
            $candidateChain = Get-SealedLiveJournalChain -TransactionDirectory $directory.FullName
            if ($null -eq $candidateChain.Header) { continue }
            if ([string] $candidateChain.Header['OperationKind'] -ceq 'environment-rollback' -and
                [string] $candidateChain.Header['OriginalDocumentHash'] -ceq [string] $planDocument['DocumentHash']) {
                return $candidateChain
            }
        }
        throw 'FAIL: no environment-rollback journal was published for the plan'
    }

    # (a) A restore-path failure runs no cleanup at all. The restore source of
    # the add target is removed from the source receipt after the plan was
    # derived, so the engine fails while staging that target -- after the
    # update and prune targets completed -- restores every installed target in
    # reverse and closes with failed-restored. The staged copy the restoration
    # moved back, the journal, the pre-rollback receipt and both receipts stay
    # on disk.
    $restoreFailureGraph = New-SourceGraph ([ordered]@{ Label = 'restore-failure' })
    $restoreFailurePlan = Join-Path $work 'restore-failure-plan.json'
    $r = Invoke-GraphRollback -Graph $restoreFailureGraph -PlanPath $restoreFailurePlan
    Assert ($r.Code -eq 0 -and $r.Out -match 'environment rollback plan created') 'the restore-failure source graph derives its rollback plan'
    Remove-RollbackFixturePath -Path (Join-Path ([string] $restoreFailureGraph.ReceiptPath) 'snapshot/reasonix/pruned-restore-failure')
    $r = Invoke-RollbackExecution -PlanPath $restoreFailurePlan -SourceReceiptPath ([string] $restoreFailureGraph.ReceiptPath)
    if ($r.Code -eq 0 -or $r.Out -notmatch 'apply-failed-but-restored') {
        Write-Host '----- restore-failure execution output -----'
        Write-Host $r.Out
    }
    Assert ($r.Code -ne 0 -and $r.Out -match 'apply-failed-but-restored') 'the failed rollback restores the surface and reports apply-failed-but-restored'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $graphLiveRoot 'claude/skills/kept/SKILL.md')) -eq 'kept-new-restore-failure') 'the failed rollback restores its update target to the pre-rollback bytes'
    Assert (Test-Path -LiteralPath (Join-Path $graphLiveRoot 'codex/skills/added-restore-failure/SKILL.md') -PathType Leaf) 'the failed rollback restores its pruned target'
    $restoreFailureChain = Get-RollbackTransactionChain -PlanPath $restoreFailurePlan
    $restoreFailureStaging = Get-RollbackTransactionStagingRoot -Chain $restoreFailureChain
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $restoreFailureStaging 'Claude/staged/kept/SKILL.md')) -eq 'kept-old-restore-failure') 'the failed rollback keeps the staged copy its restoration moved back'
    Assert (@(Get-ChildItem -LiteralPath $restoreFailureStaging -Recurse -Force -File).Count -gt 0) 'the failed rollback leaves its staging evidence on disk'
    $null = Test-SealedLiveJournalChain -Header $restoreFailureChain.Header -Records @($restoreFailureChain.Records) -Result $restoreFailureChain.Result -ResultFileHash $restoreFailureChain.ResultFileHash
    Assert ([string] $restoreFailureChain.Result['Outcome'] -ceq 'failed-restored') 'the failed rollback publishes the failed-restored result'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $restoreFailureChain.Header['ReceiptIntent']['Path'])) -ceq 'COMPLETE') 'the failed rollback keeps its own complete pre-rollback receipt'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $restoreFailureGraph.ReceiptPath)) -ceq 'COMPLETE') 'the failed rollback keeps the source activation receipt'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path ([string] $restoreFailureGraph.ReceiptPath) 'snapshot/claude/kept/SKILL.md')) -eq 'kept-old-restore-failure') 'the failed rollback keeps the source snapshot bytes it staged from'

    # Keep the failed transaction's evidence throughout the next transaction
    # and its public recovery. New rollback namespaces must not need a manual
    # removal of an earlier transaction's staged/swap-old entries.
    $restoreFailureEvidence = Get-SemanticJsonHash -InputObject (Get-SafeTreeSnapshot -Root $restoreFailureStaging)

    # (b) A failure after the authority state boundary is recovery-required:
    # the engine never rewrites live/state again and restores nothing, so the
    # swap-old entries and the pre-rollback state-recovery copy must all
    # survive. The injected checkpoint fails the transaction inside the window
    # after STATE_PUBLISHED through an unreachable failpoint pipe.
    $recoveryGraph = New-SourceGraph ([ordered]@{ Label = 'recovery-required' })
    $recoveryPlan = Join-Path $work 'recovery-required-plan.json'
    $r = Invoke-GraphRollback -Graph $recoveryGraph -PlanPath $recoveryPlan
    Assert ($r.Code -eq 0 -and $r.Out -match 'environment rollback plan created') 'the recovery-required source graph derives its rollback plan'
    $beforeRecoveryStateHash = (Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $beforeRecoveryState = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($statePath))
    $beforeRecoveryLive = @($beforeRecoveryState['FinalResolvedIdentities'] | ForEach-Object { (Get-SafeTreeSnapshot -Root ([string] $_['ResolvedPath'])).TreeHash })
    $savedFailpoints = [System.Environment]::GetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS')
    try {
        [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', (ConvertTo-Json -InputObject @([ordered]@{ Checkpoint = 'STATE_PUBLISHED'; PipeName = ('ai-agent-dotfiles-absent-' + [Guid]::NewGuid().ToString('N')) }) -Compress))
        $r = Invoke-RollbackExecution -PlanPath $recoveryPlan -SourceReceiptPath ([string] $recoveryGraph.ReceiptPath)
    }
    finally {
        [System.Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS', $savedFailpoints)
    }
    if ($r.Code -eq 0 -or $r.Out -notmatch 'live-transaction-recovery-required') {
        Write-Host '----- recovery-required execution output -----'
        Write-Host $r.Out
    }
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-transaction-recovery-required') 'a failure after the state boundary requires recovery instead of a restore'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $graphLiveRoot 'claude/skills/kept/SKILL.md')) -eq 'kept-old-recovery-required') 'the recovery-required rollback keeps the live targets it installed'
    $recoveryChain = Get-RollbackTransactionChain -PlanPath $recoveryPlan
    $recoveryStaging = Get-RollbackTransactionStagingRoot -Chain $recoveryChain
    Assert ($recoveryStaging -cne $restoreFailureStaging) 'successive rollback attempts use distinct transaction staging namespaces'
    Assert (Test-Path -LiteralPath (Join-Path $recoveryStaging 'Claude/swap/kept')) 'the recovery-required rollback keeps the swap-old entry of its update target'
    Assert (Test-Path -LiteralPath (Join-Path $recoveryStaging 'Codex/swap/added-recovery-required')) 'the recovery-required rollback keeps the swap-old entry of its prune target'
    Assert (Test-Path -LiteralPath (Join-Path $recoveryStaging 'Claude/state-recovery/current-env.preimage.json') -PathType Leaf) 'the recovery-required rollback keeps the pre-rollback state-recovery copy'
    Assert ($null -eq $recoveryChain.Result) 'the recovery-required rollback publishes no result'
    Assert (@(@($recoveryChain.Records) | Where-Object { [string] ([System.Collections.IDictionary] $_['Document'])['Phase'] -ceq 'COMPLETE' }).Count -eq 0) 'the recovery-required rollback publishes no terminal record'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $recoveryChain.Header['ReceiptIntent']['Path'])) -ceq 'COMPLETE') 'the recovery-required rollback keeps its own complete pre-rollback receipt'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $recoveryGraph.ReceiptPath)) -ceq 'COMPLETE') 'the recovery-required rollback keeps the source activation receipt'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path ([string] $recoveryGraph.ReceiptPath) 'snapshot/claude/kept/SKILL.md')) -eq 'kept-old-recovery-required') 'the recovery-required rollback keeps the source snapshot bytes it staged from'
    Assert ((Get-SemanticJsonHash -InputObject (Get-SafeTreeSnapshot -Root $restoreFailureStaging)) -ceq $restoreFailureEvidence) 'the next failed rollback preserves the earlier failure staging bytes and identities'

    # STATE_PUBLISHED precedes POSTCONDITIONS_OK, so this transaction requires
    # rollback recovery. The public reviewed plan must read the journal-bound
    # private state copy and restore both state and live targets from it.
    $recoveryTransactionId = [string] $recoveryChain.Header['TransactionId']
    $privateRecoveryPlan = Join-Path $work 'private-staging-recovery-plan.json'
    $statePreimageBinding = Get-SealedLiveAuthorityStatePreimageBinding -Records @($recoveryChain.Records) -ExpectedTargetPath $statePath
    Assert ([string] $statePreimageBinding.PreimageCopy -ceq (Join-Path $recoveryStaging 'Claude/state-recovery/current-env.preimage.json')) 'the unfinished journal binds the state preimage in its own transaction staging'
    $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $recoveryScript -Arguments @('-Action', 'rollback', '-TransactionId', $recoveryTransactionId, '-DryRun', '-PlanPath', $privateRecoveryPlan, '-RepoRoot', $RepoRoot) -AuthorityRepoRoot $RepoRoot
    if ($r.Code -ne 0) { Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'live recovery plan created') 'public recovery derives a reviewed plan for the transaction-private staging'
    $privateRecoveryDocument = ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($privateRecoveryPlan))
    $privateRecoveryPayload = [System.Collections.IDictionary] $privateRecoveryDocument['PlanPayload']
    Assert ([string] $privateRecoveryPayload['AuthorityStatePreimagePath'] -ceq [string] $statePreimageBinding.PreimageCopy) 'the public recovery plan binds the exact journal preimage path'
    Assert ([string] $privateRecoveryPayload['AuthorityStatePreimage']['Hash'] -ceq $beforeRecoveryStateHash) 'the public recovery plan binds the pre-rollback state bytes'
    $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $recoveryScript -Arguments @('-Action', 'rollback', '-TransactionId', $recoveryTransactionId, '-Apply', '-PlanPath', $privateRecoveryPlan, '-RepoRoot', $RepoRoot) -AuthorityRepoRoot $RepoRoot
    if ($r.Code -ne 0) { Write-Host $r.Out }
    Assert ($r.Code -eq 0 -and $r.Out -match 'live recovery applied: rollback .*\(outcome=rolled-back\)') 'public recovery restores the transaction-private staging and closes the rollback'
    Assert ((Get-FileHash -LiteralPath $statePath -Algorithm SHA256).Hash.ToLowerInvariant() -ceq $beforeRecoveryStateHash) 'public recovery restores the exact pre-rollback authority state bytes'
    $afterRecoveryLive = @($beforeRecoveryState['FinalResolvedIdentities'] | ForEach-Object { (Get-SafeTreeSnapshot -Root ([string] $_['ResolvedPath'])).TreeHash })
    Assert ((Get-SemanticJsonHash -InputObject $afterRecoveryLive) -ceq (Get-SemanticJsonHash -InputObject $beforeRecoveryLive)) 'public recovery restores every live tree from the transaction-private swap paths'
    $recoveredChain = Get-RollbackTransactionChain -PlanPath $recoveryPlan
    $null = Test-SealedLiveJournalChain -Header $recoveredChain.Header -Records @($recoveredChain.Records) -Result $recoveredChain.Result -ResultFileHash $recoveredChain.ResultFileHash
    $recoveredTerminals = @($recoveredChain.Records | Where-Object { $_['Document']['Phase'] -ceq 'COMPLETE' })
    Assert ($recoveredTerminals.Count -eq 1 -and $recoveredChain.Result['Outcome'] -ceq 'rolled-back') 'public recovery publishes one validated rolled-back terminal'
    Assert (@(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot (Join-Path $controlBase 'live-transactions')).Count -eq 0) 'public recovery leaves no unfinished transaction'
    Assert ((Get-SemanticJsonHash -InputObject (Get-SafeTreeSnapshot -Root $restoreFailureStaging)) -ceq $restoreFailureEvidence) 'public recovery preserves the earlier failure staging bytes and identities'
    foreach ($path in $legacyStagingEvidence.Keys) {
        Assert ((Get-SemanticJsonHash -InputObject (Get-SealedLiveObservableFileState -Path $path)) -ceq [string] $legacyStagingEvidence[$path]) 'public recovery preserves legacy staging bytes and entry identity'
    }
    if ($Section -ceq 'rollback-staging') {
        Write-Host 'backup recovery staging tests: PASS'
        return
    }

    # A receipt whose linked source transaction never existed is rejected even
    # though its own marker and hashes are valid.
    $orphanReceipt = New-PreflightReceipt -SourceOperationKind 'environment' -Label 'orphan' -WithAuthorityStatePreimage
    $orphanPlan = Join-Path $work 'orphan-plan.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $orphanReceipt, '-DryRun', '-PlanPath', $orphanPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-transaction-missing') 'a receipt without a linked source journal fails closed'
    Assert (-not (Test-Path -LiteralPath $orphanPlan)) 'the orphan-receipt rejection writes no plan'

    # A receipt whose authority preimage was never captured cannot name a
    # rollback destination.
    $missingPreimageGraph = New-SourceGraph ([ordered]@{ Label = 'missing-preimage'; MissingAuthorityPreimage = $true })
    $r = Invoke-GraphRollback -Graph $missingPreimageGraph -PlanPath (Join-Path $work 'missing-preimage-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-preimage-missing \(AuthorityStatePreimage\)') 'a receipt with a missing authority preimage fails closed'

    Write-Host '[receipt and backup integrity rejections]'
    $eligibleReceiptPath = [string] $eligibleGraph.ReceiptPath

    # The receipt binds its own absolute path: a relocated copy of the exact
    # receipt bytes is a tampered receipt even with an unchanged manifest.
    $relocatedReceipt = Join-Path $work 'relocated-receipt'
    Copy-Item -LiteralPath $eligibleReceiptPath -Destination $relocatedReceipt -Recurse -Force
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $relocatedReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-tampered \(receipt path\)') 'a relocated receipt copy fails closed on its path binding'

    # In-place mutations on the eligible receipt are ordered by the reviewed
    # gate sequence so each case is observed at its own layer.
    $driftedSkill = Join-Path $eligibleReceiptPath 'snapshot/claude/kept/SKILL.md'
    $driftedOriginal = Get-Content -Raw -LiteralPath $driftedSkill
    Write-TextFile -Path $driftedSkill -Content ($driftedOriginal + 'drift')
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $eligibleReceiptPath, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-backup-drift \(Claude snapshot root\)') 'modified backup bytes with an unchanged manifest fail closed'
    Write-TextFile -Path $driftedSkill -Content $driftedOriginal

    $preimageStateCopy = Join-Path $eligibleReceiptPath 'authority-preimage/current-env.json'
    $preimageStateOriginal = Get-Content -Raw -LiteralPath $preimageStateCopy
    Write-TextFile -Path $preimageStateCopy -Content ($preimageStateOriginal + ' ')
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $eligibleReceiptPath, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-preimage-tampered \(AuthorityStatePreimage\)') 'a tampered authority preimage copy fails closed'
    Write-TextFile -Path $preimageStateCopy -Content $preimageStateOriginal

    $claimsPreimageCopy = Join-Path $eligibleReceiptPath 'authority-preimage/root-claims.json'
    $claimsPreimageOriginal = Get-Content -Raw -LiteralPath $claimsPreimageCopy
    Write-TextFile -Path $claimsPreimageCopy -Content ($claimsPreimageOriginal + ' ')
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $eligibleReceiptPath, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-preimage-tampered \(RootClaimsPreimage\)') 'a tampered claims preimage copy fails closed'

    Write-TextFile -Path (Join-Path $eligibleReceiptPath '_meta/COMPLETE') -Content ('f' * 64)
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $eligibleReceiptPath, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-tampered \(complete marker\)') 'a complete marker that disagrees with the receipt hash fails closed'

    function Edit-ReceiptDocument {
        param([Parameter(Mandatory)] [string] $ReceiptPath, [Parameter(Mandatory)] [scriptblock] $Mutate)
        $documentPath = Join-Path $ReceiptPath '_meta/receipt.json'
        $document = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($documentPath, [System.Text.UTF8Encoding]::new($false, $true)))
        & $Mutate $document
        Write-TextFile -Path $documentPath -Content ((ConvertTo-Json -InputObject $document -Depth 40) + "`n")
    }

    Edit-ReceiptDocument -ReceiptPath $eligibleReceiptPath -Mutate { param($Document) $Document['ReceiptHash'] = ('f' * 64) }
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $eligibleReceiptPath, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-tampered') 'a tampered receipt self-hash fails closed'

    Edit-ReceiptDocument -ReceiptPath $eligibleReceiptPath -Mutate { param($Document) $Document.Remove('CreatedAtUtc') }
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $eligibleReceiptPath, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-not-complete \(missing CreatedAtUtc\)') 'an incomplete receipt document fails closed'

    Write-Host '[source-graph binding rejections]'
    $foreignHomeGraph = New-SourceGraph ([ordered]@{ Label = 'foreign-home'; ReceiptHomeAuthorityKey = ('b' * 64) })
    $r = Invoke-GraphRollback -Graph $foreignHomeGraph -PlanPath (Join-Path $work 'foreign-home-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-home-authority-mismatch') 'a receipt bound to another HomeRoot fails closed'

    $originGraph = New-SourceGraph ([ordered]@{ Label = 'origin-mismatch'; OriginOverride = $true })
    $r = Invoke-GraphRollback -Graph $originGraph -PlanPath (Join-Path $work 'origin-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-origin-mismatch \(repo identity\)') 'a source transaction from another repository origin fails closed'
    Assert (-not (Test-Path -LiteralPath (Join-Path $work 'origin-plan.json'))) 'the origin-mismatch rejection writes no plan'

    # A source header that binds a FOREIGN worktree overlay identity can only be
    # rolled back from the worktree that held that lock: refused as an origin
    # mismatch, never skipping the second lock.
    $overlayGraph = New-SourceGraph ([ordered]@{ Label = 'overlay-lock'; OverlayLockHeader = $true })
    $r = Invoke-GraphRollback -Graph $overlayGraph -PlanPath (Join-Path $work 'overlay-lock-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-origin-mismatch \(overlay lock\)') 'a source header that binds a foreign worktree overlay lock fails closed as an origin mismatch'
    Assert (-not (Test-Path -LiteralPath (Join-Path $work 'overlay-lock-plan.json'))) 'the foreign-overlay rejection writes no plan'

    # The same source transaction with THIS worktree's exact overlay identity is
    # rollback-able: DryRun derives the reviewed plan under the full lock order
    # (canonical -> worktree overlay -> global).
    $originOverlayGraph = New-SourceGraph ([ordered]@{ Label = 'overlay-origin'; OverlayLockHeaderOrigin = $true })
    $originOverlayPlan = Join-Path $work 'overlay-origin-plan.json'
    $r = Invoke-GraphRollback -Graph $originOverlayGraph -PlanPath $originOverlayPlan
    if ($r.Code -ne 0) { Write-Host '----- origin overlay rollback dry-run output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0) 'a source header that binds this worktree overlay identity derives the reviewed plan'
    Assert (Test-Path -LiteralPath $originOverlayPlan -PathType Leaf) 'the origin-overlay dry-run writes its plan'

    # Use an explicit independent unfinished sibling: the earlier failure now
    # closes through public recovery before later source graphs change state.
    # A valid selected source and overlay lock still cannot bypass this gate.
    $originSiblingId = [Guid]::NewGuid().ToString()
    $originSiblingReceiptId = [Guid]::NewGuid().ToString()
    $originSiblingHeader = ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString([byte[]] $siblingFiles['header.json']))
    $originSiblingHeader['TransactionId'] = $originSiblingId
    $originSiblingHeader['ReceiptIntent'] = [ordered]@{ Id = $originSiblingReceiptId; Path = (Join-Path $backupRoot $originSiblingReceiptId) }
    New-SealedLiveJournalHeader -Document $originSiblingHeader -TransactionDirectory (Join-Path (Join-Path $controlBase 'live-transactions') $originSiblingId) | Out-Null
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $originOverlayGraph.ReceiptPath, '-Apply', '-PlanPath', $originOverlayPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-recovery-required: unfinished live transaction') 'origin-overlay Apply respects the unfinished sibling gate under the full lock order'
    $originSiblingPlan = Join-Path $work 'origin-overlay-sibling-abandon-plan.json'
    foreach ($mode in @('-DryRun', '-Apply')) {
        $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $recoveryScript -Arguments @('-Action', 'abandon', '-TransactionId', $originSiblingId, $mode, '-PlanPath', $originSiblingPlan, '-RepoRoot', $RepoRoot) -AuthorityRepoRoot $RepoRoot
        if ($r.Code -ne 0) { Write-Host $r.Out }
        Assert ($r.Code -eq 0) "the origin-overlay gate's explicit sibling closes through reviewed abandonment on $mode"
    }
    Assert (@(Get-SealedLiveJournalUnfinishedTransactionIds -TransactionsRoot (Join-Path $controlBase 'live-transactions')).Count -eq 0) 'the origin-overlay gate leaves no unfinished fixture transaction'

    $overlayGraph = New-SourceGraph ([ordered]@{ Label = 'overlay-drift'; OverlayDrift = $true })
    $r = Invoke-GraphRollback -Graph $overlayGraph -PlanPath (Join-Path $work 'overlay-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-overlay-drift \(overlay hash\)') 'a source transaction whose preimage overlay baseline differs from its poststate fails closed'

    $wrongRootGraph = New-SourceGraph ([ordered]@{ Label = 'wrong-reasonix'; WrongReasonixLiveRoot = $true })
    $r = Invoke-GraphRollback -Graph $wrongRootGraph -PlanPath (Join-Path $work 'wrong-root-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-live-root-drift \(Reasonix root\)') 'a receipt recorded against a different Reasonix root fails closed'

    $reservedGraph = New-SourceGraph ([ordered]@{ Label = 'reserved'; ReserveOnly = $true })
    $r = Invoke-GraphRollback -Graph $reservedGraph -PlanPath (Join-Path $work 'reserved-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-transaction-unfinished') 'a receipt linked to a header-only reservation fails closed'

    $restoredGraph = New-SourceGraph ([ordered]@{ Label = 'failed-restored'; FailMode = 'failed-restored' })
    Assert ([string] $restoredGraph.Outcome -ceq 'failed-restored') 'the failing produce run publishes a failed-restored terminal'
    $r = Invoke-GraphRollback -Graph $restoredGraph -PlanPath (Join-Path $work 'restored-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-outcome-unsupported \(outcome=failed-restored\)') 'a failed-restored source transaction cannot start a rollback'

    Write-Host '[root transition rejection]'
    # A forged default→custom Reasonix transition after a claim exists: the
    # header binds the claims of a different root, and the immutable claims
    # proof rejects the transaction after restoring every installed target.
    $transitionGraph = New-SourceGraph ([ordered]@{ Label = 'root-transition'; RootTransitionReasonix = $true })
    Assert ([string] $transitionGraph.Outcome -ceq 'failed-restored') 'the root transition attempt closes failed-restored'
    $transitionClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([System.IO.File]::ReadAllBytes($claimsPath))).ToLowerInvariant()
    $transitionReceipt = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Join-Path ([string] $transitionGraph.ReceiptPath) '_meta/receipt.json'), [System.Text.UTF8Encoding]::new($false, $true)))
    Assert ($transitionClaimsHash -ceq [string] $transitionReceipt['RootClaimsPreimage']['Hash']) 'the immutable claims bytes are unchanged by the rejected transition'
    $transitionRoot = Join-Path $authorityHome 'source-graph-root-transition/transition-reasonix/skills'
    Assert (@(Get-ChildItem -LiteralPath $transitionRoot -Force -ErrorAction SilentlyContinue).Count -eq 0) 'the proposed transition root was never claimed or populated'
    Assert (Test-Path -LiteralPath (Join-Path ([string] $transitionGraph.ReasonixLiveRoot) "pruned-root-transition/SKILL.md") -PathType Leaf) 'the transition attempt restores its pruned target'
    $r = Invoke-GraphRollback -Graph $transitionGraph -PlanPath (Join-Path $work 'transition-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-outcome-unsupported \(outcome=failed-restored\)') 'a rejected transition receipt cannot start a rollback'

    $tamperedGraph = New-SourceGraph ([ordered]@{ Label = 'chain-tamper' })
    $tamperedRecordPath = Join-Path (Join-Path (Join-Path $controlBase 'live-transactions') ([string] $tamperedGraph.TransactionId)) '000001.json'
    $tamperedRecord = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($tamperedRecordPath, [System.Text.UTF8Encoding]::new($false, $true)))
    $tamperedRecord['Data']['ReceiptRef']['Hash'] = ('0' * 64)
    Write-TextFile -Path $tamperedRecordPath -Content ((ConvertTo-Json -InputObject $tamperedRecord -Depth 40) + "`n")
    $r = Invoke-GraphRollback -Graph $tamperedGraph -PlanPath (Join-Path $work 'tampered-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-transaction-tampered') 'a tampered source journal fails closed'

    Write-Host '[two backups: later generation and staleness]'
    $staleGraph = New-SourceGraph ([ordered]@{ Label = 'stale-first' })
    $laterGraph = New-SourceGraph ([ordered]@{ Label = 'later-generation' })
    $laterPlan = Join-Path $work 'later-plan.json'
    $r = Invoke-GraphRollback -Graph $laterGraph -PlanPath $laterPlan
    Assert ($r.Code -eq 0 -and $r.Out -match 'environment rollback plan created') 'the latest receipt derives its rollback plan while two backups exist'
    $r = Invoke-GraphRollback -Graph $staleGraph -PlanPath (Join-Path $work 'stale-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-state-drift \(state hash\)') 'the superseded earlier receipt is stale against the later generation'
    Assert (-not (Test-Path -LiteralPath (Join-Path $work 'stale-plan.json'))) 'the stale-receipt rejection writes no plan'

    Write-Host '[authority drift rejections]'
    Write-TextFile -Path ([string] $laterGraph.StatePath) -Content ((Get-Content -Raw -LiteralPath ([string] $laterGraph.StatePath)) + ' ')
    $r = Invoke-GraphRollback -Graph $laterGraph -PlanPath (Join-Path $work 'state-drift-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-state-drift \(state hash\)') 'changed current state bytes fail closed'

    Write-TextFile -Path ([string] $laterGraph.ClaimsPath) -Content ((Get-Content -Raw -LiteralPath ([string] $laterGraph.ClaimsPath)) + ' ')
    $r = Invoke-GraphRollback -Graph $laterGraph -PlanPath (Join-Path $work 'claims-drift-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-claims-drift') 'changed current claims bytes fail closed'

    # The live-root replacement runs last: it changes the claimed directory
    # identity, so no further source graph could be built on this sandbox.
    Write-Host '[current surface drift rejections]'
    $liveDriftGraph = New-SourceGraph ([ordered]@{ Label = 'live-drift' })
    $reasonixRoot = [string] $liveDriftGraph.ReasonixLiveRoot
    $preservedRoot = Join-Path $work 'reasonix-preserved'
    Copy-Item -LiteralPath $reasonixRoot -Destination $preservedRoot -Recurse -Force
    Remove-RollbackFixturePath -Path $reasonixRoot
    New-Item -ItemType Directory -Force -Path $reasonixRoot | Out-Null
    Copy-Item -Path (Join-Path $preservedRoot '*') -Destination $reasonixRoot -Recurse -Force
    $r = Invoke-GraphRollback -Graph $liveDriftGraph -PlanPath (Join-Path $work 'live-drift-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-live-root-drift \(Reasonix identity\)') 'a replaced live root fails closed even with identical content'

    Write-Host '[final reviewed-plan gate]'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $laterGraph.ReceiptPath, '-Apply', '-PlanPath', (Join-Path $work 'apply-plan.json'))
    Assert ($r.Code -ne 0 -and $r.Out -match 'Artifact or evidence path is missing') 'sandbox rollback Apply requires an existing reviewed plan for an eligible source'

    Write-Host 'backup recovery tests: PASS'
}
finally {
    if ($workOwned -and (Test-Path -LiteralPath $work)) {
        Remove-RollbackFixturePath -Path $work
    }
}
