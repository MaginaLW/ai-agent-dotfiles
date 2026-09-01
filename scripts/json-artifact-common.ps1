#requires -Version 7.0

Set-StrictMode -Version Latest

$script:JsonArtifactRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'semantic-json.ps1')
. (Join-Path $PSScriptRoot 'scan-input-common.ps1')

$script:JsonArtifactMaximumBytes = [long] [int]::MaxValue

if (-not ('AiAgentDotfiles.PinnedToolProcessRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using Microsoft.Win32.SafeHandles;

namespace AiAgentDotfiles
{
    public sealed class PinnedToolProcessResult
    {
        public int ExitCode { get; internal set; }
        public string Stdout { get; internal set; }
        public string Stderr { get; internal set; }
        public string Output
        {
            get { return ((Stdout ?? String.Empty) + Environment.NewLine + (Stderr ?? String.Empty)).Trim(); }
        }
    }

    internal sealed class PinnedToolOutputBudget
    {
        private readonly object gate = new object();
        private long remaining;
        internal bool Exceeded { get; private set; }

        internal PinnedToolOutputBudget(long maximumBytes)
        {
            remaining = maximumBytes;
        }

        internal int Reserve(int requested)
        {
            lock (gate)
            {
                if (requested <= remaining)
                {
                    remaining -= requested;
                    return requested;
                }
                int allowed = remaining > Int32.MaxValue ? Int32.MaxValue : (int)Math.Max(0, remaining);
                remaining = 0;
                Exceeded = true;
                return allowed;
            }
        }
    }

    public static class PinnedToolProcessRunner
    {
        private const uint CREATE_SUSPENDED = 0x00000004;
        private const uint CREATE_UNICODE_ENVIRONMENT = 0x00000400;
        private const uint EXTENDED_STARTUPINFO_PRESENT = 0x00080000;
        private const uint CREATE_NO_WINDOW = 0x08000000;
        private const uint STARTF_USESTDHANDLES = 0x00000100;
        private const uint HANDLE_FLAG_INHERIT = 0x00000001;
        private const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x00002000;
        private const uint WAIT_OBJECT_0 = 0;
        private const uint WAIT_TIMEOUT = 258;
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_HANDLE_LIST = new IntPtr(0x00020002);
        private static readonly IntPtr PROC_THREAD_ATTRIBUTE_JOB_LIST = new IntPtr(0x0002000D);

        [StructLayout(LayoutKind.Sequential)]
        private struct SECURITY_ATTRIBUTES
        {
            internal int nLength;
            internal IntPtr lpSecurityDescriptor;
            [MarshalAs(UnmanagedType.Bool)] internal bool bInheritHandle;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct STARTUPINFO
        {
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
        private struct STARTUPINFOEX
        {
            internal STARTUPINFO StartupInfo;
            internal IntPtr lpAttributeList;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct PROCESS_INFORMATION
        {
            internal IntPtr hProcess;
            internal IntPtr hThread;
            internal uint dwProcessId;
            internal uint dwThreadId;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_LIMIT_INFORMATION
        {
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
        private struct IO_COUNTERS
        {
            internal ulong ReadOperationCount;
            internal ulong WriteOperationCount;
            internal ulong OtherOperationCount;
            internal ulong ReadTransferCount;
            internal ulong WriteTransferCount;
            internal ulong OtherTransferCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_EXTENDED_LIMIT_INFORMATION
        {
            internal JOBOBJECT_BASIC_LIMIT_INFORMATION BasicLimitInformation;
            internal IO_COUNTERS IoInfo;
            internal UIntPtr ProcessMemoryLimit;
            internal UIntPtr JobMemoryLimit;
            internal UIntPtr PeakProcessMemoryUsed;
            internal UIntPtr PeakJobMemoryUsed;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct JOBOBJECT_BASIC_ACCOUNTING_INFORMATION
        {
            internal long TotalUserTime;
            internal long TotalKernelTime;
            internal long ThisPeriodTotalUserTime;
            internal long ThisPeriodTotalKernelTime;
            internal uint TotalPageFaultCount;
            internal uint TotalProcesses;
            internal uint ActiveProcesses;
            internal uint TotalTerminatedProcesses;
        }

        private enum JOBOBJECTINFOCLASS
        {
            JobObjectBasicAccountingInformation = 1,
            JobObjectExtendedLimitInformation = 9
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CreatePipe(out IntPtr readPipe, out IntPtr writePipe, ref SECURITY_ATTRIBUTES attributes, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool CreateProcessW(
            string applicationName,
            StringBuilder commandLine,
            IntPtr processAttributes,
            IntPtr threadAttributes,
            [MarshalAs(UnmanagedType.Bool)] bool inheritHandles,
            uint creationFlags,
            IntPtr environment,
            string currentDirectory,
            ref STARTUPINFOEX startupInfo,
            out PROCESS_INFORMATION processInformation);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool InitializeProcThreadAttributeList(IntPtr attributeList, int attributeCount, int flags, ref IntPtr size);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool UpdateProcThreadAttribute(
            IntPtr attributeList,
            uint flags,
            IntPtr attribute,
            IntPtr value,
            IntPtr size,
            IntPtr previousValue,
            IntPtr returnSize);

        [DllImport("kernel32.dll")]
        private static extern void DeleteProcThreadAttributeList(IntPtr attributeList);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr CreateJobObjectW(IntPtr attributes, string name);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool SetInformationJobObject(IntPtr job, JOBOBJECTINFOCLASS infoClass, IntPtr info, uint length);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool QueryInformationJobObject(IntPtr job, JOBOBJECTINFOCLASS infoClass, IntPtr info, uint length, IntPtr returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool IsProcessInJob(IntPtr process, IntPtr job, [MarshalAs(UnmanagedType.Bool)] out bool result);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateJobObject(IntPtr job, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint ResumeThread(IntPtr thread);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetExitCodeProcess(IntPtr process, out uint exitCode);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool CloseHandle(IntPtr handle);

        private static Win32Exception Win32(string operation)
        {
            return new Win32Exception(Marshal.GetLastWin32Error(), operation);
        }

        private static void CreateAnonymousPipe(out IntPtr parentEnd, out IntPtr childEnd, bool parentReads)
        {
            SECURITY_ATTRIBUTES attributes = new SECURITY_ATTRIBUTES();
            attributes.nLength = Marshal.SizeOf(typeof(SECURITY_ATTRIBUTES));
            attributes.bInheritHandle = true;
            IntPtr readPipe;
            IntPtr writePipe;
            if (!CreatePipe(out readPipe, out writePipe, ref attributes, 0))
                throw Win32("CreatePipe failed");
            parentEnd = parentReads ? readPipe : writePipe;
            childEnd = parentReads ? writePipe : readPipe;
            if (!SetHandleInformation(parentEnd, HANDLE_FLAG_INHERIT, 0))
            {
                CloseHandle(readPipe);
                CloseHandle(writePipe);
                parentEnd = IntPtr.Zero;
                childEnd = IntPtr.Zero;
                throw Win32("SetHandleInformation failed");
            }
        }

        private static string QuoteArgument(string value)
        {
            if (value == null) value = String.Empty;
            if (value.Length > 0 && value.IndexOfAny(new char[] { ' ', '\t', '\n', '\v', '"' }) < 0)
                return value;
            StringBuilder result = new StringBuilder();
            result.Append('"');
            int backslashes = 0;
            foreach (char character in value)
            {
                if (character == '\\')
                {
                    backslashes++;
                    continue;
                }
                if (character == '"')
                {
                    result.Append('\\', backslashes * 2 + 1);
                    result.Append('"');
                    backslashes = 0;
                    continue;
                }
                result.Append('\\', backslashes);
                backslashes = 0;
                result.Append(character);
            }
            result.Append('\\', backslashes * 2);
            result.Append('"');
            return result.ToString();
        }

        private static StringBuilder BuildCommandLine(string executablePath, string[] arguments)
        {
            StringBuilder commandLine = new StringBuilder(QuoteArgument(executablePath));
            foreach (string argument in arguments)
            {
                commandLine.Append(' ');
                commandLine.Append(QuoteArgument(argument));
            }
            return commandLine;
        }

        private static Task<byte[]> BeginDrain(FileStream stream, PinnedToolOutputBudget budget)
        {
            return Task.Factory.StartNew<byte[]>(delegate
            {
                using (stream)
                using (MemoryStream captured = new MemoryStream())
                {
                    byte[] buffer = new byte[8192];
                    int count;
                    while ((count = stream.Read(buffer, 0, buffer.Length)) > 0)
                    {
                        int allowed = budget.Reserve(count);
                        if (allowed > 0) captured.Write(buffer, 0, allowed);
                    }
                    return captured.ToArray();
                }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        private static Task BeginWrite(FileStream stream, byte[] input)
        {
            byte[] privateInput = input == null ? new byte[0] : (byte[])input.Clone();
            return Task.Factory.StartNew(delegate
            {
                using (stream)
                {
                    if (privateInput.Length > 0) stream.Write(privateInput, 0, privateInput.Length);
                    stream.Flush();
                }
            }, CancellationToken.None, TaskCreationOptions.LongRunning, TaskScheduler.Default);
        }

        private static uint GetActiveProcessCount(IntPtr job)
        {
            int size = Marshal.SizeOf(typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
            IntPtr memory = Marshal.AllocHGlobal(size);
            try
            {
                if (!QueryInformationJobObject(job, JOBOBJECTINFOCLASS.JobObjectBasicAccountingInformation, memory, (uint)size, IntPtr.Zero))
                    throw Win32("QueryInformationJobObject failed");
                JOBOBJECT_BASIC_ACCOUNTING_INFORMATION info =
                    (JOBOBJECT_BASIC_ACCOUNTING_INFORMATION)Marshal.PtrToStructure(memory, typeof(JOBOBJECT_BASIC_ACCOUNTING_INFORMATION));
                return info.ActiveProcesses;
            }
            finally { Marshal.FreeHGlobal(memory); }
        }

        private static bool WaitForJobEmpty(IntPtr job, Stopwatch clock, int totalMilliseconds)
        {
            try
            {
                while (clock.ElapsedMilliseconds < totalMilliseconds)
                {
                    if (GetActiveProcessCount(job) == 0) return true;
                    Thread.Sleep(5);
                }
                return GetActiveProcessCount(job) == 0;
            }
            catch { return false; }
        }

        private static bool WaitTask(Task task, Stopwatch clock, int totalMilliseconds)
        {
            int remaining = totalMilliseconds - (int)clock.ElapsedMilliseconds;
            if (remaining <= 0) return task.IsCompleted;
            try { return task.IsCompleted || task.Wait(remaining); }
            catch (AggregateException) { return true; }
        }

        private static void FailFast(string message, Exception cause)
        {
            Environment.FailFast("pinned-tool-process-reap-failed: " + message, cause);
        }

        public static PinnedToolProcessResult Run(
            string executablePath,
            string[] arguments,
            byte[] standardInput,
            bool useStandardInput,
            int timeoutMilliseconds,
            int reapTimeoutMilliseconds,
            long maximumCombinedOutputBytes)
        {
            if (String.IsNullOrWhiteSpace(executablePath)) throw new ArgumentException("Executable path is required.", "executablePath");
            executablePath = Path.GetFullPath(executablePath);
            if (arguments == null) arguments = new string[0];
            arguments = (string[])arguments.Clone();
            if (timeoutMilliseconds <= 0 || reapTimeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException("Pinned tool timeouts must be positive.");
            if (maximumCombinedOutputBytes <= 0) throw new ArgumentOutOfRangeException("maximumCombinedOutputBytes");

            IntPtr stdinParent = IntPtr.Zero, stdinChild = IntPtr.Zero;
            IntPtr stdoutParent = IntPtr.Zero, stdoutChild = IntPtr.Zero;
            IntPtr stderrParent = IntPtr.Zero, stderrChild = IntPtr.Zero;
            IntPtr attributeList = IntPtr.Zero, handleList = IntPtr.Zero, jobList = IntPtr.Zero;
            IntPtr job = IntPtr.Zero, limitMemory = IntPtr.Zero;
            PROCESS_INFORMATION process = new PROCESS_INFORMATION();
            bool processCreated = false, assigned = false, jobEmpty = false;
            FileStream stdinStream = null, stdoutStream = null, stderrStream = null;
            Task writer = null;
            Task<byte[]> stdoutReader = null, stderrReader = null;
            Exception failure = null;
            uint rootExitCode = 0;
            PinnedToolOutputBudget budget = new PinnedToolOutputBudget(maximumCombinedOutputBytes);

            try
            {
                CreateAnonymousPipe(out stdinParent, out stdinChild, false);
                CreateAnonymousPipe(out stdoutParent, out stdoutChild, true);
                CreateAnonymousPipe(out stderrParent, out stderrChild, true);

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
                if (!InitializeProcThreadAttributeList(attributeList, 2, 0, ref attributeSize))
                    throw Win32("InitializeProcThreadAttributeList failed");
                handleList = Marshal.AllocHGlobal(IntPtr.Size * 3);
                Marshal.WriteIntPtr(handleList, 0, stdinChild);
                Marshal.WriteIntPtr(handleList, IntPtr.Size, stdoutChild);
                Marshal.WriteIntPtr(handleList, IntPtr.Size * 2, stderrChild);
                if (!UpdateProcThreadAttribute(attributeList, 0, PROC_THREAD_ATTRIBUTE_HANDLE_LIST, handleList, new IntPtr(IntPtr.Size * 3), IntPtr.Zero, IntPtr.Zero))
                    throw Win32("UpdateProcThreadAttribute failed");
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
                if (!CreateProcessW(executablePath, BuildCommandLine(executablePath, arguments), IntPtr.Zero, IntPtr.Zero, true, flags, IntPtr.Zero, null, ref startup, out process))
                    throw Win32("CreateProcessW failed");
                processCreated = true;
                assigned = true;

                CloseHandle(stdinChild); stdinChild = IntPtr.Zero;
                CloseHandle(stdoutChild); stdoutChild = IntPtr.Zero;
                CloseHandle(stderrChild); stderrChild = IntPtr.Zero;

                bool inJob;
                if (!IsProcessInJob(process.hProcess, job, out inJob) || !inJob)
                    throw Win32("IsProcessInJob failed");

                stdinStream = new FileStream(new SafeFileHandle(stdinParent, true), FileAccess.Write, 4096, false); stdinParent = IntPtr.Zero;
                stdoutStream = new FileStream(new SafeFileHandle(stdoutParent, true), FileAccess.Read, 4096, false); stdoutParent = IntPtr.Zero;
                stderrStream = new FileStream(new SafeFileHandle(stderrParent, true), FileAccess.Read, 4096, false); stderrParent = IntPtr.Zero;
                stdoutReader = BeginDrain(stdoutStream, budget); stdoutStream = null;
                stderrReader = BeginDrain(stderrStream, budget); stderrStream = null;
                writer = BeginWrite(stdinStream, useStandardInput ? standardInput : null); stdinStream = null;

                if (ResumeThread(process.hThread) == UInt32.MaxValue) throw Win32("ResumeThread failed");
                CloseHandle(process.hThread); process.hThread = IntPtr.Zero;

                Stopwatch execution = Stopwatch.StartNew();
                Stopwatch descendantExit = null;
                bool rootExited = false;
                while (true)
                {
                    if (budget.Exceeded) { failure = new InvalidOperationException("Pinned tool output exceeded the configured byte limit."); break; }
                    if (writer.IsFaulted) { failure = new InvalidOperationException("Pinned tool input write failed.", writer.Exception); break; }
                    if (stdoutReader.IsFaulted || stderrReader.IsFaulted) { failure = new InvalidOperationException("Pinned tool output drain failed."); break; }
                    if (execution.ElapsedMilliseconds >= timeoutMilliseconds) { failure = new TimeoutException("Pinned tool execution timed out."); break; }
                    if (!rootExited)
                    {
                        uint rootWait = WaitForSingleObject(process.hProcess, 0);
                        if (rootWait == WAIT_OBJECT_0)
                        {
                            if (!GetExitCodeProcess(process.hProcess, out rootExitCode)) throw Win32("GetExitCodeProcess failed");
                            CloseHandle(process.hProcess); process.hProcess = IntPtr.Zero;
                            rootExited = true;
                            descendantExit = Stopwatch.StartNew();
                        }
                        else if (rootWait != WAIT_TIMEOUT)
                        {
                            throw Win32("WaitForSingleObject failed");
                        }
                    }
                    if (rootExited)
                    {
                        if (GetActiveProcessCount(job) == 0) break;
                        if (descendantExit.ElapsedMilliseconds >= reapTimeoutMilliseconds)
                        {
                            failure = new InvalidOperationException("Pinned tool left descendant processes after its primary process exited.");
                            break;
                        }
                    }
                    Thread.Sleep(5);
                }

                if (failure != null)
                {
                    Stopwatch reap = Stopwatch.StartNew();
                    if (!TerminateJobObject(job, 1) && GetActiveProcessCount(job) != 0)
                        failure = new InvalidOperationException("TerminateJobObject failed.", Win32("TerminateJobObject failed"));
                    if (process.hThread != IntPtr.Zero) { CloseHandle(process.hThread); process.hThread = IntPtr.Zero; }
                    if (process.hProcess != IntPtr.Zero) { CloseHandle(process.hProcess); process.hProcess = IntPtr.Zero; }
                    if (!WaitForJobEmpty(job, reap, reapTimeoutMilliseconds))
                        FailFast("the process job did not become empty after termination.", failure);
                    if (!WaitTask(writer, reap, reapTimeoutMilliseconds) ||
                        !WaitTask(stdoutReader, reap, reapTimeoutMilliseconds) ||
                        !WaitTask(stderrReader, reap, reapTimeoutMilliseconds))
                        FailFast("the process pipes did not close after the job became empty.", failure);
                }
                else
                {
                    Stopwatch drain = Stopwatch.StartNew();
                    if (!WaitTask(writer, drain, reapTimeoutMilliseconds) ||
                        !WaitTask(stdoutReader, drain, reapTimeoutMilliseconds) ||
                        !WaitTask(stderrReader, drain, reapTimeoutMilliseconds))
                        FailFast("the process pipes did not close after the job became empty.", failure);
                }
                try { jobEmpty = GetActiveProcessCount(job) == 0; }
                catch (Exception queryFailure) { FailFast("job accounting failed at the release boundary.", queryFailure); }
                if (!jobEmpty) FailFast("the process job was not empty at the release boundary.", failure);

                if (failure == null)
                {
                    if (writer.IsFaulted) failure = new InvalidOperationException("Pinned tool input write failed.", writer.Exception);
                    else if (stdoutReader.IsFaulted || stderrReader.IsFaulted) failure = new InvalidOperationException("Pinned tool output drain failed.");
                    else if (budget.Exceeded) failure = new InvalidOperationException("Pinned tool output exceeded the configured byte limit.");
                }
                if (failure != null) throw failure;

                return new PinnedToolProcessResult
                {
                    ExitCode = unchecked((int)rootExitCode),
                    Stdout = new UTF8Encoding(false, false).GetString(stdoutReader.Result),
                    Stderr = new UTF8Encoding(false, false).GetString(stderrReader.Result)
                };
            }
            catch (Exception error)
            {
                if (failure == null) failure = error;
                if (processCreated && !jobEmpty)
                {
                    if (assigned)
                    {
                        Stopwatch setupReap = Stopwatch.StartNew();
                        try { TerminateJobObject(job, 1); } catch { }
                        if (process.hThread != IntPtr.Zero) { CloseHandle(process.hThread); process.hThread = IntPtr.Zero; }
                        if (process.hProcess != IntPtr.Zero) { CloseHandle(process.hProcess); process.hProcess = IntPtr.Zero; }
                        if (!WaitForJobEmpty(job, setupReap, reapTimeoutMilliseconds))
                            FailFast("setup failure left a non-empty process job.", failure);
                        if ((writer != null && !WaitTask(writer, setupReap, reapTimeoutMilliseconds)) ||
                            (stdoutReader != null && !WaitTask(stdoutReader, setupReap, reapTimeoutMilliseconds)) ||
                            (stderrReader != null && !WaitTask(stderrReader, setupReap, reapTimeoutMilliseconds)))
                            FailFast("setup failure left process pipe tasks active after the job became empty.", failure);
                    }
                    else
                    {
                        try { TerminateProcess(process.hProcess, 1); } catch { }
                        if (WaitForSingleObject(process.hProcess, (uint)reapTimeoutMilliseconds) != WAIT_OBJECT_0)
                            FailFast("setup failure left the suspended primary process alive.", failure);
                    }
                }
                throw;
            }
            finally
            {
                if (stdinStream != null) stdinStream.Dispose();
                if (stdoutStream != null) stdoutStream.Dispose();
                if (stderrStream != null) stderrStream.Dispose();
                if (process.hThread != IntPtr.Zero) CloseHandle(process.hThread);
                if (process.hProcess != IntPtr.Zero) CloseHandle(process.hProcess);
                if (job != IntPtr.Zero) CloseHandle(job);
                if (stdinParent != IntPtr.Zero) CloseHandle(stdinParent);
                if (stdinChild != IntPtr.Zero) CloseHandle(stdinChild);
                if (stdoutParent != IntPtr.Zero) CloseHandle(stdoutParent);
                if (stdoutChild != IntPtr.Zero) CloseHandle(stdoutChild);
                if (stderrParent != IntPtr.Zero) CloseHandle(stderrParent);
                if (stderrChild != IntPtr.Zero) CloseHandle(stderrChild);
                if (attributeList != IntPtr.Zero) { DeleteProcThreadAttributeList(attributeList); Marshal.FreeHGlobal(attributeList); }
                if (handleList != IntPtr.Zero) Marshal.FreeHGlobal(handleList);
                if (jobList != IntPtr.Zero) Marshal.FreeHGlobal(jobList);
                if (limitMemory != IntPtr.Zero) Marshal.FreeHGlobal(limitMemory);
            }
        }
    }
}
'@
}

function Get-PinnedToolLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $capture = Read-PinnedToolLockCapture -Path $Path
    $full = $capture.FullPath
    $lock = $capture.Document
    foreach ($field in @('SchemaVersion', 'ToolKind', 'Version', 'AssetName', 'AssetUrl', 'ReleaseUrl', 'AssetSha256', 'ExecutableName', 'ExecutableSha256', 'VersionArguments', 'ExpectedVersionPattern', 'LicenseIdentifier', 'LicenseUrl')) {
        if (-not $lock.Contains($field)) { throw "Pinned tool lock is missing $field`: $full" }
    }
    if ([long] $lock.SchemaVersion -ne 1) { throw "Unsupported pinned tool lock version: $($lock.SchemaVersion)" }
    if ([string] $lock.AssetSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Pinned tool asset SHA-256 must be lowercase hexadecimal.' }
    if ([string] $lock.ExecutableSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Pinned tool executable SHA-256 must be lowercase hexadecimal.' }
    if ([string] $lock.AssetUrl -notmatch '^https://github\.com/[^/]+/[^/]+/releases/download/') { throw 'Pinned tool asset URL must be an official GitHub release asset URL.' }
    if ([System.IO.Path]::GetFileName([string] $lock.AssetUrl) -cne [string] $lock.AssetName) { throw 'Pinned tool asset name does not match its URL.' }
    return $lock
}

function Read-PinnedToolLockCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $full=[IO.Path]::GetFullPath($Path)
    $parents=$null;$handle=$null
    try{
        $parentsReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $full) -OwnershipReceiver $parentsReceiver
        $parents=$parentsReceiver.GetDeliveredExact()
        $handle=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parents[$parents.Count-1],[IO.Path]::GetFileName($full))
        $bytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($handle,$script:JsonArtifactMaximumBytes)
        $document=ConvertFrom-SemanticJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
        return [pscustomobject]@{FullPath=$full;Bytes=$bytes;Document=$document;Sha256=[string]$handle.ReadResult.Sha256;Identity=[string]$handle.ReadResult.Identity}
    }
    finally{
        if($handle){$handle.Dispose()}
        if($parents){Close-SafeDirectoryContainmentChain -Handles $parents}
    }
}

function Get-PinnedToolCacheRoot {
    [CmdletBinding()]
    param([string] $CacheRoot)

    if ($CacheRoot) { return [System.IO.Path]::GetFullPath($CacheRoot) }
    $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if ([string]::IsNullOrWhiteSpace($local)) { throw 'The OS LocalApplicationData known folder is unavailable.' }
    return Join-Path $local 'ai-agent-dotfiles/tool-cache'
}

function Get-PinnedToolPaths {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Lock, [string] $CacheRoot)

    $root = Join-Path (Get-PinnedToolCacheRoot -CacheRoot $CacheRoot) (Join-Path ([string] $Lock.ToolKind) ([string] $Lock.Version))
    return [pscustomobject]@{
        Root = $root
        Archive = Join-Path $root ([string] $Lock.AssetName)
        Executable = Join-Path $root (Join-Path 'bin' ([string] $Lock.ExecutableName))
    }
}

function Invoke-PinnedToolProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ToolLease,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments,
        [AllowNull()] [byte[]] $StandardInputBytes,
        [Parameter(Mandatory)] [string] $Operation,
        [int] $TimeoutMilliseconds = 120000,
        [int] $ReapTimeoutMilliseconds = 5000,
        [long] $MaximumCombinedOutputBytes = 1048576
    )

    if ($TimeoutMilliseconds -le 0 -or $ReapTimeoutMilliseconds -le 0 -or $MaximumCombinedOutputBytes -le 0) {
        throw 'Pinned tool process limits must be positive.'
    }
    if ([bool] $ToolLease.Closed -or $null -eq $ToolLease.ExecutableHandle) { throw 'Pinned tool execution lease is closed.' }
    $heldExecutableBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes(
        $ToolLease.ExecutableHandle,
        [long] $ToolLease.ExecutableHandle.ReadResult.Length
    )
    $heldExecutableSha = [Convert]::ToHexString(
        [Security.Cryptography.SHA256]::HashData($heldExecutableBytes)
    ).ToLowerInvariant()
    if ($heldExecutableSha -cne [string] $ToolLease.ExecutableSha256) {
        throw 'Pinned tool execution lease changed before launch.'
    }
    $executablePath = [IO.Path]::GetFullPath([string] $ToolLease.Paths.Executable)
    $parentHandle = $ToolLease.ExecutableParentHandles[$ToolLease.ExecutableParentHandles.Count - 1]
    $relativeInfo = [AiAgentDotfiles.NoFollowFile]::InspectChild($parentHandle, [IO.Path]::GetFileName($executablePath))
    if ([string] $relativeInfo.Identity -cne [string] $ToolLease.ExecutableHandle.Info.Identity) {
        throw 'Pinned tool execution path is detached from its held executable identity.'
    }

    $hasStandardInput = $PSBoundParameters.ContainsKey('StandardInputBytes')
    $nativeResult = [AiAgentDotfiles.PinnedToolProcessRunner]::Run(
        $executablePath,
        [string[]] @($Arguments),
        $(if ($hasStandardInput) { [byte[]] $StandardInputBytes } else { $null }),
        $hasStandardInput,
        $TimeoutMilliseconds,
        $ReapTimeoutMilliseconds,
        $MaximumCombinedOutputBytes
    )
    $postBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes(
        $ToolLease.ExecutableHandle,
        [long] $ToolLease.ExecutableHandle.ReadResult.Length
    )
    $postSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($postBytes)).ToLowerInvariant()
    if ($postSha -cne [string] $ToolLease.ExecutableSha256) {
        throw 'Pinned tool execution lease changed during launch.'
    }
    return $nativeResult
}

function Test-PinnedToolVersion {
    param([Parameter(Mandatory)] $ToolLease)

    $lock = $ToolLease.Lock
    $processResult = Invoke-PinnedToolProcess `
        -ToolLease $ToolLease `
        -Arguments @($lock.VersionArguments | ForEach-Object { [string] $_ }) `
        -Operation "Pinned $($lock.ToolKind) version probe"
    $output = [string] $processResult.Output
    if ($processResult.ExitCode -ne 0) { throw "Pinned $($lock.ToolKind) version probe failed with exit code $($processResult.ExitCode)`: $output" }
    if ($output -notmatch [string] $lock.ExpectedVersionPattern) { throw "Pinned $($lock.ToolKind) version output did not match the lock: $output" }
    return $output
}

function Close-PinnedToolLease {
    [CmdletBinding()]
    param([AllowNull()] $ToolLease)

    if ($null -eq $ToolLease -or [bool] $ToolLease.Closed) { return }
    $ToolLease.Closed = $true
    $failure = $null
    try { if ($ToolLease.ExecutableHandle) { $ToolLease.ExecutableHandle.Dispose() } } catch { $failure = $_ }
    try { if ($ToolLease.ExecutableParentHandles) { Close-SafeDirectoryContainmentChain -Handles $ToolLease.ExecutableParentHandles } } catch { if ($null -eq $failure) { $failure = $_ } }
    try { if ($ToolLease.ArchiveHandle) { $ToolLease.ArchiveHandle.Dispose() } } catch { if ($null -eq $failure) { $failure = $_ } }
    try { if ($ToolLease.ArchiveParentHandles) { Close-SafeDirectoryContainmentChain -Handles $ToolLease.ArchiveParentHandles } } catch { if ($null -eq $failure) { $failure = $_ } }
    try { if ($ToolLease.LockCapture -and $ToolLease.LockCapture.HeldHandle) { $ToolLease.LockCapture.HeldHandle.Dispose() } } catch { if ($null -eq $failure) { $failure = $_ } }
    try { if ($ToolLease.LockParentHandles) { Close-SafeDirectoryContainmentChain -Handles $ToolLease.LockParentHandles } } catch { if ($null -eq $failure) { $failure = $_ } }
    if ($failure) { throw $failure }
}

function Open-PinnedToolLease {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot)

    $lockFull = [IO.Path]::GetFullPath($LockPath)
    $lockParentHandles = $null
    $lockHandle = $null
    $archiveParentHandles = $null
    $archiveHandle = $null
    $executableParentHandles = $null
    $executableHandle = $null
    $lease = $null
    try {
        $lockParentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $lockFull) -OwnershipReceiver $lockParentHandlesReceiver
        $lockParentHandles = $lockParentHandlesReceiver.GetDeliveredExact()
        $lockHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($lockParentHandles[$lockParentHandles.Count - 1], [IO.Path]::GetFileName($lockFull))
        $lockBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($lockHandle, $script:JsonArtifactMaximumBytes)
        $lock = ConvertFrom-SemanticJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($lockBytes))
        foreach ($field in @('SchemaVersion','ToolKind','Version','AssetName','AssetUrl','ReleaseUrl','AssetSha256','ExecutableName','ExecutableSha256','VersionArguments','ExpectedVersionPattern','LicenseIdentifier','LicenseUrl')) {
            if (-not $lock.Contains($field)) { throw "Pinned tool lock is missing $field`: $lockFull" }
        }
        if ([long]$lock.SchemaVersion -ne 1 -or [string]$lock.AssetSha256 -cnotmatch '^[0-9a-f]{64}$' -or [string]$lock.ExecutableSha256 -cnotmatch '^[0-9a-f]{64}$') { throw "Pinned tool lock is invalid: $lockFull" }
        $paths = Get-PinnedToolPaths -Lock $lock -CacheRoot $CacheRoot
        try { $archiveParentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new(); Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $paths.Archive) -OwnershipReceiver $archiveParentHandlesReceiver; $archiveParentHandles = $archiveParentHandlesReceiver.GetDeliveredExact() }
        catch { throw "Pinned $($lock.ToolKind) is not installed: $($paths.Archive)" }
        $archiveHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($archiveParentHandles[$archiveParentHandles.Count - 1], [IO.Path]::GetFileName($paths.Archive))
        if ([string]$archiveHandle.ReadResult.Sha256 -cne [string]$lock.AssetSha256) { throw "Pinned $($lock.ToolKind) archive hash mismatch." }
        try { $executableParentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new(); Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $paths.Executable) -OwnershipReceiver $executableParentHandlesReceiver; $executableParentHandles = $executableParentHandlesReceiver.GetDeliveredExact() }
        catch { throw "Pinned $($lock.ToolKind) is not installed: $($paths.Executable)" }
        $executableHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($executableParentHandles[$executableParentHandles.Count - 1], [IO.Path]::GetFileName($paths.Executable))
        if ([string]$executableHandle.ReadResult.Sha256 -cne [string]$lock.ExecutableSha256) { throw "Pinned $($lock.ToolKind) executable hash mismatch." }
        $lease = [pscustomobject][ordered]@{
            Lock=$lock;Paths=$paths;LockCapture=[pscustomobject]@{FullPath=$lockFull;Bytes=$lockBytes;Sha256=[string]$lockHandle.ReadResult.Sha256;Identity=[string]$lockHandle.ReadResult.Identity;HeldHandle=$lockHandle}
            LockParentHandles=$lockParentHandles;ArchiveHandle=$archiveHandle;ArchiveParentHandles=$archiveParentHandles
            ExecutableHandle=$executableHandle;ExecutableParentHandles=$executableParentHandles
            ExecutableSha256=[string]$executableHandle.ReadResult.Sha256;ExecutableIdentity=[string]$executableHandle.ReadResult.Identity
            VersionOutput=$null;Closed=$false
        }
        $versionOutput = Test-PinnedToolVersion -ToolLease $lease
        $lease.VersionOutput = $versionOutput
        return $lease
    }
    catch {
        $primary = $_
        if ($lease) { try { Close-PinnedToolLease -ToolLease $lease } catch {} }
        else {
            if ($executableHandle) { $executableHandle.Dispose() }
            if ($executableParentHandles) { Close-SafeDirectoryContainmentChain -Handles $executableParentHandles }
            if ($archiveHandle) { $archiveHandle.Dispose() }
            if ($archiveParentHandles) { Close-SafeDirectoryContainmentChain -Handles $archiveParentHandles }
            if ($lockHandle) { $lockHandle.Dispose() }
            if ($lockParentHandles) { Close-SafeDirectoryContainmentChain -Handles $lockParentHandles }
        }
        throw $primary
    }
}

function Assert-PinnedToolInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot)

    $lease = $null
    try {
        $lease = Open-PinnedToolLease -LockPath $LockPath -CacheRoot $CacheRoot
        return [pscustomobject]@{Lock=$lease.Lock;Paths=$lease.Paths;ExecutableSha256=$lease.ExecutableSha256;ExecutableIdentity=$lease.ExecutableIdentity;VersionOutput=$lease.VersionOutput}
    }
    finally { if ($lease) { Close-PinnedToolLease -ToolLease $lease } }
}

function Install-PinnedTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot, [switch] $VerifyOnly)

    $lock = Get-PinnedToolLock -Path $LockPath
    $paths = Get-PinnedToolPaths -Lock $lock -CacheRoot $CacheRoot
    if ($VerifyOnly) { return Assert-PinnedToolInstalled -LockPath $LockPath -CacheRoot $CacheRoot }
    if (Test-Path -LiteralPath $paths.Root) { return Assert-PinnedToolInstalled -LockPath $LockPath -CacheRoot $CacheRoot }

    $parent = Split-Path -Parent $paths.Root
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $candidate = Join-Path $parent ".install-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
    try {
        $archive = Join-Path $candidate ([string] $lock.AssetName)
        Invoke-WebRequest -UseBasicParsing -Uri ([string] $lock.AssetUrl) -OutFile $archive
        $archiveHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($archiveHash -cne [string] $lock.AssetSha256) { throw "Downloaded $($lock.ToolKind) archive hash mismatch." }
        $expanded = Join-Path $candidate 'expanded'
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded
        $matches = @(Get-ChildItem -LiteralPath $expanded -File -Recurse -Filter ([string] $lock.ExecutableName))
        if ($matches.Count -ne 1) { throw "Pinned archive must contain exactly one $($lock.ExecutableName)." }
        $bin = Join-Path $candidate 'bin'
        [System.IO.Directory]::CreateDirectory($bin) | Out-Null
        Copy-Item -LiteralPath $matches[0].FullName -Destination (Join-Path $bin ([string] $lock.ExecutableName))
        Remove-Item -LiteralPath $expanded -Recurse -Force
        $candidateExecutable = Join-Path $bin ([string] $lock.ExecutableName)
        $candidateExecutableHash = (Get-FileHash -LiteralPath $candidateExecutable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($candidateExecutableHash -cne [string]$lock.ExecutableSha256) { throw "Pinned $($lock.ToolKind) executable hash mismatch." }
        try { [System.IO.Directory]::Move($candidate, $paths.Root) }
        catch {
            if (-not (Test-Path -LiteralPath $paths.Root -PathType Container)) { throw }
            Remove-Item -LiteralPath $candidate -Recurse -Force
        }
        return Assert-PinnedToolInstalled -LockPath $LockPath -CacheRoot $CacheRoot
    }
    finally {
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    }
}

function Assert-NoReparseExistingChain {
    param([Parameter(Mandatory)] [string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    $current = $root.TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    if ($current.EndsWith(':')) { $current += [System.IO.Path]::DirectorySeparatorChar }
    $relative = $full.Substring($root.Length)
    foreach ($part in @($relative -split '[\\/]' | Where-Object { $_ })) {
        $current = Join-Path $current $part
        if (-not (Test-Path -LiteralPath $current)) { break }
        $info = [AiAgentDotfiles.NoFollowFile]::Inspect($current)
        if ($info.IsReparsePoint) { throw "Path chain contains a reparse point: $current" }
    }
}

function Test-PathEqualsOrInside {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Root)
    return Test-PathInsideRoot -Path $Path -Root $Root
}

function Resolve-PrivateArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('ExternalUserArtifact', 'InternalContractPath', 'EvidenceInputPath')] [string] $Role,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $InternalRoot,
        [string[]] $EvidenceRoots = @(),
        [string[]] $ForbiddenRoots = @(),
        [switch] $AllowMissingLeaf
    )

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $full = [System.IO.Path]::GetFullPath($Path)
    $protected = @(Get-ProtectedReasonixRelativePaths | ForEach-Object { [System.IO.Path]::GetFullPath((Join-Path $repo $_)) })
    if ($protected -contains $full) { throw 'Protected Reasonix path cannot be used as an artifact or evidence path.' }

    $gitDir = (& git -C $repo rev-parse --absolute-git-dir 2>$null).Trim()
    $commonDir = (& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Git private directories.' }
    $homeRoot = [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)

    switch ($Role) {
        'ExternalUserArtifact' {
            foreach ($root in @($repo, $gitDir, $commonDir) + @($ForbiddenRoots)) {
                if ($root -and ((Test-PathEqualsOrInside -Path $full -Root $root) -or (Test-PathEqualsOrInside -Path $root -Root $full))) {
                    throw "External user artifact must be disjoint from worktree, Git internals, and safety roots: $full"
                }
            }
            if ($full.TrimEnd([char]92) -ieq $volumeRoot.TrimEnd([char]92) -or ($homeRoot -and $full.TrimEnd([char]92) -ieq $homeRoot.TrimEnd([char]92))) {
                throw 'External user artifact cannot be a volume or HomeRoot root.'
            }
        }
        'InternalContractPath' {
            if ([string]::IsNullOrWhiteSpace($InternalRoot)) { throw 'InternalContractPath requires one exact InternalRoot.' }
            if (-not (Test-PathEqualsOrInside -Path $full -Root $InternalRoot)) { throw 'Internal contract path is outside its registered namespace.' }
        }
        'EvidenceInputPath' {
            if ($EvidenceRoots.Count -eq 0) { throw 'EvidenceInputPath requires an operation-specific allowlist.' }
            $allowed = $false
            foreach ($root in $EvidenceRoots) { if (Test-PathEqualsOrInside -Path $full -Root $root) { $allowed = $true; break } }
            if (-not $allowed) { throw 'Evidence input is outside its operation allowlist.' }
        }
    }

    Assert-NoReparseExistingChain -Path $full
    $exists = Test-Path -LiteralPath $full -PathType Leaf
    if (-not $exists -and -not $AllowMissingLeaf) { throw "Artifact or evidence path is missing: $full" }
    if (-not $exists) { return [pscustomobject]@{ FullPath = $full; Exists = $false; Identity = 'MISSING'; LinkCount = 0; NamedStreamCount = 0 } }

    $info = [AiAgentDotfiles.NoFollowFile]::Inspect($full)
    if ($info.IsDirectory -or $info.IsReparsePoint) { throw "Path is not a regular no-follow file: $full" }
    if ($info.LinkCount -ne 1) { throw "Path has multiple hard links: $full" }
    $streams = @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($full))
    if ($streams.Count -ne 0) { throw "Path has named alternate data streams: $full" }
    $after = [AiAgentDotfiles.NoFollowFile]::Inspect($full)
    if ($after.Identity -cne $info.Identity -or $after.Length -ne $info.Length) { throw "Path identity changed during validation: $full" }
    return [pscustomobject]@{ FullPath = $full; Exists = $true; Identity = $info.Identity; LinkCount = [int] $info.LinkCount; NamedStreamCount = $streams.Count; Length = [long] $info.Length }
}

function Assert-ExactJsonArtifactCapture {
    param([Parameter(Mandatory)] $Capture)

    if ($Capture.PSObject.TypeNames[0] -cne 'AiAgentDotfiles.ExactJsonArtifactCapture') {
        throw 'JSON artifact capture is not a trusted exact-byte capture.'
    }
    foreach ($field in @('FullPath', 'Bytes', 'Sha256', 'Document', 'Identity', 'Length')) {
        if ($field -notin @($Capture.PSObject.Properties.Name)) { throw "JSON artifact capture is missing $field." }
    }
    $bytes = [byte[]] ([byte[]] $Capture.Bytes).Clone()
    if ([long] $Capture.Length -ne $bytes.LongLength) { throw 'JSON artifact capture length is inconsistent.' }
    $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($hash -cne [string] $Capture.Sha256) { throw 'JSON artifact capture hash is inconsistent.' }
    $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    $parsedDocument = ConvertFrom-SemanticJson -Json $json
    $validated = [pscustomobject][ordered]@{
        FullPath = [System.IO.Path]::GetFullPath([string] $Capture.FullPath)
        Bytes = $bytes
        Sha256 = $hash
        Document = $parsedDocument
        Identity = [string] $Capture.Identity
        Length = [long] $Capture.Length
    }
    $validated.PSObject.TypeNames.Insert(0, 'AiAgentDotfiles.ExactJsonArtifactCapture')
    return $validated
}

function Read-ExactJsonArtifactCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('ExternalUserArtifact', 'InternalContractPath', 'EvidenceInputPath')] [string] $Role,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $InternalRoot,
        [string[]] $EvidenceRoots = @(),
        [string[]] $ForbiddenRoots = @(),
        [long] $MaximumBytes = $script:JsonArtifactMaximumBytes
    )

    if ($MaximumBytes -lt 0) { throw 'JSON artifact maximum byte length must be non-negative.' }
    $resolveArguments = @{
        Path = $Path
        Role = $Role
        RepoRoot = $RepoRoot
        EvidenceRoots = $EvidenceRoots
        ForbiddenRoots = $ForbiddenRoots
    }
    if ($InternalRoot) { $resolveArguments.InternalRoot = $InternalRoot }
    $evidence = Resolve-PrivateArtifactPath @resolveArguments
    $parentPath = Split-Path -Parent $evidence.FullPath
    $leafName = [System.IO.Path]::GetFileName($evidence.FullPath)
    $directoryHandles = $null
    $fileHandle = $null
    try {
        $directoryHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $parentPath -OwnershipReceiver $directoryHandlesReceiver
        $directoryHandles = $directoryHandlesReceiver.GetDeliveredExact()
        if ($directoryHandles.Count -eq 0) { throw "Unable to hold the JSON artifact parent directory: $parentPath" }
        $fileHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($directoryHandles[$directoryHandles.Count - 1], $leafName)
        if ([string] $fileHandle.Info.Identity -cne [string] $evidence.Identity -or [long] $fileHandle.Info.Length -ne [long] $evidence.Length) {
            throw "JSON artifact identity changed while opening its held handle: $($evidence.FullPath)"
        }
        $bytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($fileHandle, $MaximumBytes)
        $json = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $document = ConvertFrom-SemanticJson -Json $json
        $capture = [pscustomobject][ordered]@{
            FullPath = [string] $evidence.FullPath
            Bytes = [byte[]] $bytes
            Sha256 = [string] $fileHandle.ReadResult.Sha256
            Document = $document
            Identity = [string] $fileHandle.ReadResult.Identity
            Length = [long] $fileHandle.ReadResult.Length
        }
        $capture.PSObject.TypeNames.Insert(0, 'AiAgentDotfiles.ExactJsonArtifactCapture')
        return Assert-ExactJsonArtifactCapture -Capture $capture
    }
    finally {
        if ($null -ne $fileHandle) { $fileHandle.Dispose() }
        if ($null -ne $directoryHandles) { Close-SafeDirectoryContainmentChain -Handles $directoryHandles }
    }
}

function Test-RepositoryJsonSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SchemaPath, [Parameter(Mandatory)] [string] $SchemaRoot)

    $root = (Resolve-Path -LiteralPath $SchemaRoot).Path
    $capture = Read-ExactJsonArtifactCapture -Path $SchemaPath -Role EvidenceInputPath -RepoRoot $script:JsonArtifactRepoRoot -EvidenceRoots @($root)
    $schema = $capture.Document
    if ($schema -isnot [System.Collections.IDictionary]) { throw 'Repository schema root must be an object.' }
    $dialect = 'https://json-schema.org/draft/2020-12/schema'
    if (-not $schema.Contains('$schema') -or [string] $schema['$schema'] -cne $dialect) { throw "Repository schema must use the exact Draft 2020-12 dialect: $dialect" }
    $expectedId = "https://ai-agent-dotfiles.invalid/schemas/$([System.IO.Path]::GetFileName($capture.FullPath))"
    if (-not $schema.Contains('$id') -or [string] $schema['$id'] -cne $expectedId) { throw "Repository schema identifier must exactly match its basename: $expectedId" }

    $protectedTexts = @(Get-ProtectedReasonixRelativePaths)
    function Visit-SchemaNode {
        param([AllowNull()] [object] $Node, [string] $Location = '#')
        if ($null -eq $Node) { return }
        if ($Node -is [System.Collections.IDictionary]) {
            foreach ($key in $Node.Keys) {
                $name = [string] $key
                $value = $Node[$key]
                if ($name -in @('$dynamicRef', '$dynamicAnchor', '$recursiveRef', '$recursiveAnchor')) { throw "Dynamic or recursive schema reference keyword is forbidden at $Location/$name." }
                if ($name -eq '$ref' -and ($value -isnot [string] -or -not ([string] $value).StartsWith('#', [System.StringComparison]::Ordinal))) { throw "Only same-document fragment `$ref values are allowed at $Location." }
                if ($Location -ne '#' -and $name -in @('$id', '$schema')) { throw "Nested $name is forbidden at $Location." }
                Visit-SchemaNode -Node $value -Location "$Location/$name"
            }
            return
        }
        if ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
            $index = 0
            foreach ($item in $Node) { Visit-SchemaNode -Node $item -Location "$Location/$index"; $index++ }
            return
        }
        if ($Node -is [string]) {
            foreach ($protectedText in $protectedTexts) {
                if ($Node.Contains($protectedText, [System.StringComparison]::OrdinalIgnoreCase)) { throw "Schema text names a protected Reasonix path at $Location." }
            }
        }
    }
    Visit-SchemaNode -Node $schema
    return [pscustomobject]@{ SchemaPath = $capture.FullPath; SchemaId = $expectedId; SchemaHash = Get-SemanticJsonHash -InputObject $schema; Identity = $capture.Identity; ArtifactCapture = $capture }
}

function New-HeldJsonSchemaCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $SchemaCapture)

    $capture = Assert-ExactJsonArtifactCapture -Capture $SchemaCapture
    $tempParentPath = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
    $tempRoot = [System.IO.Path]::GetPathRoot($tempParentPath)
    if ($tempParentPath.Length -gt $tempRoot.Length) {
        $tempParentPath = $tempParentPath.TrimEnd([char[]] @(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        ))
    }
    $parentHandles = $null
    $directoryHandle = $null
    $schemaHandle = $null
    $directoryName = $null
    $directoryIdentity = $null
    $schemaName = $null
    $schemaIdentity = $null
    $temporaryRoot = $null
    $temporarySchema = $null
    $succeeded = $false
    $failure = $null
    try {
        $parentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $tempParentPath -OwnershipReceiver $parentHandlesReceiver
        $parentHandles = $parentHandlesReceiver.GetDeliveredExact()
        if ($parentHandles.Count -eq 0) { throw 'Unable to hold the temporary root containment chain.' }
        $directoryName = 'ai-agent-dotfiles-schema-copy-' + [Guid]::NewGuid().ToString('N')
        $directoryHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($parentHandles[$parentHandles.Count - 1], $directoryName)
        $directoryIdentity = [string] $directoryHandle.Info.Identity
        $temporaryRoot = Join-Path $tempParentPath $directoryName
        $schemaName = [System.IO.Path]::GetFileName([string] $capture.FullPath)
        if ([string]::IsNullOrWhiteSpace($schemaName) -or $schemaName.IndexOfAny([char[]]@([char]0, [char]':', [char]'/', [char]'\')) -ge 0) {
            throw 'Schema basename is unsafe for the controlled validator copy.'
        }
        $temporarySchema = Join-Path $temporaryRoot $schemaName
        $schemaHandle = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($directoryHandle, $schemaName, [byte[]] $capture.Bytes)
        $schemaIdentity = [string] $schemaHandle.Info.Identity
        $copyBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($schemaHandle, [long] $capture.Length)
        $copyHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($copyBytes)).ToLowerInvariant()
        if ($copyBytes.LongLength -ne [long] $capture.Length -or $copyHash -cne [string] $capture.Sha256) {
            throw 'Controlled schema copy differs from its exact-byte capture.'
        }
        $result = [pscustomobject][ordered]@{
            RootPath = $temporaryRoot
            SchemaPath = $temporarySchema
            ParentHandles = $parentHandles
            DirectoryHandle = $directoryHandle
            DirectoryName = $directoryName
            DirectoryIdentity = $directoryIdentity
            SchemaHandle = $schemaHandle
            SchemaName = $schemaName
            SchemaIdentity = $schemaIdentity
            Sha256 = $copyHash
        }
        $result.PSObject.TypeNames.Insert(0, 'AiAgentDotfiles.HeldJsonSchemaCopy')
        $succeeded = $true
        return $result
    }
    catch { $failure = $_ }
    finally {
        if (-not $succeeded) {
            if ($null -ne $schemaHandle) { try { $schemaHandle.Dispose() } catch {} }
            if ($null -ne $directoryHandle -and $schemaName -and $schemaIdentity) {
                try { [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($directoryHandle, $schemaName, $schemaIdentity) | Out-Null } catch {}
            }
            if ($null -ne $directoryHandle) { try { $directoryHandle.Dispose() } catch {} }
            if ($null -ne $parentHandles -and $directoryName -and $directoryIdentity) {
                try { [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($parentHandles[$parentHandles.Count - 1], $directoryName, $directoryIdentity) | Out-Null } catch {}
            }
            if ($null -ne $parentHandles) { try { Close-SafeDirectoryContainmentChain -Handles $parentHandles } catch {} }
        }
    }
    if ($null -ne $failure) { throw $failure }
}

function Close-HeldJsonSchemaCopy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $SchemaCopy)

    $cleanupFailure = $null
    $inventorySafe = $false
    try {
        $names = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($SchemaCopy.DirectoryHandle) | Sort-Object)
        $inventorySafe = $names.Count -eq 1 -and [string] $names[0] -ceq [string] $SchemaCopy.SchemaName
        if (-not $inventorySafe) { throw 'Controlled schema-copy cleanup found an unknown directory entry.' }
    }
    catch { $cleanupFailure = $_ }
    try { if ($null -ne $SchemaCopy.SchemaHandle) { $SchemaCopy.SchemaHandle.Dispose() } } catch { if($null -eq $cleanupFailure){$cleanupFailure=$_} }
    if ($inventorySafe) {
        try {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity(
                $SchemaCopy.DirectoryHandle,
                [string] $SchemaCopy.SchemaName,
                [string] $SchemaCopy.SchemaIdentity
            ) | Out-Null
        }
        catch { if($null -eq $cleanupFailure){$cleanupFailure=$_} }
        try {
            $remaining = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($SchemaCopy.DirectoryHandle))
            if ($remaining.Count -ne 0) { throw 'Controlled schema-copy directory is not empty after exact child deletion.' }
        }
        catch { if($null -eq $cleanupFailure){$cleanupFailure=$_} }
    }
    try { if ($null -ne $SchemaCopy.DirectoryHandle) { $SchemaCopy.DirectoryHandle.Dispose() } } catch { if($null -eq $cleanupFailure){$cleanupFailure=$_} }
    if ($inventorySafe) {
        try {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity(
                $SchemaCopy.ParentHandles[$SchemaCopy.ParentHandles.Count - 1],
                [string] $SchemaCopy.DirectoryName,
                [string] $SchemaCopy.DirectoryIdentity
            ) | Out-Null
        }
        catch { if($null -eq $cleanupFailure){$cleanupFailure=$_} }
    }
    try { if ($null -ne $SchemaCopy.ParentHandles) { Close-SafeDirectoryContainmentChain -Handles $SchemaCopy.ParentHandles } } catch { if($null -eq $cleanupFailure){$cleanupFailure=$_} }
    if ($null -ne $cleanupFailure) { throw $cleanupFailure }
}

function Invoke-PinnedJsonSchemaValidatorProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ToolLease,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [Parameter(Mandatory)] [byte[]] $InstanceBytes,
        [int] $TimeoutMilliseconds = 120000,
        [int] $ReapTimeoutMilliseconds = 5000
    )

    $result = Invoke-PinnedToolProcess `
        -ToolLease $ToolLease `
        -Arguments @('validate', [IO.Path]::GetFullPath($SchemaPath), '-') `
        -StandardInputBytes $InstanceBytes `
        -Operation 'Pinned JSON Schema validator' `
        -TimeoutMilliseconds $TimeoutMilliseconds `
        -ReapTimeoutMilliseconds $ReapTimeoutMilliseconds
    if ($result.ExitCode -ne 0) {
        throw "JSON Schema validation failed with exit code $($result.ExitCode)`: $($result.Output)"
    }
    return $result
}

function Invoke-PinnedJsonSchemaValidatorFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ToolLease,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [Parameter(Mandatory)] [ValidateNotNullOrEmpty()] [string[]] $InstancePaths,
        [int] $TimeoutMilliseconds = 120000,
        [int] $ReapTimeoutMilliseconds = 5000
    )

    $arguments = [Collections.Generic.List[string]]::new()
    $arguments.Add('validate')
    $arguments.Add([IO.Path]::GetFullPath($SchemaPath))
    foreach ($instancePath in $InstancePaths) { $arguments.Add([IO.Path]::GetFullPath($instancePath)) }
    $result = Invoke-PinnedToolProcess `
        -ToolLease $ToolLease `
        -Arguments @($arguments) `
        -Operation 'Pinned JSON Schema validator' `
        -TimeoutMilliseconds $TimeoutMilliseconds `
        -ReapTimeoutMilliseconds $ReapTimeoutMilliseconds
    if ($result.ExitCode -ne 0) {
        throw "JSON Schema validation failed with exit code $($result.ExitCode)`: $($result.Output)"
    }
    return $result
}

function Invoke-FixedJsonSchemaValidationBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SchemaValidation,
        [Parameter(Mandatory)] [byte[]] $InstanceBytes,
        [Parameter(Mandatory)] [string] $InstancePath,
        [string] $ValidatorCacheRoot
    )

    if ('ArtifactCapture' -notin @($SchemaValidation.PSObject.Properties.Name)) { throw 'Schema validation did not retain its exact-byte capture.' }
    $schemaCapture = Assert-ExactJsonArtifactCapture -Capture $SchemaValidation.ArtifactCapture
    $validatedInstanceBytes = [byte[]] $InstanceBytes.Clone()
    $toolLease = $null
    $schemaCopy = $null
    $failure = $null
    $processResult = $null
    try {
        $toolLease = Open-PinnedToolLease -LockPath (Join-Path $script:JsonArtifactRepoRoot 'tools/schema-validator/validator.lock.json') -CacheRoot $ValidatorCacheRoot
        $schemaCopy = New-HeldJsonSchemaCopy -SchemaCapture $schemaCapture
        $processResult = Invoke-PinnedJsonSchemaValidatorProcess -ToolLease $toolLease -SchemaPath $schemaCopy.SchemaPath -InstanceBytes $validatedInstanceBytes
    }
    catch { $failure = $_ }
    finally {
        if ($null -ne $schemaCopy) {
            try { Close-HeldJsonSchemaCopy -SchemaCopy $schemaCopy }
            catch { if ($null -eq $failure) { $failure = $_ } }
        }
        if ($null -ne $toolLease) {
            try { Close-PinnedToolLease -ToolLease $toolLease }
            catch { if ($null -eq $failure) { $failure = $_ } }
        }
    }
    if ($null -ne $failure) { throw $failure }
    return [pscustomobject]@{ Result = 'PASS'; SchemaPath = $schemaCapture.FullPath; InstancePath = [System.IO.Path]::GetFullPath($InstancePath); Output = $processResult.Output }
}

function Invoke-FixedJsonSchemaValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SchemaPath,
        [Parameter(Mandatory)] [string] $InstancePath,
        [string] $ValidatorCacheRoot
    )

    $schemaValidation = Test-RepositoryJsonSchema -SchemaPath $SchemaPath -SchemaRoot (Split-Path -Parent $SchemaPath)
    $instanceRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($InstancePath))
    $instance = Read-ExactJsonArtifactCapture -Path $InstancePath -Role EvidenceInputPath -RepoRoot $script:JsonArtifactRepoRoot -EvidenceRoots @($instanceRoot)
    $result = Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $schemaValidation -InstanceBytes $instance.Bytes -InstancePath $instance.FullPath -ValidatorCacheRoot $ValidatorCacheRoot
    $result | Add-Member -NotePropertyName ArtifactCapture -NotePropertyValue $instance
    $result | Add-Member -NotePropertyName SchemaCapture -NotePropertyValue $schemaValidation.ArtifactCapture
    return $result
}
