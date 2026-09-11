#requires -Version 7.0
<#
.SYNOPSIS
    Read-only recovery status locator for live transaction journals.

.DESCRIPTION
    Scans every transaction journal under <ControlBase>\live-transactions and
    reports, per transaction, exactly one recovery status: abandon-eligible,
    rollback-required, finalize-eligible, or manual-recovery-required. An
    overall status of clean is reported when nothing is unfinished.

    The scan is strictly read-only: journals are enumerated and read with
    immediate open/close (no retained handles), and nothing is renamed,
    deleted, or written. Missing, ambiguous, or unresolvable evidence fails
    closed as manual-recovery-required. This locator only reports; the
    reviewed recovery dispatcher (Task 6 Step 3) decides and executes any
    transition.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $ControlBase,
    [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'live-transaction-common.ps1')
. (Join-Path $PSScriptRoot 'backup-receipt-common.ps1')

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

$controlFull = [System.IO.Path]::GetFullPath($ControlBase)
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

        $status = 'manual-recovery-required'
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
                $status = Get-RecoveryTransactionStatus -Chain $chain
                if ($status -ceq 'manual-recovery-required') { $reasons.Add('phase evidence does not match any reviewed recovery shape') }
            }
            else {
                $status = 'manual-recovery-required'
            }
        }
        else {
            $status = 'manual-recovery-required'
        }

        if ($status -cne 'finished') {
            # The overall status is the most severe unfinished transaction:
            # manual beats rollback, rollback beats finalize, finalize beats
            # abandon; clean only when nothing is unfinished.
            $severity = @{ 'abandon-eligible' = 1; 'finalize-eligible' = 2; 'rollback-required' = 3; 'manual-recovery-required' = 4 }
            if ($overall -ceq 'clean') { $overall = $status }
            elseif ($severity[[string] $status] -gt $severity[$overall]) { $overall = $status }
        }

        $entries.Add([ordered]@{
            TransactionId = $dir.Name
            Status = $status
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
