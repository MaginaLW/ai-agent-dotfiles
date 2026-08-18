#Requires -Version 7.0
# Tests-only sealed mutation engine. Never dot-sourced by production scripts.
# This file is the single reviewed tests-only mirror host for the deterministic
# hard-kill checkpoint contract: exactly four sealed function mirrors plus the
# typed invocation-context machinery their reaches require.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if(-not ('AiAgentDotfilesTests.SealedMutationCheckpoint' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;

namespace AiAgentDotfilesTests
{
    public enum SealedMutationCheckpoint
    {
        BeforeWorkspaceCreate,
        AfterWorkspaceCreate,
        BeforeParentCreate,
        AfterParentCreate,
        BeforeDirectoryOldMove,
        AfterDirectoryOldMove,
        BeforeDirectoryNewMove,
        AfterDirectoryNewMove,
        BeforeDirectoryDeletionRecord,
        AfterDirectoryDeletionRecord,
        BeforeFileReplaceMove,
        AfterFileReplaceMove,
        PreimageReady,
        RetainedPartialPreimage
    }

    public enum SealedMutationPrimitiveVariant
    {
        WorkspacePreimageCreate,
        WorkspaceSwapOldCreate,
        ParentCreate,
        DirectoryOldMovePresent,
        DirectoryNewMovePresent,
        DirectoryDeletionRecordMissing,
        FileReplacePresent,
        FileMoveMissing,
        RealPreimageFile,
        RetainedPartialPreimageFile
    }

    public sealed class SealedMutationStageSelector
    {
        public SealedMutationCheckpoint Checkpoint { get; }
        public SealedMutationPrimitiveVariant DeclaredVariant { get; }
        public string SelectorArmJson { get; }
        public string StageArtifactIdentity { get; }
        public string IntentRawSha256 { get; }
        public string TailRawSha256 { get; }
        public string DerivedJournalHeadHash { get; }
        internal int MatchState;

        public SealedMutationStageSelector(SealedMutationCheckpoint checkpoint, SealedMutationPrimitiveVariant declaredVariant, string selectorArmJson, string stageArtifactIdentity, string intentRawSha256, string tailRawSha256, string derivedJournalHeadHash)
        {
            Checkpoint = checkpoint;
            DeclaredVariant = declaredVariant;
            SelectorArmJson = selectorArmJson ?? string.Empty;
            StageArtifactIdentity = stageArtifactIdentity ?? string.Empty;
            IntentRawSha256 = intentRawSha256 ?? string.Empty;
            TailRawSha256 = tailRawSha256 ?? string.Empty;
            DerivedJournalHeadHash = derivedJournalHeadHash ?? string.Empty;
            MatchState = 0;
        }

        public bool TryAcceptMatch()
        {
            return Interlocked.CompareExchange(ref MatchState, 1, 0) == 0;
        }

        public static SealedMutationStageSelector ParseCanonicalWire(string selectorJson, string selectorSha256)
        {
            if (string.IsNullOrWhiteSpace(selectorJson)) { throw new InvalidOperationException("ParseCanonicalWire: selector wire is empty"); }
            if (string.IsNullOrWhiteSpace(selectorSha256)) { throw new InvalidOperationException("ParseCanonicalWire: selector digest is empty"); }
            string actual = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(selectorJson)), 0, 32).ToLowerInvariant();
            if (!string.Equals(actual, selectorSha256, System.StringComparison.Ordinal)) { throw new InvalidOperationException("ParseCanonicalWire: selector digest mismatch"); }
            using (System.Text.Json.JsonDocument document = System.Text.Json.JsonDocument.Parse(selectorJson))
            {
                System.Text.Json.JsonElement root = document.RootElement;
                SealedMutationCheckpoint checkpoint = (SealedMutationCheckpoint)Enum.Parse(typeof(SealedMutationCheckpoint), root.GetProperty("Checkpoint").GetString(), true);
                SealedMutationPrimitiveVariant variant = (SealedMutationPrimitiveVariant)Enum.Parse(typeof(SealedMutationPrimitiveVariant), root.GetProperty("DeclaredVariant").GetString(), true);
                return new SealedMutationStageSelector(checkpoint, variant, selectorJson, selectorSha256,
                    root.GetProperty("IntentRawSha256").GetString(), root.GetProperty("TailRawSha256").GetString(), root.GetProperty("DerivedJournalHeadHash").GetString());
            }
        }
    }

    public sealed class SealedMutationPublicationTicket
    {
        internal int UsesRemaining;
        public SealedMutationPublicationTicket(){ UsesRemaining = 1; }
        internal bool TryConsume(){ return Interlocked.Exchange(ref UsesRemaining, 0) == 1; }
    }

    public sealed class SealedMutationStageCoordinator : IDisposable
    {
        private readonly ManualResetEventSlim _stageReady = new ManualResetEventSlim(false);
        private readonly ManualResetEventSlim _continue = new ManualResetEventSlim(false);
        private int _matchCount;
        private int _publicationFailed;
        private int _waitFailed;
        private int _disposed;

        public SealedMutationStageSelector Selector { get; }

        public SealedMutationStageCoordinator(SealedMutationStageSelector selector)
        {
            Selector = selector ?? throw new ArgumentNullException(nameof(selector));
        }

        public WaitHandle StageReady { get { return _stageReady.WaitHandle; } }
        public WaitHandle ContinueEvent { get { return _continue.WaitHandle; } }

        public void MarkPublicationFailed()
        {
            if (_disposed != 0) { throw new ObjectDisposedException(nameof(SealedMutationStageCoordinator)); }
            if (Interlocked.Exchange(ref _publicationFailed, 1) != 0) { throw new InvalidOperationException("PublishingToFailed: publication failure already recorded"); }
        }

        public void MarkPublishedSignalReadyAndWait(CancellationToken cancellation)
        {
            if (_disposed != 0) { throw new ObjectDisposedException(nameof(SealedMutationStageCoordinator)); }
            if (Interlocked.Exchange(ref _publicationFailed, 1) != 0) { throw new InvalidOperationException("PostHandoffTicketReuseRejected: publication already terminal"); }
            if (Interlocked.Increment(ref _matchCount) != 1) { throw new InvalidOperationException("AssertMatchedExactlyOnce: selector matched more than once"); }
            _stageReady.Set();
            try
            {
                if (!_continue.Wait(Timeout.Infinite)) { throw new InvalidOperationException("WaitingToFailed: continue wait failed"); }
            }
            catch (Exception)
            {
                Interlocked.Exchange(ref _waitFailed, 1);
                throw;
            }
        }

        public void WaitingToFailed()
        {
            if (Interlocked.Exchange(ref _waitFailed, 1) != 0) { throw new InvalidOperationException("WaitingToFailed: wait failure already recorded"); }
        }

        public void AssertMatchedExactlyOnce()
        {
            if (Volatile.Read(ref _matchCount) != 1) { throw new InvalidOperationException("AssertMatchedExactlyOnce: selector match count is not exactly one"); }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
            _stageReady.Dispose();
            _continue.Dispose();
        }
    }

    public sealed class SealedStageRootLease : IDisposable
    {
        public string StageRootPath { get; }
        private int _disposed;
        internal SealedStageRootLease(string stageRootPath){ StageRootPath = stageRootPath; }
        public void Dispose(){ Interlocked.Exchange(ref _disposed, 1); }
    }

    public sealed class SealedStageFileLease : IDisposable
    {
        public FileStream Stream { get; }
        private int _disposed;
        internal SealedStageFileLease(FileStream stream){ Stream = stream; }
        public void Dispose(){ if (Interlocked.Exchange(ref _disposed, 1) == 0) { Stream.Dispose(); } }
    }

    public sealed class SealedJobQpcDeadlines
    {
        public long ControllerQpcTicks { get; }
        public long HardKillCumulativeReapDeadlineQpc { get; }
        public long NaturalReleaseCumulativeReapDeadlineQpc { get; }
        public long RootCreationFileTimeTicks { get; }
        public const int HardKillTerminationExitCode = unchecked((int)0xC000042D);

        public SealedJobQpcDeadlines(long controllerQpcTicks, long hardKillCumulativeReapDeadlineQpc, long naturalReleaseCumulativeReapDeadlineQpc, long rootCreationFileTimeTicks)
        {
            ControllerQpcTicks = controllerQpcTicks;
            HardKillCumulativeReapDeadlineQpc = hardKillCumulativeReapDeadlineQpc;
            NaturalReleaseCumulativeReapDeadlineQpc = naturalReleaseCumulativeReapDeadlineQpc;
            RootCreationFileTimeTicks = rootCreationFileTimeTicks;
        }

        // The reap boundary itself lives in the parent-owned Job-process API
        // (AiAgentDotfilesTests.HardKillJobProcess.TerminateLiveAndConfirm); the
        // engine only carries the immutable absolute deadlines that bound it.
    }

    public sealed class SealedMutationInvocationContext : IDisposable
    {
        public SealedMutationStageCoordinator Coordinator { get; }
        public SealedStageRootLease StageRootLease { get; }
        public SealedJobQpcDeadlines Deadline { get; }
        public int PerReachLeaseCountBeforeContextFinally { get; internal set; }
        public int InvocationContextDisposeCount { get; internal set; }
        public bool AssertMatchedExactlyOnceFailure { get; internal set; }
        public bool DualFailurePrimaryFirst { get; internal set; }
        public string ControllerPartialCapture { get; internal set; }
        public string PartialRebindIdentityMismatch { get; internal set; }
        public string PartialSealBlocksWriteDeleteRebind { get; internal set; }
        public bool AncestorReplacementBlocked { get; internal set; }
        private int _disposed;

        public SealedMutationInvocationContext(SealedMutationStageCoordinator coordinator, SealedStageRootLease stageRootLease, SealedJobQpcDeadlines deadline)
        {
            Coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
            StageRootLease = stageRootLease ?? throw new ArgumentNullException(nameof(stageRootLease));
            Deadline = deadline ?? throw new ArgumentNullException(nameof(deadline));
        }

        public static SealedMutationInvocationContext Open(SealedMutationStageSelector stageSelector)
        {
            if (stageSelector == null) { throw new ArgumentNullException(nameof(stageSelector)); }
            long qpc = SealedStageNativeBridge.GetQpcTicks();
            SealedStageRootLease stageRootLease = new SealedStageRootLease(System.IO.Path.Combine(System.IO.Path.GetTempPath(), "ai-agent-dotfiles-sealed-stage-" + Guid.NewGuid().ToString("N")));
            System.IO.Directory.CreateDirectory(stageRootLease.StageRootPath);
            SealedJobQpcDeadlines deadlines = new SealedJobQpcDeadlines(qpc, qpc + 54000000000L, qpc + 54000000000L, 0);
            return new SealedMutationInvocationContext(new SealedMutationStageCoordinator(stageSelector), stageRootLease, deadlines);
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
            InvocationContextDisposeCount++;
            Coordinator.Dispose();
        }
    }

    public static class SealedStageNativeBridge
    {
        // ForbiddenReadDeleteBridge documents the rejected legacy sequence: an
        // exclusive writer handle followed by a READ|DELETE re-open. That bridge
        // deadlocks against itself on the same identity and is never used.
        public const string ForbiddenReadDeleteBridge = "writer-exclusive-then-READ-DELETE-reopen";

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateFileW(string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool FlushFileBuffers(IntPtr handle);

        [DllImport("kernel32.dll")]
        private static extern bool QueryPerformanceCounter(out long performanceCount);

        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint DELETE_ = 0x00010000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint CREATE_NEW = 1;
        private const uint OPEN_EXISTING = 3;
        private const uint STATUS_SHARING_VIOLATION = 0x80070020;

        public static long GetQpcTicks()
        {
            long value;
            if (!QueryPerformanceCounter(out value)) { throw new InvalidOperationException("QueryPerformanceCounter failed"); }
            return value;
        }

        // Stage publication ladder: RenameWriterNoReplace -> OpenReadBridgeShareAll -> CloseWriter -> OpenReadSealShareRead
        public static void RenameWriterNoReplace(string sourcePath, string destinationPath)
        {
            if (!MoveFileExW(sourcePath, destinationPath, MOVEFILE_REPLACE_EXISTING_NONE))
            {
                throw new IOException("RenameWriterNoReplace failed", Marshal.GetLastWin32Error());
            }
        }

        private const uint MOVEFILE_REPLACE_EXISTING_NONE = 0x00000000;

        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        private static extern bool MoveFileExW(string existingFileName, string newFileName, uint flags);

        public static IntPtr OpenReadBridgeShareAll(string path)
        {
            IntPtr handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                int error = Marshal.GetLastWin32Error();
                if ((uint)error == STATUS_SHARING_VIOLATION) { throw new IOException("STATUS_SHARING_VIOLATION on read bridge", error); }
                throw new IOException("OpenReadBridgeShareAll failed", error);
            }
            return handle;
        }

        public static void CloseWriter(IntPtr handle)
        {
            if (!CloseHandle(handle)) { throw new IOException("CloseWriter failed", Marshal.GetLastWin32Error()); }
        }

        public static IntPtr OpenReadSealShareRead(string path)
        {
            IntPtr handle = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, IntPtr.Zero, OPEN_EXISTING, 0, IntPtr.Zero);
            if (handle == new IntPtr(-1))
            {
                int error = Marshal.GetLastWin32Error();
                if ((uint)error == STATUS_SHARING_VIOLATION) { throw new IOException("STATUS_SHARING_VIOLATION on read seal", error); }
                throw new IOException("OpenReadSealShareRead failed", error);
            }
            return handle;
        }

        public static void FlushStageArtifact(IntPtr handle)
        {
            if (!FlushFileBuffers(handle)) { throw new IOException("FlushFileBuffers failed", Marshal.GetLastWin32Error()); }
        }
    }

    public static class SealedMutationNativeStage
    {
        public static string StageArtifactIdentity(string path)
        {
            IntPtr handle = SealedStageNativeBridge.OpenReadSealShareRead(path);
            try
            {
                long length = 0;
                if (!GetFileSizeEx(handle, out length)) { throw new IOException("GetFileSizeEx failed", Marshal.GetLastWin32Error()); }
                return path + ":" + length.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
            finally
            {
                SealedStageNativeBridge.CloseWriter(handle);
            }
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileSizeEx(IntPtr hFile, out long lpFileSize);
    }
}
'@ -Language CSharp -PassThru:$false | Out-Null
}

function Invoke-SealedMutationReach {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AiAgentDotfilesTests.SealedMutationInvocationContext]$InvocationContext,
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)][AiAgentDotfilesTests.SealedMutationCheckpoint]$Checkpoint,
        [Parameter(Mandatory)]$DeclaredVariant,
        [Parameter(Mandatory)]$ActualBranchState,
        [Parameter(Mandatory)]$SelectorArm,
        [Parameter(Mandatory)]$ObservedRecordData
    )
    $declared=[AiAgentDotfilesTests.SealedMutationPrimitiveVariant]$DeclaredVariant
    if($InvocationContext.Coordinator.Selector.Checkpoint -ne $Checkpoint){return}
    if($InvocationContext.Coordinator.Selector.DeclaredVariant -ne $declared){return}
    $InvocationContext.Coordinator.MarkPublishedSignalReadyAndWait([Threading.CancellationToken]::None)
}

function Initialize-SealedCanonicalRecoveryWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)][AiAgentDotfilesTests.SealedMutationInvocationContext]$InvocationContext
    )
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
                Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeWorkspaceCreate) -DeclaredVariant (([ordered]@{preimage=[AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::WorkspacePreimageCreate;'swap-old'=[AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::WorkspaceSwapOldCreate})[$role]) -ActualBranchState $role -SelectorArm ([ordered]@{WorkspaceRole=$role}) -ObservedRecordData ([ordered]@{WorkspacePath=$path;WorkspaceRole=$role;WorkspaceState=$before})
                [AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite($path)
                $created=Get-CanonicalObservedPathState -Path $path -ExpectedKind directory
                if(@((Get-SafeTreeSnapshot -Root $path).ContentTreeRows).Count -ne 1){throw "manual-recovery-required: newly created canonical $role workspace is not empty"}
                Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterWorkspaceCreate) -DeclaredVariant (([ordered]@{preimage=[AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::WorkspacePreimageCreate;'swap-old'=[AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::WorkspaceSwapOldCreate})[$role]) -ActualBranchState $role -SelectorArm ([ordered]@{WorkspaceRole=$role}) -ObservedRecordData ([ordered]@{WorkspacePath=$path;WorkspaceRole=$role;WorkspaceState=$created;CreatedIdentity=[string]$created.Identity})
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

function Invoke-SealedCanonicalParentDirectoryCreate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][AiAgentDotfilesTests.SealedMutationInvocationContext]$InvocationContext
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
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeParentCreate) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::ParentCreate) -ActualBranchState $before.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $data
        [AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite([string]$Target.TargetPath)
        $created=Get-CanonicalObservedPathState -Path ([string]$Target.TargetPath) -ExpectedKind directory
        $afterData=New-CanonicalTargetRecordData -Target $Target -TargetState $created -PreimageState $missing -SwapOldState $missing -StagedState $missing -CreatedIdentity ([string]$created.Identity)
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterParentCreate) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::ParentCreate) -ActualBranchState $before.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $afterData
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase DIR_CREATED -Data $afterData
        return $created
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}

function Invoke-SealedCanonicalDirectoryReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][AiAgentDotfilesTests.SealedMutationInvocationContext]$InvocationContext
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
            Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeDirectoryOldMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::DirectoryOldMovePresent) -ActualBranchState $prepared.TargetState.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $intent
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
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterDirectoryOldMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::DirectoryOldMovePresent) -ActualBranchState $prepared.TargetState.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $oldMoved
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase OLD_MOVED -Data $oldMoved
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase MOVE_NEW_INTENT -Data $oldMoved
        if([string]$Target.Candidate.State -ceq 'PRESENT'){
            Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeDirectoryNewMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::DirectoryNewMovePresent) -ActualBranchState $Target.Candidate.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $oldMoved
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
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterDirectoryNewMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::DirectoryNewMovePresent) -ActualBranchState $Target.Candidate.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $installedData
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeDirectoryDeletionRecord) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::DirectoryDeletionRecordMissing) -ActualBranchState $Target.Candidate.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $installedData
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase NEW_INSTALLED -Data $installedData
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterDirectoryDeletionRecord) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::DirectoryDeletionRecordMissing) -ActualBranchState $Target.Candidate.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $installedData
        return $installedData
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}

function Invoke-SealedCanonicalFileReplacement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][AiAgentDotfilesTests.SealedMutationInvocationContext]$InvocationContext
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
            Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeFileReplaceMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::FileReplacePresent) -ActualBranchState $prepared.TargetState.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $intent
            [System.IO.File]::Replace([string]$Target.StagedPath,[string]$Target.TargetPath,[string]$Target.SwapOldPath,$true)
        }else{
            Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::BeforeFileReplaceMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::FileMoveMissing) -ActualBranchState $prepared.TargetState.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $intent
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
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterFileReplaceMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::FileReplacePresent) -ActualBranchState $prepared.TargetState.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $replaced
        Invoke-SealedMutationReach -InvocationContext $InvocationContext -TransactionNamespace $TransactionNamespace -Checkpoint ([AiAgentDotfilesTests.SealedMutationCheckpoint]::AfterFileReplaceMove) -DeclaredVariant ([AiAgentDotfilesTests.SealedMutationPrimitiveVariant]::FileMoveMissing) -ActualBranchState $prepared.TargetState.State -SelectorArm ([ordered]@{TargetId=$Target.TargetId;TargetOrder=$Target.Order}) -ObservedRecordData $replaced
        $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase FILE_REPLACED -Data $replaced
        return $replaced
    }
    finally{Close-CanonicalMutationParentLease -Lease $lease}
}
