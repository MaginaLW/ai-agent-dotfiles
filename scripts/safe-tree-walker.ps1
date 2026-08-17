#requires -Version 7.0

Set-StrictMode -Version Latest

if (-not $IsWindows) { throw 'SafeTreeWalker protocol v1 supports Windows only.' }
. (Join-Path $PSScriptRoot 'semantic-json.ps1')

if (-not ('AiAgentDotfiles.NoFollowFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace AiAgentDotfiles {
    public sealed class FileIdentityInfo {
        public string Identity { get; set; }
        public uint LinkCount { get; set; }
        public long Length { get; set; }
        public FileAttributes Attributes { get; set; }
        public bool IsDirectory { get { return (Attributes & FileAttributes.Directory) != 0; } }
        public bool IsReparsePoint { get { return (Attributes & FileAttributes.ReparsePoint) != 0; } }
    }
    public sealed class FileReadResult {
        public string Identity { get; set; }
        public uint LinkCount { get; set; }
        public long Length { get; set; }
        public string Sha256 { get; set; }
    }
    public sealed class VolumeInfo {
        public string RootPath { get; set; }
        public string FileSystemType { get; set; }
        public string VolumeSerial { get; set; }
        public string DriveType { get; set; }
    }
    public sealed class DirectorySecuritySnapshot {
        public string Identity { get; set; }
        public uint LinkCount { get; set; }
        public string Sddl { get; set; }
    }
    public sealed class SafeDirectoryHandle : IDisposable {
        private SafeFileHandle handle;
        internal SafeDirectoryHandle(SafeFileHandle value, FileIdentityInfo info) { handle = value; Info = info; }
        public FileIdentityInfo Info { get; private set; }
        internal SafeFileHandle Handle { get { return handle; } }
        public void Dispose() { if (handle != null) { handle.Dispose(); handle = null; } }
    }
    public sealed class SafeRegularFileHandle : IDisposable {
        private FileStream stream;
        private readonly string expectedIdentity;
        private readonly uint expectedLinkCount;
        private readonly long expectedLength;
        private readonly string expectedSha256;
        internal SafeRegularFileHandle(FileStream value, FileIdentityInfo info, FileReadResult readResult) {
            stream = value;
            expectedIdentity = readResult.Identity;
            expectedLinkCount = readResult.LinkCount;
            expectedLength = readResult.Length;
            expectedSha256 = readResult.Sha256;
            Info = new FileIdentityInfo { Identity=info.Identity, LinkCount=info.LinkCount, Length=info.Length, Attributes=info.Attributes };
            ReadResult = new FileReadResult { Identity=readResult.Identity, LinkCount=readResult.LinkCount, Length=readResult.Length, Sha256=readResult.Sha256 };
        }
        public FileIdentityInfo Info { get; private set; }
        public FileReadResult ReadResult { get; private set; }
        internal FileStream Stream { get { return stream; } }
        internal SafeFileHandle Handle { get { return stream.SafeFileHandle; } }
        internal string ExpectedIdentity { get { return expectedIdentity; } }
        internal uint ExpectedLinkCount { get { return expectedLinkCount; } }
        internal long ExpectedLength { get { return expectedLength; } }
        internal string ExpectedSha256 { get { return expectedSha256; } }
        public void Dispose() { if (stream != null) { stream.Dispose(); stream = null; } }
    }
    public sealed class SafeLockFileHandle : IDisposable {
        private FileStream stream;
        internal SafeLockFileHandle(FileStream value, FileIdentityInfo info) {
            stream = value;
            Info = new FileIdentityInfo { Identity=info.Identity, LinkCount=info.LinkCount, Length=info.Length, Attributes=info.Attributes };
        }
        public FileIdentityInfo Info { get; private set; }
        public FileStream Stream {
            get {
                if (stream == null) throw new ObjectDisposedException("SafeLockFileHandle");
                return stream;
            }
        }
        internal SafeFileHandle Handle { get { return stream == null ? null : stream.SafeFileHandle; } }
        public void Dispose() { if (stream != null) { stream.Dispose(); stream = null; } }
    }
    public static class NoFollowFile {
        private const uint GENERIC_READ = 0x80000000;
        private const uint GENERIC_WRITE = 0x40000000;
        private const uint DELETE = 0x00010000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint OPEN_EXISTING = 3;
        private const uint CREATE_NEW = 1;
        private const uint READ_CONTROL = 0x00020000;
        private const uint OWNER_SECURITY_INFORMATION = 0x00000001;
        private const uint DACL_SECURITY_INFORMATION = 0x00000004;
        private const int SE_FILE_OBJECT = 1;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_ATTRIBUTE_NORMAL = 0x00000080;
        private const uint OBJ_CASE_INSENSITIVE = 0x00000040;
        private const uint FILE_DIRECTORY_FILE = 0x00000001;
        private const uint FILE_NON_DIRECTORY_FILE = 0x00000040;
        private const uint FILE_OPEN_REPARSE_POINT = 0x00200000;
        private const uint FILE_SYNCHRONOUS_IO_NONALERT = 0x00000020;
        private const uint SYNCHRONIZE = 0x00100000;
        private const uint FILE_LIST_DIRECTORY = 0x00000001;
        private const uint FILE_READ_ATTRIBUTES = 0x00000080;
        private const uint FILE_READ_DATA = 0x00000001;
        private const int FILE_OPEN = 1;
        private const int FILE_CREATE = 2;
        private const int FILE_OPEN_IF = 3;
        private const int FILE_NAMES_INFORMATION = 12;
        private const int FILE_DISPOSITION_INFORMATION_EX = 64;
        private const int FILE_DISPOSITION_DELETE = 0x00000001;
        private const int FILE_DISPOSITION_POSIX_SEMANTICS = 0x00000002;
        private const int FILE_STREAM_INFORMATION = 22;
        private const int FILE_RENAME_INFORMATION = 10;
        private const int STATUS_NO_MORE_FILES = unchecked((int)0x80000006);
        private const int STATUS_BUFFER_OVERFLOW = unchecked((int)0x80000005);
        private const int STATUS_INFO_LENGTH_MISMATCH = unchecked((int)0xC0000004);
        private const int STATUS_BUFFER_TOO_SMALL = unchecked((int)0xC0000023);
        [StructLayout(LayoutKind.Sequential)] private struct FILETIME { public uint Low; public uint High; }
        [StructLayout(LayoutKind.Sequential)] private struct BY_HANDLE_FILE_INFORMATION {
            public FileAttributes FileAttributes; public FILETIME CreationTime; public FILETIME LastAccessTime;
            public FILETIME LastWriteTime; public uint VolumeSerialNumber; public uint FileSizeHigh; public uint FileSizeLow;
            public uint NumberOfLinks; public uint FileIndexHigh; public uint FileIndexLow;
        }
        [StructLayout(LayoutKind.Sequential)] private struct UNICODE_STRING {
            public ushort Length; public ushort MaximumLength; public IntPtr Buffer;
        }
        [StructLayout(LayoutKind.Sequential)] private struct OBJECT_ATTRIBUTES {
            public int Length; public IntPtr RootDirectory; public IntPtr ObjectName; public uint Attributes;
            public IntPtr SecurityDescriptor; public IntPtr SecurityQualityOfService;
        }
        [StructLayout(LayoutKind.Sequential)] private struct IO_STATUS_BLOCK {
            public IntPtr Status; public IntPtr Information;
        }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateFileW(
            string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes, uint creationDisposition,
            uint flagsAndAttributes, IntPtr templateFile);
        [DllImport("ntdll.dll")] private static extern int NtCreateFile(
            out SafeFileHandle fileHandle, uint desiredAccess, ref OBJECT_ATTRIBUTES objectAttributes,
            out IO_STATUS_BLOCK ioStatusBlock, IntPtr allocationSize, uint fileAttributes, uint shareAccess,
            int createDisposition, uint createOptions, IntPtr eaBuffer, uint eaLength);
        [DllImport("ntdll.dll")] private static extern uint RtlNtStatusToDosError(int status);
        [DllImport("ntdll.dll")] private static extern int NtQueryDirectoryFile(
            SafeFileHandle fileHandle, IntPtr eventHandle, IntPtr apcRoutine, IntPtr apcContext,
            out IO_STATUS_BLOCK ioStatusBlock, IntPtr fileInformation, uint length, int fileInformationClass,
            [MarshalAs(UnmanagedType.U1)] bool returnSingleEntry, IntPtr fileName, [MarshalAs(UnmanagedType.U1)] bool restartScan);
        [DllImport("ntdll.dll")] private static extern int NtQueryInformationFile(
            SafeFileHandle fileHandle, out IO_STATUS_BLOCK ioStatusBlock, IntPtr fileInformation,
            uint length, int fileInformationClass);
        [DllImport("ntdll.dll")] private static extern int NtSetInformationFile(
            SafeFileHandle fileHandle, out IO_STATUS_BLOCK ioStatusBlock, IntPtr fileInformation,
            uint length, int fileInformationClass);
        [DllImport("kernel32.dll", SetLastError = true)] private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);
        [DllImport("advapi32.dll", SetLastError = true)] private static extern uint GetSecurityInfo(
            SafeFileHandle handle, int objectType, uint securityInfo, out IntPtr owner, out IntPtr group,
            out IntPtr dacl, out IntPtr sacl, out IntPtr securityDescriptor);
        [DllImport("advapi32.dll")] private static extern uint GetSecurityDescriptorLength(IntPtr securityDescriptor);
        [DllImport("kernel32.dll")] private static extern IntPtr LocalFree(IntPtr memory);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool GetVolumeInformationW(
            string rootPathName, StringBuilder volumeNameBuffer, int volumeNameSize, out uint volumeSerialNumber,
            out uint maximumComponentLength, out uint fileSystemFlags, StringBuilder fileSystemNameBuffer, int fileSystemNameSize);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] private static extern uint GetDriveTypeW(string rootPathName);

        private sealed class SafeDirectoryChain : IDisposable {
            private readonly System.Collections.Generic.List<SafeDirectoryHandle> handles = new System.Collections.Generic.List<SafeDirectoryHandle>();
            internal void Add(SafeDirectoryHandle handle) { handles.Add(handle); }
            internal SafeDirectoryHandle Leaf { get { return handles[handles.Count - 1]; } }
            public void Dispose() {
                for (int index = handles.Count - 1; index >= 0; index--) handles[index].Dispose();
                handles.Clear();
            }
        }
        private sealed class SafePathHandle : IDisposable {
            private SafeDirectoryChain parentChain;
            private SafeFileHandle handle;
            internal SafePathHandle(SafeDirectoryChain parents, SafeFileHandle value) { parentChain = parents; handle = value; }
            internal SafeFileHandle Handle { get { return handle; } }
            public void Dispose() {
                if (handle != null) { handle.Dispose(); handle = null; }
                if (parentChain != null) { parentChain.Dispose(); parentChain = null; }
            }
        }
        private sealed class SafePathRegularFile : IDisposable {
            private SafeDirectoryChain parentChain;
            private SafeRegularFileHandle file;
            internal SafePathRegularFile(SafeDirectoryChain parents, SafeRegularFileHandle value) { parentChain = parents; file = value; }
            internal SafeRegularFileHandle File { get { return file; } }
            public void Dispose() {
                if (file != null) { file.Dispose(); file = null; }
                if (parentChain != null) { parentChain.Dispose(); parentChain = null; }
            }
        }

        private static string NormalizeNativePath(string path) {
            string full = Path.GetFullPath(path);
            if (full.StartsWith(@"\\?\", StringComparison.Ordinal)) return full;
            if (full.StartsWith(@"\\", StringComparison.Ordinal)) return @"\\?\UNC\" + full.Substring(2);
            return @"\\?\" + full;
        }
        private static SafeFileHandle OpenMetadata(string path, uint access, uint share) {
            SafeFileHandle handle = CreateFileW(NormalizeNativePath(path), access, share, IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_OPEN_REPARSE_POINT | FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to open path without following reparse points: " + path);
            return handle;
        }
        private static string NormalizeLexicalPath(string path) {
            if (String.IsNullOrWhiteSpace(path)) throw new ArgumentException("Safe path must not be empty.", "path");
            string full = Path.GetFullPath(path);
            string root = Path.GetPathRoot(full);
            if (String.IsNullOrEmpty(root)) throw new InvalidOperationException("Safe path has no volume root: " + path);
            while (full.Length > root.Length && (full[full.Length - 1] == Path.DirectorySeparatorChar || full[full.Length - 1] == Path.AltDirectorySeparatorChar))
                full = full.Substring(0, full.Length - 1);
            return full;
        }
        private static SafeDirectoryHandle HoldAbsoluteVolumeRoot(string path) {
            SafeFileHandle handle = OpenMetadata(path, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE);
            try {
                FileIdentityInfo info = ReadInfo(handle);
                if (!info.IsDirectory || info.IsReparsePoint) throw new InvalidOperationException("Volume root is not a no-follow directory: " + path);
                return new SafeDirectoryHandle(handle, info);
            } catch { handle.Dispose(); throw; }
        }
        private static SafeDirectoryChain OpenSafeDirectoryChain(string path) {
            string full = NormalizeLexicalPath(path);
            string volumeRoot = Path.GetPathRoot(full);
            string relative = Path.GetRelativePath(volumeRoot, full);
            var chain = new SafeDirectoryChain();
            try {
                SafeDirectoryHandle parent = HoldAbsoluteVolumeRoot(volumeRoot);
                chain.Add(parent);
                if (!String.Equals(relative, ".", StringComparison.Ordinal)) {
                    string[] segments = relative.Split(new char[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (string segment in segments) {
                        if (segment == "." || segment == "..") throw new InvalidOperationException("Unsafe containment path segment: " + full);
                        SafeDirectoryHandle child = HoldChildDirectory(parent, segment);
                        chain.Add(child);
                        parent = child;
                    }
                }
                return chain;
            } catch { chain.Dispose(); throw; }
        }
        private static void GetSafePathParent(string path, out string full, out string parentPath, out string leaf) {
            full = NormalizeLexicalPath(path);
            string volumeRoot = Path.GetPathRoot(full);
            if (String.Equals(Path.GetRelativePath(volumeRoot, full), ".", StringComparison.Ordinal))
                throw new InvalidOperationException("Volume root has no relative final entry: " + full);
            parentPath = Path.GetDirectoryName(full);
            leaf = Path.GetFileName(full);
            ValidateRelativeName(leaf);
        }
        private static SafePathHandle OpenSafePathHandle(string path, uint access, uint share, uint options) {
            string full = NormalizeLexicalPath(path);
            string volumeRoot = Path.GetPathRoot(full);
            if (String.Equals(Path.GetRelativePath(volumeRoot, full), ".", StringComparison.Ordinal))
                return new SafePathHandle(null, OpenMetadata(volumeRoot, access, share));
            string parentPath, leaf;
            GetSafePathParent(full, out full, out parentPath, out leaf);
            SafeDirectoryChain parents = OpenSafeDirectoryChain(parentPath);
            try { return new SafePathHandle(parents, OpenRelative(parents.Leaf, leaf, access, share, FILE_OPEN, options)); }
            catch { parents.Dispose(); throw; }
        }
        private static SafePathRegularFile OpenSafeRegularFileByPath(string path) {
            string full, parentPath, leaf;
            GetSafePathParent(path, out full, out parentPath, out leaf);
            SafeDirectoryChain parents = OpenSafeDirectoryChain(parentPath);
            try { return new SafePathRegularFile(parents, OpenAndHashChildRegularFile(parents.Leaf, leaf)); }
            catch { parents.Dispose(); throw; }
        }
        private static FileIdentityInfo ReadInfo(SafeFileHandle handle) {
            BY_HANDLE_FILE_INFORMATION raw;
            if (!GetFileInformationByHandle(handle, out raw)) throw new Win32Exception(Marshal.GetLastWin32Error());
            ulong index = ((ulong)raw.FileIndexHigh << 32) | raw.FileIndexLow;
            long length = ((long)raw.FileSizeHigh << 32) | raw.FileSizeLow;
            return new FileIdentityInfo {
                Identity = raw.VolumeSerialNumber.ToString("x8") + ":" + index.ToString("x16"),
                LinkCount = raw.NumberOfLinks, Length = length, Attributes = raw.FileAttributes
            };
        }
        private static void ValidateRelativeName(string name) {
            if (String.IsNullOrEmpty(name) || name.IndexOf('\\') >= 0 || name.IndexOf('/') >= 0 || name.IndexOf(':') >= 0 || name.IndexOf('\0') >= 0 || name == "." || name == "..")
                throw new ArgumentException("Relative entry name must be one non-stream path component.", "name");
        }
        private static SafeFileHandle OpenRelative(SafeDirectoryHandle parent, string name, uint access, uint share, int disposition, uint options) {
            ValidateRelativeName(name);
            IntPtr nameBuffer = Marshal.StringToHGlobalUni(name);
            IntPtr unicodePointer = IntPtr.Zero;
            bool parentReference = false;
            SafeFileHandle parentHandle = parent == null ? null : parent.Handle;
            if (parentHandle == null) { Marshal.FreeHGlobal(nameBuffer); throw new ObjectDisposedException("parent"); }
            try {
                parentHandle.DangerousAddRef(ref parentReference);
                UNICODE_STRING unicode = new UNICODE_STRING { Length = checked((ushort)(name.Length * 2)), MaximumLength = checked((ushort)((name.Length + 1) * 2)), Buffer = nameBuffer };
                unicodePointer = Marshal.AllocHGlobal(Marshal.SizeOf<UNICODE_STRING>());
                Marshal.StructureToPtr(unicode, unicodePointer, false);
                OBJECT_ATTRIBUTES attributes = new OBJECT_ATTRIBUTES {
                    Length = Marshal.SizeOf<OBJECT_ATTRIBUTES>(), RootDirectory = parentHandle.DangerousGetHandle(), ObjectName = unicodePointer,
                    Attributes = OBJ_CASE_INSENSITIVE, SecurityDescriptor = IntPtr.Zero, SecurityQualityOfService = IntPtr.Zero
                };
                IO_STATUS_BLOCK io;
                SafeFileHandle result;
                int status = NtCreateFile(out result, access | SYNCHRONIZE, ref attributes, out io, IntPtr.Zero, 0, share, disposition,
                    options | FILE_OPEN_REPARSE_POINT | FILE_SYNCHRONOUS_IO_NONALERT, IntPtr.Zero, 0);
                if (status < 0) throw new Win32Exception((int)RtlNtStatusToDosError(status), "Unable to open child relative to its held directory: " + name);
                return result;
            } finally {
                if (unicodePointer != IntPtr.Zero) Marshal.FreeHGlobal(unicodePointer);
                Marshal.FreeHGlobal(nameBuffer);
                if (parentReference) parentHandle.DangerousRelease();
            }
        }
        public static FileIdentityInfo Inspect(string path) {
            using (SafePathHandle capture = OpenSafePathHandle(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0)) { return ReadInfo(capture.Handle); }
        }
        public static SafeDirectoryHandle HoldDirectory(string path) {
            string full = NormalizeLexicalPath(path);
            string volumeRoot = Path.GetPathRoot(full);
            if (!String.Equals(Path.GetRelativePath(volumeRoot, full), ".", StringComparison.Ordinal))
                throw new InvalidOperationException("Absolute directory hold is restricted to a volume root; open descendants relative to the held root: " + full);
            return HoldAbsoluteVolumeRoot(volumeRoot);
        }
        public static SafeDirectoryHandle HoldChildDirectory(SafeDirectoryHandle parent, string name) {
            SafeFileHandle handle = OpenRelative(parent, name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_OPEN, FILE_DIRECTORY_FILE);
            try {
                FileIdentityInfo info = ReadInfo(handle);
                if (!info.IsDirectory || info.IsReparsePoint) throw new InvalidOperationException("Relative containment child is not a no-follow directory: " + name);
                return new SafeDirectoryHandle(handle, info);
            } catch { handle.Dispose(); throw; }
        }
        public static SafeDirectoryHandle TryHoldPathChildDirectory(SafeDirectoryHandle parent, string name) {
            try { return HoldChildDirectory(parent, name); }
            catch (Win32Exception error) when (error.NativeErrorCode == 2 || error.NativeErrorCode == 3) { return null; }
        }
        public static SafeDirectoryHandle TryHoldChildDirectory(SafeDirectoryHandle parent, string name) {
            try { return HoldChildDirectory(parent, name); }
            catch (InvalidOperationException error) when (error.Message.StartsWith("Relative containment child is not a no-follow directory:", StringComparison.Ordinal)) { return null; }
            catch (Win32Exception error) when (error.NativeErrorCode == 267) { return null; }
        }
        public static FileIdentityInfo InspectChild(SafeDirectoryHandle parent, string name) {
            using (SafeFileHandle handle = OpenRelative(parent, name, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN, 0)) { return ReadInfo(handle); }
        }
        public static FileIdentityInfo TryInspectChild(SafeDirectoryHandle parent, string name) {
            try { return InspectChild(parent, name); }
            catch (Win32Exception error) when (error.NativeErrorCode == 2 || error.NativeErrorCode == 3) { return null; }
        }
        public static SafeDirectoryHandle CreateChildDirectory(SafeDirectoryHandle parent, string name) {
            SafeFileHandle handle = OpenRelative(parent, name, FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE, FILE_CREATE, FILE_DIRECTORY_FILE);
            try {
                FileIdentityInfo info = ReadInfo(handle);
                if (!info.IsDirectory || info.IsReparsePoint) throw new InvalidOperationException("Created relative child is not a no-follow directory: " + name);
                return new SafeDirectoryHandle(handle, info);
            } catch { handle.Dispose(); throw; }
        }
        private static string[] GetChildNamesByHandle(SafeFileHandle directoryHandle) {
            var names = new System.Collections.Generic.List<string>();
            const int capacity = 65536;
            IntPtr buffer = Marshal.AllocHGlobal(capacity);
            try {
                bool restart = true;
                while (true) {
                    IO_STATUS_BLOCK io;
                    int status = NtQueryDirectoryFile(directoryHandle, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero, out io, buffer,
                        capacity, FILE_NAMES_INFORMATION, false, IntPtr.Zero, restart);
                    restart = false;
                    if (status == STATUS_NO_MORE_FILES) break;
                    if (status < 0 && status != STATUS_BUFFER_OVERFLOW) throw new Win32Exception((int)RtlNtStatusToDosError(status), "Unable to enumerate held directory.");
                    long available = io.Information.ToInt64();
                    if (available <= 0 || available > capacity) throw new InvalidOperationException("Held directory enumeration returned invalid bounds.");
                    int offset = 0;
                    while (true) {
                        if (offset < 0 || offset + 12 > available) throw new InvalidOperationException("Held directory enumeration entry is out of bounds.");
                        int next = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 8);
                        if (nameLength < 0 || (nameLength & 1) != 0 || offset + 12L + nameLength > available) throw new InvalidOperationException("Held directory enumeration name is out of bounds.");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 12), nameLength / 2);
                        if (name != "." && name != "..") names.Add(name);
                        if (next == 0) break;
                        if (next < 12) throw new InvalidOperationException("Held directory enumeration offset is invalid.");
                        offset += next;
                    }
                }
                return names.ToArray();
            } finally { Marshal.FreeHGlobal(buffer); }
        }
        public static string[] GetChildNames(SafeDirectoryHandle directory) {
            if (directory == null || directory.Handle == null) throw new ObjectDisposedException("directory");
            return GetChildNamesByHandle(directory.Handle);
        }
        private static string[] GetNamedStreamsByHandle(SafeFileHandle handle) {
            int capacity = 4096;
            while (capacity <= 16777216) {
                IntPtr buffer = Marshal.AllocHGlobal(capacity);
                try {
                    IO_STATUS_BLOCK io;
                    int status = NtQueryInformationFile(handle, out io, buffer, (uint)capacity, FILE_STREAM_INFORMATION);
                    if (status == STATUS_BUFFER_OVERFLOW || status == STATUS_INFO_LENGTH_MISMATCH || status == STATUS_BUFFER_TOO_SMALL) { capacity *= 2; continue; }
                    if (status < 0) throw new Win32Exception((int)RtlNtStatusToDosError(status), "Unable to enumerate named streams from held handle.");
                    long available = io.Information.ToInt64();
                    if (available == 0) return Array.Empty<string>();
                    if (available < 24 || available > capacity) throw new InvalidOperationException("Held stream enumeration returned invalid bounds.");
                    var streams = new System.Collections.Generic.List<string>();
                    int offset = 0;
                    while (true) {
                        if (offset < 0 || offset + 24 > available) throw new InvalidOperationException("Held stream enumeration entry is out of bounds.");
                        int next = Marshal.ReadInt32(buffer, offset);
                        int nameLength = Marshal.ReadInt32(buffer, offset + 4);
                        if (nameLength < 0 || (nameLength & 1) != 0 || offset + 24L + nameLength > available) throw new InvalidOperationException("Held stream enumeration name is out of bounds.");
                        string name = Marshal.PtrToStringUni(IntPtr.Add(buffer, offset + 24), nameLength / 2);
                        if (!String.Equals(name, "::$DATA", StringComparison.OrdinalIgnoreCase)) streams.Add(name);
                        if (next == 0) break;
                        if (next < 24) throw new InvalidOperationException("Held stream enumeration offset is invalid.");
                        offset += next;
                    }
                    return streams.ToArray();
                } finally { Marshal.FreeHGlobal(buffer); }
            }
            throw new InvalidOperationException("Held stream enumeration exceeded the safety bound.");
        }
        public static string[] GetNamedStreams(SafeDirectoryHandle directory) { return GetNamedStreamsByHandle(directory.Handle); }
        public static DirectorySecuritySnapshot GetDirectorySecuritySnapshot(string path) {
            using (SafePathHandle capture = OpenSafePathHandle(path, READ_CONTROL | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, FILE_DIRECTORY_FILE)) {
                FileIdentityInfo info = ReadInfo(capture.Handle);
                if (!info.IsDirectory || info.IsReparsePoint) throw new InvalidOperationException("Security target is not a no-follow directory: " + path);
                IntPtr owner, group, dacl, sacl, descriptor;
                uint error = GetSecurityInfo(capture.Handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                    out owner, out group, out dacl, out sacl, out descriptor);
                if (error != 0) throw new Win32Exception((int)error, "Unable to query directory security by handle: " + path);
                try {
                    uint length = GetSecurityDescriptorLength(descriptor);
                    byte[] bytes = new byte[length];
                    Marshal.Copy(descriptor, bytes, 0, checked((int)length));
                    var raw = new RawSecurityDescriptor(bytes, 0);
                    return new DirectorySecuritySnapshot {
                        Identity = info.Identity, LinkCount = info.LinkCount,
                        Sddl = raw.GetSddlForm(AccessControlSections.Owner | AccessControlSections.Access)
                    };
                } finally { if (descriptor != IntPtr.Zero) LocalFree(descriptor); }
            }
        }
        public static string[] GetNamedStreams(string path) {
            using (SafePathHandle capture = OpenSafePathHandle(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, 0))
                return GetNamedStreamsByHandle(capture.Handle);
        }
        public static FileReadResult HashRegularFile(string source) {
            using (SafePathRegularFile capture = OpenSafeRegularFileByPath(source))
                return new FileReadResult { Identity=capture.File.ReadResult.Identity, LinkCount=capture.File.ReadResult.LinkCount,
                    Length=capture.File.ReadResult.Length, Sha256=capture.File.ReadResult.Sha256 };
        }
        public static FileReadResult HashChildRegularFile(SafeDirectoryHandle parent, string name) {
            using (SafeRegularFileHandle capture = OpenAndHashChildRegularFile(parent, name))
                return new FileReadResult { Identity=capture.ReadResult.Identity, LinkCount=capture.ReadResult.LinkCount,
                    Length=capture.ReadResult.Length, Sha256=capture.ReadResult.Sha256 };
        }
        public static SafeRegularFileHandle OpenAndHashChildRegularFile(SafeDirectoryHandle parent, string name) {
            SafeFileHandle handle = OpenRelative(parent, name, FILE_READ_DATA | FILE_READ_ATTRIBUTES, FILE_SHARE_READ, FILE_OPEN, FILE_NON_DIRECTORY_FILE);
            FileStream stream = null;
            try {
                FileIdentityInfo info = ReadInfo(handle);
                if (info.IsDirectory || info.IsReparsePoint) throw new InvalidOperationException("Relative source is not a regular file: " + name);
                if (info.LinkCount != 1) throw new InvalidOperationException("Relative source has multiple hard links: " + name);
                string[] streams = GetNamedStreamsByHandle(handle);
                if (streams.Length != 0) throw new InvalidOperationException("Relative source has a named alternate data stream: " + name);
                stream = new FileStream(handle, FileAccess.Read);
                using (var sha = SHA256.Create()) {
                    byte[] buffer = new byte[131072]; int read; long length = 0;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) { sha.TransformBlock(buffer, 0, read, null, 0); length += read; }
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    FileIdentityInfo after = ReadInfo(handle);
                    if (after.IsDirectory || after.IsReparsePoint || !String.Equals(after.Identity, info.Identity, StringComparison.Ordinal) ||
                        after.LinkCount != 1 || after.Length != info.Length || after.Length != length)
                        throw new InvalidOperationException("Relative source changed during hash: " + name);
                    if (GetNamedStreamsByHandle(handle).Length != 0)
                        throw new InvalidOperationException("Relative source acquired a named alternate data stream during hash: " + name);
                    stream.Position = 0;
                    var result = new FileReadResult { Identity = info.Identity, LinkCount = info.LinkCount, Length = length,
                        Sha256 = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant() };
                    return new SafeRegularFileHandle(stream, info, result);
                }
            } catch {
                if (stream != null) stream.Dispose(); else handle.Dispose();
                throw;
            }
        }
        public static SafeRegularFileHandle CreateAndHashChildRegularFile(SafeDirectoryHandle parent, string name, byte[] bytes) {
            if (bytes == null) throw new ArgumentNullException("bytes");
            SafeFileHandle handle = OpenRelative(parent, name,
                GENERIC_READ | GENERIC_WRITE | DELETE | FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ, FILE_CREATE, FILE_NON_DIRECTORY_FILE);
            FileStream stream = null;
            try {
                FileIdentityInfo created = ReadInfo(handle);
                if (created.IsDirectory || created.IsReparsePoint || created.LinkCount != 1 || created.Length != 0)
                    throw new InvalidOperationException("Created relative child is not a new regular file: " + name);
                if (GetNamedStreamsByHandle(handle).Length != 0)
                    throw new InvalidOperationException("Created relative child has a named alternate data stream: " + name);

                stream = new FileStream(handle, FileAccess.ReadWrite);
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(true);
                stream.Position = 0;
                using (var sha = SHA256.Create()) {
                    string intendedHash = BitConverter.ToString(SHA256.HashData(bytes)).Replace("-", "").ToLowerInvariant();
                    byte[] buffer = new byte[131072]; int read; long length = 0;
                    while ((read = stream.Read(buffer, 0, buffer.Length)) > 0) {
                        sha.TransformBlock(buffer, 0, read, null, 0);
                        length += read;
                    }
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    FileIdentityInfo after = ReadInfo(handle);
                    if (after.IsDirectory || after.IsReparsePoint || after.LinkCount != 1 ||
                        !String.Equals(after.Identity, created.Identity, StringComparison.Ordinal) ||
                        after.Length != bytes.LongLength || after.Length != length)
                        throw new InvalidOperationException("Created relative child changed during durable write: " + name);
                    if (GetNamedStreamsByHandle(handle).Length != 0)
                        throw new InvalidOperationException("Created relative child acquired a named alternate data stream during durable write: " + name);
                    stream.Position = 0;
                    string actualHash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    if (!String.Equals(actualHash, intendedHash, StringComparison.Ordinal))
                        throw new InvalidOperationException("Created relative child bytes differ from the intended durable write: " + name);
                    var result = new FileReadResult { Identity = after.Identity, LinkCount = after.LinkCount, Length = length,
                        Sha256 = actualHash };
                    return new SafeRegularFileHandle(stream, after, result);
                }
            } catch {
                if (stream != null) stream.Dispose(); else handle.Dispose();
                throw;
            }
        }
        public static SafeRegularFileHandle CreateAndSealChildRegularFile(SafeDirectoryHandle parent, string name, byte[] bytes) {
            if (bytes == null) throw new ArgumentNullException("bytes");
            SafeRegularFileHandle writer = null;
            SafeFileHandle bridge = null;
            SafeFileHandle sealedHandle = null;
            FileStream sealedStream = null;
            try {
                writer = CreateAndHashChildRegularFile(parent, name, bytes);
                FileIdentityInfo writerState = ValidateHeldRegularFileState(writer, "before read-only seal bridge");

                bridge = OpenRelative(parent, name, FILE_READ_DATA | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, FILE_OPEN, FILE_NON_DIRECTORY_FILE);
                FileIdentityInfo bridgeBefore = ReadInfo(bridge);
                if (bridgeBefore.IsDirectory || bridgeBefore.IsReparsePoint || bridgeBefore.LinkCount != 1 ||
                    !String.Equals(bridgeBefore.Identity, writer.ExpectedIdentity, StringComparison.Ordinal) ||
                    !String.Equals(bridgeBefore.Identity, writerState.Identity, StringComparison.Ordinal) ||
                    bridgeBefore.Length != writer.ExpectedLength)
                    throw new InvalidOperationException("Read-only seal bridge differs from its durable writer identity: " + name);
                if (GetNamedStreamsByHandle(bridge).Length != 0)
                    throw new InvalidOperationException("Read-only seal bridge has a named alternate data stream: " + name);

                writer.Dispose();
                writer = null;

                sealedHandle = OpenRelative(parent, name, FILE_READ_DATA | FILE_READ_ATTRIBUTES,
                    FILE_SHARE_READ, FILE_OPEN, FILE_NON_DIRECTORY_FILE);
                FileIdentityInfo sealedBefore = ReadInfo(sealedHandle);
                if (sealedBefore.IsDirectory || sealedBefore.IsReparsePoint || sealedBefore.LinkCount != 1 ||
                    !String.Equals(sealedBefore.Identity, bridgeBefore.Identity, StringComparison.Ordinal) ||
                    sealedBefore.Length != bridgeBefore.Length)
                    throw new InvalidOperationException("Read-only sealed child differs from its bridge identity: " + name);
                if (GetNamedStreamsByHandle(sealedHandle).Length != 0)
                    throw new InvalidOperationException("Read-only sealed child has a named alternate data stream: " + name);

                sealedStream = new FileStream(sealedHandle, FileAccess.Read);
                sealedHandle = null;
                using (var sha = SHA256.Create()) {
                    byte[] buffer = new byte[131072]; int read; long length = 0;
                    while ((read = sealedStream.Read(buffer, 0, buffer.Length)) > 0) {
                        sha.TransformBlock(buffer, 0, read, null, 0);
                        length += read;
                    }
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    string actualHash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    FileIdentityInfo sealedAfter = ReadInfo(sealedStream.SafeFileHandle);
                    FileIdentityInfo bridgeAfter = ReadInfo(bridge);
                    if (sealedAfter.IsDirectory || sealedAfter.IsReparsePoint || sealedAfter.LinkCount != 1 ||
                        bridgeAfter.IsDirectory || bridgeAfter.IsReparsePoint || bridgeAfter.LinkCount != 1 ||
                        !String.Equals(sealedAfter.Identity, sealedBefore.Identity, StringComparison.Ordinal) ||
                        !String.Equals(bridgeAfter.Identity, bridgeBefore.Identity, StringComparison.Ordinal) ||
                        !String.Equals(sealedAfter.Identity, bridgeAfter.Identity, StringComparison.Ordinal) ||
                        sealedAfter.Length != bytes.LongLength || sealedAfter.Length != length ||
                        bridgeAfter.Length != sealedAfter.Length)
                        throw new InvalidOperationException("Read-only sealed child changed during exact-byte verification: " + name);
                    if (GetNamedStreamsByHandle(sealedStream.SafeFileHandle).Length != 0 || GetNamedStreamsByHandle(bridge).Length != 0)
                        throw new InvalidOperationException("Read-only sealed child acquired a named alternate data stream: " + name);
                    if (!String.Equals(actualHash, BitConverter.ToString(SHA256.HashData(bytes)).Replace("-", "").ToLowerInvariant(), StringComparison.Ordinal))
                        throw new InvalidOperationException("Read-only sealed child bytes differ from the intended durable write: " + name);

                    sealedStream.Position = 0;
                    var result = new FileReadResult { Identity=sealedAfter.Identity, LinkCount=sealedAfter.LinkCount,
                        Length=length, Sha256=actualHash };
                    var sealedFile = new SafeRegularFileHandle(sealedStream, sealedAfter, result);
                    sealedStream = null;
                    return sealedFile;
                }
            } catch {
                throw;
            } finally {
                if (sealedStream != null) sealedStream.Dispose();
                else if (sealedHandle != null) sealedHandle.Dispose();
                if (bridge != null) bridge.Dispose();
                if (writer != null) writer.Dispose();
            }
        }
        private static SafeLockFileHandle OpenChildLockFileCore(SafeDirectoryHandle parent, string name, int disposition) {
            SafeFileHandle handle = OpenRelative(parent, name,
                GENERIC_READ | GENERIC_WRITE | FILE_READ_ATTRIBUTES,
                FILE_SHARE_READ, disposition, FILE_NON_DIRECTORY_FILE);
            FileStream stream = null;
            try {
                FileIdentityInfo before = ReadInfo(handle);
                if (before.IsDirectory || before.IsReparsePoint)
                    throw new InvalidOperationException("Relative lock child is not a regular file: " + name);
                if (before.LinkCount != 1)
                    throw new InvalidOperationException("Relative lock child has multiple hard links: " + name);
                if (GetNamedStreamsByHandle(handle).Length != 0)
                    throw new InvalidOperationException("Relative lock child has a named alternate data stream: " + name);
                FileIdentityInfo after = ReadInfo(handle);
                if (after.IsDirectory || after.IsReparsePoint || after.LinkCount != 1 ||
                    !String.Equals(after.Identity, before.Identity, StringComparison.Ordinal) || after.Length != before.Length)
                    throw new InvalidOperationException("Relative lock child changed during acquisition: " + name);
                if (GetNamedStreamsByHandle(handle).Length != 0)
                    throw new InvalidOperationException("Relative lock child acquired a named alternate data stream during acquisition: " + name);
                stream = new FileStream(handle, FileAccess.ReadWrite);
                return new SafeLockFileHandle(stream, after);
            } catch {
                if (stream != null) stream.Dispose(); else handle.Dispose();
                throw;
            }
        }
        public static SafeLockFileHandle OpenChildLockFile(SafeDirectoryHandle parent, string name) {
            return OpenChildLockFileCore(parent, name, FILE_OPEN);
        }
        public static SafeLockFileHandle OpenOrCreateChildLockFile(SafeDirectoryHandle parent, string name) {
            return OpenChildLockFileCore(parent, name, FILE_OPEN_IF);
        }
        private static FileIdentityInfo ValidateHeldRegularFileState(SafeRegularFileHandle source, string stage) {
            if (source == null) throw new ArgumentNullException("source");
            FileStream stream = source.Stream;
            if (stream == null) throw new ObjectDisposedException("source");
            FileIdentityInfo state = ReadInfo(stream.SafeFileHandle);
            if (state.IsDirectory || state.IsReparsePoint || !String.Equals(state.Identity, source.ExpectedIdentity, StringComparison.Ordinal))
                throw new InvalidOperationException("Held source identity changed " + stage + ".");
            if (state.LinkCount != 1 || source.ExpectedLinkCount != 1)
                throw new InvalidOperationException("Held source has multiple hard links " + stage + ".");
            if (state.Length != source.ExpectedLength)
                throw new InvalidOperationException("Held source length changed " + stage + ".");
            if (GetNamedStreamsByHandle(stream.SafeFileHandle).Length != 0)
                throw new InvalidOperationException("Held source has a named alternate data stream " + stage + ".");
            return state;
        }
        public static byte[] ReadHeldRegularFileBytes(SafeRegularFileHandle source, long maxBytes) {
            if (source == null) throw new ArgumentNullException("source");
            if (maxBytes < 0) throw new ArgumentOutOfRangeException("maxBytes", "Held source maximum byte length must be non-negative.");
            FileStream input = source.Stream;
            if (input == null) throw new ObjectDisposedException("source");
            try {
                FileIdentityInfo before = ValidateHeldRegularFileState(source, "before byte read");
                if (before.Length > maxBytes)
                    throw new InvalidOperationException("Held source length exceeds the caller maximum byte length.");
                if (before.Length > Int32.MaxValue)
                    throw new InvalidOperationException("Held source is too large for a bounded byte array.");

                input.Position = 0;
                byte[] bytes = new byte[checked((int)before.Length)];
                int offset = 0;
                using (var sha = SHA256.Create()) {
                    while (offset < bytes.Length) {
                        int read = input.Read(bytes, offset, bytes.Length - offset);
                        if (read <= 0) throw new InvalidOperationException("Held source ended before its approved length during byte read.");
                        sha.TransformBlock(bytes, offset, read, null, 0);
                        offset += read;
                    }
                    if (input.ReadByte() != -1) throw new InvalidOperationException("Held source exceeded its approved length during byte read.");
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    string hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    FileIdentityInfo after = ValidateHeldRegularFileState(source, "after byte read");
                    if (!String.Equals(after.Identity, before.Identity, StringComparison.Ordinal) || after.Length != offset)
                        throw new InvalidOperationException("Held source length changed during byte read.");
                    if (!String.Equals(hash, source.ExpectedSha256, StringComparison.Ordinal))
                        throw new InvalidOperationException("Held source hash changed during byte read.");
                }
                return bytes;
            } finally {
                if (source.Stream != null) source.Stream.Position = 0;
            }
        }
        public static FileIdentityInfo RenameHeldRegularFileNoReplace(SafeRegularFileHandle source, SafeDirectoryHandle destinationParent, string destinationName) {
            if (source == null) throw new ArgumentNullException("source");
            if (destinationParent == null) throw new ArgumentNullException("destinationParent");
            ValidateRelativeName(destinationName);
            FileIdentityInfo before = ValidateHeldRegularFileState(source, "before no-replace rename");
            SafeFileHandle parentHandle = destinationParent.Handle;
            if (parentHandle == null || parentHandle.IsClosed || parentHandle.IsInvalid)
                throw new ObjectDisposedException("destinationParent");

            byte[] nameBytes = Encoding.Unicode.GetBytes(destinationName);
            int rootOffset = IntPtr.Size == 8 ? 8 : 4;
            int nameLengthOffset = IntPtr.Size == 8 ? 16 : 8;
            int fileNameOffset = IntPtr.Size == 8 ? 20 : 12;
            byte[] layout = new byte[checked(fileNameOffset + nameBytes.Length)];
            IntPtr buffer = Marshal.AllocHGlobal(layout.Length);
            bool parentReference = false;
            try {
                Marshal.Copy(layout, 0, buffer, layout.Length);
                parentHandle.DangerousAddRef(ref parentReference);
                Marshal.WriteByte(buffer, 0, 0);
                Marshal.WriteIntPtr(buffer, rootOffset, parentHandle.DangerousGetHandle());
                Marshal.WriteInt32(buffer, nameLengthOffset, nameBytes.Length);
                Marshal.Copy(nameBytes, 0, IntPtr.Add(buffer, fileNameOffset), nameBytes.Length);
                IO_STATUS_BLOCK io;
                int status = NtSetInformationFile(source.Handle, out io, buffer, (uint)layout.Length, FILE_RENAME_INFORMATION);
                if (status < 0)
                    throw new Win32Exception((int)RtlNtStatusToDosError(status),
                        "Unable to atomically rename held regular file without replacement: " + destinationName);

                FileIdentityInfo after = ValidateHeldRegularFileState(source, "after no-replace rename");
                FileIdentityInfo published = InspectChild(destinationParent, destinationName);
                if (published.IsDirectory || published.IsReparsePoint || published.LinkCount != 1 ||
                    !String.Equals(after.Identity, before.Identity, StringComparison.Ordinal) ||
                    !String.Equals(published.Identity, before.Identity, StringComparison.Ordinal) ||
                    published.Length != before.Length)
                    throw new InvalidOperationException("Published child identity differs from its held source: " + destinationName);
                return published;
            } finally {
                if (parentReference) parentHandle.DangerousRelease();
                Marshal.FreeHGlobal(buffer);
            }
        }
        private static FileIdentityInfo CloneInfo(FileIdentityInfo info) {
            return new FileIdentityInfo { Identity=info.Identity, LinkCount=info.LinkCount, Length=info.Length, Attributes=info.Attributes };
        }
        private static void MarkHeldChildForDeletion(SafeFileHandle handle, string name) {
            IntPtr disposition = Marshal.AllocHGlobal(4);
            try {
                Marshal.WriteInt32(disposition, FILE_DISPOSITION_DELETE | FILE_DISPOSITION_POSIX_SEMANTICS);
                IO_STATUS_BLOCK io;
                int status = NtSetInformationFile(handle, out io, disposition, 4, FILE_DISPOSITION_INFORMATION_EX);
                if (status < 0)
                    throw new Win32Exception((int)RtlNtStatusToDosError(status),
                        "Unable to remove the exact relative child with POSIX disposition: " + name);
            } finally { Marshal.FreeHGlobal(disposition); }
        }
        private static FileIdentityInfo DeleteChildIfIdentity(SafeDirectoryHandle parent, string name, string expectedIdentity, bool directory) {
            if (parent == null) throw new ArgumentNullException("parent");
            ValidateRelativeName(name);
            if (String.IsNullOrWhiteSpace(expectedIdentity))
                throw new ArgumentException("Expected child identity must not be empty.", "expectedIdentity");

            SafeFileHandle handle = null;
            FileIdentityInfo approved = null;
            bool marked = false;
            try {
                uint access = DELETE | FILE_READ_ATTRIBUTES | (directory ? FILE_LIST_DIRECTORY : 0);
                uint options = directory ? FILE_DIRECTORY_FILE : FILE_NON_DIRECTORY_FILE;
                handle = OpenRelative(parent, name, access, 0, FILE_OPEN, options);
                FileIdentityInfo before = ReadInfo(handle);
                if (!String.Equals(before.Identity, expectedIdentity, StringComparison.Ordinal))
                    throw new InvalidOperationException("Relative cleanup child identity differs from the expected object: " + name);

                if (directory) {
                    if (!before.IsDirectory || before.IsReparsePoint)
                        throw new InvalidOperationException("Relative cleanup child is not a no-follow directory: " + name);
                    if (GetNamedStreamsByHandle(handle).Length != 0)
                        throw new InvalidOperationException("Relative cleanup directory has a named alternate data stream: " + name);
                    if (GetChildNamesByHandle(handle).Length != 0)
                        throw new InvalidOperationException("Relative cleanup directory is not empty: " + name);
                } else {
                    if (before.IsDirectory || before.IsReparsePoint)
                        throw new InvalidOperationException("Relative cleanup child is not a no-follow regular file: " + name);
                    if (before.LinkCount != 1)
                        throw new InvalidOperationException("Relative cleanup child has multiple hard links: " + name);
                    if (GetNamedStreamsByHandle(handle).Length != 0)
                        throw new InvalidOperationException("Relative cleanup child has a named alternate data stream: " + name);
                }

                FileIdentityInfo after = ReadInfo(handle);
                if (!String.Equals(after.Identity, before.Identity, StringComparison.Ordinal) ||
                    after.IsDirectory != before.IsDirectory || after.IsReparsePoint ||
                    (!directory && (after.LinkCount != 1 || after.Length != before.Length)))
                    throw new InvalidOperationException("Relative cleanup child changed during identity validation: " + name);
                if (GetNamedStreamsByHandle(handle).Length != 0)
                    throw new InvalidOperationException("Relative cleanup child acquired a named alternate data stream: " + name);
                if (directory && GetChildNamesByHandle(handle).Length != 0)
                    throw new InvalidOperationException("Relative cleanup directory acquired a child during identity validation: " + name);

                approved = CloneInfo(after);
                MarkHeldChildForDeletion(handle, name);
                marked = true;
            } finally {
                if (handle != null) handle.Dispose();
            }

            if (!marked) throw new InvalidOperationException("Relative cleanup child was not marked for deletion: " + name);
            return approved;
        }
        public static FileIdentityInfo DeleteChildRegularFileIfIdentity(SafeDirectoryHandle parent, string name, string expectedIdentity) {
            return DeleteChildIfIdentity(parent, name, expectedIdentity, false);
        }
        public static FileIdentityInfo DeleteChildEmptyDirectoryIfIdentity(SafeDirectoryHandle parent, string name, string expectedIdentity) {
            return DeleteChildIfIdentity(parent, name, expectedIdentity, true);
        }
        public static FileReadResult CopyRegularFile(string source, string destination) {
            string destinationFull, destinationParentPath, destinationName;
            GetSafePathParent(destination, out destinationFull, out destinationParentPath, out destinationName);
            using (SafePathRegularFile sourceCapture = OpenSafeRegularFileByPath(source))
            using (SafeDirectoryChain destinationParents = OpenSafeDirectoryChain(destinationParentPath))
                return CopyHeldRegularFile(sourceCapture.File, destinationParents.Leaf, destinationName);
        }
        public static FileReadResult CopyChildRegularFile(SafeDirectoryHandle sourceParent, string sourceName, SafeDirectoryHandle destinationParent, string destinationName) {
            using (SafeRegularFileHandle source = OpenAndHashChildRegularFile(sourceParent, sourceName))
                return CopyHeldRegularFile(source, destinationParent, destinationName);
        }
        public static FileReadResult CopyHeldRegularFile(SafeRegularFileHandle source, SafeDirectoryHandle destinationParent, string destinationName) {
            if (source == null) throw new ArgumentNullException("source");
            FileStream input = source.Stream;
            if (input == null) throw new ObjectDisposedException("source");
            try {
                FileIdentityInfo before = ValidateHeldRegularFileState(source, "before copy");
                input.Position = 0;
                using (SafeFileHandle destinationHandle = OpenRelative(destinationParent, destinationName, GENERIC_WRITE | FILE_READ_ATTRIBUTES, 0, FILE_CREATE, FILE_NON_DIRECTORY_FILE))
                using (var output = new FileStream(destinationHandle, FileAccess.Write))
                using (var sha = SHA256.Create()) {
                    FileIdentityInfo destinationBefore = ReadInfo(destinationHandle);
                    if (destinationBefore.IsDirectory || destinationBefore.IsReparsePoint || destinationBefore.LinkCount != 1)
                        throw new InvalidOperationException("Destination is not a create-new regular file: " + destinationName);
                    if (GetNamedStreamsByHandle(destinationHandle).Length != 0)
                        throw new InvalidOperationException("Destination create-new file has a named alternate data stream: " + destinationName);
                    byte[] buffer = new byte[131072]; int read; long length = 0;
                    while ((read = input.Read(buffer, 0, buffer.Length)) > 0) {
                        output.Write(buffer, 0, read);
                        sha.TransformBlock(buffer, 0, read, null, 0);
                        length += read;
                    }
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    output.Flush(true);
                    string hash = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant();
                    FileIdentityInfo after = ValidateHeldRegularFileState(source, "after copy");
                    if (!String.Equals(after.Identity, before.Identity, StringComparison.Ordinal) || length != source.ExpectedLength ||
                        !String.Equals(hash, source.ExpectedSha256, StringComparison.Ordinal))
                        throw new InvalidOperationException("Held source content changed during copy: " + destinationName);
                    FileIdentityInfo destinationAfter = ReadInfo(destinationHandle);
                    if (destinationAfter.IsDirectory || destinationAfter.IsReparsePoint || destinationAfter.LinkCount != 1 ||
                        !String.Equals(destinationAfter.Identity, destinationBefore.Identity, StringComparison.Ordinal) || destinationAfter.Length != length)
                        throw new InvalidOperationException("Destination changed during create-new copy: " + destinationName);
                    if (GetNamedStreamsByHandle(destinationHandle).Length != 0)
                        throw new InvalidOperationException("Destination acquired a named alternate data stream during copy: " + destinationName);
                    return new FileReadResult { Identity = before.Identity, LinkCount = before.LinkCount, Length = length, Sha256 = hash };
                }
            } finally {
                if (source.Stream != null) source.Stream.Position = 0;
            }
        }
        public static VolumeInfo GetVolumeInfo(string path) {
            string root = Path.GetPathRoot(Path.GetFullPath(path));
            var volumeName = new StringBuilder(261); var fsName = new StringBuilder(261);
            uint serial, maxComponent, flags;
            if (!GetVolumeInformationW(root, volumeName, volumeName.Capacity, out serial, out maxComponent, out flags, fsName, fsName.Capacity))
                throw new Win32Exception(Marshal.GetLastWin32Error(), "Unable to query volume information: " + root);
            uint driveType = GetDriveTypeW(root);
            string driveTypeName = driveType == 3 ? "Fixed" : driveType == 2 ? "Removable" : driveType == 4 ? "Network" : driveType == 5 ? "CDRom" : driveType == 6 ? "Ram" : "Unknown";
            return new VolumeInfo { RootPath = root, FileSystemType = fsName.ToString(), VolumeSerial = serial.ToString("x8"), DriveType = driveTypeName };
        }
    }
}
'@
}

function Test-SafePathInsideRoot {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Root)
    $pathFull = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92, [char]47)
    $rootFull = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]47)
    return $pathFull.Equals($rootFull, [System.StringComparison]::OrdinalIgnoreCase) -or
        $pathFull.StartsWith($rootFull + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function ConvertTo-SafeRelativePath {
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Path)
    $relative = $Path.Replace([char]92, [char]47)
    if ($relative -in @('', '.')) { return '' }
    foreach ($segment in @($relative -split '/')) {
        if ($segment -in @('', '.', '..')) { throw "Unsafe relative path: $Path" }
    }
    return $relative
}

function Test-SafeTreeEntryExcluded {
    param([string] $RelativePath, [string[]] $ExcludeRelativePaths, [string[]] $ExcludePrefixes, [scriptblock] $ShouldSkipEntry)
    foreach ($exact in @($ExcludeRelativePaths)) { if ($RelativePath.Equals(($exact -replace '\\','/'), [System.StringComparison]::OrdinalIgnoreCase)) { return $true } }
    foreach ($prefix in @($ExcludePrefixes)) {
        $normalized = ($prefix -replace '\\','/').TrimEnd('/')
        if ($RelativePath.Equals($normalized, [System.StringComparison]::OrdinalIgnoreCase) -or $RelativePath.StartsWith($normalized + '/', [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    if ($ShouldSkipEntry -and (& $ShouldSkipEntry $RelativePath)) { return $true }
    return $false
}

function Open-SafeDirectoryContainmentChain {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    if (-not (Test-SafePathInsideRoot -Path $full -Root $volumeRoot)) { throw "Safe tree containment path escaped its volume root: $full" }
    $relative = [System.IO.Path]::GetRelativePath($volumeRoot, $full)
    $handles = [System.Collections.Generic.List[object]]::new()
    try {
        $parentHandle = [AiAgentDotfiles.NoFollowFile]::HoldDirectory($volumeRoot)
        $handles.Add($parentHandle)
        if ($relative -ne '.') {
            foreach ($segment in @($relative -split '[\\/]')) {
                if ($segment -in @('', '.', '..')) { throw "Unsafe containment path segment: $full" }
                $childHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldPathChildDirectory($parentHandle, $segment)
                if ($null -eq $childHandle) { throw "Safe tree containment path is missing: $full" }
                $handles.Add($childHandle)
                $parentHandle = $childHandle
            }
        }
        return ,$handles
    }
    catch {
        for ($index = $handles.Count - 1; $index -ge 0; $index--) { $handles[$index].Dispose() }
        throw
    }
}

function Open-SafeExistingDirectoryContainmentChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ref] $ExistingPath
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    if (-not (Test-SafePathInsideRoot -Path $full -Root $volumeRoot)) { throw "Safe tree containment path escaped its volume root: $full" }
    $relative = [System.IO.Path]::GetRelativePath($volumeRoot, $full)
    $handles = [System.Collections.Generic.List[object]]::new()
    $cursor = $volumeRoot
    try {
        $parentHandle = [AiAgentDotfiles.NoFollowFile]::HoldDirectory($volumeRoot)
        $handles.Add($parentHandle)
        if ($relative -ne '.') {
            foreach ($segment in @($relative -split '[\\/]')) {
                if ($segment -in @('', '.', '..')) { throw "Unsafe containment path segment: $full" }
                $childHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldPathChildDirectory($parentHandle, $segment)
                if ($null -eq $childHandle) { break }
                $handles.Add($childHandle)
                $parentHandle = $childHandle
                $cursor = Join-Path $cursor $segment
            }
        }
        $ExistingPath.Value = $cursor
        return ,$handles
    }
    catch {
        Close-SafeDirectoryContainmentChain -Handles $handles
        throw
    }
}

function Close-SafeDirectoryContainmentChain {
    param([object[]] $Handles)
    for ($index = @($Handles).Count - 1; $index -ge 0; $index--) { $Handles[$index].Dispose() }
}

function Get-NoFollowRootEntryMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($full)
    $handles = $null
    try {
        if ([System.IO.Path]::GetRelativePath($volumeRoot, $full) -eq '.') {
            $handles = Open-SafeDirectoryContainmentChain -Path $full
            $info = $handles[$handles.Count - 1].Info
        }
        else {
            $parent = [System.IO.Path]::GetDirectoryName($full)
            $existingParent = $null
            $handles = Open-SafeExistingDirectoryContainmentChain -Path $parent -ExistingPath ([ref]$existingParent)
            if (-not ([System.IO.Path]::GetFullPath($existingParent).TrimEnd([char]92,[char]47).Equals([System.IO.Path]::GetFullPath($parent).TrimEnd([char]92,[char]47), [System.StringComparison]::OrdinalIgnoreCase))) {
                return [pscustomobject][ordered]@{ Path=$full; EntryType='MISSING'; Identity=$null; LinkCount=0 }
            }
            $info = [AiAgentDotfiles.NoFollowFile]::TryInspectChild($handles[$handles.Count - 1], [System.IO.Path]::GetFileName($full))
            if ($null -eq $info) { return [pscustomobject][ordered]@{ Path=$full; EntryType='MISSING'; Identity=$null; LinkCount=0 } }
        }
        $type = if ($info.IsReparsePoint) { 'ReparsePoint' } elseif ($info.IsDirectory) { 'Directory' } else { 'File' }
        return [pscustomobject][ordered]@{ Path=$full; EntryType=$type; Identity=[string]$info.Identity; LinkCount=[long]$info.LinkCount }
    }
    finally { if ($null -ne $handles) { Close-SafeDirectoryContainmentChain -Handles $handles } }
}

function Get-SafeTreeSnapshotInternal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string[]] $ExcludeRelativePaths = @(),
        [string[]] $ExcludePrefixes = @(),
        [scriptblock] $ShouldSkipEntry,
        [switch] $RetainContainmentHandles
    )
    $rootFull = [System.IO.Path]::GetFullPath($Root)
    $containmentHandles = Open-SafeDirectoryContainmentChain -Path $rootFull
    $directoryHandlesByRelativePath = @{ '' = $containmentHandles[$containmentHandles.Count - 1] }
    $fileHandlesByRelativePath = @{}
    $succeeded = $false
    try {
        $rows = [System.Collections.Generic.List[object]]::new()
        $evidence = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $queue = [System.Collections.Generic.Queue[object]]::new()
        $queue.Enqueue([pscustomobject]@{ FullPath=$rootFull; RelativePath=''; ContainmentHandle=$containmentHandles[$containmentHandles.Count - 1] })
        while ($queue.Count -gt 0) {
            $current = $queue.Dequeue()
            $before = $current.ContainmentHandle.Info
            if (-not $before.IsDirectory -or $before.IsReparsePoint) { throw "Safe tree contains a non-directory or reparse directory: $($current.RelativePath)" }
            $streams = @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($current.ContainmentHandle))
            if ($streams.Count -gt 0) { throw "Safe tree directory has a named alternate data stream: $($current.RelativePath)" }
            if (-not $seen.Add([string]$before.Identity)) { throw "Safe tree contains a repeated directory identity: $($current.RelativePath)" }
            $rows.Add([ordered]@{ Type='Directory'; RelativePath=[string]$current.RelativePath })
            $evidence.Add([ordered]@{ Type='Directory'; RelativePath=[string]$current.RelativePath; Identity=[string]$before.Identity; LinkCount=[long]$before.LinkCount; NamedStreamCount=0 })
            foreach ($entryName in @([AiAgentDotfiles.NoFollowFile]::GetChildNames($current.ContainmentHandle) | Sort-Object)) {
                $entry = Join-Path $current.FullPath $entryName
                $relativeSource = if ($current.RelativePath) { Join-Path $current.RelativePath $entryName } else { $entryName }
                $relative = ConvertTo-SafeRelativePath $relativeSource
                if (Test-SafeTreeEntryExcluded -RelativePath $relative -ExcludeRelativePaths $ExcludeRelativePaths -ExcludePrefixes $ExcludePrefixes -ShouldSkipEntry $ShouldSkipEntry) { continue }
                $full = [System.IO.Path]::GetFullPath($entry)
                if (-not (Test-SafePathInsideRoot -Path $full -Root $rootFull)) { throw "Safe tree entry escaped its root: $relative" }
                $directoryHandle = [AiAgentDotfiles.NoFollowFile]::TryHoldChildDirectory($current.ContainmentHandle, $entryName)
                if ($null -ne $directoryHandle) {
                    $containmentHandles.Add($directoryHandle)
                    $directoryHandlesByRelativePath[$relative] = $directoryHandle
                    $queue.Enqueue([pscustomobject]@{ FullPath=$full; RelativePath=$relative; ContainmentHandle=$directoryHandle })
                    continue
                }
                $entryInfo = [AiAgentDotfiles.NoFollowFile]::InspectChild($current.ContainmentHandle, $entryName)
                if ($entryInfo.IsReparsePoint) { throw "Safe tree contains a reparse entry: $relative" }
                if ($entryInfo.IsDirectory) { throw "Safe tree directory changed before containment: $relative" }
                $fileHandle = $null
                try {
                    $fileHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($current.ContainmentHandle, $entryName)
                    $read = $fileHandle.ReadResult
                    if ($read.Identity -cne $entryInfo.Identity -or $read.Length -ne $entryInfo.Length -or $entryInfo.LinkCount -ne 1) { throw "Safe tree file changed during read: $relative" }
                    if (-not $seen.Add([string]$read.Identity)) { throw "Safe tree contains a repeated file identity: $relative" }
                    if ($RetainContainmentHandles) { $fileHandlesByRelativePath[$relative] = $fileHandle; $fileHandle = $null }
                }
                finally { if ($null -ne $fileHandle) { $fileHandle.Dispose() } }
                $rows.Add([ordered]@{ Type='File'; RelativePath=$relative; Length=[long]$read.Length; Sha256=[string]$read.Sha256 })
                $evidence.Add([ordered]@{ Type='File'; RelativePath=$relative; Identity=[string]$read.Identity; LinkCount=1; NamedStreamCount=0 })
            }
        }
        $orderedRows = @($rows | Sort-Object @{Expression='RelativePath';Ascending=$true}, @{Expression='Type';Ascending=$true})
        $orderedEvidence = @($evidence | Sort-Object @{Expression='RelativePath';Ascending=$true}, @{Expression='Type';Ascending=$true})
        $snapshot = [pscustomobject][ordered]@{ Root=$rootFull; ContentTreeRows=$orderedRows; TraversalIdentityEvidence=$orderedEvidence; TreeHash=(Get-SemanticJsonHash -InputObject $orderedRows) }
        $succeeded = $true
        return [pscustomobject]@{ Snapshot=$snapshot; ContainmentHandles=$containmentHandles; DirectoryHandlesByRelativePath=$directoryHandlesByRelativePath; FileHandlesByRelativePath=$fileHandlesByRelativePath }
    }
    finally {
        if (-not $RetainContainmentHandles -or -not $succeeded) {
            foreach ($heldFile in $fileHandlesByRelativePath.Values) { $heldFile.Dispose() }
            Close-SafeDirectoryContainmentChain -Handles $containmentHandles
        }
    }
}

function Get-SafeTreeSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [string[]] $ExcludeRelativePaths = @(),
        [string[]] $ExcludePrefixes = @(),
        [scriptblock] $ShouldSkipEntry
    )
    return (Get-SafeTreeSnapshotInternal -Root $Root -ExcludeRelativePaths $ExcludeRelativePaths -ExcludePrefixes $ExcludePrefixes -ShouldSkipEntry $ShouldSkipEntry).Snapshot
}

function Compare-SafeContentTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]] $LeftRows, [Parameter(Mandatory)] [object[]] $RightRows)
    return (Get-SemanticJsonHash -InputObject @($LeftRows)) -ceq (Get-SemanticJsonHash -InputObject @($RightRows))
}

function Copy-SafeTree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SourceRoot,
        [Parameter(Mandatory)] [string] $DestinationRoot,
        [string[]] $ExcludeRelativePaths = @(),
        [string[]] $ExcludePrefixes = @(),
        [scriptblock] $ShouldSkipEntry
    )
    $source = [System.IO.Path]::GetFullPath($SourceRoot)
    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if ((Test-SafePathInsideRoot $source $destination) -or (Test-SafePathInsideRoot $destination $source)) { throw 'Safe tree source and destination must be disjoint.' }
    $existingDestinationAncestor = $null
    $destinationHandles = Open-SafeExistingDirectoryContainmentChain -Path $destination -ExistingPath ([ref]$existingDestinationAncestor)
    $destinationByRelativePath = @{}
    $destinationByRelativePath[''] = $null
    $sourceTraversal = $null
    try {
        if ([System.IO.Path]::GetFullPath($existingDestinationAncestor).TrimEnd([char]92,[char]47).Equals($destination.TrimEnd([char]92,[char]47), [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Safe tree destination must be create-new: $destination"
        }
        $sourceTraversal = Get-SafeTreeSnapshotInternal -Root $source -ExcludeRelativePaths $ExcludeRelativePaths -ExcludePrefixes $ExcludePrefixes -ShouldSkipEntry $ShouldSkipEntry -RetainContainmentHandles
        $sourceSnapshot = $sourceTraversal.Snapshot
        $evidenceByPath = @{}; foreach ($item in $sourceSnapshot.TraversalIdentityEvidence) { $evidenceByPath["$($item.Type):$($item.RelativePath)"] = $item }
        $relativeDestination = [System.IO.Path]::GetRelativePath($existingDestinationAncestor, $destination)
        $destinationCursor = $existingDestinationAncestor
        $destinationParentHandle = $destinationHandles[$destinationHandles.Count - 1]
        foreach ($segment in @($relativeDestination -split '[\\/]')) {
            if ($segment -in @('', '.', '..')) { throw "Unsafe destination path segment: $destination" }
            $destinationCursor = Join-Path $destinationCursor $segment
            $createdDirectory = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($destinationParentHandle, $segment)
            $destinationHandles.Add($createdDirectory)
            $destinationParentHandle = $createdDirectory
        }
        $destinationByRelativePath[''] = $destinationHandles[$destinationHandles.Count - 1]
        foreach ($row in @($sourceSnapshot.ContentTreeRows | Where-Object { $_.Type -eq 'Directory' -and $_.RelativePath } | Sort-Object @{Expression={($_.RelativePath -split '/').Count}}, RelativePath)) {
            $relativeDirectory = ConvertTo-SafeRelativePath ([string]$row.RelativePath)
            $parentRelative = ConvertTo-SafeRelativePath ([System.IO.Path]::GetDirectoryName($relativeDirectory))
            $leaf = [System.IO.Path]::GetFileName($relativeDirectory)
            $parentHandle = $destinationByRelativePath[$parentRelative]
            if ($null -eq $parentHandle) { throw "Safe tree planned destination parent is missing: $parentRelative" }
            $createdDirectory = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($parentHandle, $leaf)
            $destinationHandles.Add($createdDirectory)
            $destinationByRelativePath[$relativeDirectory] = $createdDirectory
        }
        foreach ($row in @($sourceSnapshot.ContentTreeRows | Where-Object Type -eq 'File' | Sort-Object RelativePath)) {
            $relativeFile = ConvertTo-SafeRelativePath ([string]$row.RelativePath)
            $parentRelative = ConvertTo-SafeRelativePath ([System.IO.Path]::GetDirectoryName($relativeFile))
            $leaf = [System.IO.Path]::GetFileName($relativeFile)
            $destinationParentHandle = $destinationByRelativePath[$parentRelative]
            if ($null -eq $destinationParentHandle) { throw "Safe tree planned destination parent is missing: $parentRelative" }
            $sourceFileHandle = $sourceTraversal.FileHandlesByRelativePath[$relativeFile]
            if ($null -eq $sourceFileHandle) { throw "Safe tree planned source file is missing: $relativeFile" }
            $copy = [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($sourceFileHandle, $destinationParentHandle, $leaf)
            $expected = $evidenceByPath["File:$($row.RelativePath)"]
            if ($copy.Identity -cne [string]$expected.Identity -or $copy.Length -ne [long]$row.Length -or $copy.Sha256 -cne [string]$row.Sha256) { throw "Safe tree source changed during copy: $($row.RelativePath)" }
        }
        $destinationSnapshot = Get-SafeTreeSnapshot -Root $destination
        if (-not (Compare-SafeContentTree -LeftRows $sourceSnapshot.ContentTreeRows -RightRows $destinationSnapshot.ContentTreeRows)) { throw 'Safe tree destination content differs from source.' }
        return [pscustomobject][ordered]@{ SourceSnapshot=$sourceSnapshot; DestinationSnapshot=$destinationSnapshot; SourceTreeHash=$sourceSnapshot.TreeHash; DestinationTreeHash=$destinationSnapshot.TreeHash }
    }
    catch {
        Close-SafeDirectoryContainmentChain -Handles $destinationHandles
        $destinationHandles = $null
        throw
    }
    finally {
        if ($null -ne $sourceTraversal) {
            foreach ($heldFile in $sourceTraversal.FileHandlesByRelativePath.Values) { $heldFile.Dispose() }
            Close-SafeDirectoryContainmentChain -Handles $sourceTraversal.ContainmentHandles
        }
        if ($null -ne $destinationHandles) { Close-SafeDirectoryContainmentChain -Handles $destinationHandles }
    }
}
