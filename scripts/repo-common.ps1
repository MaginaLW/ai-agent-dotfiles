#requires -Version 7.0
<#
.SYNOPSIS
    Shared repository scan-policy helpers. Dot-source only.

.DESCRIPTION
    The single definition of the policy literals several scripts and gates share: the
    generated skill roots, scan-input prefixes, protected Reasonix desktop-state files,
    porcelain status pathspecs, binary-extension list, Codex live-root rule and the
    drive-letter/UNC machine-private path patterns. Change these only with the owner's
    approval; every consumer fails closed around them. Keep exactly one definition of each
    helper in the repository: the syntax gate's unknown-parameter pass skips names defined
    in more than one script.
#>

Set-StrictMode -Version Latest

# Live Reasonix desktop state that may sit untracked in a checkout; it stays out of the
# secret-scan input, the syntax gate and every porcelain status check.
$script:ProtectedReasonixFiles = @(
    '.reasonix/desktop-topic-auto-title-meta.json',
    '.reasonix/desktop-topic-created-at.json',
    '.reasonix/desktop-topic-title-sources.json',
    '.reasonix/desktop-topic-titles.json'
)

function Get-PorcelainStatusPaths {
    # git status pathspecs covering the whole tree minus the protected Reasonix files.
    $paths = @('.') + @($script:ProtectedReasonixFiles | ForEach-Object { ":(exclude)$_" })
    return , $paths
}

# Generated output roots and the filtered input prefixes shared by the build/scan gates.
$script:GeneratedSkillRoots = @('claude/skills', 'codex/skills', 'reasonix/skills')
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

function Test-IsProtectedReasonixFile {
    param([Parameter(Mandatory)] [string] $RelativePath)
    foreach ($path in $script:ProtectedReasonixFiles) {
        if ($RelativePath.Equals($path, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
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

function Invoke-SecretScanGate {
    # Runs scripts/scan-secrets.ps1 under the given repository root in a child pwsh and
    # throws on failure. Callers decide when it runs (before writes, or after with a revert).
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) { throw "Missing secret scan script: $scan" }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE." }
}
