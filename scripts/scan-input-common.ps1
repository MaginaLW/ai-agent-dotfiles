#requires -Version 7.0

Set-StrictMode -Version Latest

if (-not $IsWindows) {
    throw 'The Phase 0 no-follow scan walker currently supports Windows only.'
}

if (-not ('AiAgentDotfiles.NoFollowFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
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

    public sealed class FileCopyResult {
        public string Identity { get; set; }
        public uint LinkCount { get; set; }
        public long Length { get; set; }
        public string Sha256 { get; set; }
    }

    public static class NoFollowFile {
        private const uint GENERIC_READ = 0x80000000;
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        private static readonly IntPtr INVALID_HANDLE_VALUE = new IntPtr(-1);

        [StructLayout(LayoutKind.Sequential)]
        private struct FILETIME {
            public uint Low;
            public uint High;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct BY_HANDLE_FILE_INFORMATION {
            public FileAttributes FileAttributes;
            public FILETIME CreationTime;
            public FILETIME LastAccessTime;
            public FILETIME LastWriteTime;
            public uint VolumeSerialNumber;
            public uint FileSizeHigh;
            public uint FileSizeLow;
            public uint NumberOfLinks;
            public uint FileIndexHigh;
            public uint FileIndexLow;
        }

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct WIN32_FIND_STREAM_DATA {
            public long StreamSize;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 296)]
            public string StreamName;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName, uint desiredAccess, uint shareMode, IntPtr securityAttributes,
            uint creationDisposition, uint flagsAndAttributes, IntPtr templateFile);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out BY_HANDLE_FILE_INFORMATION info);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern IntPtr FindFirstStreamW(string fileName, int infoLevel, out WIN32_FIND_STREAM_DATA data, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern bool FindNextStreamW(IntPtr handle, out WIN32_FIND_STREAM_DATA data);

        [DllImport("kernel32.dll")]
        private static extern bool FindClose(IntPtr handle);

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

        private static FileIdentityInfo ReadInfo(SafeFileHandle handle) {
            BY_HANDLE_FILE_INFORMATION raw;
            if (!GetFileInformationByHandle(handle, out raw)) throw new Win32Exception(Marshal.GetLastWin32Error());
            ulong index = ((ulong)raw.FileIndexHigh << 32) | raw.FileIndexLow;
            long length = ((long)raw.FileSizeHigh << 32) | raw.FileSizeLow;
            return new FileIdentityInfo {
                Identity = raw.VolumeSerialNumber.ToString("x8") + ":" + index.ToString("x16"),
                LinkCount = raw.NumberOfLinks,
                Length = length,
                Attributes = raw.FileAttributes
            };
        }

        public static FileIdentityInfo Inspect(string path) {
            using (SafeFileHandle handle = OpenMetadata(path, 0, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)) {
                return ReadInfo(handle);
            }
        }

        public static string[] GetNamedStreams(string path) {
            WIN32_FIND_STREAM_DATA data;
            IntPtr find = FindFirstStreamW(NormalizeNativePath(path), 0, out data, 0);
            if (find == INVALID_HANDLE_VALUE) {
                int error = Marshal.GetLastWin32Error();
                if (error == 38) return Array.Empty<string>();
                throw new Win32Exception(error, "Unable to enumerate alternate data streams: " + path);
            }
            try {
                var streams = new System.Collections.Generic.List<string>();
                do {
                    if (!String.Equals(data.StreamName, "::$DATA", StringComparison.OrdinalIgnoreCase)) streams.Add(data.StreamName);
                } while (FindNextStreamW(find, out data));
                int error = Marshal.GetLastWin32Error();
                if (error != 38) throw new Win32Exception(error, "Unable to finish alternate data stream enumeration: " + path);
                return streams.ToArray();
            } finally {
                FindClose(find);
            }
        }

        public static FileCopyResult CopyRegularFile(string source, string destination) {
            using (SafeFileHandle handle = OpenMetadata(source, GENERIC_READ, FILE_SHARE_READ)) {
                FileIdentityInfo info = ReadInfo(handle);
                if (info.IsDirectory || info.IsReparsePoint) throw new InvalidOperationException("Source is not a regular file: " + source);
                if (info.LinkCount != 1) throw new InvalidOperationException("Source has multiple hard links: " + source);
                using (var input = new FileStream(handle, FileAccess.Read))
                using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                using (var sha = SHA256.Create()) {
                    byte[] buffer = new byte[131072];
                    int read;
                    long length = 0;
                    while ((read = input.Read(buffer, 0, buffer.Length)) > 0) {
                        output.Write(buffer, 0, read);
                        sha.TransformBlock(buffer, 0, read, null, 0);
                        length += read;
                    }
                    sha.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
                    output.Flush(true);
                    return new FileCopyResult {
                        Identity = info.Identity,
                        LinkCount = info.LinkCount,
                        Length = length,
                        Sha256 = BitConverter.ToString(sha.Hash).Replace("-", "").ToLowerInvariant()
                    };
                }
            }
        }
    }
}
'@
}

function Get-ProtectedReasonixRelativePaths {
    [CmdletBinding()]
    param()

    return @(
        '.reasonix/desktop-topic-auto-title-meta.json',
        '.reasonix/desktop-topic-created-at.json',
        '.reasonix/desktop-topic-title-sources.json',
        '.reasonix/desktop-topic-titles.json'
    )
}

function Get-ScanSourcePolicyHash {
    $policy = @(
        'phase0-scan-input-v1',
        'include=git-ls-files-tracked-plus-nonignored',
        'exclude-prefix=claude/skills/',
        'exclude-prefix=codex/skills/',
        'exclude-prefix=reasonix/skills/',
        'exclude-prefix=envs/',
        'exclude-prefix=reports/',
        'exclude-prefix=tmp/',
        'exclude-prefix=imports/'
    ) + @(Get-ProtectedReasonixRelativePaths | ForEach-Object { "protected=$_" })
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes(($policy -join "`n") + "`n")
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Test-PathInsideRoot {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Assert-NoFollowDirectoryChain {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $FilePath)

    $relativeParent = [System.IO.Path]::GetRelativePath($RepoRoot, (Split-Path -Parent $FilePath))
    $current = $RepoRoot
    $parts = if ($relativeParent -eq '.') { @() } else { @($relativeParent -split '[\\/]') }
    foreach ($part in @('') + $parts) {
        if ($part) { $current = Join-Path $current $part }
        $info = [AiAgentDotfiles.NoFollowFile]::Inspect($current)
        if (-not $info.IsDirectory -or $info.IsReparsePoint) {
            throw "Directory chain contains a non-directory or reparse entry: $current"
        }
    }
}

function Normalize-ScanRelativePath {
    param([Parameter(Mandatory)] [string] $RelativePath)

    $normalized = $RelativePath.Replace([char]92, [char]47)
    if ($normalized.StartsWith('./', [System.StringComparison]::Ordinal)) {
        $normalized = $normalized.Substring(2)
    }
    if ([string]::IsNullOrWhiteSpace($normalized) -or [System.IO.Path]::IsPathRooted($normalized)) {
        throw "Invalid repository-relative scan path: $RelativePath"
    }
    foreach ($segment in @($normalized -split '/')) {
        if ($segment -in @('', '.', '..')) { throw "Invalid repository-relative scan path: $RelativePath" }
    }
    return $normalized
}

function New-FilteredScanInput {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $DestinationRoot
    )

    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $DestinationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
    if (Test-Path -LiteralPath $DestinationRoot) { throw "DestinationRoot must be create-new: $DestinationRoot" }
    if ((Test-PathInsideRoot -Path $DestinationRoot -Root $RepoRoot) -or (Test-PathInsideRoot -Path $RepoRoot -Root $DestinationRoot)) {
        throw 'DestinationRoot and RepoRoot must be disjoint.'
    }

    $protected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in Get-ProtectedReasonixRelativePaths) { $null = $protected.Add($relative) }
    $protectedIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($relative in Get-ProtectedReasonixRelativePaths) {
        $full = Join-Path $RepoRoot $relative
        if (Test-Path -LiteralPath $full) {
            $metadata = [AiAgentDotfiles.NoFollowFile]::Inspect($full)
            $null = $protectedIdentities.Add($metadata.Identity)
        }
    }

    $excludedPrefixes = @('.git/', 'claude/skills/', 'codex/skills/', 'reasonix/skills/', 'envs/', 'reports/', 'tmp/', 'imports/')
    $fileEntries = [System.Collections.Generic.List[object]]::new()
    $pendingDirectories = [System.Collections.Generic.Queue[string]]::new()
    $pendingDirectories.Enqueue($RepoRoot)
    while ($pendingDirectories.Count -gt 0) {
        $directory = $pendingDirectories.Dequeue()
        foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $relative = Normalize-ScanRelativePath -RelativePath ([System.IO.Path]::GetRelativePath($RepoRoot, $entry))
            if ($protected.Contains($relative)) { continue }
            $excluded = @($excludedPrefixes | Where-Object {
                $prefixRoot = $_.TrimEnd('/')
                $relative.Equals($prefixRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
                    $relative.StartsWith($_, [System.StringComparison]::OrdinalIgnoreCase)
            }).Count -gt 0
            if ($excluded) { continue }
            $full = [System.IO.Path]::GetFullPath($entry)
            if (-not (Test-PathInsideRoot -Path $full -Root $RepoRoot)) { throw "Scan input escaped RepoRoot: $relative" }
            $info = [AiAgentDotfiles.NoFollowFile]::Inspect($full)
            if ($info.IsReparsePoint) { throw "Repository scan tree contains a reparse entry: $relative" }
            if ($info.IsDirectory) {
                & git -C $RepoRoot check-ignore --quiet -- $relative
                $ignoreCode = $LASTEXITCODE
                if ($ignoreCode -eq 0) { continue }
                if ($ignoreCode -ne 1) { throw "git check-ignore failed for directory: $relative" }
                $pendingDirectories.Enqueue($full)
            }
            else {
                $fileEntries.Add([pscustomobject]@{ RelativePath = $relative; FullPath = $full; Metadata = $info })
            }
        }
    }

    $ignoredFiles = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($fileEntries.Count -gt 0) {
        $ignoredOutput = @($fileEntries.RelativePath | & git -C $RepoRoot check-ignore --stdin)
        $ignoreCode = $LASTEXITCODE
        if ($ignoreCode -notin @(0, 1)) { throw 'git check-ignore failed for file inputs.' }
        foreach ($ignored in $ignoredOutput) { $null = $ignoredFiles.Add((Normalize-ScanRelativePath -RelativePath ([string]$ignored))) }
    }
    $seenIdentities = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $candidates = [System.Collections.Generic.List[object]]::new()
    foreach ($entry in @($fileEntries | Sort-Object RelativePath)) {
        $relative = $entry.RelativePath
        if ($ignoredFiles.Contains($relative)) { continue }
        $full = $entry.FullPath
        Assert-NoFollowDirectoryChain -RepoRoot $RepoRoot -FilePath $full
        $info = $entry.Metadata
        if ($info.IsDirectory -or $info.IsReparsePoint) { throw "Scan input is not a regular file: $relative" }
        if ($info.LinkCount -ne 1) { throw "Scan input has multiple hard links: $relative" }
        $streams = @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($full))
        if ($streams.Count -gt 0) { throw "Scan input has a named alternate data stream: $relative" }
        if ($protectedIdentities.Contains($info.Identity)) { throw "Scan input aliases a protected Reasonix file: $relative" }
        if (-not $seenIdentities.Add($info.Identity)) { throw "Duplicate file identity in scan input: $relative" }
        $candidates.Add([pscustomobject]@{ RelativePath = $relative; FullPath = $full; Identity = $info.Identity; Length = [long]$info.Length })
    }

    [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($candidate in @($candidates | Sort-Object RelativePath)) {
            $destination = Join-Path $DestinationRoot $candidate.RelativePath
            $parent = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
            $copy = [AiAgentDotfiles.NoFollowFile]::CopyRegularFile($candidate.FullPath, $destination)
            $after = [AiAgentDotfiles.NoFollowFile]::Inspect($candidate.FullPath)
            if ($copy.Identity -ne $candidate.Identity -or $after.Identity -ne $candidate.Identity -or $copy.Length -ne $candidate.Length -or $after.Length -ne $candidate.Length -or $after.LinkCount -ne 1 -or $after.IsReparsePoint) {
                throw "Scan input identity or content metadata drifted during copy: $($candidate.RelativePath)"
            }
            $rows.Add([ordered]@{
                RelativePath = $candidate.RelativePath
                Length = [long] $copy.Length
                Sha256 = $copy.Sha256
                IdentityHash = $candidate.Identity
                LinkCount = 1
                NamedStreamCount = 0
            })
        }
    }
    catch {
        if (Test-Path -LiteralPath $DestinationRoot -PathType Container) { Remove-Item -LiteralPath $DestinationRoot -Recurse -Force }
        throw
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'scan-input-manifest'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        SourcePolicyHash = Get-ScanSourcePolicyHash
        SourceRoot = $RepoRoot
        DestinationRoot = $DestinationRoot
        ExcludedProtectedPaths = @(Get-ProtectedReasonixRelativePaths)
        Files = @($rows)
    }
}

function Write-ScanInputManifest {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Manifest, [Parameter(Mandatory)] [string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Manifest -Depth 20) + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}
