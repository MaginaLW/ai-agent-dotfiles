#requires -Version 7.0

Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'safe-tree-walker.ps1')

function Test-TargetPathOverlap {
    param([string] $Left, [string] $Right)
    return (Test-SafePathInsideRoot -Path $Left -Root $Right) -or (Test-SafePathInsideRoot -Path $Right -Root $Left)
}

function Assert-SupportedTargetFilesystem {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $DriveType, [Parameter(Mandatory)] [string] $FileSystemType)
    if ($DriveType -cne 'Fixed' -or $FileSystemType -cne 'NTFS') { throw "unsupported target filesystem: $DriveType/$FileSystemType" }
}

function Get-TargetMetadataContext {
    param([Parameter(Mandatory)] [string] $Path)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92, [char]47)
    $root = [System.IO.Path]::GetPathRoot($full).TrimEnd([char]92, [char]47) + [System.IO.Path]::DirectorySeparatorChar
    $rootTrimmed = $root.TrimEnd([char]92, [char]47)
    if ($full.Equals($rootTrimmed, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'volume root cannot be a target' }
    $relative = [System.IO.Path]::GetRelativePath($root, $full)
    $segments = @($relative -split '[\\/]' | Where-Object { $_ })
    if (@($segments | Where-Object { $_ -ieq '.system' }).Count -gt 0) { throw '.system cannot be a managed target' }
    $ancestors = [System.Collections.Generic.List[object]]::new()
    $current = $root
    $rootInfo = [AiAgentDotfiles.NoFollowFile]::Inspect($root)
    if (-not $rootInfo.IsDirectory -or $rootInfo.IsReparsePoint) { throw 'volume root identity is invalid' }
    $ancestors.Add([ordered]@{ Path=$root; Identity=[string]$rootInfo.Identity; Type='Directory'; ReparsePoint=$false })
    $deepest = $root
    $missingRemainder = [System.Collections.Generic.List[string]]::new()
    $missing = $false
    foreach ($segment in $segments) {
        if ($missing) { $missingRemainder.Add($segment); continue }
        $candidate = Join-Path $current $segment
        if (-not (Test-Path -LiteralPath $candidate)) { $missing=$true; $missingRemainder.Add($segment); continue }
        $info = [AiAgentDotfiles.NoFollowFile]::Inspect($candidate)
        if ($info.IsReparsePoint) { throw "target path contains a reparse ancestor: $candidate" }
        $type = if ($info.IsDirectory) { 'Directory' } else { 'File' }
        $ancestors.Add([ordered]@{ Path=[System.IO.Path]::GetFullPath($candidate); Identity=[string]$info.Identity; Type=$type; ReparsePoint=$false })
        $current = $candidate; $deepest = $candidate
        if (-not $info.IsDirectory -and $segment -cne $segments[-1]) { throw "target path descends through a file: $candidate" }
    }
    $targetStatus = if ($missing) { 'MISSING' } else { 'EXISTS' }
    $targetType = if ($missing) { 'MISSING' } else { [string]$ancestors[-1].Type }
    $intent = [ordered]@{
        LocationKey = $full.ToLowerInvariant().Replace([char]92,[char]47)
        RequestedPath = $full
        TargetStatus = $targetStatus
        TargetType = $targetType
        VolumeId = ([string]$rootInfo.Identity -split ':')[0]
        DeepestExistingParentPath = [System.IO.Path]::GetFullPath($deepest)
        DeepestExistingParentIdentity = [string]$ancestors[-1].Identity
        MissingRemainder = @($missingRemainder)
        Ancestors = @($ancestors)
    }
    return $intent
}

function Invoke-TargetFilesystemCapabilityProbe {
    param([Parameter(Mandatory)] [string] $ProbeRoot, [Parameter(Mandatory)] $VolumeInfo)
    $probeRootFull = (Resolve-Path -LiteralPath $ProbeRoot).Path
    $probeVolume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($probeRootFull)
    if ($probeVolume.VolumeSerial -cne $VolumeInfo.VolumeSerial) { throw 'capability probe must be on the target volume' }
    Assert-SupportedTargetFilesystem -DriveType $VolumeInfo.DriveType -FileSystemType $VolumeInfo.FileSystemType
    $slot = Join-Path $probeRootFull ".target-capability-$([Guid]::NewGuid().ToString('N'))"
    try {
        [System.IO.Directory]::CreateDirectory($slot) | Out-Null
        $oldDir = Join-Path $slot 'directory-old'; $newDir = Join-Path $slot 'directory-new'
        [System.IO.Directory]::CreateDirectory($oldDir) | Out-Null
        [System.IO.Directory]::Move($oldDir, $newDir)
        $destination = Join-Path $slot 'replace-target.txt'; $replacement = Join-Path $slot 'replace-source.txt'; $backup = Join-Path $slot 'replace-backup.txt'
        [System.IO.File]::WriteAllText($destination, 'old', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::WriteAllText($replacement, 'new', [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Replace($replacement, $destination, $backup, $true)
        if ([System.IO.File]::ReadAllText($destination) -cne 'new' -or [System.IO.File]::ReadAllText($backup) -cne 'old') { throw 'atomic replace probe postcondition failed' }
    }
    finally {
        if (Test-Path -LiteralPath $slot) {
            if (-not (Test-SafePathInsideRoot -Path $slot -Root $probeRootFull) -or [System.IO.Path]::GetFileName($slot) -notlike '.target-capability-*') { throw 'unsafe capability cleanup target' }
            Remove-Item -LiteralPath $slot -Recurse -Force
        }
    }
    return Get-SemanticJsonHash -InputObject ([ordered]@{ ProtocolVersion=1; DriveType=[string]$VolumeInfo.DriveType; FileSystemType=[string]$VolumeInfo.FileSystemType; VolumeSerial=[string]$VolumeInfo.VolumeSerial; DirectoryRename=$true; AtomicReplace=$true })
}

function Resolve-TargetContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('MetadataOnly','MutationPreflight')] [string] $Mode,
        [string] $HomeRoot,
        [string[]] $ForbiddenRoots = @(),
        [string] $ProbeRoot
    )
    if ($Path.StartsWith('\\', [System.StringComparison]::Ordinal)) { throw 'network/UNC target is unsupported' }
    $metadata = Get-TargetMetadataContext -Path $Path
    if ($HomeRoot) {
        $homeFull = [System.IO.Path]::GetFullPath($HomeRoot).TrimEnd([char]92,[char]47)
        if ($metadata.RequestedPath.Equals($homeFull, [System.StringComparison]::OrdinalIgnoreCase)) { throw 'HomeRoot itself cannot be a target' }
    }
    foreach ($root in @($ForbiddenRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
        $overlaps = Test-TargetPathOverlap -Left $metadata.RequestedPath -Right ([System.IO.Path]::GetFullPath($root))
        if ($overlaps) { throw "target overlap with forbidden root: $root" }
    }
    $intentHash = Get-SemanticJsonHash -InputObject $metadata
    $result = [ordered]@{}
    foreach ($key in $metadata.Keys) { $result[$key]=$metadata[$key] }
    $result.RequestedInitialRootContextHash = $intentHash
    if ($Mode -eq 'MetadataOnly') {
        $result.FilesystemCapabilityStatus='UNPROBED'; $result.FilesystemCapabilityHash=$null
        return [pscustomobject]$result
    }
    if ([string]::IsNullOrWhiteSpace($ProbeRoot)) { throw 'MutationPreflight requires an approved ProbeRoot' }
    $volume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($metadata.DeepestExistingParentPath)
    $result.FilesystemCapabilityStatus='SUPPORTED'
    $result.FilesystemCapabilityHash=Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $ProbeRoot -VolumeInfo $volume
    $result.DriveType=[string]$volume.DriveType; $result.FileSystemType=[string]$volume.FileSystemType; $result.VolumeSerial=[string]$volume.VolumeSerial
    return [pscustomobject]$result
}
