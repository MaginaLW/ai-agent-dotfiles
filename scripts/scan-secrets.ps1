#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$configPath = Join-Path $RepoRoot '.gitleaks.toml'
$gitleaksFailed = $false
$jsonArtifactCommon = Join-Path $PSScriptRoot 'json-artifact-common.ps1'
if (-not (Test-Path -LiteralPath $jsonArtifactCommon -PathType Leaf)) {
    throw "Missing JSON artifact and pinned-tool helper: $jsonArtifactCommon"
}
. $jsonArtifactCommon
$toolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gitleaksTool = Assert-PinnedToolInstalled -LockPath (Join-Path $toolchainRoot 'tools/gitleaks/gitleaks.lock.json')
$gitleaks = $gitleaksTool.Paths.Executable
$scanWorkspace = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-scan-$([Guid]::NewGuid().ToString('N'))"
$scanRoot = Join-Path $scanWorkspace 'input'
$scanManifestPath = Join-Path $scanWorkspace 'scan-input-manifest.json'
$scanManifest = New-FilteredScanInput -RepoRoot $RepoRoot -DestinationRoot $scanRoot
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
    Write-Host "Running pinned gitleaks from $gitleaks against a filtered no-follow input."
    $arguments = @('detect', '--no-git', '--source', $scanRoot, '--redact')
    if (Test-Path -LiteralPath $configPath) {
        $arguments += @('--config', $configPath)
    }
    & $gitleaks @arguments
    if ($LASTEXITCODE -ne 0) {
        $gitleaksFailed = $true
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

    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
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
