#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'live-safety-interlock.ps1')
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'safe-tree-walker.ps1')
. (Join-Path $PSScriptRoot 'target-context-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')

$script:BackupReceiptIntentMismatch = 'backup-receipt-intent-mismatch'
$script:BackupReceiptSlotCollision = 'backup-receipt-slot-collision'
$script:BackupReceiptBackupRootInvalid = 'backup-receipt-backup-root-invalid'
$script:BackupReceiptSourceDrift = 'backup-receipt-source-drift'
$script:BackupReceiptTargetStateDrift = 'backup-receipt-target-state-drift'
$script:BackupReceiptSchemaUnsupported = 'backup-receipt-schema-unsupported'
$script:BackupReceiptHashMismatch = 'backup-receipt-hash-mismatch'
$script:BackupReceiptPublishFailed = 'backup-receipt-publish-failed'
$script:BackupReceiptVerifierInvalid = 'backup-receipt-verifier-invalid'

$script:BackupReceiptKinds = @(
    'initial',
    'environment',
    'task-overlay',
    'migrate',
    'adopt',
    'repair-adopt',
    'retirement'
)
$script:BackupReceiptPlatforms = @('Claude', 'Codex', 'Reasonix')
$script:BackupReceiptHashPattern = '^[0-9a-f]{64}$'
$script:BackupReceiptUuidPattern = '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'
$script:BackupReceiptIdentityPattern = '^[0-9a-f]{8}:[0-9a-f]{16}$'
$script:BackupReceiptFailpointVariable = 'AI_AGENT_DOTFILES_BACKUP_RECEIPT_FAILPOINTS'

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

function Assert-BackupReceiptHashSpelling {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [string] -or [string] $Value -cnotmatch $script:BackupReceiptHashPattern) { throw $Failure }
}

function Assert-BackupReceiptUuidSpelling {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [string] -or [string] $Value -cnotmatch $script:BackupReceiptUuidPattern) { throw $Failure }
}

function Assert-BackupReceiptAbsolutePath {
    param($Value, [Parameter(Mandatory)] [string] $Failure)
    if ($Value -isnot [string] -or [string] $Value -cnotmatch '^[A-Za-z]:\\') { throw $Failure }
}

function Get-BackupReceiptChildDirectoryNames {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Path -Directory -Force | ForEach-Object Name)
}

function Get-BackupReceiptSelfExcludedHash {
    # The ReceiptHash covers the complete receipt document excluding only itself;
    # CreatedAtUtc and every other semantic field stay protected.
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $copy = [ordered]@{}
    foreach ($key in @($Document.Keys)) {
        if ([string] $key -ceq 'ReceiptHash') { continue }
        $copy[[string] $key] = $Document[$key]
    }
    return Get-SemanticJsonHash -InputObject $copy
}

# ---------------------------------------------------------------------------
# Test-only failpoints (capability-gated)
# ---------------------------------------------------------------------------

function Get-SealedBackupReceiptFailpointPlan {
    if (-not (Test-LiveSafetySandboxCapability)) { return @() }
    $raw = [System.Environment]::GetEnvironmentVariable($script:BackupReceiptFailpointVariable)
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    try {
        $plan = ConvertFrom-SemanticJson -Json $raw
    }
    catch {
        throw "backup receipt failpoint plan is not strict semantic JSON: $($_.Exception.Message)"
    }
    return @([object[]] $plan)
}

function Invoke-SealedBackupReceiptFailpoint {
    # Publishes the checkpoint to the test controller and blocks until the
    # controller answers or the process is killed; never triggers without the
    # sandbox capability and an explicitly configured checkpoint.
    param([Parameter(Mandatory)] [string] $Checkpoint)

    $row = @((Get-SealedBackupReceiptFailpointPlan) | Where-Object { [string] $_['Checkpoint'] -ceq $Checkpoint })
    if ($row.Count -eq 0) { return }
    $pipeName = [string] $row[0]['PipeName']
    if ([string]::IsNullOrWhiteSpace($pipeName)) { throw "backup receipt failpoint '$Checkpoint' has no pipe name" }
    $client = [System.IO.Pipes.NamedPipeClientStream]::new('.', $pipeName, [System.IO.Pipes.PipeDirection]::Out, [System.IO.Pipes.PipeOptions]::None)
    try {
        $client.Connect(30000)
        $writer = [System.IO.StreamWriter]::new($client, [System.Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.WriteLine($Checkpoint)
        $writer.Flush()
        # Hold the pipe open and wait for the controller to kill this process;
        # a missed kill aborts the producer with a partial slot, which the
        # restart classifier still reports as PARTIAL.
        $deadline = [DateTime]::UtcNow.AddSeconds(120)
        while ([DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 200 }
        throw "backup receipt failpoint '$Checkpoint' was not killed within 120 seconds"
    }
    finally {
        $client.Dispose()
    }
}

# ---------------------------------------------------------------------------
# Reservation intent and BackupRoot validation
# ---------------------------------------------------------------------------

function Test-SealedBackupReceiptIntent {
    # Validates the flushed reservation intent the transaction host passes in:
    # exact keys, canonical spellings, distinct ids, and a receipt path whose
    # leaf is the ReceiptId and whose parent is the resolved BackupRoot.
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReservationIntent,
        [Parameter(Mandatory)] [string] $BackupRoot
    )

    $expected = @('TransactionId', 'ReceiptId', 'ReceiptPath')
    $actual = @([string[]] $ReservationIntent.Keys | Sort-Object { [string] $_ })
    if (($actual -join "`0") -cne (($expected | Sort-Object { [string] $_ }) -join "`0")) { throw $script:BackupReceiptIntentMismatch }
    Assert-BackupReceiptUuidSpelling -Value $ReservationIntent['TransactionId'] -Failure $script:BackupReceiptIntentMismatch
    Assert-BackupReceiptUuidSpelling -Value $ReservationIntent['ReceiptId'] -Failure $script:BackupReceiptIntentMismatch
    if ([string] $ReservationIntent['TransactionId'] -ceq [string] $ReservationIntent['ReceiptId']) { throw $script:BackupReceiptIntentMismatch }
    Assert-BackupReceiptAbsolutePath -Value $ReservationIntent['ReceiptPath'] -Failure $script:BackupReceiptIntentMismatch
    $receiptPath = [System.IO.Path]::GetFullPath([string] $ReservationIntent['ReceiptPath'])
    $leaf = [System.IO.Path]::GetFileName($receiptPath)
    if ($leaf -cne [string] $ReservationIntent['ReceiptId']) { throw $script:BackupReceiptIntentMismatch }
    $root = [System.IO.Path]::GetFullPath($BackupRoot).TrimEnd([char]92, [char]47)
    $parent = [System.IO.Path]::GetFullPath((Split-Path -Parent $receiptPath)).TrimEnd([char]92, [char]47)
    if ($parent -cne $root) { throw $script:BackupReceiptIntentMismatch }
    return [pscustomobject][ordered]@{
        TransactionId = [string] $ReservationIntent['TransactionId']
        ReceiptId = [string] $ReservationIntent['ReceiptId']
        ReceiptPath = $receiptPath
    }
}

function Assert-SealedBackupReceiptBackupRoot {
    # The host resolves BackupRoot from the Known Folder private root (or a
    # capability-scoped test path). The producer validates existence, no-reparse
    # ancestry, identity stability, Fixed/NTFS volume, current-user-only
    # security evidence, and disjointness from the forbidden/live roots.
    param(
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $ForbiddenRoots
    )

    try {
        $root = [System.IO.Path]::GetFullPath($BackupRoot)
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { throw 'missing' }
        Assert-NoReparseExistingChain -Path $root
        $context = Get-TargetMetadataContext -Path $root
        if ([string] $context.TargetStatus -cne 'EXISTS') { throw 'missing' }
        $identity = [string] $context.Ancestors[-1].Identity
        $volume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($root)
        if ([string] $volume.DriveType -cne 'Fixed' -or [string] $volume.FileSystemType -cne 'NTFS') {
            throw 'unsupported filesystem'
        }
        $security = Get-CanonicalDirectorySecurityEvidence -Path $root -ExpectedIdentity $identity
        Assert-CanonicalControlledPrivateAncestorSecurity -Evidence $security -Path $root -TokenSid (Get-CanonicalTokenSid)
        foreach ($forbidden in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            $forbiddenFull = [System.IO.Path]::GetFullPath($forbidden).TrimEnd([char]92, [char]47)
            $rootTrimmed = $root.TrimEnd([char]92, [char]47)
            if ($rootTrimmed -ieq $forbiddenFull -or
                $rootTrimmed.StartsWith($forbiddenFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase) -or
                $forbiddenFull.StartsWith($rootTrimmed + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
                throw 'overlap'
            }
        }
        return [pscustomobject][ordered]@{
            Path = $root
            Identity = $identity
            DriveType = [string] $volume.DriveType
            FileSystemType = [string] $volume.FileSystemType
            SecurityEvidenceHash = (Get-SemanticJsonHash -InputObject $security)
        }
    }
    catch {
        throw $script:BackupReceiptBackupRootInvalid
    }
}

# ---------------------------------------------------------------------------
# Receipt producer (the transaction host's internal managed-backup function)
# ---------------------------------------------------------------------------

function Invoke-SealedManagedBackupReceipt {
    # Creates the unique predeclared receipt slot, snapshots only the planned
    # pre-change managed targets with SafeTreeWalker, captures the authority
    # preimages as exact bytes, publishes the immutable SchemaVersion=1
    # receipt, and returns a structured result. The caller (transaction host)
    # owns the TransactionId/ReceiptId binding and the later RECEIPT_COMPLETE
    # journal append; this function never scans BackupRoot children, never
    # re-derives paths from HomeRoot, and never invents a second receipt id.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReservationIntent,
        [Parameter(Mandatory)] [ValidateSet('initial', 'environment', 'task-overlay', 'migrate', 'adopt', 'repair-adopt', 'retirement')] [string] $SourceOperationKind,
        [Parameter(Mandatory)] [string] $PlanHash,
        [Parameter(Mandatory)] [string] $DocumentHash,
        [Parameter(Mandatory)] [string] $ExecutionContextHash,
        [Parameter(Mandatory)] [string] $ControlBaseHash,
        [Parameter(Mandatory)] [string] $FilesystemCapabilityHash,
        [Parameter(Mandatory)] [string] $HomeAuthorityKey,
        [Parameter(Mandatory)] [string] $BackupRoot,
        [Parameter(Mandatory)] [object[]] $Platforms,
        [AllowNull()] [string] $AuthorityStatePath,
        [AllowNull()] [string] $RootClaimsPath,
        [string[]] $ForbiddenRoots = @()
    )

    foreach ($hashName in @('PlanHash', 'DocumentHash', 'ExecutionContextHash', 'ControlBaseHash', 'FilesystemCapabilityHash', 'HomeAuthorityKey')) {
        Assert-BackupReceiptHashSpelling -Value $PSBoundParameters[$hashName] -Failure $script:BackupReceiptIntentMismatch
    }
    $platformRows = [ordered]@{}
    foreach ($platformRow in @($Platforms)) {
        $platform = [string] $platformRow['Platform']
        if ($platform -cnotin $script:BackupReceiptPlatforms) { throw $script:BackupReceiptIntentMismatch }
        if ($platformRows.Contains($platform)) { throw $script:BackupReceiptIntentMismatch }
        $liveRoot = [System.IO.Path]::GetFullPath([string] $platformRow['LiveRoot'])
        $targets = [System.Collections.Generic.List[object]]::new()
        foreach ($target in @([object[]] $platformRow['Targets'])) {
            $name = [string] $target['Name']
            if ($name -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]*$' -or $name -ieq '.system') { throw $script:BackupReceiptIntentMismatch }
            $livePath = [System.IO.Path]::GetFullPath([string] $target['LivePath'])
            $plannedHash = $target['PlannedTreeHash']
            if ($null -ne $plannedHash) {
                Assert-BackupReceiptHashSpelling -Value $plannedHash -Failure $script:BackupReceiptIntentMismatch
            }
            $targets.Add([pscustomobject][ordered]@{
                Name = $name
                LivePath = $livePath
                PlannedTreeHash = $(if ($null -ne $plannedHash) { [string] $plannedHash } else { $null })
            })
        }
        $platformRows[$platform] = [pscustomobject][ordered]@{
            Platform = $platform
            LiveRoot = $liveRoot
            Targets = @($targets)
        }
    }
    if ($platformRows.Count -ne 3) { throw $script:BackupReceiptIntentMismatch }

    $backupRootEvidence = Assert-SealedBackupReceiptBackupRoot -BackupRoot $BackupRoot -ForbiddenRoots (@($ForbiddenRoots) + @($platformRows.Values | ForEach-Object { [string] $_.LiveRoot }))
    $intent = Test-SealedBackupReceiptIntent -ReservationIntent $ReservationIntent -BackupRoot ([string] $backupRootEvidence.Path)
    $receiptPath = [string] $intent.ReceiptPath

    $slotContext = Get-TargetMetadataContext -Path $receiptPath
    if ([string] $slotContext.TargetStatus -cne 'MISSING') { throw $script:BackupReceiptSlotCollision }
    Assert-NoReparseExistingChain -Path $receiptPath
    $slotParentReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    Open-SafeDirectoryContainmentChain -Path ([System.IO.Path]::GetFullPath((Split-Path -Parent $receiptPath))) -OwnershipReceiver $slotParentReceiver
    $slotParentHandles = $slotParentReceiver.GetDeliveredExact()
    $slotHandle = $null
    try {
        $slotHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($slotParentHandles[$slotParentHandles.Count - 1], ([string] $intent.ReceiptId))
    }
    catch {
        throw $script:BackupReceiptSlotCollision
    }
    finally {
        if ($null -ne $slotHandle) { $slotHandle.Dispose() }
        if ($null -ne $slotParentHandles) { Close-SafeDirectoryContainmentChain -Handles $slotParentHandles }
    }
    Invoke-SealedBackupReceiptFailpoint -Checkpoint 'slot-created'

    $snapshotRoot = Join-Path $receiptPath 'snapshot'
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        [System.IO.Directory]::CreateDirectory((Join-Path $snapshotRoot $platform)) | Out-Null
    }

    $snapshotRows = [System.Collections.Generic.List[object]]::new()
    $unknownMarkers = [System.Collections.Generic.List[object]]::new()
    $systemMarker = $null
    foreach ($platform in $script:BackupReceiptPlatforms) {
        $row = $platformRows[$platform]
        $targetRows = [System.Collections.Generic.List[object]]::new()
        $plannedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($target in @($row.Targets)) { [void] $plannedNames.Add([string] $target.Name) }
        foreach ($child in (@(Get-BackupReceiptChildDirectoryNames -Path ([string] $row.LiveRoot)) | Sort-Object)) {
            if ($platform -ieq 'codex' -and [string] $child -ieq '.system') {
                $systemDir = Join-Path ([string] $row.LiveRoot) '.system'
                $info = [AiAgentDotfiles.NoFollowFile]::Inspect($systemDir)
                $systemMarker = [ordered]@{
                    Platform = 'Codex'
                    Name = '.system'
                    Present = $true
                    Identity = [string] $info.Identity
                }
                continue
            }
            if (-not $plannedNames.Contains([string] $child)) {
                $identity = $null
                try {
                    $info = [AiAgentDotfiles.NoFollowFile]::Inspect((Join-Path ([string] $row.LiveRoot) $child))
                    if ([bool] $info.IsDirectory -and -not [bool] $info.IsReparsePoint) { $identity = [string] $info.Identity }
                }
                catch {
                    $identity = $null
                }
                $unknownMarkers.Add([ordered]@{
                    Platform = $platform
                    Name = [string] $child
                    Identity = $identity
                })
            }
        }
        foreach ($target in (@($row.Targets) | Sort-Object { [string] $_.Name })) {
            $snapshotTarget = Join-Path (Join-Path $snapshotRoot ([string] $platform).ToLowerInvariant()) ([string] $target.Name)
            if ($null -eq $target.PlannedTreeHash) {
                $context = Get-TargetMetadataContext -Path ([string] $target.LivePath)
                if ([string] $context.TargetStatus -cne 'MISSING') { throw $script:BackupReceiptTargetStateDrift }
                $targetRows.Add([ordered]@{
                    Name = [string] $target.Name
                    Status = 'MISSING'
                    LiveIdentity = $null
                    SnapshotTreeHash = $null
                })
                continue
            }
            $context = Get-TargetMetadataContext -Path ([string] $target.LivePath)
            if ([string] $context.TargetStatus -cne 'EXISTS') { throw $script:BackupReceiptSourceDrift }
            $liveIdentity = [string] $context.Ancestors[-1].Identity
            $liveTreeHash = (Get-SafeTreeSnapshot -Root ([string] $target.LivePath)).TreeHash
            if ([string] $liveTreeHash -cne [string] $target.PlannedTreeHash) { throw $script:BackupReceiptSourceDrift }
            $copyResult = Copy-SafeTree -SourceRoot ([string] $target.LivePath) -DestinationRoot $snapshotTarget
            $snapshotTreeHash = [string] $copyResult.DestinationTreeHash
            if ($snapshotTreeHash -cne [string] $target.PlannedTreeHash) { throw $script:BackupReceiptPublishFailed }
            $targetRows.Add([ordered]@{
                Name = [string] $target.Name
                Status = 'COPIED'
                LiveIdentity = $liveIdentity
                SnapshotTreeHash = $snapshotTreeHash
            })
        }
        $snapshotRows.Add([ordered]@{
            Platform = $platform
            LiveRoot = [string] $row.LiveRoot
            RootHash = (Get-SafeTreeSnapshot -Root (Join-Path $snapshotRoot ([string] $platform).ToLowerInvariant())).TreeHash
            Targets = @($targetRows)
        })
    }
    if ($null -eq $systemMarker) {
        $systemMarker = [ordered]@{ Platform = 'Codex'; Name = '.system'; Present = $false; Identity = $null }
    }
    Invoke-SealedBackupReceiptFailpoint -Checkpoint 'snapshot-published'

    $preimageRoot = Join-Path $receiptPath 'authority-preimage'
    [System.IO.Directory]::CreateDirectory($preimageRoot) | Out-Null
    $preimageRows = [ordered]@{}
    foreach ($entry in @(
        @{ Key = 'AuthorityStatePreimage'; SourcePath = $AuthorityStatePath; Leaf = 'current-env.json' },
        @{ Key = 'RootClaimsPreimage'; SourcePath = $RootClaimsPath; Leaf = 'root-claims.json' }
    )) {
        if ([string]::IsNullOrWhiteSpace([string] $entry.SourcePath)) {
            $preimageRows[[string] $entry.Key] = [ordered]@{
                Status = 'MISSING'
                SourcePath = $null
                Hash = $null
                Length = $null
                Identity = $null
            }
            continue
        }
        $sourcePath = [System.IO.Path]::GetFullPath([string] $entry.SourcePath)
        $capture = Read-CanonicalHeldRegularFileCapture -Path $sourcePath
        $destination = Join-Path $preimageRoot ([string] $entry.Leaf)
        $stream = [System.IO.File]::Open($destination, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write([byte[]] $capture.Bytes, 0, [long] $capture.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        $written = [AiAgentDotfiles.NoFollowFile]::HashRegularFile($destination)
        if ([string] $written.Sha256 -cne [string] $capture.Sha256) { throw $script:BackupReceiptPublishFailed }
        $preimageRows[[string] $entry.Key] = [ordered]@{
            Status = 'COPIED'
            SourcePath = $sourcePath
            Hash = [string] $capture.Sha256
            Length = [long] $capture.Length
            Identity = [string] $capture.Identity
        }
    }
    Invoke-SealedBackupReceiptFailpoint -Checkpoint 'preimage-published'

    $document = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'backup-receipt'
        SourceTransactionId = [string] $intent.TransactionId
        ReceiptId = [string] $intent.ReceiptId
        ReceiptPath = $receiptPath
        SourceOperationKind = $SourceOperationKind
        PlanHash = $PlanHash
        DocumentHash = $DocumentHash
        ExecutionContextHash = $ExecutionContextHash
        ControlBaseHash = $ControlBaseHash
        FilesystemCapabilityHash = $FilesystemCapabilityHash
        HomeAuthorityKey = $HomeAuthorityKey
        ReceiptIntent = [ordered]@{ Id = [string] $intent.ReceiptId; Path = $receiptPath }
        ManagedSnapshots = @($snapshotRows)
        UnknownMarkers = @($unknownMarkers)
        SystemMarker = $systemMarker
        AuthorityStatePreimage = $preimageRows['AuthorityStatePreimage']
        RootClaimsPreimage = $preimageRows['RootClaimsPreimage']
        CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    $document['ReceiptHash'] = Get-BackupReceiptSelfExcludedHash -Document $document

    $metaRoot = Join-Path $receiptPath '_meta'
    [System.IO.Directory]::CreateDirectory($metaRoot) | Out-Null
    $receiptBytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $document -Depth 40) + "`n")
    $tempPath = Join-Path $metaRoot ("receipt.json." + [Guid]::NewGuid().ToString('N') + ".tmp")
    $finalPath = Join-Path $metaRoot 'receipt.json'
    try {
        $stream = [System.IO.File]::Open($tempPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($receiptBytes, 0, $receiptBytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        [System.IO.File]::Move($tempPath, $finalPath)
    }
    catch {
        throw $script:BackupReceiptPublishFailed
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
    Invoke-SealedBackupReceiptFailpoint -Checkpoint 'receipt-published'

    $completePath = Join-Path $metaRoot 'COMPLETE'
    $completeStream = [System.IO.File]::Open($completePath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes([string] $document['ReceiptHash'])
        $completeStream.Write($bytes, 0, $bytes.Length)
        $completeStream.Flush($true)
    }
    finally { $completeStream.Dispose() }
    Invoke-SealedBackupReceiptFailpoint -Checkpoint 'complete-published'

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'backup-receipt'
        SourceTransactionId = [string] $document['SourceTransactionId']
        ReceiptId = [string] $document['ReceiptId']
        ReceiptPath = $receiptPath
        ReceiptHash = [string] $document['ReceiptHash']
        SourceOperationKind = $SourceOperationKind
        PlanHash = $PlanHash
        DocumentHash = $DocumentHash
        ExecutionContextHash = $ExecutionContextHash
        ControlBaseHash = $ControlBaseHash
        FilesystemCapabilityHash = $FilesystemCapabilityHash
        HomeAuthorityKey = $HomeAuthorityKey
        ReceiptIntent = $intent
        ManagedSnapshots = @($snapshotRows)
        UnknownMarkers = @($unknownMarkers)
        SystemMarker = $systemMarker
        AuthorityStatePreimage = $preimageRows['AuthorityStatePreimage']
        RootClaimsPreimage = $preimageRows['RootClaimsPreimage']
        BackupRoot = [string] $backupRootEvidence.Path
        CreatedAtUtc = [string] $document['CreatedAtUtc']
    }
}

# ---------------------------------------------------------------------------
# Restart classification (reads only the declared slot)
# ---------------------------------------------------------------------------

function Get-SealedBackupReceiptSlotState {
    # Restart classification for the header-declared receipt slot. It reads
    # only the exact declared path and never enumerates BackupRoot siblings.
    param([Parameter(Mandatory)] [string] $ReceiptPath)

    $slot = [System.IO.Path]::GetFullPath($ReceiptPath)
    if (-not (Test-Path -LiteralPath $slot -PathType Container)) { return 'MISSING' }
    $metaRoot = Join-Path $slot '_meta'
    if (-not (Test-Path -LiteralPath (Join-Path $metaRoot 'receipt.json') -PathType Leaf)) { return 'PARTIAL' }
    if (-not (Test-Path -LiteralPath (Join-Path $metaRoot 'COMPLETE') -PathType Leaf)) { return 'PARTIAL' }
    return 'COMPLETE'
}

# ---------------------------------------------------------------------------
# Receipt semantic validation (registry) and consumer verification
# ---------------------------------------------------------------------------

function Test-BackupReceiptSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)

    $schemaUnsupported = $script:BackupReceiptSchemaUnsupported
    $hashMismatch = $script:BackupReceiptHashMismatch
    $intentMismatch = $script:BackupReceiptIntentMismatch

    if ([long] $Document.SchemaVersion -ne 1 -or [string] $Document.ArtifactKind -cne 'backup-receipt') { throw $schemaUnsupported }
    if ([string] $Document.SourceTransactionId -ceq [string] $Document.ReceiptId) { throw $intentMismatch }
    if ([string] $Document.ReceiptIntent.Id -cne [string] $Document.ReceiptId) { throw $intentMismatch }
    if ([string] $Document.ReceiptIntent.Path -cne [string] $Document.ReceiptPath) { throw $intentMismatch }
    $receiptPath = [System.IO.Path]::GetFullPath([string] $Document.ReceiptPath)
    if ([System.IO.Path]::GetFileName($receiptPath) -cne [string] $Document.ReceiptId) { throw $intentMismatch }

    $platformRank = @{ Claude = 0; Codex = 1; Reasonix = 2 }
    $snapshots = @([object[]] $Document.ManagedSnapshots)
    if ($snapshots.Count -ne 3) { throw $intentMismatch }
    for ($index = 0; $index -lt 3; $index++) {
        $row = $snapshots[$index]
        if ([string] $row['Platform'] -cne $script:BackupReceiptPlatforms[$index]) { throw $intentMismatch }
        Assert-BackupReceiptHashSpelling -Value $row['RootHash'] -Failure $hashMismatch
        $seenNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $sortKeys = [System.Collections.Generic.List[string]]::new()
        foreach ($target in @([object[]] $row['Targets'])) {
            $name = [string] $target['Name']
            if (-not $seenNames.Add($name)) { throw $intentMismatch }
            $sortKeys.Add($name)
            $status = [string] $target['Status']
            if ($status -ceq 'COPIED') {
                if ([string] $target['LiveIdentity'] -cnotmatch $script:BackupReceiptIdentityPattern) { throw $intentMismatch }
                Assert-BackupReceiptHashSpelling -Value $target['SnapshotTreeHash'] -Failure $hashMismatch
            }
            elseif ($status -ceq 'MISSING') {
                if ($null -ne $target['LiveIdentity'] -or $null -ne $target['SnapshotTreeHash']) { throw $intentMismatch }
            }
            else { throw $intentMismatch }
        }
        $ordered = [string[]] @($sortKeys)
        $sorted = [string[]] @($sortKeys)
        if ($sorted.Count -gt 1) { [Array]::Sort($sorted, [StringComparer]::Ordinal) }
        if (($ordered -join "`n") -cne ($sorted -join "`n")) { throw $intentMismatch }
        $null = $platformRank
    }

    $rank = @{ Claude = 0; Codex = 1; Reasonix = 2 }
    $markerKeys = [System.Collections.Generic.List[string]]::new()
    $seenUnknown = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($marker in @([object[]] $Document.UnknownMarkers)) {
        if ([string] $marker['Platform'] -cnotin $script:BackupReceiptPlatforms) { throw $intentMismatch }
        $key = [string] $marker['Platform'] + '/' + [string] $marker['Name']
        if (-not $seenUnknown.Add($key)) { throw $intentMismatch }
        $markerKeys.Add($key)
    }
    $sortedKeys = [string[]] @($markerKeys)
    if ($sortedKeys.Count -gt 1) {
        $sortedKeys = @($sortedKeys | Sort-Object { $rank[([string] $_).Split('/')[0]] }, { $_ })
    }
    if (($markerKeys -join "`n") -cne ($sortedKeys -join "`n")) { throw $intentMismatch }

    foreach ($name in @('AuthorityStatePreimage', 'RootClaimsPreimage')) {
        $preimage = $Document[$name]
        if ([string] $preimage['Status'] -ceq 'COPIED') {
            Assert-BackupReceiptHashSpelling -Value $preimage['Hash'] -Failure $hashMismatch
        }
        elseif ([string] $preimage['Status'] -ceq 'MISSING') {
            if ($null -ne $preimage['Hash']) { throw $intentMismatch }
        }
        else { throw $intentMismatch }
    }

    $expectedHash = Get-BackupReceiptSelfExcludedHash -Document $Document
    if ([string] $Document.ReceiptHash -cne $expectedHash) { throw $hashMismatch }
}

function Assert-SealedBackupReceiptValid {
    # Consumer verification: re-reads the published receipt exact-byte, validates
    # schema plus semantics, re-verifies the COMPLETE marker, the intent binding,
    # the managed snapshot trees, and the authority preimage bytes. Rollback
    # consumers (Task 6/7) call this before trusting any snapshot.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ReceiptPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReservationIntent,
        [Parameter(Mandatory)] [string] $BackupRoot,
        [AllowNull()] [string] $ExpectedSourceOperationKind,
        [AllowNull()] [string] $ExpectedPlanHash,
        [AllowNull()] [string] $ExpectedDocumentHash,
        [AllowNull()] [string] $ExpectedExecutionContextHash,
        [AllowNull()] [string] $ExpectedControlBaseHash,
        [AllowNull()] [string] $ExpectedFilesystemCapabilityHash,
        [AllowNull()] [string] $ExpectedHomeAuthorityKey
    )

    try {
        return (Assert-SealedBackupReceiptValidInner @PSBoundParameters)
    }
    catch {
        if ($env:AI_AGENT_DOTFILES_BACKUP_RECEIPT_DEBUG -eq '1') { throw }
        throw $script:BackupReceiptVerifierInvalid
    }
}

function Assert-SealedBackupReceiptValidInner {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ReceiptPath,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $ReservationIntent,
        [Parameter(Mandatory)] [string] $BackupRoot,
        [AllowNull()] [string] $ExpectedSourceOperationKind,
        [AllowNull()] [string] $ExpectedPlanHash,
        [AllowNull()] [string] $ExpectedDocumentHash,
        [AllowNull()] [string] $ExpectedExecutionContextHash,
        [AllowNull()] [string] $ExpectedControlBaseHash,
        [AllowNull()] [string] $ExpectedFilesystemCapabilityHash,
        [AllowNull()] [string] $ExpectedHomeAuthorityKey
    )

    $slot = [System.IO.Path]::GetFullPath($ReceiptPath)
    if ((Get-SealedBackupReceiptSlotState -ReceiptPath $slot) -cne 'COMPLETE') { throw $script:BackupReceiptVerifierInvalid }
    $schemaValidation = Test-RepositoryJsonSchema -SchemaPath (Join-Path $PSScriptRoot '../schemas/backup-receipt.schema.json') -SchemaRoot (Join-Path $PSScriptRoot '../schemas')
    $capture = Read-CanonicalHeldRegularFileCapture -Path (Join-Path $slot '_meta/receipt.json')
    $null = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $schemaValidation -InstanceBytes ([byte[]] $capture.Bytes) -InstancePath (Join-Path $slot '_meta/receipt.json')
    $document = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $capture.Bytes))
    Test-BackupReceiptSemantics -Document $document

    $intent = Test-SealedBackupReceiptIntent -ReservationIntent $ReservationIntent -BackupRoot $BackupRoot
    if ([string] $document.ReceiptId -cne [string] $intent.ReceiptId -or
        [string] $document.SourceTransactionId -cne [string] $intent.TransactionId -or
        [string] $document.ReceiptPath -cne [string] $intent.ReceiptPath) { throw $script:BackupReceiptIntentMismatch }

    $optionalBindings = [ordered]@{
        SourceOperationKind = 'ExpectedSourceOperationKind'
        PlanHash = 'ExpectedPlanHash'
        DocumentHash = 'ExpectedDocumentHash'
        ExecutionContextHash = 'ExpectedExecutionContextHash'
        ControlBaseHash = 'ExpectedControlBaseHash'
        FilesystemCapabilityHash = 'ExpectedFilesystemCapabilityHash'
        HomeAuthorityKey = 'ExpectedHomeAuthorityKey'
    }
    foreach ($field in @($optionalBindings.Keys)) {
        $parameterName = [string] $optionalBindings[$field]
        if (-not $PSBoundParameters.ContainsKey($parameterName)) { continue }
        $expectedValue = $PSBoundParameters[$parameterName]
        if ($null -ne $expectedValue -and [string] $document[$field] -cne [string] $expectedValue) {
            throw $script:BackupReceiptVerifierInvalid
        }
    }

    $completeCapture = Read-CanonicalHeldRegularFileCapture -Path (Join-Path $slot '_meta/COMPLETE')
    if ([string] ([System.Text.UTF8Encoding]::new($false, $true).GetString([byte[]] $completeCapture.Bytes)) -cne [string] $document.ReceiptHash) {
        throw $script:BackupReceiptVerifierInvalid
    }

    $snapshots = @([object[]] $document.ManagedSnapshots)
    for ($index = 0; $index -lt 3; $index++) {
        $row = $snapshots[$index]
        $platformDir = Join-Path (Join-Path $slot 'snapshot') ([string] $row['Platform']).ToLowerInvariant()
        $rootSnapshot = Get-SafeTreeSnapshot -Root $platformDir
        if ([string] $rootSnapshot.TreeHash -cne [string] $row['RootHash']) { throw $script:BackupReceiptVerifierInvalid }
        foreach ($target in @([object[]] $row['Targets'])) {
            $snapshotTarget = Join-Path $platformDir ([string] $target['Name'])
            if ([string] $target['Status'] -ceq 'COPIED') {
                $targetSnapshot = Get-SafeTreeSnapshot -Root $snapshotTarget
                if ([string] $targetSnapshot.TreeHash -cne [string] $target['SnapshotTreeHash']) { throw $script:BackupReceiptVerifierInvalid }
            }
            else {
                if (Test-Path -LiteralPath $snapshotTarget) { throw $script:BackupReceiptVerifierInvalid }
            }
        }
    }

    foreach ($entry in @(
        @{ Name = 'AuthorityStatePreimage'; Leaf = 'current-env.json' },
        @{ Name = 'RootClaimsPreimage'; Leaf = 'root-claims.json' }
    )) {
        $preimage = $document[$entry.Name]
        if ([string] $preimage['Status'] -cne 'COPIED') { continue }
        $preimageCapture = Read-CanonicalHeldRegularFileCapture -Path (Join-Path (Join-Path $slot 'authority-preimage') ([string] $entry.Leaf))
        # The bound Identity is source provenance and is not re-derivable from
        # the snapshot copy; the copy re-verifies bytes and length only.
        if ([string] $preimageCapture.Sha256 -cne [string] $preimage['Hash'] -or
            [long] $preimageCapture.Length -ne [long] $preimage['Length']) { throw $script:BackupReceiptVerifierInvalid }
    }

    return $document
}
