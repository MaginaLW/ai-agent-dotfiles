#requires -Version 7.0

Set-StrictMode -Version Latest

$script:JsonArtifactRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'semantic-json.ps1')
. (Join-Path $PSScriptRoot 'scan-input-common.ps1')

$script:PinnedToolValidationCache = @{}

function Get-PinnedToolLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $full = (Resolve-Path -LiteralPath $Path).Path
    $lock = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($full, [System.Text.UTF8Encoding]::new($false, $true)))
    foreach ($field in @('SchemaVersion', 'ToolKind', 'Version', 'AssetName', 'AssetUrl', 'ReleaseUrl', 'AssetSha256', 'ExecutableName', 'VersionArguments', 'ExpectedVersionPattern', 'LicenseIdentifier', 'LicenseUrl')) {
        if (-not $lock.Contains($field)) { throw "Pinned tool lock is missing $field`: $full" }
    }
    if ([long] $lock.SchemaVersion -ne 1) { throw "Unsupported pinned tool lock version: $($lock.SchemaVersion)" }
    if ([string] $lock.AssetSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Pinned tool asset SHA-256 must be lowercase hexadecimal.' }
    if ([string] $lock.AssetUrl -notmatch '^https://github\.com/[^/]+/[^/]+/releases/download/') { throw 'Pinned tool asset URL must be an official GitHub release asset URL.' }
    if ([System.IO.Path]::GetFileName([string] $lock.AssetUrl) -cne [string] $lock.AssetName) { throw 'Pinned tool asset name does not match its URL.' }
    return $lock
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

function Test-PinnedToolVersion {
    param([Parameter(Mandatory)] [string] $ExecutablePath, [Parameter(Mandatory)] [System.Collections.IDictionary] $Lock)

    $output = (& $ExecutablePath @($Lock.VersionArguments) 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "Pinned $($Lock.ToolKind) version probe failed with exit code $LASTEXITCODE`: $output" }
    if ($output -notmatch [string] $Lock.ExpectedVersionPattern) { throw "Pinned $($Lock.ToolKind) version output did not match the lock: $output" }
    return $output
}

function Assert-PinnedToolInstalled {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $LockPath, [string] $CacheRoot)

    $lock = Get-PinnedToolLock -Path $LockPath
    $paths = Get-PinnedToolPaths -Lock $lock -CacheRoot $CacheRoot
    foreach ($path in @($paths.Archive, $paths.Executable)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Pinned $($lock.ToolKind) is not installed: $path" }
    }
    $cacheKey = "$($paths.Root)|$((Get-Item -LiteralPath $paths.Archive).LastWriteTimeUtc.Ticks)|$((Get-Item -LiteralPath $paths.Executable).LastWriteTimeUtc.Ticks)"
    if ($script:PinnedToolValidationCache.ContainsKey($cacheKey)) { return $script:PinnedToolValidationCache[$cacheKey] }

    $archiveHash = (Get-FileHash -LiteralPath $paths.Archive -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($archiveHash -cne [string] $lock.AssetSha256) { throw "Pinned $($lock.ToolKind) archive hash mismatch." }
    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-tool-verify-$([Guid]::NewGuid().ToString('N'))"
    try {
        Expand-Archive -LiteralPath $paths.Archive -DestinationPath $probe
        $matches = @(Get-ChildItem -LiteralPath $probe -File -Recurse -Filter ([string] $lock.ExecutableName))
        if ($matches.Count -ne 1) { throw "Pinned archive must contain exactly one $($lock.ExecutableName)." }
        $archiveExeHash = (Get-FileHash -LiteralPath $matches[0].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $installedExeHash = (Get-FileHash -LiteralPath $paths.Executable -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($archiveExeHash -cne $installedExeHash) { throw "Pinned $($lock.ToolKind) executable differs from its verified archive." }
        $versionOutput = Test-PinnedToolVersion -ExecutablePath $paths.Executable -Lock $lock
        $result = [pscustomobject]@{ Lock = $lock; Paths = $paths; ExecutableSha256 = $installedExeHash; VersionOutput = $versionOutput }
        $script:PinnedToolValidationCache[$cacheKey] = $result
        return $result
    }
    finally {
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force }
    }
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
        $null = Test-PinnedToolVersion -ExecutablePath (Join-Path $bin ([string] $lock.ExecutableName)) -Lock $lock
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

function Test-RepositoryJsonSchema {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SchemaPath, [Parameter(Mandatory)] [string] $SchemaRoot)

    $root = (Resolve-Path -LiteralPath $SchemaRoot).Path
    $evidence = Resolve-PrivateArtifactPath -Path $SchemaPath -Role EvidenceInputPath -RepoRoot $script:JsonArtifactRepoRoot -EvidenceRoots @($root)
    $json = [System.IO.File]::ReadAllText($evidence.FullPath, [System.Text.UTF8Encoding]::new($false, $true))
    $after = [AiAgentDotfiles.NoFollowFile]::Inspect($evidence.FullPath)
    if ($after.Identity -cne $evidence.Identity -or $after.Length -ne $evidence.Length) { throw 'Schema identity changed while reading.' }
    $schema = ConvertFrom-SemanticJson -Json $json
    if ($schema -isnot [System.Collections.IDictionary]) { throw 'Repository schema root must be an object.' }
    $dialect = 'https://json-schema.org/draft/2020-12/schema'
    if (-not $schema.Contains('$schema') -or [string] $schema['$schema'] -cne $dialect) { throw "Repository schema must use the exact Draft 2020-12 dialect: $dialect" }
    $expectedId = "https://ai-agent-dotfiles.invalid/schemas/$([System.IO.Path]::GetFileName($evidence.FullPath))"
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
    return [pscustomobject]@{ SchemaPath = $evidence.FullPath; SchemaId = $expectedId; SchemaHash = Get-SemanticJsonHash -InputObject $schema; Identity = $evidence.Identity }
}

function Invoke-FixedJsonSchemaValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $SchemaPath,
        [Parameter(Mandatory)] [string] $InstancePath,
        [string] $ValidatorCacheRoot
    )

    $null = Test-RepositoryJsonSchema -SchemaPath $SchemaPath -SchemaRoot (Split-Path -Parent $SchemaPath)
    $instanceRoot = Split-Path -Parent ([System.IO.Path]::GetFullPath($InstancePath))
    $instance = Resolve-PrivateArtifactPath -Path $InstancePath -Role EvidenceInputPath -RepoRoot $script:JsonArtifactRepoRoot -EvidenceRoots @($instanceRoot)
    $tool = Assert-PinnedToolInstalled -LockPath (Join-Path $script:JsonArtifactRepoRoot 'tools/schema-validator/validator.lock.json') -CacheRoot $ValidatorCacheRoot
    $output = (& $tool.Paths.Executable validate $SchemaPath $instance.FullPath 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0) { throw "JSON Schema validation failed with exit code $LASTEXITCODE`: $output" }
    return [pscustomobject]@{ Result = 'PASS'; SchemaPath = $SchemaPath; InstancePath = $instance.FullPath; Output = $output }
}
