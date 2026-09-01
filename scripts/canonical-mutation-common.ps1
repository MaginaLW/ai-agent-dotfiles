#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'transaction-journal-common.ps1')

if (-not ('AiAgentDotfiles.CanonicalNativeMutation' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

namespace AiAgentDotfiles {
    public static class CanonicalNativeMutation {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateDirectoryW(string path, IntPtr securityAttributes);

        private static string ToExtendedPath(string path) {
            if (path.StartsWith(@"\\?\", StringComparison.Ordinal)) return path;
            if (path.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + path.Substring(2);
            return @"\\?\" + path;
        }

        public static void CreateDirectoryNoOverwrite(string path) {
            if (!CreateDirectoryW(ToExtendedPath(path), IntPtr.Zero)) {
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to create a single directory component without overwrite: " + path);
            }
        }
    }
}
'@
}

function Assert-CanonicalRecoveryOwnedPath {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$RecoveryTransactionRoot,
        [switch]$AllowRoot
    )
    $full=[System.IO.Path]::GetFullPath($Path)
    $root=[System.IO.Path]::GetFullPath($RecoveryTransactionRoot)
    if (-not (Test-SafePathInsideRoot -Path $full -Root $root) -or (-not $AllowRoot -and $full.Equals($root,[StringComparison]::OrdinalIgnoreCase))) {
        throw "canonical recovery-owned path escapes its transaction root: $full"
    }
    Assert-NoReparseExistingChain -Path $full
    return $full
}

function Close-CanonicalRetainedTreeTraversal {
    param([AllowNull()]$Traversal)
    if ($null -eq $Traversal) { return }
    foreach ($heldFile in @($Traversal.FileHandlesByRelativePath.Values)) { $heldFile.Dispose() }
    Close-SafeDirectoryContainmentChain -Handles $Traversal.ContainmentHandles
}

function Get-CanonicalRetainedDirectoryObservation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full=[System.IO.Path]::GetFullPath($Path)
    $traversal=$null
    try {
        $traversal=Get-SafeTreeSnapshotInternal -Root $full -RetainContainmentHandles
        $rootEvidence=@($traversal.Snapshot.TraversalIdentityEvidence | Where-Object {
            [string]$_.Type -ceq 'Directory' -and [string]$_.RelativePath -ceq ''
        })
        if ($rootEvidence.Count -ne 1) { throw "canonical directory traversal has invalid root identity evidence: $full" }
        $heldRoot=$traversal.DirectoryHandlesByRelativePath['']
        if ($null -eq $heldRoot -or [string]$heldRoot.Info.Identity -cne [string]$rootEvidence[0].Identity) {
            throw "canonical directory traversal root identity changed while retained: $full"
        }
        return [pscustomobject][ordered]@{
            Path=$full
            Identity=[string]$rootEvidence[0].Identity
            Hash=[string]$traversal.Snapshot.TreeHash
        }
    }
    finally { Close-CanonicalRetainedTreeTraversal -Traversal $traversal }
}

function Get-CanonicalObservedPathState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [ValidateSet('auto','file','directory')][string]$ExpectedKind='auto'
    )
    $full=[System.IO.Path]::GetFullPath($Path)
    $marker=Get-NoFollowRootEntryMarker -Path $full
    if ([string]$marker.EntryType -ceq 'MISSING') { return [ordered]@{State='MISSING'} }
    if ([string]$marker.EntryType -ceq 'ReparsePoint') { throw "canonical mutation path is a reparse point: $full" }
    if ([string]$marker.EntryType -ceq 'Directory') {
        if ($ExpectedKind -eq 'file') { throw "canonical mutation expected a file but found a directory: $full" }
        $directory=Get-CanonicalRetainedDirectoryObservation -Path $full
        return [ordered]@{State='PRESENT';Type='Directory';Hash=[string]$directory.Hash;Identity=[string]$directory.Identity}
    }
    if ($ExpectedKind -eq 'directory') { throw "canonical mutation expected a directory but found a file: $full" }
    $read=[AiAgentDotfiles.NoFollowFile]::HashRegularFile($full)
    return [ordered]@{State='PRESENT';Type='File';Hash=[string]$read.Sha256;Identity=[string]$read.Identity}
}

function Test-CanonicalObservedStateEqual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [switch]$IgnoreIdentity
    )
    if ([string]$Actual.State -cne [string]$Expected.State) { return $false }
    if ([string]$Expected.State -ceq 'MISSING') { return $true }
    if ([string]$Actual.Type -cne [string]$Expected.Type -or [string]$Actual.Hash -cne [string]$Expected.Hash) { return $false }
    if (-not $IgnoreIdentity -and $Expected.PSObject.Properties['Identity'] -and [string]$Actual.Identity -cne [string]$Expected.Identity) { return $false }
    return $true
}

function Test-CanonicalDataField {
    param([Parameter(Mandatory)]$Data,[Parameter(Mandatory)][string]$Name)
    if($Data -is [System.Collections.IDictionary]){return $Data.Contains($Name)}
    return $null -ne $Data.PSObject.Properties[$Name]
}

function Test-CanonicalObservedMatchesContractState {
    param([Parameter(Mandatory)]$Actual,[Parameter(Mandatory)]$Contract)
    if ([string]$Actual.State -cne [string]$Contract.State) { return $false }
    return [string]$Contract.State -ceq 'MISSING' -or [string]$Actual.Hash -ceq [string]$Contract.Hash
}

function Assert-CanonicalObservedStateEqual {
    param([Parameter(Mandatory)]$Actual,[Parameter(Mandatory)]$Expected,[string]$Label='canonical mutation tuple',[switch]$IgnoreIdentity)
    if (-not (Test-CanonicalObservedStateEqual -Actual $Actual -Expected $Expected -IgnoreIdentity:$IgnoreIdentity)) {
        throw "manual-recovery-required: $Label does not match its reviewed state"
    }
}

function Open-CanonicalMutationParentLease {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$LeafPaths,
        [switch]$RequireLeafParentsExist
    )

    $parentSet=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($leafPath in @($LeafPaths)){
        if([string]::IsNullOrWhiteSpace($leafPath)){throw 'canonical mutation parent lease requires a non-empty leaf path'}
        $full=[IO.Path]::GetFullPath($leafPath)
        $parent=[IO.Path]::GetDirectoryName($full)
        if([string]::IsNullOrWhiteSpace($parent)){throw "canonical mutation parent lease cannot resolve a parent: $full"}
        $null=$parentSet.Add($parent)
    }
    if($parentSet.Count -eq 0){throw 'canonical mutation parent lease requires at least one leaf path'}

    $entries=[Collections.Generic.List[object]]::new()
    try{
        foreach($parent in @($parentSet|Sort-Object)){
            $existingParent=$null
            $leafParentReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SafeExistingDirectoryContainmentChain -Path $parent -ExistingPath ([ref]$existingParent) -OwnershipReceiver $leafParentReceiver
            $handles=@($leafParentReceiver.GetDeliveredExact())
            $requestedNormalized=[IO.Path]::GetFullPath($parent).TrimEnd([char]92,[char]47)
            $existingNormalized=[IO.Path]::GetFullPath([string]$existingParent).TrimEnd([char]92,[char]47)
            if($RequireLeafParentsExist -and -not $existingNormalized.Equals($requestedNormalized,[StringComparison]::OrdinalIgnoreCase)){
                Close-SafeDirectoryContainmentChain -Handles $handles
                throw "canonical mutation leaf parent is not durably prepared: $parent"
            }
            $entries.Add([pscustomobject][ordered]@{ParentPath=$parent;ExistingParentPath=[string]$existingParent;Handles=$handles})
        }
        return [pscustomobject][ordered]@{Entries=$entries}
    }
    catch{
        for($index=$entries.Count-1;$index -ge 0;$index--){Close-SafeDirectoryContainmentChain -Handles @($entries[$index].Handles)}
        throw
    }
}

function Close-CanonicalMutationParentLease {
    param([AllowNull()]$Lease)
    if($null -eq $Lease){return}
    $entries=@($Lease.Entries)
    for($index=$entries.Count-1;$index -ge 0;$index--){Close-SafeDirectoryContainmentChain -Handles @($entries[$index].Handles)}
}

function Get-CanonicalMutationJournalLeaseLeaf {
    param([Parameter(Mandatory)][string]$TransactionNamespace)
    return [IO.Path]::Combine([IO.Path]::GetFullPath($TransactionNamespace),'.canonical-mutation-parent-lease')
}

function Assert-CanonicalPreparedTupleUnderLease {
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Prepared,[string]$Label='prepared canonical mutation tuple')
    $expected=[ordered]@{
        Target=$Prepared.TargetState
        Preimage=$Prepared.PreimageState
        SwapOld=$Prepared.SwapOldState
        Staged=$Prepared.StagedState
    }
    $actual=Get-CanonicalTargetTuple -Target $Target
    if(-not(Test-CanonicalTargetTupleEqual -Actual $actual -Expected $expected)){throw "manual-recovery-required: $Label changed before its filesystem primitive"}
    return $actual
}

function Copy-CanonicalFileCreateNew {
    param([Parameter(Mandatory)][string]$Source,[Parameter(Mandatory)][string]$Destination)
    $parent=Split-Path -Parent $Destination
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw "canonical immutable file copy parent is not durably prepared: $parent" }
    if (Test-Path -LiteralPath $Destination) { throw "canonical immutable file copy destination already exists: $Destination" }
    $copy=[AiAgentDotfiles.NoFollowFile]::CopyRegularFile($Source,$Destination)
    $destinationState=Get-CanonicalObservedPathState -Path $Destination -ExpectedKind file
    if ([string]$copy.Sha256 -cne [string]$destinationState.Hash) { throw 'canonical immutable file copy hash mismatch' }
    return $destinationState
}

function Initialize-CanonicalRecoveryWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransactionNamespace)
    $initialState=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    $initialRecoveryRoot=[IO.Path]::GetFullPath([string]$initialState.Header.RecoveryTransactionRoot)
    $lease=$null
    try{
        $lease=Open-CanonicalMutationParentLease -RequireLeafParentsExist -LeafPaths @(
            (Join-Path $initialRecoveryRoot '.canonical-mutation-root-lease'),
            (Get-CanonicalMutationJournalLeaseLeaf -TransactionNamespace $TransactionNamespace)
        )
        $state=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
        $recoveryRoot=[IO.Path]::GetFullPath([string]$state.Header.RecoveryTransactionRoot)
        if(-not $recoveryRoot.Equals($initialRecoveryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'manual-recovery-required: canonical recovery transaction root changed while acquiring its parent lease'}
        $rootState=Get-CanonicalObservedPathState -Path $recoveryRoot -ExpectedKind directory
        if([string]$rootState.State -cne 'PRESENT'){throw 'canonical recovery transaction root must exist before journaled workspace preparation'}
        foreach($target in @($state.Header.Targets)){
            if([string]$target.TargetKind -eq 'parent-directory'){continue}
            $expectedPreimageParent=[IO.Path]::GetFullPath((Join-Path $recoveryRoot 'preimage'))
            $expectedSwapParent=[IO.Path]::GetFullPath((Join-Path $recoveryRoot 'swap-old'))
            if(-not([IO.Path]::GetFullPath((Split-Path -Parent ([string]$target.PreimagePath))).Equals($expectedPreimageParent,[StringComparison]::OrdinalIgnoreCase)) -or
               -not([IO.Path]::GetFullPath((Split-Path -Parent ([string]$target.SwapOldPath))).Equals($expectedSwapParent,[StringComparison]::OrdinalIgnoreCase))){
                throw 'canonical recovery target workspace paths do not use the contracted containers'
            }
        }
        foreach($role in @('preimage','swap-old')){
            $path=[IO.Path]::GetFullPath((Join-Path $recoveryRoot $role))
            $null=Assert-CanonicalRecoveryOwnedPath -Path $path -RecoveryTransactionRoot $recoveryRoot
            $current=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
            $records=@($current.Records|Where-Object{[string]$_.Phase -in @('WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED') -and [string]$_.Data.WorkspaceRole -ceq $role})
            if($records.Count -eq 0){
                $before=Get-CanonicalObservedPathState -Path $path
                if([string]$before.State -cne 'MISSING'){throw "manual-recovery-required: unjournaled canonical $role workspace exists"}
                $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase WORKSPACE_CREATE_INTENT -Data ([ordered]@{WorkspacePath=$path;WorkspaceRole=$role;WorkspaceState=$before})
                [AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite($path)
                $created=Get-CanonicalObservedPathState -Path $path -ExpectedKind directory
                if(@((Get-SafeTreeSnapshot -Root $path).ContentTreeRows).Count -ne 1){throw "manual-recovery-required: newly created canonical $role workspace is not empty"}
                $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase WORKSPACE_CREATED -Data ([ordered]@{WorkspacePath=$path;WorkspaceRole=$role;WorkspaceState=$created;CreatedIdentity=[string]$created.Identity})
            }else{
                if($records.Count -ne 2 -or [string]$records[0].Phase -cne 'WORKSPACE_CREATE_INTENT' -or [string]$records[1].Phase -cne 'WORKSPACE_CREATED'){throw "manual-recovery-required: canonical $role workspace record sequence is incomplete"}
                $workspaceState=@(Get-CanonicalRecoveryWorkspaceReconciliation -State $current|Where-Object{[string]$_.WorkspaceRole -ceq $role})
                if($workspaceState.Count -ne 1 -or [string]$workspaceState[0].ReconciledState -cne 'READY'){throw "manual-recovery-required: canonical $role workspace identity or inventory changed"}
            }
        }
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}

function New-CanonicalTargetRecordData {
    param(
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)]$TargetState,
        [Parameter(Mandatory)]$PreimageState,
        [Parameter(Mandatory)]$SwapOldState,
        [Parameter(Mandatory)]$StagedState,
        [string]$CreatedIdentity
    )
    $data=[ordered]@{
        TargetId=[string]$Target.TargetId;TargetKind=[string]$Target.TargetKind;TargetPath=[string]$Target.TargetPath
        PreimagePath=[string]$Target.PreimagePath;SwapOldPath=[string]$Target.SwapOldPath;StagedPath=$Target.StagedPath
        TargetState=$TargetState;PreimageState=$PreimageState;SwapOldState=$SwapOldState;StagedState=$StagedState
    }
    if ($CreatedIdentity) { $data.CreatedIdentity=$CreatedIdentity }
    return $data
}

function Initialize-CanonicalTargetPreimage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target
    )
    $existingState=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    $preparedPhase=if([string]$Target.TargetKind -ceq 'file'){'FILE_PREPARED'}else{'PREPARED'}
    $existingPrepared=@($existingState.Records|Where-Object{[string]$_.Phase -ceq $preparedPhase -and [string]$_.Data.TargetId -ceq [string]$Target.TargetId})
    if($existingPrepared.Count -gt 0){
        if($existingPrepared.Count -ne 1){throw 'manual-recovery-required: duplicate canonical prepared record'}
        $reconciled=Get-CanonicalTargetReconciliation -Target $Target -Records @($existingState.Records)
        if([string]$reconciled.State -cne 'PRE_PRIMITIVE'){throw 'manual-recovery-required: prepared target no longer matches its durable tuple'}
        $data=$existingPrepared[0].Data
        return [pscustomobject][ordered]@{TargetState=$data.TargetState;PreimageState=$data.PreimageState;SwapOldState=$data.SwapOldState;StagedState=$data.StagedState}
    }
    Initialize-CanonicalRecoveryWorkspace -TransactionNamespace $TransactionNamespace
    $targetKind=[string]$Target.TargetKind
    if($targetKind -notin @('directory','file')){throw 'Only file and directory targets use immutable preimages.'}
    $expectedKind=if($targetKind -eq 'file'){'file'}else{'directory'}
    $initialState=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    $initialRecoveryRoot=[IO.Path]::GetFullPath([string]$initialState.Header.RecoveryTransactionRoot)
    $lease=$null
    $targetLease=$null
    try{
        $lease=Open-CanonicalMutationParentLease -RequireLeafParentsExist -LeafPaths @(
            [string]$Target.PreimagePath,[string]$Target.SwapOldPath,[string]$Target.StagedPath,
            (Get-CanonicalMutationJournalLeaseLeaf -TransactionNamespace $TransactionNamespace)
        )
        $targetLease=Open-CanonicalMutationParentLease -LeafPaths @([string]$Target.TargetPath) -RequireLeafParentsExist:([string]$Target.Current.State -ceq 'PRESENT')
        $state=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
        $recoveryRoot=[IO.Path]::GetFullPath([string]$state.Header.RecoveryTransactionRoot)
        if(-not $recoveryRoot.Equals($initialRecoveryRoot,[StringComparison]::OrdinalIgnoreCase)){throw 'manual-recovery-required: canonical recovery transaction root changed while acquiring the preimage parent lease'}
        foreach($name in @('PreimagePath','SwapOldPath','StagedPath')){
            $value=$Target.$name
            if($null -ne $value){$null=Assert-CanonicalRecoveryOwnedPath -Path ([string]$value) -RecoveryTransactionRoot $recoveryRoot}
        }
        foreach($ownedLeaf in @([string]$Target.PreimagePath,[string]$Target.SwapOldPath,[string]$Target.StagedPath)){
            $ownedParent=Split-Path -Parent $ownedLeaf
            if(-not(Test-Path -LiteralPath $ownedParent -PathType Container)){throw "canonical recovery workspace parent is not durably prepared: $ownedParent"}
            $null=Assert-CanonicalRecoveryOwnedPath -Path $ownedParent -RecoveryTransactionRoot $recoveryRoot -AllowRoot
        }
        $targetState=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind $expectedKind
        if(-not(Test-CanonicalObservedMatchesContractState -Actual $targetState -Contract $Target.Current)){throw 'canonical target changed before preimage creation'}
        $swapState=Get-CanonicalObservedPathState -Path ([string]$Target.SwapOldPath)
        if([string]$swapState.State -cne 'MISSING'){throw 'canonical swap-old must be MISSING before mutation'}
        $preimageState=Get-CanonicalObservedPathState -Path ([string]$Target.PreimagePath)
        if([string]$preimageState.State -cne 'MISSING'){throw 'canonical immutable preimage path must be MISSING before preparation'}
        $stagedState=Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath) -ExpectedKind $expectedKind
        if(-not(Test-CanonicalObservedMatchesContractState -Actual $stagedState -Contract $Target.Candidate)){throw 'canonical staged target differs from reviewed candidate'}
        $intentData=New-CanonicalTargetRecordData -Target $Target -TargetState $targetState -PreimageState $preimageState -SwapOldState $swapState -StagedState $stagedState
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase PREIMAGE_COPY_INTENT -Data $intentData
        if([string]$targetState.State -ceq 'PRESENT'){
            if($targetKind -eq 'directory'){
                $null=Copy-SafeTree -SourceRoot ([string]$Target.TargetPath) -DestinationRoot ([string]$Target.PreimagePath)
                $preimageState=Get-CanonicalObservedPathState -Path ([string]$Target.PreimagePath) -ExpectedKind directory
            }else{
                $preimageState=Copy-CanonicalFileCreateNew -Source ([string]$Target.TargetPath) -Destination ([string]$Target.PreimagePath)
            }
            if([string]$preimageState.Hash -cne [string]$targetState.Hash){throw 'canonical immutable preimage differs from target'}
        }
        $phase=if($targetKind -eq 'file'){'FILE_PREPARED'}else{'PREPARED'}
        $data=New-CanonicalTargetRecordData -Target $Target -TargetState $targetState -PreimageState $preimageState -SwapOldState $swapState -StagedState $stagedState
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase $phase -Data $data
        return [pscustomobject][ordered]@{TargetState=$targetState;PreimageState=$preimageState;SwapOldState=$swapState;StagedState=$stagedState}
    }
    finally{
        Close-CanonicalMutationParentLease -Lease $targetLease
        Close-CanonicalMutationParentLease -Lease $lease
    }
}

function Initialize-CanonicalTransactionPreimages {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransactionNamespace)
    $state=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    foreach($target in @($state.Header.Targets|Where-Object{[string]$_.TargetKind -ne 'parent-directory'}|Sort-Object{[long]$_.Order})){
        $null=Initialize-CanonicalTargetPreimage -TransactionNamespace $TransactionNamespace -Target $target
    }
    Assert-CanonicalTransactionPreimageBarrier -TransactionNamespace $TransactionNamespace
}

function Assert-CanonicalTransactionPreimageBarrier {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TransactionNamespace)
    $state=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    foreach($target in @($state.Header.Targets|Where-Object{[string]$_.TargetKind -ne 'parent-directory'})){
        $required=if([string]$target.TargetKind -ceq 'file'){'FILE_PREPARED'}else{'PREPARED'}
        $matching=@($state.Records|Where-Object{[string]$_.Phase -ceq $required -and [string]$_.Data.TargetId -ceq [string]$target.TargetId})
        if($matching.Count -ne 1){throw 'canonical-transaction-preimage-barrier-incomplete'}
        $reconciled=Get-CanonicalTargetReconciliation -Target $target -Records @($state.Records)
        if([string]$reconciled.State -notin @('PRE_PRIMITIVE','OLD_MOVED','NEW_INSTALLED')){throw 'canonical-transaction-preimage-barrier-drift'}
    }
}

function Invoke-CanonicalParentDirectoryCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target
    )
    if([string]$Target.TargetKind -cne 'parent-directory'){throw 'DIR_CREATE target must be parent-directory.'}
    $lease=$null
    try{
        $lease=Open-CanonicalMutationParentLease -RequireLeafParentsExist -LeafPaths @(
            [string]$Target.TargetPath,
            (Get-CanonicalMutationJournalLeaseLeaf -TransactionNamespace $TransactionNamespace)
        )
        Assert-CanonicalTransactionPreimageBarrier -TransactionNamespace $TransactionNamespace
        $state=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
        $recoveryRoot=[string]$state.Header.RecoveryTransactionRoot
        foreach($name in @('PreimagePath','SwapOldPath')){$null=Assert-CanonicalRecoveryOwnedPath -Path ([string]$Target.$name) -RecoveryTransactionRoot $recoveryRoot}
        $before=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath)
        if([string]$before.State -cne 'MISSING'){throw 'canonical parent component is no longer MISSING'}
        $missing=[ordered]@{State='MISSING'}
        $data=New-CanonicalTargetRecordData -Target $Target -TargetState $missing -PreimageState $missing -SwapOldState $missing -StagedState $missing
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase DIR_CREATE_INTENT -Data $data
        [AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite([string]$Target.TargetPath)
        $created=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind directory
        $afterData=New-CanonicalTargetRecordData -Target $Target -TargetState $created -PreimageState $missing -SwapOldState $missing -StagedState $missing -CreatedIdentity ([string]$created.Identity)
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase DIR_CREATED -Data $afterData
        return $created
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}

function Invoke-CanonicalDirectoryReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target
    )
    if([string]$Target.TargetKind -cne 'directory'){throw 'Directory replacement requires a directory target.'}
    $prepared=Initialize-CanonicalTargetPreimage -TransactionNamespace $TransactionNamespace -Target $Target
    $lease=$null
    try{
        $lease=Open-CanonicalMutationParentLease -RequireLeafParentsExist -LeafPaths @(
            [string]$Target.TargetPath,[string]$Target.PreimagePath,[string]$Target.SwapOldPath,[string]$Target.StagedPath,
            (Get-CanonicalMutationJournalLeaseLeaf -TransactionNamespace $TransactionNamespace)
        )
        Assert-CanonicalTransactionPreimageBarrier -TransactionNamespace $TransactionNamespace
        $null=Assert-CanonicalPreparedTupleUnderLease -Target $Target -Prepared $prepared -Label 'prepared directory tuple'
        $intent=New-CanonicalTargetRecordData -Target $Target -TargetState $prepared.TargetState -PreimageState $prepared.PreimageState -SwapOldState $prepared.SwapOldState -StagedState $prepared.StagedState
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase MOVE_OLD_INTENT -Data $intent
        if([string]$prepared.TargetState.State -ceq 'PRESENT'){
            [System.IO.Directory]::Move([string]$Target.TargetPath,[string]$Target.SwapOldPath)
        }
        $afterOldTarget=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath)
        $afterOldSwap=Get-CanonicalObservedPathState -Path ([string]$Target.SwapOldPath)
        $afterOldStaged=Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath) -ExpectedKind directory
        $missing=[ordered]@{State='MISSING'}
        Assert-CanonicalObservedStateEqual -Actual $afterOldTarget -Expected $missing -Label 'directory target after old move'
        if([string]$prepared.TargetState.State -ceq 'PRESENT'){
            Assert-CanonicalObservedStateEqual -Actual $afterOldSwap -Expected $prepared.TargetState -Label 'directory swap-old after old move'
        }else{Assert-CanonicalObservedStateEqual -Actual $afterOldSwap -Expected $missing -Label 'directory swap-old for MISSING old target'}
        $oldMoved=New-CanonicalTargetRecordData -Target $Target -TargetState $afterOldTarget -PreimageState $prepared.PreimageState -SwapOldState $afterOldSwap -StagedState $afterOldStaged
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase OLD_MOVED -Data $oldMoved
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase MOVE_NEW_INTENT -Data $oldMoved
        if([string]$Target.Candidate.State -ceq 'PRESENT'){
            [System.IO.Directory]::Move([string]$Target.StagedPath,[string]$Target.TargetPath)
        }else{
            $candidateStaged=Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath)
            if([string]$candidateStaged.State -cne 'MISSING'){throw 'manual-recovery-required: deletion candidate staged path is not MISSING'}
        }
        $installed=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind directory
        $swap=Get-CanonicalObservedPathState -Path ([string]$Target.SwapOldPath)
        $staged=Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath)
        Assert-CanonicalObservedStateEqual -Actual $installed -Expected $prepared.StagedState -Label 'installed directory candidate'
        Assert-CanonicalObservedStateEqual -Actual $staged -Expected $missing -Label 'directory staged path after install'
        $installedData=New-CanonicalTargetRecordData -Target $Target -TargetState $installed -PreimageState $prepared.PreimageState -SwapOldState $swap -StagedState $staged
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase NEW_INSTALLED -Data $installedData
        return $installedData
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}

function Invoke-CanonicalFileReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target
    )
    if([string]$Target.TargetKind -cne 'file'){throw 'File replacement requires a file target.'}
    $prepared=Initialize-CanonicalTargetPreimage -TransactionNamespace $TransactionNamespace -Target $Target
    $lease=$null
    try{
        $lease=Open-CanonicalMutationParentLease -RequireLeafParentsExist -LeafPaths @(
            [string]$Target.TargetPath,[string]$Target.PreimagePath,[string]$Target.SwapOldPath,[string]$Target.StagedPath,
            (Get-CanonicalMutationJournalLeaseLeaf -TransactionNamespace $TransactionNamespace)
        )
        Assert-CanonicalTransactionPreimageBarrier -TransactionNamespace $TransactionNamespace
        $null=Assert-CanonicalPreparedTupleUnderLease -Target $Target -Prepared $prepared -Label 'prepared file tuple'
        $intent=New-CanonicalTargetRecordData -Target $Target -TargetState $prepared.TargetState -PreimageState $prepared.PreimageState -SwapOldState $prepared.SwapOldState -StagedState $prepared.StagedState
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase FILE_REPLACE_INTENT -Data $intent
        if([string]$prepared.TargetState.State -ceq 'PRESENT'){
            [System.IO.File]::Replace([string]$Target.StagedPath,[string]$Target.TargetPath,[string]$Target.SwapOldPath,$true)
        }else{
            [System.IO.File]::Move([string]$Target.StagedPath,[string]$Target.TargetPath,$false)
        }
        $installed=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind file
        $swap=Get-CanonicalObservedPathState -Path ([string]$Target.SwapOldPath)
        $staged=Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath)
        $missing=[ordered]@{State='MISSING'}
        Assert-CanonicalObservedStateEqual -Actual $installed -Expected $prepared.StagedState -Label 'installed file candidate' -IgnoreIdentity
        Assert-CanonicalObservedStateEqual -Actual $staged -Expected $missing -Label 'file staged path after replace'
        if([string]$prepared.TargetState.State -ceq 'PRESENT'){
            if(-not(Test-CanonicalObservedStateEqual -Actual $swap -Expected $prepared.TargetState -IgnoreIdentity)){
                throw 'manual-recovery-required: atomic file replace captured unreviewed raced bytes in swap-old'
            }
        }else{Assert-CanonicalObservedStateEqual -Actual $swap -Expected $missing -Label 'file swap-old for MISSING old target'}
        $replaced=New-CanonicalTargetRecordData -Target $Target -TargetState $installed -PreimageState $prepared.PreimageState -SwapOldState $swap -StagedState $staged
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase FILE_REPLACED -Data $replaced
        return $replaced
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}

function Get-CanonicalTargetTuple {
    param([Parameter(Mandatory)]$Target)
    $kind=[string]$Target.TargetKind
    $expected=if($kind -eq 'file'){'file'}elseif($kind -in @('directory','parent-directory')){'directory'}else{'auto'}
    return [ordered]@{
        Target=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind $expected
        Preimage=Get-CanonicalObservedPathState -Path ([string]$Target.PreimagePath)
        SwapOld=Get-CanonicalObservedPathState -Path ([string]$Target.SwapOldPath)
        Staged=if($null -eq $Target.StagedPath){[ordered]@{State='MISSING'}}else{Get-CanonicalObservedPathState -Path ([string]$Target.StagedPath)}
    }
}

function Get-CanonicalRecoveryWorkspaceReconciliation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    if(@($State.Header.Targets|Where-Object{[string]$_.TargetKind -ne 'parent-directory'}).Count -eq 0){return @()}
    $root=[IO.Path]::GetFullPath([string]$State.Header.RecoveryTransactionRoot)
    $items=[Collections.Generic.List[object]]::new()
    foreach($role in @('preimage','swap-old')){
        $path=[IO.Path]::GetFullPath((Join-Path $root $role))
        $records=@($State.Records|Where-Object{[string]$_.Phase -in @('WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED') -and [string]$_.Data.WorkspaceRole -ceq $role})
        $actual=Get-CanonicalObservedPathState -Path $path
        $status='AMBIGUOUS'
        if($records.Count -eq 0){
            if([string]$actual.State -ceq 'MISSING'){$status='UNPREPARED'}
        }elseif($records.Count -eq 1 -and [string]$records[0].Phase -ceq 'WORKSPACE_CREATE_INTENT' -and [string]$records[0].Data.WorkspacePath -ceq $path -and [string]$records[0].Data.WorkspaceState.State -ceq 'MISSING'){
            if([string]$actual.State -ceq 'MISSING'){$status='INTENT_NO_CREATE'}
            elseif([string]$actual.State -ceq 'PRESENT' -and [string]$actual.Type -ceq 'Directory' -and @((Get-SafeTreeSnapshot -Root $path).ContentTreeRows).Count -eq 1){$status='CREATED_UNRECORDED'}
        }elseif($records.Count -eq 2 -and [string]$records[0].Phase -ceq 'WORKSPACE_CREATE_INTENT' -and [string]$records[1].Phase -ceq 'WORKSPACE_CREATED' -and [string]$records[0].Data.WorkspacePath -ceq $path -and [string]$records[1].Data.WorkspacePath -ceq $path -and [string]$records[1].Data.CreatedIdentity -ceq [string]$records[1].Data.WorkspaceState.Identity -and [string]$actual.State -ceq 'PRESENT' -and [string]$actual.Type -ceq 'Directory' -and [string]$actual.Identity -ceq [string]$records[1].Data.CreatedIdentity){
            $allowed=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach($target in @($State.Header.Targets)){
                $leaf=if($role -ceq 'preimage'){[string]$target.PreimagePath}else{[string]$target.SwapOldPath}
                if([IO.Path]::GetFullPath((Split-Path -Parent $leaf)).Equals($path,[StringComparison]::OrdinalIgnoreCase)){$null=$allowed.Add([IO.Path]::GetFileName($leaf))}
            }
            $unknown=$false
            foreach($entry in [IO.Directory]::EnumerateFileSystemEntries($path)){
                $info=[AiAgentDotfiles.NoFollowFile]::Inspect($entry)
                if($info.IsReparsePoint -or -not $allowed.Contains([IO.Path]::GetFileName($entry))){$unknown=$true;break}
            }
            if(-not $unknown){$status='READY'}
        }
        $items.Add([ordered]@{WorkspaceRole=$role;WorkspacePath=$path;ReconciledState=$status;ObservedState=$actual})
    }
    return @($items)
}

function Test-CanonicalTargetTupleEqual {
    param([Parameter(Mandatory)]$Actual,[Parameter(Mandatory)]$Expected,[switch]$IgnoreIdentity)
    foreach($name in @('Target','Preimage','SwapOld','Staged')){
        if(-not(Test-CanonicalObservedStateEqual -Actual $Actual[$name] -Expected $Expected[$name] -IgnoreIdentity:$IgnoreIdentity)){return $false}
    }
    return $true
}

function Test-CanonicalUnpreparedTargetTuple {
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Tuple)
    $missing=[ordered]@{State='MISSING'}
    if([string]$Target.TargetKind -ceq 'parent-directory'){
        $expected=[ordered]@{Target=$missing;Preimage=$missing;SwapOld=$missing;Staged=$missing}
        return Test-CanonicalTargetTupleEqual -Actual $Tuple -Expected $expected
    }
    if(-not(Test-CanonicalObservedMatchesContractState -Actual $Tuple.Target -Contract $Target.Current)){return $false}
    if(-not(Test-CanonicalObservedMatchesContractState -Actual $Tuple.Staged -Contract $Target.Candidate)){return $false}
    if([string]$Tuple.Preimage.State -cne 'MISSING' -or [string]$Tuple.SwapOld.State -cne 'MISSING'){return $false}
    $expectedType=if([string]$Target.TargetKind -ceq 'file'){'File'}else{'Directory'}
    foreach($state in @($Tuple.Target,$Tuple.Staged)){
        if([string]$state.State -ceq 'PRESENT' -and [string]$state.Type -cne $expectedType){return $false}
    }
    return $true
}

function Get-CanonicalTargetReconciliation {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)
    $targetRecords=@($Records|Where-Object{(Test-CanonicalDataField -Data $_.Data -Name 'TargetId') -and [string]$_.Data.TargetId -ceq [string]$Target.TargetId})
    if($targetRecords.Count -eq 0){
        $actual=Get-CanonicalTargetTuple -Target $Target
        $state=if(Test-CanonicalUnpreparedTargetTuple -Target $Target -Tuple $actual){'UNPREPARED'}else{'AMBIGUOUS'}
        return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State=$state;PrimitiveOccurred=if($state -ceq 'UNPREPARED'){$false}else{$null};Tuple=$actual}
    }
    $actual=Get-CanonicalTargetTuple -Target $Target
    $preparedRecords=@($targetRecords|Where-Object{[string]$_.Phase -ne 'PREIMAGE_COPY_INTENT'})
    if($preparedRecords.Count -eq 0){
        $baseValid=(Test-CanonicalObservedMatchesContractState -Actual $actual.Target -Contract $Target.Current) -and
            (Test-CanonicalObservedMatchesContractState -Actual $actual.Staged -Contract $Target.Candidate) -and
            [string]$actual.SwapOld.State -ceq 'MISSING'
        $preimageValid=[string]$actual.Preimage.State -ceq 'MISSING'
        if(-not $preimageValid -and [string]$Target.Current.State -ceq 'PRESENT'){
            $expectedType=if([string]$Target.TargetKind -ceq 'file'){'File'}else{'Directory'}
            $preimageValid=[string]$actual.Preimage.State -ceq 'PRESENT' -and [string]$actual.Preimage.Type -ceq $expectedType -and [string]$actual.Preimage.Hash -ceq [string]$Target.Current.Hash
        }
        $state=if($baseValid -and $preimageValid){'PRE_PRIMITIVE'}else{'AMBIGUOUS'}
        return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State=$state;PrimitiveOccurred=if($state -ceq 'PRE_PRIMITIVE'){$false}else{$null};Tuple=$actual}
    }
    $first=$preparedRecords[0].Data
    $pre=[ordered]@{Target=$first.TargetState;Preimage=$first.PreimageState;SwapOld=$first.SwapOldState;Staged=$first.StagedState}
    if([string]$Target.TargetKind -eq 'parent-directory'){
        $missing=[ordered]@{State='MISSING'}
        $pre=[ordered]@{Target=$missing;Preimage=$missing;SwapOld=$missing;Staged=$missing}
        if(Test-CanonicalTargetTupleEqual -Actual $actual -Expected $pre){return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='PRE_PRIMITIVE';PrimitiveOccurred=$false;Tuple=$actual}}
        if([string]$actual.Target.State -ceq 'PRESENT' -and [string]$actual.Target.Type -ceq 'Directory' -and [string]$actual.Preimage.State -ceq 'MISSING' -and [string]$actual.SwapOld.State -ceq 'MISSING' -and [string]$actual.Staged.State -ceq 'MISSING'){
            $snapshot=Get-SafeTreeSnapshot -Root ([string]$Target.TargetPath)
            if(@($snapshot.ContentTreeRows).Count -eq 1){return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='PARENT_CREATED';PrimitiveOccurred=$true;Tuple=$actual}}
        }
        return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='AMBIGUOUS';PrimitiveOccurred=$null;Tuple=$actual}
    }
    if(-not(Test-CanonicalObservedStateEqual -Actual $actual.Preimage -Expected $pre.Preimage)){return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='AMBIGUOUS';PrimitiveOccurred=$null;Tuple=$actual}}
    if(Test-CanonicalTargetTupleEqual -Actual $actual -Expected $pre -IgnoreIdentity:([string]$Target.TargetKind -eq 'file')){return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='PRE_PRIMITIVE';PrimitiveOccurred=$false;Tuple=$actual}}
    $missing=[ordered]@{State='MISSING'}
    if([string]$Target.TargetKind -eq 'directory'){
        $oldSwap=if([string]$pre.Target.State -ceq 'PRESENT'){$pre.Target}else{$missing}
        $afterOld=[ordered]@{Target=$missing;Preimage=$pre.Preimage;SwapOld=$oldSwap;Staged=$pre.Staged}
        if(Test-CanonicalTargetTupleEqual -Actual $actual -Expected $afterOld){
            $lastPhase=[string]$targetRecords[-1].Phase
            $state=if([string]$Target.Candidate.State -ceq 'MISSING' -and $lastPhase -ceq 'NEW_INSTALLED'){'NEW_INSTALLED'}else{'OLD_MOVED'}
            return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State=$state;PrimitiveOccurred=$true;Tuple=$actual}
        }
    }
    $oldSwap=if([string]$pre.Target.State -ceq 'PRESENT'){$pre.Target}else{$missing}
    $post=[ordered]@{Target=$pre.Staged;Preimage=$pre.Preimage;SwapOld=$oldSwap;Staged=$missing}
    if(Test-CanonicalTargetTupleEqual -Actual $actual -Expected $post -IgnoreIdentity:([string]$Target.TargetKind -eq 'file')){return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='NEW_INSTALLED';PrimitiveOccurred=$true;Tuple=$actual}}
    return [pscustomobject][ordered]@{TargetId=[string]$Target.TargetId;State='AMBIGUOUS';PrimitiveOccurred=$null;Tuple=$actual}
}

function Restore-CanonicalMutationTarget {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Target,[Parameter(Mandatory)]$Reconciliation)
    if([string]$Reconciliation.State -eq 'AMBIGUOUS'){throw 'manual-recovery-required: target tuple is ambiguous'}
    if([string]$Reconciliation.State -in @('UNPREPARED','PRE_PRIMITIVE')){return}
    $leafPaths=[Collections.Generic.List[string]]::new()
    $leafPaths.Add([string]$Target.TargetPath)
    if([string]$Target.TargetKind -ne 'parent-directory'){
        foreach($path in @([string]$Target.PreimagePath,[string]$Target.SwapOldPath,[string]$Target.StagedPath)){$leafPaths.Add($path)}
    }
    $lease=$null
    try{
        $lease=Open-CanonicalMutationParentLease -RequireLeafParentsExist -LeafPaths @($leafPaths)
        $actualTuple=Get-CanonicalTargetTuple -Target $Target
        if(-not(Test-CanonicalTargetTupleEqual -Actual $actualTuple -Expected $Reconciliation.Tuple)){throw 'manual-recovery-required: rollback target tuple changed while acquiring its parent lease'}

        if([string]$Target.TargetKind -eq 'parent-directory'){
            $actual=$actualTuple.Target
            if([string]$actual.Identity -cne [string]$Reconciliation.Tuple.Target.Identity){throw 'manual-recovery-required: created parent identity changed'}
            if(@((Get-SafeTreeSnapshot -Root ([string]$Target.TargetPath)).ContentTreeRows).Count -ne 1){throw 'manual-recovery-required: created parent is no longer empty'}
            [System.IO.Directory]::Delete([string]$Target.TargetPath,$false)
            $removed=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath)
            if([string]$removed.State -cne 'MISSING'){throw 'manual-recovery-required: created parent remained after rollback removal'}
            return
        }

        $oldPresent=[string]$Target.Current.State -ceq 'PRESENT'
        if([string]$Target.TargetKind -eq 'directory'){
            if([string]$Reconciliation.State -eq 'NEW_INSTALLED'){
                if([string]$Target.Candidate.State -ceq 'PRESENT'){
                    if(Test-Path -LiteralPath ([string]$Target.StagedPath)){throw 'manual-recovery-required: staged preservation path is occupied'}
                    [System.IO.Directory]::Move([string]$Target.TargetPath,[string]$Target.StagedPath)
                }elseif(Test-Path -LiteralPath ([string]$Target.TargetPath)){
                    throw 'manual-recovery-required: deleted directory target unexpectedly reappeared before rollback'
                }
            }
            if($oldPresent){
                [System.IO.Directory]::Move([string]$Target.SwapOldPath,[string]$Target.TargetPath)
            }
        }else{
            if([string]$Reconciliation.State -eq 'NEW_INSTALLED'){
                if(Test-Path -LiteralPath ([string]$Target.StagedPath)){throw 'manual-recovery-required: staged preservation path is occupied'}
                if($oldPresent){
                    [System.IO.File]::Replace([string]$Target.SwapOldPath,[string]$Target.TargetPath,[string]$Target.StagedPath,$true)
                }else{
                    [System.IO.File]::Move([string]$Target.TargetPath,[string]$Target.StagedPath,$false)
                }
            }
        }
        $restoredTuple=Get-CanonicalTargetTuple -Target $Target
        if(-not(Test-CanonicalObservedMatchesContractState -Actual $restoredTuple.Target -Contract $Target.Current)){throw 'manual-recovery-required: target did not restore to reviewed preimage state'}
        if(-not(Test-CanonicalObservedStateEqual -Actual $restoredTuple.Preimage -Expected $Reconciliation.Tuple.Preimage)){throw 'manual-recovery-required: immutable preimage changed during rollback'}
        $missing=[ordered]@{State='MISSING'}
        Assert-CanonicalObservedStateEqual -Actual $restoredTuple.SwapOld -Expected $missing -Label 'rollback swap-old postcondition'
        $expectedStaged=if([string]$Reconciliation.State -ceq 'NEW_INSTALLED'){$Reconciliation.Tuple.Target}else{$Reconciliation.Tuple.Staged}
        Assert-CanonicalObservedStateEqual -Actual $restoredTuple.Staged -Expected $expectedStaged -Label 'rollback staged postcondition' -IgnoreIdentity:([string]$Target.TargetKind -eq 'file')
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}
