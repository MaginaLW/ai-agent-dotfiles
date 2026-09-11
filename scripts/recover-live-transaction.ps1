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

    The abandon/rollback/finalize modes are the Task 6 Step 3 dispatcher
    surface. They resolve the sandbox-injected authority, require the
    complete bootstrap prefix, and currently fail closed with
    live-recovery-dispatch-not-wired before any lock acquisition, plan
    publication, or mutation; the reviewed transitions land in the
    remaining Step 3 slices.

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
    [Parameter(Mandatory, ParameterSetName = 'Apply')] [string] $PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'home-authority-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'backup-receipt-common.ps1')

$script:LiveRecoveryHostResolutionRequired = 'live-plan-host-resolution-required'
$script:LiveRecoveryAuthorityMissing = 'live-plan-authority-missing'
$script:LiveRecoveryDispatchNotWired = 'live-recovery-dispatch-not-wired'

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
    # Task 6 Step 3 dispatcher surface. Resolution order is final: the
    # sandbox-injected authority, the complete bootstrap gate, and only then
    # the reviewed transitions (remaining slices). Until they land, nothing
    # may be planned, locked, or mutated.
    $internalRoots = Resolve-LiveRecoveryInternalRoots
    $authorityContext = New-LiveRecoveryAuthorityContext -HomeRoot $internalRoots.HomeRoot -ControlBase $internalRoots.ControlBase -BackupRoot $internalRoots.BackupRoot
    Assert-LiveRecoveryAuthorityComplete -AuthorityContext $authorityContext
    throw $script:LiveRecoveryDispatchNotWired
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
