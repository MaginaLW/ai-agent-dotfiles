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

function Invoke-SecretScanGate {
    # Runs scripts/scan-secrets.ps1 under the given repository root in a child pwsh and
    # throws on failure. Callers decide when it runs (before writes, or after with a revert).
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) { throw "Missing secret scan script: $scan" }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) { throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE." }
}
