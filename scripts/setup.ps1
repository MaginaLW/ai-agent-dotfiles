#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [switch] $ApproveRunner,
    [switch] $InstallPreCommit,
    [switch] $InstallAutoSync
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not $ApproveRunner) { throw 'runner-review-required: explicit -ApproveRunner is required.' }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'approved-runner-common.ps1')

# Phase 3 Task 8: explicit setup pins the selection-aware preview routing
# contract, not just the toolchain bytes. The approved runner never self-approves
# this table: a checkout whose route table differs from the frozen authority
# route set is refused here, and after approval any toolchain drift — including
# this file or the route table — fails the hooks closed with
# runner-review-required until a new explicit approval.
. (Join-Path $PSScriptRoot 'harness-env-common.ps1')
$policy = Get-RunnerPolicy -RepoRoot $RepoRoot
$routeTable = $policy.PreviewRouteActions
if ($routeTable -isnot [System.Collections.IDictionary] -or @($routeTable.Keys).Count -eq 0) {
    throw 'runner-review-required: runner policy carries no preview route table.'
}
$authorityRoutes = @($script:HarnessEnvAuthorityRouteNextOperation.Keys | Sort-Object { [string] $_ })
$policyRoutes = @($routeTable.Keys | Sort-Object { [string] $_ })
if (@(Compare-Object $authorityRoutes $policyRoutes).Count -ne 0) {
    throw 'runner-review-required: the preview route table does not match the frozen authority route set.'
}
foreach ($route in $policyRoutes) {
    $row = $routeTable[$route]
    $action = if ($row -is [System.Collections.IDictionary] -and $row.Contains('Action')) { [string] $row['Action'] } else { $null }
    $command = if ($row -is [System.Collections.IDictionary] -and $row.Contains('Command')) { [string] $row['Command'] } else { $null }
    $expectedAction = if ([string] $script:HarnessEnvAuthorityRouteNextOperation[$route] -clike 'env activate*') { 'environment-preview' } else { 'diagnostic' }
    if ($action -cne $expectedAction -or [string]::IsNullOrWhiteSpace($command)) {
        throw "runner-review-required: preview route action for '$route' is not a pinned row."
    }
}

$state = Approve-RunnerSnapshot -RepoRoot $RepoRoot
$entry = Publish-ApprovedHookEntry -RepoRoot $RepoRoot -State $state
$hooksRoot = ((& git -C $RepoRoot rev-parse --path-format=absolute --git-path hooks 2>$null) | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Git hooks directory.' }
[System.IO.Directory]::CreateDirectory($hooksRoot) | Out-Null

function Write-PinnedHook {
    param([Parameter(Mandatory)] [string] $Name, [Parameter(Mandatory)] [string] $Body)
    $path = Join-Path $hooksRoot $Name
    [System.IO.File]::WriteAllText($path, $Body.TrimEnd("`r","`n")+"`n", [System.Text.UTF8Encoding]::new($false))
    Write-Host "Pinned Git hook installed: $path"
}

if ($InstallPreCommit) {
    $body = @"
#!/bin/sh
repo_root="`$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
pwsh -NoProfile -ExecutionPolicy Bypass -File "$entry" -RepoRoot "`$repo_root" -Trigger pre-commit
"@
    Write-PinnedHook -Name 'pre-commit' -Body $body
}
if ($InstallAutoSync) {
    $postMerge = @"
#!/bin/sh
repo_root="`$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
pwsh -NoProfile -ExecutionPolicy Bypass -File "$entry" -RepoRoot "`$repo_root" -Trigger post-merge
"@
    $postCheckout = @"
#!/bin/sh
repo_root="`$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
pwsh -NoProfile -ExecutionPolicy Bypass -File "$entry" -RepoRoot "`$repo_root" -Trigger post-checkout -OldRev "`$1" -NewRev "`$2" -CheckoutFlag "`$3"
"@
    $postRewrite = @"
#!/bin/sh
repo_root="`$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0
git_dir="`$(git rev-parse --git-dir 2>/dev/null)" || exit 0
revision_file="`$git_dir/ai-agent-dotfiles/post-rewrite-revs"
mkdir -p "`$(dirname "`$revision_file")"
cat > "`$revision_file"
pwsh -NoProfile -ExecutionPolicy Bypass -File "$entry" -RepoRoot "`$repo_root" -Trigger post-rewrite -RewriteCommand "`$1" -RevisionFile "`$revision_file"
"@
    Write-PinnedHook -Name 'post-merge' -Body $postMerge
    Write-PinnedHook -Name 'post-checkout' -Body $postCheckout
    Write-PinnedHook -Name 'post-rewrite' -Body $postRewrite
}

Write-Host "Runner approved: $($state.ToolchainPolicyHash)"
Write-Host "Approved commit: $($state.ApprovedCommit)"
