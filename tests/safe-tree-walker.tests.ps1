#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/path-safety-fixtures.ps1')
. (Join-Path $RepoRoot 'scripts/safe-tree-walker.ps1')

$work = New-PathSafetyFixtureRoot -Prefix 'ai-agent-dotfiles-safe-tree'
try {
    $source = Join-Path $work 'source'
    [System.IO.Directory]::CreateDirectory((Join-Path $source 'empty')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $source 'nested/deeper')) | Out-Null
    New-PathSafetyFile -Path (Join-Path $source 'root.txt') -Content 'root bytes' | Out-Null
    New-PathSafetyFile -Path (Join-Path $source 'nested/deeper/value.txt') -Content 'nested bytes' | Out-Null

    Write-Host '[content rows and deterministic copy]'
    $snapshot = Get-SafeTreeSnapshot -Root $source
    Assert-TestCondition (@($snapshot.ContentTreeRows | Where-Object { $_.Type -eq 'Directory' -and $_.RelativePath -eq '' }).Count -eq 1) 'content rows include the root directory'
    Assert-TestCondition (@($snapshot.ContentTreeRows | Where-Object { $_.Type -eq 'Directory' -and $_.RelativePath -eq 'empty' }).Count -eq 1) 'content rows preserve an empty directory'
    Assert-TestCondition (@($snapshot.ContentTreeRows | Where-Object Type -eq 'File').Count -eq 2) 'content rows include regular unnamed streams only'
    Assert-TestCondition ($snapshot.TraversalIdentityEvidence.Count -eq $snapshot.ContentTreeRows.Count) 'identity evidence is separate and complete'

    $copyRoot = Join-Path $work 'copy'
    $copy = Copy-SafeTree -SourceRoot $source -DestinationRoot $copyRoot
    Assert-TestCondition ($copy.SourceTreeHash -ceq $copy.DestinationTreeHash) 'safe copy preserves the semantic content-tree hash'
    Assert-TestCondition (Compare-SafeContentTree -LeftRows $snapshot.ContentTreeRows -RightRows $copy.DestinationSnapshot.ContentTreeRows) 'safe copy preserves exact file and empty-directory shape'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath (Join-Path $copyRoot 'nested/deeper/value.txt')) -ceq 'nested bytes') 'safe copy preserves file bytes'

    $missingParentCopyRoot = Join-Path $work 'missing-parent/deeper/copy'
    $missingParentCopy = Copy-SafeTree -SourceRoot $source -DestinationRoot $missingParentCopyRoot
    Assert-TestCondition ($missingParentCopy.SourceTreeHash -ceq $missingParentCopy.DestinationTreeHash) 'safe copy create-new builds and contains a full missing destination-parent chain'
    $existingDestinationRoot = Join-Path $work 'existing-destination'
    [System.IO.Directory]::CreateDirectory($existingDestinationRoot) | Out-Null
    Assert-PathSafetyThrows -Script { Copy-SafeTree -SourceRoot $source -DestinationRoot $existingDestinationRoot } -Pattern 'create-new' -Message 'safe copy never reuses an existing destination root'

    $baselineHash = $snapshot.TreeHash
    [System.IO.Directory]::CreateDirectory((Join-Path $source 'another-empty')) | Out-Null
    Assert-TestCondition ((Get-SafeTreeSnapshot -Root $source).TreeHash -cne $baselineHash) 'empty-directory addition changes the tree hash'
    Remove-Item -LiteralPath (Join-Path $source 'another-empty')
    Move-Item -LiteralPath (Join-Path $source 'empty') -Destination (Join-Path $source 'renamed-empty')
    Assert-TestCondition ((Get-SafeTreeSnapshot -Root $source).TreeHash -cne $baselineHash) 'empty-directory rename changes the tree hash'
    Move-Item -LiteralPath (Join-Path $source 'renamed-empty') -Destination (Join-Path $source 'empty')

    Write-Host '[held regular file bounded bytes]'
    $heldReadPath = Join-Path $source 'held-read.txt'
    $heldReadBytes = [System.Text.Encoding]::UTF8.GetBytes('approved-held-bytes')
    $sameLengthRewrite = [System.Text.Encoding]::UTF8.GetBytes('modified-held-bytes')
    [System.IO.File]::WriteAllBytes($heldReadPath, $heldReadBytes)
    Assert-TestCondition ($sameLengthRewrite.Length -eq $heldReadBytes.Length) 'held-file rewrite fixture preserves byte length'
    $heldReadChain = $null
    $heldReadFile = $null
    try {
        $heldReadChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $source -OwnershipReceiver $heldReadChainReceiver
        $heldReadChain = $heldReadChainReceiver.GetDeliveredExact()
        $heldReadParent = $heldReadChain[$heldReadChain.Count - 1]

        $preExistingWriter = [System.IO.File]::Open($heldReadPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
        try {
            Assert-PathSafetyThrows -Script {
                $candidate = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($heldReadParent, 'held-read.txt')
                try { $candidate.ReadResult | Out-Null } finally { $candidate.Dispose() }
            } -Pattern 'open|used by another process|access' -Message 'held-file acquisition rejects a pre-existing writer'
        }
        finally { $preExistingWriter.Dispose() }

        $heldReadFile = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($heldReadParent, 'held-read.txt')
        $firstHeldBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, 1024)
        $secondHeldBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, 1024)
        Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($firstHeldBytes, $heldReadBytes) -and [System.Linq.Enumerable]::SequenceEqual[byte]($secondHeldBytes, $heldReadBytes)) 'held-file bytes are repeatable from position zero on the same handle'
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, $heldReadBytes.Length - 1) | Out-Null
        } -Pattern 'maximum|limit|exceed' -Message 'held-file byte read enforces the caller maximum'

        Assert-PathSafetyThrows -Script {
            $rewrite = [System.IO.File]::Open($heldReadPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try {
                $rewrite.Position = 0
                $rewrite.Write($sameLengthRewrite, 0, $sameLengthRewrite.Length)
                $rewrite.Flush($true)
            }
            finally { $rewrite.Dispose() }
        } -Pattern 'open|used by another process|access' -Message 'held-file share mode blocks same-length in-place rewrite'
        $afterRewriteAttempt = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, 1024)
        Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($afterRewriteAttempt, $heldReadBytes)) 'blocked rewrite leaves held-file bytes unchanged and readable from position zero'

        $heldCopyDestination = Join-Path $work 'held-copy-destination'
        [System.IO.Directory]::CreateDirectory($heldCopyDestination) | Out-Null
        $heldCopyChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $heldCopyDestination -OwnershipReceiver $heldCopyChainReceiver
        $heldCopyChain = $heldCopyChainReceiver.GetDeliveredExact()
        try {
            $heldCopyParent = $heldCopyChain[$heldCopyChain.Count - 1]
            $liveHardLink = Join-Path $source 'held-read-live-hardlink.txt'
            New-PathSafetyHardLink -Path $liveHardLink -Target $heldReadPath | Out-Null
            try {
                Assert-PathSafetyThrows -Script {
                    [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, 1024) | Out-Null
                } -Pattern 'hard link|multiple' -Message 'held-file byte read rejects a hard link added after acquisition'
                Assert-PathSafetyThrows -Script {
                    [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($heldReadFile, $heldCopyParent, 'hardlink-rejected.txt') | Out-Null
                } -Pattern 'hard link|multiple' -Message 'held-file copy rejects a hard link added after acquisition'
            }
            finally { Remove-Item -LiteralPath $liveHardLink -Force }
            Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $heldCopyDestination 'hardlink-rejected.txt'))) 'post-acquisition hard-link rejection creates no destination'

            Add-PathSafetyNamedStream -Path $heldReadPath
            try {
                Assert-PathSafetyThrows -Script {
                    [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, 1024) | Out-Null
                } -Pattern 'stream' -Message 'held-file byte read rejects an alternate stream added after acquisition'
                Assert-PathSafetyThrows -Script {
                    [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($heldReadFile, $heldCopyParent, 'stream-rejected.txt') | Out-Null
                } -Pattern 'stream' -Message 'held-file copy rejects an alternate stream added after acquisition'
            }
            finally { Remove-Item -LiteralPath $heldReadPath -Stream 'safety-sentinel' }
            Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $heldCopyDestination 'stream-rejected.txt'))) 'post-acquisition ADS rejection creates no destination'

            $colonBase = Join-Path $heldCopyDestination 'colon-base.txt'
            [System.IO.File]::WriteAllText($colonBase, 'base', [System.Text.UTF8Encoding]::new($false))
            Assert-PathSafetyThrows -Script {
                [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($heldReadFile, $heldCopyParent, 'colon-base.txt:unsafe-stream') | Out-Null
            } -Pattern 'non-stream|component|Relative entry name' -Message 'relative create rejects a colon ADS destination name'
            Assert-TestCondition (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($colonBase)).Count -eq 0) 'colon destination rejection creates no named stream'

            $instanceNonPublic = [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic
            $expectedHashField = [AiAgentDotfiles.SafeRegularFileHandle].GetField('expectedSha256', $instanceNonPublic)
            $streamProperty = [AiAgentDotfiles.SafeRegularFileHandle].GetProperty('Stream', $instanceNonPublic)
            $heldStream = $streamProperty.GetValue($heldReadFile)
            $approvedExpectedHash = $expectedHashField.GetValue($heldReadFile)
            try {
                $expectedHashField.SetValue($heldReadFile, ('0' * 64))
                Assert-PathSafetyThrows -Script {
                    [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($heldReadFile, $heldCopyParent, 'post-write-failure.txt') | Out-Null
                } -Pattern 'content changed' -Message 'held-file copy fails closed after a sealed post-write authority mismatch'
                Assert-TestCondition ($heldStream.Position -eq 0) 'held-file copy resets source position after post-write failure'
            }
            finally { $expectedHashField.SetValue($heldReadFile, $approvedExpectedHash) }
            $afterCopyFailure = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($heldReadFile, 1024)
            Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($afterCopyFailure, $heldReadBytes)) 'held-file bytes remain repeatable after post-write copy failure'
        }
        finally { Close-SafeDirectoryContainmentChain -Handles $heldCopyChain }
        $heldReadFile.Dispose()
        $heldReadFile = $null

        $heldReadHardLink = Join-Path $source 'held-read-hardlink.txt'
        New-PathSafetyHardLink -Path $heldReadHardLink -Target $heldReadPath | Out-Null
        try {
            Assert-PathSafetyThrows -Script {
                $candidate = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($heldReadParent, 'held-read.txt')
                try { $candidate.ReadResult | Out-Null } finally { $candidate.Dispose() }
            } -Pattern 'hard link|multiple' -Message 'held-file byte API cannot acquire a multi-link source'
        }
        finally { Remove-Item -LiteralPath $heldReadHardLink -Force }

        Add-PathSafetyNamedStream -Path $heldReadPath
        try {
            Assert-PathSafetyThrows -Script {
                $candidate = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($heldReadParent, 'held-read.txt')
                try { $candidate.ReadResult | Out-Null } finally { $candidate.Dispose() }
            } -Pattern 'stream' -Message 'held-file byte API cannot acquire a source with an alternate data stream'
        }
        finally { Remove-Item -LiteralPath $heldReadPath -Stream 'safety-sentinel' }
    }
    finally {
        if ($null -ne $heldReadFile) { $heldReadFile.Dispose() }
        if ($null -ne $heldReadChain) { Close-SafeDirectoryContainmentChain -Handles $heldReadChain }
    }

    Write-Host '[create-and-seal regular file for external readers]'
    $sealedParentPath = Join-Path $work 'sealed-instance'
    [System.IO.Directory]::CreateDirectory($sealedParentPath) | Out-Null
    $sealedChain = $null
    $sealedHandle = $null
    try {
        $sealedChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $sealedParentPath -OwnershipReceiver $sealedChainReceiver
        $sealedChain = $sealedChainReceiver.GetDeliveredExact()
        $sealedParent = $sealedChain[$sealedChain.Count - 1]
        $sealedName = 'instances.jsonl'
        $sealedPath = Join-Path $sealedParentPath $sealedName
        $sealedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("{`"SchemaVersion`":1}`n{`"SchemaVersion`":2}`n")
        $sealedRewrite = [System.Text.UTF8Encoding]::new($false).GetBytes("{`"SchemaVersion`":3}`n{`"SchemaVersion`":4}`n")
        Assert-TestCondition ($sealedRewrite.Length -eq $sealedBytes.Length) 'sealed instance mutation fixture preserves byte length'

        $sealedHandle = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($sealedParent, $sealedName, $sealedBytes)
        $sealedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sealedBytes)).ToLowerInvariant()
        Assert-TestCondition ([string]$sealedHandle.Info.Identity -ceq [string]$sealedHandle.ReadResult.Identity -and [long]$sealedHandle.ReadResult.Length -eq $sealedBytes.Length -and [string]$sealedHandle.ReadResult.Sha256 -ceq $sealedHash) 'sealed instance returns one exact regular-file identity, length, and hash'
        $sealedHeldBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($sealedHandle, 4096)
        Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($sealedHeldBytes, $sealedBytes)) 'sealed instance remains exact on its returned held read handle'

        $readerScript = @'
$bytes = [IO.File]::ReadAllBytes($env:SAFE_TREE_SEALED_PATH)
[Console]::Out.WriteLine([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant())
[Console]::Out.Flush()
$null = [Console]::In.ReadLine()
'@
        $readerInfo = [Diagnostics.ProcessStartInfo]::new()
        $readerInfo.FileName = (Get-Command pwsh).Source
        $readerInfo.UseShellExecute = $false
        $readerInfo.RedirectStandardInput = $true
        $readerInfo.RedirectStandardOutput = $true
        $readerInfo.RedirectStandardError = $true
        $readerInfo.CreateNoWindow = $true
        $readerInfo.Environment['SAFE_TREE_SEALED_PATH'] = $sealedPath
        $readerInfo.ArgumentList.Add('-NoProfile')
        $readerInfo.ArgumentList.Add('-EncodedCommand')
        $readerInfo.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($readerScript)))
        $reader = [Diagnostics.Process]::new()
        $reader.StartInfo = $readerInfo
        try {
            Assert-TestCondition ($reader.Start()) 'sealed instance launches an isolated path reader'
            $readerOutput = $reader.StandardOutput.ReadLine()
            $reader.Refresh()
            Assert-TestCondition (-not $reader.HasExited -and $readerOutput -ceq $sealedHash) 'sealed instance is readable by a concurrently alive external CLI'

            Assert-PathSafetyThrows -Script {
                $writer = [IO.File]::Open($sealedPath, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                try { $writer.Write($sealedRewrite, 0, $sealedRewrite.Length); $writer.Flush($true) } finally { $writer.Dispose() }
            } -Pattern 'open|used by another process|access|sharing' -Message 'sealed instance blocks a same-length mutation writer while the external reader remains alive'
            Assert-PathSafetyThrows -Script {
                Move-Item -LiteralPath $sealedPath -Destination (Join-Path $sealedParentPath 'renamed.jsonl') -ErrorAction Stop
            } -Pattern 'used by another process|access|denied|cannot' -Message 'sealed instance blocks rename while the external reader remains alive'
            Assert-PathSafetyThrows -Script {
                Remove-Item -LiteralPath $sealedPath -Force -ErrorAction Stop
            } -Pattern 'used by another process|access|denied|cannot' -Message 'sealed instance blocks delete while the external reader remains alive'
            $reader.Refresh()
            Assert-TestCondition (-not $reader.HasExited) 'external CLI stays alive throughout sealed mutation, rename, and delete probes'

            $reader.StandardInput.WriteLine('release')
            $reader.StandardInput.Flush()
            $reader.StandardInput.Close()
            $readerExited = $reader.WaitForExit(15000)
            if (-not $readerExited) { $reader.Kill($true); $reader.WaitForExit() }
            $readerError = $reader.StandardError.ReadToEnd()
            Assert-TestCondition ($readerExited -and $reader.ExitCode -eq 0) ("external CLI exits cleanly after the sealed probes ({0})" -f $readerError)
        }
        finally {
            if (-not $reader.HasExited) {
                try { $reader.StandardInput.WriteLine('release'); $reader.StandardInput.Flush(); $reader.StandardInput.Close() } catch {}
                if (-not $reader.WaitForExit(5000)) { $reader.Kill($true); $reader.WaitForExit() }
            }
            $reader.Dispose()
        }
        $sealedAfterAttempts = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($sealedHandle, 4096)
        Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($sealedAfterAttempts, $sealedBytes)) 'rejected mutation, rename, and delete leave sealed bytes exact'

        $safeTreeSourceText = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts/safe-tree-walker.ps1')
        $sealApiText = [regex]::Match($safeTreeSourceText, '(?s)public static SafeRegularFileHandle CreateAndSealChildRegularFile\(.+?\n\s*\}\n\s*private static SafeLockFileHandle').Value
        Assert-TestCondition ($sealApiText -match 'OpenRelative' -and $sealApiText -notmatch 'OpenMetadata|CreateFileW|File\.Open|Path\.') 'writer-to-bridge-to-sealed transition uses only held-parent-relative child opens'

        $sealedHandle.Dispose(); $sealedHandle = $null
        $releasedPath = Join-Path $sealedParentPath 'released.jsonl'
        Move-Item -LiteralPath $sealedPath -Destination $releasedPath -ErrorAction Stop
        Assert-TestCondition ((Test-Path -LiteralPath $releasedPath -PathType Leaf) -and -not (Test-Path -LiteralPath $sealedPath)) 'disposing the sealed handle releases rename/delete sharing for cleanup'
        Remove-Item -LiteralPath $releasedPath -Force
    }
    finally {
        if ($null -ne $sealedHandle) { $sealedHandle.Dispose() }
        if ($null -ne $sealedChain) { Close-SafeDirectoryContainmentChain -Handles $sealedChain }
    }

    Write-Host '[held-parent-relative identity-bound cleanup]'
    if (-not ('AiAgentDotfilesTest.AttributeLeaseProbe' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace AiAgentDotfilesTest {
    public static class AttributeLeaseProbe {
        private const uint FILE_SHARE_READ = 0x00000001;
        private const uint FILE_SHARE_WRITE = 0x00000002;
        private const uint FILE_SHARE_DELETE = 0x00000004;
        private const uint OPEN_EXISTING = 3;
        private const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000;
        private const uint FILE_FLAG_OPEN_REPARSE_POINT = 0x00200000;
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string path, uint access, uint share, IntPtr security,
            uint disposition, uint flags, IntPtr template);
        public static SafeFileHandle Open(string path) {
            SafeFileHandle handle = CreateFileW(path, 0,
                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, IntPtr.Zero, OPEN_EXISTING,
                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, IntPtr.Zero);
            if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
            return handle;
        }
    }
}
'@
    }
    $deleteParentPath = Join-Path $work 'identity-delete'
    [System.IO.Directory]::CreateDirectory($deleteParentPath) | Out-Null
    $deleteChain = $null
    $deleteSealedHandle = $null
    $deleteDirectoryHandle = $null
    $deleteReader = $null
    try {
        $deleteChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $deleteParentPath -OwnershipReceiver $deleteChainReceiver
        $deleteChain = $deleteChainReceiver.GetDeliveredExact()
        $deleteParent = $deleteChain[$deleteChain.Count - 1]

        Write-Host '[held owned directory cleanup]'
        $ownedEmptyHandle = $null
        $ownedWrongIdentityHandle = $null
        $ownedForeignHandle = $null
        $ownedAdsHandle = $null
        $ownedMutableReceiptHandle = $null
        try {
            $ownedEmptyName = 'owned-held-empty'
            $ownedEmptyPath = Join-Path $deleteParentPath $ownedEmptyName
            $ownedEmptyMovedPath = Join-Path $deleteParentPath 'owned-held-empty-moved'
            $ownedEmptyHandle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($deleteParent, $ownedEmptyName)
            $ownedEmptyIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ownedEmptyHandle)
            Assert-TestCondition ($ownedEmptyIdentity -cmatch '^[0-9a-f]{8}:[0-9a-f]{16}$' -and
                [uint32][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredLinkCountExact($ownedEmptyHandle) -eq 1 -and
                [uint32][AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($ownedEmptyHandle).LinkCount -eq 1 -and
                [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($ownedEmptyHandle)) 'held cleanup directory returns an immutable acquired identity receipt'
            Assert-PathSafetyThrows -Script {
                [IO.Directory]::Move($ownedEmptyPath, $ownedEmptyMovedPath)
            } -Pattern 'used by another process|access|denied|sharing' -Message 'held cleanup directory blocks an external same-name move before exact deletion'
            Assert-PathSafetyThrows -Script {
                [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($deleteParent, $ownedEmptyName) | Out-Null
            } -Pattern 'exist|create|open child|collision' -Message 'held cleanup directory creation is create-new and never adopts an existing same-name entry'
            $ownedEmptyDeleted = [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedEmptyHandle, $ownedEmptyIdentity)
            $ownedEmptyHandle = $null
            Assert-TestCondition ([string]$ownedEmptyDeleted.Identity -ceq $ownedEmptyIdentity -and
                -not (Test-Path -LiteralPath $ownedEmptyPath) -and -not (Test-Path -LiteralPath $ownedEmptyMovedPath)) 'held cleanup deletes the exact acquired empty directory without a name reopen'

            $ownedWrongIdentityName = 'owned-held-wrong-identity'
            $ownedWrongIdentityPath = Join-Path $deleteParentPath $ownedWrongIdentityName
            $ownedWrongIdentityHandle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($deleteParent, $ownedWrongIdentityName)
            $ownedWrongIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ownedWrongIdentityHandle)
            Assert-PathSafetyThrows -Script {
                [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedWrongIdentityHandle, '00000000:0000000000000001') | Out-Null
            } -Pattern 'identity|expected' -Message 'held cleanup rejects a wrong expected identity'
            Assert-TestCondition ((Test-Path -LiteralPath $ownedWrongIdentityPath -PathType Container) -and
                [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($ownedWrongIdentityHandle)) 'wrong held-cleanup identity preserves the directory and its held lease'
            [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedWrongIdentityHandle, $ownedWrongIdentity) | Out-Null
            $ownedWrongIdentityHandle = $null

            $ownedForeignName = 'owned-held-foreign-child'
            $ownedForeignPath = Join-Path $deleteParentPath $ownedForeignName
            $ownedForeignFile = Join-Path $ownedForeignPath 'foreign.bin'
            $ownedForeignBytes = [Text.UTF8Encoding]::new($false).GetBytes('foreign child must survive rejection')
            $ownedForeignHandle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($deleteParent, $ownedForeignName)
            $ownedForeignIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ownedForeignHandle)
            [IO.File]::WriteAllBytes($ownedForeignFile, $ownedForeignBytes)
            Assert-PathSafetyThrows -Script {
                [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedForeignHandle, $ownedForeignIdentity) | Out-Null
            } -Pattern 'empty|child|entry' -Message 'held cleanup rejects a directory containing a foreign child'
            Assert-TestCondition ((Test-Path -LiteralPath $ownedForeignFile -PathType Leaf) -and
                [System.Linq.Enumerable]::SequenceEqual[byte]([IO.File]::ReadAllBytes($ownedForeignFile), $ownedForeignBytes) -and
                [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($ownedForeignHandle)) 'foreign-child rejection preserves exact bytes and keeps the owned slot held'
            $ownedForeignFileIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($ownedForeignHandle, 'foreign.bin')).Identity
            [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($ownedForeignHandle, 'foreign.bin', $ownedForeignFileIdentity) | Out-Null
            [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedForeignHandle, $ownedForeignIdentity) | Out-Null
            $ownedForeignHandle = $null

            $ownedAdsName = 'owned-held-ads'
            $ownedAdsPath = Join-Path $deleteParentPath $ownedAdsName
            $ownedAdsHandle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($deleteParent, $ownedAdsName)
            $ownedAdsIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ownedAdsHandle)
            $ownedAdsStreamHandle = [IO.File]::OpenHandle(
                ($ownedAdsPath + ':safety-sentinel'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,
                ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete),[IO.FileOptions]::None)
            try {
                $ownedAdsStream = [IO.FileStream]::new($ownedAdsStreamHandle,[IO.FileAccess]::Write)
                try { $ownedAdsStream.WriteByte(1); $ownedAdsStream.Flush($true) }
                finally { $ownedAdsStream.Dispose() }
            }
            finally { if (-not $ownedAdsStreamHandle.IsClosed) { $ownedAdsStreamHandle.Dispose() } }
            Assert-PathSafetyThrows -Script {
                [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedAdsHandle, $ownedAdsIdentity) | Out-Null
            } -Pattern 'stream' -Message 'held cleanup rejects an owned directory that acquired an alternate stream'
            Assert-TestCondition ((Test-Path -LiteralPath $ownedAdsPath -PathType Container) -and
                @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($ownedAdsHandle)).Count -eq 1) 'held cleanup preserves a directory and its alternate stream after rejection'
            [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($ownedAdsHandle)
            $ownedAdsHandle = $null
            [IO.File]::Delete($ownedAdsPath + ':safety-sentinel')
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, $ownedAdsName, $ownedAdsIdentity) | Out-Null

            $ownedMutableReceiptName = 'owned-held-mutable-receipt'
            $ownedMutableReceiptPath = Join-Path $deleteParentPath $ownedMutableReceiptName
            $ownedMutableReceiptHandle = [AiAgentDotfiles.NoFollowFile]::CreateHeldChildDirectoryForCleanup($deleteParent, $ownedMutableReceiptName)
            $ownedMutableReceiptIdentity = [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ownedMutableReceiptHandle)
            [AiAgentDotfiles.SafeDirectoryHandle]::GetInfoExact($ownedMutableReceiptHandle).Identity = '00000000:0000000000000002'
            Assert-PathSafetyThrows -Script {
                [AiAgentDotfiles.NoFollowFile]::DeleteHeldEmptyDirectoryIfIdentity($ownedMutableReceiptHandle, $ownedMutableReceiptIdentity) | Out-Null
            } -Pattern 'identity|receipt|acquired' -Message 'held cleanup rejects a mutable public receipt that diverges from the immutable acquired identity'
            Assert-TestCondition ((Test-Path -LiteralPath $ownedMutableReceiptPath -PathType Container) -and
                [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($ownedMutableReceiptHandle) -ceq $ownedMutableReceiptIdentity) 'mutable receipt rejection preserves the exact acquired directory'
            [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($ownedMutableReceiptHandle)
            $ownedMutableReceiptHandle = $null
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, $ownedMutableReceiptName, $ownedMutableReceiptIdentity) | Out-Null
        }
        finally {
            foreach ($heldOwned in @($ownedMutableReceiptHandle,$ownedAdsHandle,$ownedForeignHandle,$ownedWrongIdentityHandle,$ownedEmptyHandle)) {
                if ($null -ne $heldOwned) { try { [AiAgentDotfiles.SafeDirectoryHandle]::DisposeExact($heldOwned) } catch {} }
            }
        }

        $regularDeletePath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'regular.txt') -Content 'controlled regular bytes'
        $regularDeleteInfo = [AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'regular.txt')
        $regularDeleted = [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'regular.txt', [string]$regularDeleteInfo.Identity)
        Assert-TestCondition ([string]$regularDeleted.Identity -ceq [string]$regularDeleteInfo.Identity -and -not (Test-Path -LiteralPath $regularDeletePath)) 'identity-bound regular cleanup deletes the exact relative child'

        $attributeLeasePath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'attribute-lease.txt') -Content 'attribute lease bytes'
        $attributeLeaseIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'attribute-lease.txt')).Identity
        $attributeLease = [AiAgentDotfilesTest.AttributeLeaseProbe]::Open($attributeLeasePath)
        try {
            $attributeLeaseDeleted = [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'attribute-lease.txt', $attributeLeaseIdentity)
            Assert-TestCondition ([string]$attributeLeaseDeleted.Identity -ceq $attributeLeaseIdentity -and -not $attributeLease.IsClosed -and -not $attributeLease.IsInvalid) 'identity cleanup commits the exact file while an attributes-only share-delete lease remains alive'
            Assert-TestCondition (-not (Test-Path -LiteralPath $attributeLeasePath)) 'identity cleanup removes the namespace link before returning despite an attributes-only lease'
        }
        finally { $attributeLease.Dispose() }
        Assert-TestCondition (-not (Test-Path -LiteralPath $attributeLeasePath)) 'closing an attributes-only lease cannot turn a reported cleanup failure into delayed deletion'

        $replacementPath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'replacement.txt') -Content 'original controlled bytes'
        $originalReplacementIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'replacement.txt')).Identity
        Remove-Item -LiteralPath $replacementPath -Force
        New-PathSafetyFile -Path $replacementPath -Content 'replacement must survive' | Out-Null
        $replacementInfo = [AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'replacement.txt')
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'replacement.txt', $originalReplacementIdentity) | Out-Null
        } -Pattern 'identity|expected' -Message 'identity-bound regular cleanup rejects a same-name replacement'
        Assert-TestCondition ([string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'replacement.txt')).Identity -ceq [string]$replacementInfo.Identity -and (Get-Content -Raw -LiteralPath $replacementPath) -ceq 'replacement must survive') 'regular replacement rejection preserves replacement identity and bytes'

        $hardDeletePath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'hardlink.txt') -Content 'hardlink cleanup bytes'
        $hardDeleteLink = Join-Path $deleteParentPath 'hardlink-second.txt'
        New-PathSafetyHardLink -Path $hardDeleteLink -Target $hardDeletePath | Out-Null
        $hardDeleteIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'hardlink.txt')).Identity
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'hardlink.txt', $hardDeleteIdentity) | Out-Null
        } -Pattern 'hard link|multiple|link' -Message 'identity-bound regular cleanup rejects a multi-link child'
        Assert-TestCondition ((Test-Path -LiteralPath $hardDeletePath) -and (Test-Path -LiteralPath $hardDeleteLink)) 'hard-link rejection preserves every link'
        Remove-Item -LiteralPath $hardDeleteLink -Force
        [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'hardlink.txt', $hardDeleteIdentity) | Out-Null

        $adsDeletePath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'ads.txt') -Content 'stream cleanup bytes'
        Add-PathSafetyNamedStream -Path $adsDeletePath
        $adsDeleteIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'ads.txt')).Identity
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'ads.txt', $adsDeleteIdentity) | Out-Null
        } -Pattern 'stream' -Message 'identity-bound regular cleanup rejects a child with an alternate stream'
        Assert-TestCondition ((Test-Path -LiteralPath $adsDeletePath) -and @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($adsDeletePath)).Count -eq 1) 'alternate-stream rejection preserves the base file and named stream'
        Remove-Item -LiteralPath $adsDeletePath -Stream 'safety-sentinel'
        [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'ads.txt', $adsDeleteIdentity) | Out-Null

        $typeDirectoryPath = Join-Path $deleteParentPath 'regular-type-directory'
        [System.IO.Directory]::CreateDirectory($typeDirectoryPath) | Out-Null
        $typeDirectoryIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'regular-type-directory')).Identity
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'regular-type-directory', $typeDirectoryIdentity) | Out-Null
        } -Pattern 'directory|regular|open child' -Message 'regular cleanup rejects a directory child without deleting it'
        Assert-TestCondition (Test-Path -LiteralPath $typeDirectoryPath -PathType Container) 'regular type-mismatch rejection preserves the directory'
        [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'regular-type-directory', $typeDirectoryIdentity) | Out-Null

        $typeFilePath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'directory-type-file.txt') -Content 'regular file must survive directory API'
        $typeFileIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'directory-type-file.txt')).Identity
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'directory-type-file.txt', $typeFileIdentity) | Out-Null
        } -Pattern 'directory|regular|open child' -Message 'directory cleanup rejects a regular-file child without deleting it'
        Assert-TestCondition ((Test-Path -LiteralPath $typeFilePath -PathType Leaf) -and (Get-Content -Raw -LiteralPath $typeFilePath) -ceq 'regular file must survive directory API') 'directory type-mismatch rejection preserves regular-file bytes'
        [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'directory-type-file.txt', $typeFileIdentity) | Out-Null

        $emptyDeletePath = Join-Path $deleteParentPath 'empty-directory'
        [System.IO.Directory]::CreateDirectory($emptyDeletePath) | Out-Null
        $emptyDeleteInfo = [AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'empty-directory')
        $emptyDeleted = [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'empty-directory', [string]$emptyDeleteInfo.Identity)
        Assert-TestCondition ([string]$emptyDeleted.Identity -ceq [string]$emptyDeleteInfo.Identity -and -not (Test-Path -LiteralPath $emptyDeletePath)) 'identity-bound directory cleanup deletes the exact empty relative child'

        $nonemptyDeletePath = Join-Path $deleteParentPath 'nonempty-directory'
        [System.IO.Directory]::CreateDirectory($nonemptyDeletePath) | Out-Null
        New-PathSafetyFile -Path (Join-Path $nonemptyDeletePath 'sentinel.txt') -Content 'must survive' | Out-Null
        $nonemptyDeleteIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'nonempty-directory')).Identity
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'nonempty-directory', $nonemptyDeleteIdentity) | Out-Null
        } -Pattern 'empty|contains|directory' -Message 'identity-bound directory cleanup rejects a nonempty child'
        Assert-TestCondition ((Get-Content -Raw -LiteralPath (Join-Path $nonemptyDeletePath 'sentinel.txt')) -ceq 'must survive') 'nonempty-directory rejection preserves its child bytes'
        Remove-Item -LiteralPath $nonemptyDeletePath -Recurse -Force

        $directoryReplacementPath = Join-Path $deleteParentPath 'directory-replacement'
        [System.IO.Directory]::CreateDirectory($directoryReplacementPath) | Out-Null
        $originalDirectoryIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'directory-replacement')).Identity
        [System.IO.Directory]::Delete($directoryReplacementPath, $false)
        [System.IO.Directory]::CreateDirectory($directoryReplacementPath) | Out-Null
        $replacementDirectoryInfo = [AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'directory-replacement')
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'directory-replacement', $originalDirectoryIdentity) | Out-Null
        } -Pattern 'identity|expected' -Message 'identity-bound directory cleanup rejects a same-name replacement'
        Assert-TestCondition ([string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'directory-replacement')).Identity -ceq [string]$replacementDirectoryInfo.Identity) 'directory replacement rejection preserves the replacement'
        [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'directory-replacement', [string]$replacementDirectoryInfo.Identity) | Out-Null

        $deleteOutsidePath = Join-Path $work 'identity-delete-outside'
        [System.IO.Directory]::CreateDirectory($deleteOutsidePath) | Out-Null
        $deleteOutsideSentinel = New-PathSafetyFile -Path (Join-Path $deleteOutsidePath 'sentinel.txt') -Content 'outside must survive'
        $deleteJunctionPath = Join-Path $deleteParentPath 'directory-junction'
        New-PathSafetyJunction -Path $deleteJunctionPath -Target $deleteOutsidePath | Out-Null
        $deleteJunctionIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'directory-junction')).Identity
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'directory-junction', $deleteJunctionIdentity) | Out-Null
        } -Pattern 'reparse|directory|open child' -Message 'identity-bound directory cleanup rejects a reparse child'
        Assert-TestCondition ((Test-Path -LiteralPath $deleteJunctionPath) -and (Get-Content -Raw -LiteralPath $deleteOutsideSentinel) -ceq 'outside must survive') 'reparse rejection preserves the entry and never deletes outside content'
        Remove-Item -LiteralPath $deleteJunctionPath -Force

        $busySealedBytes = [Text.UTF8Encoding]::new($false).GetBytes('busy sealed cleanup')
        $deleteSealedHandle = [AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($deleteParent, 'busy-sealed.txt', $busySealedBytes)
        $busySealedIdentity = [string]$deleteSealedHandle.Info.Identity
        $busySealedCode = $null
        try { [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'busy-sealed.txt', $busySealedIdentity) | Out-Null }
        catch { $failure = $_.Exception; while ($failure.InnerException) { $failure = $failure.InnerException }; if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $busySealedCode = [int]$failure.NativeErrorCode } }
        Assert-TestCondition ($busySealedCode -eq 32 -and (Test-Path -LiteralPath (Join-Path $deleteParentPath 'busy-sealed.txt'))) 'active sealed handle blocks identity cleanup with sharing violation and preserves the file'
        $deleteSealedHandle.Dispose(); $deleteSealedHandle = $null
        [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'busy-sealed.txt', $busySealedIdentity) | Out-Null

        $deleteDirectoryHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($deleteParent, 'busy-directory')
        $busyDirectoryIdentity = [string]$deleteDirectoryHandle.Info.Identity
        $busyDirectoryCode = $null
        try { [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'busy-directory', $busyDirectoryIdentity) | Out-Null }
        catch { $failure = $_.Exception; while ($failure.InnerException) { $failure = $failure.InnerException }; if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $busyDirectoryCode = [int]$failure.NativeErrorCode } }
        Assert-TestCondition ($busyDirectoryCode -eq 32 -and (Test-Path -LiteralPath (Join-Path $deleteParentPath 'busy-directory'))) 'active child-directory handle blocks identity cleanup with sharing violation and preserves the directory'
        $deleteDirectoryHandle.Dispose(); $deleteDirectoryHandle = $null
        [AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($deleteParent, 'busy-directory', $busyDirectoryIdentity) | Out-Null

        $externalDeletePath = New-PathSafetyFile -Path (Join-Path $deleteParentPath 'external-reader.txt') -Content 'external reader cleanup'
        $externalDeleteIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($deleteParent, 'external-reader.txt')).Identity
        $deleteReaderScript = @'
$stream = [IO.File]::Open($env:SAFE_TREE_DELETE_PATH, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
[Console]::Out.WriteLine('ready')
[Console]::Out.Flush()
$null = [Console]::In.ReadLine()
$stream.Dispose()
'@
        $deleteReaderInfo = [Diagnostics.ProcessStartInfo]::new()
        $deleteReaderInfo.FileName = (Get-Command pwsh).Source
        $deleteReaderInfo.UseShellExecute = $false
        $deleteReaderInfo.RedirectStandardInput = $true
        $deleteReaderInfo.RedirectStandardOutput = $true
        $deleteReaderInfo.RedirectStandardError = $true
        $deleteReaderInfo.CreateNoWindow = $true
        $deleteReaderInfo.Environment['SAFE_TREE_DELETE_PATH'] = $externalDeletePath
        $deleteReaderInfo.ArgumentList.Add('-NoProfile')
        $deleteReaderInfo.ArgumentList.Add('-EncodedCommand')
        $deleteReaderInfo.ArgumentList.Add([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($deleteReaderScript)))
        $deleteReader = [Diagnostics.Process]::new(); $deleteReader.StartInfo = $deleteReaderInfo
        Assert-TestCondition ($deleteReader.Start() -and $deleteReader.StandardOutput.ReadLine() -ceq 'ready') 'identity cleanup launches an isolated external share-read lease'
        $externalReaderDeleteCode = $null
        try { [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'external-reader.txt', $externalDeleteIdentity) | Out-Null }
        catch { $failure = $_.Exception; while ($failure.InnerException) { $failure = $failure.InnerException }; if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $externalReaderDeleteCode = [int]$failure.NativeErrorCode } }
        Assert-TestCondition ($externalReaderDeleteCode -eq 32 -and (Test-Path -LiteralPath $externalDeletePath)) 'external share-read lease blocks identity cleanup and preserves the file'
        $deleteReader.StandardInput.WriteLine('release'); $deleteReader.StandardInput.Flush(); $deleteReader.StandardInput.Close()
        $deleteReaderExited = $deleteReader.WaitForExit(15000)
        if (-not $deleteReaderExited) { $deleteReader.Kill($true); $deleteReader.WaitForExit() }
        Assert-TestCondition ($deleteReaderExited -and $deleteReader.ExitCode -eq 0) 'external share-read lease exits before exact cleanup'
        $deleteReader.Dispose(); $deleteReader = $null
        [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'external-reader.txt', $externalDeleteIdentity) | Out-Null

        $missingDeleteCode = $null
        try { [AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($deleteParent, 'missing.txt', '00000000:0000000000000001') | Out-Null }
        catch { $failure = $_.Exception; while ($failure.InnerException) { $failure = $failure.InnerException }; if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $missingDeleteCode = [int]$failure.NativeErrorCode } }
        Assert-TestCondition ($missingDeleteCode -in @(2,3)) 'identity cleanup treats a missing child as a strict native failure'

        $deleteApiText = [regex]::Match((Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts/safe-tree-walker.ps1')), '(?s)private static void MarkHeldChildForDeletion\(.+?public static FileIdentityInfo DeleteChildEmptyDirectoryIfIdentity\(.+?\n\s*\}').Value
        Assert-TestCondition ($deleteApiText -match 'OpenRelative' -and $deleteApiText -match 'NtSetInformationFile' -and $deleteApiText -notmatch 'File\.Delete|Directory\.Delete|OpenMetadata|CreateFileW|Path\.') 'identity cleanup uses only held-parent-relative no-follow handles and handle disposition'
        Assert-TestCondition ($deleteApiText -match 'FILE_DISPOSITION_POSIX_SEMANTICS' -and $deleteApiText -notmatch 'TryInspectChild') 'identity cleanup treats POSIX disposition as its commit point and performs no fallible path reopen afterward'
    }
    finally {
        if ($null -ne $deleteReader) {
            if (-not $deleteReader.HasExited) {
                try { $deleteReader.StandardInput.WriteLine('release'); $deleteReader.StandardInput.Flush(); $deleteReader.StandardInput.Close() } catch {}
                if (-not $deleteReader.WaitForExit(5000)) { $deleteReader.Kill($true); $deleteReader.WaitForExit() }
            }
            $deleteReader.Dispose()
        }
        if ($null -ne $deleteDirectoryHandle) { $deleteDirectoryHandle.Dispose() }
        if ($null -ne $deleteSealedHandle) { $deleteSealedHandle.Dispose() }
        if ($null -ne $deleteChain) { Close-SafeDirectoryContainmentChain -Handles $deleteChain }
    }

    Write-Host '[held create-new atomic no-replace publish]'
    $publishAnchor = Join-Path $work 'held-publish-anchor'
    $publishAnchorMoved = Join-Path $work 'held-publish-anchor-moved'
    $publishTempParentPath = Join-Path $publishAnchor 'pending'
    $publishFinalParentPath = Join-Path $publishAnchor 'published'
    [System.IO.Directory]::CreateDirectory($publishTempParentPath) | Out-Null
    [System.IO.Directory]::CreateDirectory($publishFinalParentPath) | Out-Null
    $publishTempChain = $null
    $publishFinalChain = $null
    $publishHandle = $null
    $collisionHandle = $null
    $publishAnchorMovedUnexpectedly = $false
    try {
        $publishTempChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $publishTempParentPath -OwnershipReceiver $publishTempChainReceiver
        $publishTempChain = $publishTempChainReceiver.GetDeliveredExact()
        $publishFinalChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $publishFinalParentPath -OwnershipReceiver $publishFinalChainReceiver
        $publishFinalChain = $publishFinalChainReceiver.GetDeliveredExact()
        $publishTempParent = $publishTempChain[$publishTempChain.Count - 1]
        $publishFinalParent = $publishFinalChain[$publishFinalChain.Count - 1]
        $publishBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('{"Result":"PASS","Sequence":1}')
        $publishTempPath = Join-Path $publishTempParentPath 'record.tmp'

        $occupiedTempPath = New-PathSafetyFile -Path (Join-Path $publishTempParentPath 'occupied.tmp') -Content 'occupied temp'
        $occupiedTempIdentity = [string]([AiAgentDotfiles.NoFollowFile]::InspectChild($publishTempParent, 'occupied.tmp')).Identity
        Assert-PathSafetyThrows -Script {
            $unexpectedTemp = [AiAgentDotfiles.NoFollowFile]::CreateAndHashChildRegularFile($publishTempParent, 'occupied.tmp', $publishBytes)
            try { $unexpectedTemp.ReadResult | Out-Null } finally { $unexpectedTemp.Dispose() }
        } -Pattern 'exist|collision|open|create' -Message 'held temp creation is create-new and rejects an occupied pending slot'
        Assert-TestCondition ([string]([AiAgentDotfiles.NoFollowFile]::InspectChild($publishTempParent, 'occupied.tmp')).Identity -ceq $occupiedTempIdentity -and (Get-Content -Raw -LiteralPath $occupiedTempPath) -ceq 'occupied temp') 'occupied pending-slot rejection preserves incumbent identity and bytes'

        $publishHandle = [AiAgentDotfiles.NoFollowFile]::CreateAndHashChildRegularFile($publishTempParent, 'record.tmp', $publishBytes)
        $publishIdentity = [string]$publishHandle.ReadResult.Identity
        $publishHeldBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($publishHandle, 4096)
        Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($publishHeldBytes, $publishBytes)) 'create-new publish bytes are flushed and re-read from the same held handle'
        Assert-TestCondition ([string]$publishHandle.Info.Identity -ceq $publishIdentity -and [long]$publishHandle.ReadResult.Length -eq $publishBytes.Length) 'create-new publish handle binds one regular-file identity and exact length'
        Assert-PathSafetyThrows -Script {
            $writer = [System.IO.File]::Open($publishTempPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::ReadWrite)
            try { $writer.WriteByte(1) } finally { $writer.Dispose() }
        } -Pattern 'open|used by another process|access' -Message 'create-new publish handle denies a second writer'
        Assert-PathSafetyThrows -Script {
            Move-Item -LiteralPath $publishTempPath -Destination (Join-Path $publishTempParentPath 'external-rename.tmp') -ErrorAction Stop
        } -Pattern 'used by another process|access|denied|cannot' -Message 'create-new publish handle denies external delete/rename sharing'

        try {
            Move-Item -LiteralPath $publishAnchor -Destination $publishAnchorMoved -ErrorAction Stop
            $publishAnchorMovedUnexpectedly = $true
        }
        catch {}
        Assert-TestCondition (-not $publishAnchorMovedUnexpectedly) 'held publish parent chains block ordinary ancestor rename throughout publication'

        $publishedInfo = [AiAgentDotfiles.NoFollowFile]::RenameHeldRegularFileNoReplace($publishHandle, $publishFinalParent, 'record.json')
        Assert-TestCondition ([string]$publishedInfo.Identity -ceq $publishIdentity -and -not (Test-Path -LiteralPath $publishTempPath) -and (Test-Path -LiteralPath (Join-Path $publishFinalParentPath 'record.json'))) 'atomic no-replace rename publishes the exact held source identity'
        $publishHandle.Dispose(); $publishHandle = $null
        $publishedRead = [AiAgentDotfiles.NoFollowFile]::HashChildRegularFile($publishFinalParent, 'record.json')
        Assert-TestCondition ([string]$publishedRead.Identity -ceq $publishIdentity -and [string]$publishedRead.Sha256 -ceq ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($publishBytes)).ToLowerInvariant())) 'published child identity and bytes equal the same-handle source capture'

        $collisionBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('incumbent')
        [System.IO.File]::WriteAllBytes((Join-Path $publishFinalParentPath 'collision.json'), $collisionBytes)
        $rejectedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes('must-not-replace')
        $collisionHandle = [AiAgentDotfiles.NoFollowFile]::CreateAndHashChildRegularFile($publishTempParent, 'collision.tmp', $rejectedBytes)
        Assert-PathSafetyThrows -Script {
            [AiAgentDotfiles.NoFollowFile]::RenameHeldRegularFileNoReplace($collisionHandle, $publishFinalParent, 'collision.json') | Out-Null
        } -Pattern 'exist|collision|replace|rename' -Message 'atomic no-replace rename rejects a populated final slot'
        $collisionHeldBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($collisionHandle, 4096)
        Assert-TestCondition ([System.Linq.Enumerable]::SequenceEqual[byte]($collisionHeldBytes, $rejectedBytes) -and [System.Linq.Enumerable]::SequenceEqual[byte]([System.IO.File]::ReadAllBytes((Join-Path $publishFinalParentPath 'collision.json')), $collisionBytes)) 'rename collision preserves both held temp bytes and incumbent final bytes'
    }
    finally {
        if ($null -ne $collisionHandle) { $collisionHandle.Dispose() }
        if ($null -ne $publishHandle) { $publishHandle.Dispose() }
        if ($null -ne $publishFinalChain) { Close-SafeDirectoryContainmentChain -Handles $publishFinalChain }
        if ($null -ne $publishTempChain) { Close-SafeDirectoryContainmentChain -Handles $publishTempChain }
        if ($publishAnchorMovedUnexpectedly -and (Test-Path -LiteralPath $publishAnchorMoved) -and -not (Test-Path -LiteralPath $publishAnchor)) {
            Move-Item -LiteralPath $publishAnchorMoved -Destination $publishAnchor
        }
    }

    Write-Host '[held open-or-create regular lock]'
    $lockAnchor = Join-Path $work 'held-lock-anchor'
    $lockAnchorMoved = Join-Path $work 'held-lock-anchor-moved'
    $lockParentPath = Join-Path $lockAnchor 'locks'
    [System.IO.Directory]::CreateDirectory($lockParentPath) | Out-Null
    $lockChain = $null
    $lockHandle = $null
    $lockAnchorMovedUnexpectedly = $false
    try {
        $lockChainReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $lockParentPath -OwnershipReceiver $lockChainReceiver
        $lockChain = $lockChainReceiver.GetDeliveredExact()
        $lockParent = $lockChain[$lockChain.Count - 1]
        $lockPath = Join-Path $lockParentPath 'canonical.lock'
        $lockHandle = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lockParent, 'canonical.lock')
        $lockIdentity = [string]$lockHandle.Info.Identity
        $lockMetadata = [System.Text.UTF8Encoding]::new($false).GetBytes('owner=fixture')
        $lockHandle.Stream.SetLength(0)
        $lockHandle.Stream.Write($lockMetadata, 0, $lockMetadata.Length)
        $lockHandle.Stream.Flush($true)
        Assert-TestCondition ($lockHandle.Stream.CanRead -and $lockHandle.Stream.CanWrite -and -not $lockHandle.Info.IsDirectory -and -not $lockHandle.Info.IsReparsePoint -and [long]$lockHandle.Info.LinkCount -eq 1) 'lock acquisition returns one held read/write regular-file stream with handle-derived identity'
        Assert-TestCondition ([string]([AiAgentDotfiles.NoFollowFile]::InspectChild($lockParent, 'canonical.lock')).Identity -ceq $lockIdentity) 'lock child name resolves to the exact held lock identity'
        Assert-PathSafetyThrows -Script {
            Move-Item -LiteralPath $lockPath -Destination (Join-Path $lockParentPath 'renamed.lock') -ErrorAction Stop
        } -Pattern 'used by another process|access|denied|cannot' -Message 'held lock denies leaf delete/rename sharing for the lock lifetime'

        $busyClock = [System.Diagnostics.Stopwatch]::StartNew()
        $secondWriterBusy = $false
        $secondWriterNativeError = $null
        try {
            $secondLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lockParent, 'canonical.lock')
            try { $secondLock.Info | Out-Null } finally { $secondLock.Dispose() }
        }
        catch {
            $secondWriterBusy = $_.Exception.Message -match 'open|used by another process|sharing|busy|access'
            $busyFailure = $_.Exception
            while ($busyFailure.InnerException) { $busyFailure = $busyFailure.InnerException }
            if ($busyFailure.PSObject.Properties.Name -contains 'NativeErrorCode') { $secondWriterNativeError = [int]$busyFailure.NativeErrorCode }
        }
        $busyClock.Stop()
        Assert-TestCondition ($secondWriterBusy -and $secondWriterNativeError -eq 32 -and $busyClock.ElapsedMilliseconds -lt 1000) 'second lock writer fails immediately with a sharing violation and no wait or replacement'

        try {
            Move-Item -LiteralPath $lockAnchor -Destination $lockAnchorMoved -ErrorAction Stop
            $lockAnchorMovedUnexpectedly = $true
        }
        catch {}
        Assert-TestCondition (-not $lockAnchorMovedUnexpectedly) 'held lock parent chain blocks ordinary ancestor replacement for the lock lifetime'

        $lockHandle.Dispose(); $lockHandle = $null
        $reopenedLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lockParent, 'canonical.lock')
        try {
            $reopenedBytes = [byte[]]::new($lockMetadata.Length)
            $reopenedLock.Stream.Position = 0
            $reopenedCount = $reopenedLock.Stream.Read($reopenedBytes, 0, $reopenedBytes.Length)
            Assert-TestCondition ([string]$reopenedLock.Info.Identity -ceq $lockIdentity -and $reopenedCount -eq $lockMetadata.Length -and [System.Linq.Enumerable]::SequenceEqual[byte]($reopenedBytes, $lockMetadata)) 'released lock reopens the same existing identity without truncating its metadata bytes'
        }
        finally { $reopenedLock.Dispose() }

        $noCreateName = 'status-missing.lock'
        $noCreatePath = Join-Path $lockParentPath $noCreateName
        $noCreateBeforeNames = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($lockParent) | Sort-Object)
        $noCreateBeforeHash = [string](Get-SafeTreeSnapshot -Root $lockParentPath).TreeHash
        $noCreateStatus = $null
        try {
            $unexpectedLock = [AiAgentDotfiles.NoFollowFile]::OpenChildLockFile($lockParent, $noCreateName)
            try { $unexpectedLock.Info | Out-Null } finally { $unexpectedLock.Dispose() }
        }
        catch {
            $noCreateFailure = $_.Exception
            while ($noCreateFailure.InnerException) { $noCreateFailure = $noCreateFailure.InnerException }
            if (($noCreateFailure.PSObject.Properties.Name -contains 'NativeErrorCode') -and [int]$noCreateFailure.NativeErrorCode -in @(2,3)) {
                $noCreateStatus = 'canonical-lock-missing'
            }
        }
        $noCreateAfterNames = @([AiAgentDotfiles.NoFollowFile]::GetChildNames($lockParent) | Sort-Object)
        $noCreateAfterHash = [string](Get-SafeTreeSnapshot -Root $lockParentPath).TreeHash
        Assert-TestCondition ($noCreateStatus -ceq 'canonical-lock-missing' -and -not (Test-Path -LiteralPath $noCreatePath)) 'existing-only lock acquisition maps a missing child to canonical-lock-missing without creating it'
        Assert-TestCondition ([string]::Join("`n", [string[]]$noCreateBeforeNames) -ceq [string]::Join("`n", [string[]]$noCreateAfterNames) -and $noCreateBeforeHash -ceq $noCreateAfterHash) 'existing-only missing lock leaves parent inventory and content-tree hash unchanged'

        $existingOnlyLock = [AiAgentDotfiles.NoFollowFile]::OpenChildLockFile($lockParent, 'canonical.lock')
        try {
            Assert-TestCondition ([string]$existingOnlyLock.Info.Identity -ceq $lockIdentity) 'existing-only lock acquisition opens the exact existing regular-file identity'
        }
        finally { $existingOnlyLock.Dispose() }
        $safeTreeSourceText = Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts/safe-tree-walker.ps1')
        $existingOnlyApiText = [regex]::Match($safeTreeSourceText, '(?s)public static SafeLockFileHandle OpenChildLockFile\(.+?\n\s*\}').Value
        Assert-TestCondition ($existingOnlyApiText -match 'OpenChildLockFileCore\(parent, name, FILE_OPEN\)' -and $existingOnlyApiText -notmatch 'Inspect|TryInspect|FILE_OPEN_IF|File\.|Path\.') 'existing-only lock acquisition uses one atomic FILE_OPEN with no path precheck or delete-recreate window'

        $hardLinkBase = New-PathSafetyFile -Path (Join-Path $lockParentPath 'hardlink-base') -Content 'hardlink lock base'
        $hardLinkLock = Join-Path $lockParentPath 'hardlink.lock'
        New-PathSafetyHardLink -Path $hardLinkLock -Target $hardLinkBase | Out-Null
        try {
            Assert-PathSafetyThrows -Script {
                $unsafeLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lockParent, 'hardlink.lock')
                try { $unsafeLock.Info | Out-Null } finally { $unsafeLock.Dispose() }
            } -Pattern 'hard link|multiple' -Message 'lock acquisition rejects an existing multi-link file'
        }
        finally { Remove-Item -LiteralPath $hardLinkLock -Force; Remove-Item -LiteralPath $hardLinkBase -Force }

        $adsLock = New-PathSafetyFile -Path (Join-Path $lockParentPath 'ads.lock') -Content 'ads lock base'
        Add-PathSafetyNamedStream -Path $adsLock
        try {
            Assert-PathSafetyThrows -Script {
                $unsafeLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lockParent, 'ads.lock')
                try { $unsafeLock.Info | Out-Null } finally { $unsafeLock.Dispose() }
            } -Pattern 'stream' -Message 'lock acquisition rejects an existing named alternate data stream'
        }
        finally { Remove-Item -LiteralPath $adsLock -Stream 'safety-sentinel'; Remove-Item -LiteralPath $adsLock -Force }

        $outsideLockDirectory = Join-Path $work 'held-lock-outside'
        $outsideLockSentinel = New-PathSafetyFile -Path (Join-Path $outsideLockDirectory 'sentinel.txt') -Content 'outside lock sentinel'
        $reparseLock = Join-Path $lockParentPath 'reparse.lock'
        New-PathSafetyJunction -Path $reparseLock -Target $outsideLockDirectory | Out-Null
        try {
            Assert-PathSafetyThrows -Script {
                $unsafeLock = [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($lockParent, 'reparse.lock')
                try { $unsafeLock.Info | Out-Null } finally { $unsafeLock.Dispose() }
            } -Pattern 'open|regular|reparse|directory' -Message 'lock acquisition rejects a reparse child without following it'
            Assert-TestCondition ((Get-Content -Raw -LiteralPath $outsideLockSentinel) -ceq 'outside lock sentinel') 'reparse lock rejection leaves the outside target byte-identical'
        }
        finally { Remove-Item -LiteralPath $reparseLock -Force }
    }
    finally {
        if ($null -ne $lockHandle) { $lockHandle.Dispose() }
        if ($null -ne $lockChain) { Close-SafeDirectoryContainmentChain -Handles $lockChain }
        if ($lockAnchorMovedUnexpectedly -and (Test-Path -LiteralPath $lockAnchorMoved) -and -not (Test-Path -LiteralPath $lockAnchor)) {
            Move-Item -LiteralPath $lockAnchorMoved -Destination $lockAnchor
        }
    }

    Write-Host '[single-file path API ancestor no-follow]'
    $pathApiOutsideSource = Join-Path $work 'path-api-outside-source'
    $pathApiOutsideSentinel = New-PathSafetyFile -Path (Join-Path $pathApiOutsideSource 'sentinel.txt') -Content 'path api outside source sentinel'
    $pathApiSourceJunction = Join-Path $work 'path-api-source-junction'
    New-PathSafetyJunction -Path $pathApiSourceJunction -Target $pathApiOutsideSource | Out-Null
    $pathApiHashFailure = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    $pathApiStreamsFailure = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    $pathApiInspectFailure = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    $pathApiCopySourceFailure = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    $pathApiSourceCopyDestination = Join-Path $work 'path-api-approved-destination/from-source.txt'
    $pathApiOutsideHandle = [System.IO.File]::Open($pathApiOutsideSentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        foreach ($attempt in @(
            [pscustomobject]@{ Result=$pathApiInspectFailure; Action={ [AiAgentDotfiles.NoFollowFile]::Inspect((Join-Path $pathApiSourceJunction 'sentinel.txt')) | Out-Null } },
            [pscustomobject]@{ Result=$pathApiStreamsFailure; Action={ [AiAgentDotfiles.NoFollowFile]::GetNamedStreams((Join-Path $pathApiSourceJunction 'sentinel.txt')) | Out-Null } },
            [pscustomobject]@{ Result=$pathApiHashFailure; Action={ [AiAgentDotfiles.NoFollowFile]::HashRegularFile((Join-Path $pathApiSourceJunction 'sentinel.txt')) | Out-Null } },
            [pscustomobject]@{ Result=$pathApiCopySourceFailure; Action={ [AiAgentDotfiles.NoFollowFile]::CopyRegularFile((Join-Path $pathApiSourceJunction 'sentinel.txt'), $pathApiSourceCopyDestination) | Out-Null } }
        )) {
            try { & $attempt.Action }
            catch {
                $attempt.Result.Error = $_.Exception.Message
                $failure = $_.Exception
                while ($failure.InnerException) { $failure = $failure.InnerException }
                if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $attempt.Result.NativeErrorCode = $failure.NativeErrorCode }
            }
        }
    }
    finally { $pathApiOutsideHandle.Dispose() }
    $pathApiApprovedSource = New-PathSafetyFile -Path (Join-Path $work 'path-api-approved-source/value.txt') -Content 'approved path api source'
    $pathApiOutsideSecurityDirectory = Join-Path $pathApiOutsideSource 'security-directory'
    [System.IO.Directory]::CreateDirectory($pathApiOutsideSecurityDirectory) | Out-Null
    $pathApiSecurityFailure = $null
    try { [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot((Join-Path $pathApiSourceJunction 'security-directory')) | Out-Null }
    catch { $pathApiSecurityFailure = $_.Exception.Message }
    $pathApiOutsideDestination = Join-Path $work 'path-api-outside-destination'
    [System.IO.Directory]::CreateDirectory($pathApiOutsideDestination) | Out-Null
    $pathApiDestinationJunction = Join-Path $work 'path-api-destination-junction'
    New-PathSafetyJunction -Path $pathApiDestinationJunction -Target $pathApiOutsideDestination | Out-Null
    $pathApiDestinationFailure = $null
    try { [AiAgentDotfiles.NoFollowFile]::CopyRegularFile($pathApiApprovedSource, (Join-Path $pathApiDestinationJunction 'copied.txt')) | Out-Null }
    catch { $pathApiDestinationFailure = $_.Exception.Message }
    $pathApiOutsideCopy = Join-Path $pathApiOutsideDestination 'copied.txt'
    $pathApiOutsideCopyCreated = Test-Path -LiteralPath $pathApiOutsideCopy
    if ($pathApiOutsideCopyCreated) { Remove-Item -LiteralPath $pathApiOutsideCopy -Force }
    Write-Host ("  inspect-error={0}; inspect-native={1}; streams-error={2}; streams-native={3}; hash-error={4}; hash-native={5}; copy-source-error={6}; copy-source-native={7}; security-error={8}; destination-error={9}; outside-created={10}" -f
        $pathApiInspectFailure.Error, $pathApiInspectFailure.NativeErrorCode,
        $pathApiStreamsFailure.Error, $pathApiStreamsFailure.NativeErrorCode,
        $pathApiHashFailure.Error, $pathApiHashFailure.NativeErrorCode,
        $pathApiCopySourceFailure.Error, $pathApiCopySourceFailure.NativeErrorCode,
        $pathApiSecurityFailure, $pathApiDestinationFailure, $pathApiOutsideCopyCreated)
    Assert-TestCondition ($pathApiInspectFailure.Error -match 'reparse|containment|no-follow') 'path Inspect rejects a source ancestor junction without following it'
    Assert-TestCondition ($pathApiInspectFailure.NativeErrorCode -notin @(5, 32, 33)) 'path Inspect never reaches the locked outside sentinel'
    Assert-TestCondition ($pathApiStreamsFailure.Error -match 'reparse|containment|no-follow') 'path GetNamedStreams rejects a source ancestor junction without following it'
    Assert-TestCondition ($pathApiStreamsFailure.NativeErrorCode -notin @(5, 32, 33)) 'path GetNamedStreams never reaches the locked outside sentinel'
    Assert-TestCondition ($pathApiHashFailure.Error -match 'reparse|containment|no-follow') 'path HashRegularFile rejects a source ancestor junction without following it'
    Assert-TestCondition ($pathApiHashFailure.NativeErrorCode -notin @(5, 32, 33)) 'path HashRegularFile never reaches the locked outside sentinel'
    Assert-TestCondition ($pathApiCopySourceFailure.Error -match 'reparse|containment|no-follow') 'path CopyRegularFile rejects a source ancestor junction without following it'
    Assert-TestCondition ($pathApiCopySourceFailure.NativeErrorCode -notin @(5, 32, 33)) 'path CopyRegularFile never reaches the locked outside source sentinel'
    Assert-TestCondition (-not (Test-Path -LiteralPath $pathApiSourceCopyDestination)) 'path CopyRegularFile creates no destination after rejecting the source ancestor junction'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath $pathApiOutsideSentinel) -ceq 'path api outside source sentinel') 'single-file path APIs leave the outside source sentinel byte-identical'
    Assert-TestCondition ($pathApiSecurityFailure -match 'reparse|containment|no-follow') 'path GetDirectorySecuritySnapshot rejects an ancestor junction'
    Assert-TestCondition ($pathApiDestinationFailure -match 'reparse|containment|no-follow') 'path CopyRegularFile rejects a destination ancestor junction before create-new'
    Assert-TestCondition (-not $pathApiOutsideCopyCreated) 'path CopyRegularFile never creates a file through a destination ancestor junction'
    Remove-Item -LiteralPath $pathApiSourceJunction -Force
    Remove-Item -LiteralPath $pathApiDestinationJunction -Force

    Write-Host '[no-follow rejection]'
    $outside = Join-Path $work 'outside'
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    $outsideFile = New-PathSafetyFile -Path (Join-Path $outside 'sentinel.txt') -Content 'outside sentinel'
    $junction = Join-Path $source 'outside-link'
    New-PathSafetyJunction -Path $junction -Target $outside | Out-Null
    Assert-PathSafetyThrows -Script { Get-SafeTreeSnapshot -Root $source } -Pattern 'reparse' -Message 'junction is rejected without following its target'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath $outsideFile) -ceq 'outside sentinel') 'outside sentinel remains byte-identical'
    $marker = Get-NoFollowRootEntryMarker -Path $junction
    Assert-TestCondition ($marker.EntryType -eq 'ReparsePoint') 'unknown root-entry marker records a reparse entry without traversal'
    Remove-Item -LiteralPath $junction -Force

    Write-Host '[initial path no-follow]'
    $sourceEntryOutside = Join-Path $work 'source-entry-outside'
    $sourceEntrySentinel = New-PathSafetyFile -Path (Join-Path $sourceEntryOutside 'root/value.txt') -Content 'source entry outside sentinel'
    $sourceEntryJunction = Join-Path $work 'source-entry-junction'
    New-PathSafetyJunction -Path $sourceEntryJunction -Target $sourceEntryOutside | Out-Null
    $sourceEntryResult = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    $sourceEntryHandle = [System.IO.File]::Open($sourceEntrySentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        try { Get-SafeTreeSnapshot -Root (Join-Path $sourceEntryJunction 'root') | Out-Null }
        catch {
            $sourceEntryResult.Error = $_.Exception.Message
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $sourceEntryResult.NativeErrorCode = $failure.NativeErrorCode }
        }
    }
    finally { $sourceEntryHandle.Dispose() }
    Assert-TestCondition ($sourceEntryResult.Error -match 'reparse|containment|no-follow') 'source-root ancestor junction is rejected by entry metadata'
    Assert-TestCondition ($sourceEntryResult.NativeErrorCode -notin @(5, 32, 33)) 'source-root resolution never reaches the locked outside sentinel'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath $sourceEntrySentinel) -ceq 'source entry outside sentinel') 'source-root outside sentinel remains byte-identical'
    Remove-Item -LiteralPath $sourceEntryJunction -Force

    $markerOutside = Join-Path $work 'marker-outside'
    $markerSentinel = New-PathSafetyFile -Path (Join-Path $markerOutside 'sentinel.txt') -Content 'marker outside sentinel'
    $markerJunction = Join-Path $work 'marker-junction'
    New-PathSafetyJunction -Path $markerJunction -Target $markerOutside | Out-Null
    $markerEntry = $null
    $markerError = $null
    $markerHandle = [System.IO.File]::Open($markerSentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { try { $markerEntry = Get-NoFollowRootEntryMarker -Path $markerJunction } catch { $markerError = $_.Exception.Message } }
    finally { $markerHandle.Dispose() }
    Assert-TestCondition ($null -eq $markerError -and $markerEntry.EntryType -eq 'ReparsePoint') 'final marker inspects the junction entry without following its target'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath $markerSentinel) -ceq 'marker outside sentinel') 'marker outside sentinel remains byte-identical'
    Remove-Item -LiteralPath $markerJunction -Force

    $destinationEntrySource = Join-Path $work 'destination-entry-source'
    [System.IO.Directory]::CreateDirectory($destinationEntrySource) | Out-Null
    New-PathSafetyFile -Path (Join-Path $destinationEntrySource 'value.txt') -Content 'destination entry source' | Out-Null
    $destinationEntryOutside = Join-Path $work 'destination-entry-outside'
    $destinationEntrySentinel = New-PathSafetyFile -Path (Join-Path $destinationEntryOutside 'sentinel.txt') -Content 'destination entry outside sentinel'
    $destinationEntryJunction = Join-Path $work 'destination-entry-junction'
    New-PathSafetyJunction -Path $destinationEntryJunction -Target $destinationEntryOutside | Out-Null
    $destinationEntryResult = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    $destinationEntryHandle = [System.IO.File]::Open($destinationEntrySentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        try { Copy-SafeTree -SourceRoot $destinationEntrySource -DestinationRoot (Join-Path $destinationEntryJunction 'new/copy') | Out-Null }
        catch {
            $destinationEntryResult.Error = $_.Exception.Message
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $destinationEntryResult.NativeErrorCode = $failure.NativeErrorCode }
        }
    }
    finally { $destinationEntryHandle.Dispose() }
    Assert-TestCondition ($destinationEntryResult.Error -match 'reparse|containment|no-follow') 'destination ancestor junction is rejected before create-new'
    Assert-TestCondition ($destinationEntryResult.NativeErrorCode -notin @(5, 32, 33)) 'destination ancestor discovery never reaches the locked outside sentinel'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $destinationEntryOutside 'new/copy'))) 'destination ancestor discovery creates nothing outside'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath $destinationEntrySentinel) -ceq 'destination entry outside sentinel') 'destination outside sentinel remains byte-identical'
    Remove-Item -LiteralPath $destinationEntryJunction -Force

    Assert-TestCondition (${function:Get-SafeTreeSnapshotInternal}.Ast.Extent.Text -notmatch '\bResolve-Path\b|\bTest-Path\b') 'source-root first access is lexical plus handle-relative, never provider resolution'
    Assert-TestCondition (${function:Get-NoFollowRootEntryMarker}.Ast.Extent.Text -notmatch '\bResolve-Path\b|\bTest-Path\b|NoFollowFile\]::Inspect\(') 'final marker first access is parent-handle-relative'
    Assert-TestCondition (${function:Open-SafeExistingDirectoryContainmentChain}.Ast.Extent.Text -notmatch '\bResolve-Path\b|\bTest-Path\b') 'destination ancestor discovery uses handle existence and type'
    Assert-TestCondition (${function:Open-SafeDirectoryContainmentChain}.Ast.Extent.Text -match 'HoldPathChildDirectory' -and ${function:Open-SafeDirectoryContainmentChain}.Ast.Extent.Text -notmatch 'HoldDirectory\(\$component\)') 'containment components open relative to the held parent'

    Write-Host '[ancestor replacement containment]'
    $sourceRaceAnchor = Join-Path $work 'source-race-anchor'
    $sourceRaceAnchorOriginal = Join-Path $work 'source-race-anchor-original'
    $sourceRaceRoot = Join-Path $sourceRaceAnchor 'root'
    [System.IO.Directory]::CreateDirectory($sourceRaceRoot) | Out-Null
    New-PathSafetyFile -Path (Join-Path $sourceRaceRoot 'value.txt') -Content 'approved source bytes' | Out-Null
    $outsideReadRoot = Join-Path $work 'outside-read'
    [System.IO.Directory]::CreateDirectory($outsideReadRoot) | Out-Null
    $outsideReadSentinel = New-PathSafetyFile -Path (Join-Path $outsideReadRoot 'root/value.txt') -Content 'outside read sentinel'
    $sourceRace = [pscustomobject]@{ SwapAttempted=$false; SwapBlocked=$false; Error=$null; NativeErrorCode=$null }
    $outsideReadHandle = [System.IO.File]::Open($outsideReadSentinel, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try {
        try {
            Get-SafeTreeSnapshot -Root $sourceRaceRoot -ShouldSkipEntry {
                param($RelativePath)
                if (-not $sourceRace.SwapAttempted -and $RelativePath -ceq 'value.txt') {
                    $sourceRace.SwapAttempted = $true
                    try {
                        Move-Item -LiteralPath $sourceRaceAnchor -Destination $sourceRaceAnchorOriginal -ErrorAction Stop
                        New-PathSafetyJunction -Path $sourceRaceAnchor -Target $outsideReadRoot | Out-Null
                    }
                    catch {
                        $sourceRace.SwapBlocked = $true
                        if ((Test-Path -LiteralPath $sourceRaceAnchorOriginal) -and -not (Test-Path -LiteralPath $sourceRaceAnchor)) {
                            Move-Item -LiteralPath $sourceRaceAnchorOriginal -Destination $sourceRaceAnchor
                        }
                    }
                }
                return $false
            } | Out-Null
        }
        catch {
            $sourceRace.Error = $_.Exception.Message
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $sourceRace.NativeErrorCode = $failure.NativeErrorCode }
        }
    }
    finally { $outsideReadHandle.Dispose() }
    if ((Get-NoFollowRootEntryMarker -Path $sourceRaceAnchor).EntryType -eq 'ReparsePoint') {
        Remove-Item -LiteralPath $sourceRaceAnchor -Force
    }
    if (Test-Path -LiteralPath $sourceRaceAnchorOriginal) {
        Move-Item -LiteralPath $sourceRaceAnchorOriginal -Destination $sourceRaceAnchor
    }

    $destinationRaceSource = Join-Path $work 'destination-race-source'
    [System.IO.Directory]::CreateDirectory($destinationRaceSource) | Out-Null
    New-PathSafetyFile -Path (Join-Path $destinationRaceSource 'payload.txt') -Content 'destination race payload' | Out-Null
    $destinationAnchor = Join-Path $work 'destination-anchor'
    $destinationAnchorOriginal = Join-Path $work 'destination-anchor-original'
    $outsideWriteRoot = Join-Path $work 'outside-write'
    [System.IO.Directory]::CreateDirectory($destinationAnchor) | Out-Null
    [System.IO.Directory]::CreateDirectory($outsideWriteRoot) | Out-Null
    $destinationRace = [pscustomobject]@{ SwapAttempted=$false; SwapBlocked=$false; Error=$null }
    try {
        Copy-SafeTree -SourceRoot $destinationRaceSource -DestinationRoot (Join-Path $destinationAnchor 'copy') -ShouldSkipEntry {
            param($RelativePath)
            if (-not $destinationRace.SwapAttempted -and $RelativePath -ceq 'payload.txt') {
                $destinationRace.SwapAttempted = $true
                try {
                    Move-Item -LiteralPath $destinationAnchor -Destination $destinationAnchorOriginal -ErrorAction Stop
                    New-PathSafetyJunction -Path $destinationAnchor -Target $outsideWriteRoot | Out-Null
                }
                catch {
                    $destinationRace.SwapBlocked = $true
                    if ((Test-Path -LiteralPath $destinationAnchorOriginal) -and -not (Test-Path -LiteralPath $destinationAnchor)) {
                        Move-Item -LiteralPath $destinationAnchorOriginal -Destination $destinationAnchor
                    }
                }
            }
            return $false
        } | Out-Null
    }
    catch { $destinationRace.Error = $_.Exception.Message }
    if ((Get-NoFollowRootEntryMarker -Path $destinationAnchor).EntryType -eq 'ReparsePoint') {
        Remove-Item -LiteralPath $destinationAnchor -Force
    }
    if (Test-Path -LiteralPath $destinationAnchorOriginal) {
        Move-Item -LiteralPath $destinationAnchorOriginal -Destination $destinationAnchor
    }

    Write-Host ("  source swap blocked={0}; native-error={1}; error={2}" -f $sourceRace.SwapBlocked, $sourceRace.NativeErrorCode, $sourceRace.Error)
    Write-Host ("  destination swap blocked={0}; error={1}" -f $destinationRace.SwapBlocked, $destinationRace.Error)
    Assert-TestCondition ($sourceRace.SwapAttempted) 'source ancestor replacement fixture reached the deterministic race point'
    Assert-TestCondition ($sourceRace.SwapBlocked -or ($sourceRace.Error -match 'containment|ancestor identity|directory changed during traversal') -or ($sourceRace.NativeErrorCode -eq 3)) 'source ancestor replacement is blocked before the outside read sentinel is opened'
    Assert-TestCondition ($sourceRace.NativeErrorCode -notin @(5, 32, 33)) 'source ancestor replacement never reaches the denied-read outside sentinel'
    Assert-TestCondition ((Get-Content -Raw -LiteralPath $outsideReadSentinel) -ceq 'outside read sentinel') 'outside read sentinel remains byte-identical'
    Assert-TestCondition ($destinationRace.SwapAttempted) 'destination ancestor replacement fixture reached the deterministic race point'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $outsideWriteRoot 'copy/payload.txt'))) 'destination ancestor replacement never writes outside the approved destination root'
    Assert-TestCondition ($destinationRace.SwapBlocked -or ($destinationRace.Error -match 'containment|ancestor|reparse|changed during traversal')) 'destination ancestor replacement is blocked or rejected fail-closed'

    Write-Host '[snapshot-to-copy source lifetime]'
    $copyWindowSource = Join-Path $work 'copy-window-source'
    $copyWindowPayload = Join-Path $copyWindowSource 'payload'
    $copyWindowOriginal = Join-Path $work 'copy-window-payload-original'
    $copyWindowReplacement = Join-Path $work 'copy-window-replacement'
    $copyWindowDestination = Join-Path $work 'copy-window-destination'
    [System.IO.Directory]::CreateDirectory((Join-Path $copyWindowSource '000-trigger')) | Out-Null
    [System.IO.Directory]::CreateDirectory($copyWindowPayload) | Out-Null
    New-PathSafetyFile -Path (Join-Path $copyWindowPayload 'value.txt') -Content 'approved copy-window bytes' | Out-Null
    New-PathSafetyFile -Path (Join-Path $copyWindowReplacement 'value.txt') -Content 'outside replacement sentinel' | Out-Null
    foreach ($index in 0..399) {
        [System.IO.Directory]::CreateDirectory((Join-Path $copyWindowSource ("delay-{0:D4}" -f $index))) | Out-Null
    }
    $raceControl = Join-Path $work 'copy-window-control'
    [System.IO.Directory]::CreateDirectory($raceControl) | Out-Null
    $raceReady = Join-Path $raceControl 'ready'
    $raceAttempted = Join-Path $raceControl 'attempted'
    $raceSwapped = Join-Path $raceControl 'swapped'
    $raceRelease = Join-Path $raceControl 'release'
    $raceError = Join-Path $raceControl 'error.txt'
    $raceHost = Join-Path $PSScriptRoot 'helpers/safe-tree-regular-replacement-host.ps1'
    $raceStart = [System.Diagnostics.ProcessStartInfo]::new()
    $raceStart.FileName = (Get-Command pwsh).Source
    $raceStart.UseShellExecute = $false
    foreach ($argument in @(
        '-NoProfile','-File',$raceHost,
        '-TriggerPath',(Join-Path $copyWindowDestination '000-trigger'),
        '-SourcePath',$copyWindowPayload,'-OriginalPath',$copyWindowOriginal,'-ReplacementPath',$copyWindowReplacement,
        '-SentinelRelativePath','value.txt','-ReadyPath',$raceReady,'-AttemptedPath',$raceAttempted,
        '-SwappedPath',$raceSwapped,'-ReleasePath',$raceRelease,'-ErrorPath',$raceError
    )) { $raceStart.ArgumentList.Add($argument) }
    $raceProcess = [System.Diagnostics.Process]::Start($raceStart)
    $readyClock = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Test-Path -LiteralPath $raceReady)) {
        if ($raceProcess.HasExited) { throw 'Regular-directory replacement host exited before becoming ready.' }
        if ($readyClock.ElapsedMilliseconds -ge 10000) { throw 'Timed out waiting for the regular-directory replacement host.' }
        Start-Sleep -Milliseconds 5
    }
    $copyWindowFailure = [pscustomobject]@{ Error=$null; NativeErrorCode=$null }
    try {
        try { Copy-SafeTree -SourceRoot $copyWindowSource -DestinationRoot $copyWindowDestination | Out-Null }
        catch {
            $copyWindowFailure.Error = $_.Exception.Message
            $failure = $_.Exception
            while ($failure.InnerException) { $failure = $failure.InnerException }
            if ($failure.PSObject.Properties.Name -contains 'NativeErrorCode') { $copyWindowFailure.NativeErrorCode = $failure.NativeErrorCode }
        }
    }
    finally {
        [System.IO.File]::WriteAllText($raceRelease, 'release', [System.Text.UTF8Encoding]::new($false))
        if (-not $raceProcess.WaitForExit(10000)) { $raceProcess.Kill($true); throw 'Regular-directory replacement host did not exit.' }
        $raceProcess.Dispose()
    }
    $copyWindowAttempted = Test-Path -LiteralPath $raceAttempted
    $copyWindowSwapped = Test-Path -LiteralPath $raceSwapped
    $copyWindowBlocked = (Test-Path -LiteralPath $raceError) -and -not $copyWindowSwapped
    Write-Host ("  regular source replacement attempted={0}; swapped={1}; blocked={2}; native-error={3}; error={4}" -f $copyWindowAttempted, $copyWindowSwapped, $copyWindowBlocked, $copyWindowFailure.NativeErrorCode, $copyWindowFailure.Error)
    if ($copyWindowSwapped) {
        if (Test-Path -LiteralPath $copyWindowPayload) { Remove-Item -LiteralPath $copyWindowPayload -Recurse -Force }
        if (Test-Path -LiteralPath $copyWindowOriginal) { Move-Item -LiteralPath $copyWindowOriginal -Destination $copyWindowPayload }
    }
    Assert-TestCondition $copyWindowAttempted 'regular-directory replacement fixture reached the snapshot-to-copy gap'
    Assert-TestCondition (-not $copyWindowSwapped -and $copyWindowBlocked) 'source directory identity remains held from snapshot through copy'
    Assert-TestCondition ($copyWindowFailure.NativeErrorCode -notin @(5, 32, 33)) 'snapshot-to-copy replacement never reaches the denied-read sentinel'

    $hardTarget = Join-Path $source 'root.txt'
    $hardlink = Join-Path $source 'hardlink.txt'
    New-PathSafetyHardLink -Path $hardlink -Target $hardTarget | Out-Null
    Assert-PathSafetyThrows -Script { Get-SafeTreeSnapshot -Root $source } -Pattern 'hard link|multiple' -Message 'multi-link file identity is rejected'
    Remove-Item -LiteralPath $hardlink -Force

    Add-PathSafetyNamedStream -Path $hardTarget
    Assert-PathSafetyThrows -Script { Get-SafeTreeSnapshot -Root $source } -Pattern 'stream' -Message 'named alternate data stream is rejected'
    Remove-Item -LiteralPath $hardTarget -Stream 'safety-sentinel'

    $locked = Join-Path $source 'locked.txt'
    New-PathSafetyFile -Path $locked -Content 'locked' | Out-Null
    $handle = [System.IO.File]::Open($locked, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    try { Assert-PathSafetyThrows -Script { Get-SafeTreeSnapshot -Root $source } -Pattern 'open|used by another process|access' -Message 'permission/share failure fails closed' }
    finally { $handle.Dispose(); Remove-Item -LiteralPath $locked -Force }

    Write-Host 'safe tree walker tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
