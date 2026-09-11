#requires -Version 7.0
<#
.SYNOPSIS
    Read-only recovery status locator and fixed public dispatcher for live
    transaction journals.

.DESCRIPTION
    The status scan reads every transaction journal under
    <ControlBase>\live-transactions and reports, per transaction, exactly one
    recovery status: abandon-eligible, rollback-required, finalize-eligible,
    or manual-recovery-required. An overall status of clean is reported when
    nothing is unfinished. The scan is strictly read-only: journals are
    enumerated and read with immediate open/close (no retained handles), and
    nothing is renamed, deleted, or written. Missing, ambiguous, or
    unresolvable evidence fails closed as manual-recovery-required.

    The abandon/rollback/finalize modes are the Task 6 Step 3 dispatcher.
    They resolve the caller's repository as the origin candidate, require the
    sandbox-injected authority with its complete bootstrap prefix, acquire the
    origin canonical/overlay/global lock order, and re-find and revalidate the
    exact transaction under those locks. -DryRun derives the schema-1
    rollback/recovery plan from the journal evidence and writes it create-new
    to -PlanPath. -Apply validates the reviewed plan fail-closed under the
    held locks (semantics, kind/transaction match, and the derived journal
    head) and currently stops at live-recovery-dispatch-not-wired; the
    reviewed transitions execute in the remaining Step 3 slices.

    All routes resolve the live surface only inside the internal sandbox;
    production resolution arrives with the reviewed live-safety release.
#>
[CmdletBinding(DefaultParameterSetName = 'Status')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Status')] [switch] $Status,
    [Parameter(ParameterSetName = 'Status')] [string] $ControlBase,
    [Parameter(ParameterSetName = 'Status')] [string] $JsonPath,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidateSet('abandon', 'rollback', 'finalize')] [string] $Action,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')]
    [ValidatePattern('^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')] [string] $TransactionId,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')] [switch] $DryRun,
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [switch] $Apply,
    [Parameter(Mandatory, ParameterSetName = 'DryRun')]
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $PlanPath,
    [Parameter(ParameterSetName = 'DryRun')]
    [Parameter(ParameterSetName = 'Apply')] [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'backup-receipt-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')

$script:LiveRecoveryHostResolutionRequired = 'live-plan-host-resolution-required'
$script:LiveRecoveryAuthorityMissing = 'live-plan-authority-missing'
$script:LiveRecoveryDispatchNotWired = 'live-recovery-dispatch-not-wired'
$script:LiveRecoveryTransactionUnknown = 'live-recovery-transaction-unknown'
$script:LiveRecoveryOriginMismatch = 'manual-recovery-required'
$script:LiveRecoveryActionMismatch = 'live-recovery-action-mismatch'
$script:LiveRecoveryTransactionFinished = 'live-recovery-transaction-finished'
$script:LiveRecoveryPlanPathCollision = 'live-recovery-plan-path-collision'
$script:LiveRecoveryPlanMissing = 'live-recovery-plan-missing'
$script:LiveRecoveryPlanMismatch = 'live-recovery-plan-mismatch'
$script:LiveRecoveryPlanStale = 'live-recovery-plan-stale'
$script:LiveRecoveryReceiptUnsupported = 'live-recovery-receipt-state-unsupported'
$script:LiveRecoveryStateFormUnsupported = 'live-recovery-state-form-unsupported'

function Resolve-LiveRecoveryInternalRoots {
    # Only a genuine sandbox capability with all three prefixed locators may
    # resolve the live surface. Anything else fails closed without reading
    # USERPROFILE or an unprefixed INTERNAL_* variable.
    [CmdletBinding()]
    param()

    if (-not (Test-LiveSafetySandboxCapability)) { throw $script:LiveRecoveryHostResolutionRequired }
    $homeRoot = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
    $backupRoot = $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT
    $controlBase = $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE
    foreach ($value in @($homeRoot, $backupRoot, $controlBase)) {
        if ([string]::IsNullOrWhiteSpace($value)) { throw $script:LiveRecoveryHostResolutionRequired }
    }
    return [pscustomobject][ordered]@{
        HomeRoot = [System.IO.Path]::GetFullPath($homeRoot)
        BackupRoot = [System.IO.Path]::GetFullPath($backupRoot)
        ControlBase = [System.IO.Path]::GetFullPath($controlBase)
    }
}

function New-LiveRecoveryAuthorityContext {
    # Resolve the full home-authority context from the sandbox-injected home
    # and fail closed unless its derived control/backup locators equal the
    # injected roots.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $HomeRoot,
        [Parameter(Mandatory)] [string] $ControlBase,
        [Parameter(Mandatory)] [string] $BackupRoot
    )

    $identity = [pscustomobject][ordered]@{
        ResolverVersion = $script:HomeAuthorityResolverVersion
        TokenSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $HomeRoot
        RoamingAppDataRoot = (Join-Path $HomeRoot 'AppData\Roaming')
        LocalAppDataRoot = (Join-Path $HomeRoot 'AppData\Local')
    }
    foreach ($folder in @([string] $identity.RoamingAppDataRoot, [string] $identity.LocalAppDataRoot)) {
        if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
    }
    $context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity -ForbiddenRoots @($ControlBase, $BackupRoot)
    $derivedControl = [System.IO.Path]::GetFullPath([string] $context.ControlBase)
    $derivedBackup = [System.IO.Path]::GetFullPath([string] $context.BackupRoot)
    if ($derivedControl -cne [System.IO.Path]::GetFullPath($ControlBase) -or
        $derivedBackup -cne [System.IO.Path]::GetFullPath($BackupRoot)) {
        throw $script:LiveRecoveryHostResolutionRequired
    }
    return $context
}

function Assert-LiveRecoveryAuthorityComplete {
    # Sync never bootstraps the authority prefix and neither does recovery:
    # both require the complete seven-directory bootstrap before they may
    # interpret anything under the control base.
    [CmdletBinding()]
    param([Parameter(Mandatory)] $AuthorityContext)

    $complete = $false
    try {
        $status = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $AuthorityContext
        $complete = ([string] $status.Status -ceq 'COMPLETE' -and [long] $status.CompletePrefixLength -eq 7)
    }
    catch {
        if ([string] $_.Exception.Message -ceq 'operation-lock-busy') { throw }
        $complete = $false
    }
    if (-not $complete) { throw $script:LiveRecoveryAuthorityMissing }
}

$script:PrePrimitivePhases = @('RESERVED', 'PREPARED', 'RECEIPT_COMPLETE', 'DIR_CREATE_INTENT', 'FILE_REPLACE_INTENT')

function New-LiveRecoveryPlanPayload {
    # Derives the schema-1 rollback/recovery plan payload from the journal
    # evidence under the held origin lock order. Every binding comes from the
    # chain or from the verifier-revalidated receipt; nothing is invented.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Chain,
        [Parameter(Mandatory)] $AuthorityContext,
        [Parameter(Mandatory)] [ValidateSet('abandon', 'rollback', 'finalize')] [string] $Action
    )

    $headerMap = [System.Collections.IDictionary] $Chain.Header
    $kind = "live-recover-$Action"
    $receiptBacked = Test-LiveTransactionMapHasName -Map $headerMap -Name 'ReceiptIntent'

    $records = @($Chain.Records)
    $chainRows = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $records) {
        $document = [System.Collections.IDictionary] $record['Document']
        $chainRows.Add([ordered]@{
            Sequence = [long] $record['Sequence']
            Phase = [string] $document['Phase']
            Hash = (Get-SemanticJsonHash -InputObject $document)
        })
    }
    $headHash = if ($chainRows.Count -gt 0) { [string] $chainRows[$chainRows.Count - 1]['Hash'] } else { Get-SealedLiveJournalHeaderHash -Header $headerMap }

    $consumed = [System.Collections.Generic.List[string]]::new()
    foreach ($record in $records) {
        $document = [System.Collections.IDictionary] $record['Document']
        if ([string] $document['Phase'] -ceq 'RECOVERY_ACTION_INTENT') {
            $data = [System.Collections.IDictionary] $document['Data']
            if (Test-LiveTransactionMapHasName -Map $data -Name 'DocumentHash') { $consumed.Add([string] $data['DocumentHash']) }
        }
    }

    $pendingTemps = [System.Collections.Generic.List[object]]::new()
    $pendingRoot = Join-Path ([string] $Chain.Directory) '_pending'
    if (Test-Path -LiteralPath $pendingRoot -PathType Container) {
        foreach ($file in @(Get-ChildItem -LiteralPath $pendingRoot -File -Force | Sort-Object Name)) {
            $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
            $pendingTemps.Add([ordered]@{
                Name = $file.Name
                Path = $file.FullName
                Length = [long] $bytes.Length
                Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
            })
        }
    }

    $resultInventory = [ordered]@{ State = 'MISSING' }
    $resultOutcome = $null
    if ($null -ne $Chain.Result) {
        $resultOutcome = [string] ([System.Collections.IDictionary] $Chain.Result)['Outcome']
        $resultInventory = [ordered]@{ State = 'PRESENT'; Hash = [string] $Chain.ResultFileHash; Outcome = $resultOutcome }
    }

    $requiredStatus = @{ 'abandon' = 'abandon-eligible'; 'rollback' = 'rollback-required'; 'finalize' = 'finalize-eligible' }[$Action]
    $entryStatus = Get-RecoveryTransactionStatus -Chain $Chain
    if ($entryStatus -ceq 'finished') { throw $script:LiveRecoveryTransactionFinished }
    if ($entryStatus -cne $requiredStatus) {
        throw ($script:LiveRecoveryActionMismatch + ' (requested ' + $Action + ', journal is ' + $entryStatus + ')')
    }

    $payload = [ordered]@{
        SchemaVersion = 1
        PlanKind = $kind
        TransactionMode = if ($receiptBacked) { 'receipt-backed' } else { 'state-only' }
        HomeAuthorityKey = [string] $headerMap['HomeAuthorityKey']
        OriginRepoId = [string] $headerMap['OriginRepoId']
        GitCommonDirHash = [string] $headerMap['GitCommonDirHash']
        CanonicalLockKey = [string] $headerMap['CanonicalLockKey']
        TransactionId = [string] $headerMap['TransactionId']
        OriginalOperationKind = [string] $headerMap['OperationKind']
        OriginalDocumentHash = [string] $headerMap['OriginalDocumentHash']
        HeaderHash = (Get-SealedLiveJournalHeaderHash -Header $headerMap)
        DerivedJournalHeadHash = $headHash
        ChainRecords = @($chainRows)
        PendingTemps = @($pendingTemps)
        ResultInventory = $resultInventory
        Targets = @($headerMap['Targets'])
        Action = $Action
    }
    if (Test-LiveTransactionMapHasName -Map $headerMap -Name 'OverlayLockKey') { $payload['OverlayLockKey'] = [string] $headerMap['OverlayLockKey'] }
    if (Test-LiveTransactionMapHasName -Map $headerMap -Name 'RootClaimsHash') { $payload['RootClaimsHash'] = [string] $headerMap['RootClaimsHash'] }
    if (($Action -ne 'abandon') -and (Test-LiveTransactionMapHasName -Map $headerMap -Name 'OriginalPlanHash')) { $payload['OriginalPlanHash'] = [string] $headerMap['OriginalPlanHash'] }
    if ($consumed.Count -gt 0) { $payload['ConsumedRecoveryDocumentHashes'] = @($consumed) }

    $receiptState = $null
    if ($receiptBacked) {
        $intent = [System.Collections.IDictionary] $headerMap['ReceiptIntent']
        $payload['ReceiptIntent'] = [ordered]@{ Id = [string] $intent['Id']; Path = [string] $intent['Path'] }
        $receiptState = Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $intent['Path'])
        $payload['ReceiptState'] = $receiptState
        if (($Action -ne 'abandon') -and $receiptState -cne 'COMPLETE') {
            throw $script:LiveRecoveryReceiptUnsupported
        }
        if ($receiptState -ceq 'COMPLETE') {
            $receiptDocument = Assert-SealedBackupReceiptValid `
                -ReceiptPath ([string] $intent['Path']) `
                -ReservationIntent ([ordered]@{ TransactionId = [string] $headerMap['TransactionId']; ReceiptId = [string] $intent['Id']; ReceiptPath = [string] $intent['Path'] }) `
                -BackupRoot ([string] $AuthorityContext.BackupRoot) `
                -ExpectedSourceOperationKind ([string] $headerMap['OperationKind']) `
                -ExpectedDocumentHash ([string] $headerMap['OriginalDocumentHash'])
            $receiptHash = $null
            foreach ($record in $records) {
                $document = [System.Collections.IDictionary] $record['Document']
                if ([string] $document['Phase'] -ceq 'RECEIPT_COMPLETE') {
                    $data = [System.Collections.IDictionary] $document['Data']
                    if (Test-LiveTransactionMapHasName -Map $data -Name 'ReceiptRef') {
                        $receiptHash = [string] ([System.Collections.IDictionary] $data['ReceiptRef'])['Hash']
                    }
                }
            }
            if ([string]::IsNullOrWhiteSpace($receiptHash)) { throw $script:LiveRecoveryReceiptUnsupported }
            $payload['ReceiptState'] = 'COMPLETE'
            $payload['ReceiptId'] = [string] $receiptDocument.ReceiptId
            $payload['ReceiptHash'] = $receiptHash
            $payload['SourceTransactionId'] = [string] $receiptDocument.SourceTransactionId
            $payload['SourceOperationKind'] = [string] $receiptDocument.SourceOperationKind
        }
    }
    else {
        if ($Action -cne 'abandon') { throw $script:LiveRecoveryStateFormUnsupported }
        $payload['ReceiptRef'] = 'NO_LIVE_MUTATION'
        $observed = Get-LiveTransactionObservedDirectory -Path ([string] $AuthorityContext.AuthorityRoot)
        if ([string] $observed['State'] -ceq 'MISSING') {
            $payload['AuthorityStatePreimage'] = [ordered]@{ State = 'MISSING' }
            $payload['AuthorityStateExpected'] = [ordered]@{ State = 'MISSING' }
        }
        else {
            $stateBinding = [ordered]@{ State = 'PRESENT'; Hash = [string] $observed['Hash']; Identity = [string] $observed['Identity'] }
            $payload['AuthorityStatePreimage'] = $stateBinding
            $payload['AuthorityStateExpected'] = [ordered]@{ State = 'PRESENT'; Hash = [string] $observed['Hash']; Identity = [string] $observed['Identity'] }
        }
    }

    $expectedOutcome = switch ($Action) {
        'abandon' { 'abandoned' }
        'rollback' { 'rolled-back' }
        'finalize' { if ($null -ne $resultOutcome) { $resultOutcome } else { 'committed' } }
    }
    $payload['ExpectedOutcome'] = $expectedOutcome
    $projection = [ordered]@{ Outcome = $expectedOutcome; ClosingKind = 'recovery'; ClosingPlanKind = $kind }
    if ($null -ne $receiptState) { $projection['ReceiptState'] = $receiptState }
    $payload['ExpectedTerminalProjection'] = $projection
    return $payload
}

$script:PrimitivePhases = @('NEW_INSTALLED', 'OLD_MOVED', 'FILE_REPLACED', 'DIR_CREATED', 'CLAIMS_PUBLISHED', 'STATE_PREIMAGE_COMPLETE', 'STATE_PUBLISHED', 'RECOVERY_ACTION_INTENT', 'RECOVERY_ACTION_APPLIED')

function Get-RecoveryTransactionStatus {
    param([Parameter(Mandatory)] $Chain)

    $phases = @($Chain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_.Document)['Phase'] })
    $result = $Chain.Result
    $hasTerminal = ($phases.Count -gt 0 -and [string] $phases[-1] -ceq 'COMPLETE')

    if ($null -ne $result -and $hasTerminal) {
        # A fixed result plus the terminal record: the transaction is finished
        # regardless of outcome; recovery never revisits a closed transaction.
        return 'finished'
    }

    if ($null -ne $result -and -not $hasTerminal) {
        # A published result without the terminal COMPLETE record is the
        # result-publish failpoint window: only finalize may close it.
        return 'finalize-eligible'
    }

    $hasPrimitive = @($phases | Where-Object { $_ -cin $script:PrimitivePhases }).Count -gt 0
    $hasPostconditions = 'POSTCONDITIONS_OK' -cin $phases
    $hasStatePublished = 'STATE_PUBLISHED' -cin $phases
    if ($hasPrimitive -and -not ($hasStatePublished -and $hasPostconditions)) {
        return 'rollback-required'
    }
    if ($hasStatePublished -and $hasPostconditions) {
        # The complete state postimage and postconditions are published but the
        # result/terminal pair is missing: finalize after the reviewed check.
        return 'finalize-eligible'
    }
    if (@($phases | Where-Object { $_ -cin $script:PrePrimitivePhases }).Count -gt 0 -and -not $hasPrimitive) {
        return 'abandon-eligible'
    }
    return 'manual-recovery-required'
}

if ($Status) {
    if ([string]::IsNullOrWhiteSpace($ControlBase)) {
        # The public CLI route resolves the control base from the
        # sandbox-injected authority and requires the complete bootstrap.
        $internalRoots = Resolve-LiveRecoveryInternalRoots
        $authorityContext = New-LiveRecoveryAuthorityContext -HomeRoot $internalRoots.HomeRoot -ControlBase $internalRoots.ControlBase -BackupRoot $internalRoots.BackupRoot
        Assert-LiveRecoveryAuthorityComplete -AuthorityContext $authorityContext
        $resolvedControlBase = [string] $authorityContext.ControlBase
    }
    else {
        # Direct/test invocations bind the control base explicitly; the scan
        # is strictly read-only either way.
        $resolvedControlBase = [System.IO.Path]::GetFullPath($ControlBase)
    }
}
else {
    # Task 6 Step 3 dispatcher. Resolution order is final: the caller's
    # repository as the origin candidate, the sandbox-injected authority, the
    # complete bootstrap gate, and only then the origin canonical lock order.
    $repoFull = [System.IO.Path]::GetFullPath((Resolve-Path -LiteralPath $RepoRoot).Path)
    $internalRoots = Resolve-LiveRecoveryInternalRoots
    $authorityContext = New-LiveRecoveryAuthorityContext -HomeRoot $internalRoots.HomeRoot -ControlBase $internalRoots.ControlBase -BackupRoot $internalRoots.BackupRoot
    Assert-LiveRecoveryAuthorityComplete -AuthorityContext $authorityContext

    $planResolution = Resolve-PrivateArtifactPath -Path ([System.IO.Path]::GetFullPath($PlanPath)) -Role ExternalUserArtifact -RepoRoot $repoFull -AllowMissingLeaf:$DryRun
    $planFull = [string] $planResolution.FullPath

    $git = Get-CanonicalGitContext -RepoRoot $repoFull
    $contractPaths = Get-CanonicalTransactionContractPaths -GitContext $git
    $repoId = Get-CanonicalRepoIdentity -GitContext $git
    $canonicalLockKey = Get-SemanticJsonHash -InputObject ([ordered]@{ Path = [string] $contractPaths.LockPath })

    $transactionsRoot = Join-Path ([string] $authorityContext.ControlBase) 'live-transactions'
    $transactionDir = Join-Path $transactionsRoot $TransactionId
    if (-not (Test-Path -LiteralPath $transactionDir -PathType Container)) { throw $script:LiveRecoveryTransactionUnknown }

    $canonicalLock = Enter-CanonicalRepoLock -LockPath ([string] $contractPaths.LockPath) -AllowCreate
    $canonicalWitness = $null
    $globalLock = $null
    try {
        # The namespace witness binds the canonical setup window; a repo whose
        # setup state is absent dispatches UNBOUND exactly like the canonical
        # recover route, and the origin identity checks still hold.
        try {
            $canonicalWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot $repoFull -CanonicalLockHandle $canonicalLock
        }
        catch {
            if ([string] $_.Exception.Message -cin @('canonical-setup-required', 'canonical-recovery-required')) {
                $canonicalWitness = $null
            }
            else { throw }
        }
        try {
            $globalLock = if ($null -ne $canonicalWitness) {
                Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $authorityContext -RequiredCanonicalWitness $canonicalWitness
            } else {
                Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $authorityContext
            }
            try {
                $chain = Get-SealedLiveJournalChain -TransactionDirectory $transactionDir
                $headerMap = [System.Collections.IDictionary] $chain.Header
                if ($null -eq $headerMap) { throw ($script:LiveRecoveryOriginMismatch + ': live journal header is missing') }
                if ([string] $headerMap['HomeAuthorityKey'] -cne [string] $authorityContext.HomeAuthorityKey) {
                    throw ($script:LiveRecoveryOriginMismatch + ': live journal home authority mismatch')
                }
                # Origin candidate matching: a wrong clone fails here and never
                # substitutes its own repository lock.
                if ([string] $headerMap['OriginRepoId'] -cne $repoId -or
                    [string] $headerMap['GitCommonDirHash'] -cne [string] $git.GitCommonDirHash -or
                    [string] $headerMap['CanonicalLockKey'] -cne $canonicalLockKey) {
                    throw ($script:LiveRecoveryOriginMismatch + ': live journal origin identity mismatch')
                }
                $null = Test-SealedLiveJournalChain -Header $chain.Header -Records $chain.Records -Result $chain.Result -ResultFileHash $chain.ResultFileHash

                if ($DryRun) {
                    $payload = New-LiveRecoveryPlanPayload -Chain $chain -AuthorityContext $authorityContext -Action $Action
                    $document = [ordered]@{
                        SchemaVersion = 1
                        ArtifactKind = 'rollback-plan'
                        Metadata = [ordered]@{
                            CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
                            Generator = 'scripts/agent-dotfiles.ps1'
                            RepositoryCommit = [string] $git.RepositoryCommit
                        }
                        PlanPayload = $payload
                    }
                    $document['PlanHash'] = Get-PlanHash -PlanPayload $payload
                    $document['DocumentHash'] = Get-DocumentHash -Document $document
                    if (Test-Path -LiteralPath $planFull) { throw $script:LiveRecoveryPlanPathCollision }
                    $planParent = Split-Path -Parent $planFull
                    if (-not [string]::IsNullOrWhiteSpace($planParent) -and -not (Test-Path -LiteralPath $planParent)) {
                        New-Item -ItemType Directory -Force -Path $planParent | Out-Null
                    }
                    [IO.File]::WriteAllText($planFull, (ConvertTo-Json -InputObject $document -Depth 64) + "`n", [System.Text.UTF8Encoding]::new($false))
                    Write-Host "live recovery plan created: $Action $TransactionId"
                    Write-Host "PlanHash: $($document['PlanHash'])"
                    exit 0
                }

                # Apply: validate the reviewed plan fail-closed under the held
                # locks; the reviewed transitions execute in the next slice.
                if (-not (Test-Path -LiteralPath $planFull -PathType Leaf)) { throw $script:LiveRecoveryPlanMissing }
                $planDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($planFull, [System.Text.UTF8Encoding]::new($false, $true)))
                Test-RollbackPlanSemantics -Document $planDocument
                $planPayload = [System.Collections.IDictionary] $planDocument['PlanPayload']
                if ([string] $planPayload['PlanKind'] -cne "live-recover-$Action" -or
                    [string] $planPayload['TransactionId'] -cne $TransactionId) {
                    throw $script:LiveRecoveryPlanMismatch
                }
                $records = @($chain.Records)
                $actualHead = if ($records.Count -gt 0) {
                    Get-SemanticJsonHash -InputObject ([System.Collections.IDictionary] $records[-1]['Document'])
                } else { Get-SealedLiveJournalHeaderHash -Header $headerMap }
                if ([string] $planPayload['DerivedJournalHeadHash'] -cne $actualHead) { throw $script:LiveRecoveryPlanStale }
                throw $script:LiveRecoveryDispatchNotWired
            }
            finally {
                if ($null -ne $globalLock) { Exit-HomeAuthorityGlobalLiveLock -LockHandle $globalLock }
            }
        }
        finally {
            if ($null -ne $canonicalWitness) { Close-CanonicalHeldNamespaceWitness -Witness $canonicalWitness }
        }
    }
    finally {
        if ($null -ne $canonicalLock) { Exit-CanonicalRepoLock -LockHandle $canonicalLock }
    }
}

$controlFull = $resolvedControlBase
$transactionsRoot = Join-Path $controlFull 'live-transactions'
$entries = [System.Collections.Generic.List[object]]::new()
$overall = 'clean'

if (Test-Path -LiteralPath $transactionsRoot -PathType Container) {
    foreach ($dir in @(Get-ChildItem -LiteralPath $transactionsRoot -Directory -Force | Sort-Object Name)) {
        $reasons = [System.Collections.Generic.List[string]]::new()
        $chain = $null
        try {
            $chain = Get-SealedLiveJournalChain -TransactionDirectory $dir.FullName
        }
        catch {
            $reasons.Add("journal chain unreadable: $($_.Exception.Message)")
        }

        $entryStatus = 'manual-recovery-required'
        $phases = @()
        $resultOutcome = $null
        $originRepoId = $null
        $homeAuthorityKey = $null
        $receiptState = $null
        $receiptId = $null
        $unknownCount = 0

        if ($null -ne $chain) {
            $unknownCount = @($chain.UnknownNames).Count
            $header = $Chain.Header
            if ($unknownCount -gt 0) { $reasons.Add("unknown namespace entries: $unknownCount") }
            if ($null -eq $header) {
                $reasons.Add('journal header missing or unreadable')
            }
            else {
                $headerMap = [System.Collections.IDictionary] $header
                if (-not $headerMap.Contains('TransactionId') -or [string] $headerMap['TransactionId'] -cne $dir.Name) {
                    $reasons.Add('header TransactionId missing or mismatched with the directory name')
                }
                foreach ($field in @('OriginRepoId', 'GitCommonDirHash', 'CanonicalLockKey', 'HomeAuthorityKey')) {
                    if (-not $headerMap.Contains($field) -or [string] $headerMap[$field] -ceq '') {
                        $reasons.Add("header field $field missing or empty")
                    }
                }
                $originRepoId = if ($headerMap.Contains('OriginRepoId')) { [string] $headerMap['OriginRepoId'] } else { $null }
                $homeAuthorityKey = if ($headerMap.Contains('HomeAuthorityKey')) { [string] $headerMap['HomeAuthorityKey'] } else { $null }
                if ($headerMap.Contains('ReceiptIntent')) {
                    $intent = [System.Collections.IDictionary] $headerMap['ReceiptIntent']
                    $receiptId = if ($intent.Contains('Id')) { [string] $intent['Id'] } else { $null }
                    $receiptPath = if ($intent.Contains('Path')) { [string] $intent['Path'] } else { $null }
                    if ($receiptPath -and (Test-Path -LiteralPath $receiptPath)) {
                        try { $receiptState = Get-SealedBackupReceiptSlotState -ReceiptPath $receiptPath } catch { $receiptState = $null; $reasons.Add("receipt slot state unreadable: $($_.Exception.Message)") }
                    }
                    else {
                        $receiptState = 'MISSING'
                    }
                }
            }
            $phases = @($Chain.Records | ForEach-Object { [string] ([System.Collections.IDictionary] $_.Document)['Phase'] })
            $resultOutcome = if ($null -ne $Chain.Result) { [string] ([System.Collections.IDictionary] $Chain.Result)['Outcome'] } else { $null }
            if (-not $reasons.Count) {
                $entryStatus = Get-RecoveryTransactionStatus -Chain $chain
                if ($entryStatus -ceq 'manual-recovery-required') { $reasons.Add('phase evidence does not match any reviewed recovery shape') }
            }
            else {
                $entryStatus = 'manual-recovery-required'
            }
        }
        else {
            $entryStatus = 'manual-recovery-required'
        }

        if ($entryStatus -cne 'finished') {
            # The overall status is the most severe unfinished transaction:
            # manual beats rollback, rollback beats finalize, finalize beats
            # abandon; clean only when nothing is unfinished.
            $severity = @{ 'abandon-eligible' = 1; 'finalize-eligible' = 2; 'rollback-required' = 3; 'manual-recovery-required' = 4 }
            if ($overall -ceq 'clean') { $overall = $entryStatus }
            elseif ($severity[[string] $entryStatus] -gt $severity[$overall]) { $overall = $entryStatus }
        }

        $entries.Add([ordered]@{
            TransactionId = $dir.Name
            Status = $entryStatus
            ResultOutcome = $resultOutcome
            ReceiptState = $receiptState
            ReceiptId = $receiptId
            OriginRepoId = $originRepoId
            HomeAuthorityKey = $homeAuthorityKey
            Phases = @($phases)
            UnknownEntryCount = $unknownCount
            Reasons = @($reasons)
        })
    }
}

if ($overall -ceq 'clean') {
    Write-Host "Recovery scan: clean (no unfinished live transactions under $transactionsRoot)"
}
else {
    Write-Host "Recovery scan: $overall"
    foreach ($entry in $entries) {
        if ([string] $entry['Status'] -ceq 'finished') { continue }
        Write-Host ("- {0}: {1} (outcome={2}, receipt={3})" -f $entry['TransactionId'], $entry['Status'], $entry['ResultOutcome'], $entry['ReceiptState'])
        foreach ($reason in @($entry['Reasons'])) { Write-Host ("    reason: {0}" -f $reason) }
    }
}

if (-not [string]::IsNullOrWhiteSpace($JsonPath)) {
    $jsonFull = [System.IO.Path]::GetFullPath($JsonPath)
    $document = [ordered]@{
        SchemaVersion = 1
        ReportKind = 'live-recovery-status'
        ControlBase = $controlFull
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        OverallStatus = $overall
        Transactions = @($entries)
    }
    $parent = Split-Path -Parent $jsonFull
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        throw "recovery status JSON directory does not exist: $parent"
    }
    if (Test-Path -LiteralPath $jsonFull) { throw "recovery status JSON path already exists: $jsonFull" }
    [IO.File]::WriteAllText($jsonFull, (ConvertTo-Json -InputObject $document -Depth 6) + "`n", [System.Text.UTF8Encoding]::new($false))
}

exit 0
