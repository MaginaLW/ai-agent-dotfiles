#requires -Version 7.0
# Pinned tool helpers: install a tool from the official release asset named in a
# lock file (tools/<tool>/<tool>.lock.json) and hand out its executable only after
# the archive and executable SHA-256 hashes match the lock.
# The cache is <LocalAppData>\ai-agent-dotfiles.tool-cache\<ToolKind>\<Version>.

Set-StrictMode -Version Latest

function Read-PinnedToolLockFile {
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot)

    $full = (Resolve-Path -LiteralPath $LockPath).Path
    $lock = Get-Content -LiteralPath $full -Raw | ConvertFrom-Json -AsHashtable
    foreach ($field in @('SchemaVersion', 'ToolKind', 'Version', 'AssetName', 'AssetUrl', 'AssetSha256', 'ExecutableName', 'ExecutableSha256', 'VersionArguments', 'ExpectedVersionPattern')) {
        if (-not $lock.ContainsKey($field)) { throw "Pinned tool lock is missing $field`: $full" }
    }
    if ([long] $lock.SchemaVersion -ne 1) { throw "Unsupported pinned tool lock version: $($lock.SchemaVersion)" }
    foreach ($field in @('AssetSha256', 'ExecutableSha256')) {
        if ([string] $lock[$field] -cnotmatch '^[0-9a-f]{64}$') { throw "Pinned tool $field must be lowercase hexadecimal." }
    }
    if ([string] $lock.AssetUrl -notmatch '^https://github\.com/[^/]+/[^/]+/releases/download/') { throw 'Pinned tool asset URL must be an official GitHub release asset URL.' }
    if ([System.IO.Path]::GetFileName([string] $lock.AssetUrl) -cne [string] $lock.AssetName) { throw 'Pinned tool asset name does not match its URL.' }

    if (-not $CacheRoot) {
        $local = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
        if ([string]::IsNullOrWhiteSpace($local)) { throw 'The OS LocalApplicationData known folder is unavailable.' }
        $CacheRoot = Join-Path $local 'ai-agent-dotfiles.tool-cache'
    }
    $root = Join-Path ([System.IO.Path]::GetFullPath($CacheRoot)) (Join-Path ([string] $lock.ToolKind) ([string] $lock.Version))
    return [pscustomobject]@{
        Lock = $lock
        Root = $root
        Archive = Join-Path $root ([string] $lock.AssetName)
        Executable = Join-Path $root (Join-Path 'bin' ([string] $lock.ExecutableName))
    }
}

function Get-PinnedToolFileSha256 {
    param([Parameter(Mandatory)] [string] $Path)
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item -or $item.PSIsContainer) { return $null }
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Pinned tool file is a reparse point: $Path" }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-PinnedToolExecutable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot)

    $tool = Read-PinnedToolLockFile -LockPath $LockPath -CacheRoot $CacheRoot
    $lock = $tool.Lock
    $archiveHash = Get-PinnedToolFileSha256 -Path $tool.Archive
    if ($null -eq $archiveHash) { throw "Pinned $($lock.ToolKind) is not installed: $($tool.Archive)" }
    if ($archiveHash -cne [string] $lock.AssetSha256) { throw "Pinned $($lock.ToolKind) archive hash mismatch." }
    $executableHash = Get-PinnedToolFileSha256 -Path $tool.Executable
    if ($null -eq $executableHash) { throw "Pinned $($lock.ToolKind) is not installed: $($tool.Executable)" }
    if ($executableHash -cne [string] $lock.ExecutableSha256) { throw "Pinned $($lock.ToolKind) executable hash mismatch." }

    $versionArguments = [string[]] @($lock.VersionArguments | ForEach-Object { [string] $_ })
    $versionOutput = ((& $tool.Executable @versionArguments 2>&1 | ForEach-Object { [string] $_ }) -join "`n").Trim()
    if ($LASTEXITCODE -ne 0) { throw "Pinned $($lock.ToolKind) version probe failed with exit code $LASTEXITCODE`: $versionOutput" }
    if ($versionOutput -notmatch [string] $lock.ExpectedVersionPattern) { throw "Pinned $($lock.ToolKind) version output did not match the lock: $versionOutput" }
    return [pscustomobject]@{ Executable = $tool.Executable; ExecutableSha256 = $executableHash; VersionOutput = $versionOutput; Lock = $lock }
}

function Install-PinnedTool {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot, [switch] $VerifyOnly)

    $tool = Read-PinnedToolLockFile -LockPath $LockPath -CacheRoot $CacheRoot
    $lock = $tool.Lock
    if ($VerifyOnly -or (Test-Path -LiteralPath $tool.Root)) { return Get-PinnedToolExecutable -LockPath $LockPath -CacheRoot $CacheRoot }

    # Build the install in a sibling candidate directory, then move it into place.
    $parent = Split-Path -Parent $tool.Root
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $candidate = Join-Path $parent ".install-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
    try {
        $archive = Join-Path $candidate ([string] $lock.AssetName)
        Invoke-WebRequest -UseBasicParsing -Uri ([string] $lock.AssetUrl) -OutFile $archive
        if ((Get-PinnedToolFileSha256 -Path $archive) -cne [string] $lock.AssetSha256) { throw "Downloaded $($lock.ToolKind) archive hash mismatch." }
        $expanded = Join-Path $candidate 'expanded'
        Expand-Archive -LiteralPath $archive -DestinationPath $expanded
        $found = @(Get-ChildItem -LiteralPath $expanded -File -Recurse -Filter ([string] $lock.ExecutableName))
        if ($found.Count -ne 1) { throw "Pinned archive must contain exactly one $($lock.ExecutableName)." }
        $bin = Join-Path $candidate 'bin'
        [System.IO.Directory]::CreateDirectory($bin) | Out-Null
        $candidateExecutable = Join-Path $bin ([string] $lock.ExecutableName)
        Copy-Item -LiteralPath $found[0].FullName -Destination $candidateExecutable
        Remove-Item -LiteralPath $expanded -Recurse -Force
        if ((Get-PinnedToolFileSha256 -Path $candidateExecutable) -cne [string] $lock.ExecutableSha256) { throw "Pinned $($lock.ToolKind) executable hash mismatch." }
        try { [System.IO.Directory]::Move($candidate, $tool.Root) }
        catch { if (-not (Test-Path -LiteralPath $tool.Root -PathType Container)) { throw } }
        return Get-PinnedToolExecutable -LockPath $LockPath -CacheRoot $CacheRoot
    }
    finally {
        if (Test-Path -LiteralPath $candidate) { Remove-Item -LiteralPath $candidate -Recurse -Force }
    }
}
