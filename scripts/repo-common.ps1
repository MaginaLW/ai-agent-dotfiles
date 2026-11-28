#requires -Version 7.0
<#
.SYNOPSIS
    Shared repository scan-policy helpers. Dot-source only.

.DESCRIPTION
    The single definition of the policy literals several scripts and gates share: the
    generated skill roots, scan-input prefixes,
    porcelain status pathspecs, binary-extension list, Codex live-root rule and the
    drive-letter/UNC machine-private path patterns. Change these only with the owner's
    approval; every consumer fails closed around them. Keep exactly one definition of each
    helper in the repository: the syntax gate's unknown-parameter pass skips names defined
    in more than one script.
#>

Set-StrictMode -Version Latest

function Get-PorcelainStatusPaths {
    # git status pathspecs covering the whole tree.
    return , @('.')
}

# Generated output roots and the filtered input prefixes shared by the build/scan gates.
$script:GeneratedSkillRoots = @('codex/skills')
$script:GeneratedSkillRootPrefixes = @($script:GeneratedSkillRoots | ForEach-Object { "$_/" })
$script:ScanExcludedPrefixes = @('.git/') + $script:GeneratedSkillRootPrefixes + @('tmp/')

function Get-GeneratedSkillRoots {
    # Repository-relative generated roots, without trailing separators.
    return $script:GeneratedSkillRoots
}

function Get-ScanExcludedPrefixes {
    # Secret-scan and syntax-gate input prefixes, including the Git and temporary roots.
    return $script:ScanExcludedPrefixes
}

function Get-CodexLiveSkillRoots {
    # Returns both Codex candidates and the selected root. When both exist the callers
    # decide whether to refuse (deploy) or warn (doctor); neither may guess.
    param([Parameter(Mandatory)] [string] $HomeRoot)
    $preferred = Join-Path $HomeRoot '.codex\skills'
    $fallback = Join-Path $HomeRoot '.agents\skills'
    $preferredExists = Test-Path -LiteralPath $preferred
    $fallbackExists = Test-Path -LiteralPath $fallback
    $ambiguous = $preferredExists -and $fallbackExists
    $selected = if ($ambiguous) { $null } elseif ($fallbackExists) { $fallback } else { $preferred }
    return [pscustomobject] @{
        Preferred = $preferred
        Fallback = $fallback
        PreferredExists = $preferredExists
        FallbackExists = $fallbackExists
        Ambiguous = $ambiguous
        Selected = $selected
    }
}

function Test-DeploySkillName($Name) {
    return $Name -is [string] -and $Name -match '^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?\z'
}

# Missing state owns no directories. An invalid record has null Ownership and cannot drive deployment.
function Get-DeploySkillsStateRecord {
    param([Parameter(Mandatory)] [string] $StateRoot)

    $statePath = Join-Path $StateRoot 'deployed-skills.json'
    $record = [pscustomobject]@{
        StatePath           = $statePath
        Reason              = $null
        RecordedEnvironment = $null
        Ownership           = $null
    }
    try {
        if (Test-Path -LiteralPath $StateRoot -PathType Leaf -ErrorAction Stop) {
            $record.Reason = 'state-root-not-directory'
            return $record
        }
        if (Test-Path -LiteralPath $statePath -PathType Container -ErrorAction Stop) {
            $record.Reason = 'state-path-is-directory'
            return $record
        }
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf -ErrorAction Stop)) {
            $record.Reason = 'missing-state'
            $record.Ownership = @{ Codex = @() }
            return $record
        }
        $stateText = Get-Content -Raw -LiteralPath $statePath -ErrorAction Stop
    }
    catch {
        $record.Reason = 'read-error'
        return $record
    }
    try {
        $state = ConvertFrom-Json -InputObject $stateText -AsHashtable -NoEnumerate -ErrorAction Stop
    }
    catch {
        $record.Reason = 'invalid-json'
        return $record
    }
    if ($state -isnot [System.Collections.IDictionary] -or $state['Codex'] -isnot [array]) {
        $record.Reason = 'invalid-state'
        return $record
    }
    foreach ($name in $state['Codex']) {
        if (-not (Test-DeploySkillName $name)) {
            $record.Reason = 'invalid-state'
            return $record
        }
    }
    $environment = $state['Environment']
    if ($null -eq $environment -or ($environment -is [string] -and [string]::IsNullOrWhiteSpace($environment))) {
        $record.Reason = 'missing-environment'
    }
    elseif ($environment -isnot [string] -or $environment -match '[\r\n]') {
        $record.Reason = 'invalid-state'
        return $record
    }
    else { $record.RecordedEnvironment = $environment }
    $record.Ownership = @{ Codex = $state['Codex'] }
    return $record
}

# Files that must never be tracked, independent of their contents.
function Test-IsDangerousTrackedPath {
    param([Parameter(Mandatory)] [string] $RelativePath)

    $path = $RelativePath -replace '\\', '/'
    $leaf = [IO.Path]::GetFileName($path)
    return $leaf -match '(?i)\.(pem|key|p12|pfx)$' -or
        $leaf -match '(?i)^id_(rsa|ed25519)$' -or
        $leaf -match '(?i)^\.env(?:\..+)?$' -or
        $leaf -match '(?i)^\.?tokens?(?:\.(txt|json|ya?ml))?$' -or
        $leaf -match '(?i)\.tokens?$' -or
        $leaf -match '(?i)^(auth|\.credentials)\.json$' -or
        $path -match '(?i)(^|/)(backup|backups)(/|$)' -or
        $path -match '(?i)(^|/)\.ssh(/|$)'
}

# Extensions whose files are never read line-by-line by a text scanner.
$script:BinaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.7z', '.exe', '.dll', '.sqlite', '.db')

function Test-IsBinaryExtension {
    param([Parameter(Mandatory)] [string] $Path)
    return [System.IO.Path]::GetExtension($Path).ToLowerInvariant() -in $script:BinaryExtensions
}

# Machine-private path patterns. The drive pattern's negative lookbehind keeps URL schemes
# like https:// from matching as "s:/".
$script:DriveAbsolutePathPattern = '(?<![A-Za-z])[A-Za-z]:[\\/]'
$script:UncPathPattern = '\\\\[A-Za-z0-9?.$_-]'

function Assert-PlainPathNoReparse {
    <#
    .SYNOPSIS
        Verifies a path's existing ancestors (from root down) and leaf contain no reparse points.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $AllowMissing,
        [string] $MessagePrefix = 'reparse-point-refused: path contains a reparse point',
        [System.Collections.Generic.HashSet[string]] $CheckedPaths
    )
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw 'Path must not be empty.'
    }
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path, [ref]$provider, [ref]$drive)
    if ($null -eq $provider -or $provider.Name -cne 'FileSystem') {
        throw "Path must be a filesystem path: $Path"
    }
    $full = [System.IO.Path]::GetFullPath($resolved)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ([string]::IsNullOrEmpty($root)) {
        throw "Path must be rooted: $Path"
    }
    $trimmedRoot = $root.TrimEnd('\', '/')
    $remainder = $full.Substring($root.Length).TrimStart('\', '/')
    $segments = if ([string]::IsNullOrEmpty($remainder)) { @() } else { @($remainder -split '[\\/]' | Where-Object { $_ }) }

    $candidates = [System.Collections.Generic.List[string]]::new()
    $candidates.Add($root)
    $cursor = if ($trimmedRoot) { $trimmedRoot } else { $root }
    foreach ($segment in $segments) {
        $cursor = if ($cursor.EndsWith('\') -or $cursor.EndsWith('/')) { $cursor + $segment } else { $cursor + [System.IO.Path]::DirectorySeparatorChar + $segment }
        $candidates.Add($cursor)
    }

    for ($i = 0; $i -lt $candidates.Count; $i++) {
        $current = $candidates[$i]
        $isLeaf = ($i -eq ($candidates.Count - 1))
        if ($null -ne $CheckedPaths -and (-not $isLeaf) -and $CheckedPaths.Contains($current)) {
            continue
        }
        $item = $null
        try {
            $item = Get-Item -LiteralPath $current -Force -ErrorAction Stop
        }
        catch [System.Management.Automation.ItemNotFoundException] {
            $item = $null
        }
        catch [System.IO.DirectoryNotFoundException] {
            $item = $null
        }
        catch [System.IO.FileNotFoundException] {
            $item = $null
        }
        if ($null -eq $item) {
            if ($AllowMissing) { return }
            throw "Path does not exist: $current"
        }
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "${MessagePrefix}: $current"
        }
        if ($null -ne $CheckedPaths -and $item.PSIsContainer) {
            $null = $CheckedPaths.Add($current)
        }
    }
}

function Assert-TreeNoReparse {
    <#
    .SYNOPSIS
        Verifies a directory path, its existing ancestors, and all descendants contain no reparse points.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [switch] $AllowMissing,
        [string] $MessagePrefix = 'reparse-point-refused: path contains a reparse point'
    )
    Assert-PlainPathNoReparse -Path $Root -AllowMissing:$AllowMissing -MessagePrefix $MessagePrefix
    $provider = $null
    $drive = $null
    $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Root, [ref]$provider, [ref]$drive)
    $fullRoot = [System.IO.Path]::GetFullPath($resolved)
    $rootItem = $null
    try {
        $rootItem = Get-Item -LiteralPath $fullRoot -Force -ErrorAction Stop
    }
    catch [System.Management.Automation.ItemNotFoundException] {
        $rootItem = $null
    }
    catch [System.IO.DirectoryNotFoundException] {
        $rootItem = $null
    }
    catch [System.IO.FileNotFoundException] {
        $rootItem = $null
    }
    if ($null -eq $rootItem) {
        if ($AllowMissing) { return }
        throw "Path does not exist: $fullRoot"
    }
    if (-not $rootItem.PSIsContainer) {
        throw "Path is not a plain directory: $fullRoot"
    }
    foreach ($entry in @(Get-ChildItem -LiteralPath $fullRoot -Recurse -Force -ErrorAction Stop)) {
        if ($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "${MessagePrefix}: $($entry.FullName)"
        }
    }
}

function Invoke-BoundedProcess {
    <#
    .SYNOPSIS
        Runs an external process with async stdout/stderr draining and bounded timeout.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $FilePath,
        [AllowEmptyCollection()] [string[]] $Arguments = @(),
        [string] $WorkingDirectory,
        [System.Collections.IDictionary] $Environment,
        [ValidateRange(1, 86400)] [int] $TimeoutSeconds = 120,
        [string] $TimeoutMessage,
        [switch] $CloseStdIn
    )

    $info = [System.Diagnostics.ProcessStartInfo]::new($FilePath)
    foreach ($arg in @($Arguments)) {
        if ($null -ne $arg) { $info.ArgumentList.Add([string]$arg) }
    }
    if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
        $info.WorkingDirectory = $WorkingDirectory
    }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    if ($CloseStdIn) {
        $info.RedirectStandardInput = $true
    }
    if ($null -ne $Environment) {
        foreach ($key in $Environment.Keys) {
            $val = $Environment[$key]
            if ($null -eq $val) {
                $null = $info.Environment.Remove([string]$key)
            }
            else {
                $info.Environment[[string]$key] = [string]$val
            }
        }
    }

    $process = [System.Diagnostics.Process]::Start($info)
    if ($null -eq $process) {
        throw "Failed to start process: $FilePath"
    }
    try {
        if ($CloseStdIn) {
            $process.StandardInput.Close()
        }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $timeoutMs = $TimeoutSeconds * 1000
        if (-not $process.WaitForExit($timeoutMs)) {
            try { $process.Kill($true) } catch { }
            if (-not [string]::IsNullOrWhiteSpace($TimeoutMessage)) {
                throw $TimeoutMessage
            }
            $null = $process.WaitForExit(5000)
            $outText = if ($stdoutTask.Wait(2000)) { $stdoutTask.GetAwaiter().GetResult() } else { '' }
            $errText = if ($stderrTask.Wait(2000)) { $stderrTask.GetAwaiter().GetResult() } else { '' }
            return @{
                ExitCode = -1
                StdOut   = $outText
                StdErr   = $errText
                TimedOut = $true
            }
        }
        $process.WaitForExit()
        return @{
            ExitCode = $process.ExitCode
            StdOut   = $stdoutTask.GetAwaiter().GetResult()
            StdErr   = $stderrTask.GetAwaiter().GetResult()
            TimedOut = $false
        }
    }
    finally {
        $process.Dispose()
    }
}

function Invoke-SecretScanGate {
    # Runs scripts/scan-secrets.ps1 under the given repository root in a child pwsh and
    # throws on failure. Callers decide when it runs (before writes, or after with a revert).
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) { throw "Missing secret scan script: $scan" }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE." }
}
