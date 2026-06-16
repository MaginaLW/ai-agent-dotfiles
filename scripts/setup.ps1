#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Alias('InstallHook')]
    [switch] $InstallPreCommit,
    [switch] $InstallAutoSync,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path $RepoRoot).Path
$git = Get-Command git -ErrorAction SilentlyContinue
if (-not $git) {
    throw 'git was not found on PATH.'
}

Push-Location $RepoRoot
try {
    git rev-parse --is-inside-work-tree *> $null
    if ($LASTEXITCODE -ne 0) {
        throw "RepoRoot is not inside a Git repository: $RepoRoot"
    }

    $executionPolicy = Get-ExecutionPolicy -Scope CurrentUser
    $gitleaks = Get-Command gitleaks -ErrorAction SilentlyContinue
    $gitattributesPath = Join-Path $RepoRoot '.gitattributes'
    $scanScript = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    $hooksDir = Join-Path $RepoRoot '.git/hooks'
    $hookPath = Join-Path $hooksDir 'pre-commit'
    $autoSyncScript = Join-Path $RepoRoot 'scripts/auto-sync-after-git.ps1'

    function Write-GitHook {
        param(
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [string] $Content
        )

        $path = Join-Path $hooksDir $Name
        $hookContent = $Content.TrimEnd("`r", "`n") + "`n"
        [System.IO.File]::WriteAllText($path, $hookContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Git hook installed: $path"
    }

    Write-Host "PowerShell: $($PSVersionTable.PSVersion)"
    Write-Host "Git: $(git --version)"
    Write-Host "ExecutionPolicy(CurrentUser): $executionPolicy"

    if ($executionPolicy -in @('Restricted', 'Undefined')) {
        Write-Host 'If script execution is blocked, run: Set-ExecutionPolicy -Scope CurrentUser RemoteSigned'
    }

    if ($gitleaks) {
        Write-Host "gitleaks: $($gitleaks.Source)"
    }
    else {
        Write-Host 'gitleaks: not found. Install from https://github.com/gitleaks/gitleaks or place gitleaks.exe on PATH.'
    }

    if (-not (Test-Path -LiteralPath $gitattributesPath)) {
        throw '.gitattributes is missing.'
    }
    Write-Host '.gitattributes: present. If line endings were changed, run git add --renormalize . after review.'

    if (-not (Test-Path -LiteralPath $scanScript)) {
        throw 'scripts/scan-secrets.ps1 is missing.'
    }
    if (-not (Test-Path -LiteralPath $autoSyncScript)) {
        throw 'scripts/auto-sync-after-git.ps1 is missing.'
    }

    if ($InstallPreCommit) {
        Write-Host 'A pre-commit hook will run scripts/scan-secrets.ps1 before local commits.'
        if (-not $Force) {
            $answer = Read-Host 'Type YES to install or replace .git/hooks/pre-commit'
            if ($answer -ne 'YES') {
                Write-Host 'Pre-commit hook installation skipped.'
                return
            }
        }

        $hook = @'
#!/bin/sh
pwsh -NoProfile -ExecutionPolicy Bypass -File "$PWD/scripts/scan-secrets.ps1" -RepoRoot "$PWD"
'@
        Write-GitHook -Name 'pre-commit' -Content $hook
    }
    else {
        Write-Host "Pre-commit hook prepared but not installed. Re-run with -InstallPreCommit to request confirmation."
        if (Test-Path -LiteralPath $hookPath) {
            Write-Host "Existing pre-commit hook found: $hookPath"
        }
    }

    if ($InstallAutoSync) {
        Write-Host 'Auto-sync hooks will run scripts/sync.ps1 -Apply after relevant Git updates.'
        if (-not $Force) {
            $answer = Read-Host 'Type YES to install or replace .git/hooks/post-merge, post-checkout, and post-rewrite'
            if ($answer -ne 'YES') {
                Write-Host 'Auto-sync hook installation skipped.'
                return
            }
        }

        $postMerge = @'
#!/bin/sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
pwsh -NoProfile -ExecutionPolicy Bypass -File "$repo_root/scripts/auto-sync-after-git.ps1" -RepoRoot "$repo_root" -Trigger post-merge
'@
        $postCheckout = @'
#!/bin/sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
pwsh -NoProfile -ExecutionPolicy Bypass -File "$repo_root/scripts/auto-sync-after-git.ps1" -RepoRoot "$repo_root" -Trigger post-checkout -OldRev "$1" -NewRev "$2" -CheckoutFlag "$3"
'@
        $postRewrite = @'
#!/bin/sh
repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
git_dir="$(git rev-parse --git-dir 2>/dev/null)" || exit 0
state_dir="$git_dir/ai-agent-dotfiles"
mkdir -p "$state_dir"
revision_file="$state_dir/post-rewrite-revs"
cat > "$revision_file"
pwsh -NoProfile -ExecutionPolicy Bypass -File "$repo_root/scripts/auto-sync-after-git.ps1" -RepoRoot "$repo_root" -Trigger post-rewrite -RewriteCommand "$1" -RevisionFile "$revision_file"
'@

        Write-GitHook -Name 'post-merge' -Content $postMerge
        Write-GitHook -Name 'post-checkout' -Content $postCheckout
        Write-GitHook -Name 'post-rewrite' -Content $postRewrite
    }
    else {
        Write-Host 'Auto-sync hooks prepared but not installed. Re-run with -InstallAutoSync to request confirmation.'
        foreach ($name in @('post-merge', 'post-checkout', 'post-rewrite')) {
            $path = Join-Path $hooksDir $name
            if (Test-Path -LiteralPath $path) {
                Write-Host "Existing Git hook found: $path"
            }
        }
    }
}
finally {
    Pop-Location
}
