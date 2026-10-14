#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $JsonPath,
    [string] $ScannerConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$configPath = if ($ScannerConfigPath) { (Resolve-Path -LiteralPath $ScannerConfigPath).Path } else { Join-Path $RepoRoot '.gitleaks.toml' }
. (Join-Path $PSScriptRoot 'pinned-tool.ps1')
. (Join-Path $PSScriptRoot 'repo-common.ps1')

# Scan input exclusions (matched case-insensitively). Change them only with the
# owner's approval:
#  - the path prefixes below (generated roots and tmp/);
#  - the four protected .reasonix/desktop-topic-* files (repo-common.ps1);
#  - Git-ignored entries: `git ls-files -co --exclude-standard` selects tracked
#    files plus untracked, non-ignored files.
# The fallback scanner additionally skips backup/* and tmp/* (Test-IsSkippedPath
# below, unchanged); gitleaks still sees backup/ when it is not Git-ignored.
$scanExcludedPrefixes = @('.git/', 'claude/skills/', 'codex/skills/', 'reasonix/skills/', 'tmp/')

function Test-IsScanInputExcluded {
    param([Parameter(Mandatory)] [string] $RelativePath)

    if (Test-IsProtectedReasonixFile -RelativePath $RelativePath) { return $true }
    foreach ($prefix in $scanExcludedPrefixes) {
        if ($RelativePath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Assert-ScanInputNoReparse {
    # Fail closed on any reparse point (symlink, junction) in the file's path,
    # from the drive root down to the file itself, as the old no-follow walker did.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [AllowEmptyCollection()] [System.Collections.Generic.HashSet[string]] $CheckedDirectories)

    $item = Get-Item -LiteralPath $Path -Force
    if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Scan input contains a reparse point: $Path" }
    if ($item.PSIsContainer) { throw "Scan input entry is a directory (nested repository or submodule): $Path" }
    $directory = $item.Directory
    while ($null -ne $directory -and $CheckedDirectories.Add($directory.FullName)) {
        if ($directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { throw "Scan input path contains a reparse point: $($directory.FullName)" }
        $directory = $directory.Parent
    }
}

function Get-ScanInputRelativePaths {
    param([Parameter(Mandatory)] [string] $Root)

    # Decode Git's UTF-8 output explicitly so non-ASCII file names survive.
    $previousEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
        $listing = & git -C $Root ls-files -z --cached --others --exclude-standard
        if ($LASTEXITCODE -ne 0) { throw "git ls-files failed for scan input: $Root" }
    }
    finally { [Console]::OutputEncoding = $previousEncoding }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $checkedDirectories = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($relative in @(($listing -join '') -split "`0")) {
        if ([string]::IsNullOrEmpty($relative) -or -not $seen.Add($relative)) { continue }
        if (Test-IsScanInputExcluded -RelativePath $relative) { continue }
        $full = Join-Path $Root $relative
        # A tracked file deleted from the working tree is not on disk to scan.
        if ($null -eq (Get-Item -LiteralPath $full -Force -ErrorAction SilentlyContinue)) { continue }
        Assert-ScanInputNoReparse -Path $full -CheckedDirectories $checkedDirectories
        $paths.Add($relative)
    }
    return , $paths.ToArray()
}

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

$script:ScanBlockingPatterns = @(
    @{ Name = 'Anthropic API key'; Regex = 'sk-ant-[A-Za-z0-9_-]{20,}' },
    @{ Name = 'OpenAI API key'; Regex = 'sk-(proj-)?[A-Za-z0-9_-]{20,}' },
    @{ Name = 'GitHub classic PAT'; Regex = 'ghp_[A-Za-z0-9]{36}' },
    @{ Name = 'GitHub fine-grained PAT'; Regex = 'github_pat_[A-Za-z0-9_]{22,}' },
    @{ Name = 'Slack token'; Regex = 'xox[bpars]-[A-Za-z0-9-]{10,}' },
    @{ Name = 'Private key'; Regex = '-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----' },
    @{ Name = 'Bearer token'; Regex = 'Bearer\s+[A-Za-z0-9._-]{20,}' },
    @{ Name = 'Literal secret assignment'; Regex = '(?i)(api_key|token|secret|password|client_secret|refresh_token|access_token)\s*[:=]\s*["''][^$][^"'']{8,}["'']' }
)

$script:ScanHintRegex = '(?i)\b(api_key|apikey|token|secret|password|passwd|credential|authorization|bearer|cookie|private_key|OPENAI_API_KEY|ANTHROPIC_API_KEY|GITHUB_TOKEN)\b'

function Copy-ScanInputs {
    # Materialises the filtered input set as a plain copy tree for gitleaks.
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $ScanRoot, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RelativePaths)

    foreach ($relative in $RelativePaths) {
        $destination = Join-Path $ScanRoot $relative
        [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        [System.IO.File]::Copy((Join-Path $RepoRoot $relative), $destination)
    }
    [System.IO.Directory]::CreateDirectory($ScanRoot) | Out-Null
}

function Invoke-GitleaksScan {
    # Runs the pinned gitleaks over the filtered copy, echoes its combined output and
    # returns whether it failed. Same 120 s bound the old pinned-tool lease enforced:
    # a hung scanner fails closed.
    param([Parameter(Mandatory)] [string] $ScanRoot, [Parameter(Mandatory)] [string] $ConfigPath, [Parameter(Mandatory)] [string] $LockPath, [Parameter(Mandatory)] [int] $InputCount)

    $arguments = @('detect', '--no-git', '--source', $ScanRoot, '--redact')
    if (Test-Path -LiteralPath $ConfigPath) {
        $arguments += @('--config', $ConfigPath)
    }
    $gitleaks = Get-PinnedToolExecutable -LockPath $LockPath
    Write-Host "Running pinned gitleaks from $($gitleaks.Executable) against a filtered copy of $InputCount files."
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new($gitleaks.Executable)
    foreach ($argument in $arguments) { $startInfo.ArgumentList.Add($argument) }
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $gitleaksProcess = [System.Diagnostics.Process]::Start($startInfo)
    $stdoutTask = $gitleaksProcess.StandardOutput.ReadToEndAsync()
    $stderrTask = $gitleaksProcess.StandardError.ReadToEndAsync()
    if (-not $gitleaksProcess.WaitForExit(120000)) {
        $gitleaksProcess.Kill($true)
        throw 'gitleaks-timeout: the pinned scanner did not finish within 120 seconds.'
    }
    $gitleaksProcess.WaitForExit()
    $output = $stdoutTask.GetAwaiter().GetResult() + $stderrTask.GetAwaiter().GetResult()
    if (-not [string]::IsNullOrWhiteSpace($output)) {
        Write-Host $output.TrimEnd()
    }
    return [pscustomobject]@{ Failed = ($gitleaksProcess.ExitCode -ne 0) }
}

function Invoke-FallbackScan {
    # The local pattern pass over the same filtered copy: blocking findings plus
    # non-blocking keyword hints.
    param([Parameter(Mandatory)] [string] $ScanRoot)

    $findings = [System.Collections.Generic.List[object]]::new()
    $hints = [System.Collections.Generic.List[object]]::new()
    Get-ChildItem -LiteralPath $ScanRoot -File -Recurse -Force | ForEach-Object {
        $relativePath = [System.IO.Path]::GetRelativePath($ScanRoot, $_.FullName)
        if (Test-IsSkippedPath -RelativePath $relativePath) {
            return
        }
        if (Test-IsBinaryExtension -Path $_.FullName) {
            return
        }

        $lineNumber = 0
        foreach ($line in [System.IO.File]::ReadLines($_.FullName)) {
            $lineNumber++

            foreach ($pattern in $script:ScanBlockingPatterns) {
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

            if ($line -match $script:ScanHintRegex -and $line -notmatch '#\s*scan-ok\b') {
                $hints.Add([pscustomobject]@{
                    File = $relativePath
                    Line = $lineNumber
                    Pattern = 'Keyword hint'
                })
            }
        }
    }
    return [pscustomobject]@{ Findings = @($findings); Hints = @($hints) }
}

function Write-ScanJson {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [bool] $GitleaksFailed,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Findings,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Hints
    )

    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Result = $Result
        Scanner = 'pinned-gitleaks-and-fallback'
        GitleaksAvailable = $true
        GitleaksFailed = $GitleaksFailed
        BlockingFindingCount = $Findings.Count
        HintCount = $Hints.Count
        Findings = @($Findings)
    }
    $parent = Split-Path -Parent $Path
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $document -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
}

$toolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$gitleaksLockPath = Join-Path $toolchainRoot 'tools/gitleaks/gitleaks.lock.json'
$scanWorkspace = Join-Path ([IO.Path]::GetTempPath()) "ai-agent-dotfiles-scan-$([Guid]::NewGuid().ToString('N'))"
$scanRoot = Join-Path $scanWorkspace 'input'
$scanInputPaths = Get-ScanInputRelativePaths -Root $RepoRoot

try {
    Copy-ScanInputs -RepoRoot $RepoRoot -ScanRoot $scanRoot -RelativePaths $scanInputPaths

    $gitleaksResult = Invoke-GitleaksScan -ScanRoot $scanRoot -ConfigPath $configPath -LockPath $gitleaksLockPath -InputCount $scanInputPaths.Count
    $fallback = Invoke-FallbackScan -ScanRoot $scanRoot

    if ($fallback.Hints.Count -gt 0) {
        Write-Host "WARN: Keyword hints found (non-blocking): $($fallback.Hints.Count)"
        $fallback.Hints | Select-Object -First 20 | Format-Table -AutoSize | Out-String | Write-Host
        if ($fallback.Hints.Count -gt 20) {
            Write-Host "WARN: $($fallback.Hints.Count - 20) additional keyword hints suppressed."
        }
    }

    if ($fallback.Findings.Count -gt 0) {
        [Console]::Error.WriteLine('ERROR: Possible secret found.')
        $fallback.Findings | Format-Table -AutoSize | Out-String | Write-Host
        [Console]::Error.WriteLine('Action: remove it, replace it with an environment variable placeholder, or append "# scan-ok" only after manual review.')
        if ($JsonPath) { Write-ScanJson -Path $JsonPath -Result 'FAIL' -GitleaksFailed $gitleaksResult.Failed -Findings $fallback.Findings -Hints $fallback.Hints }
        exit 1
    }

    if ($gitleaksResult.Failed) {
        [Console]::Error.WriteLine('ERROR: gitleaks reported one or more findings.')
        if ($JsonPath) { Write-ScanJson -Path $JsonPath -Result 'FAIL' -GitleaksFailed $true -Findings @() -Hints @() }
        exit 1
    }

    Write-Host 'No blocking secrets found.'
    if ($JsonPath) { Write-ScanJson -Path $JsonPath -Result 'PASS' -GitleaksFailed $false -Findings @() -Hints @() }
}
finally {
    if (Test-Path -LiteralPath $scanWorkspace -PathType Container) {
        Remove-Item -LiteralPath $scanWorkspace -Recurse -Force
    }
}
