#requires -Version 7.0

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

function Resolve-RepoRoot {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot
    )

    return (Resolve-Path -LiteralPath $RepoRoot).Path
}

function Get-CodexLiveSkillsInfo {
    param(
        [Parameter(Mandatory)] [string] $HomeRoot
    )

    $preferred = Join-Path $HomeRoot '.codex/skills'
    $fallback = Join-Path $HomeRoot '.agents/skills'
    if (Test-Path -LiteralPath $preferred) {
        return [pscustomobject] @{
            Path = $preferred
            Selection = 'preferred'
            RelativePath = '.codex/skills'
        }
    }
    if (Test-Path -LiteralPath $fallback) {
        return [pscustomobject] @{
            Path = $fallback
            Selection = 'fallback'
            RelativePath = '.agents/skills'
        }
    }
    return [pscustomobject] @{
        Path = $preferred
        Selection = 'preferred-missing'
        RelativePath = '.codex/skills'
    }
}

function Get-PlatformSkillSources {
    param(
        [Parameter(Mandatory)] [string] $HomeRoot,
        [switch] $IncludeClaude,
        [switch] $IncludeCodex,
        [switch] $IncludeReasonix
    )

    $sources = [System.Collections.Generic.List[object]]::new()
    if ($IncludeClaude) {
        $sources.Add([pscustomobject] @{
            Tool = 'claude'
            PreferredPlatform = ''
            Path = Join-Path $HomeRoot '.claude/skills'
            Selection = 'fixed'
            RelativePath = '.claude/skills'
        })
    }
    if ($IncludeCodex) {
        $codex = Get-CodexLiveSkillsInfo -HomeRoot $HomeRoot
        $sources.Add([pscustomobject] @{
            Tool = 'codex'
            PreferredPlatform = ''
            Path = $codex.Path
            Selection = $codex.Selection
            RelativePath = $codex.RelativePath
        })
    }
    if ($IncludeReasonix) {
        $sources.Add([pscustomobject] @{
            Tool = 'reasonix'
            PreferredPlatform = 'reasonix-only'
            Path = Join-Path $HomeRoot 'AppData/Roaming/reasonix/skills'
            Selection = 'fixed'
            RelativePath = 'AppData/Roaming/reasonix/skills'
        })
    }
    return @($sources)
}

function Get-SkillDirectories {
    param(
        [Parameter(Mandatory)] [string] $RootPath,
        [string[]] $ExcludeNames = @('.system')
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notin $ExcludeNames -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))
        } | Sort-Object Name)
}

function Join-RepoPath {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    return Join-Path $RepoRoot $RelativePath
}

function Assert-PathUnderRoot {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $prefix = $fullRoot + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath -ne $fullRoot -and -not $fullPath.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to touch path outside root: $fullPath"
    }
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] [string] $Content
    )

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    $normalized = (($Content ?? '') -replace "`r`n", "`n") -replace "`r", "`n"
    [System.IO.File]::WriteAllText($Path, $normalized, [System.Text.UTF8Encoding]::new($false))
}

function ConvertTo-KebabName {
    param(
        [Parameter(Mandatory)] [string] $Name
    )

    $value = $Name.Trim().ToLowerInvariant()
    $value = $value -replace '[^a-z0-9]+', '-'
    $value = $value.Trim('-')
    if ([string]::IsNullOrWhiteSpace($value)) {
        return 'unnamed-skill'
    }
    return $value
}

function Get-FileSha256 {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-StringSha256 {
    param(
        [Parameter(Mandatory)] [string] $Text
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Text)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-', '').ToLowerInvariant()
    }
    finally {
        $sha.Dispose()
    }
}

function Get-TreeHash {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $rows = Get-ChildItem -LiteralPath $Path -File -Recurse -Force |
        Sort-Object FullName |
        ForEach-Object {
            $relative = [System.IO.Path]::GetRelativePath($Path, $_.FullName) -replace '\\', '/'
            "$relative|$($_.Length)|$(Get-FileSha256 -Path $_.FullName)"
        }

    return Get-StringSha256 -Text (($rows -join "`n") + "`n")
}

function Test-LikelyBinaryFile {
    param(
        [Parameter(Mandatory)] [System.IO.FileInfo] $File
    )

    $binaryExtensions = @('.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip', '.7z', '.exe', '.dll', '.sqlite', '.db')
    if ($File.Extension.ToLowerInvariant() -in $binaryExtensions) {
        return $true
    }

    if ($File.Length -gt 0) {
        $stream = [System.IO.File]::OpenRead($File.FullName)
        try {
            $buffer = New-Object byte[] ([Math]::Min(4096, [int] $File.Length))
            $read = $stream.Read($buffer, 0, $buffer.Length)
            for ($i = 0; $i -lt $read; $i++) {
                if ($buffer[$i] -eq 0) {
                    return $true
                }
            }
        }
        finally {
            $stream.Dispose()
        }
    }

    return $false
}

function Get-TextFileContent {
    param(
        [Parameter(Mandatory)] [string] $Path
    )

    return [System.IO.File]::ReadAllText($Path)
}

function Get-SkillFrontMatter {
    param(
        [Parameter(Mandatory)] [string] $SkillPath
    )

    $skillMd = Join-Path $SkillPath 'SKILL.md'
    $fields = [ordered] @{}
    $body = ''
    if (-not (Test-Path -LiteralPath $skillMd)) {
        return [pscustomobject] @{
            Name = $null
            Description = $null
            Fields = $fields
            Body = $body
        }
    }

    $text = Get-TextFileContent -Path $skillMd
    $lines = $text -split "`r?`n"
    if ($lines.Count -gt 0 -and $lines[0].Trim() -eq '---') {
        $endIndex = $null
        for ($i = 1; $i -lt $lines.Count; $i++) {
            if ($lines[$i].Trim() -eq '---') {
                $endIndex = $i
                break
            }
            if ($lines[$i] -match '^\s*([A-Za-z0-9_-]+)\s*:\s*(.*)\s*$') {
                $key = $Matches[1]
                $value = $Matches[2].Trim().Trim('"', "'")
                $fields[$key] = $value
            }
        }
        if ($null -ne $endIndex) {
            $body = ($lines[($endIndex + 1)..($lines.Count - 1)] -join "`n").TrimStart("`n")
        }
    }
    else {
        $body = $text
    }

    return [pscustomobject] @{
        Name = if ($fields.Contains('name')) { $fields['name'] } else { $null }
        Description = if ($fields.Contains('description')) { $fields['description'] } else { $null }
        Fields = $fields
        Body = $body
    }
}

function Get-SkillName {
    param(
        [Parameter(Mandatory)] [string] $SkillPath
    )

    $frontMatter = Get-SkillFrontMatter -SkillPath $SkillPath
    $rawName = if ($frontMatter.Name) { $frontMatter.Name } else { Split-Path -Leaf $SkillPath }
    return ConvertTo-KebabName -Name $rawName
}

function Get-RelativeDisplayPath {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    return ([System.IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/')
}

function Get-PortableSkillPath {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $fullRepo = [System.IO.Path]::GetFullPath($RepoRoot).TrimEnd('\', '/')
    $repoPrefix = $fullRepo + [System.IO.Path]::DirectorySeparatorChar
    if ($fullPath.Equals($fullRepo, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($repoPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        return Get-RelativeDisplayPath -Root $RepoRoot -Path $fullPath
    }

    $normalized = $fullPath -replace '\\', '/'
    if ($normalized -match '(?i)(/\.claude/.*|/\.codex/.*|/\.agents/.*|/AppData/Roaming/reasonix/.*)$') {
        return '<HomeRoot>' + $Matches[1]
    }
    return '<external>/' + (Split-Path -Leaf $fullPath)
}

function Get-SkillSignals {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SkillPath
    )

    $claudeFeatures = [System.Collections.Generic.List[string]]::new()
    $codexFeatures = [System.Collections.Generic.List[string]]::new()
    $reasonixFeatures = [System.Collections.Generic.List[string]]::new()
    $localPaths = [System.Collections.Generic.List[object]]::new()
    $secretFindings = [System.Collections.Generic.List[object]]::new()
    $binaryFindings = [System.Collections.Generic.List[object]]::new()

    $claudePatterns = [ordered] @{
        'claude-skill-dir' = '\$\{CLAUDE_SKILL_DIR\}'
        'allowed-tools' = '(?im)^\s*allowed-tools\s*:'
        'disable-model-invocation' = '(?im)^\s*disable-model-invocation\s*:'
        'user-invocable' = '(?im)^\s*user-invocable\s*:'
        'claude-hooks' = '(?i)\bClaude hooks?\b|\bhooks\s*:'
        'output-styles' = '(?i)\boutput-styles?\b'
        'subagents' = '(?i)\bsubagents?\b'
    }
    $codexPatterns = [ordered] @{
        'agents-openai-yaml' = '(?i)agents/openai\.ya?ml|agents\\openai\.ya?ml'
        'codex-plugin-metadata' = '(?i)codex plugin metadata|\.codex-plugin'
        'codex-ui-metadata' = '(?i)codex ui metadata'
        'codex-tool-dependency' = '(?i)codex-specific tool dependencies'
    }
    $reasonixPatterns = [ordered] @{
        'reasonix-skill-root' = '(?i)[/\\](?:AppData[/\\]Roaming[/\\]reasonix|\.reasonix)[/\\](?:skills[/\\])?'
        'reasonix-reference' = '(?i)\bReasonix\b|\breasonix\b'
    }
    $secretPatterns = [ordered] @{
        'Anthropic API key' = 'sk-ant-[A-Za-z0-9_-]{20,}'
        'OpenAI API key' = 'sk-(proj-)?[A-Za-z0-9_-]{20,}'
        'GitHub classic PAT' = 'ghp_[A-Za-z0-9]{36}'
        'GitHub fine-grained PAT' = 'github_pat_[A-Za-z0-9_]{22,}'
        'Slack token' = 'xox[bpars]-[A-Za-z0-9-]{10,}'
        'Private key' = '-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----'
        'Bearer token' = 'Bearer\s+[A-Za-z0-9._-]{20,}'
        'Literal secret assignment' = '(?i)(api_key|token|secret|password|client_secret|refresh_token|access_token)\s*[:=]\s*["''][^$][^"'']{8,}["'']'
    }
    $localPathPatterns = [ordered] @{
        'Windows user path' = 'C:\\Users\\[^\\\s"''\)]+'
        'Windows user path slash' = 'C:/Users/[^/\s"''\)]+'
        'USERPROFILE percent' = '%USERPROFILE%'
        'USERPROFILE env' = '\$env:USERPROFILE'
        'Unix home path' = '/home/[^/\s"''\)]+'
    }

    $files = @(Get-ChildItem -LiteralPath $SkillPath -File -Recurse -Force)
    foreach ($file in $files) {
        $relative = Get-RelativeDisplayPath -Root $RepoRoot -Path $file.FullName
        if ($file.Length -gt 1024 * 1024) {
            $binaryFindings.Add([pscustomobject] @{ File = $relative; Rule = 'large-file'; Severity = 'medium' })
        }
        if (Test-LikelyBinaryFile -File $file) {
            $binaryFindings.Add([pscustomobject] @{ File = $relative; Rule = 'unknown-or-binary-file'; Severity = 'medium' })
            continue
        }

        $text = Get-TextFileContent -Path $file.FullName
        foreach ($entry in $claudePatterns.GetEnumerator()) {
            if ($text -match $entry.Value -and -not $claudeFeatures.Contains($entry.Key)) {
                $claudeFeatures.Add($entry.Key)
            }
        }
        foreach ($entry in $codexPatterns.GetEnumerator()) {
            if (($text -match $entry.Value -or ($file.FullName -match $entry.Value)) -and -not $codexFeatures.Contains($entry.Key)) {
                $codexFeatures.Add($entry.Key)
            }
        }
        foreach ($entry in $reasonixPatterns.GetEnumerator()) {
            if (($text -match $entry.Value -or ($file.FullName -match $entry.Value)) -and -not $reasonixFeatures.Contains($entry.Key)) {
                $reasonixFeatures.Add($entry.Key)
            }
        }
        foreach ($entry in $localPathPatterns.GetEnumerator()) {
            if ($text -match $entry.Value) {
                $localPaths.Add([pscustomobject] @{ File = $relative; Rule = $entry.Key; Severity = 'medium' })
            }
        }

        $lineNumber = 0
        foreach ($line in ($text -split "`r?`n")) {
            $lineNumber++
            if ($line -match '#\s*scan-ok\b') {
                continue
            }
            foreach ($entry in $secretPatterns.GetEnumerator()) {
                if ($line -notmatch $entry.Value) {
                    continue
                }
                if ($entry.Key -eq 'Bearer token' -and $line -match 'Bearer\s+\$\{[A-Za-z_][A-Za-z0-9_]*\}') {
                    continue
                }
                if ($line -match '(?i)\b\w+_env_var\s*=\s*["''][A-Za-z_][A-Za-z0-9_]*["'']') {
                    continue
                }
                if ($entry.Key -eq 'Literal secret assignment' -and $line -match '[:=]\s*["'']\$\{[A-Za-z_][A-Za-z0-9_]*\}["'']') {
                    continue
                }
                if ($entry.Key -eq 'Literal secret assignment' -and $line -match '[:=]\s*["''][A-Z][A-Z0-9_]{2,}["'']') {
                    continue
                }
                $secretFindings.Add([pscustomobject] @{
                    File = $relative
                    Line = $lineNumber
                    Rule = $entry.Key
                    Severity = 'high'
                })
            }
        }
    }

    return [pscustomobject] @{
        ClaudeFeatures = @($claudeFeatures | Sort-Object -Unique)
        CodexFeatures = @($codexFeatures | Sort-Object -Unique)
        ReasonixFeatures = @($reasonixFeatures | Sort-Object -Unique)
        LocalPathFindings = @($localPaths)
        SecretFindings = @($secretFindings)
        BinaryFindings = @($binaryFindings)
    }
}

function Get-SkillRecord {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SkillPath,
        [Parameter(Mandatory)] [string] $SourceTool,
        [Parameter(Mandatory)] [string] $MachineId,
        [Parameter(Mandatory)] [string] $Collection,
        [string] $PreferredPlatform = ''
    )

    $frontMatter = Get-SkillFrontMatter -SkillPath $SkillPath
    $skillMd = Join-Path $SkillPath 'SKILL.md'
    $files = @(Get-ChildItem -LiteralPath $SkillPath -File -Recurse -Force -ErrorAction SilentlyContinue)
    $signals = Get-SkillSignals -RepoRoot $RepoRoot -SkillPath $SkillPath
    $dirName = Split-Path -Leaf $SkillPath
    $skillName = Get-SkillName -SkillPath $SkillPath
    $qualityScore = Get-SkillQualityScore -SkillPath $SkillPath -Signals $signals
    $classification = Get-SkillClassification -Signals $signals -PreferredPlatform $PreferredPlatform
    $scanStatus = Get-SkillScanStatus -SkillPath $SkillPath -Signals $signals
    $platformSignals = [pscustomobject] @{
        claude = @($signals.ClaudeFeatures)
        codex = @($signals.CodexFeatures)
    }

    return [pscustomobject] @{
        source_tool = $SourceTool
        machine_id = $MachineId
        collection = $Collection
        source_path = Get-PortableSkillPath -RepoRoot $RepoRoot -Path $SkillPath
        resolved_source_path = $SkillPath
        repo_relative_path = Get-RelativeDisplayPath -Root $RepoRoot -Path $SkillPath
        skill_dir_name = $dirName
        normalized_name = $skillName
        frontmatter_name = $frontMatter.Name
        frontmatter_description = $frontMatter.Description
        has_skill_md = Test-Path -LiteralPath $skillMd
        file_count = $files.Count
        total_size = [int64] (($files | Measure-Object -Property Length -Sum).Sum ?? 0)
        sha256_of_skill_md = Get-FileSha256 -Path $skillMd
        sha256_tree_hash = Get-TreeHash -Path $SkillPath
        possible_platform_specific_features = @($signals.ClaudeFeatures + $signals.CodexFeatures + $signals.ReasonixFeatures | Sort-Object -Unique)
        platform_signals = $platformSignals
        possible_secret_findings = @($signals.SecretFindings)
        possible_local_path_findings = @($signals.LocalPathFindings)
        possible_binary_findings = @($signals.BinaryFindings)
        scan_status = $scanStatus
        modified_time_utc = 'not-collected'
        modified_time_source = 'not-collected'
        classification = $classification
        quality_score = $qualityScore
    }
}

function Get-SkillScanStatus {
    param(
        [Parameter(Mandatory)] [string] $SkillPath,
        [Parameter(Mandatory)] [object] $Signals
    )

    $skillMd = Join-Path $SkillPath 'SKILL.md'
    if (-not (Test-Path -LiteralPath $skillMd) -or (Get-Item -LiteralPath $skillMd).Length -eq 0) {
        return 'failed-missing-entrypoint'
    }
    if (@($Signals.SecretFindings).Count -gt 0) {
        return 'quarantine-secret'
    }
    if (@($Signals.BinaryFindings).Count -gt 0) {
        return 'quarantine-binary-or-large-file'
    }
    if (@($Signals.LocalPathFindings).Count -gt 0) {
        return 'review-required-path'
    }
    if (@($Signals.ClaudeFeatures).Count -gt 0 -and @($Signals.CodexFeatures).Count -gt 0) {
        return 'quarantine-platform-conflict'
    }
    return 'passed'
}

function ConvertTo-SafeSkillRecord {
    param(
        [Parameter(Mandatory)] [object] $Record
    )

    return [pscustomobject] [ordered] @{
        source_tool = $Record.source_tool
        machine_id = $Record.machine_id
        collection = $Record.collection
        source_path = $Record.source_path
        repo_relative_path = $Record.repo_relative_path
        skill_dir_name = $Record.skill_dir_name
        normalized_name = $Record.normalized_name
        frontmatter_name = $Record.frontmatter_name
        frontmatter_description = $Record.frontmatter_description
        has_skill_md = $Record.has_skill_md
        file_count = $Record.file_count
        total_size = $Record.total_size
        sha256_of_skill_md = $Record.sha256_of_skill_md
        sha256_tree_hash = $Record.sha256_tree_hash
        possible_platform_specific_features = @($Record.possible_platform_specific_features)
        platform_signals = $Record.platform_signals
        possible_secret_findings = @($Record.possible_secret_findings)
        possible_local_path_findings = @($Record.possible_local_path_findings)
        possible_binary_findings = @($Record.possible_binary_findings)
        scan_status = $Record.scan_status
        modified_time_utc = $Record.modified_time_utc
        modified_time_source = $Record.modified_time_source
        classification = $Record.classification
        quality_score = $Record.quality_score
    }
}

function Get-SkillQualityScore {
    param(
        [Parameter(Mandatory)] [string] $SkillPath,
        [Parameter(Mandatory)] [object] $Signals
    )

    $score = 50
    $frontMatter = Get-SkillFrontMatter -SkillPath $SkillPath
    if ($frontMatter.Name) { $score += 10 }
    if ($frontMatter.Description) {
        $score += 15
        if ($frontMatter.Description.Length -le 180) { $score += 5 }
    }
    if ($frontMatter.Body -match '(?im)^##\s+Steps') { $score += 10 }
    if ($frontMatter.Body -match '(?im)^##\s+Output') { $score += 5 }
    if (Test-Path -LiteralPath (Join-Path $SkillPath 'references')) { $score += 5 }
    if (Test-Path -LiteralPath (Join-Path $SkillPath 'scripts')) { $score += 5 }
    if (@($Signals.SecretFindings).Count -gt 0) { $score -= 40 }
    if (@($Signals.BinaryFindings).Count -gt 0) { $score -= 15 }
    if (@($Signals.LocalPathFindings).Count -gt 0) { $score -= 5 }
    if ($score -lt 0) { return 0 }
    if ($score -gt 100) { return 100 }
    return $score
}

function Get-SkillClassification {
    param(
        [Parameter(Mandatory)] [object] $Signals,
        [string] $PreferredPlatform = ''
    )

    if (@($Signals.SecretFindings).Count -gt 0) {
        return 'quarantine'
    }
    if (@($Signals.BinaryFindings).Count -gt 0) {
        return 'quarantine'
    }

    $hasClaude = @($Signals.ClaudeFeatures).Count -gt 0
    $hasCodex = @($Signals.CodexFeatures).Count -gt 0
    $hasReasonix = @($Signals.ReasonixFeatures).Count -gt 0
    if ($hasClaude -and $hasCodex) {
        return 'quarantine'
    }
    if (($hasReasonix -and ($hasClaude -or $hasCodex)) -or
        ($PreferredPlatform -eq 'reasonix-only' -and ($hasClaude -or $hasCodex))) {
        return 'quarantine'
    }
    if ($hasClaude) {
        return 'claude-only'
    }
    if ($hasCodex) {
        return 'codex-only'
    }
    if ($hasReasonix) {
        return 'reasonix-only'
    }
    return 'shared'
}

function Convert-LocalPathsToPortable {
    param(
        [Parameter(Mandatory)] [string] $Text
    )

    $rewrites = [System.Collections.Generic.List[object]]::new()
    $result = $Text
    $patterns = @(
        @{ Regex = 'C:\\Users\\[^\\\s"''\)]+'; Replacement = '$HOME'; Rule = 'Windows user path' },
        @{ Regex = 'C:/Users/[^/\s"''\)]+'; Replacement = '$HOME'; Rule = 'Windows user path slash' },
        @{ Regex = '%USERPROFILE%'; Replacement = '$HOME'; Rule = 'USERPROFILE percent' },
        @{ Regex = '\$env:USERPROFILE'; Replacement = '$HOME'; Rule = 'USERPROFILE env' },
        @{ Regex = '/home/[^/\s"''\)]+'; Replacement = '$HOME'; Rule = 'Unix home path' }
    )
    foreach ($pattern in $patterns) {
        if ($result -match $pattern.Regex) {
            $rewrites.Add([pscustomobject] @{ Rule = $pattern.Rule; Replacement = $pattern.Replacement })
            $result = [regex]::Replace($result, $pattern.Regex, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $pattern.Replacement })
        }
    }

    return [pscustomobject] @{
        Text = $result
        Rewrites = @($rewrites)
    }
}

function Normalize-SkillDirectory {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $InputSkillPath,
        [Parameter(Mandatory)] [string] $OutputSkillPath,
        [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'reasonix-only')] [string] $TargetType
    )

    Assert-PathUnderRoot -Root $RepoRoot -Path $OutputSkillPath
    if (-not (Test-Path -LiteralPath (Join-Path $InputSkillPath 'SKILL.md'))) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'missing-skill-md'; Rewrites = @() }
    }

    $signals = Get-SkillSignals -RepoRoot $RepoRoot -SkillPath $InputSkillPath
    if (@($signals.SecretFindings).Count -gt 0) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'possible-secret'; Rewrites = @() }
    }
    if (@($signals.BinaryFindings).Count -gt 0) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'binary-or-large-file'; Rewrites = @() }
    }
    if (@($signals.ClaudeFeatures).Count -gt 0 -and @($signals.CodexFeatures).Count -gt 0) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'platform-conflict'; Rewrites = @() }
    }
    if ($TargetType -eq 'shared' -and (@($signals.ClaudeFeatures).Count -gt 0 -or @($signals.CodexFeatures).Count -gt 0)) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'platform-incompatible'; Rewrites = @() }
    }
    if ($TargetType -eq 'claude-only' -and (@($signals.CodexFeatures).Count -gt 0)) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'platform-incompatible'; Rewrites = @() }
    }
    if ($TargetType -eq 'codex-only' -and (@($signals.ClaudeFeatures).Count -gt 0)) {
        return [pscustomobject] @{ Status = 'quarantine'; Reason = 'platform-incompatible'; Rewrites = @() }
    }
    if ($TargetType -eq 'reasonix-only' -and (@($signals.ClaudeFeatures).Count -gt 0 -or @($signals.CodexFeatures).Count -gt 0)) {
        Remove-Item -LiteralPath $OutputSkillPath -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputSkillPath) | Out-Null
    Copy-Item -LiteralPath $InputSkillPath -Destination $OutputSkillPath -Recurse

    $allRewrites = [System.Collections.Generic.List[object]]::new()
    $files = @(Get-ChildItem -LiteralPath $OutputSkillPath -File -Recurse -Force)
    foreach ($file in $files) {
        if (Test-LikelyBinaryFile -File $file) {
            continue
        }
        $text = Get-TextFileContent -Path $file.FullName
        $rewriteResult = Convert-LocalPathsToPortable -Text $text
        if ($rewriteResult.Rewrites.Count -gt 0) {
            Write-Utf8NoBomFile -Path $file.FullName -Content $rewriteResult.Text
            foreach ($rewrite in $rewriteResult.Rewrites) {
                $allRewrites.Add([pscustomobject] @{
                    File = Get-RelativeDisplayPath -Root $RepoRoot -Path $file.FullName
                    Rule = $rewrite.Rule
                    Replacement = $rewrite.Replacement
                })
            }
        }
    }

    $skillMd = Join-Path $OutputSkillPath 'SKILL.md'
    $frontMatter = Get-SkillFrontMatter -SkillPath $OutputSkillPath
    $name = ConvertTo-KebabName -Name (Split-Path -Leaf $OutputSkillPath)
    $description = $frontMatter.Description
    if ([string]::IsNullOrWhiteSpace($description)) {
        $description = "Use for $name workflows."
    }
    $description = ($description -replace '\s+', ' ').Trim()
    if ($description.Length -gt 180) {
        $description = $description.Substring(0, 177).TrimEnd() + '...'
    }

    $body = $frontMatter.Body.TrimStart()
    if ([string]::IsNullOrWhiteSpace($body)) {
        $title = ($name -split '-' | ForEach-Object { if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) } }) -join ' '
        $body = "# $title`n`n## Purpose`n`n$description`n"
    }

    $frontMatterLines = [System.Collections.Generic.List[string]]::new()
    $frontMatterLines.Add('---')
    $frontMatterLines.Add("name: $name")
    $frontMatterLines.Add("description: $description")
    if ($TargetType -ne 'shared') {
        foreach ($entry in $frontMatter.Fields.GetEnumerator()) {
            if ($entry.Key -in @('name', 'description')) {
                continue
            }
            $frontMatterLines.Add("$($entry.Key): $($entry.Value)")
        }
    }
    $frontMatterLines.Add('---')
    $newSkillMd = ($frontMatterLines -join "`n") + "`n`n" + $body.TrimEnd() + "`n"
    Write-Utf8NoBomFile -Path $skillMd -Content $newSkillMd

    return [pscustomobject] @{ Status = 'merged'; Reason = ''; Rewrites = @($allRewrites) }
}

function Copy-SkillToArchive {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $ArchiveRelativePath
    )

    $target = Join-RepoPath -RepoRoot $RepoRoot -RelativePath $ArchiveRelativePath
    Assert-PathUnderRoot -Root $RepoRoot -Path $target
    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $SourcePath -Destination $target -Recurse
    return $target
}
