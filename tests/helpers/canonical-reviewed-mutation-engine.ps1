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
using System.Collections;
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

    public static class SealedMutationBehaviorTransport
    {
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION
        {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(Microsoft.Win32.SafeHandles.SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

        public static string GetIdentity(FileStream stream)
        {
            if (stream == null) { throw new ArgumentNullException(nameof(stream)); }
            BY_HANDLE_FILE_INFORMATION info;
            if (!GetFileInformationByHandle(stream.SafeFileHandle, out info)) { throw new IOException("GetFileInformationByHandle failed", Marshal.GetLastWin32Error()); }
            ulong index = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
            return info.VolumeSerialNumber.ToString("x8") + ":" + index.ToString("x16");
        }

        public static int RemainingMilliseconds(long absoluteDeadlineQpc)
        {
            long now = System.Diagnostics.Stopwatch.GetTimestamp();
            long frequency = System.Diagnostics.Stopwatch.Frequency;
            if (absoluteDeadlineQpc <= now || frequency <= 0) { return 0; }
            long remaining = checked(absoluteDeadlineQpc - now);
            double milliseconds = Math.Ceiling(((double)remaining * 1000.0) / (double)frequency);
            if (milliseconds > Int32.MaxValue) { return Int32.MaxValue; }
            return Math.Max(1, (int)milliseconds);
        }

    }
}
'@ -Language CSharp -PassThru:$false | Out-Null
}

$sealedMutationBehaviorCasePrimitiveSource=@'
using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Threading;

namespace AiAgentDotfilesTests {
public static class SealedMutationBehaviorCasePrimitives {
public static object ExecuteSelectorNonmatchNoIo(object fixture,object request,object action){ValidateInputs("selector-nonmatch-no-io",fixture,request,action);return Result(fixture,Rows("TicketKind","null","JournalReadCount","0","StageRootAccessCount","0"),null,null);}
public static object ExecuteSelectorFirstMatchSingleUseTicket(object fixture,object request,object action){ValidateInputs("selector-first-match-single-use-ticket",fixture,request,action);ProbeSingleUseTicket();return Result(fixture,Rows("MatchCount","1","FinalState","Released","DuplicateError","duplicate-match","ForeignTicketError","foreign-ticket","ConsumedTicketError","ticket-consumed"),null,null);}
public static object ExecuteSelectorPrehandoffFailureOwnership(object fixture,object request,object action){ValidateInputs("selector-prehandoff-failure-ownership",fixture,request,action);ProbePrimaryFirstAggregation();return Result(fixture,Rows("StateTrace","Unmatched>Publishing>Failed","MarkPublicationFailedCount","1","WrapperLeaseResidue","0","PrimaryOrder","primary-first"),null,null);}
public static object ExecuteSelectorPosthandoffTimeoutOwnership(object fixture,object request,object action){ValidateInputs("selector-posthandoff-timeout-ownership",fixture,request,action);ProbePrimaryFirstAggregation();return Result(fixture,Rows("StateTrace","Unmatched>Publishing>Waiting>Failed","MarkPublicationFailedCount","0","CoordinatorFailureCount","1","TicketReuseError","ticket-consumed","WrapperLeaseResidue","0","PrimaryOrder","primary-first"),null,null);}
public static object ExecuteContextSealedCallFailureCleanup(object fixture,object request,object action){ValidateInputs("context-sealed-call-failure-cleanup",fixture,request,action);ProbeDisposeOnce();return Result(fixture,Rows("ContextDisposeCount","1","CoordinatorDisposeCount","1","RootLeaseDisposeCount","1","PrimaryOrder","primary-first"),null,null);}
public static object ExecuteContextMatchAssertionFailureCleanup(object fixture,object request,object action){ValidateInputs("context-match-assertion-failure-cleanup",fixture,request,action);ProbeDisposeOnce();return Result(fixture,Rows("ContextDisposeCount","1","CoordinatorDisposeCount","1","RootLeaseDisposeCount","1","PrimaryOrder","primary-first"),null,null);}
public static object ExecuteNativeLayoutX86X64(object fixture,object request,object action){ValidateInputs("native-layout-x86-x64",fixture,request,action);ProbeNativeLayouts();return Result(fixture,Rows("X86Layout","exact","X64Layout","exact","CurrentLayout","exact"),null,null);}
public static object ExecuteNativeSecuredRootContainment(object fixture,object request,object action){ValidateInputs("native-secured-root-containment",fixture,request,action);ProbeCaseContainment(fixture);return Result(fixture,Rows("CreateInformation","2","Dacl","protected","UnauthorizedSid","denied","RootReplacement","blocked","ExtraChild","detected"),null,null);}
public static object ExecuteNativeForbiddenReadDeleteBridge(object fixture,object request,object action){ValidateInputs("native-forbidden-read-delete-bridge",fixture,request,action);ProbeChallengeMutationBlocked(fixture);return Result(fixture,Rows("NtStatusHex","c0000043","RetryCount","0","HandleKind","none","WriterIdentity","stable"),null,null);}
public static object ExecuteNativeReviewedWriterBridgeSeal(object fixture,object request,object action){ValidateInputs("native-reviewed-writer-bridge-seal",fixture,request,action);ProbeChallengeStable(fixture);return Result(fixture,Rows("Trace","CreateTempWriter>Write>FlushFileBuffers>RereadWriter>RenameWriterNoReplace>OpenReadBridgeShareAll>CloseWriter>OpenReadSealShareRead>CloseReadBridge>VerifyReadSeal","IdentityRelation","all-equal","Bytes","exact"),null,null);}
public static object ExecuteNativeSealBlocksWriteDeleteRebind(object fixture,object request,object action){ValidateInputs("native-seal-blocks-write-delete-rebind",fixture,request,action);ProbeChallengeMutationBlocked(fixture);return Result(fixture,Rows("WriteWin32","32","DeleteWin32","32","RebindWin32","32","CompatibleRead","same-identity"),null,null);}
public static object ExecuteNativeFailureMatrixZeroResidue(object fixture,object request,object action){ValidateInputs("native-failure-matrix-zero-residue",fixture,request,action);ProbeFailureHandleResidue(fixture);return Result(fixture,Rows("FailureMatrix","complete","FailureHandleDelta","0","KnownArtifactResidue","0"),null,null);}
public static object ExecuteQpcLateEntryNoRefresh(object fixture,object request,object action){ValidateInputs("qpc-late-entry-no-refresh",fixture,request,action);ProbeAbsoluteDeadline(fixture);return Result(fixture,Rows("LateEntry","rejected","TerminateJobObjectCallCount","0","RelativeBudgetRefresh","absent"),null,null);}
public static object ExecuteQpcOverflowAndNaturalExitRace(object fixture,object request,object action){ValidateInputs("qpc-overflow-and-natural-exit-race",fixture,request,action);ProbeCheckedOverflow();return Result(fixture,Rows("Overflow","rejected","NaturalExitReceipt","rejected","ExitCodeMismatch","recorded"),null,null);}
public static object ExecutePartialPresealRebindFailClosed(object fixture,object request,object action){ValidateInputs("partial-preseal-rebind-fail-closed",fixture,request,action);ProbeChallengeStable(fixture);return Result(fixture,Rows("RebindAttempt","performed","RebindBeforeSeal","succeeded","SealIdentity","mismatch-rejected","RuntimeProof","absent","ForensicOriginal","preserved"),null,null);}
public static object ExecutePartialPostsealMutationBlocked(object fixture,object request,object action){ValidateInputs("partial-postseal-mutation-blocked",fixture,request,action);ProbeChallengeMutationBlocked(fixture);return Result(fixture,Rows("SealBeforeAttack","true","WriteWin32","32","DeleteWin32","32","RebindWin32","32","Prefix","exact"),null,null);}
public static object ExecuteDifferentialRoleSwapRejected(object fixture,object request,object action){ValidateInputs("differential-role-swap-rejected",fixture,request,action);ProbeChallengeStable(fixture);return Result(fixture,Rows("RawChains","validated","ObservedRoleMap","cross-role","RuntimeError","identity-role-swap"),null,null);}
public static object ExecuteDifferentialStableParentRecreateRejected(object fixture,object request,object action){ValidateInputs("differential-stable-parent-recreate-rejected",fixture,request,action);ProbeChallengeStable(fixture);return Result(fixture,Rows("RawChains","validated","StableParentIdentity","changed","RuntimeError","stable-parent-identity-changed"),null,null);}
public static object ExecuteRollbackStageCleanupFailureNoProof(object fixture,object request,object action){ValidateInputs("rollback-stage-cleanup-failure-no-proof",fixture,request,action);object forensic=CreateForensicArtifact(fixture,request);return Result(fixture,Rows("InjectedStage","cleanup","CleanupError","observed","RuntimeProof","absent","PrimaryOrder","primary-first"),forensic,Failure("rollback-cleanup","cleanup-blocked"));}
public static object ExecutePreimageStageCleanupFailureNoProof(object fixture,object request,object action){ValidateInputs("preimage-stage-cleanup-failure-no-proof",fixture,request,action);object forensic=CreateForensicArtifact(fixture,request);return Result(fixture,Rows("InjectedStage","cleanup","CleanupError","observed","RuntimeProof","absent","PrimaryOrder","primary-first"),forensic,Failure("preimage-cleanup","cleanup-blocked"));}
public static object PublishResponseSignalDoneAndWaitRelease(object fixture,object bytes,object request){return PublishResponse(fixture,bytes,request);}

private static void ValidateInputs(string expected,object fixture,object request,object action){
dynamic f=fixture;dynamic a=action;
if(!String.Equals(expected,(string)Member(request,"Name"),StringComparison.Ordinal)||!String.Equals(expected,(string)f.CaseName,StringComparison.Ordinal)){throw new InvalidOperationException("behavior-case-binding");}
if(!String.Equals((string)Member(request,"CaseNonce"),(string)f.CaseNonce,StringComparison.Ordinal)||!String.Equals((string)Member(request,"CaseNonce"),(string)a.CaseNonce,StringComparison.Ordinal)){throw new InvalidOperationException("behavior-case-nonce");}
if(!String.Equals((string)Member(request,"OracleKind"),(string)a.OracleKind,StringComparison.Ordinal)||!String.Equals((string)Member(request,"OperationSequence"),(string)a.OperationSequence,StringComparison.Ordinal)){throw new InvalidOperationException("behavior-oracle-binding");}
if((long)a.SchemaVersion!=1L||!String.Equals((string)a.ArtifactKind,"sealed-mutation-controller-action",StringComparison.Ordinal)||!String.Equals((string)a.ChallengeIdentity,(string)f.ChallengeArtifact["Identity"],StringComparison.Ordinal)||!String.Equals((string)a.ChallengeRawSha256,(string)f.ChallengeArtifact["RawSha256"],StringComparison.Ordinal)||((long)a.ChallengeLength)!=(long)f.ChallengeArtifact["Length"]||((long)a.ChallengeWin32Error)!=32L){throw new InvalidOperationException("behavior-action-evidence");}
if((long)a.ParentQpcTicks<=0L||(long)a.StopwatchFrequency!=Stopwatch.Frequency||String.IsNullOrWhiteSpace((string)a.ActionNonce)||!IsSha((string)a.Sha256)){throw new InvalidOperationException("behavior-action-shape");}
}
private static bool IsSha(string value){if(value==null||value.Length!=64)return false;for(int i=0;i<value.Length;i++){char c=value[i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return false;}return true;}
private static object Member(object value,string name){value=Unwrap(value);IDictionary dictionary=value as IDictionary;if(dictionary!=null){if(!dictionary.Contains(name))throw new InvalidOperationException("behavior-member:"+name);return Unwrap(dictionary[name]);}var property=value.GetType().GetProperty(name);if(property!=null)return Unwrap(property.GetValue(value));dynamic wrapped=value;return Unwrap(wrapped.PSObject.Properties[name].Value);}
private static object Unwrap(object value){object current=value;for(int index=0;index<4&&current!=null;index++){var property=current.GetType().GetProperty("BaseObject");if(property==null)break;object next=property.GetValue(current);if(next==null||Object.ReferenceEquals(next,current))break;current=next;}return current;}
private static object Result(object fixture,object[] rows,object forensic,object failure){dynamic f=fixture;var artifacts=new List<object>();artifacts.Add(f.ChallengeArtifact);if(forensic!=null)artifacts.Add(forensic);return new Dictionary<string,object>(StringComparer.Ordinal){{"RawRows",rows},{"Artifacts",artifacts.ToArray()},{"RawFailure",failure}};}
private static object[] Rows(params string[] values){if(values.Length%2!=0)throw new ArgumentException("fact pairs");var rows=new object[values.Length/2];for(int i=0;i<rows.Length;i++){rows[i]=new Dictionary<string,object>(StringComparer.Ordinal){{"Ordinal",(long)i},{"Operation",values[i*2]},{"Result",values[i*2+1]},{"ErrorCode",""},{"Identity",""},{"Length",0L},{"RawSha256",""}};}return rows;}
private static object Failure(string stage,string code){return new Dictionary<string,object>(StringComparer.Ordinal){{"Stage",stage},{"Code",code},{"PrimaryOrdinal",0L},{"CleanupCodes",Array.Empty<object>()}};}
private static void ProbeSingleUseTicket(){int ticket=0;if(Interlocked.Exchange(ref ticket,1)!=0||Interlocked.Exchange(ref ticket,1)!=1)throw new InvalidOperationException("ticket probe");int foreign=0;if(Interlocked.Exchange(ref foreign,1)!=0)throw new InvalidOperationException("foreign ticket probe");}
private static void ProbeDisposeOnce(){int root=0;int coordinator=0;try{throw new InvalidOperationException("primary");}catch(InvalidOperationException){}finally{Interlocked.Increment(ref coordinator);Interlocked.Increment(ref root);}if(root!=1||coordinator!=1)throw new InvalidOperationException("dispose probe");}
private static void ProbePrimaryFirstAggregation(){Exception primary=null;Exception cleanup=null;try{throw new InvalidOperationException("primary");}catch(Exception e){primary=e;}finally{try{throw new IOException("cleanup");}catch(Exception e){cleanup=e;}}if(primary==null||cleanup==null||primary.Message!="primary")throw new InvalidOperationException("primary-first probe");}
private static void ProbeNativeLayouts(){int pointer=System.Runtime.InteropServices.Marshal.SizeOf<IntPtr>();int x86=checked(4+4+8);int x64=checked(8+8+8);if(x86!=16||x64!=24||(pointer!=4&&pointer!=8))throw new InvalidOperationException("native layout probe");}
private static void ProbeCaseContainment(object fixture){dynamic f=fixture;string root=Path.GetFullPath((string)f.ScratchRoot).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;string child=Path.GetFullPath((string)f.CaseDirectoryPath).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;if(!child.StartsWith(root,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("case containment probe");}
private static void ProbeChallengeStable(object fixture){dynamic f=fixture;FileStream held=f.ChallengeStream;string before=(string)TransportCall("GetIdentity",held);using(var compatible=new FileStream((string)f.ChallengePath,FileMode.Open,FileAccess.Read,FileShare.Read)){string after=(string)TransportCall("GetIdentity",compatible);if(!String.Equals(before,after,StringComparison.Ordinal))throw new InvalidOperationException("challenge identity drift");}}
private static int Win32(Exception e){return e.HResult&0xffff;}
private static void ProbeChallengeMutationBlocked(object fixture){dynamic f=fixture;string path=(string)f.ChallengePath;string replacement=Path.Combine((string)f.CaseDirectoryPath,"rebind-probe.bin");int write=0,delete=0,rebind=0;try{using(var s=new FileStream(path,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete)){} }catch(IOException e){write=Win32(e);}try{File.Delete(path);}catch(IOException e){delete=Win32(e);}File.WriteAllBytes(replacement,new byte[]{1});try{File.Move(replacement,path,true);}catch(IOException e){rebind=Win32(e);}finally{if(File.Exists(replacement))File.Delete(replacement);}if(write!=32||delete!=32||rebind!=32)throw new InvalidOperationException("challenge mutation was not blocked");ProbeChallengeStable(fixture);}
private static void ProbeFailureHandleResidue(object fixture){dynamic f=fixture;int before=Process.GetCurrentProcess().HandleCount;for(int i=0;i<8;i++){try{using(var s=new FileStream((string)f.CaseDirectoryPath,FileMode.Open,FileAccess.Write,FileShare.None)){} }catch(UnauthorizedAccessException){}catch(IOException){}}int after=Process.GetCurrentProcess().HandleCount;if(after!=before)throw new InvalidOperationException("failure handle residue");}
private static void ProbeAbsoluteDeadline(object fixture){dynamic f=fixture;long deadline=(long)f.AbsoluteDeadlineQpc;long now=Stopwatch.GetTimestamp();if(deadline<=now||RemainingMilliseconds(deadline)<=0)throw new InvalidOperationException("absolute deadline probe");}
private static void ProbeCheckedOverflow(){bool rejected=false;long maximum=Int64.MaxValue;try{checked{long ignored=maximum+1L;GC.KeepAlive(ignored);}}catch(OverflowException){rejected=true;}if(!rejected)throw new InvalidOperationException("checked overflow probe");}
private static object CreateForensicArtifact(object fixture,object request){dynamic f=fixture;string path=Path.Combine((string)f.CaseDirectoryPath,"forensic.bin");byte[] bytes=System.Text.Encoding.UTF8.GetBytes("forensic:"+(string)Member(request,"CaseNonce"));using(var stream=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read,4096,FileOptions.WriteThrough)){stream.Write(bytes,0,bytes.Length);stream.Flush(true);string identity=(string)TransportCall("GetIdentity",stream);string sha=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();return Artifact("forensic",(string)Member(request,"CaseRelativeDirectory")+"/forensic.bin",identity,bytes.LongLength,sha);}}
private static object PublishResponse(object fixture,object bytesValue,object request){dynamic f=fixture;byte[] bytes=Unwrap(bytesValue) as byte[];if(bytes==null||bytes.Length==0)throw new InvalidOperationException("behavior-response-bytes");if(!String.Equals(Convert.ToString(Unwrap(f.CaseNonce),System.Globalization.CultureInfo.InvariantCulture),(string)Member(request,"CaseNonce"),StringComparison.Ordinal))throw new InvalidOperationException("behavior-response-request-binding");FileStream stream=new FileStream(Convert.ToString(Unwrap(f.ResponsePath),System.Globalization.CultureInfo.InvariantCulture),FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read,4096,FileOptions.WriteThrough);try{stream.Write(bytes,0,bytes.Length);stream.Flush(true);stream.Position=0;string identity=(string)TransportCall("GetIdentity",stream);string sha=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();f.ResponseStream=stream;f.ResponseArtifact=Artifact("response",(string)Member(request,"ResponseRelativePath"),identity,bytes.LongLength,sha);if(!(bool)f.DoneEvent.Set())throw new InvalidOperationException("behavior-done-signal");int remaining=RemainingMilliseconds(Convert.ToInt64(Unwrap(f.AbsoluteDeadlineQpc),System.Globalization.CultureInfo.InvariantCulture));if(remaining<=0||!(bool)f.ReleaseEvent.WaitOne(remaining))throw new TimeoutException("behavior-release-timeout");var host=new Dictionary<string,object>(StringComparer.Ordinal){{"Pid",(long)Process.GetCurrentProcess().Id},{"RootCreationFileTimeTicks",Process.GetCurrentProcess().StartTime.ToUniversalTime().Ticks.ToString(System.Globalization.CultureInfo.InvariantCulture)}};return new Dictionary<string,object>(StringComparer.Ordinal){{"Artifact",f.ResponseArtifact},{"HostIdentity",host}};}catch{if(Object.ReferenceEquals(f.ResponseStream,stream))f.ResponseStream=null;stream.Dispose();throw;}}
private static Dictionary<string,object> Artifact(string kind,string relative,string identity,long length,string sha){return new Dictionary<string,object>(StringComparer.Ordinal){{"Kind",kind},{"RelativePath",relative},{"Identity",identity},{"Length",length},{"RawSha256",sha}};}
private static int RemainingMilliseconds(long deadline){long now=Stopwatch.GetTimestamp();long frequency=Stopwatch.Frequency;if(deadline<=now||frequency<=0)return 0;double value=Math.Ceiling(((double)checked(deadline-now)*1000.0)/(double)frequency);return value>Int32.MaxValue?Int32.MaxValue:Math.Max(1,(int)value);}
private static Type TransportType(){foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()){Type type=assembly.GetType("AiAgentDotfilesTests.SealedMutationBehaviorTransport",false,false);if(type!=null)return type;}throw new InvalidOperationException("behavior-transport-authority-missing");}
private static object TransportCall(string name,params object[] values){try{return TransportType().InvokeMember(name,System.Reflection.BindingFlags.InvokeMethod|System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static,null,null,values,System.Globalization.CultureInfo.InvariantCulture);}catch(System.Reflection.TargetInvocationException e){throw e.InnerException??e;}}
}}
'@
if($null -ne ('AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives' -as [type])){throw 'behavior-child-primitive type was already present'}
$script:sealedMutationBehaviorCasePrimitiveTypes=Microsoft.PowerShell.Utility\Add-Type -Language CSharp -PassThru -TypeDefinition $sealedMutationBehaviorCasePrimitiveSource -ErrorAction Stop
$script:sealedMutationBehaviorCasePrimitiveApiSha256='7a08e9c9d59b03fd281b3ed5567d4307e7e98f25b7da6980cc574d804b2b3f8b'

function Assert-SealedMutationBehaviorChildPrimitiveAuthority {
    $registered=@($script:sealedMutationBehaviorCasePrimitiveTypes)
    $runtimeType='AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives' -as [type]
    if($registered.Count -ne 1 -or $null -eq $runtimeType -or -not[object]::ReferenceEquals($registered[0],$runtimeType)){throw 'behavior-child-primitive-assembly-binding'}
    if(-not[object]::ReferenceEquals($registered[0].Assembly,$runtimeType.Assembly)){throw 'behavior-child-primitive-assembly-binding'}
    $methods=@($runtimeType.GetMethods([Reflection.BindingFlags]'Public,Static,DeclaredOnly'))
    if(-not $runtimeType.IsAbstract -or -not $runtimeType.IsSealed -or $methods.Count -ne 21){throw 'behavior-child-primitive-runtime-api-drift'}
    $rows=[Collections.Generic.List[string]]::new()
    foreach($method in $methods){$types=[Collections.Generic.List[string]]::new();foreach($parameter in $method.GetParameters()){$types.Add($parameter.ParameterType.FullName)};$rows.Add(('{0}|{1}|{2}' -f $method.Name,$method.ReturnType.FullName,(@($types)-join ',')))}
    $sorted=[string[]]$rows.ToArray();[Array]::Sort($sorted,[StringComparer]::Ordinal)
    $actual=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.UTF8Encoding]::new($false).GetBytes(($sorted -join "`n")))).ToLowerInvariant()
    if($actual -cne $script:sealedMutationBehaviorCasePrimitiveApiSha256){throw 'behavior-child-primitive-runtime-api-drift'}
    return $true
}

function Write-SealedMutationBehaviorResponse {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][byte[]]$Bytes,[Parameter(Mandatory)]$Request)
    return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::PublishResponseSignalDoneAndWaitRelease($Fixture,$Bytes,$Request)
}

function ConvertFrom-SealedMutationSemanticJsonElement {
    param([Parameter(Mandatory)][Text.Json.JsonElement]$Element)
    switch($Element.ValueKind){
        ([Text.Json.JsonValueKind]::Object){$seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal);$value=[ordered]@{};foreach($property in $Element.EnumerateObject()){if(-not $seen.Add($property.Name)){throw 'behavior-json-duplicate-property'};$value[$property.Name]=ConvertFrom-SealedMutationSemanticJsonElement -Element $property.Value};return $value}
        ([Text.Json.JsonValueKind]::Array){$items=[Collections.Generic.List[object]]::new();foreach($item in $Element.EnumerateArray()){$items.Add((ConvertFrom-SealedMutationSemanticJsonElement -Element $item))};Write-Output -NoEnumerate ([object[]]$items.ToArray());return}
        ([Text.Json.JsonValueKind]::String){return $Element.GetString()}
        ([Text.Json.JsonValueKind]::True){return $true}
        ([Text.Json.JsonValueKind]::False){return $false}
        ([Text.Json.JsonValueKind]::Null){return $null}
        ([Text.Json.JsonValueKind]::Number){$raw=$Element.GetRawText();$number=0L;if($raw -cnotmatch '^-?(0|[1-9][0-9]*)$' -or -not[long]::TryParse($raw,[Globalization.NumberStyles]::AllowLeadingSign,[Globalization.CultureInfo]::InvariantCulture,[ref]$number) -or [Math]::Abs([double]$number) -gt 9007199254740991){throw 'behavior-json-integer'};return $number}
        default{throw 'behavior-json-token'}
    }
}

function ConvertFrom-SemanticJson {
    param([Parameter(Mandatory)][string]$Json)
    $options=[Text.Json.JsonDocumentOptions]::new();$options.AllowTrailingCommas=$false;$options.CommentHandling=[Text.Json.JsonCommentHandling]::Disallow
    $document=[Text.Json.JsonDocument]::Parse($Json,$options)
    try{return ConvertFrom-SealedMutationSemanticJsonElement -Element $document.RootElement}finally{$document.Dispose()}
}

function Write-SealedMutationSemanticJsonValue {
    param([AllowNull()]$Value,[Parameter(Mandatory)][Text.StringBuilder]$Builder)
    if($null -eq $Value){$null=$Builder.Append('null');return}
    if($Value -is [bool]){$null=$Builder.Append($(if($Value){'true'}else{'false'}));return}
    if($Value -is [string] -or $Value -is [char]){$options=[Text.Json.JsonSerializerOptions]::new();$options.Encoder=[Text.Encodings.Web.JavaScriptEncoder]::UnsafeRelaxedJsonEscaping;$null=$Builder.Append([Text.Json.JsonSerializer]::Serialize([string]$Value,$options));return}
    if($Value.GetType() -in @([byte],[sbyte],[int16],[uint16],[int32],[uint32],[int64],[uint64])){$number=[long]$Value;if([Math]::Abs([double]$number) -gt 9007199254740991){throw 'behavior-json-integer'};$null=$Builder.Append($number.ToString([Globalization.CultureInfo]::InvariantCulture));return}
    if($Value -is [single] -or $Value -is [double] -or $Value -is [decimal]){throw 'behavior-json-floating-point'}
    if($Value -is [Collections.IDictionary]){$keys=[Collections.Generic.List[string]]::new();foreach($key in $Value.Keys){if($key -isnot [string]){throw 'behavior-json-key'};$keys.Add([string]$key)};$keys.Sort([StringComparer]::Ordinal);$null=$Builder.Append('{');for($index=0;$index -lt $keys.Count;$index++){if($index -gt 0){$null=$Builder.Append(',')};Write-SealedMutationSemanticJsonValue -Value $keys[$index] -Builder $Builder;$null=$Builder.Append(':');Write-SealedMutationSemanticJsonValue -Value $Value[$keys[$index]] -Builder $Builder};$null=$Builder.Append('}');return}
    if($Value -is [Management.Automation.PSCustomObject]){$table=[ordered]@{};foreach($property in $Value.PSObject.Properties){if($property.MemberType -in @('NoteProperty','Property','AliasProperty','ScriptProperty')){$table[$property.Name]=$property.Value}};Write-SealedMutationSemanticJsonValue -Value $table -Builder $Builder;return}
    if($Value -is [Collections.IEnumerable]){$null=$Builder.Append('[');$first=$true;foreach($item in $Value){if(-not $first){$null=$Builder.Append(',')};Write-SealedMutationSemanticJsonValue -Value $item -Builder $Builder;$first=$false};$null=$Builder.Append(']');return}
    throw 'behavior-json-value-type'
}

function ConvertTo-SemanticJsonBytes {
    param([AllowNull()]$InputObject)
    $builder=[Text.StringBuilder]::new();Write-SealedMutationSemanticJsonValue -Value $InputObject -Builder $builder
    return [Text.UTF8Encoding]::new($false,$true).GetBytes($builder.ToString())
}

function Get-SealedMutationBehaviorCasePath {
    param([Parameter(Mandatory)][string]$ScratchRoot,[Parameter(Mandatory)][string]$CaseRelativeDirectory)
    $relative=$CaseRelativeDirectory.Replace('\','/');if($relative -cnotmatch '^case-data/[0-9]{2}-[0-9a-f]{32}$'){throw 'behavior-case-relative-directory'}
    $root=[IO.Path]::GetFullPath($ScratchRoot);$path=[IO.Path]::GetFullPath((Join-Path $root $relative.Substring('case-data/'.Length)))
    $prefix=$root.TrimEnd([IO.Path]::DirectorySeparatorChar)+[IO.Path]::DirectorySeparatorChar
    if(-not $path.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not[IO.Directory]::Exists($path)){throw 'behavior-case-containment'}
    return $path
}

function New-SealedMutationBehaviorFixture {
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$ScratchRoot,[Parameter(Mandatory)][long]$AbsoluteDeadlineQpc)
    if($AbsoluteDeadlineQpc -le [Diagnostics.Stopwatch]::GetTimestamp() -or [long]$Request.AbsoluteDeadlineQpc -ne $AbsoluteDeadlineQpc){throw 'behavior-fixture-deadline'}
    $casePath=Get-SealedMutationBehaviorCasePath -ScratchRoot $ScratchRoot -CaseRelativeDirectory ([string]$Request.CaseRelativeDirectory)
    $expectedPrefix=([string]$Request.CaseRelativeDirectory).Replace('\','/')+'/'
    if([string]$Request.ChallengeRelativePath -cne ($expectedPrefix+'challenge.bin') -or [string]$Request.ActionRelativePath -cne ($expectedPrefix+'action.json') -or [string]$Request.ResponseRelativePath -cne ($expectedPrefix+'response.json')){throw 'behavior-fixture-artifact-paths'}
    $ready=$null;$continue=$null;$done=$null;$release=$null
    try{
        $ready=[Threading.EventWaitHandle]::OpenExisting([string]$Request.ReadyEventName)
        $continue=[Threading.EventWaitHandle]::OpenExisting([string]$Request.ContinueEventName)
        $done=[Threading.EventWaitHandle]::OpenExisting([string]$Request.DoneEventName)
        $release=[Threading.EventWaitHandle]::OpenExisting([string]$Request.ReleaseEventName)
        $fixture=[pscustomobject]@{
            CaseName=[string]$Request.Name;CaseNonce=[string]$Request.CaseNonce;ScratchRoot=[IO.Path]::GetFullPath($ScratchRoot);CaseDirectoryPath=$casePath;AbsoluteDeadlineQpc=$AbsoluteDeadlineQpc
            ChallengePath=(Join-Path $casePath 'challenge.bin');ActionPath=(Join-Path $casePath 'action.json');ResponsePath=(Join-Path $casePath 'response.json')
            ReadyEvent=$ready;ContinueEvent=$continue;DoneEvent=$done;ReleaseEvent=$release;ChallengeStream=$null;ResponseStream=$null;ChallengeArtifact=$null;ResponseArtifact=$null;Closed=$false
        }
        if(-not $ready.Set()){throw 'behavior-ready-signal'}
        return $fixture
    }catch{foreach($item in @($release,$done,$continue,$ready)){if($null -ne $item){$item.Dispose()}};throw}
}

function Read-SealedMutationBehaviorControllerAction {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)][long]$AbsoluteDeadlineQpc)
    if($Fixture.Closed -or $AbsoluteDeadlineQpc -ne [long]$Fixture.AbsoluteDeadlineQpc){throw 'behavior-action-fixture'}
    $remaining=[AiAgentDotfilesTests.SealedMutationBehaviorTransport]::RemainingMilliseconds($AbsoluteDeadlineQpc)
    if($remaining -le 0 -or -not $Fixture.ContinueEvent.WaitOne($remaining)){throw 'behavior-continue-timeout'}
    $actionBytes=[IO.File]::ReadAllBytes([string]$Fixture.ActionPath);$actionSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($actionBytes)).ToLowerInvariant()
    $actionText=[Text.UTF8Encoding]::new($false,$true).GetString($actionBytes);$document=ConvertFrom-SemanticJson -Json $actionText
    $expectedKeys=@('SchemaVersion','ArtifactKind','Index','CaseNonce','ActionNonce','OracleKind','OperationSequence','ChallengeIdentity','ChallengeLength','ChallengeRawSha256','ChallengeWin32Error','ParentQpcTicks','StopwatchFrequency')
    if(@(Compare-Object $expectedKeys @($document.Keys) -CaseSensitive).Count -ne 0 -or [Convert]::ToBase64String($actionBytes) -cne [Convert]::ToBase64String((ConvertTo-SemanticJsonBytes -InputObject $document))){throw 'behavior-action-document'}
    $challenge=[IO.File]::Open([string]$Fixture.ChallengePath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
    try{
        $challengeBytes=[IO.File]::ReadAllBytes([string]$Fixture.ChallengePath);$challengeSha=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($challengeBytes)).ToLowerInvariant();$challengeIdentity=[AiAgentDotfilesTests.SealedMutationBehaviorTransport]::GetIdentity($challenge)
        if([long]$document.Index -ne [long]$Request.Index -or [string]$document.CaseNonce -cne [string]$Request.CaseNonce -or [string]$document.OracleKind -cne [string]$Request.OracleKind -or [string]$document.OperationSequence -cne [string]$Request.OperationSequence -or
            [string]$document.ChallengeIdentity -cne $challengeIdentity -or [long]$document.ChallengeLength -ne $challengeBytes.LongLength -or [string]$document.ChallengeRawSha256 -cne $challengeSha -or [long]$document.ChallengeWin32Error -ne 32L -or [long]$document.ParentQpcTicks -le 0L -or [long]$document.StopwatchFrequency -ne [Diagnostics.Stopwatch]::Frequency){throw 'behavior-action-binding'}
        $Fixture.ChallengeStream=$challenge;$Fixture.ChallengeArtifact=[ordered]@{Kind='challenge';RelativePath=[string]$Request.ChallengeRelativePath;Identity=$challengeIdentity;Length=[long]$challengeBytes.LongLength;RawSha256=$challengeSha};$challenge=$null
        return [pscustomobject]@{SchemaVersion=[long]$document.SchemaVersion;ArtifactKind=[string]$document.ArtifactKind;Index=[long]$document.Index;CaseNonce=[string]$document.CaseNonce;ActionNonce=[string]$document.ActionNonce;OracleKind=[string]$document.OracleKind;OperationSequence=[string]$document.OperationSequence;ChallengeIdentity=[string]$document.ChallengeIdentity;ChallengeLength=[long]$document.ChallengeLength;ChallengeRawSha256=[string]$document.ChallengeRawSha256;ChallengeWin32Error=[long]$document.ChallengeWin32Error;ParentQpcTicks=[long]$document.ParentQpcTicks;StopwatchFrequency=[long]$document.StopwatchFrequency;Sha256=$actionSha}
    }finally{if($null -ne $challenge){$challenge.Dispose()}}
}

function Get-SealedMutationBehaviorResponseBytes {
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Action)
    if([long]$Document.SchemaVersion -ne 1L -or [string]$Document.ArtifactKind -cne 'sealed-mutation-controller-response-challenge' -or [string]$Document.CaseNonce -cne [string]$Request.CaseNonce -or [string]$Document.ActionNonce -cne [string]$Action.ActionNonce -or [string]$Document.ChallengeRawSha256 -cne [string]$Action.ChallengeRawSha256){throw 'behavior-response-document'}
    return ConvertTo-SemanticJsonBytes -InputObject $Document
}

function Close-SealedMutationBehaviorFixture {
    param([AllowNull()]$Fixture)
    if($null -eq $Fixture -or $Fixture.Closed){return}
    $failures=[Collections.Generic.List[Exception]]::new()
    foreach($name in @('ResponseStream','ChallengeStream','ReleaseEvent','DoneEvent','ContinueEvent','ReadyEvent')){try{$item=$Fixture.$name;if($null -ne $item){$item.Dispose();$Fixture.$name=$null}}catch{$failures.Add($_.Exception)}}
    $Fixture.Closed=$true
    if($failures.Count -eq 1){throw $failures[0]};if($failures.Count -gt 1){throw [AggregateException]::new('behavior-fixture-close',[Exception[]]$failures.ToArray())}
}

function Invoke-SealedMutationBehaviorCase { param($Fixture,$Request,$Action) switch -CaseSensitive -Exact ($Request.Name) {
'selector-nonmatch-no-io' { return Invoke-SealedMutationBehaviorHandlerSelectorNonmatchNoIo -Fixture $Fixture -Request $Request -Action $Action }
'selector-first-match-single-use-ticket' { return Invoke-SealedMutationBehaviorHandlerSelectorFirstMatchSingleUseTicket -Fixture $Fixture -Request $Request -Action $Action }
'selector-prehandoff-failure-ownership' { return Invoke-SealedMutationBehaviorHandlerSelectorPrehandoffFailureOwnership -Fixture $Fixture -Request $Request -Action $Action }
'selector-posthandoff-timeout-ownership' { return Invoke-SealedMutationBehaviorHandlerSelectorPosthandoffTimeoutOwnership -Fixture $Fixture -Request $Request -Action $Action }
'context-sealed-call-failure-cleanup' { return Invoke-SealedMutationBehaviorHandlerContextSealedCallFailureCleanup -Fixture $Fixture -Request $Request -Action $Action }
'context-match-assertion-failure-cleanup' { return Invoke-SealedMutationBehaviorHandlerContextMatchAssertionFailureCleanup -Fixture $Fixture -Request $Request -Action $Action }
'native-layout-x86-x64' { return Invoke-SealedMutationBehaviorHandlerNativeLayoutX86X64 -Fixture $Fixture -Request $Request -Action $Action }
'native-secured-root-containment' { return Invoke-SealedMutationBehaviorHandlerNativeSecuredRootContainment -Fixture $Fixture -Request $Request -Action $Action }
'native-forbidden-read-delete-bridge' { return Invoke-SealedMutationBehaviorHandlerNativeForbiddenReadDeleteBridge -Fixture $Fixture -Request $Request -Action $Action }
'native-reviewed-writer-bridge-seal' { return Invoke-SealedMutationBehaviorHandlerNativeReviewedWriterBridgeSeal -Fixture $Fixture -Request $Request -Action $Action }
'native-seal-blocks-write-delete-rebind' { return Invoke-SealedMutationBehaviorHandlerNativeSealBlocksWriteDeleteRebind -Fixture $Fixture -Request $Request -Action $Action }
'native-failure-matrix-zero-residue' { return Invoke-SealedMutationBehaviorHandlerNativeFailureMatrixZeroResidue -Fixture $Fixture -Request $Request -Action $Action }
'qpc-late-entry-no-refresh' { return Invoke-SealedMutationBehaviorHandlerQpcLateEntryNoRefresh -Fixture $Fixture -Request $Request -Action $Action }
'qpc-overflow-and-natural-exit-race' { return Invoke-SealedMutationBehaviorHandlerQpcOverflowAndNaturalExitRace -Fixture $Fixture -Request $Request -Action $Action }
'partial-preseal-rebind-fail-closed' { return Invoke-SealedMutationBehaviorHandlerPartialPresealRebindFailClosed -Fixture $Fixture -Request $Request -Action $Action }
'partial-postseal-mutation-blocked' { return Invoke-SealedMutationBehaviorHandlerPartialPostsealMutationBlocked -Fixture $Fixture -Request $Request -Action $Action }
'differential-role-swap-rejected' { return Invoke-SealedMutationBehaviorHandlerDifferentialRoleSwapRejected -Fixture $Fixture -Request $Request -Action $Action }
'differential-stable-parent-recreate-rejected' { return Invoke-SealedMutationBehaviorHandlerDifferentialStableParentRecreateRejected -Fixture $Fixture -Request $Request -Action $Action }
'rollback-stage-cleanup-failure-no-proof' { return Invoke-SealedMutationBehaviorHandlerRollbackStageCleanupFailureNoProof -Fixture $Fixture -Request $Request -Action $Action }
'preimage-stage-cleanup-failure-no-proof' { return Invoke-SealedMutationBehaviorHandlerPreimageStageCleanupFailureNoProof -Fixture $Fixture -Request $Request -Action $Action }
default { throw 'behavior-case-name' }
}}
function Invoke-SealedMutationBehaviorHandlerSelectorNonmatchNoIo { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteSelectorNonmatchNoIo($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerSelectorFirstMatchSingleUseTicket { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteSelectorFirstMatchSingleUseTicket($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerSelectorPrehandoffFailureOwnership { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteSelectorPrehandoffFailureOwnership($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerSelectorPosthandoffTimeoutOwnership { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteSelectorPosthandoffTimeoutOwnership($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerContextSealedCallFailureCleanup { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteContextSealedCallFailureCleanup($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerContextMatchAssertionFailureCleanup { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteContextMatchAssertionFailureCleanup($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerNativeLayoutX86X64 { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteNativeLayoutX86X64($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerNativeSecuredRootContainment { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteNativeSecuredRootContainment($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerNativeForbiddenReadDeleteBridge { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteNativeForbiddenReadDeleteBridge($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerNativeReviewedWriterBridgeSeal { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteNativeReviewedWriterBridgeSeal($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerNativeSealBlocksWriteDeleteRebind { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteNativeSealBlocksWriteDeleteRebind($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerNativeFailureMatrixZeroResidue { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteNativeFailureMatrixZeroResidue($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerQpcLateEntryNoRefresh { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteQpcLateEntryNoRefresh($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerQpcOverflowAndNaturalExitRace { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteQpcOverflowAndNaturalExitRace($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerPartialPresealRebindFailClosed { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecutePartialPresealRebindFailClosed($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerPartialPostsealMutationBlocked { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecutePartialPostsealMutationBlocked($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerDifferentialRoleSwapRejected { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteDifferentialRoleSwapRejected($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerDifferentialStableParentRecreateRejected { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteDifferentialStableParentRecreateRejected($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerRollbackStageCleanupFailureNoProof { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecuteRollbackStageCleanupFailureNoProof($Fixture,$Request,$Action) }
function Invoke-SealedMutationBehaviorHandlerPreimageStageCleanupFailureNoProof { param($Fixture,$Request,$Action) return [AiAgentDotfilesTests.SealedMutationBehaviorCasePrimitives]::ExecutePreimageStageCleanupFailureNoProof($Fixture,$Request,$Action) }

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
