#requires -Version 7.0

Set-StrictMode -Version Latest

function ConvertTo-ReportSafeText {
    param([AllowNull()] [object] $Value)

    if ($null -eq $Value) {
        return 'Not available'
    }

    $text = [string] $Value
    $text = (($text -replace "`r`n", ' ') -replace "`r|`n", ' ').Trim()
    if (-not $text) {
        return 'Not available'
    }

    $redactions = @(
        'sk-ant-[A-Za-z0-9_-]{20,}',
        'sk-(proj-)?[A-Za-z0-9_-]{20,}',
        'ghp_[A-Za-z0-9]{36}',
        'github_pat_[A-Za-z0-9_]{22,}',
        'xox[bpars]-[A-Za-z0-9-]{10,}',
        'Bearer\s+[A-Za-z0-9._-]{20,}',
        '-----BEGIN (RSA|OPENSSH|EC) PRIVATE KEY-----'
    )
    foreach ($pattern in $redactions) {
        $text = [regex]::Replace($text, $pattern, '[REDACTED]', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    }

    $text = $text.Replace('|', '\|')
    return ($text -replace '`', "'")
}

function Get-ReportGitMetadata {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $branch = 'Not available'
    $commit = 'Not available'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $branchOutput = & $git.Source -C $RepoRoot branch --show-current 2>$null
        if ($LASTEXITCODE -eq 0 -and $branchOutput) {
            $branch = ($branchOutput -join '').Trim()
        }
        $commitOutput = & $git.Source -C $RepoRoot rev-parse HEAD 2>$null
        if ($LASTEXITCODE -eq 0 -and $commitOutput) {
            $commit = ($commitOutput -join '').Trim()
        }
    }

    return [pscustomobject] @{
        Branch = ConvertTo-ReportSafeText -Value $branch
        Commit = ConvertTo-ReportSafeText -Value $commit
    }
}

function New-RunReportPath {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [ValidateSet('build', 'sync')] [string] $ReportKind,
        [Parameter(Mandatory)] [string] $Mode,
        [Parameter(Mandatory)] [datetime] $Timestamp
    )

    $reportsRoot = Join-Path $RepoRoot 'reports'
    if (-not (Test-Path -LiteralPath $reportsRoot)) {
        New-Item -ItemType Directory -Force -Path $reportsRoot | Out-Null
    }

    $stamp = $Timestamp.ToString('yyyy-MM-dd-HHmmss')
    if ($ReportKind -eq 'build') {
        $fileName = "build-report-$stamp.md"
    }
    else {
        $machine = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Environment]::MachineName }
        $safeMachine = (($machine -replace '[^A-Za-z0-9._-]', '-') -replace '-+', '-').Trim('-')
        if (-not $safeMachine) { $safeMachine = 'unknown-machine' }
        $safeMode = (($Mode -replace '[^A-Za-z0-9._-]', '-') -replace '-+', '-').Trim('-')
        if (-not $safeMode) { $safeMode = 'unknown-mode' }
        $fileName = "sync-report-$safeMachine-$safeMode-$stamp.md"
    }

    $path = Join-Path $reportsRoot $fileName
    $suffix = 2
    while (Test-Path -LiteralPath $path) {
        $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
        $path = Join-Path $reportsRoot "$base-$suffix.md"
        $suffix++
    }
    return $path
}

function Write-RunReport {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [ValidateSet('build', 'sync')] [string] $ReportKind,
        [Parameter(Mandatory)] [string] $ScriptName,
        [Parameter(Mandatory)] [string] $Mode,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Summary,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Details,
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [string] $NextAction
    )

    $timestamp = Get-Date
    $gitMetadata = Get-ReportGitMetadata -RepoRoot $RepoRoot
    $computerName = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Environment]::MachineName }
    $path = New-RunReportPath -RepoRoot $RepoRoot -ReportKind $ReportKind -Mode $Mode -Timestamp $timestamp

    $title = if ($ReportKind -eq 'build') { 'Build Report' } else { 'Sync Report' }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("# $title")
    $lines.Add('')
    $lines.Add('## Metadata')
    $lines.Add('')
    $lines.Add("- timestamp: $(ConvertTo-ReportSafeText -Value $timestamp.ToString('o'))")
    $lines.Add("- computername: $(ConvertTo-ReportSafeText -Value $computerName)")
    $lines.Add("- git branch: $(ConvertTo-ReportSafeText -Value $gitMetadata.Branch)")
    $lines.Add("- git commit: $(ConvertTo-ReportSafeText -Value $gitMetadata.Commit)")
    $lines.Add("- script name: $(ConvertTo-ReportSafeText -Value $ScriptName)")
    $lines.Add("- mode: $(ConvertTo-ReportSafeText -Value $Mode)")
    $lines.Add('')
    $lines.Add('## Summary')
    $lines.Add('')
    $lines.Add('| Field | Value |')
    $lines.Add('|---|---:|')
    foreach ($key in $Summary.Keys) {
        $lines.Add("| $(ConvertTo-ReportSafeText -Value $key) | $(ConvertTo-ReportSafeText -Value $Summary[$key]) |")
    }
    $lines.Add('')
    $lines.Add('## Details')
    foreach ($section in $Details.Keys) {
        $lines.Add('')
        $lines.Add("### $(ConvertTo-ReportSafeText -Value $section)")
        $items = @($Details[$section])
        if ($items.Count -eq 0) {
            $lines.Add('')
            $lines.Add('- None')
        }
        else {
            $lines.Add('')
            foreach ($item in $items) {
                $lines.Add("- $(ConvertTo-ReportSafeText -Value $item)")
            }
        }
    }
    $lines.Add('')
    $lines.Add('## Result')
    $lines.Add('')
    $lines.Add("- status: **$(ConvertTo-ReportSafeText -Value $Result)**")
    $lines.Add("- next suggested action: $(ConvertTo-ReportSafeText -Value $NextAction)")
    $lines.Add('')

    [System.IO.File]::WriteAllText($path, ($lines -join "`n"), [System.Text.UTF8Encoding]::new($false))
    return $path
}
