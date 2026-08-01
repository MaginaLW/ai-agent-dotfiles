#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('manual', 'post-merge', 'post-checkout', 'post-rewrite')]
    [string] $Trigger = 'manual',
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $OldRev,
    [string] $NewRev,
    [string] $CheckoutFlag,
    [string] $RewriteCommand,
    [string] $RevisionFile,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$relevantPathspecs = @(
    'skills-source',
    'manifests/managed-skills.txt',
    'openclaw/plugins/managed-plugins.json',
    'scripts/build-skills.ps1',
    'scripts/sync.ps1',
    'scripts/sync-openclaw-plugins.ps1',
    'scripts/scan-secrets.ps1',
    'scripts/backup.ps1',
    'scripts/auto-sync-after-git.ps1',
    '.agent-harness/task-skills.psd1',
    'scripts/task-skills.ps1',
    'scripts/activate-harness-env.ps1',
    'scripts/build-harness-env.ps1',
    'scripts/harness-env-common.ps1'
)
$taskOverlayPathspec = '.agent-harness/task-skills.psd1'

function Invoke-Git {
    param([Parameter(Mandatory)] [string[]] $Arguments)
    return & git -C $RepoRoot @Arguments
}

function Get-GitDir {
    $gitDir = Invoke-Git -Arguments @('rev-parse', '--git-dir')
    if ($LASTEXITCODE -ne 0 -or -not $gitDir) {
        throw "Unable to resolve .git directory for RepoRoot: $RepoRoot"
    }

    $gitDir = ($gitDir | Select-Object -First 1).Trim()
    if ([System.IO.Path]::IsPathRooted($gitDir)) {
        return [System.IO.Path]::GetFullPath($gitDir)
    }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $gitDir))
}

$gitDirPath = Get-GitDir
$stateDir = Join-Path $gitDirPath 'ai-agent-dotfiles'
New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
$logPath = Join-Path $stateDir 'auto-sync.log'
$lockPath = Join-Path $stateDir 'auto-sync.lock'

function Write-AutoSyncLog {
    param([Parameter(Mandatory)] [object] $Message)

    $text = [string] $Message
    $line = "[{0}] {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $text
    Add-Content -LiteralPath $logPath -Value $line -Encoding utf8
    Write-Host $text
}

function Test-RelevantDiff {
    param(
        [Parameter(Mandatory)] [string] $FromRev,
        [Parameter(Mandatory)] [string] $ToRev
    )

    if (-not $FromRev -or -not $ToRev -or $FromRev -eq $ToRev) {
        return $false
    }

    $changed = Invoke-Git -Arguments (@('diff', '--name-only', $FromRev, $ToRev, '--') + $relevantPathspecs)
    if ($LASTEXITCODE -ne 0) {
        Write-AutoSyncLog "Could not diff $FromRev..$ToRev; running sync defensively."
        return $true
    }

    return @($changed | Where-Object { $_ }).Count -gt 0
}

function Test-TaskOverlayDiff {
    param(
        [Parameter(Mandatory)] [string] $FromRev,
        [Parameter(Mandatory)] [string] $ToRev
    )

    if (-not $FromRev -or -not $ToRev -or $FromRev -eq $ToRev) {
        return $false
    }
    $changed = Invoke-Git -Arguments @('diff', '--name-only', $FromRev, $ToRev, '--', $taskOverlayPathspec)
    if ($LASTEXITCODE -ne 0) {
        return $false
    }
    return @($changed | Where-Object { ([string] $_).Trim() -eq $taskOverlayPathspec }).Count -gt 0
}

function Test-TaskOverlayChangedForTrigger {
    if ($Force -or $Trigger -eq 'manual') {
        return $false
    }

    switch ($Trigger) {
        'post-checkout' {
            if ($CheckoutFlag -ne '1') { return $false }
            return Test-TaskOverlayDiff -FromRev $OldRev -ToRev $NewRev
        }
        'post-merge' {
            $origHead = Invoke-Git -Arguments @('rev-parse', '--verify', 'ORIG_HEAD')
            $origHeadCode = $LASTEXITCODE
            $head = Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD')
            $headCode = $LASTEXITCODE
            if ($origHeadCode -ne 0 -or $headCode -ne 0 -or -not $origHead -or -not $head) { return $false }
            return Test-TaskOverlayDiff -FromRev (($origHead | Select-Object -First 1).Trim()) -ToRev (($head | Select-Object -First 1).Trim())
        }
        'post-rewrite' {
            if (-not $RevisionFile -or -not (Test-Path -LiteralPath $RevisionFile)) { return $false }
            foreach ($line in [System.IO.File]::ReadLines($RevisionFile)) {
                $parts = @($line -split '\s+' | Where-Object { $_ })
                if ($parts.Count -ge 2 -and (Test-TaskOverlayDiff -FromRev $parts[0] -ToRev $parts[1])) {
                    return $true
                }
            }
            return $false
        }
    }
    return $false
}

function Get-ShouldRunSync {
    if ($Force) {
        Write-AutoSyncLog 'Force was requested; auto-sync will run.'
        return $true
    }

    switch ($Trigger) {
        'manual' {
            return $true
        }
        'post-checkout' {
            if ($CheckoutFlag -ne '1') {
                Write-AutoSyncLog 'post-checkout was for paths, not a branch switch; skipping auto-sync.'
                return $false
            }
            return Test-RelevantDiff -FromRev $OldRev -ToRev $NewRev
        }
        'post-merge' {
            $origHead = Invoke-Git -Arguments @('rev-parse', '--verify', 'ORIG_HEAD')
            $origHeadCode = $LASTEXITCODE
            $head = Invoke-Git -Arguments @('rev-parse', '--verify', 'HEAD')
            $headCode = $LASTEXITCODE
            if ($origHeadCode -ne 0 -or $headCode -ne 0 -or -not $origHead -or -not $head) {
                Write-AutoSyncLog 'Could not resolve ORIG_HEAD/HEAD after merge; running sync defensively.'
                return $true
            }
            return Test-RelevantDiff -FromRev (($origHead | Select-Object -First 1).Trim()) -ToRev (($head | Select-Object -First 1).Trim())
        }
        'post-rewrite' {
            if (-not $RevisionFile -or -not (Test-Path -LiteralPath $RevisionFile)) {
                Write-AutoSyncLog 'No post-rewrite revision file was provided; running sync defensively.'
                return $true
            }

            foreach ($line in [System.IO.File]::ReadLines($RevisionFile)) {
                $parts = @($line -split '\s+' | Where-Object { $_ })
                if ($parts.Count -ge 2 -and (Test-RelevantDiff -FromRev $parts[0] -ToRev $parts[1])) {
                    return $true
                }
            }
            return $false
        }
    }
}

function Invoke-AutoSync {
    $syncScript = Join-Path $RepoRoot 'scripts/sync.ps1'
    if (-not (Test-Path -LiteralPath $syncScript)) {
        throw "Missing sync script: $syncScript"
    }

    $planPath = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-auto-sync-$([Guid]::NewGuid().ToString('N')).json"
    Write-AutoSyncLog "Running sync.ps1 -DryRun with a bound plan from $Trigger."
    $dryOutput = & pwsh -NoProfile -ExecutionPolicy Bypass -File $syncScript -DryRun -PlanPath $planPath -RepoRoot $RepoRoot 2>&1
    $dryCode = $LASTEXITCODE
    $dryOutput | ForEach-Object { Write-AutoSyncLog $_ }
    if ($dryCode -ne 0) {
        Write-AutoSyncLog "sync.ps1 -DryRun failed with exit code $dryCode; no apply attempted."
        exit $dryCode
    }

    Write-AutoSyncLog 'Running sync.ps1 -Apply with the exact dry-run plan.'
    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $syncScript -Apply -PlanPath $planPath -RepoRoot $RepoRoot 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-AutoSyncLog $_ }
    if ($exitCode -ne 0) {
        Write-AutoSyncLog "sync.ps1 -Apply failed with exit code $exitCode. Plan retained at $planPath."
        exit $exitCode
    }
    Remove-Item -LiteralPath $planPath -Force -ErrorAction SilentlyContinue
    Write-AutoSyncLog 'sync.ps1 -Apply completed.'
}

function Invoke-TaskOverlayAutoSync {
    $taskScript = Join-Path $RepoRoot 'scripts/task-skills.ps1'
    if (-not (Test-Path -LiteralPath $taskScript -PathType Leaf)) {
        throw "Missing task skill script: $taskScript"
    }

    Write-AutoSyncLog 'Task overlay changed; routing through addition-only env task sync.'
    $output = & pwsh -NoProfile -ExecutionPolicy Bypass -File $taskScript -Action sync -Apply -Automatic -RepoRoot $RepoRoot 2>&1
    $exitCode = $LASTEXITCODE
    $output | ForEach-Object { Write-AutoSyncLog $_ }
    if ($exitCode -ne 0) {
        Write-AutoSyncLog "Addition-only task sync failed with exit code $exitCode. No fallback full-root apply attempted."
        exit $exitCode
    }
    Write-AutoSyncLog 'Addition-only task sync completed or safely skipped.'
}

$lockStream = $null
$acquiredLock = $false
try {
    if (Test-Path -LiteralPath $lockPath) {
        $lockAge = (Get-Date) - (Get-Item -LiteralPath $lockPath).LastWriteTime
        if ($lockAge.TotalHours -ge 2) {
            Remove-Item -LiteralPath $lockPath -Force
        }
    }

    try {
        $lockStream = [System.IO.File]::Open($lockPath, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        $acquiredLock = $true
    }
    catch [System.IO.IOException] {
        Write-AutoSyncLog 'Auto-sync is already running; skipping this hook invocation.'
        exit 0
    }

    Write-AutoSyncLog "Hook trigger: $Trigger"
    if ($RewriteCommand) {
        Write-AutoSyncLog "Rewrite command: $RewriteCommand"
    }

    if (Get-ShouldRunSync) {
        if (Test-TaskOverlayChangedForTrigger) {
            Invoke-TaskOverlayAutoSync
        }
        else {
            Invoke-AutoSync
        }
    }
    else {
        Write-AutoSyncLog 'No relevant skill-management changes detected; skipping auto-sync.'
    }
}
finally {
    if ($lockStream) {
        $lockStream.Dispose()
    }
    if ($acquiredLock -and (Test-Path -LiteralPath $lockPath)) {
        Remove-Item -LiteralPath $lockPath -Force
    }
}
