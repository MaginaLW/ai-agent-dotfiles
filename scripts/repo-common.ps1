#requires -Version 7.0
<#
.SYNOPSIS
    Shared repository scan-policy helpers. Dot-source only.

.DESCRIPTION
    The single definition of the policy literals several scripts and gates share: the
    protected Reasonix desktop-state files, the porcelain status pathspecs built from them,
    the binary-extension list, and the drive-letter/UNC machine-private path patterns.
    Change these only with the owner's approval; every consumer fails closed around them.
    Keep exactly one definition of each helper in the repository: the syntax gate's
    unknown-parameter pass skips names defined in more than one script.
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
    return @('.') + @($script:ProtectedReasonixFiles | ForEach-Object { ":(exclude)$_" })
}

function Test-IsProtectedReasonixFile {
    param([Parameter(Mandatory)] [string] $RelativePath)
    return $RelativePath -in $script:ProtectedReasonixFiles
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
