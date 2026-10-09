#requires -Version 7.0
<#
.SYNOPSIS
    Runs the repository validation gates in order and stops at the first failure.

.DESCRIPTION
    Gates: powershell-syntax, gitleaks-verify, build-skills, secret-scan,
    doctor (isolated temp HomeRoot, -SkipSecretsScan), generated-manifests-parity,
    run-tests -All, dangerous-tracked-files, clean-tracked-state.
    CI runs it on a clean checkout. Locally the last gate fails on a dirty tree.
#>
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$work = Join-Path ([IO.Path]::GetTempPath()) ('repository-validation-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
# The four protected Reasonix files stay out of every porcelain check.
$policyPaths = @('.') + @('auto-title-meta', 'created-at', 'title-sources', 'titles' | ForEach-Object { ":(exclude).reasonix/desktop-topic-$_.json" })

function Invoke-Gate([string] $Name, [scriptblock] $Body) {
    Write-Host "== $Name"
    $started = Get-Date
    & $Body
    Write-Host ("== $Name PASS ({0:n1}s)" -f ((Get-Date) - $started).TotalSeconds)
}

function Invoke-RepoScript([string] $Script, [string[]] $Arguments = @()) {
    & pwsh -NoProfile -File (Join-Path $RepoRoot "scripts/$Script") @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Script failed with exit code $LASTEXITCODE" }
}

function Get-GitLines([string[]] $Arguments) {
    $lines = @(& git -C $RepoRoot @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed with exit code $LASTEXITCODE" }
    return $lines
}

try {
    Invoke-Gate 'powershell-syntax' { Invoke-RepoScript 'check-powershell-syntax.ps1' @('-RepoRoot', $RepoRoot) }
    Invoke-Gate 'gitleaks-verify' { Invoke-RepoScript 'install-gitleaks.ps1' @('-VerifyOnly') }
    Invoke-Gate 'build-skills' { Invoke-RepoScript 'build-skills.ps1' @('-RepoRoot', $RepoRoot) }
    Invoke-Gate 'secret-scan' { Invoke-RepoScript 'scan-secrets.ps1' @('-RepoRoot', $RepoRoot) }
    Invoke-Gate 'doctor' {
        $isolatedHome = Join-Path $work 'doctor-home'
        New-Item -ItemType Directory -Path $isolatedHome -Force | Out-Null
        Invoke-RepoScript 'doctor.ps1' @('-RepoRoot', $RepoRoot, '-HomeRoot', $isolatedHome, '-SkipSecretsScan')
    }
    Invoke-Gate 'generated-manifests-parity' {
        $changed = @(Get-GitLines @('status', '--porcelain', '--', 'manifests'))
        if ($changed.Count) { $changed | Write-Host; throw 'build-skills changed manifests/. Rebuild locally and commit the intended manifest changes.' }
        $trackedGenerated = @(Get-GitLines @('ls-files', '--', 'claude/skills', 'codex/skills', 'reasonix/skills', 'envs'))
        if ($trackedGenerated.Count) { $trackedGenerated | Write-Host; throw 'Generated output must remain untracked.' }
    }
    Invoke-Gate 'run-tests' { Invoke-RepoScript 'run-tests.ps1' @('-All', '-JsonSummaryPath', (Join-Path $work 'test-summary.json'), '-RepoRoot', $RepoRoot) }
    Invoke-Gate 'dangerous-tracked-files' {
        $violations = @(Get-GitLines @('ls-files') | Where-Object {
            $path = $_ -replace '\\', '/'
            $leaf = [IO.Path]::GetFileName($path)
            $leaf -match '(?i)\.(pem|key|p12|pfx)$' -or
            $leaf -match '(?i)^id_(rsa|ed25519)$' -or
            $leaf -match '(?i)^\.env(?:\..+)?$' -or
            $leaf -match '(?i)^\.?tokens?(?:\.(txt|json|ya?ml))?$' -or
            $leaf -match '(?i)\.tokens?$' -or
            $leaf -match '(?i)^(auth|\.credentials)\.json$' -or
            $path -match '(?i)(^|/)(backup|backups)(/|$)' -or
            $path -match '(?i)(^|/)\.ssh(/|$)'
        })
        if ($violations.Count) {
            $violations | Sort-Object -Unique | ForEach-Object { Write-Host "Forbidden tracked file: $_" }
            throw 'Dangerous files are tracked. Remove them from Git history and rotate exposed credentials if necessary.'
        }
    }
    Invoke-Gate 'clean-tracked-state' {
        $dirty = @(Get-GitLines (@('status', '--porcelain', '--') + $policyPaths))
        if ($dirty.Count) { $dirty | ForEach-Object { Write-Host "Dirty tracked/non-ignored state: $_" }; throw 'The working tree is not clean after validation.' }
    }
    Write-Host 'Repository validation: PASS'
}
catch {
    Write-Host "Repository validation: FAIL: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
