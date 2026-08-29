#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/path-safety-fixtures.ps1')
. (Join-Path $RepoRoot 'scripts/target-context-common.ps1')

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
    $heldLease = Open-SealedHeldTargetContextLease -Path $heldMissing
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

    Write-Host 'path safety tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
