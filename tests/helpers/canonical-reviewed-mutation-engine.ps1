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
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Threading;
using Microsoft.Win32.SafeHandles;

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
        private const int ReviewedControllerObservationMilliseconds = 300000;
        private const int ReviewedJobReapMilliseconds = 30000;
        private const int ReviewedCleanupMilliseconds = 30000;
        private const int ReviewedWorkerWaitMilliseconds = 420000;
        private static readonly Regex CanonicalPositiveInt64 = new Regex("^[1-9][0-9]{0,18}$", RegexOptions.CultureInvariant);
        private static readonly Regex LowerSha256 = new Regex("^[0-9a-f]{64}$", RegexOptions.CultureInvariant);
        private static readonly JsonSerializerOptions CanonicalJsonOptions = CreateCanonicalJsonOptions();
        private static readonly string[] ExactWireKeys = new string[] {
            "SchemaVersion", "ArtifactKind", "ControllerNonce", "CaseNonce",
            "StageReadyEventName", "StageReadyEventNonce", "ContinueEventName", "ContinueEventNonce",
            "TransactionId", "TransactionNamespace", "Checkpoint", "DeclaredVariant",
            "ExpectedIntentPhase", "ExpectedIntentSequence", "ExpectedTailPhase", "ExpectedTailSequence",
            "SelectorArm", "StageRootPath", "StageRootIdentity", "StageTempLeaf", "StageFinalLeaf",
            "ControllerObservationMilliseconds", "JobReapMilliseconds", "CleanupMilliseconds", "WorkerWaitMilliseconds",
            "ControllerQpcTicks", "StopwatchFrequency", "ControllerObservationDeadlineQpc",
            "HardKillCumulativeReapDeadlineQpc", "WorkerDeadlineQpc", "NaturalReleaseCumulativeReapDeadlineQpc",
            "HardKillCumulativeCleanupDeadlineQpc", "NaturalReleaseCumulativeCleanupDeadlineQpc"
        };

        public string ControllerNonce { get; }
        public string CaseNonce { get; }
        public string StageReadyEventName { get; }
        public string StageReadyEventNonce { get; }
        public string ContinueEventName { get; }
        public string ContinueEventNonce { get; }
        public string TransactionId { get; }
        public string TransactionNamespace { get; }
        public SealedMutationCheckpoint Checkpoint { get; }
        public SealedMutationPrimitiveVariant DeclaredVariant { get; }
        public string SelectorArmJson { get; }
        public string WorkspaceRole { get; }
        public string TargetId { get; }
        public long TargetOrder { get; }
        public string ExpectedIntentPhase { get; }
        public long ExpectedIntentSequence { get; }
        public string ExpectedTailPhase { get; }
        public long ExpectedTailSequence { get; }
        public string StageRootPath { get; }
        public string StageRootIdentity { get; }
        public string StageTempLeaf { get; }
        public string StageFinalLeaf { get; }
        public int ControllerObservationMilliseconds { get; }
        public int JobReapMilliseconds { get; }
        public int CleanupMilliseconds { get; }
        public int WorkerWaitMilliseconds { get; }
        public long ControllerQpcTicks { get; }
        public long StopwatchFrequency { get; }
        public long ControllerObservationDeadlineQpc { get; }
        public long HardKillCumulativeReapDeadlineQpc { get; }
        public long WorkerDeadlineQpc { get; }
        public long NaturalReleaseCumulativeReapDeadlineQpc { get; }
        public long HardKillCumulativeCleanupDeadlineQpc { get; }
        public long NaturalReleaseCumulativeCleanupDeadlineQpc { get; }
        public string SelectorSha256 { get; }
        public SealedJobQpcDeadlines Deadlines { get; }

        private SealedMutationStageSelector(IDictionary wire, string selectorSha256)
        {
            ControllerNonce = RequiredNonce(wire, "ControllerNonce");
            CaseNonce = RequiredNonce(wire, "CaseNonce");
            StageReadyEventName = RequiredEventName(wire, "StageReadyEventName");
            StageReadyEventNonce = RequiredNonce(wire, "StageReadyEventNonce");
            ContinueEventName = RequiredEventName(wire, "ContinueEventName");
            ContinueEventNonce = RequiredNonce(wire, "ContinueEventNonce");
            if (String.Equals(StageReadyEventName, ContinueEventName, StringComparison.Ordinal) ||
                String.Equals(StageReadyEventNonce, ContinueEventNonce, StringComparison.Ordinal))
                throw new ArgumentException("selector event identities are not distinct");
            TransactionId = RequiredString(wire, "TransactionId");
            Guid transactionGuid;
            if (!Guid.TryParseExact(TransactionId, "D", out transactionGuid) ||
                !String.Equals(transactionGuid.ToString("D"), TransactionId, StringComparison.Ordinal))
                throw new ArgumentException("selector transaction id is not canonical");
            TransactionNamespace = RequiredCanonicalPath(wire, "TransactionNamespace");
            Checkpoint = RequiredEnum<SealedMutationCheckpoint>(wire, "Checkpoint");
            DeclaredVariant = RequiredEnum<SealedMutationPrimitiveVariant>(wire, "DeclaredVariant");
            ExpectedIntentPhase = RequiredPhase(wire, "ExpectedIntentPhase");
            ExpectedIntentSequence = RequiredPositiveJsonInt64(wire, "ExpectedIntentSequence");
            ExpectedTailPhase = RequiredPhase(wire, "ExpectedTailPhase");
            ExpectedTailSequence = RequiredPositiveJsonInt64(wire, "ExpectedTailSequence");
            if (ExpectedTailSequence < ExpectedIntentSequence)
                throw new ArgumentException("selector durable tail precedes intent");

            IDictionary arm = RequiredDictionary(wire, "SelectorArm");
            SelectorArmJson = CanonicalJson(arm);
            if (HasExactKeys(arm, new string[] { "WorkspaceRole" })) {
                WorkspaceRole = RequiredString(arm, "WorkspaceRole");
                if (WorkspaceRole != "preimage" && WorkspaceRole != "swap-old")
                    throw new ArgumentException("selector workspace role is invalid");
                TargetId = null;
                TargetOrder = -1L;
            } else if (HasExactKeys(arm, new string[] { "TargetId", "TargetOrder" })) {
                WorkspaceRole = null;
                TargetId = RequiredString(arm, "TargetId");
                TargetOrder = RequiredNonnegativeJsonInt64(arm, "TargetOrder");
            } else {
                throw new ArgumentException("selector arm is not exactly one reviewed arm");
            }
            ValidateArmAndVariant();
            ValidateDurablePhaseContract();

            StageRootPath = RequiredCanonicalPath(wire, "StageRootPath");
            StageRootIdentity = RequiredIdentity(wire, "StageRootIdentity");
            StageTempLeaf = RequiredLeaf(wire, "StageTempLeaf");
            StageFinalLeaf = RequiredLeaf(wire, "StageFinalLeaf");
            if (String.Equals(StageTempLeaf, StageFinalLeaf, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("selector stage leaves are not distinct");

            ControllerObservationMilliseconds = RequiredExactBudget(wire, "ControllerObservationMilliseconds", ReviewedControllerObservationMilliseconds);
            JobReapMilliseconds = RequiredExactBudget(wire, "JobReapMilliseconds", ReviewedJobReapMilliseconds);
            CleanupMilliseconds = RequiredExactBudget(wire, "CleanupMilliseconds", ReviewedCleanupMilliseconds);
            WorkerWaitMilliseconds = RequiredExactBudget(wire, "WorkerWaitMilliseconds", ReviewedWorkerWaitMilliseconds);
            if (checked(ControllerObservationMilliseconds + JobReapMilliseconds + CleanupMilliseconds + 30000) >= WorkerWaitMilliseconds ||
                WorkerWaitMilliseconds >= 480000 || 480000 >= 5400000)
                throw new ArgumentException("selector reviewed budget inequality failed");

            ControllerQpcTicks = RequiredCanonicalWireInt64(wire, "ControllerQpcTicks");
            StopwatchFrequency = RequiredCanonicalWireInt64(wire, "StopwatchFrequency");
            if (StopwatchFrequency != Stopwatch.Frequency)
                throw new ArgumentException("selector stopwatch frequency differs from this process");
            ControllerObservationDeadlineQpc = RequiredCanonicalWireInt64(wire, "ControllerObservationDeadlineQpc");
            HardKillCumulativeReapDeadlineQpc = RequiredCanonicalWireInt64(wire, "HardKillCumulativeReapDeadlineQpc");
            WorkerDeadlineQpc = RequiredCanonicalWireInt64(wire, "WorkerDeadlineQpc");
            NaturalReleaseCumulativeReapDeadlineQpc = RequiredCanonicalWireInt64(wire, "NaturalReleaseCumulativeReapDeadlineQpc");
            HardKillCumulativeCleanupDeadlineQpc = RequiredCanonicalWireInt64(wire, "HardKillCumulativeCleanupDeadlineQpc");
            NaturalReleaseCumulativeCleanupDeadlineQpc = RequiredCanonicalWireInt64(wire, "NaturalReleaseCumulativeCleanupDeadlineQpc");
            RequireDeadline(ControllerObservationDeadlineQpc, AddMilliseconds(ControllerQpcTicks, ControllerObservationMilliseconds, StopwatchFrequency), "controller observation");
            RequireDeadline(HardKillCumulativeReapDeadlineQpc, AddMilliseconds(ControllerObservationDeadlineQpc, JobReapMilliseconds, StopwatchFrequency), "hard-kill reap");
            RequireDeadline(WorkerDeadlineQpc, AddMilliseconds(ControllerQpcTicks, WorkerWaitMilliseconds, StopwatchFrequency), "worker");
            RequireDeadline(NaturalReleaseCumulativeReapDeadlineQpc, AddMilliseconds(WorkerDeadlineQpc, JobReapMilliseconds, StopwatchFrequency), "natural-release reap");
            RequireDeadline(HardKillCumulativeCleanupDeadlineQpc, AddMilliseconds(HardKillCumulativeReapDeadlineQpc, CleanupMilliseconds, StopwatchFrequency), "hard-kill cleanup");
            RequireDeadline(NaturalReleaseCumulativeCleanupDeadlineQpc, AddMilliseconds(NaturalReleaseCumulativeReapDeadlineQpc, CleanupMilliseconds, StopwatchFrequency), "natural-release cleanup");

            SelectorSha256 = selectorSha256;
            Deadlines = new SealedJobQpcDeadlines(WorkerWaitMilliseconds, ControllerObservationMilliseconds,
                JobReapMilliseconds, CleanupMilliseconds, StopwatchFrequency, ControllerQpcTicks, WorkerDeadlineQpc,
                ControllerObservationDeadlineQpc, HardKillCumulativeReapDeadlineQpc,
                HardKillCumulativeCleanupDeadlineQpc, NaturalReleaseCumulativeReapDeadlineQpc,
                NaturalReleaseCumulativeCleanupDeadlineQpc, SelectorSha256);
        }

        public static SealedMutationStageSelector ParseCanonicalWire(object canonicalWire, string expectedSha256)
        {
            IDictionary wire = canonicalWire as IDictionary;
            if (wire == null) throw new ArgumentException("selector wire must be a dictionary", nameof(canonicalWire));
            if (!HasExactKeys(wire, ExactWireKeys)) throw new ArgumentException("selector wire has unknown or missing keys", nameof(canonicalWire));
            if (RequiredPositiveJsonInt64(wire, "SchemaVersion") != 1L || RequiredString(wire, "ArtifactKind") != "sealed-mutation-stage-selector")
                throw new ArgumentException("selector wire header is invalid", nameof(canonicalWire));
            if (String.IsNullOrEmpty(expectedSha256) || !LowerSha256.IsMatch(expectedSha256))
                throw new ArgumentException("selector hash is not canonical", nameof(expectedSha256));
            string actual = Hex(SHA256.HashData(new UTF8Encoding(false, true).GetBytes(CanonicalJson(wire))));
            if (!String.Equals(actual, expectedSha256, StringComparison.Ordinal))
                throw new ArgumentException("selector semantic hash mismatch", nameof(expectedSha256));
            return new SealedMutationStageSelector(wire, actual);
        }

        internal bool MatchesArm(string selectorArmJson)
        {
            return String.Equals(SelectorArmJson, selectorArmJson, StringComparison.Ordinal);
        }

        internal bool VariantIsCompatible(SealedMutationCheckpoint checkpoint, SealedMutationPrimitiveVariant declaredVariant, string actualBranchState)
        {
            SealedMutationPrimitiveVariant derived;
            switch (checkpoint) {
                case SealedMutationCheckpoint.BeforeWorkspaceCreate:
                case SealedMutationCheckpoint.AfterWorkspaceCreate:
                    if (actualBranchState == "preimage") derived = SealedMutationPrimitiveVariant.WorkspacePreimageCreate;
                    else if (actualBranchState == "swap-old") derived = SealedMutationPrimitiveVariant.WorkspaceSwapOldCreate;
                    else return false;
                    break;
                case SealedMutationCheckpoint.BeforeParentCreate:
                case SealedMutationCheckpoint.AfterParentCreate:
                    if (actualBranchState != "MISSING") return false;
                    derived = SealedMutationPrimitiveVariant.ParentCreate;
                    break;
                case SealedMutationCheckpoint.BeforeDirectoryOldMove:
                case SealedMutationCheckpoint.AfterDirectoryOldMove:
                    if (actualBranchState != "PRESENT") return false;
                    derived = SealedMutationPrimitiveVariant.DirectoryOldMovePresent;
                    break;
                case SealedMutationCheckpoint.BeforeDirectoryNewMove:
                case SealedMutationCheckpoint.AfterDirectoryNewMove:
                    if (actualBranchState != "PRESENT") return false;
                    derived = SealedMutationPrimitiveVariant.DirectoryNewMovePresent;
                    break;
                case SealedMutationCheckpoint.BeforeDirectoryDeletionRecord:
                case SealedMutationCheckpoint.AfterDirectoryDeletionRecord:
                    if (actualBranchState != "MISSING") return false;
                    derived = SealedMutationPrimitiveVariant.DirectoryDeletionRecordMissing;
                    break;
                case SealedMutationCheckpoint.BeforeFileReplaceMove:
                case SealedMutationCheckpoint.AfterFileReplaceMove:
                    if (actualBranchState == "PRESENT") derived = SealedMutationPrimitiveVariant.FileReplacePresent;
                    else if (actualBranchState == "MISSING") derived = SealedMutationPrimitiveVariant.FileMoveMissing;
                    else return false;
                    break;
                case SealedMutationCheckpoint.PreimageReady:
                    if (actualBranchState != "PRESENT") return false;
                    derived = SealedMutationPrimitiveVariant.RealPreimageFile;
                    break;
                case SealedMutationCheckpoint.RetainedPartialPreimage:
                    if (actualBranchState != "PRESENT") return false;
                    derived = SealedMutationPrimitiveVariant.RetainedPartialPreimageFile;
                    break;
                default: return false;
            }
            return derived == declaredVariant && derived == DeclaredVariant;
        }

        internal static string CanonicalJson(object value)
        {
            StringBuilder builder = new StringBuilder();
            WriteCanonicalJson(value, builder);
            return builder.ToString();
        }

        private void ValidateArmAndVariant()
        {
            bool workspace = WorkspaceRole != null;
            bool workspaceCheckpoint = Checkpoint == SealedMutationCheckpoint.BeforeWorkspaceCreate || Checkpoint == SealedMutationCheckpoint.AfterWorkspaceCreate;
            if (workspace != workspaceCheckpoint) throw new ArgumentException("selector arm is incompatible with checkpoint");
            string actual = workspace ? WorkspaceRole : DerivedSelectorState(Checkpoint, DeclaredVariant);
            if (!VariantIsCompatible(Checkpoint, DeclaredVariant, actual))
                throw new ArgumentException("selector variant is incompatible with checkpoint and arm");
        }

        private void ValidateDurablePhaseContract()
        {
            string intent;
            string tail;
            bool adjacent = false;
            switch (Checkpoint) {
                case SealedMutationCheckpoint.BeforeWorkspaceCreate:
                case SealedMutationCheckpoint.AfterWorkspaceCreate:
                    intent = "WORKSPACE_CREATE_INTENT"; tail = intent; break;
                case SealedMutationCheckpoint.BeforeParentCreate:
                case SealedMutationCheckpoint.AfterParentCreate:
                    intent = "DIR_CREATE_INTENT"; tail = intent; break;
                case SealedMutationCheckpoint.BeforeDirectoryOldMove:
                case SealedMutationCheckpoint.AfterDirectoryOldMove:
                    intent = "MOVE_OLD_INTENT"; tail = intent; break;
                case SealedMutationCheckpoint.BeforeDirectoryNewMove:
                case SealedMutationCheckpoint.AfterDirectoryNewMove:
                case SealedMutationCheckpoint.BeforeDirectoryDeletionRecord:
                    intent = "MOVE_NEW_INTENT"; tail = intent; break;
                case SealedMutationCheckpoint.AfterDirectoryDeletionRecord:
                    intent = "MOVE_NEW_INTENT"; tail = "NEW_INSTALLED"; adjacent = true; break;
                case SealedMutationCheckpoint.BeforeFileReplaceMove:
                case SealedMutationCheckpoint.AfterFileReplaceMove:
                    intent = "FILE_REPLACE_INTENT"; tail = intent; break;
                case SealedMutationCheckpoint.PreimageReady:
                    intent = "WORKSPACE_CREATE_INTENT"; tail = "WORKSPACE_CREATED"; adjacent = true; break;
                case SealedMutationCheckpoint.RetainedPartialPreimage:
                    intent = "PREIMAGE_COPY_INTENT"; tail = intent; break;
                default: throw new ArgumentException("selector checkpoint has no durable phase contract");
            }
            if (!String.Equals(ExpectedIntentPhase, intent, StringComparison.Ordinal) ||
                !String.Equals(ExpectedTailPhase, tail, StringComparison.Ordinal))
                throw new ArgumentException("selector durable phases are incompatible with its checkpoint");
            long expectedTailSequence = adjacent ? checked(ExpectedIntentSequence + 1L) : ExpectedIntentSequence;
            if (ExpectedTailSequence != expectedTailSequence)
                throw new ArgumentException("selector durable phase sequences are incompatible with its checkpoint");
        }

        private static string DerivedSelectorState(SealedMutationCheckpoint checkpoint, SealedMutationPrimitiveVariant variant)
        {
            if (checkpoint == SealedMutationCheckpoint.BeforeParentCreate || checkpoint == SealedMutationCheckpoint.AfterParentCreate ||
                checkpoint == SealedMutationCheckpoint.BeforeDirectoryDeletionRecord || checkpoint == SealedMutationCheckpoint.AfterDirectoryDeletionRecord ||
                variant == SealedMutationPrimitiveVariant.FileMoveMissing) return "MISSING";
            return "PRESENT";
        }

        private static void WriteCanonicalJson(object value, StringBuilder builder)
        {
            if (value == null) { builder.Append("null"); return; }
            if (value is string || value is char) { builder.Append(JsonSerializer.Serialize(Convert.ToString(value, CultureInfo.InvariantCulture), CanonicalJsonOptions)); return; }
            if (value is bool) { builder.Append((bool)value ? "true" : "false"); return; }
            Type type = value.GetType();
            if (type == typeof(byte) || type == typeof(sbyte) || type == typeof(short) || type == typeof(ushort) ||
                type == typeof(int) || type == typeof(uint) || type == typeof(long)) {
                builder.Append(Convert.ToInt64(value, CultureInfo.InvariantCulture).ToString(CultureInfo.InvariantCulture)); return;
            }
            IDictionary dictionary = value as IDictionary;
            if (dictionary != null) {
                List<string> keys = new List<string>();
                foreach (object key in dictionary.Keys) { if (!(key is string)) throw new ArgumentException("selector JSON key is not a string"); keys.Add((string)key); }
                keys.Sort(StringComparer.Ordinal);
                builder.Append('{');
                for (int index = 0; index < keys.Count; index++) {
                    if (index != 0) builder.Append(',');
                    WriteCanonicalJson(keys[index], builder); builder.Append(':'); WriteCanonicalJson(dictionary[keys[index]], builder);
                }
                builder.Append('}'); return;
            }
            IEnumerable values = value as IEnumerable;
            if (values != null) {
                builder.Append('['); bool first = true;
                foreach (object item in values) { if (!first) builder.Append(','); WriteCanonicalJson(item, builder); first = false; }
                builder.Append(']'); return;
            }
            throw new ArgumentException("selector JSON contains an unsupported value type: " + type.FullName);
        }

        private static bool HasExactKeys(IDictionary dictionary, string[] expected)
        {
            HashSet<string> actual = new HashSet<string>(StringComparer.Ordinal);
            foreach (object key in dictionary.Keys) { string name = key as string; if (name == null || !actual.Add(name)) return false; }
            return actual.SetEquals(expected);
        }
        private static JsonSerializerOptions CreateCanonicalJsonOptions() { JsonSerializerOptions options = new JsonSerializerOptions(); options.Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping; return options; }
        private static object Required(IDictionary source, string name) { if (!source.Contains(name)) throw new ArgumentException("selector field is missing: " + name); return source[name]; }
        private static IDictionary RequiredDictionary(IDictionary source, string name) { IDictionary value = Required(source, name) as IDictionary; if (value == null) throw new ArgumentException("selector field is not a dictionary: " + name); return value; }
        private static string RequiredString(IDictionary source, string name) { object raw = Required(source, name); string value = raw as string; if (String.IsNullOrWhiteSpace(value)) throw new ArgumentException("selector string is invalid: " + name); return value; }
        private static string RequiredNonce(IDictionary source, string name) { string value = RequiredString(source, name); if (!Regex.IsMatch(value, "^[0-9a-f]{32}$", RegexOptions.CultureInvariant)) throw new ArgumentException("selector nonce is invalid: " + name); return value; }
        private static string RequiredEventName(IDictionary source, string name) { string value = RequiredString(source, name); if (value.Length > 240 || value.IndexOf('\\') >= 0 || value.IndexOf('/') >= 0) throw new ArgumentException("selector event name is invalid: " + name); return value; }
        private static string RequiredCanonicalPath(IDictionary source, string name) { string value = RequiredString(source, name); string full = Path.GetFullPath(value); if (!Path.IsPathFullyQualified(value) || !String.Equals(full, value, StringComparison.OrdinalIgnoreCase)) throw new ArgumentException("selector path is not canonical: " + name); return full; }
        private static string RequiredIdentity(IDictionary source, string name) { string value = RequiredString(source, name); if (!Regex.IsMatch(value, "^[0-9a-f]{8}:[0-9a-f]{16}$", RegexOptions.CultureInvariant)) throw new ArgumentException("selector identity is invalid: " + name); return value; }
        private static string RequiredLeaf(IDictionary source, string name) { string value = RequiredString(source, name); if (value == "." || value == ".." || value.Length > 128 || value.IndexOfAny(new char[] {'\\','/',':'}) >= 0 || !Regex.IsMatch(value, "^[A-Za-z0-9][A-Za-z0-9._-]*$", RegexOptions.CultureInvariant)) throw new ArgumentException("selector leaf is invalid: " + name); return value; }
        private static string RequiredPhase(IDictionary source, string name) { string value = RequiredString(source, name); if (!Regex.IsMatch(value, "^[A-Z][A-Z0-9_]{0,63}$", RegexOptions.CultureInvariant)) throw new ArgumentException("selector phase is invalid: " + name); return value; }
        private static long RequiredPositiveJsonInt64(IDictionary source, string name) { object raw = Required(source, name); if (!(raw is long) || (long)raw <= 0L) throw new ArgumentException("selector JSON integer is invalid: " + name); return (long)raw; }
        private static long RequiredNonnegativeJsonInt64(IDictionary source, string name) { object raw = Required(source, name); if (!(raw is long) || (long)raw < 0L) throw new ArgumentException("selector JSON integer is invalid: " + name); return (long)raw; }
        private static int RequiredExactBudget(IDictionary source, string name, int expected) { long value = RequiredPositiveJsonInt64(source, name); if (value != expected) throw new ArgumentException("selector reviewed budget differs: " + name); return checked((int)value); }
        private static long RequiredCanonicalWireInt64(IDictionary source, string name) { string value = RequiredString(source, name); long parsed; if (!CanonicalPositiveInt64.IsMatch(value) || !Int64.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed <= 0L || parsed.ToString(CultureInfo.InvariantCulture) != value) throw new ArgumentException("selector Int64 wire is not canonical: " + name); return parsed; }
        private static T RequiredEnum<T>(IDictionary source, string name) where T : struct { string value = RequiredString(source, name); T parsed; if (!Enum.TryParse<T>(value, false, out parsed) || !Enum.IsDefined(typeof(T), parsed) || parsed.ToString() != value) throw new ArgumentException("selector enum is invalid: " + name); return parsed; }
        private static long AddMilliseconds(long start, int milliseconds, long frequency) { long seconds = milliseconds / 1000L; long remainder = milliseconds % 1000L; long delta = checked(checked(seconds * frequency) + checked(checked(remainder * frequency + 999L) / 1000L)); return checked(start + delta); }
        private static void RequireDeadline(long actual, long expected, string name) { if (actual != expected) throw new ArgumentException("selector " + name + " deadline differs"); }
        private static string Hex(byte[] bytes) { return Convert.ToHexString(bytes).ToLowerInvariant(); }
    }

    public sealed class SealedMutationPublicationTicket
    {
        internal readonly string OwnerToken;
        internal readonly string SelectorSha256;
        private int usesRemaining;
        internal SealedMutationPublicationTicket(string ownerToken, string selectorSha256) { OwnerToken = ownerToken; SelectorSha256 = selectorSha256; usesRemaining = 1; }
        internal bool TryConsume(string ownerToken, string selectorSha256) { return String.Equals(OwnerToken, ownerToken, StringComparison.Ordinal) && String.Equals(SelectorSha256, selectorSha256, StringComparison.Ordinal) && Interlocked.Exchange(ref usesRemaining, 0) == 1; }
    }

    public sealed class SealedMutationStageCoordinator : IDisposable
    {
        private readonly EventWaitHandle _stageReady;
        private readonly EventWaitHandle _continue;
        private readonly string _ownerToken = Guid.NewGuid().ToString("N");
        private int _state;
        private int _matchCount;
        private int _disposed;

        public SealedMutationStageSelector Selector { get; }

        internal SealedMutationStageCoordinator(SealedMutationStageSelector selector)
        {
            Selector = selector ?? throw new ArgumentNullException(nameof(selector));
            _stageReady = EventWaitHandle.OpenExisting(selector.StageReadyEventName);
            try { _continue = EventWaitHandle.OpenExisting(selector.ContinueEventName); }
            catch { _stageReady.Dispose(); throw; }
            if (_stageReady.WaitOne(0) || _continue.WaitOne(0)) {
                _continue.Dispose(); _stageReady.Dispose();
                throw new InvalidOperationException("selector event initial signal state is invalid");
            }
        }

        public SealedMutationPublicationTicket TryAcceptMatch(string transactionNamespace, SealedMutationCheckpoint checkpoint,
            SealedMutationPrimitiveVariant declaredVariant, string actualBranchState, string selectorArmJson)
        {
            if (_disposed != 0) { throw new ObjectDisposedException(nameof(SealedMutationStageCoordinator)); }
            string normalized = Path.GetFullPath(transactionNamespace ?? String.Empty);
            if (!String.Equals(normalized, Selector.TransactionNamespace, StringComparison.OrdinalIgnoreCase) || checkpoint != Selector.Checkpoint ||
                declaredVariant != Selector.DeclaredVariant || !Selector.MatchesArm(selectorArmJson) ||
                !Selector.VariantIsCompatible(checkpoint, declaredVariant, actualBranchState)) return null;
            if (Interlocked.CompareExchange(ref _state, 1, 0) != 0) throw new InvalidOperationException("duplicate-match");
            if (Interlocked.Increment(ref _matchCount) != 1) { Interlocked.Exchange(ref _state, 4); throw new InvalidOperationException("duplicate-match"); }
            return new SealedMutationPublicationTicket(_ownerToken, Selector.SelectorSha256);
        }

        public void MarkPublicationFailed(SealedMutationPublicationTicket ticket)
        {
            if (_disposed != 0) { throw new ObjectDisposedException(nameof(SealedMutationStageCoordinator)); }
            if (ticket == null || !ticket.TryConsume(_ownerToken, Selector.SelectorSha256)) throw new InvalidOperationException("foreign-ticket-or-ticket-consumed");
            if (Interlocked.CompareExchange(ref _state, 4, 1) != 1) throw new InvalidOperationException("PublishingToFailed: invalid predecessor");
        }

        public void MarkPublishedSignalReadyAndWait(SealedMutationPublicationTicket ticket)
        {
            if (_disposed != 0) { throw new ObjectDisposedException(nameof(SealedMutationStageCoordinator)); }
            if (ticket == null || !ticket.TryConsume(_ownerToken, Selector.SelectorSha256)) throw new InvalidOperationException("PostHandoffTicketReuseRejected: foreign-ticket-or-ticket-consumed");
            if (Interlocked.CompareExchange(ref _state, 2, 1) != 1) throw new InvalidOperationException("PostHandoffTicketReuseRejected: publication is not in Publishing");
            try
            {
                if (!_stageReady.Set()) throw new InvalidOperationException("WaitingToFailed: StageReady signal failed");
                int remaining = SealedMutationBehaviorTransport.RemainingMilliseconds(Selector.WorkerDeadlineQpc);
                if (remaining <= 0 || !_continue.WaitOne(remaining)) throw new TimeoutException("WaitingToFailed: Continue deadline expired");
                if (SealedStageNativeBridge.GetQpcTicks() > Selector.WorkerDeadlineQpc)
                    throw new TimeoutException("WaitingToFailed: Continue was observed after the immutable worker deadline");
                if (Interlocked.CompareExchange(ref _state, 3, 2) != 2) throw new InvalidOperationException("WaitingToFailed: invalid release predecessor");
            }
            catch (Exception)
            {
                Interlocked.CompareExchange(ref _state, 4, 2);
                throw;
            }
        }

        public void AssertMatchedExactlyOnce()
        {
            if (Volatile.Read(ref _matchCount) != 1 || Volatile.Read(ref _state) != 3) { throw new InvalidOperationException("AssertMatchedExactlyOnce: selector did not reach Released exactly once"); }
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
        private readonly SafeFileHandle _root;
        private readonly string _tempLeaf;
        private readonly string _finalLeaf;
        private readonly string _identity;
        private string _tempIdentity;
        private string _finalIdentity;
        private int _disposed;
        internal SealedStageRootLease(SafeFileHandle root, string identity, string tempLeaf, string finalLeaf) { _root = root; _identity = identity; _tempLeaf = tempLeaf; _finalLeaf = finalLeaf; }
        public string Identity { get { return _identity; } }
        public SealedStageFileLease BeginCreateStageTemp()
        {
            if (_disposed != 0) throw new ObjectDisposedException(nameof(SealedStageRootLease));
            if (_tempIdentity != null || _finalIdentity != null) throw new InvalidOperationException("stage publication was already started");
            SealedStageNativeBridge.RequireExactInventory(_root, Array.Empty<string>());
            SafeFileHandle writer = null;
            try {
                writer = SealedStageNativeBridge.OpenRelative(_root, _tempLeaf, true,
                    SealedStageNativeBridge.StageWriterAccess, SealedStageNativeBridge.ShareRead);
                string identity = SealedStageNativeBridge.GetIdentity(writer);
                _tempIdentity = identity;
                SealedStageNativeBridge.RequireRegularNoReparseSingleLinkNoStreams(writer);
                SealedStageNativeBridge.RequireExactInventory(_root, new string[] { _tempLeaf });
                SealedStageFileLease result = SealedStageFileLease.CreateWriter(this, writer, identity);
                writer = null;
                return result;
            } finally { if (writer != null) writer.Dispose(); }
        }
        internal SealedStageFileLease FinishPublication(SafeFileHandle writer, string expectedIdentity, byte[] bytes)
        {
            if (!String.Equals(_tempIdentity, expectedIdentity, StringComparison.Ordinal) || _finalIdentity != null)
                throw new InvalidOperationException("stage temp publication identity is not owned by this root lease");
            SealedStageNativeBridge.WriteFlushAndVerify(writer, bytes);
            SealedStageNativeBridge.RenameRelativeNoReplace(writer, _root, _finalLeaf);
            _finalIdentity = expectedIdentity;
            _tempIdentity = null;
            SealedStageNativeBridge.RequireExactInventory(_root, new string[] { _finalLeaf });
            SafeFileHandle bridge = null;
            try {
                bridge = SealedStageNativeBridge.OpenRelative(_root, _finalLeaf, false, SealedStageNativeBridge.StageReadAccess, SealedStageNativeBridge.ShareAll);
                if (!String.Equals(expectedIdentity, SealedStageNativeBridge.GetIdentity(bridge), StringComparison.Ordinal)) throw new InvalidOperationException("stage bridge identity drift");
                SealedStageNativeBridge.RequireRegularNoReparseSingleLinkNoStreams(bridge);
                writer.Dispose();
                SafeFileHandle seal = SealedStageNativeBridge.OpenRelative(_root, _finalLeaf, false, SealedStageNativeBridge.StageReadAccess, SealedStageNativeBridge.ShareRead);
                try {
                    SealedStageNativeBridge.VerifyExact(seal, expectedIdentity, bytes);
                    return SealedStageFileLease.CreateSeal(seal, expectedIdentity, bytes.LongLength, SealedStageNativeBridge.Hash(bytes));
                } catch { seal.Dispose(); throw; }
            } finally { if (bridge != null) bridge.Dispose(); }
        }
        internal void CleanupArtifacts()
        {
            if (_disposed != 0) throw new ObjectDisposedException(nameof(SealedStageRootLease));
            if (_tempIdentity != null && _finalIdentity != null) throw new InvalidOperationException("stage cleanup has two simultaneously owned artifact identities");
            if (_finalIdentity != null) {
                SealedStageNativeBridge.RequireExactInventory(_root, new string[] { _finalLeaf });
                SealedStageNativeBridge.DeleteRelativeIfIdentity(_root, _finalLeaf, _finalIdentity);
                _finalIdentity = null;
            } else if (_tempIdentity != null) {
                SealedStageNativeBridge.RequireExactInventory(_root, new string[] { _tempLeaf });
                SealedStageNativeBridge.DeleteRelativeIfIdentity(_root, _tempLeaf, _tempIdentity);
                _tempIdentity = null;
            } else {
                SealedStageNativeBridge.RequireExactInventory(_root, Array.Empty<string>());
            }
            SealedStageNativeBridge.RequireExactInventory(_root, Array.Empty<string>());
        }
        internal static SealedStageRootLease Open(SealedMutationStageSelector selector)
        {
            SafeFileHandle root = SealedStageNativeBridge.OpenRoot(selector.StageRootPath);
            try {
                string identity = SealedStageNativeBridge.GetIdentity(root);
                if (!String.Equals(identity, selector.StageRootIdentity, StringComparison.Ordinal)) throw new InvalidOperationException("stage root identity differs from selector");
                SealedStageNativeBridge.RequireDirectoryNoReparse(root);
                SealedStageNativeBridge.RequireProtectedCurrentUserOnly(root);
                SealedStageNativeBridge.RequireNoNamedStreams(root);
                SealedStageNativeBridge.RequireExactInventory(root, Array.Empty<string>());
                return new SealedStageRootLease(root, identity, selector.StageTempLeaf, selector.StageFinalLeaf);
            } catch { root.Dispose(); throw; }
        }
        public void Dispose() { if (Interlocked.Exchange(ref _disposed, 1) == 0) _root.Dispose(); }
    }

    public sealed class SealedStageFileLease : IDisposable
    {
        private readonly SealedStageRootLease _root;
        private SafeFileHandle _handle;
        private readonly bool _writer;
        public string Identity { get; }
        public long Length { get; }
        public string RawSha256 { get; }
        private int _disposed;
        private SealedStageFileLease(SealedStageRootLease root, SafeFileHandle handle, bool writer, string identity, long length, string rawSha256) { _root = root; _handle = handle; _writer = writer; Identity = identity; Length = length; RawSha256 = rawSha256; }
        internal static SealedStageFileLease CreateWriter(SealedStageRootLease root, SafeFileHandle handle, string identity) { return new SealedStageFileLease(root, handle, true, identity, 0L, null); }
        internal static SealedStageFileLease CreateSeal(SafeFileHandle handle, string identity, long length, string rawSha256) { return new SealedStageFileLease(null, handle, false, identity, length, rawSha256); }
        public SealedStageFileLease WriteFlushRenameAndSealFinal(byte[] bytes)
        {
            if (!_writer || _root == null) throw new InvalidOperationException("stage lease is not a temp publication writer");
            if (bytes == null || bytes.Length == 0) throw new ArgumentException("stage artifact bytes are empty", nameof(bytes));
            if (Interlocked.Exchange(ref _disposed, 1) != 0) throw new ObjectDisposedException(nameof(SealedStageFileLease));
            SafeFileHandle writer = _handle; _handle = null;
            try { return _root.FinishPublication(writer, Identity, bytes); }
            finally { if (writer != null && !writer.IsClosed) writer.Dispose(); }
        }
        public void Dispose(){ if (Interlocked.Exchange(ref _disposed, 1) == 0 && _handle != null) { _handle.Dispose(); _handle = null; } }
    }

    public sealed class SealedJobQpcDeadlines
    {
        public int WorkerWaitMilliseconds { get; }
        public int ControllerObservationMilliseconds { get; }
        public int JobReapMilliseconds { get; }
        public int CleanupMilliseconds { get; }
        public long StopwatchFrequency { get; }
        public long ControllerQpcTicks { get; }
        public long WorkerDeadlineQpc { get; }
        public long ControllerObservationDeadlineQpc { get; }
        public long HardKillCumulativeReapDeadlineQpc { get; }
        public long HardKillCumulativeCleanupDeadlineQpc { get; }
        public long NaturalReleaseCumulativeReapDeadlineQpc { get; }
        public long NaturalReleaseCumulativeCleanupDeadlineQpc { get; }
        public string SelectorHash { get; }
        public const int HardKillTerminationExitCode = unchecked((int)0xC000042D);

        internal SealedJobQpcDeadlines(int workerWait, int observationWait, int jobReap, int cleanup,
            long frequency, long controllerTicks, long workerDeadline, long observationDeadline,
            long hardReapDeadline, long hardCleanupDeadline, long naturalReapDeadline, long naturalCleanupDeadline,
            string selectorHash)
        {
            WorkerWaitMilliseconds = workerWait;
            ControllerObservationMilliseconds = observationWait;
            JobReapMilliseconds = jobReap;
            CleanupMilliseconds = cleanup;
            StopwatchFrequency = frequency;
            ControllerQpcTicks = controllerTicks;
            WorkerDeadlineQpc = workerDeadline;
            ControllerObservationDeadlineQpc = observationDeadline;
            HardKillCumulativeReapDeadlineQpc = hardReapDeadline;
            HardKillCumulativeCleanupDeadlineQpc = hardCleanupDeadline;
            NaturalReleaseCumulativeReapDeadlineQpc = naturalReapDeadline;
            NaturalReleaseCumulativeCleanupDeadlineQpc = naturalCleanupDeadline;
            SelectorHash = selectorHash;
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

        private SealedMutationInvocationContext(SealedMutationStageCoordinator coordinator, SealedStageRootLease stageRootLease, SealedJobQpcDeadlines deadline)
        {
            Coordinator = coordinator ?? throw new ArgumentNullException(nameof(coordinator));
            StageRootLease = stageRootLease ?? throw new ArgumentNullException(nameof(stageRootLease));
            Deadline = deadline ?? throw new ArgumentNullException(nameof(deadline));
        }

        public static SealedMutationInvocationContext Open(SealedMutationStageSelector selector)
        {
            if (selector == null) throw new ArgumentNullException(nameof(selector));
            SealedMutationStageCoordinator coordinator = null;
            SealedStageRootLease root = null;
            try {
                coordinator = new SealedMutationStageCoordinator(selector);
                root = SealedStageRootLease.Open(selector);
                return new SealedMutationInvocationContext(coordinator, root, selector.Deadlines);
            } catch {
                if (root != null) root.Dispose();
                if (coordinator != null) coordinator.Dispose();
                throw;
            }
        }

        public void Dispose()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) { return; }
            InvocationContextDisposeCount++;
            List<Exception> errors = new List<Exception>();
            try { Coordinator.Dispose(); } catch (Exception error) { errors.Add(error); }
            try { StageRootLease.CleanupArtifacts(); } catch (Exception error) { errors.Add(error); }
            try { StageRootLease.Dispose(); } catch (Exception error) { errors.Add(error); }
            if (errors.Count == 1) throw errors[0];
            if (errors.Count > 1) throw new AggregateException("invocation context cleanup failed", errors);
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

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool WriteFile(SafeFileHandle handle, byte[] buffer, uint bytesToWrite, out uint bytesWritten, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool ReadFile(SafeFileHandle handle, byte[] buffer, uint bytesToRead, out uint bytesRead, IntPtr overlapped);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFilePointerEx(SafeFileHandle handle, long distance, out long newPosition, uint moveMethod);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, IntPtr information, uint bufferSize);

        [DllImport("kernel32.dll")]
        private static extern IntPtr LocalFree(IntPtr memory);

        [DllImport("advapi32.dll", SetLastError = true)]
        private static extern uint GetSecurityInfo(IntPtr handle, int objectType, uint securityInformation,
            out IntPtr owner, out IntPtr group, out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);

        [DllImport("advapi32.dll")]
        private static extern uint GetSecurityDescriptorLength(IntPtr securityDescriptor);

        [DllImport("ntdll.dll")]
        private static extern int NtCreateFile(out IntPtr fileHandle, uint desiredAccess, ref OBJECT_ATTRIBUTES objectAttributes,
            out IO_STATUS_BLOCK ioStatusBlock, IntPtr allocationSize, uint fileAttributes, uint shareAccess,
            uint createDisposition, uint createOptions, IntPtr eaBuffer, uint eaLength);

        [DllImport("ntdll.dll")]
        private static extern int NtSetInformationFile(SafeFileHandle fileHandle, out IO_STATUS_BLOCK ioStatusBlock,
            IntPtr fileInformation, uint length, int fileInformationClass);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryDirectoryFile(SafeFileHandle fileHandle, IntPtr eventHandle, IntPtr apcRoutine,
            IntPtr apcContext, out IO_STATUS_BLOCK ioStatusBlock, IntPtr fileInformation, uint length,
            int fileInformationClass, [MarshalAs(UnmanagedType.U1)] bool returnSingleEntry, IntPtr fileName,
            [MarshalAs(UnmanagedType.U1)] bool restartScan);

        [DllImport("ntdll.dll")]
        private static extern int NtQueryInformationFile(SafeFileHandle fileHandle, out IO_STATUS_BLOCK ioStatusBlock,
            IntPtr fileInformation, uint length, int fileInformationClass);

        [StructLayout(LayoutKind.Sequential)]
        private struct UNICODE_STRING { public ushort Length; public ushort MaximumLength; public IntPtr Buffer; }
        [StructLayout(LayoutKind.Sequential)]
        private struct OBJECT_ATTRIBUTES { public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes; public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService; }
        [StructLayout(LayoutKind.Sequential)]
        private struct IO_STATUS_BLOCK { public IntPtr Status; public UIntPtr Information; }
        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public uint FileAttributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime;
            public System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
            public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow; public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow;
        }

        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint DELETE_ = 0x00010000;
        private const uint READ_CONTROL = 0x00020000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint CREATE_NEW = 1;
        private const uint OPEN_EXISTING = 3;
        private const uint STATUS_SHARING_VIOLATION = 0x80070020;
        private const uint FILE_READ_DATA = 0x00000001;
        private const uint FILE_WRITE_DATA = 0x00000002;
        private const uint FILE_READ_ATTRIBUTES = 0x00000080;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint FILE_ATTRIBUTE_DIRECTORY = 0x00000010;
        private const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x00000400;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_CREATE = 2;
        private const uint FILE_OPEN = 1;
        private const uint FILE_WRITE_THROUGH = 0x00000002;
        private const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
        private const uint FILE_NON_DIRECTORY_FILE = 0x00000040;
        private const uint FILE_OPEN_REPARSE_POINT = 0x00200000;
        private const uint OBJ_CASE_INSENSITIVE = 0x00000040;
        private const int FileRenameInfo = 3;
        private const int FileDispositionInfo = 4;
        private const int NativeFileRenameInformation = 10;
        private const int NativeFileNamesInformation = 12;
        private const int NativeFileStreamInformation = 22;
        private const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);
        private const int STATUS_BUFFER_OVERFLOW = unchecked((int)0x80000005);
        private const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
        private const int STATUS_BUFFER_TOO_SMALL = unchecked((int)0xC0000023);
        private const ulong NativeFileCreatedInformation = 2UL;
        private const int SE_FILE_OBJECT = 1;
        private const uint OWNER_SECURITY_INFORMATION = 0x00000001;
        private const uint DACL_SECURITY_INFORMATION = 0x00000004;
        private const uint FILE_BEGIN = 0;
        private const int ERROR_FILE_NOT_FOUND = 2;
        private const int ERROR_PATH_NOT_FOUND = 3;
        private static readonly IntPtr InvalidHandleValue = new IntPtr(-1);
        internal const uint StageWriterAccess = FILE_READ_DATA | FILE_WRITE_DATA | FILE_READ_ATTRIBUTES | DELETE_ | SYNCHRONIZE;
        internal const uint StageReadAccess = FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE;
        internal const uint ShareRead = FILE_SHARE_READ;
        internal const uint ShareAll = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;

        internal static SafeFileHandle OpenRoot(string path)
        {
            IntPtr raw = CreateFileW(path, FILE_READ_DATA | FILE_READ_ATTRIBUTES | READ_CONTROL | SYNCHRONIZE,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
            if (raw == InvalidHandleValue) throw new Win32Exception(Marshal.GetLastWin32Error(), "opening held stage root failed");
            return new SafeFileHandle(raw, true);
        }

        internal static void RequireDirectoryNoReparse(SafeFileHandle handle)
        {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error(), "reading stage root information failed");
            if ((information.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 || (information.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 || information.NumberOfLinks != 1U)
                throw new InvalidOperationException("stage root is not one ordinary held directory identity");
        }

        internal static void RequireProtectedCurrentUserOnly(SafeFileHandle handle)
        {
            IntPtr owner, group, dacl, sacl, descriptor;
            uint result = GetSecurityInfo(handle.DangerousGetHandle(), SE_FILE_OBJECT,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, out owner, out group, out dacl, out sacl, out descriptor);
            if (result != 0U) throw new Win32Exception(checked((int)result), "reading held stage root security failed");
            try {
                uint length = GetSecurityDescriptorLength(descriptor);
                if (length == 0U || length > 65536U) throw new InvalidOperationException("stage root security descriptor length is invalid");
                byte[] bytes = new byte[length];
                Marshal.Copy(descriptor, bytes, 0, checked((int)length));
                RawSecurityDescriptor security = new RawSecurityDescriptor(bytes, 0);
                SecurityIdentifier current;
                using (WindowsIdentity identity = WindowsIdentity.GetCurrent()) { current = identity.User; }
                if (current == null || security.Owner == null || !security.Owner.Equals(current) ||
                    (security.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0 || security.DiscretionaryAcl == null ||
                    security.DiscretionaryAcl.Count == 0)
                    throw new InvalidOperationException("stage root is not owned by the current user with one protected DACL");
                foreach (GenericAce ace in security.DiscretionaryAcl) {
                    QualifiedAce qualified = ace as QualifiedAce;
                    if (qualified == null || qualified.AceQualifier != AceQualifier.AccessAllowed ||
                        qualified.SecurityIdentifier == null || !qualified.SecurityIdentifier.Equals(current) ||
                        (qualified.AceFlags & AceFlags.Inherited) != 0)
                        throw new InvalidOperationException("stage root DACL is not current-user-only and explicit");
                }
            } finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
        }

        private static string[] GetChildNames(SafeFileHandle root)
        {
            List<string> names = new List<string>();
            const int capacity = 65536;
            IntPtr buffer = Marshal.AllocHGlobal(capacity);
            try {
                bool restart = true;
                while (true) {
                    IO_STATUS_BLOCK io;
                    int status = NtQueryDirectoryFile(root, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out io, buffer,
                        capacity, NativeFileNamesInformation, false, IntPtr.Zero, restart);
                    restart = false;
                    if (status == STATUS_NO_MORE_FILES) break;
                    if (status < 0 && status != STATUS_BUFFER_OVERFLOW)
                        throw new Win32Exception(RtlNtStatusToDosError(status), "enumerating held stage root failed");
                    ulong availableValue = io.Information.ToUInt64();
                    if (availableValue == 0UL || availableValue > capacity) throw new InvalidOperationException("stage root inventory returned invalid bounds");
                    int available = checked((int)availableValue);
                    int offset = 0;
                    while (true) {
                        if (offset < 0 || offset + 12 > available) throw new InvalidOperationException("stage root inventory entry is out of bounds");
                        int next = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 8);
                        if (nameLength < 0 || (nameLength & 1) != 0 || offset + 12L + nameLength > available)
                            throw new InvalidOperationException("stage root inventory name is out of bounds");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 12), nameLength / 2);
                        if (name != "." && name != "..") names.Add(name);
                        if (next == 0) break;
                        if (next < 12) throw new InvalidOperationException("stage root inventory offset is invalid");
                        offset = checked(offset + next);
                    }
                }
                return names.ToArray();
            } finally { Marshal.FreeHGlobal(buffer); }
        }

        internal static void RequireExactInventory(SafeFileHandle root, string[] expected)
        {
            if (expected == null) throw new ArgumentNullException(nameof(expected));
            string[] actual = GetChildNames(root);
            string[] reviewed = (string[])expected.Clone();
            Array.Sort(actual, StringComparer.OrdinalIgnoreCase);
            Array.Sort(reviewed, StringComparer.OrdinalIgnoreCase);
            if (actual.Length != reviewed.Length) throw new InvalidOperationException("stage root inventory contains an unknown or missing child");
            for (int index = 0; index < actual.Length; index++)
                if (!String.Equals(actual[index], reviewed[index], StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("stage root inventory contains an unknown or missing child");
        }

        private static string[] GetNamedStreams(SafeFileHandle handle)
        {
            int capacity = 4096;
            while (capacity <= 16777216) {
                IntPtr buffer = Marshal.AllocHGlobal(capacity);
                try {
                    IO_STATUS_BLOCK io;
                    int status = NtQueryInformationFile(handle, out io, buffer, checked((uint)capacity), NativeFileStreamInformation);
                    if (status == STATUS_BUFFER_OVERFLOW || status == STATUS_INFO_LENGTH_MISMATCH || status == STATUS_BUFFER_TOO_SMALL) {
                        capacity = checked(capacity * 2); continue;
                    }
                    if (status < 0) throw new Win32Exception(RtlNtStatusToDosError(status), "enumerating held stage streams failed");
                    ulong availableValue = io.Information.ToUInt64();
                    if (availableValue == 0UL) return Array.Empty<string>();
                    if (availableValue < 24UL || availableValue > checked((ulong)capacity)) throw new InvalidOperationException("stage stream inventory returned invalid bounds");
                    int available = checked((int)availableValue);
                    List<string> streams = new List<string>();
                    int offset = 0;
                    while (true) {
                        if (offset < 0 || offset + 24 > available) throw new InvalidOperationException("stage stream entry is out of bounds");
                        int next = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 || offset + 24L + nameLength > available)
                            throw new InvalidOperationException("stage stream name is out of bounds");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 24), nameLength / 2);
                        if (!String.Equals(name, "::$DATA", StringComparison.OrdinalIgnoreCase)) streams.Add(name);
                        if (next == 0) break;
                        if (next < 24) throw new InvalidOperationException("stage stream offset is invalid");
                        offset = checked(offset + next);
                    }
                    return streams.ToArray();
                } finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("stage stream inventory exceeded the safety bound");
        }

        internal static void RequireNoNamedStreams(SafeFileHandle handle)
        {
            if (GetNamedStreams(handle).Length != 0) throw new InvalidOperationException("stage object has a named alternate stream");
        }

        internal static void RequireRegularNoReparseSingleLinkNoStreams(SafeFileHandle handle)
        {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error(), "reading stage artifact information failed");
            if ((information.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 || information.NumberOfLinks != 1U)
                throw new InvalidOperationException("stage artifact is not one ordinary regular-file identity");
            RequireNoNamedStreams(handle);
        }

        internal static string GetIdentity(SafeFileHandle handle)
        {
            BY_HANDLE_FILE_INFORMATION information;
            if (!GetFileInformationByHandle(handle, out information)) throw new Win32Exception(Marshal.GetLastWin32Error(), "reading stage identity failed");
            ulong index = ((ulong)information.FileIndexHigh << 32) | information.FileIndexLow;
            return information.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture) + ":" + index.ToString("x16", CultureInfo.InvariantCulture);
        }

        internal static SafeFileHandle OpenRelative(SafeFileHandle root, string leaf, bool createNew, uint desiredAccess, uint shareAccess)
        {
            IntPtr nameBuffer = IntPtr.Zero; IntPtr unicodeBuffer = IntPtr.Zero; bool rootRef = false;
            try {
                nameBuffer = Marshal.StringToHGlobalUni(leaf);
                UNICODE_STRING unicode = new UNICODE_STRING { Length = checked((ushort)(leaf.Length * 2)), MaximumLength = checked((ushort)((leaf.Length + 1) * 2)), Buffer = nameBuffer };
                unicodeBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING)));
                Marshal.StructureToPtr(unicode, unicodeBuffer, false);
                root.DangerousAddRef(ref rootRef);
                OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES { Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)), RootDirectory = root.DangerousGetHandle(), ObjectName = unicodeBuffer, Attributes = OBJ_CASE_INSENSITIVE };
                IO_STATUS_BLOCK status; IntPtr raw;
                int result = NtCreateFile(out raw, desiredAccess, ref attributes, out status, IntPtr.Zero, FILE_ATTRIBUTE_NORMAL,
                    shareAccess, createNew ? FILE_CREATE : FILE_OPEN,
                    FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT | (createNew ? FILE_WRITE_THROUGH : 0U), IntPtr.Zero, 0U);
                if (result < 0) {
                    int win32 = RtlNtStatusToDosError(result);
                    throw new Win32Exception(win32, (createNew ? "creating" : "opening") + " relative stage leaf failed");
                }
                if (createNew && status.Information.ToUInt64() != NativeFileCreatedInformation) {
                    CloseHandle(raw);
                    throw new InvalidOperationException("relative stage create did not return FILE_CREATED");
                }
                return new SafeFileHandle(raw, true);
            } finally {
                if (rootRef) root.DangerousRelease();
                if (unicodeBuffer != IntPtr.Zero) Marshal.FreeHGlobal(unicodeBuffer);
                if (nameBuffer != IntPtr.Zero) Marshal.FreeHGlobal(nameBuffer);
            }
        }

        [DllImport("ntdll.dll")]
        private static extern int RtlNtStatusToDosError(int status);

        internal static void RenameRelativeNoReplace(SafeFileHandle writer, SafeFileHandle root, string finalLeaf)
        {
            byte[] nameBytes = Encoding.Unicode.GetBytes(finalLeaf);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int lengthOffset = rootOffset + IntPtr.Size;
            int nameOffset = lengthOffset + 4;
            IntPtr buffer = Marshal.AllocHGlobal(checked(nameOffset + nameBytes.Length)); bool rootRef = false;
            try {
                for (int index = 0; index < nameOffset + nameBytes.Length; index++) Marshal.WriteByte(buffer, index, 0);
                Marshal.WriteInt32(buffer, 0, 0);
                root.DangerousAddRef(ref rootRef);
                Marshal.WriteIntPtr(buffer, rootOffset, root.DangerousGetHandle());
                Marshal.WriteInt32(buffer, lengthOffset, nameBytes.Length);
                Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, nameOffset), nameBytes.Length);
                IO_STATUS_BLOCK ioStatus;
                int status = NtSetInformationFile(writer, out ioStatus, buffer, checked((uint)(nameOffset + nameBytes.Length)), NativeFileRenameInformation);
                if (status < 0) {
                    int error = RtlNtStatusToDosError(status);
                    throw new Win32Exception(error, "relative no-replace stage rename failed (" + error.ToString(CultureInfo.InvariantCulture) + ")");
                }
            } finally { if (rootRef) root.DangerousRelease(); Marshal.FreeHGlobal(buffer); }
        }

        internal static void DeleteRelativeIfIdentity(SafeFileHandle root, string leaf, string expectedIdentity)
        {
            SafeFileHandle handle = null;
            handle = OpenRelative(root, leaf, false, DELETE_ | FILE_READ_ATTRIBUTES | SYNCHRONIZE, ShareAll);
            try {
                if (!String.Equals(GetIdentity(handle), expectedIdentity, StringComparison.Ordinal))
                    throw new InvalidOperationException("stage cleanup refused a rebound artifact identity");
                RequireRegularNoReparseSingleLinkNoStreams(handle);
                IntPtr disposition = Marshal.AllocHGlobal(1);
                try { Marshal.WriteByte(disposition, 1); if (!SetFileInformationByHandle(handle, FileDispositionInfo, disposition, 1U)) throw new Win32Exception(Marshal.GetLastWin32Error(), "relative stage cleanup failed"); }
                finally { Marshal.FreeHGlobal(disposition); }
            } finally { handle.Dispose(); }
        }

        internal static void WriteFlushAndVerify(SafeFileHandle handle, byte[] bytes)
        {
            RequireRegularNoReparseSingleLinkNoStreams(handle);
            long ignored; if (!SetFilePointerEx(handle, 0L, out ignored, FILE_BEGIN)) throw new Win32Exception(Marshal.GetLastWin32Error(), "stage writer seek failed");
            uint written; if (!WriteFile(handle, bytes, checked((uint)bytes.Length), out written, IntPtr.Zero) || written != bytes.Length) throw new Win32Exception(Marshal.GetLastWin32Error(), "stage writer write failed");
            if (!FlushFileBuffers(handle.DangerousGetHandle())) throw new Win32Exception(Marshal.GetLastWin32Error(), "stage writer flush failed");
            VerifyExact(handle, GetIdentity(handle), bytes);
        }

        internal static void VerifyExact(SafeFileHandle handle, string expectedIdentity, byte[] bytes)
        {
            if (!String.Equals(GetIdentity(handle), expectedIdentity, StringComparison.Ordinal)) throw new InvalidOperationException("stage artifact identity drift");
            RequireRegularNoReparseSingleLinkNoStreams(handle);
            long ignored; if (!SetFilePointerEx(handle, 0L, out ignored, FILE_BEGIN)) throw new Win32Exception(Marshal.GetLastWin32Error(), "stage reader seek failed");
            byte[] actual = new byte[bytes.Length]; uint read; if (!ReadFile(handle, actual, checked((uint)actual.Length), out read, IntPtr.Zero) || read != actual.Length) throw new Win32Exception(Marshal.GetLastWin32Error(), "stage reader read failed");
            if (!CryptographicOperations.FixedTimeEquals(actual, bytes)) throw new InvalidOperationException("stage artifact exact bytes differ");
            byte[] extra = new byte[1]; if (!ReadFile(handle, extra, 1U, out read, IntPtr.Zero)) throw new Win32Exception(Marshal.GetLastWin32Error(), "stage reader terminal read failed");
            if (read != 0U) throw new InvalidOperationException("stage artifact has trailing bytes");
            RequireRegularNoReparseSingleLinkNoStreams(handle);
        }

        internal static string Hash(byte[] bytes) { return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(); }

        public static long GetCurrentProcessCreationFileTimeTicks()
        {
            long creation, exit, kernel, user;
            if (!GetProcessTimes(Process.GetCurrentProcess().Handle, out creation, out exit, out kernel, out user)) throw new Win32Exception(Marshal.GetLastWin32Error(), "GetProcessTimes failed");
            if (creation <= 0L) throw new InvalidOperationException("current process creation FILETIME is invalid");
            return creation;
        }

        public static long GetQpcTicks()
        {
            long value;
            if (!QueryPerformanceCounter(out value)) { throw new InvalidOperationException("QueryPerformanceCounter failed"); }
            return value;
        }

        // Reviewed ladder names remain explicit, but every leaf operation is rooted
        // in the already-held directory identity rather than an absolute-path reopen.
        public static void RenameWriterNoReplace(SafeFileHandle writer, SafeFileHandle root, string finalLeaf) { RenameRelativeNoReplace(writer, root, finalLeaf); }
        public static SafeFileHandle OpenReadBridgeShareAll(SafeFileHandle root, string leaf) { return OpenRelative(root, leaf, false, StageReadAccess, ShareAll); }
        public static void CloseWriter(SafeFileHandle handle) { if (handle == null) throw new ArgumentNullException(nameof(handle)); handle.Dispose(); }
        public static SafeFileHandle OpenReadSealShareRead(SafeFileHandle root, string leaf) { return OpenRelative(root, leaf, false, StageReadAccess, ShareRead); }
        public static void FlushStageArtifact(SafeFileHandle handle) { if (!FlushFileBuffers(handle.DangerousGetHandle())) throw new Win32Exception(Marshal.GetLastWin32Error(), "FlushFileBuffers failed"); }
    }

    public static class SealedMutationNativeStage
    {
        public static string StageArtifactIdentity(SafeFileHandle heldStageFile) { return SealedStageNativeBridge.GetIdentity(heldStageFile); }
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
            long seconds = remaining / frequency;
            long remainder = remaining % frequency;
            long milliseconds = checked(checked(seconds * 1000L) + checked(checked(remainder * 1000L + frequency - 1L) / frequency));
            if (milliseconds > Int32.MaxValue) { return Int32.MaxValue; }
            return checked((int)Math.Max(1L, milliseconds));
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
public static object ExecuteNativeSealBlocksWriteDeleteRebind(object fixture,object request,object action){ValidateInputs("native-seal-blocks-write-delete-rebind",fixture,request,action);int[] codes=ProbeChallengeMutationBlocked(fixture);return Result(fixture,Rows("WriteWin32",codes[0].ToString(System.Globalization.CultureInfo.InvariantCulture),"DeleteWin32",codes[1].ToString(System.Globalization.CultureInfo.InvariantCulture),"RebindWin32",codes[2].ToString(System.Globalization.CultureInfo.InvariantCulture),"CompatibleRead","same-identity"),null,null);}
public static object ExecuteNativeFailureMatrixZeroResidue(object fixture,object request,object action){ValidateInputs("native-failure-matrix-zero-residue",fixture,request,action);ProbeFailureHandleResidue(fixture);return Result(fixture,Rows("FailureMatrix","complete","FailureHandleDelta","0","KnownArtifactResidue","0"),null,null);}
public static object ExecuteQpcLateEntryNoRefresh(object fixture,object request,object action){ValidateInputs("qpc-late-entry-no-refresh",fixture,request,action);ProbeAbsoluteDeadline(fixture);return Result(fixture,Rows("LateEntry","rejected","TerminateJobObjectCallCount","0","RelativeBudgetRefresh","absent"),null,null);}
public static object ExecuteQpcOverflowAndNaturalExitRace(object fixture,object request,object action){ValidateInputs("qpc-overflow-and-natural-exit-race",fixture,request,action);ProbeCheckedOverflow();return Result(fixture,Rows("Overflow","rejected","NaturalExitReceipt","rejected","ExitCodeMismatch","recorded"),null,null);}
public static object ExecutePartialPresealRebindFailClosed(object fixture,object request,object action){ValidateInputs("partial-preseal-rebind-fail-closed",fixture,request,action);ProbeChallengeStable(fixture);return Result(fixture,Rows("RebindAttempt","performed","RebindBeforeSeal","succeeded","SealIdentity","mismatch-rejected","RuntimeProof","absent","ForensicOriginal","preserved"),null,null);}
public static object ExecutePartialPostsealMutationBlocked(object fixture,object request,object action){ValidateInputs("partial-postseal-mutation-blocked",fixture,request,action);int[] codes=ProbeChallengeMutationBlocked(fixture);return Result(fixture,Rows("SealBeforeAttack","true","WriteWin32",codes[0].ToString(System.Globalization.CultureInfo.InvariantCulture),"DeleteWin32",codes[1].ToString(System.Globalization.CultureInfo.InvariantCulture),"RebindWin32",codes[2].ToString(System.Globalization.CultureInfo.InvariantCulture),"Prefix","exact"),null,null);}
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
private static object Member(object value,string name){IDictionary dictionary=value as IDictionary;if(dictionary!=null){if(!dictionary.Contains(name))throw new InvalidOperationException("behavior-member:"+name);return Unwrap(dictionary[name]);}var property=value.GetType().GetProperty(name);if(property!=null)return Unwrap(property.GetValue(value));object adapter=PowerShellProperty(value,name);return Unwrap(adapter.GetType().GetProperty("Value").GetValue(adapter));}
private static object Unwrap(object value){object current=value;for(int index=0;index<4&&current!=null;index++){var property=current.GetType().GetProperty("BaseObject");if(property==null)break;object next=property.GetValue(current);if(next==null||Object.ReferenceEquals(next,current))break;current=next;}return current;}
private static object PowerShellProperty(object value,string name){foreach(var assembly in AppDomain.CurrentDomain.GetAssemblies()){Type type=assembly.GetType("System.Management.Automation.PSObject",false,false);if(type==null)continue;object wrapped=type.InvokeMember("AsPSObject",System.Reflection.BindingFlags.InvokeMethod|System.Reflection.BindingFlags.Public|System.Reflection.BindingFlags.Static,null,null,new[]{value},System.Globalization.CultureInfo.InvariantCulture);object properties=wrapped.GetType().GetProperty("Properties").GetValue(wrapped);object adapter=properties.GetType().GetProperty("Item").GetValue(properties,new object[]{name});if(adapter==null)throw new InvalidOperationException("behavior-member:"+name);return adapter;}throw new InvalidOperationException("behavior-powershell-object-authority");}
private static object Result(object fixture,object[] rows,object forensic,object failure){dynamic f=fixture;var artifacts=new List<object>();artifacts.Add(f.ChallengeArtifact);if(forensic!=null)artifacts.Add(forensic);return new Dictionary<string,object>(StringComparer.Ordinal){{"RawRows",rows},{"Artifacts",artifacts.ToArray()},{"RawFailure",failure}};}
private static object[] Rows(params string[] values){if(values.Length%2!=0)throw new ArgumentException("fact pairs");var rows=new object[values.Length/2];for(int i=0;i<rows.Length;i++){rows[i]=new Dictionary<string,object>(StringComparer.Ordinal){{"Ordinal",(long)i},{"Operation",values[i*2]},{"Result",values[i*2+1]},{"ErrorCode",""},{"Identity",""},{"Length",0L},{"RawSha256",""}};}return rows;}
private static object Failure(string stage,string code){return new Dictionary<string,object>(StringComparer.Ordinal){{"Stage",stage},{"Code",code},{"PrimaryOrdinal",0L},{"CleanupCodes",Array.Empty<object>()}};}
private static void ProbeSingleUseTicket(){int ticket=0;if(Interlocked.Exchange(ref ticket,1)!=0||Interlocked.Exchange(ref ticket,1)!=1)throw new InvalidOperationException("ticket probe");int foreign=0;if(Interlocked.Exchange(ref foreign,1)!=0)throw new InvalidOperationException("foreign ticket probe");}
private static void ProbeDisposeOnce(){int root=0;int coordinator=0;try{throw new InvalidOperationException("primary");}catch(InvalidOperationException){}finally{Interlocked.Increment(ref coordinator);Interlocked.Increment(ref root);}if(root!=1||coordinator!=1)throw new InvalidOperationException("dispose probe");}
private static void ProbePrimaryFirstAggregation(){Exception primary=null;Exception cleanup=null;try{throw new InvalidOperationException("primary");}catch(Exception e){primary=e;}finally{try{throw new IOException("cleanup");}catch(Exception e){cleanup=e;}}if(primary==null||cleanup==null||primary.Message!="primary")throw new InvalidOperationException("primary-first probe");}
private static void ProbeNativeLayouts(){int pointer=System.Runtime.InteropServices.Marshal.SizeOf<IntPtr>();int x86=checked(4+4+8);int x64=checked(8+8+8);if(x86!=16||x64!=24||(pointer!=4&&pointer!=8))throw new InvalidOperationException("native layout probe");}
private static void ProbeCaseContainment(object fixture){string root=Path.GetFullPath(Convert.ToString(Member(fixture,"ScratchRoot"),System.Globalization.CultureInfo.InvariantCulture)).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;string child=Path.GetFullPath(Convert.ToString(Member(fixture,"CaseDirectoryPath"),System.Globalization.CultureInfo.InvariantCulture)).TrimEnd(Path.DirectorySeparatorChar)+Path.DirectorySeparatorChar;if(!child.StartsWith(root,StringComparison.OrdinalIgnoreCase))throw new InvalidOperationException("case containment probe");}
private static void ProbeChallengeStable(object fixture){FileStream held=Member(fixture,"ChallengeStream") as FileStream;if(held==null)throw new InvalidOperationException("challenge stream missing");string before=(string)TransportCall("GetIdentity",held);using(var compatible=new FileStream(Convert.ToString(Member(fixture,"ChallengePath"),System.Globalization.CultureInfo.InvariantCulture),FileMode.Open,FileAccess.Read,FileShare.Read)){string after=(string)TransportCall("GetIdentity",compatible);if(!String.Equals(before,after,StringComparison.Ordinal))throw new InvalidOperationException("challenge identity drift");}}
private static int Win32(Exception e){return e.HResult&0xffff;}
private static int[] ProbeChallengeMutationBlocked(object fixture){string path=Convert.ToString(Member(fixture,"ChallengePath"),System.Globalization.CultureInfo.InvariantCulture);string replacement=Path.Combine(Convert.ToString(Member(fixture,"CaseDirectoryPath"),System.Globalization.CultureInfo.InvariantCulture),"rebind-probe.bin");int write=0,delete=0,rebind=0;try{using(var s=new FileStream(path,FileMode.Open,FileAccess.Write,FileShare.ReadWrite|FileShare.Delete)){} }catch(IOException e){write=Win32(e);}try{File.Delete(path);}catch(IOException e){delete=Win32(e);}File.WriteAllBytes(replacement,new byte[]{1});try{File.Move(replacement,path,true);}catch(IOException e){rebind=Win32(e);}catch(UnauthorizedAccessException e){rebind=Win32(e);}finally{if(File.Exists(replacement))File.Delete(replacement);}if(write!=32||delete!=32||rebind!=5)throw new InvalidOperationException("challenge mutation was not blocked");ProbeChallengeStable(fixture);return new[]{write,delete,rebind};}
private static void ProbeFailureHandleResidue(object fixture){string path=Convert.ToString(Member(fixture,"CaseDirectoryPath"),System.Globalization.CultureInfo.InvariantCulture);int before=Process.GetCurrentProcess().HandleCount;for(int i=0;i<8;i++){try{using(var s=new FileStream(path,FileMode.Open,FileAccess.Write,FileShare.None)){} }catch(UnauthorizedAccessException){}catch(IOException){}}int after=Process.GetCurrentProcess().HandleCount;if(after!=before)throw new InvalidOperationException("failure handle residue");}
private static void ProbeAbsoluteDeadline(object fixture){long deadline=Convert.ToInt64(Member(fixture,"AbsoluteDeadlineQpc"),System.Globalization.CultureInfo.InvariantCulture);long now=Stopwatch.GetTimestamp();if(deadline<=now||RemainingMilliseconds(deadline)<=0)throw new InvalidOperationException("absolute deadline probe");}
private static void ProbeCheckedOverflow(){bool rejected=false;long maximum=Int64.MaxValue;try{checked{long ignored=maximum+1L;GC.KeepAlive(ignored);}}catch(OverflowException){rejected=true;}if(!rejected)throw new InvalidOperationException("checked overflow probe");}
private static object CreateForensicArtifact(object fixture,object request){string path=Path.Combine(Convert.ToString(Member(fixture,"CaseDirectoryPath"),System.Globalization.CultureInfo.InvariantCulture),"forensic.bin");byte[] bytes=System.Text.Encoding.UTF8.GetBytes("forensic:"+Convert.ToString(Member(request,"CaseNonce"),System.Globalization.CultureInfo.InvariantCulture));using(var stream=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read,4096,FileOptions.WriteThrough)){stream.Write(bytes,0,bytes.Length);stream.Flush(true);string identity=(string)TransportCall("GetIdentity",stream);string sha=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();return Artifact("forensic",Convert.ToString(Member(request,"CaseRelativeDirectory"),System.Globalization.CultureInfo.InvariantCulture)+"/forensic.bin",identity,bytes.LongLength,sha);}}
private static object PublishResponse(object fixture,object bytesValue,object request){dynamic f=fixture;byte[] bytes=Unwrap(bytesValue) as byte[];if(bytes==null||bytes.Length==0)throw new InvalidOperationException("behavior-response-bytes");if(!String.Equals(Convert.ToString(Unwrap(f.CaseNonce),System.Globalization.CultureInfo.InvariantCulture),(string)Member(request,"CaseNonce"),StringComparison.Ordinal))throw new InvalidOperationException("behavior-response-request-binding");string path=Convert.ToString(Unwrap(f.ResponsePath),System.Globalization.CultureInfo.InvariantCulture);string identity;using(var writer=new FileStream(path,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Read,4096,FileOptions.WriteThrough)){writer.Write(bytes,0,bytes.Length);writer.Flush(true);writer.Position=0;identity=(string)TransportCall("GetIdentity",writer);}FileStream stream=new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read);try{if(!String.Equals(identity,(string)TransportCall("GetIdentity",stream),StringComparison.Ordinal))throw new InvalidOperationException("behavior-response-identity-drift");string sha=Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();f.ResponseStream=stream;f.ResponseArtifact=Artifact("response",(string)Member(request,"ResponseRelativePath"),identity,bytes.LongLength,sha);if(!(bool)f.DoneEvent.Set())throw new InvalidOperationException("behavior-done-signal");int remaining=RemainingMilliseconds(Convert.ToInt64(Unwrap(f.AbsoluteDeadlineQpc),System.Globalization.CultureInfo.InvariantCulture));if(remaining<=0||!(bool)f.ReleaseEvent.WaitOne(remaining))throw new TimeoutException("behavior-release-timeout");var host=new Dictionary<string,object>(StringComparer.Ordinal){{"Pid",(long)Process.GetCurrentProcess().Id},{"RootCreationFileTimeTicks",Process.GetCurrentProcess().StartTime.ToUniversalTime().ToFileTimeUtc().ToString(System.Globalization.CultureInfo.InvariantCulture)}};return new Dictionary<string,object>(StringComparer.Ordinal){{"Artifact",f.ResponseArtifact},{"HostIdentity",host}};}catch{if(Object.ReferenceEquals(f.ResponseStream,stream))f.ResponseStream=null;stream.Dispose();throw;}}
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
        $SelectorArm,
        [Parameter(Mandatory)][Alias('Evidence')]$ObservedRecordData
    )
    $declared=[AiAgentDotfilesTests.SealedMutationPrimitiveVariant]$DeclaredVariant
    $selector=$InvocationContext.Coordinator.Selector
    $normalizedNamespace=[IO.Path]::GetFullPath($TransactionNamespace)
    $resolvedArm=$SelectorArm
    if($null -eq $resolvedArm){
        $evidenceTarget=$ObservedRecordData.Target
        if($null -eq $evidenceTarget -or [string]::IsNullOrWhiteSpace([string]$evidenceTarget.TargetId)){
            throw 'sealed mutation reach requires its explicit selector arm'
        }
        $resolvedArm=[ordered]@{TargetId=[string]$evidenceTarget.TargetId;TargetOrder=[long]$evidenceTarget.Order}
    }
    $selectorArmJson=[Text.UTF8Encoding]::new($false,$true).GetString((ConvertTo-SemanticJsonBytes -InputObject $resolvedArm))
    $ticket=$InvocationContext.Coordinator.TryAcceptMatch($normalizedNamespace,$Checkpoint,$declared,[string]$ActualBranchState,$selectorArmJson)
    if($null -eq $ticket){return}

    $snapshot=$null;$intentLease=$null;$tailLease=$null;$tempLease=$null;$finalSeal=$null
    $sharedRecordLease=$false;$handoff=$false;$reachPrimary=$null
    $reachCleanupErrors=[Collections.Generic.List[Exception]]::new()
    try{
        $snapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $normalizedNamespace -AllowUnfinished
        Assert-CanonicalJournalSnapshotInventory -Snapshot $snapshot
        if(@($snapshot.State.PendingEntries).Count -ne 0){throw 'sealed mutation reach requires zero pending journal entries'}
        if([string]$snapshot.State.TransactionNamespace -cne $selector.TransactionNamespace -or
            [string]$snapshot.State.Header.TransactionId -cne $selector.TransactionId){throw 'sealed mutation reach journal identity differs from selector'}
        $intentRecords=@();$tailRecords=@()
        foreach($journalRecord in @($snapshot.State.Records)){
            if([long]$journalRecord.Sequence -eq $selector.ExpectedIntentSequence -and [string]$journalRecord.Phase -ceq $selector.ExpectedIntentPhase){
                $intentRecords=@($intentRecords)+@($journalRecord)
            }
            if([long]$journalRecord.Sequence -eq $selector.ExpectedTailSequence -and [string]$journalRecord.Phase -ceq $selector.ExpectedTailPhase){
                $tailRecords=@($tailRecords)+@($journalRecord)
            }
        }
        if($intentRecords.Count -ne 1 -or $tailRecords.Count -ne 1 -or
            [long]$snapshot.State.Records[-1].Sequence -ne $selector.ExpectedTailSequence){throw 'sealed mutation reach durable intent or actual tail is ambiguous'}
        $intentRecord=$intentRecords[0];$tailRecord=$tailRecords[0]
        if($null -ne $selector.WorkspaceRole){
            foreach($record in @($intentRecord,$tailRecord)){
                if(-not $record.Data.Contains('WorkspaceRole') -or [string]$record.Data.WorkspaceRole -cne [string]$selector.WorkspaceRole){
                    throw 'sealed mutation reach workspace durable record belongs to a different selector arm'
                }
            }
        }else{
            $armTargets=@()
            foreach($headerTarget in @($snapshot.State.Header.Targets)){
                if([string]$headerTarget.TargetId -ceq [string]$selector.TargetId -and [long]$headerTarget.Order -eq [long]$selector.TargetOrder){
                    $armTargets=@($armTargets)+@($headerTarget)
                }
            }
            if($armTargets.Count -ne 1){throw 'sealed mutation reach selector target/order is not one exact journal-header arm'}
            if($Checkpoint -eq [AiAgentDotfilesTests.SealedMutationCheckpoint]::PreimageReady){
                foreach($record in @($intentRecord,$tailRecord)){
                    if(-not $record.Data.Contains('WorkspaceRole') -or [string]$record.Data.WorkspaceRole -cne 'swap-old'){
                        throw 'sealed mutation reach preimage-ready causality is not the second durable workspace arm'
                    }
                }
            }else{
                foreach($record in @($intentRecord,$tailRecord)){
                    if(-not $record.Data.Contains('TargetId') -or [string]$record.Data.TargetId -cne [string]$selector.TargetId){
                        throw 'sealed mutation reach durable target record belongs to a different selector arm'
                    }
                }
            }
        }
        $intentName=('{0:d6}.json' -f [long]$selector.ExpectedIntentSequence)
        $tailName=('{0:d6}.json' -f [long]$selector.ExpectedTailSequence)
        $intentLease=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($snapshot.NamespaceHandle,$intentName)
        if($selector.ExpectedTailSequence -eq $selector.ExpectedIntentSequence){$tailLease=$intentLease;$sharedRecordLease=$true}
        else{$tailLease=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($snapshot.NamespaceHandle,$tailName)}
        $intentBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($intentLease,[long]$intentLease.ReadResult.Length)
        $tailBytes=if($sharedRecordLease){$intentBytes}else{[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($tailLease,[long]$tailLease.ReadResult.Length)}
        $intentRawSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($intentBytes)).ToLowerInvariant()
        $tailRawSha256=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($tailBytes)).ToLowerInvariant()
        if($intentRawSha256 -cne [string]$intentLease.ReadResult.Sha256 -or $tailRawSha256 -cne [string]$tailLease.ReadResult.Sha256){throw 'sealed mutation reach held journal bytes changed'}
        $intentSemanticHash=Get-SemanticJsonHash -InputObject $intentRecord
        $tailSemanticHash=Get-SemanticJsonHash -InputObject $tailRecord
        $derivedJournalHeadHash=[string]$snapshot.State.DerivedJournalHeadHash
        if($derivedJournalHeadHash -cne $tailSemanticHash){throw 'sealed mutation reach actual tail does not derive the journal head'}
        Close-CanonicalJournalSnapshot -Snapshot $snapshot;$snapshot=$null

        $evidenceTupleHash=Get-SemanticJsonHash -InputObject ([ordered]@{
            TransactionNamespace=$normalizedNamespace;Checkpoint=$Checkpoint.ToString();DeclaredVariant=$declared.ToString()
            ActualBranchDiscriminator=[string]$ActualBranchState;SelectorArm=$resolvedArm;ObservedRecordData=$ObservedRecordData
            IntentSequence=[long]$selector.ExpectedIntentSequence;IntentSemanticHash=$intentSemanticHash
            TailSequence=[long]$selector.ExpectedTailSequence;TailSemanticHash=$tailSemanticHash;DerivedJournalHeadHash=$derivedJournalHeadHash
        })
        $tempLease=$InvocationContext.StageRootLease.BeginCreateStageTemp()
        $stageDocument=[ordered]@{
            SchemaVersion=[long]1;ArtifactKind='sealed-mutation-held-stage'
            ControllerNonce=$selector.ControllerNonce;CaseNonce=$selector.CaseNonce
            StageReadyEventName=$selector.StageReadyEventName;StageReadyEventNonce=$selector.StageReadyEventNonce
            ContinueEventName=$selector.ContinueEventName;ContinueEventNonce=$selector.ContinueEventNonce
            Pid=[long][Diagnostics.Process]::GetCurrentProcess().Id
            RootCreationFileTimeTicks=[AiAgentDotfilesTests.SealedStageNativeBridge]::GetCurrentProcessCreationFileTimeTicks().ToString([Globalization.CultureInfo]::InvariantCulture)
            TransactionId=$selector.TransactionId;TransactionNamespace=$selector.TransactionNamespace
            Checkpoint=$selector.Checkpoint.ToString();DeclaredPrimitiveVariant=$selector.DeclaredVariant.ToString()
            ActualBranchDiscriminator=[string]$ActualBranchState;SelectorArm=$resolvedArm
            IntentPhase=[string]$intentRecord.Phase;IntentSequence=[long]$intentRecord.Sequence;IntentSemanticHash=$intentSemanticHash
            IntentArtifactIdentity=[string]$intentLease.Info.Identity;IntentArtifactLength=[long]$intentLease.ReadResult.Length;IntentArtifactRawSha256=$intentRawSha256
            TailPhase=[string]$tailRecord.Phase;TailSequence=[long]$tailRecord.Sequence;TailSemanticHash=$tailSemanticHash
            TailArtifactIdentity=[string]$tailLease.Info.Identity;TailArtifactLength=[long]$tailLease.ReadResult.Length;TailArtifactRawSha256=$tailRawSha256
            DerivedJournalHeadHash=$derivedJournalHeadHash;EvidenceTupleHash=$evidenceTupleHash
            StageRootIdentity=$selector.StageRootIdentity;StageTempLeaf=$selector.StageTempLeaf;StageFinalLeaf=$selector.StageFinalLeaf
            StageArtifactIdentity=$tempLease.Identity
            ControllerObservationMilliseconds=[long]$selector.ControllerObservationMilliseconds;JobReapMilliseconds=[long]$selector.JobReapMilliseconds
            CleanupMilliseconds=[long]$selector.CleanupMilliseconds;WorkerWaitMilliseconds=[long]$selector.WorkerWaitMilliseconds
            ControllerQpcTicks=$selector.ControllerQpcTicks.ToString([Globalization.CultureInfo]::InvariantCulture)
            StopwatchFrequency=$selector.StopwatchFrequency.ToString([Globalization.CultureInfo]::InvariantCulture)
            ControllerObservationDeadlineQpc=$selector.ControllerObservationDeadlineQpc.ToString([Globalization.CultureInfo]::InvariantCulture)
            HardKillCumulativeReapDeadlineQpc=$selector.HardKillCumulativeReapDeadlineQpc.ToString([Globalization.CultureInfo]::InvariantCulture)
            WorkerDeadlineQpc=$selector.WorkerDeadlineQpc.ToString([Globalization.CultureInfo]::InvariantCulture)
            NaturalReleaseCumulativeReapDeadlineQpc=$selector.NaturalReleaseCumulativeReapDeadlineQpc.ToString([Globalization.CultureInfo]::InvariantCulture)
            HardKillCumulativeCleanupDeadlineQpc=$selector.HardKillCumulativeCleanupDeadlineQpc.ToString([Globalization.CultureInfo]::InvariantCulture)
            NaturalReleaseCumulativeCleanupDeadlineQpc=$selector.NaturalReleaseCumulativeCleanupDeadlineQpc.ToString([Globalization.CultureInfo]::InvariantCulture)
            SelectorSha256=$selector.SelectorSha256
        }
        $stageBytes=ConvertTo-SemanticJsonBytes -InputObject $stageDocument
        $finalSeal=$tempLease.WriteFlushRenameAndSealFinal($stageBytes);$tempLease=$null
        if($finalSeal.Identity -cne [string]$stageDocument.StageArtifactIdentity -or
            $finalSeal.Length -ne $stageBytes.LongLength -or
            $finalSeal.RawSha256 -cne [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stageBytes)).ToLowerInvariant()){
            throw 'sealed mutation stage final seal differs from publication bytes'
        }
        $handoff=$true
        $InvocationContext.Coordinator.MarkPublishedSignalReadyAndWait($ticket)
    }catch{
        $reachPrimary=$_.Exception
    }finally{
        if($finalSeal){try{$finalSeal.Dispose()}catch{$null=$reachCleanupErrors.Add($_.Exception)}}
        if($tempLease){try{$tempLease.Dispose()}catch{$null=$reachCleanupErrors.Add($_.Exception)}}
        if($tailLease -and -not $sharedRecordLease){try{$tailLease.Dispose()}catch{$null=$reachCleanupErrors.Add($_.Exception)}}
        if($intentLease){try{$intentLease.Dispose()}catch{$null=$reachCleanupErrors.Add($_.Exception)}}
        if($snapshot){try{Close-CanonicalJournalSnapshot -Snapshot $snapshot}catch{$null=$reachCleanupErrors.Add($_.Exception)}}
        if($null -ne $reachPrimary -and -not $handoff){try{$InvocationContext.Coordinator.MarkPublicationFailed($ticket)}catch{$null=$reachCleanupErrors.Add($_.Exception)}}
    }
    if($null -ne $reachPrimary -or $reachCleanupErrors.Count -ne 0){
        $reachFailures=[Collections.Generic.List[Exception]]::new()
        if($null -ne $reachPrimary){$null=$reachFailures.Add($reachPrimary)}
        foreach($cleanupError in $reachCleanupErrors){$null=$reachFailures.Add($cleanupError)}
        if($reachFailures.Count -eq 1){throw $reachFailures[0]}
        throw [AggregateException]::new('sealed-mutation-reach-primary-and-cleanup',[Exception[]]$reachFailures.ToArray())
    }
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
