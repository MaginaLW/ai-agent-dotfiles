#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $JsonPath,
    [switch] $CanonicalPreflight,
    [string] $SourceRoot,
    [string] $CanonicalPreflightOutputRoot,
    [string] $ScannerConfigPath,
    [string] $ValidatorCacheRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$trustedConfigPath = Join-Path $RepoRoot '.gitleaks.toml'
$configPath = $trustedConfigPath
$gitleaksFailed = $false
$preflightCommon = Join-Path $PSScriptRoot 'canonical-preflight-common.ps1'
if (-not (Test-Path -LiteralPath $preflightCommon -PathType Leaf)) {
    throw "Missing canonical preflight helper: $preflightCommon"
}
. $preflightCommon

if (-not $CanonicalPreflight) {
    foreach ($name in @('SourceRoot','CanonicalPreflightOutputRoot','ScannerConfigPath','ValidatorCacheRoot')) {
        if ($PSBoundParameters.ContainsKey($name)) { throw "$name is internal to -CanonicalPreflight." }
    }
    $SourceRoot = $RepoRoot
}
else {
    foreach ($name in @('SourceRoot','CanonicalPreflightOutputRoot','ScannerConfigPath','JsonPath')) {
        if (-not $PSBoundParameters.ContainsKey($name) -or [string]::IsNullOrWhiteSpace([string](Get-Variable -Name $name -ValueOnly))) {
            throw "-CanonicalPreflight requires -$name."
        }
    }
    $SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
    $CanonicalPreflightOutputRoot = [System.IO.Path]::GetFullPath($CanonicalPreflightOutputRoot)
    $JsonPath = [System.IO.Path]::GetFullPath($JsonPath)
    $ScannerConfigPath = (Resolve-Path -LiteralPath $ScannerConfigPath).Path
    if ($ScannerConfigPath -cne (Resolve-Path -LiteralPath $trustedConfigPath).Path) {
        throw 'Canonical preflight scanner configuration must come from the approved toolchain.'
    }
    $configPath = $ScannerConfigPath
    if ((Test-PathInsideRoot -Path $CanonicalPreflightOutputRoot -Root $SourceRoot) -or (Test-PathInsideRoot -Path $SourceRoot -Root $CanonicalPreflightOutputRoot)) {
        throw 'CanonicalPreflightOutputRoot and scan SourceRoot must be disjoint.'
    }
    $null = Resolve-CanonicalPreflightArtifactPath -Path $JsonPath -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -RepoRoot $RepoRoot -ForbiddenRoots @($SourceRoot) -AllowMissingLeaf
    $null = Get-SafeTreeSnapshot -Root $SourceRoot -ExcludeRelativePaths @(Get-ProtectedReasonixRelativePaths)
}

$toolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gitleaksLockPath = Join-Path $toolchainRoot 'tools/gitleaks/gitleaks.lock.json'
$scanWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-scan-$([Guid]::NewGuid().ToString('N'))"
$scanRoot = Join-Path $scanWorkspace 'input'
$scanManifestPath = Join-Path $scanWorkspace 'scan-input-manifest.json'
$scanManifest = if ($CanonicalPreflight) {
    New-FilteredScanInput -RepoRoot $SourceRoot -DestinationRoot $scanRoot -ExcludedPrefixes @() -SkipGitIgnore
}
else {
    New-FilteredScanInput -RepoRoot $SourceRoot -DestinationRoot $scanRoot
}
Write-ScanInputManifest -Manifest $scanManifest -Path $scanManifestPath

function Test-IsSkippedPath {
    param(
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $normalized = $RelativePath -replace '\\', '/'
    return (
        $normalized -like '.git/*' -or
        $normalized -like 'claude/skills/*' -or
        $normalized -like 'codex/skills/*' -or
        $normalized -like 'backup/*' -or
        $normalized -like 'tmp/*'
    )
}

function Test-IsBinaryExtension {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    $binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.7z', '.exe', '.dll', '.sqlite', '.db')
    return [System.IO.Path]::GetExtension($Path).ToLowerInvariant() -in $binaryExtensions
}

function Test-IsAllowedPlaceholderLine {
    param(
        [Parameter(Mandatory)] [string] $Line,
        [Parameter(Mandatory)] [string] $PatternName
    )

    if ($Line -match '#\s*scan-ok\b') {
        return $true
    }

    if ($Line -match '(?i)\b\w+_env_var\s*=\s*["''][A-Za-z_][A-Za-z0-9_]*["'']') {
        return $true
    }

    if ($PatternName -eq 'Bearer token' -and $Line -match 'Bearer\s+\$\{[A-Za-z_][A-Za-z0-9_]*\}') {
        return $true
    }

    if ($PatternName -eq 'Literal secret assignment') {
        if ($Line -match '[:=]\s*["'']\$\{[A-Za-z_][A-Za-z0-9_]*\}["'']') {
            return $true
        }

        if ($Line -match '[:=]\s*["''][A-Z][A-Z0-9_]{2,}["'']') {
            return $true
        }
    }

    return $false
}

try {
    $arguments = @('detect', '--no-git', '--source', $scanRoot, '--redact')
    if (Test-Path -LiteralPath $configPath) {
        $arguments += @('--config', $configPath)
    }
    $gitleaksLease = $null
    try {
        $gitleaksLease = Open-PinnedToolLease -LockPath $gitleaksLockPath
        Write-Host "Running pinned gitleaks from $($gitleaksLease.Paths.Executable) against a filtered no-follow input."
        $gitleaksResult = Invoke-PinnedToolProcess `
            -ToolLease $gitleaksLease `
            -Arguments $arguments `
            -Operation 'Pinned gitleaks secret scan' `
            -TimeoutMilliseconds 120000 `
            -ReapTimeoutMilliseconds 5000 `
            -MaximumCombinedOutputBytes 1048576
        if (-not [string]::IsNullOrWhiteSpace([string]$gitleaksResult.Output)) {
            Write-Host ([string]$gitleaksResult.Output).TrimEnd()
        }
        if ($gitleaksResult.ExitCode -ne 0) {
            $gitleaksFailed = $true
        }
    }
    finally {
        if ($null -ne $gitleaksLease) { Close-PinnedToolLease -ToolLease $gitleaksLease }
    }

$blockingPatterns = @(
    @{ Name = 'Anthropic API key'; Regex = 'sk-ant-[A-Za-z0-9_-]{20,}' },
    @{ Name = 'OpenAI API key'; Regex = 'sk-(proj-)?[A-Za-z0-9_-]{20,}' },
    @{ Name = 'GitHub classic PAT'; Regex = 'ghp_[A-Za-z0-9]{36}' },
    @{ Name = 'GitHub fine-grained PAT'; Regex = 'github_pat_[A-Za-z0-9_]{22,}' },
    @{ Name = 'Slack token'; Regex = 'xox[bpars]-[A-Za-z0-9-]{10,}' },
    @{ Name = 'Private key'; Regex = '-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----' },
    @{ Name = 'Bearer token'; Regex = 'Bearer\s+[A-Za-z0-9._-]{20,}' },
    @{ Name = 'Literal secret assignment'; Regex = '(?i)(api_key|token|secret|password|client_secret|refresh_token|access_token)\s*[:=]\s*["''][^$][^"'']{8,}["'']' }
)

$hintRegex = '(?i)\b(api_key|apikey|token|secret|password|passwd|credential|authorization|bearer|cookie|private_key|OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN)\b'
$findings = [System.Collections.Generic.List[object]]::new()
$hints = [System.Collections.Generic.List[object]]::new()

function Write-ScanJson {
    param([Parameter(Mandatory)] [string] $Path, [ValidateSet('PASS', 'FAIL')] [string] $Result)

    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Result = $Result
        Scanner = 'pinned-gitleaks-and-fallback'
        GitleaksAvailable = $true
        GitleaksFailed = [bool] $gitleaksFailed
        BlockingFindingCount = $findings.Count
        HintCount = $hints.Count
        Findings = @($findings)
    }
    if ($CanonicalPreflight) {
        $null = Publish-ValidatedPreflightJson -Document $document -Path $Path -SchemaPath (Join-Path $RepoRoot 'schemas/secret-scan.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
        return
    }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
}

Get-ChildItem -LiteralPath $scanRoot -File -Recurse -Force | ForEach-Object {
    $relativePath = [System.IO.Path]::GetRelativePath($scanRoot, $_.FullName)
    if (Test-IsSkippedPath -RelativePath $relativePath) {
        return
    }
    if (Test-IsBinaryExtension -Path $_.FullName) {
        return
    }

    $lineNumber = 0
    foreach ($line in [System.IO.File]::ReadLines($_.FullName)) {
        $lineNumber++

        foreach ($pattern in $blockingPatterns) {
            if ($line -match $pattern.Regex) {
                if (-not (Test-IsAllowedPlaceholderLine -Line $line -PatternName $pattern.Name)) {
                    $findings.Add([pscustomobject]@{
                        File = $relativePath
                        Line = $lineNumber
                        Pattern = $pattern.Name
                    })
                }
            }
        }

        if ($line -match $hintRegex -and $line -notmatch '#\s*scan-ok\b') {
            $hints.Add([pscustomobject]@{
                File = $relativePath
                Line = $lineNumber
                Pattern = 'Keyword hint'
            })
        }
    }
}

if ($hints.Count -gt 0) {
    Write-Host "WARN: Keyword hints found (non-blocking): $($hints.Count)"
    $hints | Select-Object -First 20 | Format-Table -AutoSize | Out-String | Write-Host
    if ($hints.Count -gt 20) {
        Write-Host "WARN: $($hints.Count - 20) additional keyword hints suppressed."
    }
}

if ($findings.Count -gt 0) {
    Write-Host 'ERROR: Possible secret found.'
    $findings | Format-Table -AutoSize | Out-String | Write-Host
    Write-Host 'Action: remove it, replace it with an environment variable placeholder, or append "# scan-ok" only after manual review.'
    if ($JsonPath) { Write-ScanJson -Path $JsonPath -Result 'FAIL' }
    exit 1
}

if ($gitleaksFailed) {
    Write-Host 'ERROR: gitleaks reported one or more findings.'
    if ($JsonPath) { Write-ScanJson -Path $JsonPath -Result 'FAIL' }
    exit 1
}

Write-Host 'No blocking secrets found.'
if ($JsonPath) { Write-ScanJson -Path $JsonPath -Result 'PASS' }
}
finally {
    if (Test-Path -LiteralPath $scanWorkspace -PathType Container) {
        Remove-Item -LiteralPath $scanWorkspace -Recurse -Force
    }
}
