#requires -Version 7.0

Set-StrictMode -Version Latest

if(-not('AiAgentDotfilesTests.HardKillJobProcess' -as [type])){
    Add-Type -TypeDefinition @'
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

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES {
            internal int nLength;
            internal IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] internal bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO {
            internal int cb;
            internal string lpReserved;
            internal string lpDesktop;
            internal string lpTitle;
            internal int dwX;
            internal int dwY;
            internal int dwXSize;
            internal int dwYSize;
            internal int dwXCountChars;
            internal int dwYCountChars;
            internal int dwFillAttribute;
            internal uint dwFlags;
            internal short wShowWindow;
            internal short cbReserved2;
            internal IntPtr lpReserved2;
            internal IntPtr hStdInput;
            internal IntPtr hStdOutput;
            internal IntPtr hStdError;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct STARTUPINFOEX {
            internal STARTUPINFO StartupInfo;
            internal IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION {
            internal IntPtr hProcess;
            internal IntPtr hThread;
            internal uint dwProcessId;
            internal uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION {
            internal long PerProcessUserTimeLimit;
            internal long PerJobUserTimeLimit;
            internal uint LimitFlags;
            internal UIntPtr MinimumWorkingSetSize;
            internal UIntPtr MaximumWorkingSetSize;
            internal uint ActiveProcessLimit;
            internal UIntPtr Affinity;
            internal uint PriorityClass;
            internal uint SchedulingClass;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct IO_COUNTERS {
            internal ulong ReadOperationCount;
            internal ulong WriteOperationCount;
            internal ulong OtherOperationCount;
            internal ulong ReadTransferCount;
            internal ulong WriteTransferCount;
            internal ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION {
            internal JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            internal IO_COUNTERS IoInfo;
            internal UIntPtr ProcessMemoryLimit;
            internal UIntPtr JobMemoryLimit;
            internal UIntPtr PeakProcessMemoryUsed;
            internal UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION {
            internal long TotalUserTime;
            internal long TotalKernelTime;
            internal long ThisPeriodTotalUserTime;
            internal long ThisPeriodTotalKernelTime;
            internal uint TotalPageFaultCount;
            internal uint TotalProcesses;
            internal uint ActiveProcesses;
            internal uint TotalTerminatedProcesses;
        }

        private enum JOBOBJECTINFOCLASS {
            JobObjectBasicAccountingInformation = 1,
            JobObjectExtendedLimitInformation = 9
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateFileW(string name, uint access, uint share, ref SECURITY_ATTRIBUTES security, uint creation, uint flags, IntPtr template);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(string applicationName, StringBuilder commandLine, IntPtr processAttributes, IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles, uint creationFlags, IntPtr environment, string currentDirectory,
            ref STARTUPINFOEX startupInfo, out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(IntPtr attributeList, uint flags, IntPtr attribute, IntPtr value, IntPtr size, IntPtr previousValue, IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, JOBOBJECTINFOCLASS infoClass, IntPtr info, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr job, JOBOBJECTINFOCLASS infoClass, IntPtr info, uint length, IntPtr returnLength);

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
        private Process rootProcess;
        private readonly int rootProcessId;
        private readonly long rootStartTimeUtcTicks;
        private bool containmentEmpty;
        private bool reaped;
        private bool disposed;

        private HardKillJobProcess(IntPtr job, IntPtr processHandle, Process process, int processId, long startTicks, string stdoutPath, string stderrPath) {
            jobHandle = job;
            rootProcessHandle = processHandle;
            rootProcess = process;
            rootProcessId = processId;
            rootStartTimeUtcTicks = startTicks;
            StandardOutputPath = stdoutPath;
            StandardErrorPath = stderrPath;
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
        public long StartTimeUtcTicks { get { return rootStartTimeUtcTicks; } }
        public string StandardOutputPath { get; private set; }
        public string StandardErrorPath { get; private set; }
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
            if (argument.Length > 0 && argument.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0) return argument;
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
            SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.bInheritHandle = true;
            uint access = read ? GENERIC_READ : GENERIC_WRITE;
            uint share = path == null ? FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE : FILE_SHARE_READ;
            uint creation = path == null ? OPEN_EXISTING : CREATE_NEW;
            uint flags = FILE_ATTRIBUTE_NORMAL | (path == null ? 0 : FILE_FLAG_WRITE_THROUGH);
            string target = path == null ? "NUL" : Path.GetFullPath(path);
            if (path != null) {
                string parent = Path.GetDirectoryName(target);
                if (String.IsNullOrWhiteSpace(parent) || !Directory.Exists(parent)) throw new DirectoryNotFoundException("Redirect parent is missing: " + parent);
            }
            IntPtr handle = CreateFileW(target, access, share, ref attributes, creation, flags, IntPtr.Zero);
            if (handle == INVALID_HANDLE_VALUE) throw Win32("CreateFileW standard handle failed");
            return handle;
        }

        private static uint GetActiveProcessCount(IntPtr job) {
            int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
            IntPtr memory = Marshal.AllocHGlobal(size);
            try {
                if (!QueryInformationJobObject(job, JOBOBJECTINFOCLASS.JobObjectBasicAccountingInformation, memory, (uint)size, IntPtr.Zero))
                    throw Win32("QueryInformationJobObject failed");
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info = (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(memory, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                return info.ActiveProcesses;
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
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            Process managedProcess = null;
            bool processCreated = false, success = false;
            Exception failure = null;
            try {
                stdinChild = OpenChildStandardHandle(null, true);
                stdoutChild = OpenChildStandardHandle(stdout, false);
                stderrChild = OpenChildStandardHandle(stderr, false);

                job = CreateJobObjectW(IntPtr.Zero, null);
                if (job == IntPtr.Zero) throw Win32("CreateJobObject failed");
                JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits = new JOBOBJECT_EXTENDED_LIMIT_INFORMATION();
                limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
                int limitSize = Marshal.SizeOf(typeof(JOBOBJECT_EXTENDED_LIMIT_INFORMATION));
                limitMemory = Marshal.AllocHGlobal(limitSize);
                Marshal.StructureToPtr(limits, limitMemory, false);
                if (!SetInformationJobObject(job, JOBOBJECTINFOCLASS.JobObjectExtendedLimitInformation, limitMemory, (uint)limitSize))
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

                STARTUPINFOEX startup = new STARTUPINFOEX();
                startup.StartupInfo.cb = Marshal.SizeOf(typeof(STARTUPINFOEX));
                startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
                startup.StartupInfo.hStdInput = stdinChild;
                startup.StartupInfo.hStdOutput = stdoutChild;
                startup.StartupInfo.hStdError = stderrChild;
                startup.lpAttributeList = attributeList;
                uint flags = CREATE_SUSPENDED | CREATE_NO_WINDOW | CREATE_UNICODE_ENVIRONMENT | EXTENDED_STARTUPINFO_PRESENT;
                if (!CreateProcessW(executable, BuildCommandLine(executable, arguments), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero,
                    Environment.CurrentDirectory, ref startup, out process)) throw Win32("CreateProcessW failed");
                processCreated = true;

                bool inJob;
                if (!IsProcessInJob(process.hProcess, job, out inJob) || !inJob) throw Win32("IsProcessInJob failed");
                long creation, exit, kernel, user;
                if (!GetProcessTimes(process.hProcess, out creation, out exit, out kernel, out user)) throw Win32("GetProcessTimes failed");
                if (ResumeThread(process.hThread) == UInt32.MaxValue) throw Win32("ResumeThread failed");
                CloseHandle(process.hThread); process.hThread = IntPtr.Zero;
                managedProcess = Process.GetProcessById((int)process.dwProcessId);
                HardKillJobProcess result = new HardKillJobProcess(job, process.hProcess, managedProcess, (int)process.dwProcessId, creation, stdout, stderr);
                job = IntPtr.Zero; process.hProcess = IntPtr.Zero; managedProcess = null;
                success = true;
                return result;
            }
            catch (Exception error) { failure = error; throw; }
            finally {
                if (!success && processCreated) {
                    try {
                        if (job != IntPtr.Zero) TerminateJobObject(job, 1);
                        if (process.hThread != IntPtr.Zero) {
                            CloseHandle(process.hThread); process.hThread = IntPtr.Zero;
                        }
                        if (process.hProcess != IntPtr.Zero) {
                            WaitForSingleObject(process.hProcess, 5000);
                            CloseHandle(process.hProcess); process.hProcess = IntPtr.Zero;
                        }
                        if (managedProcess != null) { managedProcess.Dispose(); managedProcess = null; }
                        if (job != IntPtr.Zero && !WaitForJobEmpty(job, Stopwatch.StartNew(), 5000))
                            FailStop("start failure did not empty the Job", CombineStartAndCleanupFailure(failure, new TimeoutException("start failure did not empty the Job")));
                    }
                    catch (Exception cleanupError) { FailStop("start failure cleanup could not prove an empty Job", CombineStartAndCleanupFailure(failure, cleanupError)); }
                }
                if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
                if (stdinChild != IntPtr.Zero && stdinChild != INVALID_HANDLE_VALUE) CloseHandle(stdinChild);
                if (stdoutChild != IntPtr.Zero && stdoutChild != INVALID_HANDLE_VALUE) CloseHandle(stdoutChild);
                if (stderrChild != IntPtr.Zero && stderrChild != INVALID_HANDLE_VALUE) CloseHandle(stderrChild);
                if (attributeList != IntPtr.Zero) { DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
                if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
                if (limitMemory != IntPtr.Zero) Marshal.FreeHGlobal(limitMemory);
                if (job != IntPtr.Zero) CloseHandle(job);
            }
        }

        public void TerminateAndConfirm(int timeoutMilliseconds) {
            if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("timeoutMilliseconds");
            lock (gate) {
                if (disposed) throw new ObjectDisposedException("HardKillJobProcess");
                if (reaped) return;
                Stopwatch deadline = Stopwatch.StartNew();
                if (!containmentEmpty) {
                    try {
                        if (!TerminateJobObject(jobHandle, 1) && GetActiveProcessCount(jobHandle) != 0)
                            FailStop("TerminateJobObject failed while the Job remained non-empty", Win32("TerminateJobObject failed"));
                        if (rootProcessHandle != IntPtr.Zero) {
                            int remaining = Math.Max(0, timeoutMilliseconds - (int)Math.Min(Int32.MaxValue, deadline.ElapsedMilliseconds));
                            uint wait = WaitForSingleObject(rootProcessHandle, (uint)remaining);
                            if (wait != WAIT_OBJECT_0 && wait != WAIT_TIMEOUT)
                                FailStop("root wait failed before Job emptiness was proved", Win32("WaitForSingleObject root failed"));
                            if (!CloseHandle(rootProcessHandle))
                                FailStop("the native root process reference could not be closed before Job accounting", Win32("CloseHandle root process failed"));
                            rootProcessHandle = IntPtr.Zero;
                        }
                        if (rootProcess != null) { rootProcess.Dispose(); rootProcess = null; }
                        if (!WaitForJobEmpty(jobHandle, deadline, timeoutMilliseconds))
                            FailStop("Job ActiveProcesses did not reach zero", null);
                        if (!CloseHandle(jobHandle))
                            FailStop("the empty Job handle could not be closed", Win32("CloseHandle Job failed"));
                        jobHandle = IntPtr.Zero;
                        containmentEmpty = true;
                    }
                    catch (Exception error) { FailStop("Job reap proof failed before containment reached zero", error); }
                }
                if (!WaitForOriginalProcessIdentityGone(rootProcessId, rootStartTimeUtcTicks, deadline, timeoutMilliseconds))
                    throw new InvalidOperationException("The Job is empty, but the exact root PID/start identity has not yet disappeared.");
                reaped = true;
            }
        }

        public void Dispose() {
            lock (gate) {
                if (disposed) return;
                if (!containmentEmpty) FailStop("Dispose was called before Job ActiveProcesses reached zero", null);
                if (!reaped) throw new InvalidOperationException("The empty Job lease cannot be disposed before exact root identity disappearance is confirmed.");
                if (jobHandle != IntPtr.Zero) { CloseHandle(jobHandle); jobHandle = IntPtr.Zero; }
                disposed = true;
            }
        }
    }
}
'@
}

function Start-HardKillJobProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$ArgumentList,
        [string]$RedirectStandardOutputPath,
        [string]$RedirectStandardErrorPath
    )
    return [AiAgentDotfilesTests.HardKillJobProcess]::Start(
        [IO.Path]::GetFullPath($FilePath),
        [string[]]@($ArgumentList),
        $(if($RedirectStandardOutputPath){[IO.Path]::GetFullPath($RedirectStandardOutputPath)}else{$null}),
        $(if($RedirectStandardErrorPath){[IO.Path]::GetFullPath($RedirectStandardErrorPath)}else{$null})
    )
}

function Confirm-HardKillJobProcessReaped {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AiAgentDotfilesTests.HardKillJobProcess]$JobProcess,[int]$TimeoutMilliseconds=5000)
    $JobProcess.TerminateAndConfirm($TimeoutMilliseconds)
    return $true
}

function Close-HardKillJobProcess {
    [CmdletBinding()]
    param([AllowNull()][AiAgentDotfilesTests.HardKillJobProcess]$JobProcess)
    if($null -eq $JobProcess){return}
    if(-not $JobProcess.Reaped){$JobProcess.TerminateAndConfirm(5000)}
    $JobProcess.Dispose()
}
