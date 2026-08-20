#requires -Version 7.0

Set-StrictMode -Version Latest

$hardKillSealedMutationTransportAuthoritySource=@'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

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

        private static int RemainingMilliseconds(long absoluteDeadlineQpc) {
            if (absoluteDeadlineQpc <= 0) return 0;
            long now = Stopwatch.GetTimestamp();
            if (now >= absoluteDeadlineQpc) return 0;
            long delta = absoluteDeadlineQpc - now;
            long milliseconds = checked((delta * 1000L + Stopwatch.Frequency - 1L) / Stopwatch.Frequency);
            return (int)Math.Min(Int32.MaxValue, Math.Max(1L, milliseconds));
        }

        private static bool WaitForJobEmptyUntil(IntPtr job, long absoluteDeadlineQpc) {
            while (GetActiveProcessCount(job) != 0) {
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                if (remaining <= 0) return false;
                Thread.Sleep(Math.Min(5, remaining));
            }
            return true;
        }

        private static bool WaitForOriginalProcessIdentityGoneUntil(int processId, long startTicks, long absoluteDeadlineQpc) {
            while (!OriginalProcessIdentityGone(processId, startTicks)) {
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                if (remaining <= 0) return false;
                Thread.Sleep(Math.Min(5, remaining));
            }
            return true;
        }

        private void ValidateExpectedIdentity(long expectedProcessId, long expectedCreationTicks) {
            if (expectedProcessId != rootProcessId || expectedCreationTicks != rootStartTimeUtcTicks)
                throw new InvalidOperationException("The exact root PID/creation identity differs from the sealed session.");
        }

        private void CloseRootAndJobAfterExit(long absoluteDeadlineQpc) {
            if (rootThreadHandle != IntPtr.Zero) {
                CloseHandle(rootThreadHandle);
                rootThreadHandle = IntPtr.Zero;
            }
            if (rootProcessHandle != IntPtr.Zero) {
                int remaining = RemainingMilliseconds(absoluteDeadlineQpc);
                uint wait = WaitForSingleObject(rootProcessHandle, (uint)Math.Max(0, remaining));
                if (wait != WAIT_OBJECT_0) throw new TimeoutException("The exact root process did not exit before the absolute reap deadline.");
                if (!CloseHandle(rootProcessHandle)) throw Win32("CloseHandle root process failed");
                rootProcessHandle = IntPtr.Zero;
            }
            if (rootProcess != null) { rootProcess.Dispose(); rootProcess = null; }
            if (!WaitForJobEmptyUntil(jobHandle, absoluteDeadlineQpc)) throw new TimeoutException("Job ActiveProcesses did not reach zero before the absolute reap deadline.");
            if (!CloseHandle(jobHandle)) throw Win32("CloseHandle Job failed");
            jobHandle = IntPtr.Zero;
            containmentEmpty = true;
            if (!WaitForOriginalProcessIdentityGoneUntil(rootProcessId, rootStartTimeUtcTicks, absoluteDeadlineQpc))
                throw new TimeoutException("The exact root PID/creation identity remained visible after Job close.");
            reaped = true;
        }

        public HardKillLiveTerminationReceipt TerminateLiveAndConfirm(long expectedProcessId, long expectedCreationTicks, SealedJobQpcDeadlines deadlines) {
            if (deadlines == null) throw new ArgumentNullException("deadlines");
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) throw new InvalidOperationException("A Job reap receipt was already produced.");
                if (!resumed) throw new InvalidOperationException("The suspended root cannot be terminated before the session resumes it.");
                ValidateExpectedIdentity(expectedProcessId, expectedCreationTicks);
                long deadline = deadlines.HardKillCumulativeReapDeadlineQpc;
                if (RemainingMilliseconds(deadline) <= 0) throw new TimeoutException("The hard-kill reap deadline elapsed before termination entry.");
                long activeBefore = GetActiveProcessCount(jobHandle);
                bool rootAliveBefore = WaitForSingleObject(rootProcessHandle, 0) == WAIT_TIMEOUT;
                long terminationQpc = Stopwatch.GetTimestamp();
                if (!TerminateJobObject(jobHandle, 1) && GetActiveProcessCount(jobHandle) != 0) throw Win32("TerminateJobObject failed");
                CloseRootAndJobAfterExit(deadline);
                return new HardKillLiveTerminationReceipt(rootProcessId, rootStartTimeUtcTicks, deadline, 0L, true, true,
                    activeBefore, rootAliveBefore, 1, true, terminationQpc);
            }
        }

        public HardKillNaturalExitReceipt ConfirmNaturalExitAndClose(long expectedProcessId, long expectedCreationTicks, SealedJobQpcDeadlines deadlines) {
            if (deadlines == null) throw new ArgumentNullException("deadlines");
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) throw new InvalidOperationException("A Job reap receipt was already produced.");
                if (!resumed) throw new InvalidOperationException("The suspended root cannot exit before the session resumes it.");
                ValidateExpectedIdentity(expectedProcessId, expectedCreationTicks);
                long deadline = deadlines.NaturalReleaseCumulativeReapDeadlineQpc;
                int remaining = RemainingMilliseconds(deadline);
                if (remaining <= 0 || WaitForSingleObject(rootProcessHandle, (uint)remaining) != WAIT_OBJECT_0)
                    throw new TimeoutException("The exact root did not exit naturally before the absolute reap deadline.");
                uint exitCode;
                if (!GetExitCodeProcess(rootProcessHandle, out exitCode)) throw Win32("GetExitCodeProcess failed");
                long rootExitQpc = Stopwatch.GetTimestamp();
                CloseRootAndJobAfterExit(deadline);
                return new HardKillNaturalExitReceipt(rootProcessId, rootStartTimeUtcTicks, deadline, 0L, true, true,
                    unchecked((int)exitCode), rootExitQpc, false);
            }
        }

        internal HardKillFailureCleanupReceipt ContainFailure(Exception primary, SealedJobQpcDeadlines deadlines, long absoluteCapQpcTicks) {
            if (primary == null) throw new ArgumentNullException("primary");
            if (deadlines == null) throw new ArgumentNullException("deadlines");
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) throw new InvalidOperationException("A Job reap receipt was already produced.");
                if (absoluteCapQpcTicks <= 0 || RemainingMilliseconds(absoluteCapQpcTicks) <= 0)
                    throw new TimeoutException("The failure-containment absolute cap elapsed before cleanup entry.");
                bool terminationIssued = false;
                long terminationQpc = 0L;
                if (!containmentEmpty) {
                    try {
                        terminationQpc = Stopwatch.GetTimestamp();
                        terminationIssued = true;
                        if (!TerminateJobObject(jobHandle, 1) && GetActiveProcessCount(jobHandle) != 0) throw Win32("TerminateJobObject failure containment failed");
                        CloseRootAndJobAfterExit(absoluteCapQpcTicks);
                    }
                    catch (Exception error) { FailStop("Job failure containment could not prove zero/close/identity-gone", new AggregateException(primary, error)); }
                }
                return new HardKillFailureCleanupReceipt(rootProcessId, rootStartTimeUtcTicks, absoluteCapQpcTicks, 0L, true, true,
                    absoluteCapQpcTicks, primary.GetType().FullName, 0L, terminationIssued, terminationQpc);
            }
        }

        internal void TerminateForLegacy(int timeoutMilliseconds) {
            if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) return;
                if (!resumed) ResumeRoot();
                long deadline = checked(Stopwatch.GetTimestamp() +
                    ((long)(timeoutMilliseconds / 1000) * Stopwatch.Frequency) +
                    (((long)(timeoutMilliseconds % 1000) * Stopwatch.Frequency + 999L) / 1000L));
                if (!TerminateJobObject(jobHandle, 1) && GetActiveProcessCount(jobHandle) != 0) throw Win32("TerminateJobObject failed");
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

        internal HardKillJobReapReceipt(long processId, long creationTicks, long deadline, long active, bool jobClosed,
            bool exactIdentityGone, long zeroQpcTicks) {
            pid = processId;
            rootCreationFileTimeTicks = creationTicks;
            reapDeadlineQpcTicks = deadline;
            activeAfter = active;
            jobHandleClosed = jobClosed;
            identityGone = exactIdentityGone;
            jobZeroQpcTicks = zeroQpcTicks == 0L ? Stopwatch.GetTimestamp() : zeroQpcTicks;
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

        internal HardKillLiveTerminationReceipt(long pid, long creation, long deadline, long activeAfter, bool jobClosed,
            bool identityGone, long before, bool aliveBefore, int exitCode, bool issued, long terminationTicks)
            : base(pid, creation, deadline, activeAfter, jobClosed, identityGone, 0L) {
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

        internal HardKillNaturalExitReceipt(long pid, long creation, long deadline, long activeAfter, bool jobClosed,
            bool identityGone, int exitCode, long exitTicks, bool issued)
            : base(pid, creation, deadline, activeAfter, jobClosed, identityGone, 0L) {
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

        internal HardKillFailureCleanupReceipt(long pid, long creation, long deadline, long activeAfter, bool jobClosed,
            bool identityGone, long absoluteCap, string mode, long exitTicks, bool issued, long terminationTicks)
            : base(pid, creation, deadline, activeAfter, jobClosed, identityGone, 0L) {
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
        private bool cleanupCompleted;
        private bool closed;

        private HardKillSealedMutationControllerScope(object definition, SealedJobQpcDeadlines qpcDeadlines, string mode,
            string fixturePath, string outputPath, string errorPath, string[] arguments, string observePath, string afterPath,
            string engineSha256, string fixtureSha256, string hostSha256) {
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

        private static long AddMilliseconds(long start, int milliseconds, long frequency) {
            if (milliseconds <= 0 || frequency <= 0) throw new ArgumentOutOfRangeException("milliseconds");
            long seconds = milliseconds / 1000L;
            long remainder = milliseconds % 1000L;
            long delta = checked(seconds * frequency + (remainder * frequency + 999L) / 1000L);
            return checked(start + delta);
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
            long start = Stopwatch.GetTimestamp();
            long frequency = Stopwatch.Frequency;
            long workerDeadline = AddMilliseconds(start, worker, frequency);
            long observationDeadline = AddMilliseconds(start, observation, frequency);
            long hardReap = AddMilliseconds(start, reap, frequency);
            long hardCleanup = AddMilliseconds(hardReap, cleanup, frequency);
            long naturalReap = AddMilliseconds(start, checked(observation + reap), frequency);
            long naturalCleanup = AddMilliseconds(naturalReap, cleanup, frequency);
            string selector = RequiredString(definition, "SelectorHash", false);
            if (!System.Text.RegularExpressions.Regex.IsMatch(selector, "^[0-9a-f]{64}$", System.Text.RegularExpressions.RegexOptions.CultureInvariant))
                throw new ArgumentException("The selected sealed transport case has an invalid SelectorHash.");
            SealedJobQpcDeadlines qpc = new SealedJobQpcDeadlines(worker, observation, reap, cleanup, frequency, start,
                workerDeadline, observationDeadline, hardReap, hardCleanup, naturalReap, naturalCleanup, selector);
            return new HardKillSealedMutationControllerScope(definition, qpc, mode,
                RequiredString(definition, "InvocationFixturePath", true), RequiredString(definition, "StdoutPath", true),
                RequiredString(definition, "StderrPath", true), RequiredStringArray(definition, "HostArguments"),
                RequiredString(definition, "ObservationPath", true), RequiredString(definition, "PostStatePath", true),
                RequiredString(definition, "ExpectedEngineSha256", false), RequiredString(definition, "SealedInvocationFixtureSha256", false),
                RequiredString(definition, "ExpectedProbeHostSha256", false));
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
            while (!File.Exists(path)) {
                if (Stopwatch.GetTimestamp() >= deadline) throw new TimeoutException("The sealed host did not publish the expected evidence before the absolute observation deadline.");
                Thread.Sleep(5);
            }
            byte[] bytes;
            FileStream stream = null;
            try {
                stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (stream.Length > Int32.MaxValue) throw new IOException("The sealed evidence is too large.");
                bytes = new byte[(int)stream.Length];
                int offset = 0;
                while (offset < bytes.Length) {
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
            if (dictionary == null || !dictionary.ContainsKey("Lease") || !(dictionary["Lease"] is FileStream))
                throw new InvalidOperationException("The sealed evidence does not retain its exact read lease.");
            FileStream lease = (FileStream)dictionary["Lease"];
            lease.Dispose();
            dictionary.Remove("Lease");
        }

        public object Observe(HardKillSealedMutationHostSession session) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (session == null || !Object.ReferenceEquals(deadlines, session.Deadlines) || !session.IsResumed)
                throw new InvalidOperationException("Observation requires this scope's exact resumed session.");
            return ReadEvidence(observationPath, deadlines.ControllerObservationDeadlineQpc);
        }

        public object ReadPostState(HardKillSealedMutationHostSession session, object observation, HardKillJobReapReceipt receipt) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (session == null || observation == null || receipt == null || !Object.ReferenceEquals(receipt, session.ReapReceipt))
                throw new InvalidOperationException("Post-state acquisition requires the exact accepted receipt and prior observation.");
            long deadline = reapMode == "hard-kill" ? deadlines.HardKillCumulativeCleanupDeadlineQpc : deadlines.NaturalReleaseCumulativeCleanupDeadlineQpc;
            return ReadEvidence(postStatePath, deadline);
        }

        public bool CompleteCleanup(HardKillSealedMutationHostSession session, object observation, HardKillJobReapReceipt receipt, object postState) {
            if (closed) throw new ObjectDisposedException("HardKillSealedMutationControllerScope");
            if (cleanupCompleted) throw new InvalidOperationException("Controller cleanup was already completed.");
            if (session == null || observation == null || postState == null || receipt == null || !Object.ReferenceEquals(receipt, session.ReapReceipt) ||
                receipt.ActiveAfter != 0L || !receipt.JobHandleClosed || !receipt.IdentityGone)
                throw new InvalidOperationException("Controller cleanup requires the exact zero/close/identity-gone receipt and both held evidence documents.");
            Exception postFailure = null;
            try { CloseEvidenceLease(postState); } catch (Exception error) { postFailure = error; }
            Exception observationFailure = null;
            try { CloseEvidenceLease(observation); } catch (Exception error) { observationFailure = error; }
            if (postFailure != null && observationFailure != null) throw new AggregateException("Both sealed evidence leases failed to close.", postFailure, observationFailure);
            if (postFailure != null) throw postFailure;
            if (observationFailure != null) throw observationFailure;
            cleanupCompleted = true;
            return true;
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
    $null=$terminateMethod.Invoke($JobProcess,@([int]$TimeoutMilliseconds))
    return $true
}

function Close-HardKillJobProcess {
    [CmdletBinding()]
    param([AllowNull()][AiAgentDotfilesTests.HardKillJobProcess]$JobProcess)
    if($null -eq $JobProcess){return}
    if(-not $JobProcess.Reaped){
        $terminateMethod=[AiAgentDotfilesTests.HardKillJobProcess].GetMethod('TerminateForLegacy',[Reflection.BindingFlags]'Instance,NonPublic')
        if($null -eq $terminateMethod){throw 'hard-kill legacy termination bridge is unavailable'}
        $null=$terminateMethod.Invoke($JobProcess,@([int]5000))
    }
    $JobProcess.Dispose()
}
