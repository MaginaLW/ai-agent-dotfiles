#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$ProfileRoot,
    [Parameter(Mandatory)][string]$RoamingAppDataRoot,
    [Parameter(Mandatory)][string]$LocalAppDataRoot,
    [Parameter(Mandatory)][ValidateSet('bootstrap-hold','complete-hold','global-hold','global-once','global-wait','crash-complete','canonical-global-hold')][string]$Operation,
    [string]$IntentPath,
    [string]$RepoRoot,
    [string]$ReadyMarker,
    [string]$StartMarker,
    [string]$AcquiredMarker,
    [string]$ContendedMarker,
    [string]$ReleaseMarker,
    [string]$ExpectedWorkingDirectory,
    [ValidateRange(1,300)][int]$WaitSeconds = 3,
    [ValidateSet('before','after')][string]$CrashStage = 'after',
    [ValidateRange(0,6)][int]$CrashOrder = 0
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $ToolchainRoot 'scripts/home-authority-common.ps1')
. (Join-Path $ToolchainRoot 'tests/helpers/home-authority-test-host.ps1')

function Write-HostMarker {
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Value)
    $full = [IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { throw 'host marker parent is missing' }
    $stream = [IO.File]::Open($full,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Value)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Wait-HostMarker {
    param([Parameter(Mandatory)][string]$Path)
    while (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { Start-Sleep -Milliseconds 10 }
}

function Read-HostIntent {
    if ([string]::IsNullOrWhiteSpace($IntentPath)) { throw 'host intent path is required' }
    $bytes = [IO.File]::ReadAllBytes([IO.Path]::GetFullPath($IntentPath))
    return ([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json -AsHashtable -Depth 100)
}

function Wait-WithHeldLock {
    param([Parameter(Mandatory)]$Lock)
    try {
        if ($AcquiredMarker) { Write-HostMarker -Path $AcquiredMarker -Value ([string]$Lock.Info.Identity) }
        if ($ReleaseMarker) { Wait-HostMarker -Path $ReleaseMarker }
        else { while ($true) { Start-Sleep -Milliseconds 100 } }
    }
    finally { Exit-HomeAuthorityLockHandle -LockHandle $Lock }
}

try {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $context = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $ProfileRoot -RoamingAppDataRoot $RoamingAppDataRoot -LocalAppDataRoot $LocalAppDataRoot
    $intent = $null
    if ($Operation -in @('bootstrap-hold','complete-hold','crash-complete')) {
        $intent = Read-HostIntent
        $null = Assert-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -Intent $intent
    }
    $readyValue = 'ready'
    if ($ExpectedWorkingDirectory) {
        $expectedCwd = [IO.Path]::GetFullPath($ExpectedWorkingDirectory).TrimEnd([char]92,[char]47)
        $actualCwd = [IO.Path]::GetFullPath((Get-Location).Path).TrimEnd([char]92,[char]47)
        if (-not $actualCwd.Equals($expectedCwd,[StringComparison]::OrdinalIgnoreCase)) { throw 'host working directory mismatch' }
        $gitDir = ((& git -C $actualCwd rev-parse --path-format=absolute --absolute-git-dir 2>$null) | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]$gitDir)) { throw 'host repository identity unavailable' }
        $readyValue = "ready|$([string]$intent.IntentHash)|$([string]$intent.InitialBootstrapStatus)|$([long]$intent.InitialCompletePrefixLength)|$([IO.Path]::GetFullPath(([string]$gitDir).Trim()))"
    }
    if ($ReadyMarker) { Write-HostMarker -Path $ReadyMarker -Value $readyValue }
    if ($StartMarker) { Wait-HostMarker -Path $StartMarker }

    switch ($Operation) {
        'bootstrap-hold' {
            $lock = Enter-SealedHomeAuthorityBootstrapLock -AuthorityContext $context -Intent $intent
            Wait-WithHeldLock -Lock $lock
        }
        'complete-hold' {
            $lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $intent
            Wait-WithHeldLock -Lock $lock
        }
        'global-hold' {
            $lock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $context
            Wait-WithHeldLock -Lock $lock
        }
        'canonical-global-hold' {
            if ([string]::IsNullOrWhiteSpace($RepoRoot)) { throw 'canonical-global-hold requires -RepoRoot' }
            . (Join-Path $ToolchainRoot 'scripts/canonical-transaction-common.ps1')
            $repoFull = [IO.Path]::GetFullPath($RepoRoot)
            $git = Get-CanonicalGitContext -RepoRoot $repoFull
            $paths = Get-CanonicalTransactionContractPaths -GitContext $git
            $canonicalLock = Enter-CanonicalRepoLock -LockPath ([string]$paths.LockPath)
            $witness = $null
            try {
                $witness = Open-CanonicalHeldNamespaceWitness -RepoRoot $repoFull -CanonicalLockHandle $canonicalLock -ToolchainRoot $ToolchainRoot
                $lock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $context -RequiredCanonicalWitness $witness
                try {
                    if ($AcquiredMarker) { Write-HostMarker -Path $AcquiredMarker -Value ([string]$lock.Info.Identity) }
                    if ($ReleaseMarker) { Wait-HostMarker -Path $ReleaseMarker }
                    else { while ($true) { Start-Sleep -Milliseconds 100 } }
                }
                finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
            }
            finally {
                if ($null -ne $witness) { Close-CanonicalHeldNamespaceWitness -Witness $witness }
                Exit-CanonicalRepoLock -LockHandle $canonicalLock
            }
        }
        'global-once' {
            $lock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $context
            try { if ($AcquiredMarker) { Write-HostMarker -Path $AcquiredMarker -Value ([string]$lock.Info.Identity) } }
            finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
        }
        'global-wait' {
            $waitLimitMilliseconds = [long]$WaitSeconds * 1000L
            $waitWatch = [Diagnostics.Stopwatch]::StartNew()
            $lock = $null
            $contended = $false
            while ($null -eq $lock) {
                if ($contended -and $waitWatch.ElapsedMilliseconds -ge $waitLimitMilliseconds) { throw 'operation-lock-busy' }
                $candidate = $null
                try { $candidate = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $context }
                catch {
                    if ($_.Exception.Message -cne 'operation-lock-busy') { throw }
                    if (-not $contended -and $ContendedMarker) { Write-HostMarker -Path $ContendedMarker -Value 'operation-lock-busy'; $contended=$true }
                    if ($waitWatch.ElapsedMilliseconds -ge $waitLimitMilliseconds) { throw }
                    Start-Sleep -Milliseconds 10
                    continue
                }
                if ($waitWatch.ElapsedMilliseconds -ge $waitLimitMilliseconds) {
                    Exit-HomeAuthorityGlobalLiveLock -LockHandle $candidate
                    throw 'operation-lock-busy'
                }
                $lock = $candidate
            }
            try { if ($AcquiredMarker) { Write-HostMarker -Path $AcquiredMarker -Value ([string]$lock.Info.Identity) } }
            finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
        }
        'crash-complete' {
            $checkpoint = {
                param($Entry)
                if ([long]$Entry.Order -eq $CrashOrder) {
                    if ($AcquiredMarker) { Write-HostMarker -Path $AcquiredMarker -Value ("$CrashStage/$CrashOrder") }
                    while ($true) { Start-Sleep -Milliseconds 100 }
                }
            }
            $arguments = @{ AuthorityContext=$context; Intent=$intent }
            if ($CrashStage -ceq 'before') { $arguments.BeforeCreate = $checkpoint } else { $arguments.AfterCreate = $checkpoint }
            $lock = Complete-SealedHomeAuthorityBootstrap @arguments
            try { }
            finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
        }
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
