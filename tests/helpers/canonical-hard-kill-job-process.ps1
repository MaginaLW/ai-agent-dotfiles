#requires -Version 7.0

Set-StrictMode -Version Latest

$hardKillSealedMutationTransportAuthoritySource=@'
using System;
using System.Collections;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

namespace AiAgentDotfilesTests {
    public sealed class HardKillJobProcess : IDisposable {
        private const uint CREATE_SUSPENDED = 0x00000004;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint CREATE_NEW = 1;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint FILE_FLAG_WRITE_THROUGH = 0x80000000;
        private const uint PROCESS_QUERY_LIMITED_INFORMATION = 0x00001000;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint HardKillTerminationExitCode = 0xC000042D;
        private const int ReviewedWorkerWaitMilliseconds = 420000;
        private const int ReviewedControllerObservationMilliseconds = 300000;
        private const int ReviewedJobReapMilliseconds = 30000;
        private const int ReviewedCleanupMilliseconds = 30000;
        private const int ReviewedLegacyReapMilliseconds = 30000;
        private const int ERROR_INVALID_PARAMETER = 87;
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = new IntPtr(0x00020002);
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = new IntPtr(0x0002000D);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory,
            IntPtr startupInfo, IntPtr processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr job, int infoClass, IntPtr info, uint length, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out long creation, out long exit, out long kernel, out long user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint access, [MarshalAs(UnmanagedType.Bool)] bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private readonly object gate = new object();
        private IntPtr jobHandle;
        private IntPtr rootProcessHandle;
        private IntPtr rootThreadHandle;
        private Process rootProcess;
        private readonly int rootProcessId;
        private readonly long rootStartTimeUtcTicks;
        private readonly string standardOutputPath;
        private readonly string standardErrorPath;
        private bool containmentEmpty;
        private bool resumed;
        private bool reaped;
        private bool disposed;
        private bool legacyReapDeadlineBound;
        private long legacyReapDeadlineQpc;
        private int legacyTerminationAttemptCount;
        private int legacyTerminationNativeErrorCode;
        private string legacyTerminationFailureOperation;

        private HardKillJobProcess(IntPtr job, IntPtr processHandle, IntPtr threadHandle, Process process, int processId, long startTicks, string stdoutPath, string stderrPath) {
            jobHandle = job;
            rootProcessHandle = processHandle;
            rootThreadHandle = threadHandle;
            rootProcess = process;
            rootProcessId = processId;
            rootStartTimeUtcTicks = startTicks;
            standardOutputPath = stdoutPath;
            standardErrorPath = stderrPath;
        }

        public Process Process {
            get {
                lock (gate) {
                    if (reaped || disposed || rootProcess == null) throw new ObjectDisposedException("HardKillJobProcess", "The root Process is unavailable after Job reap.");
                    return rootProcess;
                }
            }
        }
        public int ProcessId { get { return rootProcessId; } }
        public long RootCreationFileTimeTicks { get { return rootStartTimeUtcTicks; } }
        public string StandardOutputPath { get { return standardOutputPath; } }
        public string StandardErrorPath { get { return standardErrorPath; } }
        public bool Reaped { get { lock (gate) { return reaped; } } }
        public uint ActiveProcesses { get { lock (gate) { if (disposed) throw new ObjectDisposedException("HardKillJobProcess"); return containmentEmpty ? 0U : GetActiveProcessCount(jobHandle); } } }
        public int RootExitCode {
            get {
                lock (gate) {
                    if (reaped || disposed || rootProcessHandle == IntPtr.Zero)
                        throw new ObjectDisposedException("HardKillJobProcess", "The exact root exit code must be captured before Job reap.");
                    uint wait = WaitForSingleObject(rootProcessHandle, 0);
                    if (wait != WAIT_OBJECT_0) throw new InvalidOperationException("The exact root process has not exited.");
                    uint exitCode;
                    if (!GetExitCodeProcess(rootProcessHandle, out exitCode)) throw Win32("GetExitCodeProcess failed");
                    return unchecked((int)exitCode);
                }
            }
        }

        private static Win32Exception Win32(string operation) { return new Win32Exception(Marshal.GetLastWin32Error(), operation); }

        private Win32Exception CreateLegacyTerminationFailure() {
            Win32Exception failure = new Win32Exception(legacyTerminationNativeErrorCode, legacyTerminationFailureOperation);
            failure.Data["NativeErrorCode"] = legacyTerminationNativeErrorCode;
            failure.Data["NativeOperation"] = legacyTerminationFailureOperation;
            return failure;
        }

        private static string QuoteArgument(string argument) {
            if (argument == null) argument = String.Empty;
            if (argument.Length > 0 && argument.IndexOf(' ') < 0 && argument.IndexOf('\t') < 0 && argument.IndexOf('\n') < 0 &&
                argument.IndexOf('\v') < 0 && argument.IndexOf('"') < 0) return argument;
            StringBuilder quoted = new StringBuilder();
            quoted.Append('"');
            int slashes = 0;
            foreach (char value in argument) {
                if (value == '\\') { slashes++; continue; }
                if (value == '"') { quoted.Append('\\', slashes * 2 + 1); quoted.Append('"'); slashes = 0; continue; }
                if (slashes > 0) { quoted.Append('\\', slashes); slashes = 0; }
                quoted.Append(value);
            }
            if (slashes > 0) quoted.Append('\\', slashes * 2);
            quoted.Append('"');
            return quoted.ToString();
        }

        private static StringBuilder BuildCommandLine(string executable, string[] arguments) {
            StringBuilder command = new StringBuilder(QuoteArgument(executable));
            foreach (string argument in arguments ?? new string[0]) { command.Append(' '); command.Append(QuoteArgument(argument)); }
            return command;
        }

        private static IntPtr OpenChildStandardHandle(string path, bool read) {
            uint access = read ? GENERIC_READ : GENERIC_WRITE;
            uint share = path == null ? FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE : FILE_SHARE_READ;
            uint creation = path == null ? OPEN_EXISTING : CREATE_NEW;
            uint flags = FILE_ATTRIBUTE_NORMAL | (path == null ? 0 : FILE_FLAG_WRITE_THROUGH);
            string target = path == null ? "NUL" : Path.GetFullPath(path);
            if (path != null) {
                string parent = Path.GetDirectoryName(target);
                if (String.IsNullOrWhiteSpace(parent) || !Directory.Exists(parent)) throw new DirectoryNotFoundException("Redirect parent is missing: " + parent);
            }
            int securitySize = IntPtr.Size == 8 ? 24 : 12;
            IntPtr security = Marshal.AllocHGlobal(securitySize);
            try {
                for (int offset = 0; offset < securitySize; offset += 4) Marshal.WriteInt32(security, offset, 0);
                Marshal.WriteInt32(security, 0, securitySize);
                Marshal.WriteInt32(security, IntPtr.Size == 8 ? 16 : 8, 1);
                IntPtr handle = CreateFileW(target, access, share, security, creation, flags, IntPtr.Zero);
                if (handle == INVALID_HANDLE_VALUE) throw Win32("CreateFileW standard handle failed");
                return handle;
            }
            finally { Marshal.FreeHGlobal(security); }
        }

        private static uint GetActiveProcessCount(IntPtr job) {
            const int size = 48;
            IntPtr memory = Marshal.AllocHGlobal(size);
            try {
                if (!QueryInformationJobObject(job, 1, memory, (uint)size, IntPtr.Zero))
                    throw Win32("QueryInformationJobObject failed");
                return unchecked((uint)Marshal.ReadInt32(memory, 40));
            }
            finally { Marshal.FreeHGlobal(memory); }
        }

        private static bool OriginalProcessIdentityGone(int processId, long startTicks) {
            IntPtr process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | SYNCHRONIZE, false, (uint)processId);
            if (process == IntPtr.Zero) {
                int error = Marshal.GetLastWin32Error();
                if (error == ERROR_INVALID_PARAMETER) return true;
                throw new Win32Exception(error, "OpenProcess identity check failed");
            }
            try {
                long creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) throw Win32("GetProcessTimes identity check failed");
                return creation != startTicks;
            }
            finally { CloseHandle(process); }
        }

        private static bool WaitForJobEmpty(IntPtr job, Stopwatch deadline, int timeoutMilliseconds) {
            while (GetActiveProcessCount(job) != 0) {
                if (deadline.ElapsedMilliseconds >= timeoutMilliseconds) return false;
                Thread.Sleep(5);
            }
            return true;
        }

        private static bool WaitForOriginalProcessIdentityGone(int processId, long startTicks, Stopwatch deadline, int timeoutMilliseconds) {
            while (!OriginalProcessIdentityGone(processId, startTicks)) {
                if (deadline.ElapsedMilliseconds >= timeoutMilliseconds) return false;
                Thread.Sleep(5);
            }
            return true;
        }

        private static void FailStop(string message, Exception cause) {
            Environment.FailFast("Hard-kill Job containment failure: " + message, cause);
        }

        private static Exception CombineStartAndCleanupFailure(Exception primary, Exception cleanup) {
            if (primary == null) primary = new InvalidOperationException("hard-kill Job start failed without a captured primary exception");
            if (cleanup == null) cleanup = new InvalidOperationException("hard-kill Job cleanup failed without a captured cleanup exception");
            return new AggregateException("Hard-kill Job start and cleanup both failed.", new Exception[] { primary, cleanup });
        }

        public static bool CurrentProcessIsInJob() {
            using (Process current = Process.GetCurrentProcess()) {
                bool inJob;
                if (!IsProcessInJob(current.Handle, IntPtr.Zero, out inJob)) throw Win32("IsProcessInJob current process failed");
                return inJob;
            }
        }

        public static HardKillJobProcess Start(string executablePath, string[] arguments, string standardOutputPath, string standardErrorPath) {
            string executable = Path.GetFullPath(executablePath);
            string stdout = String.IsNullOrWhiteSpace(standardOutputPath) ? null : Path.GetFullPath(standardOutputPath);
            string stderr = String.IsNullOrWhiteSpace(standardErrorPath) ? null : Path.GetFullPath(standardErrorPath);
            if (stdout != null && stderr != null && String.Equals(stdout, stderr, StringComparison.OrdinalIgnoreCase))
                throw new ArgumentException("stdout and stderr redirect paths must differ.");

            IntPtr stdinChild = IntPtr.Zero, stdoutChild = IntPtr.Zero, stderrChild = IntPtr.Zero;
            IntPtr job = IntPtr.Zero, limitMemory = IntPtr.Zero, attributeList = IntPtr.Zero, handleList = IntPtr.Zero, jobList = IntPtr.Zero;
            IntPtr startupMemory = IntPtr.Zero, processMemory = IntPtr.Zero;
            IntPtr processHandle = IntPtr.Zero, threadHandle = IntPtr.Zero;
            int processId = 0;
            Process managedProcess = null;
            bool processCreated = false, success = false;
            Exception failure = null;
            try {
                stdinChild = OpenChildStandardHandle(null, true);
                stdoutChild = OpenChildStandardHandle(stdout, false);
                stderrChild = OpenChildStandardHandle(stderr, false);

                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw Win32("CreateJobObject failed");
                int limitSize = IntPtr.Size == 8 ? 144 : 108;
                limitMemory = Marshal.AllocHGlobal(limitSize);
                for (int offset = 0; offset < limitSize; offset += 4) Marshal.WriteInt32(limitMemory, offset, 0);
                Marshal.WriteInt32(limitMemory, 16, unchecked((int)JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE));
                if (!SetInformationJobObject(job, 9, limitMemory, (uint)limitSize))
                    throw Win32("SetInformationJobObject failed");

                IntPtr attributeSize = IntPtr.Zero;
                InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref attributeSize);
                attributeList = Marshal.AllocHGlobal(attributeSize);
                if (!InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeSize)) throw Win32("InitializeProcThreadAttributeList failed");
                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, stdinChild);
                Marshal.WriteIntPtr(handleList, IntPtr.Size, stdoutChild);
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderrChild);
                if (!UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList, new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                    throw Win32("UpdateProcThreadAttribute handle list failed");
                jobList = Marshal.AllocHGlobal(IntPtr.Size);
                Marshal.WriteIntPtr(jobList, job);
                if (!UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_JOB_LIST, jobList, new IntPtr(IntPtr.Size), IntPtr.Zero, IntPtr.Zero))
                    throw Win32("UpdateProcThreadAttribute job list failed");

                int startupSize = IntPtr.Size == 8 ? 112 : 72;
                int processInfoSize = IntPtr.Size == 8 ? 24 : 16;
                startupMemory = Marshal.AllocHGlobal(startupSize);
                processMemory = Marshal.AllocHGlobal(processInfoSize);
                for (int offset = 0; offset < startupSize; offset += 4) Marshal.WriteInt32(startupMemory, offset, 0);
                for (int offset = 0; offset < processInfoSize; offset += 4) Marshal.WriteInt32(processMemory, offset, 0);
                Marshal.WriteInt32(startupMemory, 0, startupSize);
                Marshal.WriteInt32(startupMemory, IntPtr.Size == 8 ? 60 : 44, unchecked((int)STARTF_USESTDHANDLES));
                int standardHandleOffset = IntPtr.Size == 8 ? 80 : 56;
                Marshal.WriteIntPtr(startupMemory, standardHandleOffset, stdinChild);
                Marshal.WriteIntPtr(startupMemory, standardHandleOffset + IntPtr.Size, stdoutChild);
                Marshal.WriteIntPtr(startupMemory, standardHandleOffset + IntPtr.Size * 2, stderrChild);
                Marshal.WriteIntPtr(startupMemory, IntPtr.Size == 8 ? 104 : 68, attributeList);
                uint flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;
                if (!CreateProcessW(executable, BuildCommandLine(executable, arguments), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero,
                    Environment.CurrentDirectory, startupMemory, processMemory)) throw Win32("CreateProcessW failed");
                processCreated = true;
                processHandle = Marshal.ReadIntPtr(processMemory, 0);
                threadHandle = Marshal.ReadIntPtr(processMemory, IntPtr.Size);
                processId = Marshal.ReadInt32(processMemory, IntPtr.Size * 2);

                bool inJob;
                if (!IsProcessInJob(processHandle, job, out inJob) || !inJob) throw Win32("IsProcessInJob failed");
                long creation, exit, kernel, user;
                if (!GetProcessTimes(processHandle, out creation, out exit, out kernel, out user)) throw Win32("GetProcessTimes failed");
                managedProcess = Process.GetProcessById(processId);
                HardKillJobProcess result = new HardKillJobProcess(job, processHandle, threadHandle, managedProcess, processId, creation, stdout, stderr);
                job = IntPtr.Zero; processHandle = IntPtr.Zero; threadHandle = IntPtr.Zero; managedProcess = null;
                success = true;
                return result;
            }
            catch (Exception error) { failure = error; throw; }
            finally {
                if (!success && processCreated) {
                    try {
                        if (job != IntPtr.Zero) TerminateJobObject(job, 1);
                        if (threadHandle != IntPtr.Zero) {
                            CloseHandle(threadHandle); threadHandle = IntPtr.Zero;
                        }
                        if (processHandle != IntPtr.Zero) {
                            WaitForSingleObject(processHandle, 5000);
                            CloseHandle(processHandle); processHandle = IntPtr.Zero;
                        }
                        if (managedProcess != null) { managedProcess.Dispose(); managedProcess = null; }
                        if (job != IntPtr.Zero && !WaitForJobEmpty(job, Stopwatch.StartNew(), 5000))
                            FailStop("start failure did not empty the Job", CombineStartAndCleanupFailure(failure, new TimeoutException("start failure did not empty the Job")));
                    }
                    catch (Exception cleanupError) { FailStop("start failure cleanup could not prove an empty Job", CombineStartAndCleanupFailure(failure, cleanupError)); }
                }
                if (threadHandle != IntPtr.Zero) CloseHandle(threadHandle);
                if (stdinChild != IntPtr.Zero && stdinChild != INVALID_HANDLE_VALUE) CloseHandle(stdinChild);
                if (stdoutChild != IntPtr.Zero && stdoutChild != INVALID_HANDLE_VALUE) CloseHandle(stdoutChild);
                if (stderrChild != IntPtr.Zero && stderrChild != INVALID_HANDLE_VALUE) CloseHandle(stderrChild);
                if (attributeList != IntPtr.Zero) { DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
                if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
                if (limitMemory != IntPtr.Zero) Marshal.FreeHGlobal(limitMemory);
                if (startupMemory != IntPtr.Zero) Marshal.FreeHGlobal(startupMemory);
                if (processMemory != IntPtr.Zero) Marshal.FreeHGlobal(processMemory);
                if (job != IntPtr.Zero) CloseHandle(job);
            }
        }

        internal void ResumeRoot() {
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) throw new InvalidOperationException("The reaped Job cannot be resumed.");
                if (resumed) throw new InvalidOperationException("The suspended root was already resumed.");
                if (rootThreadHandle == IntPtr.Zero) throw new InvalidOperationException("The suspended root thread handle is unavailable.");
                if (ResumeThread(rootThreadHandle) == UInt32.MaxValue) throw Win32("ResumeThread failed");
                if (!CloseHandle(rootThreadHandle)) throw Win32("CloseHandle root thread failed");
                rootThreadHandle = IntPtr.Zero;
                resumed = true;
            }
        }

        private static long AddMillisecondsChecked(long startQpc, int milliseconds, long frequency) {
            if (startQpc <= 0 || milliseconds <= 0 || frequency <= 0) throw new ArgumentOutOfRangeException("milliseconds");
            long seconds = milliseconds / 1000L;
            long remainder = milliseconds % 1000L;
            long delta = checked(seconds * frequency + checked(remainder * frequency + 999L) / 1000L);
            return checked(startQpc + delta);
        }

        private static int RemainingMilliseconds(long absoluteDeadlineQpc) {
            if (absoluteDeadlineQpc <= 0) throw new ArgumentOutOfRangeException("absoluteDeadlineQpc");
            long now = Stopwatch.GetTimestamp();
            if (now >= absoluteDeadlineQpc) return 0;
            long delta = absoluteDeadlineQpc - now;
            long frequency = Stopwatch.Frequency;
            long seconds = delta / frequency;
            long remainder = delta % frequency;
            long milliseconds = checked(seconds * 1000L + checked(remainder * 1000L + frequency - 1L) / frequency);
            return (int)Math.Min(Int32.MaxValue, Math.Max(1L, milliseconds));
        }

        private static void RequireTimeRemaining(long absoluteDeadlineQpc, string operation) {
            if (RemainingMilliseconds(absoluteDeadlineQpc) <= 0)
                throw new TimeoutException(operation + " exceeded its immutable absolute QPC deadline.");
        }

        private static uint GetActiveProcessCountUntil(IntPtr job, long absoluteDeadlineQpc) {
            RequireTimeRemaining(absoluteDeadlineQpc, "QueryInformationJobObject");
            return GetActiveProcessCount(job);
        }

        private static long WaitForJobEmptyUntil(IntPtr job, long absoluteDeadlineQpc) {
            while (true) {
                if (GetActiveProcessCountUntil(job, absoluteDeadlineQpc) == 0) {
                    long zeroQpc = Stopwatch.GetTimestamp();
                    if (zeroQpc > absoluteDeadlineQpc) throw new TimeoutException("Job ActiveProcesses reached zero after the immutable reap deadline.");
                    return zeroQpc;
                }
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                if (remaining <= 0) throw new TimeoutException("Job ActiveProcesses did not reach zero before the immutable reap deadline.");
                Thread.Sleep(Math.Min(5, remaining));
            }
        }

        private static void WaitForOriginalProcessIdentityGoneUntil(int processId, long startTicks, long absoluteDeadlineQpc) {
            while (true) {
                RequireTimeRemaining(absoluteDeadlineQpc, "exact process identity query");
                if (OriginalProcessIdentityGone(processId, startTicks)) return;
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                if (remaining <= 0) throw new TimeoutException("The exact root PID/creation identity remained visible after Job close.");
                Thread.Sleep(Math.Min(5, remaining));
            }
        }

        private static void ValidateDeadlines(SealedJobQpcDeadlines deadlines) {
            if (deadlines == null) throw new ArgumentNullException("deadlines");
            if (deadlines.WorkerWaitMilliseconds != ReviewedWorkerWaitMilliseconds ||
                deadlines.ControllerObservationMilliseconds != ReviewedControllerObservationMilliseconds ||
                deadlines.JobReapMilliseconds != ReviewedJobReapMilliseconds ||
                deadlines.CleanupMilliseconds != ReviewedCleanupMilliseconds)
                throw new InvalidOperationException("The sealed Job deadlines do not use the reviewed immutable budgets.");
            if (deadlines.StopwatchFrequency != Stopwatch.Frequency || deadlines.StopwatchFrequency <= 0 ||
                deadlines.ControllerQpcTicks <= 0 || deadlines.ControllerQpcTicks > Stopwatch.GetTimestamp() ||
                String.IsNullOrEmpty(deadlines.SelectorHash) ||
                !System.Text.RegularExpressions.Regex.IsMatch(deadlines.SelectorHash, "^[0-9a-f]{64}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                throw new InvalidOperationException("The sealed Job deadline epoch, frequency, or selector hash is invalid.");
            long worker = AddMillisecondsChecked(deadlines.ControllerQpcTicks, ReviewedWorkerWaitMilliseconds, deadlines.StopwatchFrequency);
            long observation = AddMillisecondsChecked(deadlines.ControllerQpcTicks, ReviewedControllerObservationMilliseconds, deadlines.StopwatchFrequency);
            long hardReap = AddMillisecondsChecked(observation, ReviewedJobReapMilliseconds, deadlines.StopwatchFrequency);
            long hardCleanup = AddMillisecondsChecked(hardReap, ReviewedCleanupMilliseconds, deadlines.StopwatchFrequency);
            long naturalReap = AddMillisecondsChecked(worker, ReviewedJobReapMilliseconds, deadlines.StopwatchFrequency);
            long naturalCleanup = AddMillisecondsChecked(naturalReap, ReviewedCleanupMilliseconds, deadlines.StopwatchFrequency);
            if (deadlines.WorkerDeadlineQpc != worker || deadlines.ControllerObservationDeadlineQpc != observation ||
                deadlines.HardKillCumulativeReapDeadlineQpc != hardReap || deadlines.HardKillCumulativeCleanupDeadlineQpc != hardCleanup ||
                deadlines.NaturalReleaseCumulativeReapDeadlineQpc != naturalReap || deadlines.NaturalReleaseCumulativeCleanupDeadlineQpc != naturalCleanup ||
                !(ReviewedControllerObservationMilliseconds + ReviewedJobReapMilliseconds + ReviewedCleanupMilliseconds + 30000 < ReviewedWorkerWaitMilliseconds) ||
                !(ReviewedWorkerWaitMilliseconds < 480000) || !(480000 < 5400000))
                throw new InvalidOperationException("The sealed Job derived absolute deadlines differ from the reviewed cumulative caps.");
        }

        private void ValidateExpectedIdentity(long expectedProcessId, long expectedCreationTicks, long absoluteDeadlineQpc) {
            if (expectedProcessId != rootProcessId || expectedCreationTicks != rootStartTimeUtcTicks)
                throw new InvalidOperationException("The exact root PID/creation identity differs from the sealed session.");
            RequireTimeRemaining(absoluteDeadlineQpc, "GetProcessTimes root identity validation");
            long creation, exit, kernel, user;
            if (rootProcessHandle == IntPtr.Zero || !GetProcessTimes(rootProcessHandle, out creation, out exit, out kernel, out user))
                throw Win32("GetProcessTimes root identity validation failed");
            if (creation != rootStartTimeUtcTicks)
                throw new InvalidOperationException("The retained raw root handle creation FILETIME differs from the sealed session.");
        }

        private bool RootIsSignaledUntil(long absoluteDeadlineQpc) {
            RequireTimeRemaining(absoluteDeadlineQpc, "exact root signal query");
            uint wait = WaitForSingleObject(rootProcessHandle, 0);
            if (wait == WAIT_OBJECT_0) return true;
            if (wait == WAIT_TIMEOUT) return false;
            throw Win32("WaitForSingleObject root signal query failed");
        }

        private void WaitForRootExitUntil(long absoluteDeadlineQpc) {
            while (true) {
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                if (remaining <= 0) throw new TimeoutException("The exact root process did not exit before the immutable absolute deadline.");
                uint wait = WaitForSingleObject(rootProcessHandle, (uint)Math.Min(50, remaining));
                if (wait == WAIT_OBJECT_0) {
                    if (Stopwatch.GetTimestamp() > absoluteDeadlineQpc)
                        throw new TimeoutException("The exact root process exit was observed after the immutable absolute deadline.");
                    return;
                }
                if (wait != WAIT_TIMEOUT) throw Win32("WaitForSingleObject root exit failed");
            }
        }

        private uint CaptureRootExitCodeUntil(long absoluteDeadlineQpc) {
            RequireTimeRemaining(absoluteDeadlineQpc, "GetExitCodeProcess");
            uint exitCode;
            if (!GetExitCodeProcess(rootProcessHandle, out exitCode)) throw Win32("GetExitCodeProcess failed");
            return exitCode;
        }

        private long CloseRootAndJobAfterExit(long absoluteDeadlineQpc) {
            if (rootThreadHandle != IntPtr.Zero) {
                RequireTimeRemaining(absoluteDeadlineQpc, "CloseHandle root thread");
                if (!CloseHandle(rootThreadHandle)) throw Win32("CloseHandle root thread failed");
                rootThreadHandle = IntPtr.Zero;
            }
            if (rootProcessHandle != IntPtr.Zero) {
                WaitForRootExitUntil(absoluteDeadlineQpc);
                RequireTimeRemaining(absoluteDeadlineQpc, "CloseHandle root process");
                if (!CloseHandle(rootProcessHandle)) throw Win32("CloseHandle root process failed");
                rootProcessHandle = IntPtr.Zero;
            }
            if (rootProcess != null) {
                RequireTimeRemaining(absoluteDeadlineQpc, "managed root disposal");
                rootProcess.Dispose(); rootProcess = null;
            }
            long jobZeroQpcTicks = WaitForJobEmptyUntil(jobHandle, absoluteDeadlineQpc);
            RequireTimeRemaining(absoluteDeadlineQpc, "CloseHandle Job");
            if (!CloseHandle(jobHandle)) throw Win32("CloseHandle Job failed");
            jobHandle = IntPtr.Zero;
            containmentEmpty = true;
            WaitForOriginalProcessIdentityGoneUntil(rootProcessId, rootStartTimeUtcTicks, absoluteDeadlineQpc);
            reaped = true;
            return jobZeroQpcTicks;
        }

        public HardKillLiveTerminationReceipt TerminateLiveAndConfirm(long expectedProcessId, long expectedCreationTicks, SealedJobQpcDeadlines deadlines) {
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) throw new InvalidOperationException("A Job reap receipt was already produced.");
                if (!resumed) throw new InvalidOperationException("The suspended root cannot be terminated before the session resumes it.");
                ValidateDeadlines(deadlines);
                RequireTimeRemaining(deadlines.ControllerObservationDeadlineQpc, "hard-kill termination entry");
                ValidateExpectedIdentity(expectedProcessId, expectedCreationTicks, deadlines.ControllerObservationDeadlineQpc);
                bool rootAliveBefore = !RootIsSignaledUntil(deadlines.ControllerObservationDeadlineQpc);
                if (!rootAliveBefore) throw new InvalidOperationException("The exact root exited before live termination could be issued.");
                long activeBefore = GetActiveProcessCountUntil(jobHandle, deadlines.ControllerObservationDeadlineQpc);
                if (activeBefore <= 0) throw new InvalidOperationException("The retained Job was empty before live termination.");
                long terminationQpc = Stopwatch.GetTimestamp();
                if (terminationQpc >= deadlines.ControllerObservationDeadlineQpc)
                    throw new TimeoutException("The hard-kill termination point exceeded the immutable observation deadline.");
                long deadline = Math.Min(AddMillisecondsChecked(terminationQpc, ReviewedJobReapMilliseconds, deadlines.StopwatchFrequency),
                    deadlines.HardKillCumulativeReapDeadlineQpc);
                if (!TerminateJobObject(jobHandle, HardKillTerminationExitCode)) throw Win32("TerminateJobObject live termination failed");
                bool terminationIssued = true;
                WaitForRootExitUntil(deadline);
                uint exitCode = CaptureRootExitCodeUntil(deadline);
                if (exitCode != HardKillTerminationExitCode)
                    throw new InvalidOperationException("The exact root exit code does not prove controller live termination.");
                long jobZeroQpcTicks = CloseRootAndJobAfterExit(deadline);
                return new HardKillLiveTerminationReceipt(rootProcessId, rootStartTimeUtcTicks, deadline, jobZeroQpcTicks, 0L, true, true,
                    activeBefore, rootAliveBefore, unchecked((int)HardKillTerminationExitCode), terminationIssued, terminationQpc);
            }
        }

        public HardKillNaturalExitReceipt ConfirmNaturalExitAndClose(long expectedProcessId, long expectedCreationTicks, SealedJobQpcDeadlines deadlines) {
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) throw new InvalidOperationException("A Job reap receipt was already produced.");
                if (!resumed) throw new InvalidOperationException("The suspended root cannot exit before the session resumes it.");
                ValidateDeadlines(deadlines);
                ValidateExpectedIdentity(expectedProcessId, expectedCreationTicks, deadlines.WorkerDeadlineQpc);
                WaitForRootExitUntil(deadlines.WorkerDeadlineQpc);
                long rootExitQpc = Stopwatch.GetTimestamp();
                if (rootExitQpc > deadlines.WorkerDeadlineQpc)
                    throw new TimeoutException("The exact root natural exit was observed after the immutable worker deadline.");
                long deadline = Math.Min(AddMillisecondsChecked(rootExitQpc, ReviewedJobReapMilliseconds, deadlines.StopwatchFrequency),
                    deadlines.NaturalReleaseCumulativeReapDeadlineQpc);
                uint exitCode = CaptureRootExitCodeUntil(deadline);
                if (exitCode != 0U) throw new InvalidOperationException("The exact root did not exit naturally with the reviewed zero exit code.");
                long jobZeroQpcTicks = CloseRootAndJobAfterExit(deadline);
                return new HardKillNaturalExitReceipt(rootProcessId, rootStartTimeUtcTicks, deadline, jobZeroQpcTicks, 0L, true, true,
                    unchecked((int)exitCode), rootExitQpc, false);
            }
        }

        internal HardKillFailureCleanupReceipt ContainFailure(Exception primary, SealedJobQpcDeadlines deadlines, long absoluteCapQpcTicks) {
            if (primary == null) throw new ArgumentNullException("primary");
            lock (gate) {
                bool terminationIssued = false;
                long terminationQpc = 0L;
                long rootExitQpc = 0L;
                long reapDeadline = absoluteCapQpcTicks;
                long jobZeroQpcTicks = 0L;
                try {
                    if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                    if (reaped) throw new InvalidOperationException("A Job reap receipt was already produced.");
                    ValidateDeadlines(deadlines);
                    if (absoluteCapQpcTicks != deadlines.HardKillCumulativeReapDeadlineQpc &&
                        absoluteCapQpcTicks != deadlines.NaturalReleaseCumulativeReapDeadlineQpc)
                        throw new InvalidOperationException("The failure-containment cap is not one of the immutable prelaunch mode caps.");
                    if (RemainingMilliseconds(absoluteCapQpcTicks) <= 0)
                        throw new TimeoutException("The failure-containment absolute cap elapsed before cleanup entry.");
                    if (!containmentEmpty) {
                        bool rootExited = RootIsSignaledUntil(absoluteCapQpcTicks);
                        uint active = GetActiveProcessCountUntil(jobHandle, absoluteCapQpcTicks);
                        if (!rootExited || active > 0U) {
                            if (!rootExited && active == 0U)
                                throw new InvalidOperationException("The retained root was live while its Job reported zero active processes.");
                            terminationQpc = Stopwatch.GetTimestamp();
                            RequireTimeRemaining(absoluteCapQpcTicks, "failure-containment termination");
                            if (!TerminateJobObject(jobHandle, HardKillTerminationExitCode))
                                throw Win32("TerminateJobObject failure containment failed");
                            terminationIssued = true;
                        }
                        WaitForRootExitUntil(absoluteCapQpcTicks);
                        rootExitQpc = Stopwatch.GetTimestamp();
                        reapDeadline = Math.Min(AddMillisecondsChecked(terminationIssued ? terminationQpc : rootExitQpc,
                            ReviewedJobReapMilliseconds, deadlines.StopwatchFrequency), absoluteCapQpcTicks);
                        CaptureRootExitCodeUntil(reapDeadline);
                        jobZeroQpcTicks = CloseRootAndJobAfterExit(reapDeadline);
                    }
                }
                catch (Exception error) {
                    FailStop("Job failure containment could not prove zero/close/identity-gone", new AggregateException(primary, error));
                }
                return new HardKillFailureCleanupReceipt(rootProcessId, rootStartTimeUtcTicks, reapDeadline, jobZeroQpcTicks, 0L, true, true,
                    absoluteCapQpcTicks, primary.GetType().FullName, rootExitQpc, terminationIssued, terminationQpc);
            }
        }

        internal void TerminateForLegacy(int timeoutMilliseconds) {
            if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            lock (gate) {
                if (legacyTerminationFailureOperation != null) throw CreateLegacyTerminationFailure();
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) return;
                if (!legacyReapDeadlineBound) {
                    legacyReapDeadlineQpc = AddMillisecondsChecked(Stopwatch.GetTimestamp(), ReviewedLegacyReapMilliseconds, Stopwatch.Frequency);
                    legacyReapDeadlineBound = true;
                }
                long deadline = legacyReapDeadlineQpc;
                RequireTimeRemaining(deadline, "legacy Job reap entry");
                if (!resumed) ResumeRoot();
                uint active = GetActiveProcessCountUntil(jobHandle, deadline);
                if (active > 0U && legacyTerminationAttemptCount == 0) {
                    legacyTerminationAttemptCount = 1;
                    if (!TerminateJobObject(jobHandle, HardKillTerminationExitCode)) {
                        legacyTerminationNativeErrorCode = Marshal.GetLastWin32Error();
                        legacyTerminationFailureOperation = "TerminateJobObject legacy containment failed";
                        throw CreateLegacyTerminationFailure();
                    }
                }
                if (rootProcessHandle != IntPtr.Zero) {
                    WaitForRootExitUntil(deadline);
                    CaptureRootExitCodeUntil(deadline);
                }
                CloseRootAndJobAfterExit(deadline);
            }
        }

        public void Dispose() {
            lock (gate) {
                if (disposed) return;
                if (!containmentEmpty) FailStop("Dispose was called before Job ActiveProcesses reached zero", null);
                if (!reaped) throw new InvalidOperationException("The empty Job lease cannot be disposed before exact root identity disappearance is confirmed.");
                if (rootThreadHandle != IntPtr.Zero) { CloseHandle(rootThreadHandle); rootThreadHandle = IntPtr.Zero; }
                if (jobHandle != IntPtr.Zero) { CloseHandle(jobHandle); jobHandle = IntPtr.Zero; }
                disposed = true;
            }
        }
    }

    public sealed class SealedJobQpcDeadlines {
        internal const int ReviewedWorkerWaitMilliseconds = 420000;
        internal const int ReviewedControllerObservationMilliseconds = 300000;
        internal const int ReviewedJobReapMilliseconds = 30000;
        internal const int ReviewedCleanupMilliseconds = 30000;
        private readonly int workerWaitMilliseconds;
        private readonly int controllerObservationMilliseconds;
        private readonly int jobReapMilliseconds;
        private readonly int cleanupMilliseconds;
        private readonly long stopwatchFrequency;
        private readonly long controllerQpcTicks;
        private readonly long workerDeadlineQpc;
        private readonly long controllerObservationDeadlineQpc;
        private readonly long hardKillCumulativeReapDeadlineQpc;
        private readonly long hardKillCumulativeCleanupDeadlineQpc;
        private readonly long naturalReleaseCumulativeReapDeadlineQpc;
        private readonly long naturalReleaseCumulativeCleanupDeadlineQpc;
        private readonly string selectorHash;

        internal SealedJobQpcDeadlines(int workerWait, int observationWait, int jobReap, int cleanup,
            long frequency, long controllerTicks, long workerDeadline, long observationDeadline,
            long hardReapDeadline, long hardCleanupDeadline, long naturalReapDeadline, long naturalCleanupDeadline,
            string selector) {
            if (workerWait != ReviewedWorkerWaitMilliseconds || observationWait != ReviewedControllerObservationMilliseconds ||
                jobReap != ReviewedJobReapMilliseconds || cleanup != ReviewedCleanupMilliseconds)
                throw new ArgumentException("The sealed Job deadline budgets differ from the reviewed constants.");
            if (frequency <= 0 || controllerTicks <= 0 || workerDeadline <= controllerTicks || observationDeadline <= controllerTicks ||
                hardReapDeadline <= observationDeadline || hardCleanupDeadline <= hardReapDeadline ||
                naturalReapDeadline <= workerDeadline || naturalCleanupDeadline <= naturalReapDeadline ||
                String.IsNullOrEmpty(selector) ||
                !System.Text.RegularExpressions.Regex.IsMatch(selector, "^[0-9a-f]{64}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                throw new ArgumentException("The sealed Job deadline object has invalid immutable values.");
            workerWaitMilliseconds = workerWait;
            controllerObservationMilliseconds = observationWait;
            jobReapMilliseconds = jobReap;
            cleanupMilliseconds = cleanup;
            stopwatchFrequency = frequency;
            controllerQpcTicks = controllerTicks;
            workerDeadlineQpc = workerDeadline;
            controllerObservationDeadlineQpc = observationDeadline;
            hardKillCumulativeReapDeadlineQpc = hardReapDeadline;
            hardKillCumulativeCleanupDeadlineQpc = hardCleanupDeadline;
            naturalReleaseCumulativeReapDeadlineQpc = naturalReapDeadline;
            naturalReleaseCumulativeCleanupDeadlineQpc = naturalCleanupDeadline;
            selectorHash = selector;
        }

        public int WorkerWaitMilliseconds { get { return workerWaitMilliseconds; } }
        public int ControllerObservationMilliseconds { get { return controllerObservationMilliseconds; } }
        public int JobReapMilliseconds { get { return jobReapMilliseconds; } }
        public int CleanupMilliseconds { get { return cleanupMilliseconds; } }
        public long StopwatchFrequency { get { return stopwatchFrequency; } }
        public long ControllerQpcTicks { get { return controllerQpcTicks; } }
        public long WorkerDeadlineQpc { get { return workerDeadlineQpc; } }
        public long ControllerObservationDeadlineQpc { get { return controllerObservationDeadlineQpc; } }
        public long HardKillCumulativeReapDeadlineQpc { get { return hardKillCumulativeReapDeadlineQpc; } }
        public long HardKillCumulativeCleanupDeadlineQpc { get { return hardKillCumulativeCleanupDeadlineQpc; } }
        public long NaturalReleaseCumulativeReapDeadlineQpc { get { return naturalReleaseCumulativeReapDeadlineQpc; } }
        public long NaturalReleaseCumulativeCleanupDeadlineQpc { get { return naturalReleaseCumulativeCleanupDeadlineQpc; } }
        public string SelectorHash { get { return selectorHash; } }
    }

    public abstract class HardKillJobReapReceipt {
        private readonly long pid;
        private readonly long rootCreationFileTimeTicks;
        private readonly long reapDeadlineQpcTicks;
        private readonly long activeAfter;
        private readonly bool jobHandleClosed;
        private readonly bool identityGone;
        private readonly long jobZeroQpcTicks;

        internal HardKillJobReapReceipt(long processId, long creationTicks, long deadline, long zeroQpcTicks, long active, bool jobClosed,
            bool exactIdentityGone) {
            if (processId <= 0 || creationTicks <= 0 || deadline <= 0 || zeroQpcTicks <= 0 || zeroQpcTicks > deadline ||
                active != 0L || !jobClosed || !exactIdentityGone)
                throw new ArgumentException("The Job reap receipt does not prove exact zero/close/identity-gone containment.");
            pid = processId;
            rootCreationFileTimeTicks = creationTicks;
            reapDeadlineQpcTicks = deadline;
            activeAfter = active;
            jobHandleClosed = jobClosed;
            identityGone = exactIdentityGone;
            jobZeroQpcTicks = zeroQpcTicks;
        }

        public long Pid { get { return pid; } }
        public long RootCreationFileTimeTicks { get { return rootCreationFileTimeTicks; } }
        public long ReapDeadlineQpcTicks { get { return reapDeadlineQpcTicks; } }
        public long ActiveAfter { get { return activeAfter; } }
        public bool JobHandleClosed { get { return jobHandleClosed; } }
        public bool IdentityGone { get { return identityGone; } }
        public long JobZeroQpcTicks { get { return jobZeroQpcTicks; } }
    }

    public sealed class HardKillLiveTerminationReceipt : HardKillJobReapReceipt {
        private readonly long activeBefore;
        private readonly bool rootAliveBefore;
        private readonly int terminationExitCode;
        private readonly bool terminationIssued;
        private readonly long terminationQpcTicks;

        internal HardKillLiveTerminationReceipt(long pid, long creation, long deadline, long zeroQpcTicks, long activeAfter, bool jobClosed,
            bool identityGone, long before, bool aliveBefore, int exitCode, bool issued, long terminationTicks)
            : base(pid, creation, deadline, zeroQpcTicks, activeAfter, jobClosed, identityGone) {
            if (before <= 0L || !aliveBefore || exitCode != unchecked((int)0xC000042D) || !issued ||
                terminationTicks <= 0L || zeroQpcTicks < terminationTicks)
                throw new ArgumentException("The live-termination receipt fields do not prove the exact reviewed termination.");
            activeBefore = before;
            rootAliveBefore = aliveBefore;
            terminationExitCode = exitCode;
            terminationIssued = issued;
            terminationQpcTicks = terminationTicks;
        }

        public long ActiveBefore { get { return activeBefore; } }
        public bool RootAliveBefore { get { return rootAliveBefore; } }
        public int TerminationExitCode { get { return terminationExitCode; } }
        public bool TerminationIssued { get { return terminationIssued; } }
        public long TerminationQpcTicks { get { return terminationQpcTicks; } }
    }

    public sealed class HardKillNaturalExitReceipt : HardKillJobReapReceipt {
        private readonly int rootExitCode;
        private readonly long rootExitQpcTicks;
        private readonly bool terminationIssued;

        internal HardKillNaturalExitReceipt(long pid, long creation, long deadline, long zeroQpcTicks, long activeAfter, bool jobClosed,
            bool identityGone, int exitCode, long exitTicks, bool issued)
            : base(pid, creation, deadline, zeroQpcTicks, activeAfter, jobClosed, identityGone) {
            if (exitCode != 0 || exitTicks <= 0L || issued || zeroQpcTicks < exitTicks)
                throw new ArgumentException("The natural-exit receipt fields do not prove an exact zero-code natural release.");
            rootExitCode = exitCode;
            rootExitQpcTicks = exitTicks;
            terminationIssued = issued;
        }

        public int RootExitCode { get { return rootExitCode; } }
        public long RootExitQpcTicks { get { return rootExitQpcTicks; } }
        public bool TerminationIssued { get { return terminationIssued; } }
    }

    public sealed class HardKillFailureCleanupReceipt : HardKillJobReapReceipt {
        private readonly long absoluteCapQpcTicks;
        private readonly string failureMode;
        private readonly long rootExitQpcTicks;
        private readonly bool terminationIssued;
        private readonly long terminationQpcTicks;

        internal HardKillFailureCleanupReceipt(long pid, long creation, long deadline, long zeroQpcTicks, long activeAfter, bool jobClosed,
            bool identityGone, long absoluteCap, string mode, long exitTicks, bool issued, long terminationTicks)
            : base(pid, creation, deadline, zeroQpcTicks, activeAfter, jobClosed, identityGone) {
            if (absoluteCap <= 0L || deadline > absoluteCap || String.IsNullOrEmpty(mode) || exitTicks <= 0L ||
                (issued && terminationTicks <= 0L) || (!issued && terminationTicks != 0L) ||
                (issued && zeroQpcTicks < terminationTicks) || zeroQpcTicks < exitTicks)
                throw new ArgumentException("The failure-cleanup receipt fields do not prove bounded containment.");
            absoluteCapQpcTicks = absoluteCap;
            failureMode = mode;
            rootExitQpcTicks = exitTicks;
            terminationIssued = issued;
            terminationQpcTicks = terminationTicks;
        }

        public long AbsoluteCapQpcTicks { get { return absoluteCapQpcTicks; } }
        public string FailureMode { get { return failureMode; } }
        public long RootExitQpcTicks { get { return rootExitQpcTicks; } }
        public bool TerminationIssued { get { return terminationIssued; } }
        public long TerminationQpcTicks { get { return terminationQpcTicks; } }
    }

    public sealed class HardKillSealedMutationHostSession {
        private readonly HardKillJobProcess jobProcess;
        private readonly HardKillSealedMutationControllerScope controllerScope;
        private readonly SealedJobQpcDeadlines deadlines;
        private readonly string reapMode;
        private readonly long failureCleanupAbsoluteCapQpcTicks;
        private bool isResumed;
        private bool closed;
        private HardKillJobReapReceipt reapReceipt;

        private HardKillSealedMutationHostSession(HardKillJobProcess job, HardKillSealedMutationControllerScope scope) {
            jobProcess = job;
            controllerScope = scope;
            deadlines = scope.Deadlines;
            reapMode = scope.ReapMode;
            failureCleanupAbsoluteCapQpcTicks = scope.FailureCleanupAbsoluteCapQpcTicks;
        }

        public static HardKillSealedMutationHostSession Acquire(string hostPath, string enginePath, HardKillSealedMutationControllerScope scope) {
            if (scope == null) throw new ArgumentNullException("scope");
            string host = Path.GetFullPath(hostPath);
            string engine = Path.GetFullPath(enginePath);
            if (!File.Exists(host) || !File.Exists(engine)) throw new FileNotFoundException("The sealed host or engine path is missing.");
            string executable = Process.GetCurrentProcess().MainModule.FileName;
            string[] arguments = scope.BuildHostArguments(host, engine);
            HardKillJobProcess job = HardKillJobProcess.Start(executable, arguments, scope.StdoutPath, scope.StderrPath);
            try { return new HardKillSealedMutationHostSession(job, scope); }
            catch {
                job.ContainFailure(new InvalidOperationException("Session construction failed after suspended launch."), scope.Deadlines, scope.FailureCleanupAbsoluteCapQpcTicks);
                job.Dispose();
                throw;
            }
        }

        public HardKillJobReapReceipt AcceptReapReceipt(HardKillJobReapReceipt receipt) {
            if (receipt == null) throw new ArgumentNullException("receipt");
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationHostSession");
            if (reapReceipt != null) throw new InvalidOperationException("The session already accepted a reap receipt.");
            if (!Object.ReferenceEquals(receipt.GetType().Assembly, GetType().Assembly) || receipt.Pid != ProcessId ||
                receipt.RootCreationFileTimeTicks != RootCreationFileTimeTicks || receipt.ActiveAfter != 0L ||
                !receipt.JobHandleClosed || !receipt.IdentityGone) throw new InvalidOperationException("The reap receipt does not prove this exact session reached zero/close/identity-gone.");
            reapReceipt = receipt;
            return receipt;
        }

        public void Resume() {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationHostSession");
            if (isResumed) throw new InvalidOperationException("The sealed host session can only be resumed once.");
            jobProcess.ResumeRoot();
            isResumed = true;
        }

        public HardKillFailureCleanupReceipt ContainFailure(Exception primary, SealedJobQpcDeadlines expectedDeadlines, long absoluteCapQpcTicks) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationHostSession");
            if (reapReceipt != null) throw new InvalidOperationException("The session already has a reap receipt.");
            if (!Object.ReferenceEquals(deadlines, expectedDeadlines) || absoluteCapQpcTicks != failureCleanupAbsoluteCapQpcTicks)
                throw new InvalidOperationException("Failure containment deadlines or absolute cap differ from the acquired session.");
            return jobProcess.ContainFailure(primary, deadlines, absoluteCapQpcTicks);
        }

        public bool Close() {
            if (closed) return true;
            if (reapReceipt == null) throw new InvalidOperationException("The sealed session cannot close without an accepted reap receipt.");
            jobProcess.Dispose();
            closed = true;
            return true;
        }

        public bool Closed { get { return closed; } }
        public SealedJobQpcDeadlines Deadlines { get { return deadlines; } }
        public bool HasReapReceipt { get { return reapReceipt != null; } }
        public long FailureCleanupAbsoluteCapQpcTicks { get { return failureCleanupAbsoluteCapQpcTicks; } }
        public bool IsResumed { get { return isResumed; } }
        public HardKillJobProcess JobProcess { get { return jobProcess; } }
        public Process Process { get { return jobProcess.Process; } }
        public long ProcessId { get { return jobProcess.ProcessId; } }
        public string ReapMode { get { return reapMode; } }
        public HardKillJobReapReceipt ReapReceipt { get { return reapReceipt; } }
        public long RootCreationFileTimeTicks { get { return jobProcess.RootCreationFileTimeTicks; } }
    }

    public sealed class HardKillSealedMutationControllerScope {
        private sealed class ControllerStageCapture : IDisposable {
            private SafeFileHandle handle;
            internal readonly string Identity;
            internal readonly long Length;
            internal readonly string RawSha256;
            internal readonly byte[] Bytes;
            internal ControllerStageCapture(SafeFileHandle value, string identity, byte[] bytes) {
                handle = value; Identity = identity; Bytes = bytes; Length = bytes.LongLength;
                RawSha256 = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
            }
            public void Dispose() { if (handle != null) { handle.Dispose(); handle = null; } }
        }

        private sealed class ControllerStageOwner {
            [StructLayout(LayoutKind.Sequential)] private struct UNICODE_STRING { internal ushort Length; internal ushort MaximumLength; internal IntPtr Buffer; }
            [StructLayout(LayoutKind.Sequential)] private struct OBJECT_ATTRIBUTES { internal int Length; internal IntPtr RootDirectory; internal IntPtr ObjectName; internal uint Attributes; internal IntPtr SecurityDescriptor; internal IntPtr SecurityQualityOfService; }
            [StructLayout(LayoutKind.Sequential)] private struct IO_STATUS_BLOCK { internal IntPtr Status; internal UIntPtr Information; }
            [StructLayout(LayoutKind.Sequential)] private struct BY_HANDLE_FILE_INFORMATION {
                internal uint FileAttributes; internal System.Runtime.InteropServices.ComTypes.FILETIME CreationTime;
                internal System.Runtime.InteropServices.ComTypes.FILETIME LastAccessTime; internal System.Runtime.InteropServices.ComTypes.FILETIME LastWriteTime;
                internal uint VolumeSerialNumber; internal uint FileSizeHigh; internal uint FileSizeLow; internal uint NumberOfLinks; internal uint FileIndexHigh; internal uint FileIndexLow;
            }
            [StructLayout(LayoutKind.Sequential)] private struct SECURITY_ATTRIBUTES { internal int Length; internal IntPtr SecurityDescriptor; [MarshalAs(UnmanagedType.Bool)] internal bool InheritHandle; }

            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateFileW(string name, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern IntPtr CreateEventW(ref SECURITY_ATTRIBUTES attributes, [MarshalAs(UnmanagedType.Bool)] bool manualReset, [MarshalAs(UnmanagedType.Bool)] bool initialState, string name);
            [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION information);
            [DllImport("kernel32.dll", SetLastError = true)] private static extern bool ReadFile(SafeFileHandle handle, byte[] buffer, uint count, out uint read, IntPtr overlapped);
            [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetFilePointerEx(SafeFileHandle handle, long distance, out long position, uint method);
            [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetFileInformationByHandle(SafeFileHandle handle, int informationClass, IntPtr information, uint size);
            [DllImport("ntdll.dll")] private static extern int NtCreateFile(out IntPtr handle, uint access, ref OBJECT_ATTRIBUTES attributes,
                out IO_STATUS_BLOCK status, IntPtr allocationSize, uint fileAttributes, uint share, uint disposition, uint options, IntPtr ea, uint eaLength);
            [DllImport("ntdll.dll")] private static extern int NtQueryDirectoryFile(SafeFileHandle handle, IntPtr eventHandle, IntPtr apcRoutine,
                IntPtr apcContext, out IO_STATUS_BLOCK status, IntPtr information, uint length, int informationClass,
                [MarshalAs(UnmanagedType.Bool)] bool returnSingleEntry, IntPtr fileName, [MarshalAs(UnmanagedType.Bool)] bool restartScan);
            [DllImport("ntdll.dll")] private static extern int NtQueryInformationFile(SafeFileHandle handle, out IO_STATUS_BLOCK status,
                IntPtr information, uint length, int informationClass);
            [DllImport("ntdll.dll")] private static extern int RtlNtStatusToDosError(int status);
            [DllImport("advapi32.dll", SetLastError = true)] private static extern bool GetKernelObjectSecurity(SafeFileHandle handle,
                int requestedInformation, byte[] securityDescriptor, uint length, out uint needed);

            private const uint FILE_LIST_DIRECTORY = 0x00000001;
            private const uint FILE_READ_DATA = 0x00000001;
            private const uint FILE_READ_ATTRIBUTES = 0x00000080;
            private const uint READ_CONTROL = 0x00020000;
            private const uint DELETE_ = 0x00010000;
            private const uint SYNCHRONIZE = 0x00100000;
            private const uint FILE_SHARE_READ = 1, FILE_SHARE_WRITE = 2, FILE_SHARE_DELETE = 4;
            private const uint OPEN_EXISTING = 3;
            private const uint FILE_ATTRIBUTE_DIRECTORY = 0x10, FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
            private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000, FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
            private const uint FILE_CREATE = 2, FILE_OPEN = 1, FILE_CREATED = 2;
            private const uint FILE_DIRECTORY_FILE = 1, FILE_NON_DIRECTORY_FILE = 0x40, FILE_OPEN_REPARSE_POINT = 0x00200000, FILE_SYNCHRONOUS_IO_NONALERT = 0x20;
            private const uint OBJ_CASE_INSENSITIVE = 0x40;
            private const int FileDispositionInfo = 4, FileNamesInformation = 12, FileStreamInformation = 22;
            private const int OWNER_SECURITY_INFORMATION = 1, DACL_SECURITY_INFORMATION = 4;
            private const int ERROR_FILE_NOT_FOUND = 2, ERROR_PATH_NOT_FOUND = 3, ERROR_ALREADY_EXISTS = 183;
            private const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);
            private static readonly IntPtr InvalidHandle = new IntPtr(-1);

            private readonly List<SafeFileHandle> tempChain;
            private SafeFileHandle root;
            private readonly SafeFileHandle tempParent;
            private readonly string rootLeaf;
            internal readonly string RootPath;
            internal readonly string RootIdentity;
            internal readonly string TempLeaf;
            internal readonly string FinalLeaf;
            private bool cleaned;

            private ControllerStageOwner(List<SafeFileHandle> chain, SafeFileHandle stageRoot, string leaf, string path, string identity, string tempLeaf, string finalLeaf) {
                tempChain = chain; tempParent = chain[chain.Count - 1]; root = stageRoot; rootLeaf = leaf;
                RootPath = path; RootIdentity = identity; TempLeaf = tempLeaf; FinalLeaf = finalLeaf;
            }

            private static byte[] CurrentUserProtectedSecurityDescriptor() {
                string sid = WindowsIdentity.GetCurrent().User.Value;
                RawSecurityDescriptor descriptor = new RawSecurityDescriptor("O:" + sid + "G:" + sid + "D:P(A;OICI;GA;;;" + sid + ")");
                byte[] bytes = new byte[descriptor.BinaryLength]; descriptor.GetBinaryForm(bytes, 0); return bytes;
            }

            internal static EventWaitHandle CreateManualResetEvent(string name) {
                byte[] descriptor = CurrentUserProtectedSecurityDescriptor(); GCHandle pin = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
                try {
                    SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES { Length = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES)), SecurityDescriptor = pin.AddrOfPinnedObject(), InheritHandle = false };
                    Marshal.GetLastWin32Error(); IntPtr raw = CreateEventW(ref attributes, true, false, name); int error = Marshal.GetLastWin32Error();
                    if (raw == IntPtr.Zero) throw new Win32Exception(error, "creating protected named event failed");
                    if (error == ERROR_ALREADY_EXISTS) { new SafeWaitHandle(raw, true).Dispose(); throw new IOException("The protected named event already exists."); }
                    EventWaitHandle result = new EventWaitHandle(false, EventResetMode.ManualReset); result.SafeWaitHandle = new SafeWaitHandle(raw, true); return result;
                } finally { pin.Free(); }
            }

            private static SafeFileHandle OpenHeldDirectory(string path) {
                IntPtr raw = CreateFileW(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE,
                    IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
                if (raw == InvalidHandle) throw new Win32Exception(Marshal.GetLastWin32Error(), "opening held TEMP containment directory failed");
                SafeFileHandle handle = new SafeFileHandle(raw, true); try { RequireDirectory(handle); return handle; } catch { handle.Dispose(); throw; }
            }

            private static SafeFileHandle OpenHeldDirectoryRelative(SafeFileHandle parent, string leaf) {
                UIntPtr ignored; SafeFileHandle handle = OpenRelative(parent, leaf, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | SYNCHRONIZE,
                    FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_OPEN,
                    FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, IntPtr.Zero, out ignored);
                try { RequireDirectory(handle); return handle; } catch { handle.Dispose(); throw; }
            }

            private static void RequireDirectory(SafeFileHandle handle) {
                BY_HANDLE_FILE_INFORMATION info; if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error(), "reading held directory identity failed");
                if ((info.FileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 || (info.FileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0 || info.NumberOfLinks != 1U)
                    throw new InvalidOperationException("Held stage containment is not one ordinary non-reparse directory identity.");
            }

            private static string Identity(SafeFileHandle handle) {
                BY_HANDLE_FILE_INFORMATION info; if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error(), "reading stage identity failed");
                ulong index = ((ulong)info.FileIndexHigh << 32) | info.FileIndexLow;
                return info.VolumeSerialNumber.ToString("x8", CultureInfo.InvariantCulture) + ":" + index.ToString("x16", CultureInfo.InvariantCulture);
            }

            private static void RequireProtectedOwnerDacl(SafeFileHandle handle) {
                uint needed; GetKernelObjectSecurity(handle, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, null, 0U, out needed);
                if (needed == 0U) throw new Win32Exception(Marshal.GetLastWin32Error(), "querying stage root security length failed");
                byte[] bytes = new byte[needed];
                if (!GetKernelObjectSecurity(handle, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION, bytes, needed, out needed))
                    throw new Win32Exception(Marshal.GetLastWin32Error(), "querying stage root security failed");
                RawSecurityDescriptor descriptor = new RawSecurityDescriptor(bytes, 0);
                SecurityIdentifier current = WindowsIdentity.GetCurrent().User;
                if (!current.Equals(descriptor.Owner) || (descriptor.ControlFlags & ControlFlags.DiscretionaryAclProtected) == 0 ||
                    descriptor.DiscretionaryAcl == null || descriptor.DiscretionaryAcl.Count != 1)
                    throw new InvalidOperationException("The stage root owner/protected DACL is not exact.");
                CommonAce ace = descriptor.DiscretionaryAcl[0] as CommonAce;
                if (ace == null || ace.AceType != AceType.AccessAllowed || ace.IsInherited || !current.Equals(ace.SecurityIdentifier) ||
                    ace.AccessMask != 0x001F01FF || (ace.AceFlags & (AceFlags.ContainerInherit | AceFlags.ObjectInherit)) !=
                    (AceFlags.ContainerInherit | AceFlags.ObjectInherit))
                    throw new InvalidOperationException("The stage root DACL has a foreign, inherited, or noncanonical ACE.");
            }

            private static List<string> Inventory(SafeFileHandle directory) {
                List<string> names = new List<string>(); IntPtr buffer = Marshal.AllocHGlobal(65536); bool restart = true;
                try {
                    while (true) {
                        IO_STATUS_BLOCK status; int result = NtQueryDirectoryFile(directory, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                            out status, buffer, 65536U, FileNamesInformation, true, IntPtr.Zero, restart);
                        restart = false;
                        if (result == STATUS_NO_MORE_FILES) break;
                        if (result < 0) throw new Win32Exception(RtlNtStatusToDosError(result), "held stage inventory query failed");
                        int nameLength = Marshal.ReadInt32(buffer, 8);
                        if (nameLength < 0 || (nameLength & 1) != 0 || nameLength > 65524) throw new InvalidOperationException("Held stage inventory row is malformed.");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, 12), nameLength / 2);
                        if (name != "." && name != "..") names.Add(name);
                    }
                    return names;
                } finally { Marshal.FreeHGlobal(buffer); }
            }

            private static void RequireOnlyDefaultStream(SafeFileHandle handle, bool permitNone) {
                IntPtr buffer = Marshal.AllocHGlobal(65536);
                try {
                    IO_STATUS_BLOCK status; int result = NtQueryInformationFile(handle, out status, buffer, 65536U, FileStreamInformation);
                    if (result < 0) throw new Win32Exception(RtlNtStatusToDosError(result), "held stage stream query failed");
                    ulong used = status.Information.ToUInt64();
                    if (used == 0UL) { if (permitNone) return; throw new InvalidOperationException("The stage final has no default stream."); }
                    int offset = 0, count = 0;
                    while (true) {
                        if ((ulong)(offset + 24) > used) throw new InvalidOperationException("Held stage stream information is truncated.");
                        int next = Marshal.ReadInt32(buffer, offset); int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 || (ulong)(offset + 24 + nameLength) > used) throw new InvalidOperationException("Held stage stream row is malformed.");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 24), nameLength / 2);
                        count++; if (!String.Equals(name, "::$DATA", StringComparison.Ordinal)) throw new InvalidOperationException("The held stage object has an alternate data stream.");
                        if (next == 0) break; if (next < 24 || offset > 65536 - next) throw new InvalidOperationException("Held stage stream chain is malformed."); offset += next;
                    }
                    if (count != 1) throw new InvalidOperationException("The held stage object stream inventory is ambiguous.");
                } finally { Marshal.FreeHGlobal(buffer); }
            }

            private static SafeFileHandle OpenRelative(SafeFileHandle parent, string leaf, uint access, uint share, uint disposition, uint options, IntPtr securityDescriptor, out UIntPtr information) {
                IntPtr name = IntPtr.Zero, unicodeBuffer = IntPtr.Zero; bool parentRef = false;
                try {
                    name = Marshal.StringToHGlobalUni(leaf); UNICODE_STRING unicode = new UNICODE_STRING { Length = checked((ushort)(leaf.Length * 2)), MaximumLength = checked((ushort)((leaf.Length + 1) * 2)), Buffer = name };
                    unicodeBuffer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UNICODE_STRING))); Marshal.StructureToPtr(unicode, unicodeBuffer, false);
                    parent.DangerousAddRef(ref parentRef); OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES { Length = Marshal.SizeOf(typeof(OBJECT_ATTRIBUTES)), RootDirectory = parent.DangerousGetHandle(), ObjectName = unicodeBuffer, Attributes = OBJ_CASE_INSENSITIVE, SecurityDescriptor = securityDescriptor };
                    IO_STATUS_BLOCK status; IntPtr raw; int result = NtCreateFile(out raw, access, ref attributes, out status, IntPtr.Zero, 0U, share, disposition, options, IntPtr.Zero, 0U);
                    if (result < 0) throw new Win32Exception(RtlNtStatusToDosError(result), "relative stage operation failed");
                    information = status.Information; return new SafeFileHandle(raw, true);
                } finally { if (parentRef) parent.DangerousRelease(); if (unicodeBuffer != IntPtr.Zero) Marshal.FreeHGlobal(unicodeBuffer); if (name != IntPtr.Zero) Marshal.FreeHGlobal(name); }
            }

            internal static ControllerStageOwner Create() {
                string temp = Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar); string volume = Path.GetPathRoot(temp);
                string remainder = temp.Substring(volume.Length).Trim(Path.DirectorySeparatorChar);
                List<SafeFileHandle> chain = new List<SafeFileHandle>(); SafeFileHandle stageRoot = null;
                try {
                    chain.Add(OpenHeldDirectory(volume));
                    foreach (string part in remainder.Split(new char[] { Path.DirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries))
                        chain.Add(OpenHeldDirectoryRelative(chain[chain.Count - 1], part));
                    string rootLeaf = "ai-agent-dotfiles-stage-" + Guid.NewGuid().ToString("N"); string rootPath = Path.Combine(temp, rootLeaf);
                    byte[] descriptor = CurrentUserProtectedSecurityDescriptor(); GCHandle pin = GCHandle.Alloc(descriptor, GCHandleType.Pinned);
                    try {
                        UIntPtr created; stageRoot = OpenRelative(chain[chain.Count - 1], rootLeaf,
                            FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES | DELETE_ | READ_CONTROL | SYNCHRONIZE,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_CREATE,
                            FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, pin.AddrOfPinnedObject(), out created);
                        if (created.ToUInt64() != FILE_CREATED) throw new IOException("The protected stage root was not atomically created as a new directory.");
                    } finally { pin.Free(); }
                    RequireDirectory(stageRoot); RequireProtectedOwnerDacl(stageRoot); RequireOnlyDefaultStream(stageRoot, true);
                    if (Inventory(stageRoot).Count != 0) throw new InvalidOperationException("The newly created held stage root is not empty.");
                    string identity = Identity(stageRoot);
                    ControllerStageOwner owner = new ControllerStageOwner(chain, stageRoot, rootLeaf, rootPath, identity,
                        "stage-" + Guid.NewGuid().ToString("N") + ".tmp", "stage-" + Guid.NewGuid().ToString("N") + ".json");
                    chain = null; stageRoot = null; return owner;
                } finally { if (stageRoot != null) stageRoot.Dispose(); if (chain != null) for (int index = chain.Count - 1; index >= 0; index--) chain[index].Dispose(); }
            }

            private SafeFileHandle OpenFile(string leaf, uint access, uint share) { UIntPtr ignored; return OpenRelative(root, leaf, access, share, FILE_OPEN, FILE_NON_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, IntPtr.Zero, out ignored); }

            private void RequireOwnedRoot() {
                if (cleaned || root == null || root.IsClosed || root.IsInvalid) throw new InvalidOperationException("The held controller stage root is unavailable.");
                RequireDirectory(root);
                if (!String.Equals(Identity(root), RootIdentity, StringComparison.Ordinal)) throw new InvalidOperationException("The held stage root identity drifted.");
                RequireProtectedOwnerDacl(root); RequireOnlyDefaultStream(root, true);
            }

            internal ControllerStageCapture CaptureFinal() {
                RequireOwnedRoot();
                List<string> children = Inventory(root); if (children.Count != 1 || !String.Equals(children[0], FinalLeaf, StringComparison.OrdinalIgnoreCase))
                    throw new InvalidOperationException("The held stage root does not contain the exact final singleton.");
                SafeFileHandle handle = OpenFile(FinalLeaf, FILE_READ_DATA | FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_READ);
                try {
                    BY_HANDLE_FILE_INFORMATION info; if (!GetFileInformationByHandle(handle, out info)) throw new Win32Exception(Marshal.GetLastWin32Error(), "reading stage final information failed");
                    if ((info.FileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) != 0 || info.NumberOfLinks != 1U) throw new InvalidOperationException("The stage final is not one ordinary file identity.");
                    long length = ((long)info.FileSizeHigh << 32) | info.FileSizeLow; if (length <= 0L || length > Int32.MaxValue) throw new IOException("The stage final length is invalid.");
                    RequireOnlyDefaultStream(handle, false); long ignored; if (!SetFilePointerEx(handle, 0L, out ignored, 0U)) throw new Win32Exception(Marshal.GetLastWin32Error(), "seeking stage final failed");
                    byte[] bytes = new byte[(int)length]; int offset = 0; while (offset < bytes.Length) { byte[] part = new byte[bytes.Length - offset]; uint read; if (!ReadFile(handle, part, (uint)part.Length, out read, IntPtr.Zero) || read == 0U) throw new EndOfStreamException("The held stage final ended early."); Buffer.BlockCopy(part, 0, bytes, offset, (int)read); offset += (int)read; }
                    byte[] terminal = new byte[1]; uint trailing; if (!ReadFile(handle, terminal, 1U, out trailing, IntPtr.Zero) || trailing != 0U) throw new IOException("The held stage final has trailing bytes.");
                    ControllerStageCapture capture = new ControllerStageCapture(handle, Identity(handle), bytes); handle = null; return capture;
                } finally { if (handle != null) handle.Dispose(); }
            }

            private void RequireMissing(string leaf) {
                try { SafeFileHandle unexpected = OpenFile(leaf, FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE); unexpected.Dispose(); throw new InvalidOperationException("Unexpected stage child remains present: " + leaf); }
                catch (Win32Exception error) when (error.NativeErrorCode == ERROR_FILE_NOT_FOUND || error.NativeErrorCode == ERROR_PATH_NOT_FOUND) { }
            }

            private void DeleteExactFinal(string expectedIdentity) {
                SafeFileHandle target = OpenFile(FinalLeaf, FILE_READ_ATTRIBUTES | DELETE_ | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE);
                try { if (!String.Equals(Identity(target), expectedIdentity, StringComparison.Ordinal)) throw new InvalidOperationException("The stage final identity changed before cleanup."); IntPtr disposition = Marshal.AllocHGlobal(1); try { Marshal.WriteByte(disposition, 1); if (!SetFileInformationByHandle(target, FileDispositionInfo, disposition, 1U)) throw new Win32Exception(Marshal.GetLastWin32Error(), "identity-bound stage final deletion failed"); } finally { Marshal.FreeHGlobal(disposition); } }
                finally { target.Dispose(); }
            }

            internal void Cleanup(string expectedFinalIdentity, long absoluteDeadlineQpc) {
                if (cleaned) throw new InvalidOperationException("The controller stage root was already cleaned.");
                RequireTimeRemaining(absoluteDeadlineQpc, "held stage cleanup entry");
                RequireOwnedRoot();
                List<string> before = Inventory(root); if (before.Count != 1 || !String.Equals(before[0], FinalLeaf, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unexpected stage children preserve the forensic root.");
                RequireTimeRemaining(absoluteDeadlineQpc, "identity-bound stage final cleanup");
                RequireMissing(TempLeaf); DeleteExactFinal(expectedFinalIdentity); RequireMissing(FinalLeaf);
                if (Inventory(root).Count != 0) throw new InvalidOperationException("The held stage root is not empty after exact child cleanup.");
                RequireTimeRemaining(absoluteDeadlineQpc, "held stage root cleanup");
                IntPtr disposition = Marshal.AllocHGlobal(1); try { Marshal.WriteByte(disposition, 1); if (!SetFileInformationByHandle(root, FileDispositionInfo, disposition, 1U)) throw new Win32Exception(Marshal.GetLastWin32Error(), "held stage root disposition failed"); } finally { Marshal.FreeHGlobal(disposition); }
                root.Dispose(); root = null;
                UIntPtr ignored; try { SafeFileHandle rebound = OpenRelative(tempParent, rootLeaf, FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN, FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, IntPtr.Zero, out ignored); rebound.Dispose(); throw new InvalidOperationException("The disposed stage root remains present under held TEMP parent."); }
                catch (Win32Exception error) when (error.NativeErrorCode == ERROR_FILE_NOT_FOUND || error.NativeErrorCode == ERROR_PATH_NOT_FOUND) { }
                for (int index = tempChain.Count - 1; index >= 0; index--) tempChain[index].Dispose(); cleaned = true;
                RequireTimeRemaining(absoluteDeadlineQpc, "held stage cleanup completion");
            }

            internal void AbortEmptyBeforeLaunch() {
                if (cleaned) return;
                RequireOwnedRoot();
                if (Inventory(root).Count != 0) throw new InvalidOperationException("Prelaunch stage abort preserves a nonempty forensic root.");
                IntPtr disposition = Marshal.AllocHGlobal(1); try { Marshal.WriteByte(disposition, 1); if (!SetFileInformationByHandle(root, FileDispositionInfo, disposition, 1U)) throw new Win32Exception(Marshal.GetLastWin32Error(), "prelaunch stage root disposition failed"); } finally { Marshal.FreeHGlobal(disposition); }
                root.Dispose(); root = null; for (int index = tempChain.Count - 1; index >= 0; index--) tempChain[index].Dispose(); cleaned = true;
            }

            internal void CleanupEmpty(long absoluteDeadlineQpc) {
                if (cleaned) throw new InvalidOperationException("The controller stage root was already cleaned.");
                RequireTimeRemaining(absoluteDeadlineQpc, "empty stage cleanup entry");
                RequireOwnedRoot();
                if (Inventory(root).Count != 0) throw new InvalidOperationException("Natural-release cleanup preserves a nonempty forensic root.");
                RequireTimeRemaining(absoluteDeadlineQpc, "empty stage root disposition");
                IntPtr disposition = Marshal.AllocHGlobal(1); try { Marshal.WriteByte(disposition, 1); if (!SetFileInformationByHandle(root, FileDispositionInfo, disposition, 1U)) throw new Win32Exception(Marshal.GetLastWin32Error(), "empty stage root disposition failed"); } finally { Marshal.FreeHGlobal(disposition); }
                root.Dispose(); root = null;
                UIntPtr ignored; try { SafeFileHandle rebound = OpenRelative(tempParent, rootLeaf, FILE_READ_ATTRIBUTES | SYNCHRONIZE, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN, FILE_DIRECTORY_FILE | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, IntPtr.Zero, out ignored); rebound.Dispose(); throw new InvalidOperationException("The disposed empty stage root remains present under held TEMP parent."); }
                catch (Win32Exception error) when (error.NativeErrorCode == ERROR_FILE_NOT_FOUND || error.NativeErrorCode == ERROR_PATH_NOT_FOUND) { }
                for (int index = tempChain.Count - 1; index >= 0; index--) tempChain[index].Dispose(); cleaned = true;
                RequireTimeRemaining(absoluteDeadlineQpc, "empty stage cleanup completion");
            }

            internal void PreserveForensicAndCloseHandles() {
                if (cleaned) return;
                List<Exception> failures = new List<Exception>();
                try { if (root != null) { root.Dispose(); root = null; } } catch (Exception error) { failures.Add(error); }
                for (int index = tempChain.Count - 1; index >= 0; index--) { try { tempChain[index].Dispose(); } catch (Exception error) { failures.Add(error); } }
                cleaned = true;
                if (failures.Count == 1) throw failures[0];
                if (failures.Count > 1) throw new AggregateException("Forensic stage owner handles could not all be released.", failures);
            }

            internal void FailureCleanup(ControllerStageCapture capture, long absoluteDeadlineQpc) {
                if (cleaned) return;
                Exception primary = null;
                try {
                    RequireTimeRemaining(absoluteDeadlineQpc, "failure stage cleanup entry");
                    RequireOwnedRoot();
                    List<string> children = Inventory(root);
                    if (children.Count == 0) { AbortEmptyBeforeLaunch(); return; }
                    if (children.Count == 1 && String.Equals(children[0], FinalLeaf, StringComparison.OrdinalIgnoreCase)) {
                        string identity = capture == null ? null : capture.Identity;
                        if (identity == null) { ControllerStageCapture acquired = CaptureFinal(); try { identity = acquired.Identity; } finally { acquired.Dispose(); } }
                        Cleanup(identity, absoluteDeadlineQpc); return;
                    }
                    primary = new InvalidOperationException("Failure cleanup preserves a stage root with unexpected forensic children.");
                } catch (Exception error) { primary = error; }
                finally {
                    if (!cleaned) {
                        try { if (root != null) { root.Dispose(); root = null; } } catch (Exception error) { if (primary == null) primary = error; else primary = new AggregateException(primary, error); }
                        for (int index = tempChain.Count - 1; index >= 0; index--) { try { tempChain[index].Dispose(); } catch (Exception error) { if (primary == null) primary = error; else primary = new AggregateException(primary, error); } }
                        cleaned = true;
                    }
                }
                if (primary != null) throw primary;
            }
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct EventBasicInformation {
            internal int EventType;
            internal int EventState;
        }

        [DllImport("ntdll.dll")]
        private static extern int NtQueryEvent(IntPtr eventHandle, int eventInformationClass,
            out EventBasicInformation eventInformation, int eventInformationLength, out int returnLength);

        private readonly object caseDefinition;
        private readonly SealedJobQpcDeadlines deadlines;
        private readonly string reapMode;
        private readonly string invocationFixturePath;
        private readonly string stdoutPath;
        private readonly string stderrPath;
        private readonly string[] hostArguments;
        private readonly string observationPath;
        private readonly string postStatePath;
        private readonly string expectedEngineSha256;
        private readonly string invocationFixtureSha256;
        private readonly string expectedProbeHostSha256;
        private readonly EventWaitHandle stageReadyEvent;
        private readonly EventWaitHandle continueEvent;
        private readonly ControllerStageOwner stageOwner;
        private readonly object selectorWire;
        private readonly string selectorHash;
        private object exactObservation;
        private string exactObservationIdentity;
        private bool cleanupCompleted;
        private bool naturalReleaseSignaled;
        private bool closed;

        private HardKillSealedMutationControllerScope(object definition, SealedJobQpcDeadlines qpcDeadlines, string mode,
            string fixturePath, string outputPath, string errorPath, string[] arguments, string observePath, string afterPath,
            string engineSha256, string fixtureSha256, string hostSha256, EventWaitHandle readyEvent, EventWaitHandle releaseEvent,
            ControllerStageOwner owner, object selector, string selectorSha256) {
            caseDefinition = definition;
            deadlines = qpcDeadlines;
            reapMode = mode;
            invocationFixturePath = fixturePath;
            stdoutPath = outputPath;
            stderrPath = errorPath;
            hostArguments = arguments;
            observationPath = observePath;
            postStatePath = afterPath;
            expectedEngineSha256 = engineSha256;
            invocationFixtureSha256 = fixtureSha256;
            expectedProbeHostSha256 = hostSha256;
            stageReadyEvent = readyEvent;
            continueEvent = releaseEvent;
            stageOwner = owner;
            selectorWire = selector;
            selectorHash = selectorSha256;
        }

        private static object ReadValue(object source, string name) {
            if (source == null) return null;
            System.Collections.IDictionary dictionary = source as System.Collections.IDictionary;
            if (dictionary != null) {
                foreach (System.Collections.DictionaryEntry entry in dictionary)
                    if (String.Equals(Convert.ToString(entry.Key), name, StringComparison.Ordinal)) return entry.Value;
                return null;
            }
            System.Reflection.PropertyInfo property = source.GetType().GetProperty(name, System.Reflection.BindingFlags.Public | System.Reflection.BindingFlags.Instance);
            return property == null ? null : property.GetValue(source, null);
        }

        private static string RequiredString(object source, string name, bool path) {
            string value = Convert.ToString(ReadValue(source, name));
            if (String.IsNullOrWhiteSpace(value)) throw new ArgumentException("The selected sealed transport case is missing " + name + ".");
            return path ? Path.GetFullPath(value) : value;
        }

        private static int RequiredPositiveInt(object source, string name) {
            object value = ReadValue(source, name);
            int parsed;
            if (value == null || !Int32.TryParse(Convert.ToString(value), out parsed) || parsed <= 0)
                throw new ArgumentException("The selected sealed transport case has an invalid " + name + ".");
            return parsed;
        }

        private static long RequiredCanonicalPositiveInt64(object source, string name) {
            object raw = ReadValue(source, name);
            string text = raw == null ? null : Convert.ToString(raw, CultureInfo.InvariantCulture);
            long parsed;
            if (String.IsNullOrEmpty(text) ||
                !System.Text.RegularExpressions.Regex.IsMatch(text, "^[1-9][0-9]{0,18}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant) ||
                !Int64.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out parsed) || parsed <= 0L ||
                !String.Equals(parsed.ToString(CultureInfo.InvariantCulture), text, StringComparison.Ordinal))
                throw new ArgumentException("The selected sealed transport case has a non-canonical " + name + ".");
            return parsed;
        }

        private static long AddMilliseconds(long start, int milliseconds, long frequency) {
            if (milliseconds <= 0 || frequency <= 0) throw new ArgumentOutOfRangeException("milliseconds");
            long seconds = milliseconds / 1000L;
            long remainder = milliseconds % 1000L;
            long delta = checked(seconds * frequency + (remainder * frequency + 999L) / 1000L);
            return checked(start + delta);
        }

        private static int RemainingMilliseconds(long absoluteDeadlineQpc) {
            if (absoluteDeadlineQpc <= 0) throw new ArgumentOutOfRangeException("absoluteDeadlineQpc");
            long now = Stopwatch.GetTimestamp();
            if (now >= absoluteDeadlineQpc) return 0;
            long frequency = Stopwatch.Frequency;
            long delta = absoluteDeadlineQpc - now;
            long seconds = delta / frequency;
            long remainder = delta % frequency;
            long milliseconds = checked(seconds * 1000L + checked(remainder * 1000L + frequency - 1L) / frequency);
            return (int)Math.Min(Int32.MaxValue, Math.Max(1L, milliseconds));
        }

        private static void RequireTimeRemaining(long absoluteDeadlineQpc, string operation) {
            if (RemainingMilliseconds(absoluteDeadlineQpc) <= 0)
                throw new TimeoutException(operation + " exceeded its immutable absolute QPC deadline.");
        }

        private static void WaitForStageReady(EventWaitHandle readyEvent, long absoluteDeadlineQpc) {
            while (true) {
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                if (remaining <= 0) throw new TimeoutException("StageReady was not signaled before the immutable observation deadline.");
                if (readyEvent.WaitOne(Math.Min(50, remaining))) {
                    if (Stopwatch.GetTimestamp() > absoluteDeadlineQpc)
                        throw new TimeoutException("StageReady was observed after the immutable observation deadline.");
                    return;
                }
            }
        }

        private static void RequireManualResetUnsignaled(EventWaitHandle value, string label) {
            bool addedRef = false;
            try {
                value.SafeWaitHandle.DangerousAddRef(ref addedRef);
                EventBasicInformation information;
                int returned;
                int status = NtQueryEvent(value.SafeWaitHandle.DangerousGetHandle(), 0, out information,
                    Marshal.SizeOf(typeof(EventBasicInformation)), out returned);
                if (status != 0 || returned != Marshal.SizeOf(typeof(EventBasicInformation)))
                    throw new InvalidOperationException(label + " native event metadata could not be queried exactly.");
                if (information.EventType != 0)
                    throw new InvalidOperationException(label + " must be an existing manual-reset notification event.");
                if (information.EventState != 0 || value.WaitOne(0))
                    throw new InvalidOperationException(label + " must be initially unsignaled.");
            }
            finally { if (addedRef) value.SafeWaitHandle.DangerousRelease(); }
        }

        private static string[] RequiredStringArray(object source, string name) {
            object raw = ReadValue(source, name);
            System.Collections.IEnumerable values = raw as System.Collections.IEnumerable;
            if (values == null || raw is string) throw new ArgumentException("The selected sealed transport case has an invalid " + name + ".");
            System.Collections.Generic.List<string> result = new System.Collections.Generic.List<string>();
            foreach (object value in values) {
                string text = Convert.ToString(value);
                if (String.IsNullOrWhiteSpace(text)) throw new ArgumentException("The selected sealed transport case contains an empty host argument.");
                result.Add(text);
            }
            if (result.Count == 0) throw new ArgumentException("The selected sealed transport case contains no host arguments.");
            return result.ToArray();
        }

        private static IDictionary RequiredDictionary(object source, string name) {
            IDictionary value = ReadValue(source, name) as IDictionary;
            if (value == null) throw new ArgumentException("The selected sealed transport case has an invalid " + name + ".");
            return value;
        }

        private static long RequiredPositiveJsonInt64(object source, string name) {
            object value = ReadValue(source, name);
            if (!(value is long) || (long)value <= 0L) throw new ArgumentException("The selected sealed transport case has an invalid JSON integer " + name + ".");
            return (long)value;
        }

        private static string RequiredSha256(object source, string name) {
            string value = RequiredString(source, name, false);
            if (!System.Text.RegularExpressions.Regex.IsMatch(value, "^[0-9a-f]{64}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                throw new ArgumentException("The selected sealed transport case has an invalid " + name + ".");
            return value;
        }

        private static string RequiredClosedValue(object source, string name, string[] allowed) {
            string value = RequiredString(source, name, false);
            if (Array.IndexOf(allowed, value) < 0) throw new ArgumentException("The selected sealed transport case has an invalid " + name + ".");
            return value;
        }

        private static void WriteJsonString(string value, StringBuilder builder) {
            builder.Append('"');
            foreach (char character in value) {
                switch (character) {
                    case '"': builder.Append("\\\""); break; case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break; case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break; case '\r': builder.Append("\\r"); break; case '\t': builder.Append("\\t"); break;
                    default: if (character < 0x20) builder.Append("\\u" + ((int)character).ToString("x4", CultureInfo.InvariantCulture)); else builder.Append(character); break;
                }
            }
            builder.Append('"');
        }

        private static void WriteCanonicalJson(object value, StringBuilder builder) {
            if (value == null) { builder.Append("null"); return; }
            if (value is string) { WriteJsonString((string)value, builder); return; }
            if (value is bool) { builder.Append((bool)value ? "true" : "false"); return; }
            if (value is byte || value is sbyte || value is short || value is ushort || value is int || value is uint || value is long || value is ulong) {
                builder.Append(Convert.ToString(value, CultureInfo.InvariantCulture)); return;
            }
            IDictionary dictionary = value as IDictionary;
            if (dictionary != null) {
                SortedDictionary<string, object> sorted = new SortedDictionary<string, object>(StringComparer.Ordinal);
                foreach (DictionaryEntry entry in dictionary) { string key = entry.Key as string; if (String.IsNullOrEmpty(key) || sorted.ContainsKey(key)) throw new ArgumentException("Canonical JSON dictionary keys are invalid."); sorted.Add(key, entry.Value); }
                builder.Append('{'); bool first = true; foreach (KeyValuePair<string, object> entry in sorted) { if (!first) builder.Append(','); first = false; WriteJsonString(entry.Key, builder); builder.Append(':'); WriteCanonicalJson(entry.Value, builder); } builder.Append('}'); return;
            }
            IEnumerable sequence = value as IEnumerable;
            if (sequence != null) { builder.Append('['); bool first = true; foreach (object item in sequence) { if (!first) builder.Append(','); first = false; WriteCanonicalJson(item, builder); } builder.Append(']'); return; }
            throw new ArgumentException("Canonical JSON contains an unsupported value type: " + value.GetType().FullName);
        }

        private static byte[] CanonicalJsonBytes(object value) { StringBuilder builder = new StringBuilder(); WriteCanonicalJson(value, builder); return new UTF8Encoding(false, true).GetBytes(builder.ToString()); }
        private static string Sha256(byte[] bytes) { return Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant(); }

        private static Dictionary<string, object> CopyCaseDefinition(object definition) {
            Dictionary<string, object> result = new Dictionary<string, object>(StringComparer.Ordinal); IDictionary dictionary = definition as IDictionary;
            if (dictionary == null) throw new ArgumentException("The sealed transport case must be a dictionary.", "definition");
            foreach (DictionaryEntry entry in dictionary) { string key = entry.Key as string; if (String.IsNullOrEmpty(key) || result.ContainsKey(key)) throw new ArgumentException("The sealed transport case has invalid keys."); result.Add(key, entry.Value); }
            return result;
        }

        public static bool IsSelectedCase(object definition) {
            object selected = ReadValue(definition, "SealedMutationTransport");
            bool value;
            return selected != null && Boolean.TryParse(Convert.ToString(selected), out value) && value;
        }

        public static HardKillSealedMutationControllerScope Create(object definition) {
            if (!IsSelectedCase(definition)) throw new ArgumentException("The case is not selected for sealed transport.", "definition");
            string mode = RequiredString(definition, "ReapMode", false);
            if (mode != "hard-kill" && mode != "natural-release") throw new ArgumentException("The selected sealed transport case has an invalid ReapMode.");
            int worker = RequiredPositiveInt(definition, "WorkerWaitMilliseconds");
            int observation = RequiredPositiveInt(definition, "ControllerObservationMilliseconds");
            int reap = RequiredPositiveInt(definition, "JobReapMilliseconds");
            int cleanup = RequiredPositiveInt(definition, "CleanupMilliseconds");
            if (worker != SealedJobQpcDeadlines.ReviewedWorkerWaitMilliseconds ||
                observation != SealedJobQpcDeadlines.ReviewedControllerObservationMilliseconds ||
                reap != SealedJobQpcDeadlines.ReviewedJobReapMilliseconds || cleanup != SealedJobQpcDeadlines.ReviewedCleanupMilliseconds)
                throw new ArgumentException("The selected sealed transport case does not use the reviewed immutable budgets.");
            string fixturePath = RequiredString(definition, "InvocationFixturePath", true);
            string stdoutPath = RequiredString(definition, "StdoutPath", true);
            string stderrPath = RequiredString(definition, "StderrPath", true);
            string[] arguments = RequiredStringArray(definition, "HostArguments");
            string afterPath = RequiredString(definition, "PostStatePath", true);
            string engineSha256 = RequiredSha256(definition, "ExpectedEngineSha256");
            string hostSha256 = RequiredSha256(definition, "ExpectedProbeHostSha256");
            string transactionId = RequiredString(definition, "TransactionId", false);
            Guid parsedTransactionId;
            if (!Guid.TryParseExact(transactionId, "D", out parsedTransactionId) || parsedTransactionId.ToString("D") != transactionId)
                throw new ArgumentException("The selected sealed transport case has a non-canonical TransactionId.");
            string transactionNamespace = RequiredString(definition, "TransactionNamespace", true);
            RequiredString(definition, "Checkpoint", false); // host wire checkpoint remains independent of the typed selector checkpoint.
            string checkpoint = RequiredString(definition, "SelectorCheckpoint", false);
            string variant = RequiredString(definition, "DeclaredVariant", false);
            string intentPhase = RequiredString(definition, "ExpectedIntentPhase", false);
            long intentSequence = RequiredPositiveJsonInt64(definition, "ExpectedIntentSequence");
            string tailPhase = RequiredString(definition, "ExpectedTailPhase", false);
            long tailSequence = RequiredPositiveJsonInt64(definition, "ExpectedTailSequence");
            if (tailSequence < intentSequence) throw new ArgumentException("The selected sealed transport case has a tail before its intent.");
            IDictionary selectorArm = RequiredDictionary(definition, "SelectorArm");
            foreach (string argument in arguments)
                if (String.Equals(argument, "-NoProfile", StringComparison.OrdinalIgnoreCase) || String.Equals(argument, "-File", StringComparison.OrdinalIgnoreCase))
                    throw new ArgumentException("HostArguments must exclude the pwsh bootstrap arguments.");

            string controllerNonce = Guid.NewGuid().ToString("N");
            string caseNonce = Guid.NewGuid().ToString("N");
            string readyNonce = Guid.NewGuid().ToString("N");
            string continueNonce = Guid.NewGuid().ToString("N");
            string stageReadyEventName = "AiAgentDotfilesTests-StageReady-" + readyNonce;
            string continueEventName = "AiAgentDotfilesTests-Continue-" + continueNonce;
            EventWaitHandle readyEvent = null;
            EventWaitHandle releaseEvent = null;
            ControllerStageOwner owner = null;
            try {
                owner = ControllerStageOwner.Create();
                readyEvent = ControllerStageOwner.CreateManualResetEvent(stageReadyEventName);
                releaseEvent = ControllerStageOwner.CreateManualResetEvent(continueEventName);
                RequireManualResetUnsignaled(readyEvent, "StageReady");
                RequireManualResetUnsignaled(releaseEvent, "Continue");
                long frequency = Stopwatch.Frequency;
                long start = Stopwatch.GetTimestamp();
                long workerDeadline = AddMilliseconds(start, worker, frequency);
                long observationDeadline = AddMilliseconds(start, observation, frequency);
                long hardReap = AddMilliseconds(observationDeadline, reap, frequency);
                long hardCleanup = AddMilliseconds(hardReap, cleanup, frequency);
                long naturalReap = AddMilliseconds(workerDeadline, reap, frequency);
                long naturalCleanup = AddMilliseconds(naturalReap, cleanup, frequency);

                SortedDictionary<string, object> selectorWire = new SortedDictionary<string, object>(StringComparer.Ordinal) {
                    { "SchemaVersion", 1L }, { "ArtifactKind", "sealed-mutation-stage-selector" },
                    { "ControllerNonce", controllerNonce }, { "CaseNonce", caseNonce },
                    { "StageReadyEventName", stageReadyEventName }, { "StageReadyEventNonce", readyNonce },
                    { "ContinueEventName", continueEventName }, { "ContinueEventNonce", continueNonce },
                    { "TransactionId", transactionId }, { "TransactionNamespace", transactionNamespace },
                    { "Checkpoint", checkpoint }, { "DeclaredVariant", variant },
                    { "ExpectedIntentPhase", intentPhase }, { "ExpectedIntentSequence", intentSequence },
                    { "ExpectedTailPhase", tailPhase }, { "ExpectedTailSequence", tailSequence },
                    { "SelectorArm", selectorArm }, { "StageRootPath", owner.RootPath }, { "StageRootIdentity", owner.RootIdentity },
                    { "StageTempLeaf", owner.TempLeaf }, { "StageFinalLeaf", owner.FinalLeaf },
                    { "ControllerObservationMilliseconds", (long)observation }, { "JobReapMilliseconds", (long)reap },
                    { "CleanupMilliseconds", (long)cleanup }, { "WorkerWaitMilliseconds", (long)worker },
                    { "ControllerQpcTicks", start.ToString(CultureInfo.InvariantCulture) },
                    { "StopwatchFrequency", frequency.ToString(CultureInfo.InvariantCulture) },
                    { "ControllerObservationDeadlineQpc", observationDeadline.ToString(CultureInfo.InvariantCulture) },
                    { "HardKillCumulativeReapDeadlineQpc", hardReap.ToString(CultureInfo.InvariantCulture) },
                    { "WorkerDeadlineQpc", workerDeadline.ToString(CultureInfo.InvariantCulture) },
                    { "NaturalReleaseCumulativeReapDeadlineQpc", naturalReap.ToString(CultureInfo.InvariantCulture) },
                    { "HardKillCumulativeCleanupDeadlineQpc", hardCleanup.ToString(CultureInfo.InvariantCulture) },
                    { "NaturalReleaseCumulativeCleanupDeadlineQpc", naturalCleanup.ToString(CultureInfo.InvariantCulture) }
                };
                string selector = Sha256(CanonicalJsonBytes(selectorWire));
                SealedJobQpcDeadlines qpc = new SealedJobQpcDeadlines(worker, observation, reap, cleanup, frequency, start,
                    workerDeadline, observationDeadline, hardReap, hardCleanup, naturalReap, naturalCleanup, selector);

                SortedDictionary<string, object> provenance = new SortedDictionary<string, object>(StringComparer.Ordinal) { { "RawSha256", engineSha256 } };
                SortedDictionary<string, object> fixture = new SortedDictionary<string, object>(StringComparer.Ordinal) {
                    { "SchemaVersion", 1L }, { "ArtifactKind", "sealed-mutation-invocation-fixture" },
                    { "HostRawSha256", hostSha256 }, { "EngineProvenance", provenance },
                    { "Selector", selectorWire }, { "SelectorSha256", selector }
                };
                byte[] fixtureBytes = CanonicalJsonBytes(fixture);
                string fixtureSha256 = Sha256(fixtureBytes);
                using (FileStream fixtureStream = new FileStream(fixturePath, FileMode.CreateNew, FileAccess.Write, FileShare.Read, 4096, FileOptions.WriteThrough)) {
                    fixtureStream.Write(fixtureBytes, 0, fixtureBytes.Length); fixtureStream.Flush(true);
                }
                Dictionary<string, object> generated = CopyCaseDefinition(definition);
                generated["Selector"] = selectorWire; generated["SelectorHash"] = selector;
                generated["SealedInvocationFixtureSha256"] = fixtureSha256;
                generated["StageReadyEventName"] = stageReadyEventName; generated["ContinueEventName"] = continueEventName;
                generated["ControllerQpcTicks"] = start.ToString(CultureInfo.InvariantCulture);
                generated["StopwatchFrequency"] = frequency.ToString(CultureInfo.InvariantCulture);
                generated["WorkerDeadlineQpc"] = workerDeadline.ToString(CultureInfo.InvariantCulture);
                generated["ControllerObservationDeadlineQpc"] = observationDeadline.ToString(CultureInfo.InvariantCulture);
                generated["HardKillCumulativeReapDeadlineQpc"] = hardReap.ToString(CultureInfo.InvariantCulture);
                generated["HardKillCumulativeCleanupDeadlineQpc"] = hardCleanup.ToString(CultureInfo.InvariantCulture);
                generated["NaturalReleaseCumulativeReapDeadlineQpc"] = naturalReap.ToString(CultureInfo.InvariantCulture);
                generated["NaturalReleaseCumulativeCleanupDeadlineQpc"] = naturalCleanup.ToString(CultureInfo.InvariantCulture);
                generated["ObservationPath"] = Path.Combine(owner.RootPath, owner.FinalLeaf);
                HardKillSealedMutationControllerScope result = new HardKillSealedMutationControllerScope(generated, qpc, mode,
                    fixturePath, stdoutPath, stderrPath, arguments, (string)generated["ObservationPath"], afterPath, engineSha256, fixtureSha256, hostSha256,
                    readyEvent, releaseEvent, owner, selectorWire, selector);
                readyEvent = null;
                releaseEvent = null;
                owner = null;
                return result;
            }
            catch (Exception primary) {
                List<Exception> failures = new List<Exception>(); failures.Add(primary);
                try { if (releaseEvent != null) releaseEvent.Dispose(); } catch (Exception error) { failures.Add(error); }
                try { if (readyEvent != null) readyEvent.Dispose(); } catch (Exception error) { failures.Add(error); }
                try { if (owner != null) owner.AbortEmptyBeforeLaunch(); } catch (Exception error) { failures.Add(error); }
                if (failures.Count == 1) throw;
                throw new AggregateException("Sealed controller creation and cleanup failed.", failures);
            }
        }

        internal string[] BuildHostArguments(string hostPath, string enginePath) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            System.Collections.Generic.List<string> result = new System.Collections.Generic.List<string>();
            result.Add("-NoProfile"); result.Add("-File"); result.Add(Path.GetFullPath(hostPath));
            result.AddRange(hostArguments);
            result.Add("-MutationEnginePath"); result.Add(Path.GetFullPath(enginePath));
            result.Add("-ExpectedEngineSha256"); result.Add(expectedEngineSha256);
            result.Add("-SealedInvocationFixturePath"); result.Add(invocationFixturePath);
            result.Add("-SealedInvocationFixtureSha256"); result.Add(invocationFixtureSha256);
            result.Add("-ExpectedProbeHostSha256"); result.Add(expectedProbeHostSha256);
            return result.ToArray();
        }

        private static object ReadEvidence(string path, long deadline) {
            RequireTimeRemaining(deadline, "sealed evidence open");
            byte[] bytes;
            FileStream stream = null;
            try {
                stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                RequireTimeRemaining(deadline, "sealed evidence held-length read");
                if (stream.Length > Int32.MaxValue) throw new IOException("The sealed evidence is too large.");
                bytes = new byte[(int)stream.Length];
                int offset = 0;
                while (offset < bytes.Length) {
                    RequireTimeRemaining(deadline, "sealed evidence held-byte read");
                    int read = stream.Read(bytes, offset, bytes.Length - offset);
                    if (read == 0) throw new EndOfStreamException("The sealed evidence ended before its held length.");
                    offset += read;
                }
                if (stream.Length != bytes.LongLength) throw new IOException("The sealed evidence length changed while held.");
                System.Collections.Generic.Dictionary<string, object> evidence = new System.Collections.Generic.Dictionary<string, object>(StringComparer.Ordinal);
                evidence.Add("Path", path);
                evidence.Add("Length", (long)bytes.LongLength);
                using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
                    evidence.Add("RawSha256", BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant());
                evidence.Add("Bytes", bytes);
                evidence.Add("Lease", stream);
                stream = null;
                return evidence;
            }
            finally { if (stream != null) stream.Dispose(); }
        }

        private static void CloseEvidenceLease(object evidence) {
            System.Collections.Generic.Dictionary<string, object> dictionary = evidence as System.Collections.Generic.Dictionary<string, object>;
            if (dictionary == null || !dictionary.ContainsKey("Lease") || !(dictionary["Lease"] is IDisposable))
                throw new InvalidOperationException("The sealed evidence does not retain its exact read lease.");
            IDisposable lease = (IDisposable)dictionary["Lease"];
            lease.Dispose();
            dictionary.Remove("Lease");
        }

        private static void CloseEvidenceLeaseIfPresent(object evidence) {
            if (evidence == null) return;
            System.Collections.Generic.Dictionary<string, object> dictionary = evidence as System.Collections.Generic.Dictionary<string, object>;
            if (dictionary == null) throw new InvalidOperationException("The sealed evidence is not the exact controller dictionary.");
            if (!dictionary.ContainsKey("Lease")) return;
            IDisposable lease = dictionary["Lease"] as IDisposable;
            if (lease == null) throw new InvalidOperationException("The sealed evidence lease has an invalid type.");
            try { lease.Dispose(); }
            finally { dictionary.Remove("Lease"); }
        }

        private static ControllerStageCapture ObservationCapture(object evidence) {
            Dictionary<string, object> dictionary = evidence as Dictionary<string, object>;
            if (dictionary == null || !dictionary.ContainsKey("Lease")) return null;
            return dictionary["Lease"] as ControllerStageCapture;
        }

        public object Observe(HardKillSealedMutationHostSession session) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (exactObservation != null) throw new InvalidOperationException("Observation may only be acquired once for this controller scope.");
            if (session == null || !Object.ReferenceEquals(deadlines, session.Deadlines) || !session.IsResumed)
                throw new InvalidOperationException("Observation requires this scope's exact resumed session.");
            WaitForStageReady(stageReadyEvent, deadlines.ControllerObservationDeadlineQpc);
            if (session.Closed || session.HasReapReceipt || session.JobProcess.ActiveProcesses == 0U)
                throw new InvalidOperationException("StageReady requires the exact resumed session to remain live and unreaped.");
            Process root = session.Process;
            root.Refresh();
            if (root.HasExited) throw new InvalidOperationException("StageReady was signaled after the exact root exited.");
            if (continueEvent.WaitOne(0)) throw new InvalidOperationException("Continue was signaled before controller observation completed.");
            RequireTimeRemaining(deadlines.ControllerObservationDeadlineQpc, "held relative stage capture");
            ControllerStageCapture capture = stageOwner.CaptureFinal();
            try {
                RequireTimeRemaining(deadlines.ControllerObservationDeadlineQpc, "held relative stage validation");
                if (continueEvent.WaitOne(0)) throw new InvalidOperationException("Continue was signaled during controller observation.");
                Dictionary<string, object> evidence = new Dictionary<string, object>(StringComparer.Ordinal);
                evidence.Add("Path", observationPath); evidence.Add("Selector", selectorWire); evidence.Add("SelectorHash", selectorHash);
                evidence.Add("Identity", capture.Identity); evidence.Add("Length", capture.Length); evidence.Add("RawSha256", capture.RawSha256);
                evidence.Add("Bytes", capture.Bytes); evidence.Add("Lease", capture); capture = null;
                exactObservation = evidence; return evidence;
            }
            finally { if (capture != null) capture.Dispose(); }
        }

        public bool ReleaseForNaturalExit(HardKillSealedMutationHostSession session, object observation) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (reapMode != "natural-release") throw new InvalidOperationException("Only a natural-release scope may signal Continue.");
            if (naturalReleaseSignaled) throw new InvalidOperationException("Continue was already signaled for this natural-release scope.");
            if (session == null || session.Closed || session.HasReapReceipt || !session.IsResumed ||
                !Object.ReferenceEquals(deadlines, session.Deadlines) || !Object.ReferenceEquals(observation, exactObservation) ||
                ObservationCapture(observation) == null || session.JobProcess.ActiveProcesses == 0U)
                throw new InvalidOperationException("Natural release requires this scope's exact live resumed session and held observation.");
            RequireTimeRemaining(deadlines.WorkerDeadlineQpc, "natural-release Continue signal");
            if (continueEvent.WaitOne(0)) throw new InvalidOperationException("Continue was signaled outside the exact natural-release transition.");
            ControllerStageCapture capture = ObservationCapture(observation);
            exactObservationIdentity = capture.Identity;
            CloseEvidenceLease(observation);
            if (!continueEvent.Set()) throw new InvalidOperationException("The natural-release Continue event could not be signaled.");
            naturalReleaseSignaled = true;
            return true;
        }

        public object ReadPostState(HardKillSealedMutationHostSession session, object observation, HardKillJobReapReceipt receipt) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (session == null || !Object.ReferenceEquals(observation, exactObservation) || receipt == null || !Object.ReferenceEquals(receipt, session.ReapReceipt))
                throw new InvalidOperationException("Post-state acquisition requires the exact accepted receipt and prior observation.");
            long deadline = CleanupDeadline(receipt);
            return ReadEvidence(postStatePath, deadline);
        }

        private long CleanupDeadline(HardKillJobReapReceipt receipt) {
            long cumulative = reapMode == "hard-kill" ? deadlines.HardKillCumulativeCleanupDeadlineQpc : deadlines.NaturalReleaseCumulativeCleanupDeadlineQpc;
            long operative = AddMilliseconds(receipt.JobZeroQpcTicks, deadlines.CleanupMilliseconds, deadlines.StopwatchFrequency);
            long result = Math.Min(operative, cumulative); RequireTimeRemaining(result, "controller cleanup"); return result;
        }

        private long FailureCleanupDeadline(HardKillJobReapReceipt receipt) {
            long cumulative = reapMode == "hard-kill" ? deadlines.HardKillCumulativeCleanupDeadlineQpc : deadlines.NaturalReleaseCumulativeCleanupDeadlineQpc;
            long operative = AddMilliseconds(receipt.JobZeroQpcTicks, deadlines.CleanupMilliseconds, deadlines.StopwatchFrequency);
            return Math.Min(operative, cumulative);
        }

        public bool CompleteCleanup(HardKillSealedMutationHostSession session, object observation, HardKillJobReapReceipt receipt, object postState) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (cleanupCompleted) throw new InvalidOperationException("Controller cleanup was already completed.");
            if (session == null || receipt == null || !Object.ReferenceEquals(receipt, session.ReapReceipt) ||
                receipt.ActiveAfter != 0L || !receipt.JobHandleClosed || !receipt.IdentityGone)
                throw new InvalidOperationException("Controller cleanup requires the exact zero/close/identity-gone receipt.");
            bool failureReceipt = receipt is HardKillFailureCleanupReceipt;
            if (observation != null && !Object.ReferenceEquals(observation, exactObservation))
                throw new InvalidOperationException("Controller cleanup received an observation from another scope.");
            if (!failureReceipt && (!Object.ReferenceEquals(observation, exactObservation) || postState == null))
                throw new InvalidOperationException("Nominal controller cleanup requires both held evidence documents.");
            ControllerStageCapture capture = ObservationCapture(observation);
            string capturedIdentity = capture == null ? null : capture.Identity;
            if (!failureReceipt && reapMode == "hard-kill" && String.IsNullOrEmpty(capturedIdentity))
                throw new InvalidOperationException("Hard-kill cleanup lacks the exact held stage identity.");
            if (!failureReceipt && reapMode == "natural-release" &&
                (!naturalReleaseSignaled || capture != null || String.IsNullOrEmpty(exactObservationIdentity)))
                throw new InvalidOperationException("Natural-release cleanup did not consume the exact observation before Continue.");
            long cleanupDeadline = CleanupDeadline(receipt);
            List<Exception> failures = new List<Exception>();
            if (postState != null) try { RequireTimeRemaining(cleanupDeadline, "post-state lease cleanup"); CloseEvidenceLease(postState); } catch (Exception error) { failures.Add(error); }
            if (observation != null) try { RequireTimeRemaining(cleanupDeadline, "stage observation lease cleanup"); CloseEvidenceLeaseIfPresent(observation); } catch (Exception error) { failures.Add(error); }
            try {
                if (failureReceipt) stageOwner.FailureCleanup(capture, cleanupDeadline);
                else if (reapMode == "natural-release") stageOwner.CleanupEmpty(cleanupDeadline);
                else {
                    stageOwner.Cleanup(capturedIdentity, cleanupDeadline);
                }
            } catch (Exception error) { failures.Add(error); }
            if (failureReceipt) cleanupCompleted = true;
            else if (failures.Count == 0) cleanupCompleted = true;
            if (failures.Count == 1) throw failures[0];
            if (failures.Count > 1) throw new AggregateException("Controller evidence and native stage cleanup failed.", failures);
            return true;
        }

        public bool CompleteFailureCleanup(HardKillSealedMutationHostSession session, object observation, HardKillJobReapReceipt receipt, object postState, Exception primary) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (cleanupCompleted) throw new InvalidOperationException("Controller cleanup was already completed.");
            if (primary == null) throw new ArgumentNullException("primary");
            if (session == null || receipt == null || !Object.ReferenceEquals(receipt, session.ReapReceipt) ||
                receipt.ActiveAfter != 0L || !receipt.JobHandleClosed || !receipt.IdentityGone)
                throw new InvalidOperationException("Failure cleanup requires the exact accepted zero/close/identity-gone receipt.");
            if (observation != null && !Object.ReferenceEquals(observation, exactObservation))
                throw new InvalidOperationException("Failure cleanup received an observation from another scope.");
            ControllerStageCapture capture = ObservationCapture(observation);
            long cleanupDeadline = FailureCleanupDeadline(receipt);
            List<Exception> failures = new List<Exception>();
            if (postState != null) try { CloseEvidenceLeaseIfPresent(postState); } catch (Exception error) { failures.Add(error); }
            if (observation != null) try { CloseEvidenceLeaseIfPresent(observation); } catch (Exception error) { failures.Add(error); }
            try { stageOwner.FailureCleanup(capture, cleanupDeadline); } catch (Exception error) { failures.Add(error); }
            cleanupCompleted = true;
            if (failures.Count == 1) throw failures[0];
            if (failures.Count > 1) throw new AggregateException("Controller failure cleanup could not release every held resource.", failures);
            return true;
        }

        public bool AbortBeforeSession() {
            if (closed) return true;
            if (cleanupCompleted) throw new InvalidOperationException("Controller cleanup was already completed.");
            List<Exception> failures = new List<Exception>();
            bool ownerReleased = false; bool continueReleased = false; bool readyReleased = false;
            try { RequireManualResetUnsignaled(stageReadyEvent, "StageReady"); } catch (Exception error) { failures.Add(error); }
            try { RequireManualResetUnsignaled(continueEvent, "Continue"); } catch (Exception error) { failures.Add(error); }
            try { stageOwner.AbortEmptyBeforeLaunch(); ownerReleased = true; }
            catch (Exception error) {
                failures.Add(error);
                try { stageOwner.PreserveForensicAndCloseHandles(); } catch (Exception releaseError) { failures.Add(releaseError); }
                finally { ownerReleased = true; }
            }
            try { continueEvent.Dispose(); continueReleased = true; } catch (Exception error) { failures.Add(error); }
            try { stageReadyEvent.Dispose(); readyReleased = true; } catch (Exception error) { failures.Add(error); }
            if (ownerReleased && continueReleased && readyReleased) { cleanupCompleted = true; closed = true; }
            if (failures.Count == 0) return true;
            if (failures.Count == 1) throw failures[0];
            throw new AggregateException("Pre-session controller abort could not release every held resource.", failures);
        }

        private static object PublishResult(string kind, object definition, object observation, HardKillJobReapReceipt receipt, object postState) {
            if (definition == null || observation == null || receipt == null || postState == null || receipt.ActiveAfter != 0L ||
                !receipt.JobHandleClosed || !receipt.IdentityGone) throw new InvalidOperationException("A sealed result requires complete provenance and an exact reap receipt.");
            System.Collections.Generic.Dictionary<string, object> result = new System.Collections.Generic.Dictionary<string, object>(StringComparer.Ordinal);
            result.Add("Kind", kind); result.Add("CaseDefinition", definition); result.Add("Observation", observation);
            result.Add("ReapReceipt", receipt); result.Add("PostState", postState);
            return result;
        }

        public static object CreateHardKillProof(object definition, object observation, HardKillLiveTerminationReceipt receipt, object postState) {
            if (receipt == null || !receipt.TerminationIssued || !receipt.RootAliveBefore) throw new InvalidOperationException("The live-termination receipt cannot publish a hard-kill proof.");
            return PublishResult("hard-kill-proof", definition, observation, receipt, postState);
        }

        public static object CreateDifferentialResult(object definition, object observation, HardKillNaturalExitReceipt receipt, object postState) {
            if (receipt == null || receipt.TerminationIssued) throw new InvalidOperationException("The natural-exit receipt cannot publish a differential result.");
            return PublishResult("natural-release-differential", definition, observation, receipt, postState);
        }

        public bool Close() {
            if (closed) return true;
            if (!cleanupCompleted) throw new InvalidOperationException("The controller scope cannot close before exact cleanup completion.");
            Exception releaseFailure = null;
            try { continueEvent.Dispose(); } catch (Exception error) { releaseFailure = error; }
            Exception readyFailure = null;
            try { stageReadyEvent.Dispose(); } catch (Exception error) { readyFailure = error; }
            if (releaseFailure != null && readyFailure != null)
                throw new AggregateException("Both sealed controller event handles failed to close.", releaseFailure, readyFailure);
            if (releaseFailure != null) throw releaseFailure;
            if (readyFailure != null) throw readyFailure;
            closed = true;
            return true;
        }

        public object CaseDefinition { get { return caseDefinition; } }
        public SealedJobQpcDeadlines Deadlines { get { return deadlines; } }
        public long FailureCleanupAbsoluteCapQpcTicks { get { return reapMode == "hard-kill" ? deadlines.HardKillCumulativeReapDeadlineQpc : deadlines.NaturalReleaseCumulativeReapDeadlineQpc; } }
        public string InvocationFixturePath { get { return invocationFixturePath; } }
        public string ReapMode { get { return reapMode; } }
        public string StderrPath { get { return stderrPath; } }
        public string StdoutPath { get { return stdoutPath; } }
    }
}
'@
if($null -ne ('AiAgentDotfilesTests.HardKillJobProcess' -as [type]) -or $null -ne ('AiAgentDotfilesTests.SealedJobQpcDeadlines' -as [type]) -or $null -ne ('AiAgentDotfilesTests.HardKillJobReapReceipt' -as [type]) -or $null -ne ('AiAgentDotfilesTests.HardKillLiveTerminationReceipt' -as [type]) -or $null -ne ('AiAgentDotfilesTests.HardKillNaturalExitReceipt' -as [type]) -or $null -ne ('AiAgentDotfilesTests.HardKillFailureCleanupReceipt' -as [type]) -or $null -ne ('AiAgentDotfilesTests.HardKillSealedMutationHostSession' -as [type]) -or $null -ne ('AiAgentDotfilesTests.HardKillSealedMutationControllerScope' -as [type])){throw 'hard-kill sealed mutation transport type was already present'}
$script:hardKillSealedMutationTransportAuthorityTypes=Microsoft.PowerShell.Utility\Add-Type -Language CSharp -PassThru -TypeDefinition $hardKillSealedMutationTransportAuthoritySource -ErrorAction Stop

function Start-HardKillJobProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [string]$RedirectStandardOutputPath,
        [string]$RedirectStandardErrorPath
    )
    $jobProcess=[AiAgentDotfilesTests.HardKillJobProcess]::Start(
        [IO.Path]::GetFullPath($FilePath),
        [string[]]@($ArgumentList),
        $(if($RedirectStandardOutputPath){[IO.Path]::GetFullPath($RedirectStandardOutputPath)}else{$null}),
        $(if($RedirectStandardErrorPath){[IO.Path]::GetFullPath($RedirectStandardErrorPath)}else{$null})
    )
    $resumeMethod=[AiAgentDotfilesTests.HardKillJobProcess].GetMethod('ResumeRoot',[Reflection.BindingFlags]'Instance,NonPublic')
    if($null -eq $resumeMethod){throw 'hard-kill legacy resume bridge is unavailable'}
    $null=$resumeMethod.Invoke($jobProcess,@())
    return $jobProcess
}

function Confirm-HardKillJobProcessReaped {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AiAgentDotfilesTests.HardKillJobProcess]$JobProcess,[int]$TimeoutMilliseconds=5000)
    $terminateMethod=[AiAgentDotfilesTests.HardKillJobProcess].GetMethod('TerminateForLegacy',[Reflection.BindingFlags]'Instance,NonPublic')
    if($null -eq $terminateMethod){throw 'hard-kill legacy termination bridge is unavailable'}
    try{$null=$terminateMethod.Invoke($JobProcess,@([int]$TimeoutMilliseconds))}
    catch{
        $bridgeFailure=$_.Exception
        while(($bridgeFailure -is [Management.Automation.MethodInvocationException] -or
            $bridgeFailure -is [Reflection.TargetInvocationException]) -and $null -ne $bridgeFailure.InnerException){
            $bridgeFailure=$bridgeFailure.InnerException
        }
        throw $bridgeFailure
    }
    return $true
}

function Close-HardKillJobProcess {
    [CmdletBinding()]
    param([AllowNull()][AiAgentDotfilesTests.HardKillJobProcess]$JobProcess)
    if($null -eq $JobProcess){return}
    if(-not $JobProcess.Reaped){throw 'hard-kill Job process cannot close before an exact reap receipt is produced'}
    $JobProcess.Dispose()
}
