#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-backup-recovery-$([Guid]::NewGuid().ToString('N'))"
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')
. (Join-Path $RepoRoot 'tests/helpers/safety-sandbox.ps1')

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

try {
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
        'rollback-live-root-drift', 'rollback-plan-missing', 'rollback-plan-mismatch',
        'worktree-overlay-lock-not-implemented', 'live-rollback-dispatch-not-wired'
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

    # -Apply stays behind the Phase 0 production interlock.
    $environmentReceipt = New-PreflightReceipt -SourceOperationKind 'environment' -Label 'environment'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-Apply', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'safety-protocol-upgrade-required') 'the rollback Apply remains interlocked'

    # A complete environment receipt without a captured authority preimage
    # cannot name a rollback destination even though its own marker is valid.
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-preimage-missing \(AuthorityStatePreimage\)') 'a receipt with a missing authority preimage fails closed'

    # The shared private-artifact-path table rejects output paths inside the
    # repository before any receipt evidence is interpreted.
    $insideRepoPlan = Join-Path $RepoRoot 'rollback-plan-inside-repo.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $insideRepoPlan)
    Assert ($r.Code -ne 0 -and $r.Out -notmatch 'live-rollback-dispatch-not-wired') 'a plan path inside the repository is rejected by the shared artifact-path table'
    Assert (-not (Test-Path -LiteralPath $insideRepoPlan)) 'the rejected plan path is never written'
    $insideRepoJson = Join-Path $RepoRoot 'rollback-report-inside-repo.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $absentPlan, '-JsonPath', $insideRepoJson)
    Assert ($r.Code -ne 0 -and $r.Out -notmatch 'live-rollback-dispatch-not-wired') 'a report path inside the repository is rejected by the shared artifact-path table'
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
Write-GraphTextFile -Path (Join-Path $sourceRoots['Claude'] 'kept/SKILL.md') -Content "kept-new-$label"
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
        Targets = @([ordered]@{ Name = "added-$label"; LivePath = (Join-Path $liveRoots['Codex'] "added-$label"); PlannedTreeHash = $null })
    },
    [ordered]@{
        Platform = 'Reasonix'
        LiveRoot = $reasonixReceiptRoot
        Targets = @($reasonixReceiptTargets)
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
    RootClaimsHash = $claimsHash
    ReceiptIntent = [ordered]@{ Id = $receiptId; Path = $receiptPath }
    Targets = @()
}
if ([bool] $spec['OverlayLockHeader']) { $header['WorktreeOverlayLockKey'] = ('8' * 64) }
$transactionDirectory = Join-Path (Join-Path $controlBase 'live-transactions') $transactionId
New-SealedLiveJournalHeader -Document $header -TransactionDirectory $transactionDirectory | Out-Null

$graphOutcome = 'reserved'
if (-not $reserveOnly) {
    $keptOldHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveRoots['Claude'] 'kept')).TreeHash
    $keptNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceRoots['Claude'] 'kept')).TreeHash
    $addedNewHash = (Get-SafeTreeSnapshot -Root (Join-Path $sourceRoots['Codex'] "added-$label")).TreeHash
    $actions = @(
        [ordered]@{ Platform = 'Claude'; Action = 'update'; Name = 'kept'; SourceHash = $keptNewHash; LiveHash = $keptOldHash },
        [ordered]@{ Platform = 'Codex'; Action = 'add'; Name = "added-$label"; SourceHash = $addedNewHash; LiveHash = $null }
    )
    if (-not $wrongReasonixRoot) {
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

    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $eligibleGraph.ReceiptPath, '-DryRun', '-PlanPath', $insideRepoPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'must be disjoint from worktree') 'a plan path inside the repository is rejected even for an eligible graph'
    Assert (-not (Test-Path -LiteralPath $insideRepoPlan)) 'the eligible-graph rejection writes no plan'

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

    $overlayGraph = New-SourceGraph ([ordered]@{ Label = 'overlay-lock'; OverlayLockHeader = $true })
    $r = Invoke-GraphRollback -Graph $overlayGraph -PlanPath (Join-Path $work 'overlay-lock-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'worktree-overlay-lock-not-implemented') 'a source header that binds the worktree overlay lock fails closed until the Phase 3 primitive'
    Assert (-not (Test-Path -LiteralPath (Join-Path $work 'overlay-lock-plan.json'))) 'the overlay-lock rejection writes no plan'

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
    Remove-Item -LiteralPath $reasonixRoot -Recurse -Force
    New-Item -ItemType Directory -Force -Path $reasonixRoot | Out-Null
    Copy-Item -Path (Join-Path $preservedRoot '*') -Destination $reasonixRoot -Recurse -Force
    $r = Invoke-GraphRollback -Graph $liveDriftGraph -PlanPath (Join-Path $work 'live-drift-plan.json')
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-live-root-drift \(Reasonix identity\)') 'a replaced live root fails closed even with identical content'

    Write-Host '[final interlock]'
    # The interlocked Apply still rejects a valid eligible graph before any
    # of the source-graph evidence is interpreted.
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', [string] $laterGraph.ReceiptPath, '-Apply', '-PlanPath', (Join-Path $work 'apply-plan.json'))
    Assert ($r.Code -ne 0 -and $r.Out -match 'safety-protocol-upgrade-required') 'the rollback Apply remains interlocked for an eligible graph'

    Write-Host 'backup recovery tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
