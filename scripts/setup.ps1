#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Alias('InstallHook')]
    [switch] $InstallPreCommit
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
    $hookPath = Join-Path $RepoRoot '.git/hooks/pre-commit'

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

    if ($InstallPreCommit) {
        Write-Host 'A pre-commit hook will run scripts/scan-secrets.ps1 before local commits.'
        $answer = Read-Host 'Type YES to install or replace .git/hooks/pre-commit'
        if ($answer -ne 'YES') {
            Write-Host 'Pre-commit hook installation skipped.'
            return
        }

        $hook = @'
#!/bin/sh
pwsh -NoProfile -ExecutionPolicy Bypass -File "$PWD/scripts/scan-secrets.ps1" -RepoRoot "$PWD"
'@
        $hookContent = $hook.TrimEnd("`r", "`n") + "`n"
        [System.IO.File]::WriteAllText($hookPath, $hookContent, [System.Text.UTF8Encoding]::new($false))
        Write-Host "Pre-commit hook installed: $hookPath"
    }
    else {
        Write-Host "Pre-commit hook prepared but not installed. Re-run with -InstallPreCommit to request confirmation."
        if (Test-Path -LiteralPath $hookPath) {
            Write-Host "Existing pre-commit hook found: $hookPath"
        }
    }
}
finally {
    Pop-Location
}
