#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/path-safety-fixtures.ps1')
. (Join-Path $RepoRoot 'scripts/target-context-common.ps1')
# The managed-output-root projection, its dual-read consumers and the recovery
# re-projection live in the canonical transaction/recovery common files; this
# suite owns the target-context fixtures they are asserted against.
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1')

$work = New-PathSafetyFixtureRoot
try {
    $existing = Join-Path $work 'existing'
    $probeRoot = Join-Path $work 'probe'
    [System.IO.Directory]::CreateDirectory($existing) | Out-Null
    [System.IO.Directory]::CreateDirectory($probeRoot) | Out-Null
    $missing = Join-Path $existing 'missing/child/target'

    Write-Host '[metadata-only target context]'
    $before = @([System.IO.Directory]::EnumerateFileSystemEntries($work, '*', [System.IO.SearchOption]::AllDirectories))
    $first = Resolve-TargetContext -Path $missing -Mode MetadataOnly
    $second = Resolve-TargetContext -Path $missing -Mode MetadataOnly
    $after = @([System.IO.Directory]::EnumerateFileSystemEntries($work, '*', [System.IO.SearchOption]::AllDirectories))
    Assert-TestCondition ($first.TargetStatus -eq 'MISSING') 'absent target is represented as MISSING'
    Assert-TestCondition ($first.FilesystemCapabilityStatus -eq 'UNPROBED') 'metadata-only context is explicitly UNPROBED'
    Assert-TestCondition ($first.RequestedInitialRootContextHash -ceq $second.RequestedInitialRootContextHash) 'metadata-only hash is stable across repeated resolution'
    Assert-TestCondition (@(Compare-Object $before $after).Count -eq 0) 'metadata-only resolution performs zero filesystem writes'
    Assert-TestCondition ($first.DeepestExistingParentPath -ceq [System.IO.Path]::GetFullPath($existing)) 'absent context binds the deepest existing parent'
    Assert-TestCondition ((@($first.MissingRemainder) -join '/') -ceq 'missing/child/target') 'absent context binds the normalized missing remainder'

    $caseVariant = Resolve-TargetContext -Path $missing.ToUpperInvariant() -Mode MetadataOnly
    Assert-TestCondition ($caseVariant.LocationKey -ceq $first.LocationKey) 'location key is case-insensitive and separator-stable'

    Write-Host '[held target metadata lease]'
    $heldMissing = Join-Path $existing 'held-missing/child/target'
    $heldMissingReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    Open-SealedHeldTargetContextLease -Path $heldMissing -OwnershipReceiver $heldMissingReceiver
    $heldLease = $heldMissingReceiver.GetDeliveredExact()
    try {
        $heldProjection = Get-SealedHeldTargetContextLease -Lease $heldLease
        $heldLegacy = Resolve-TargetContext -Path $heldMissing -Mode MetadataOnly
        Assert-TestCondition ([string]$heldProjection.TargetStatus -ceq 'MISSING' -and [string]$heldProjection.FilesystemCapabilityStatus -ceq 'UNPROBED' -and $null -eq $heldProjection.FilesystemCapabilityHash) 'held missing target remains metadata-only and explicitly UNPROBED'
        Assert-TestCondition ([string]$heldProjection.RequestedInitialRootContextHash -ceq [string]$heldLegacy.RequestedInitialRootContextHash) 'held target preserves the legacy metadata intent hash'
        Assert-TestCondition ([string]$heldProjection.HeldMetadataHash -cmatch '^[0-9a-f]{64}$') 'held target adds a domain-separated metadata hash'
        [IO.Directory]::CreateDirectory((Join-Path $existing 'held-missing')) | Out-Null
        Assert-PathSafetyThrows -Script { Assert-SealedHeldTargetContextLease -Lease $heldLease | Out-Null } -Pattern '^target-context-plan-stale:' -Message 'held missing target detects appearance of its first absent namespace entry'
    }
    finally { Close-SealedHeldTargetContextLease -Lease $heldLease }
    Assert-PathSafetyThrows -Script { Get-SealedHeldTargetContextLease -Lease $heldLease | Out-Null } -Pattern '^target-context-plan-stale:' -Message 'closed held target lease fails closed'

    Write-Host '[mutation filesystem preflight]'
    $mutation = Resolve-TargetContext -Path $missing -Mode MutationPreflight -ProbeRoot $probeRoot
    Assert-TestCondition ($mutation.FilesystemCapabilityStatus -eq 'SUPPORTED') 'local fixed NTFS mutation preflight is supported'
    Assert-TestCondition (-not [string]::IsNullOrWhiteSpace($mutation.FilesystemCapabilityHash)) 'mutation preflight binds a filesystem capability hash'
    Assert-TestCondition (@([System.IO.Directory]::EnumerateFileSystemEntries($probeRoot)).Count -eq 0) 'capability probe cleans its dedicated slot'
    Assert-TestCondition ($mutation.RequestedInitialRootContextHash -ceq $first.RequestedInitialRootContextHash) 'mutation preflight independently preserves metadata-only intent hash'

    Write-Host '[identity-owned capability probe cleanup]'
    $probeMetadata = Get-TargetMetadataContext -Path $probeRoot
    $probeIdentity = [string]$probeMetadata.DeepestExistingParentIdentity
    $targetVolume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($existing)
    Assert-PathSafetyThrows -Script {
        Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $probeRoot -VolumeInfo $targetVolume -ExpectedProbeRootIdentity '00000000:0000000000000001' | Out-Null
    } -Pattern '^capability-probe-root-stale$' -Message 'capability probe rejects a stale expected ProbeRoot identity before writing'
    Assert-TestCondition (@([IO.Directory]::EnumerateFileSystemEntries($probeRoot)).Count -eq 0) 'stale ProbeRoot identity rejection creates no slot'

    $preexistingResiduePath = Join-Path $probeRoot '.TARGET-CAPABILITY-preexisting-foreign'
    $preexistingResidueFile = Join-Path $preexistingResiduePath 'sentinel.bin'
    $preexistingResidueBytes = [Text.UTF8Encoding]::new($false).GetBytes('preexisting foreign residue must survive')
    [IO.Directory]::CreateDirectory($preexistingResiduePath) | Out-Null
    [IO.File]::WriteAllBytes($preexistingResidueFile,$preexistingResidueBytes)
    try {
        Assert-PathSafetyThrows -Script {
            Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $probeRoot -VolumeInfo $targetVolume -ExpectedProbeRootIdentity $probeIdentity | Out-Null
        } -Pattern '^capability-probe-root-residue$' -Message 'preexisting foreign ProbeRoot residue fails closed before the probe creates a slot'
        $preexistingResidueEntries = @([IO.Directory]::EnumerateFileSystemEntries($probeRoot))
        Assert-TestCondition ($preexistingResidueEntries.Count -eq 1 -and
            [IO.Path]::GetFullPath($preexistingResidueEntries[0]) -ceq [IO.Path]::GetFullPath($preexistingResiduePath) -and
            [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($preexistingResidueFile),$preexistingResidueBytes)) 'preexisting residue rejection preserves exact foreign bytes and creates zero owned slots'
    }
    finally {
        if (Test-Path -LiteralPath $preexistingResidueFile -PathType Leaf) { [IO.File]::Delete($preexistingResidueFile) }
        if (Test-Path -LiteralPath $preexistingResiduePath -PathType Container) { [IO.Directory]::Delete($preexistingResiduePath) }
    }

    $originalProbeCleanup = (Get-Command Remove-TargetFilesystemCapabilityProbeOwnedSlot -CommandType Function -ErrorAction Stop).ScriptBlock
    $foreignProbeBytes = [Text.UTF8Encoding]::new($false).GetBytes('foreign probe child must survive')
    $postResidueState = [pscustomobject]@{ Path=(Join-Path $probeRoot '.Target-Capability-post-foreign'); Injected=$false }
    $postResidueCleanup = {
        param(
            [Parameter(Mandatory)]$SlotHandle,
            [Parameter(Mandatory)][string]$SlotIdentity,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedFiles,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedDirectories
        )
        & $originalProbeCleanup -SlotHandle $SlotHandle -SlotIdentity $SlotIdentity -OwnedFiles $OwnedFiles -OwnedDirectories $OwnedDirectories
        [IO.Directory]::CreateDirectory($postResidueState.Path) | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $postResidueState.Path 'sentinel.bin'),$foreignProbeBytes)
        $postResidueState.Injected=$true
    }.GetNewClosure()
    try {
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $postResidueCleanup
        Assert-PathSafetyThrows -Script {
            Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $probeRoot -VolumeInfo $targetVolume -ExpectedProbeRootIdentity $probeIdentity | Out-Null
        } -Pattern '^capability-probe-root-residue$' -Message 'foreign ProbeRoot residue injected after exact owned cleanup fails closed'
        $postResidueEntries = @([IO.Directory]::EnumerateFileSystemEntries($probeRoot))
        Assert-TestCondition ($postResidueState.Injected -and $postResidueEntries.Count -eq 1 -and
            [IO.Path]::GetFullPath($postResidueEntries[0]) -ceq [IO.Path]::GetFullPath($postResidueState.Path) -and
            [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes((Join-Path $postResidueState.Path 'sentinel.bin')),$foreignProbeBytes)) 'post-probe residue rejection preserves foreign bytes after removing the exact owned slot'
    }
    finally {
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $originalProbeCleanup
        $postResidueFile = Join-Path $postResidueState.Path 'sentinel.bin'
        if (Test-Path -LiteralPath $postResidueFile -PathType Leaf) { [IO.File]::Delete($postResidueFile) }
        if (Test-Path -LiteralPath $postResidueState.Path -PathType Container) { [IO.Directory]::Delete($postResidueState.Path) }
    }

    $foreignProbeState = [pscustomobject]@{ Injected=$false; SlotPath=$null }
    $foreignProbeCleanup = {
        param(
            [Parameter(Mandatory)]$SlotHandle,
            [Parameter(Mandatory)][string]$SlotIdentity,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedFiles,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedDirectories
        )
        $foreign = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($SlotHandle,'foreign.bin',$foreignProbeBytes)
        try { $foreignProbeState.Injected=$true }
        finally { $foreign.Dispose() }
        & $originalProbeCleanup -SlotHandle $SlotHandle -SlotIdentity $SlotIdentity -OwnedFiles $OwnedFiles -OwnedDirectories $OwnedDirectories
    }.GetNewClosure()
    try {
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $foreignProbeCleanup
        Assert-PathSafetyThrows -Script {
            Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $probeRoot -VolumeInfo $targetVolume -ExpectedProbeRootIdentity $probeIdentity | Out-Null
        } -Pattern '^capability-probe-cleanup-failed: capability-probe-owned-slot-cleanup-failed:' -Message 'foreign child injected after the real probe makes owned-slot cleanup fail closed'
        $foreignProbeSlots = @([IO.Directory]::EnumerateDirectories($probeRoot,'.target-capability-*'))
        Assert-TestCondition ($foreignProbeState.Injected -and $foreignProbeSlots.Count -eq 1) 'foreign-child cleanup failure preserves exactly the test-owned probe slot'
        $foreignProbeState.SlotPath = $foreignProbeSlots[0]
        $foreignProbeFile = Join-Path $foreignProbeState.SlotPath 'foreign.bin'
        Assert-TestCondition ((Test-Path -LiteralPath $foreignProbeFile -PathType Leaf) -and
            [Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($foreignProbeFile),$foreignProbeBytes)) 'foreign-child cleanup failure preserves foreign bytes exactly'
    }
    finally {
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $originalProbeCleanup
        if ($null -ne $foreignProbeState.SlotPath -and (Test-Path -LiteralPath $foreignProbeState.SlotPath)) {
            $foreignSlotFull = [IO.Path]::GetFullPath([string]$foreignProbeState.SlotPath)
            if ([IO.Path]::GetDirectoryName($foreignSlotFull) -cne [IO.Path]::GetFullPath($probeRoot) -or
                [IO.Path]::GetFileName($foreignSlotFull) -cnotmatch '^\.target-capability-[0-9a-f]{32}$' -or
                [bool][AiAgentDotfiles.NoFollowFile]::Inspect($foreignSlotFull).IsReparsePoint) { throw "unsafe foreign probe fixture cleanup target: $foreignSlotFull" }
            [IO.Directory]::Delete($foreignSlotFull,$true)
        }
    }

    $originalSemanticHash = (Get-Command Get-SemanticJsonHash -CommandType Function -ErrorAction Stop).ScriptBlock
    $combinedProbeState = [pscustomobject]@{ Injected=$false; SlotPath=$null; Error=$null }
    $combinedProbeCleanup = {
        param(
            [Parameter(Mandatory)]$SlotHandle,
            [Parameter(Mandatory)][string]$SlotIdentity,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedFiles,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedDirectories
        )
        $foreign = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($SlotHandle,'foreign-primary.bin',$foreignProbeBytes)
        try { $combinedProbeState.Injected=$true }
        finally { $foreign.Dispose() }
        & $originalProbeCleanup -SlotHandle $SlotHandle -SlotIdentity $SlotIdentity -OwnedFiles $OwnedFiles -OwnedDirectories $OwnedDirectories
    }.GetNewClosure()
    try {
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $combinedProbeCleanup
        Set-Item -LiteralPath Function:\Get-SemanticJsonHash -Value { throw 'injected-capability-primary' }
        try {
            Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $probeRoot -VolumeInfo $targetVolume -ExpectedProbeRootIdentity $probeIdentity | Out-Null
        }
        catch { $combinedProbeState.Error=$_ }
        $combinedProbeSlots = @([IO.Directory]::EnumerateDirectories($probeRoot,'.target-capability-*'))
        if ($combinedProbeSlots.Count -eq 1) { $combinedProbeState.SlotPath=$combinedProbeSlots[0] }
        Assert-TestCondition ($null -ne $combinedProbeState.Error -and
            $combinedProbeState.Error.Exception.Message -match '^capability-probe-primary-and-cleanup-failed: primary=injected-capability-primary;' -and
            $combinedProbeState.Error.Exception.InnerException -is [AggregateException] -and
            @($combinedProbeState.Error.Exception.InnerException.InnerExceptions).Count -eq 2 -and
            [string]$combinedProbeState.Error.Exception.InnerException.InnerExceptions[0].Message -ceq 'injected-capability-primary' -and
            [string]$combinedProbeState.Error.Exception.InnerException.InnerExceptions[1].Message -match '^capability-probe-cleanup-failed:' -and
            [string]$combinedProbeState.Error.Exception.Data['CapabilityProbePrimaryFailure'] -ceq 'injected-capability-primary' -and
            [string]$combinedProbeState.Error.Exception.Data['CapabilityProbeCleanupFailure'] -match '^capability-probe-cleanup-failed:' -and
            $combinedProbeState.Injected) 'primary plus cleanup failure publishes one stable combined error with both original messages'
        Assert-TestCondition ($combinedProbeSlots.Count -eq 1 -and
            (Get-Content -Raw -LiteralPath (Join-Path $combinedProbeState.SlotPath 'foreign-primary.bin')) -ceq 'foreign probe child must survive') 'combined failure preserves the foreign child while removing exact owned artifacts'
    }
    finally {
        Set-Item -LiteralPath Function:\Get-SemanticJsonHash -Value $originalSemanticHash
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $originalProbeCleanup
        if ($null -ne $combinedProbeState.SlotPath -and (Test-Path -LiteralPath $combinedProbeState.SlotPath)) {
            $combinedSlotFull = [IO.Path]::GetFullPath([string]$combinedProbeState.SlotPath)
            if ([IO.Path]::GetDirectoryName($combinedSlotFull) -cne [IO.Path]::GetFullPath($probeRoot) -or
                [IO.Path]::GetFileName($combinedSlotFull) -cnotmatch '^\.target-capability-[0-9a-f]{32}$' -or
                [bool][AiAgentDotfiles.NoFollowFile]::Inspect($combinedSlotFull).IsReparsePoint) { throw "unsafe combined probe fixture cleanup target: $combinedSlotFull" }
            [IO.Directory]::Delete($combinedSlotFull,$true)
        }
    }

    $probeMoveState = [pscustomobject]@{ SlotAttempted=$false;SlotBlocked=$false;RootAttempted=$false;RootBlocked=$false }
    $probeRootMoved = $probeRoot + '-moved'
    $leaseProbeCleanup = {
        param(
            [Parameter(Mandatory)]$SlotHandle,
            [Parameter(Mandatory)][string]$SlotIdentity,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedFiles,
            [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$OwnedDirectories
        )
        $slotCandidates = @([IO.Directory]::EnumerateDirectories($probeRoot,'.target-capability-*'))
        if ($slotCandidates.Count -eq 1) {
            $probeMoveState.SlotAttempted=$true
            try { [IO.Directory]::Move($slotCandidates[0],($slotCandidates[0] + '-moved')) }
            catch { $probeMoveState.SlotBlocked=$true }
        }
        $probeMoveState.RootAttempted=$true
        try { [IO.Directory]::Move($probeRoot,$probeRootMoved) }
        catch { $probeMoveState.RootBlocked=$true }
        & $originalProbeCleanup -SlotHandle $SlotHandle -SlotIdentity $SlotIdentity -OwnedFiles $OwnedFiles -OwnedDirectories $OwnedDirectories
    }.GetNewClosure()
    try {
        Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $leaseProbeCleanup
        $leaseProbeHash = Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $probeRoot -VolumeInfo $targetVolume -ExpectedProbeRootIdentity $probeIdentity
        Assert-TestCondition ($leaseProbeHash -ceq [string]$mutation.FilesystemCapabilityHash -and
            $probeMoveState.SlotAttempted -and $probeMoveState.SlotBlocked -and
            $probeMoveState.RootAttempted -and $probeMoveState.RootBlocked) 'held slot and complete ProbeRoot containment chain block namespace replacement throughout cleanup'
        Assert-TestCondition ((Test-Path -LiteralPath $probeRoot -PathType Container) -and
            -not (Test-Path -LiteralPath $probeRootMoved) -and @([IO.Directory]::EnumerateFileSystemEntries($probeRoot)).Count -eq 0) 'blocked replacement attempts leave the original ProbeRoot identity and zero owned residue'
    }
    finally { Set-Item -LiteralPath Function:\Remove-TargetFilesystemCapabilityProbeOwnedSlot -Value $originalProbeCleanup }

    $targetContextSource = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts/target-context-common.ps1')
    $probeSourceMatch = [regex]::Match($targetContextSource,'(?s)function Remove-TargetFilesystemCapabilityProbeOwnedSlot \{.+?function Resolve-TargetContext \{').Value
    Assert-TestCondition ($probeSourceMatch -match 'Open-SafeDirectoryContainmentChain' -and
        $probeSourceMatch -match 'GetChildNames' -and
        $probeSourceMatch -match 'CreateHeldChildDirectoryForCleanup' -and
        $probeSourceMatch -match 'DeleteHeldEmptyDirectoryIfIdentity' -and
        $probeSourceMatch -notmatch 'Remove-Item|\[IO\.Directory\]::Delete|\[IO\.File\]::Delete|-Recurse|-like\s+''\.target-capability-\*''') 'production capability cleanup uses held exact identities with no wildcard, recursive, or path-delete fallback'

    Write-Host '[unsupported locations and capabilities]'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path 'relative-target' -Mode MetadataOnly } -Pattern 'absolute|fully-qualified|relative' -Message 'relative target paths are rejected before cwd-bound normalization'
    $cwdBeforeRootProbe = Join-Path $work 'cwd-before-root-probe'
    [System.IO.Directory]::CreateDirectory($cwdBeforeRootProbe) | Out-Null
    Push-Location $cwdBeforeRootProbe
    try {
        Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path ([System.IO.Path]::GetPathRoot($work)) -Mode MetadataOnly } -Pattern 'root|volume' -Message 'volume root target is rejected without degrading to a cwd-relative drive path'
    }
    finally { Pop-Location }
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path $existing -Mode MetadataOnly -HomeRoot $existing } -Pattern 'HomeRoot' -Message 'HomeRoot itself is rejected'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $existing '.system/child') -Mode MetadataOnly } -Pattern '\.system' -Message '.system target is rejected'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $existing 'child') -Mode MetadataOnly -ForbiddenRoots @($existing) } -Pattern 'overlap' -Message 'source/target ancestor overlap is rejected'
    foreach ($case in @(
        @{ DriveType='Network'; FileSystemType='NTFS' },
        @{ DriveType='Removable'; FileSystemType='NTFS' },
        @{ DriveType='Fixed'; FileSystemType='ReFS' },
        @{ DriveType='Fixed'; FileSystemType='FAT32' },
        @{ DriveType='Unknown'; FileSystemType='UNKNOWN' }
    )) {
        Assert-PathSafetyThrows -Script { Assert-SupportedTargetFilesystem -DriveType $case.DriveType -FileSystemType $case.FileSystemType } -Pattern 'unsupported' -Message "unsupported filesystem is rejected: $($case.DriveType)/$($case.FileSystemType)"
    }

    $outside = Join-Path $work 'outside'
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    $junction = Join-Path $existing 'junction'
    New-PathSafetyJunction -Path $junction -Target $outside | Out-Null
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $junction 'child') -Mode MetadataOnly } -Pattern 'reparse' -Message 'reparse ancestor is rejected without resolution'

    $danglingOutside = Join-Path $work 'dangling-outside'
    [System.IO.Directory]::CreateDirectory($danglingOutside) | Out-Null
    $danglingJunction = Join-Path $existing 'dangling-junction'
    New-PathSafetyJunction -Path $danglingJunction -Target $danglingOutside | Out-Null
    [System.IO.Directory]::Delete($danglingOutside)
    $danglingMarker = Get-NoFollowRootEntryMarker -Path $danglingJunction
    Assert-TestCondition ([string]$danglingMarker.EntryType -ceq 'ReparsePoint') 'fixture remains a dangling reparse entry'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $danglingJunction 'child') -Mode MetadataOnly } -Pattern 'reparse' -Message 'dangling reparse ancestor is rejected rather than classified MISSING'

    Write-Host '[repo-local generated output root plan projection]'
    # The projection is plan-only and takes its managed output root list as a
    # parameter; the canonical callers pass the production enumeration asserted
    # here, and the fixture uses repository-shaped roots instead of the real
    # profile.
    $projectionRepo = Join-Path $work 'projection-repo'
    $generatedRoots = @(Get-CanonicalGeneratedOutputRoots -RepoRoot $projectionRepo)
    Assert-TestCondition ($generatedRoots.Count -eq 3 -and
        (@($generatedRoots | ForEach-Object { [IO.Path]::GetRelativePath($projectionRepo,$_).Replace([char]92,[char]47) }) -join ',') -ceq 'claude/skills,codex/skills,reasonix/skills' -and
        @($generatedRoots | Where-Object { -not [IO.Path]::IsPathFullyQualified($_) }).Count -eq 0) 'the generated output root enumeration is the three fully-qualified repo-local roots'
    $projectionRoot = $generatedRoots[0]
    $projectionTarget = Join-Path $projectionRoot 'skill-a'
    [IO.Directory]::CreateDirectory($projectionTarget) | Out-Null
    $projectionContext = Resolve-TargetContext -Path $projectionTarget -Mode MetadataOnly
    $legacyHash = [string]$projectionContext.RequestedInitialRootContextHash
    $projectedHash = Get-CanonicalPlanTargetContextHash -TargetContext $projectionContext -ManagedOutputRoots $generatedRoots
    Assert-TestCondition ($legacyHash -cmatch '^[0-9a-f]{64}$' -and $projectedHash -cmatch '^[0-9a-f]{64}$' -and $projectedHash -cne $legacyHash) 'plan projection is a domain-separated 64-hex digest of the legacy metadata context'
    [IO.Directory]::Delete($projectionRoot,$true) | Out-Null
    [IO.Directory]::CreateDirectory($projectionTarget) | Out-Null
    $churnedContext = Resolve-TargetContext -Path $projectionTarget -Mode MetadataOnly
    Assert-TestCondition ([string]$churnedContext.RequestedInitialRootContextHash -cne $legacyHash -and
        (Get-CanonicalPlanTargetContextHash -TargetContext $churnedContext -ManagedOutputRoots $generatedRoots) -ceq $projectedHash) 'identity churn inside a generated output root moves the legacy digest and leaves the projected digest stable'
    [IO.Directory]::Delete((Join-Path $projectionRepo 'claude'),$true) | Out-Null
    [IO.Directory]::CreateDirectory($projectionTarget) | Out-Null
    $aboveContext = Resolve-TargetContext -Path $projectionTarget -Mode MetadataOnly
    Assert-TestCondition ((Get-CanonicalPlanTargetContextHash -TargetContext $aboveContext -ManagedOutputRoots $generatedRoots) -cne $projectedHash) 'identity churn on a repository ancestor above the generated output roots still moves the projected digest'

    Write-Host '[generated output root false-stale class]'
    $reachRepo = Join-Path $work 'reachability-repo'
    $reachRoot = Join-Path $reachRepo 'claude/skills'
    $reachTarget = Join-Path $reachRoot 'skill-a'
    [IO.Directory]::CreateDirectory($reachTarget) | Out-Null
    $reachRow = New-CanonicalTargetRow -Order 0 -TargetKind directory -Role generated -Platform Claude -RepoRoot $reachRepo -TargetPath $reachTarget -CandidatePath $null -Current ([ordered]@{State='MISSING'}) -Candidate ([ordered]@{State='MISSING'})
    $reachBefore = Resolve-TargetContext -Path $reachTarget -Mode MetadataOnly
    # build-skills.ps1 rebuild: the generated root directory object is replaced.
    [IO.Directory]::Delete($reachRoot,$true) | Out-Null
    [IO.Directory]::CreateDirectory($reachTarget) | Out-Null
    $reachAfter = Resolve-TargetContext -Path $reachTarget -Mode MetadataOnly
    Assert-TestCondition ([string]$reachBefore.RequestedInitialRootContextHash -cne [string]$reachAfter.RequestedInitialRootContextHash -and
        [string]$reachRow.TargetContextHash -cne [string]$reachBefore.RequestedInitialRootContextHash -and
        [string]$reachRow.TargetContextHash -cne [string]$reachAfter.RequestedInitialRootContextHash -and
        [string]$reachRow.TargetContextHash -ceq (Get-CanonicalPlanTargetContextHash -TargetContext $reachAfter -ManagedOutputRoots @(Get-CanonicalGeneratedOutputRoots -RepoRoot $reachRepo))) 'a real plan row under claude/skills survives a generated-root rebuild on the projected digest while both legacy digests move'
    $originalLiveRoots = (Get-Command Get-CanonicalDefaultLiveRoots -CommandType Function -ErrorAction Stop).ScriptBlock
    try {
        Set-Item -LiteralPath Function:\Get-CanonicalDefaultLiveRoots -Value { throw 'canonical-known-folder-unavailable' }
        $rowError = $null
        try { $null=New-CanonicalTargetRow -Order 0 -TargetKind directory -Role generated -Platform Claude -RepoRoot $reachRepo -TargetPath $reachTarget -CandidatePath $null -Current ([ordered]@{State='MISSING'}) -Candidate ([ordered]@{State='MISSING'}) } catch { $rowError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $rowError) 'plan row generation no longer depends on the live/home known-folder enumeration'
    }
    finally { Set-Item -LiteralPath Function:\Get-CanonicalDefaultLiveRoots -Value $originalLiveRoots }

    $anchorRepo = Join-Path $work 'anchor-repo'
    $anchorRoot = Join-Path $anchorRepo 'claude/skills'
    $anchorInsideParent = Join-Path $anchorRoot 'present-a'
    $anchorInsideMissing = Join-Path $anchorInsideParent 'child'
    [IO.Directory]::CreateDirectory($anchorInsideParent) | Out-Null
    $anchorInsideBefore = Get-CanonicalPlanTargetContextHash -TargetContext (Resolve-TargetContext -Path $anchorInsideMissing -Mode MetadataOnly) -ManagedOutputRoots @($anchorRoot)
    [IO.Directory]::Delete($anchorInsideParent,$true) | Out-Null
    [IO.Directory]::CreateDirectory($anchorInsideParent) | Out-Null
    $anchorInsideAfter = Get-CanonicalPlanTargetContextHash -TargetContext (Resolve-TargetContext -Path $anchorInsideMissing -Mode MetadataOnly) -ManagedOutputRoots @($anchorRoot)
    Assert-TestCondition ($anchorInsideBefore -ceq $anchorInsideAfter) 'a MISSING target inside a generated output root keeps no creation anchor identity'
    $anchorOutsideMissing = Join-Path $anchorRepo 'claude/missing-a/child'
    $anchorOutsideContext = Resolve-TargetContext -Path $anchorOutsideMissing -Mode MetadataOnly
    Assert-TestCondition ([string]$anchorOutsideContext.TargetStatus -ceq 'MISSING' -and
        [string]$anchorOutsideContext.DeepestExistingParentPath -ceq [IO.Path]::GetFullPath((Join-Path $anchorRepo 'claude'))) 'fixture binds a MISSING target whose deepest existing parent sits outside the generated output root inside the repository'
    $anchorOutsideBefore = Get-CanonicalPlanTargetContextHash -TargetContext $anchorOutsideContext -ManagedOutputRoots @($anchorRoot)
    [IO.Directory]::Delete((Join-Path $anchorRepo 'claude'),$true) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $anchorRepo 'claude')) | Out-Null
    $anchorOutsideAfter = Get-CanonicalPlanTargetContextHash -TargetContext (Resolve-TargetContext -Path $anchorOutsideMissing -Mode MetadataOnly) -ManagedOutputRoots @($anchorRoot)
    Assert-TestCondition ($anchorOutsideBefore -cne $anchorOutsideAfter) 'a MISSING target outside the generated output roots keeps its creation anchor identity'

    Write-Host '[generated output root dual-read consumers]'
    $consumerRepo = Join-Path $work 'consumer-repo'
    [IO.Directory]::CreateDirectory($consumerRepo) | Out-Null
    & git -C $consumerRepo init --quiet 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "unable to create the dual-read fixture repository: git init exited $LASTEXITCODE" }
    & git -C $consumerRepo -c user.email=fixture@example.invalid -c user.name=fixture commit --quiet --allow-empty -m fixture 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "unable to commit the dual-read fixture repository: git commit exited $LASTEXITCODE" }
    $consumerGit = Get-CanonicalGitContext -RepoRoot $consumerRepo
    $consumerPaths = Get-CanonicalTransactionContractPaths -GitContext $consumerGit
    $consumerRoot = Join-Path $consumerRepo 'claude/skills'
    [IO.Directory]::CreateDirectory($consumerRoot) | Out-Null
    $consumerTarget = Join-Path $consumerRoot 'skill-a'
    $consumerPresent = Join-Path $consumerRoot 'skill-present'
    [IO.Directory]::CreateDirectory($consumerPresent) | Out-Null
    $consumerContext = Resolve-TargetContext -Path $consumerTarget -Mode MetadataOnly
    $consumerLegacy = [string]$consumerContext.RequestedInitialRootContextHash
    $consumerRoots = @(Get-CanonicalGeneratedOutputRoots -RepoRoot $consumerRepo)
    $consumerProjected = Get-CanonicalPlanTargetContextHash -TargetContext $consumerContext -ManagedOutputRoots $consumerRoots
    $consumerTargetId = Get-CanonicalJournalTargetId -Order 0 -TargetKind directory -Role generated -Platform Claude -TargetPath ([IO.Path]::GetFullPath($consumerTarget))
    $stagingProbe = {
        param([string]$ContextHash,[string]$Name)
        $recovery = Join-Path $work $Name
        $payload = [ordered]@{RepoRoot=[IO.Path]::GetFullPath($consumerRepo);Targets=@([ordered]@{Order=0;CandidatePath=$null;Candidate=[ordered]@{State='MISSING'}})}
        $row = [ordered]@{
            TargetId=$consumerTargetId;Order=0;TargetKind='directory';Role='generated';Platform='Claude';TargetPath=[IO.Path]::GetFullPath($consumerTarget)
            PreimagePath=(Join-Path $recovery 'preimage/row-0');SwapOldPath=(Join-Path $recovery 'swap-old/row-0');StagedPath=$null
            Current=[ordered]@{State='MISSING'};Candidate=[ordered]@{State='MISSING'};TargetContextHash=$ContextHash
        }
        $null=Initialize-CanonicalReviewedStaging -PlanPayload $payload -RecoveryTransactionRoot $recovery -Targets @($row)
    }.GetNewClosure()
    $global:PathSafetyRecoveryEvidenceFixture = $null
    $originalEvidencePayload = (Get-Command Get-CanonicalRecoveryEvidencePayload -CommandType Function -ErrorAction Stop).ScriptBlock
    try {
        $stagingError = $null
        try { & $stagingProbe $consumerLegacy 'staging-legacy' } catch { $stagingError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $stagingError) 'staging: a reviewed row carrying the legacy whole-object digest still validates'
        $stagingError = $null
        try { & $stagingProbe $consumerProjected 'staging-projected' } catch { $stagingError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $stagingError) 'staging: a reviewed row carrying the projected plan digest validates'
        Assert-PathSafetyThrows -Script { & $stagingProbe ('0' * 64) 'staging-wrong' } -Pattern '^canonical target context changed before staging$' -Message 'staging: an unrelated digest is rejected before any staging write'

        $consumerTxId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
        $consumerNamespace = Join-Path $consumerPaths.TransactionsRoot (Join-Path $consumerGit.WorktreeId $consumerTxId)
        $consumerControlBase = Join-Path $work 'consumer-control'
        $consumerRecoveryRoot = Join-Path $work 'consumer-recovery'
        $consumerRecoveryTx = Join-Path $consumerRecoveryRoot (Join-Path $consumerGit.WorktreeId $consumerTxId)
        $consumerRepoId = Get-CanonicalRepoIdentity $consumerGit
        $recoveryStateProbe = {
            param([string]$ContextHash)
            $state = [pscustomobject][ordered]@{
                Header = [ordered]@{
                    SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$consumerTxId;CanonicalOperationKind='setup'
                    OriginalDocumentHash=('e' * 64);OriginalPlanHash=('f' * 64);RepoId=$consumerRepoId
                    GitCommonDirHash=[string]$consumerGit.GitCommonDirHash;WorktreeId=[string]$consumerGit.WorktreeId
                    TransactionNamespace=[IO.Path]::GetFullPath($consumerNamespace);RecoveryTransactionRoot=[IO.Path]::GetFullPath($consumerRecoveryTx)
                    ExpectedPostconditionsHash=('a' * 64)
                    SetupRecovery=[ordered]@{
                        ClaimPath=Join-Path $consumerControlBase (Join-Path 'canonical-roots' ($consumerRepoId + '.json'))
                        StatePath=[string]$consumerPaths.SetupStatePath
                        ExpectedStateProjection=[ordered]@{CanonicalRecoveryRoot=$consumerRecoveryRoot;ControlBase=$consumerControlBase}
                    }
                    Targets=@([ordered]@{
                        TargetId=$consumerTargetId;Order=0;TargetKind='directory';Role='generated';Platform='Claude';TargetPath=[IO.Path]::GetFullPath($consumerTarget)
                        PreimagePath=Join-Path $consumerRecoveryTx ('preimage/' + $consumerTargetId);SwapOldPath=Join-Path $consumerRecoveryTx ('swap-old/' + $consumerTargetId)
                        StagedPath=Join-Path $consumerRecoveryTx ('staged/' + $consumerTargetId)
                        Current=[ordered]@{State='MISSING'};Candidate=[ordered]@{State='MISSING'};TargetContextHash=$ContextHash
                    })
                }
                Records=@()
                TransactionNamespace=[IO.Path]::GetFullPath($consumerNamespace)
            }
            $null=Assert-CanonicalRecoveryStateContext -State $state -RepoRoot $consumerRepo
        }.GetNewClosure()
        $stateError = $null
        try { & $recoveryStateProbe $consumerLegacy } catch { $stateError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $stateError) 'recovery state context: a reviewed header carrying the legacy whole-object digest still validates'
        $stateError = $null
        try { & $recoveryStateProbe $consumerProjected } catch { $stateError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $stateError) 'recovery state context: a reviewed header carrying the projected plan digest validates'
        Assert-PathSafetyThrows -Script { & $recoveryStateProbe ('0' * 64) } -Pattern '^manual-recovery-required: target context hash differs from reviewed header$' -Message 'recovery state context: an unrelated digest is rejected'
        # One churn of the generated output root identity serves both consumers.
        [IO.Directory]::Delete($consumerRoot,$true) | Out-Null
        [IO.Directory]::CreateDirectory($consumerRoot) | Out-Null
        [IO.Directory]::CreateDirectory($consumerPresent) | Out-Null
        $stateError = $null
        try { & $recoveryStateProbe $consumerProjected } catch { $stateError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $stateError) 'recovery state context: identity churn inside the generated output root leaves the projected digest valid'
        Assert-PathSafetyThrows -Script { & $recoveryStateProbe $consumerLegacy } -Pattern '^manual-recovery-required: target context hash differs from reviewed header$' -Message 'recovery state context: the same churn still rejects the legacy whole-object digest'
        $stagingError = $null
        try { & $stagingProbe $consumerProjected 'staging-churned' } catch { $stagingError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $stagingError) 'staging: identity churn inside the generated output root leaves the projected digest valid'
        Assert-PathSafetyThrows -Script { & $stagingProbe $consumerLegacy 'staging-churned-legacy' } -Pattern '^canonical target context changed before staging$' -Message 'staging: the same churn still rejects the legacy whole-object digest'

        $leaseReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SealedHeldTargetContextLease -Path $consumerTarget -OwnershipReceiver $leaseReceiver
        $lease = $leaseReceiver.GetDeliveredExact()
        try {
            $leaseProjection = Get-SealedHeldTargetContextLease -Lease $lease
            $leaseProjected = Get-CanonicalPlanTargetContextHash -TargetContext $leaseProjection -ManagedOutputRoots (Get-CanonicalGeneratedOutputRoots -RepoRoot $consumerRepo)
            Assert-TestCondition ((Assert-SealedHeldTargetContextLease -Lease $lease) -and $leaseProjected -ceq $consumerProjected) 'held lease: the legacy digest validates under the default empty root list and the held projection hashes like the resolved context'
            # Production writes the legacy digest into this field; a caller holding a
            # projected plan/journal row must supply the same managed output root list.
            $leaseProjection.RequestedInitialRootContextHash = $leaseProjected
            $leaseProjection.HeldMetadataHash = Get-SealedHeldTargetMetadataHash -Projection $leaseProjection
            Assert-TestCondition ($null -ne (Assert-SealedHeldTargetContextLease -Lease $lease -ManagedOutputRoots $consumerRoots)) 'held lease: the projected digest validates when the caller supplies the matching generated output root list'
            Assert-PathSafetyThrows -Script { Assert-SealedHeldTargetContextLease -Lease $lease | Out-Null } -Pattern '^target-context-plan-stale: held target metadata hash mismatch$' -Message 'held lease: the projected digest is rejected without the managed output root list (bounded dual-read)'
        }
        finally { Close-SealedHeldTargetContextLease -Lease $lease }

        Write-Host '[generated output root recovery re-projection]'
        $reviewedTuple = [ordered]@{
            Target=[ordered]@{State='PRESENT';Type='Directory';Hash=('a' * 64);Identity='reviewed-identity'}
            Preimage=[ordered]@{State='MISSING'};SwapOld=[ordered]@{State='MISSING'};Staged=[ordered]@{State='MISSING'}
        }
        $reviewedRow = [ordered]@{TargetId=$consumerTargetId;TargetPath=[IO.Path]::GetFullPath($consumerPresent);Tuple=$reviewedTuple}
        $currentRows = @([ordered]@{
            TargetId=$consumerTargetId;TargetPath=[IO.Path]::GetFullPath($consumerPresent)
            Tuple=[ordered]@{
                Target=[ordered]@{State='PRESENT';Type='Directory';Hash=('a' * 64);Identity='churned-identity'}
                Preimage=[ordered]@{State='MISSING'};SwapOld=[ordered]@{State='MISSING'};Staged=[ordered]@{State='MISSING'}
            }
        })
        $observedState = [ordered]@{State='PRESENT';Type='Directory';Hash=('b' * 64);Identity='workspace-identity'}
        $reviewedPayload = [ordered]@{Targets=@($reviewedRow);WorkspaceInventory=@([ordered]@{Role='preimage';ReconciledState='READY';ObservedState=$observedState})}
        $currentPayload = [ordered]@{Targets=@($currentRows);WorkspaceInventory=@([ordered]@{Role='preimage';ReconciledState='READY';ObservedState=$observedState})}
        Assert-TestCondition ((Get-PlanHash -PlanPayload $currentPayload) -cne (Get-PlanHash -PlanPayload $reviewedPayload)) 're-projection fixture: identity drift alone already makes the re-derived payload hash differ from the reviewed plan hash'
        $null=Get-CanonicalRecoveryTargetIdentityProjection -Targets @($currentPayload.Targets) -ReviewedTargets @($reviewedPayload.Targets) -ManagedOutputRoots $consumerRoots
        Assert-TestCondition ([string]$currentRows[0].Tuple.Target.Identity -ceq 'reviewed-identity' -and [string]$currentPayload.WorkspaceInventory[0].ObservedState.Identity -ceq 'workspace-identity' -and
            (Get-PlanHash -PlanPayload $currentPayload) -ceq (Get-PlanHash -PlanPayload $reviewedPayload)) 're-projection replaces only the churned target identity under the generated output root and reproduces the reviewed plan hash without touching the workspace observed identity'
        $currentRows[0].Tuple.Target.Identity = 'churned-identity';$currentRows[0].Tuple.Target.Hash = ('0' * 64)
        $null=Get-CanonicalRecoveryTargetIdentityProjection -Targets @($currentPayload.Targets) -ReviewedTargets @($reviewedPayload.Targets) -ManagedOutputRoots $consumerRoots
        Assert-TestCondition ([string]$currentRows[0].Tuple.Target.Identity -ceq 'churned-identity' -and (Get-PlanHash -PlanPayload $currentPayload) -cne (Get-PlanHash -PlanPayload $reviewedPayload)) 're-projection refuses a tuple whose hash differs from the reviewed tuple, so the reviewed plan goes stale'
        $currentRows[0].Tuple.Target.Identity = 'churned-identity';$currentRows[0].Tuple.Target.Hash = ('a' * 64);$currentRows[0].Tuple.Target.Type = 'File'
        $null=Get-CanonicalRecoveryTargetIdentityProjection -Targets @($currentPayload.Targets) -ReviewedTargets @($reviewedPayload.Targets) -ManagedOutputRoots $consumerRoots
        Assert-TestCondition ([string]$currentRows[0].Tuple.Target.Identity -ceq 'churned-identity') 're-projection refuses a tuple whose type differs from the reviewed tuple'
        $currentRows[0].Tuple.Target.Type = 'Directory'
        $null=Get-CanonicalRecoveryTargetIdentityProjection -Targets @($currentPayload.Targets) -ReviewedTargets @($reviewedPayload.Targets) -ManagedOutputRoots @()
        Assert-TestCondition ([string]$currentRows[0].Tuple.Target.Identity -ceq 'churned-identity') 're-projection refuses a tuple whose target path is outside every generated output root'
        $null=Get-CanonicalRecoveryTargetIdentityProjection -Targets @($currentPayload.Targets) -ReviewedTargets @([ordered]@{TargetId=$consumerTargetId;TargetPath=[IO.Path]::GetFullPath($projectionTarget);Tuple=$reviewedTuple}) -ManagedOutputRoots $consumerRoots
        Assert-TestCondition ([string]$currentRows[0].Tuple.Target.Identity -ceq 'churned-identity') 're-projection refuses a reviewed tuple recorded for a different target path'

        # Behavioral wiring pin: the currency check reads its evidence through this
        # seam, so a fixture payload proves the re-projection runs before the hash
        # comparison and that the repository's generated output roots bound it.
        Set-Item -LiteralPath Function:\Get-CanonicalRecoveryEvidencePayload -Value { param($State,$RepoRoot,$Action,$ToolchainRoot) return $global:PathSafetyRecoveryEvidenceFixture }
        $currencyDocument = [pscustomobject]@{PlanPayload=[ordered]@{PlannedAction='abandon';Targets=@($reviewedRow)};PlanHash=(Get-PlanHash -PlanPayload $reviewedPayload)}
        $global:PathSafetyRecoveryEvidenceFixture = [ordered]@{Targets=@($currentRows);WorkspaceInventory=@([ordered]@{Role='preimage';ReconciledState='READY';ObservedState=$observedState})}
        $currencyError = $null
        try { $null=Assert-CanonicalRecoveryPlanCurrent -Document $currencyDocument -State ([pscustomobject]@{}) -RepoRoot $consumerRepo } catch { $currencyError = [string]$_.Exception.Message }
        Assert-TestCondition ($null -eq $currencyError) 'recovery plan currency: a churned identity under the generated output root is re-projected before the reviewed plan hash is compared'
        # A repository whose generated output roots do not cover the target keeps
        # the same churned tuple stale, so the bounded dual-read stays fail-closed.
        $currentRows[0].Tuple.Target.Identity = 'churned-identity'
        $global:PathSafetyRecoveryEvidenceFixture = [ordered]@{Targets=@($currentRows);WorkspaceInventory=@([ordered]@{Role='preimage';ReconciledState='READY';ObservedState=$observedState})}
        Assert-PathSafetyThrows -Script { $null=Assert-CanonicalRecoveryPlanCurrent -Document $currencyDocument -State ([pscustomobject]@{}) -RepoRoot $projectionRepo } -Pattern '^canonical-recovery-plan-stale$' -Message 'recovery plan currency: generated output roots that do not cover the target keep the reviewed plan stale'
    }
    finally {
        Set-Item -LiteralPath Function:\Get-CanonicalRecoveryEvidencePayload -Value $originalEvidencePayload
        Remove-Variable -Scope Global -Name PathSafetyRecoveryEvidenceFixture -ErrorAction SilentlyContinue
    }

    Write-Host 'path safety tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
