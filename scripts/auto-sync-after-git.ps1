#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('manual', 'pre-commit', 'post-merge', 'post-checkout', 'post-rewrite')]
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
. (Join-Path $PSScriptRoot 'approved-runner-common.ps1')

function Exit-Diagnostic {
    param([Parameter(Mandatory)] [string] $Token, [Parameter(Mandatory)] [string] $Detail, [int] $Code = 72)
    [Console]::Error.WriteLine("${Token}: $Detail")
    exit $Code
}

function Get-RelevantChanges {
    param([Parameter(Mandatory)] $Policy)
    $pathspecs = @($Policy.DataPathspecs) + @($Policy.ToolchainPaths)
    $from = $null; $to = $null
    switch ($Trigger) {
        'post-checkout' { if ($CheckoutFlag -ne '1') { return @() }; $from=$OldRev; $to=$NewRev }
        'post-merge' {
            $from = ((& git -C $RepoRoot rev-parse --verify ORIG_HEAD 2>$null) | Select-Object -First 1)
            $to = ((& git -C $RepoRoot rev-parse --verify HEAD 2>$null) | Select-Object -First 1)
        }
        'post-rewrite' {
            if (-not $RevisionFile -or -not (Test-Path -LiteralPath $RevisionFile -PathType Leaf)) { return @('__defensive__') }
            $all = [System.Collections.Generic.List[string]]::new()
            foreach ($line in [System.IO.File]::ReadLines($RevisionFile)) {
                $parts = @($line -split '\s+' | Where-Object { $_ })
                if ($parts.Count -lt 2) { continue }
                $all.AddRange([string[]]@(& git -C $RepoRoot diff --name-only $parts[0] $parts[1] -- @pathspecs))
            }
            return @($all | Where-Object { $_ } | Sort-Object -Unique)
        }
        default { return @('__manual__') }
    }
    if ([string]::IsNullOrWhiteSpace([string]$from) -or [string]::IsNullOrWhiteSpace([string]$to)) { return @('__defensive__') }
    return @(& git -C $RepoRoot diff --name-only ([string]$from).Trim() ([string]$to).Trim() -- @pathspecs | Where-Object { $_ } | Sort-Object -Unique)
}

try {
    $RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $state = Get-ApprovedRunnerState -RepoRoot $RepoRoot
    $executingRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    if ($executingRoot -cne (Resolve-Path -LiteralPath ([string]$state.RunnerRoot)).Path) { Exit-Diagnostic -Token 'runner-review-required' -Detail 'checkout or unapproved runner code was selected.' }

    $probe = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-runner-check-$([Guid]::NewGuid().ToString('N'))"
    try { $current = Get-RunnerPolicySnapshot -RepoRoot $RepoRoot -DestinationRoot $probe -BindingCommit ([string]$state.ApprovedCommit) -ToolCacheRoot ([string]$state.ToolCacheRoot) }
    finally { if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Recurse -Force } }
    if ([string]$current.ToolchainPolicyHash -cne [string]$state.ToolchainPolicyHash -or [string]$current.RunnerTreeHash -cne [string]$state.RunnerTreeHash -or [string]$current.ValidatorIdentityHash -cne [string]$state.ValidatorIdentityHash -or [string]$current.ScannerIdentityHash -cne [string]$state.ScannerIdentityHash) {
        Exit-Diagnostic -Token 'runner-review-required' -Detail 'checkout toolchain differs from the explicitly approved runner.'
    }

    if ($Trigger -eq 'pre-commit') {
        & pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $executingRoot 'scripts/scan-secrets.ps1') -RepoRoot $RepoRoot
        exit $LASTEXITCODE
    }
    if ($Trigger -eq 'manual' -or $Force) { Exit-Diagnostic -Token 'safety-protocol-upgrade-required' -Detail 'Phase 0 automation is preview-only and canonical routing is not released.' -Code 73 }

    $policy = Get-RunnerPolicy -RepoRoot $RepoRoot
    $changed = @(Get-RelevantChanges -Policy $policy)
    if ($changed.Count -eq 0) { Write-Host 'No policy-relevant changes; preview not created.'; exit 0 }
    $head = ((& git -C $RepoRoot rev-parse HEAD) | Select-Object -First 1).Trim()
    $contextHash = Get-SemanticJsonHash -InputObject ([ordered]@{ Trigger=$Trigger; Commit=$head; Changed=@($changed) })
    $contentHashes = @($changed | ForEach-Object { Get-SemanticJsonHash -InputObject ([ordered]@{ Path=[string]$_; Commit=$head }) } | Sort-Object -Unique)
    $command = 'pwsh -NoProfile -File scripts/agent-dotfiles.ps1 sync -DryRun -PlanPath <external-user-artifact>'
    $event = [ordered]@{
        SchemaVersion = 1; ArtifactKind = 'pending-sync-event'; EventKind = 'preview'; WorktreeNamespace = $context.WorktreeId
        Trigger = $Trigger; ApprovedToolchainHash = [string]$state.ToolchainPolicyHash; CurrentToolchainHash = [string]$current.ToolchainPolicyHash
        Commit = $head; ContextHash = $contextHash; PreviewStatus = 'non-consumable'; RedactedContext = "changed-count=$($changed.Count)"
        ContentHashes = $contentHashes; ExternalDryRunCommand = $command
    }
    $path = Write-DeduplicatedPendingEvent -StorageContext $context -Document $event
    Write-Host 'pending-preview-only: a non-consumable Git-private event was recorded.'
    Write-Host "Preview event: $path"
    Write-Host "External actionable plan requires an explicit command: $command"
    exit 0
}
catch {
    $message = $_.Exception.Message
    if ($message -match 'json-schema-validator') { Exit-Diagnostic -Token 'validator-install-required' -Detail $message -Code 70 }
    if ($message -match 'secret-scanner|gitleaks') { Exit-Diagnostic -Token 'scanner-install-required' -Detail $message -Code 71 }
    if ($message -match 'working-tree-review-required') { Exit-Diagnostic -Token 'working-tree-review-required' -Detail $message -Code 74 }
    Exit-Diagnostic -Token 'runner-review-required' -Detail $message
}
