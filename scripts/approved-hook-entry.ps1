#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [ValidateSet('manual', 'pre-commit', 'post-merge', 'post-checkout', 'post-rewrite')] [string] $Trigger,
    [string] $OldRev,
    [string] $NewRev,
    [string] $CheckoutFlag,
    [string] $RewriteCommand,
    [string] $RevisionFile,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Fail-RunnerReview { param([string] $Detail) [Console]::Error.WriteLine("runner-review-required: $Detail"); exit 72 }
function Is-Inside { param([string] $Path, [string] $Root) $p=[IO.Path]::GetFullPath($Path).TrimEnd([char]92,[char]47); $r=[IO.Path]::GetFullPath($Root).TrimEnd([char]92,[char]47); return $p.Equals($r,[StringComparison]::OrdinalIgnoreCase) -or $p.StartsWith($r+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase) }

try {
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $common = ((& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null) | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0) { Fail-RunnerReview 'Git common directory is unavailable.' }
    $private = Join-Path ([IO.Path]::GetFullPath($common)) 'ai-agent-dotfiles'
    $statePath = Join-Path $private 'approved-runner-state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { Fail-RunnerReview 'approved state is missing.' }
    $state = [IO.File]::ReadAllText($statePath, [Text.UTF8Encoding]::new($false, $true)) | ConvertFrom-Json
    $required = @('SchemaVersion','ArtifactKind','ApprovedCommit','ToolchainPolicyHash','RunnerTreeHash','RunnerRoot','RunnerEntryPath','RunnerFiles','ApprovalEventPath','ApprovalEventHash','ValidatorIdentityHash','ScannerIdentityHash','ToolCacheRoot','GitCommonDirHash','PointerGeneration')
    $actual = @($state.PSObject.Properties.Name | Sort-Object)
    if (@(Compare-Object ($required | Sort-Object) $actual).Count -ne 0 -or [long]$state.SchemaVersion -ne 1 -or [string]$state.ArtifactKind -cne 'approved-runner-state') { Fail-RunnerReview 'approved state shape is invalid.' }
    $runnerRoot = [IO.Path]::GetFullPath([string]$state.RunnerRoot)
    $approvedRoot = Join-Path $private 'r'
    if (-not (Is-Inside -Path $runnerRoot -Root $approvedRoot)) { Fail-RunnerReview 'runner root is outside the approved namespace.' }
    $entry = [IO.Path]::GetFullPath([string]$state.RunnerEntryPath)
    if ($entry -cne [IO.Path]::GetFullPath((Join-Path $runnerRoot 'scripts/auto-sync-after-git.ps1'))) { Fail-RunnerReview 'runner entry path is invalid.' }
    $expected = @{}
    foreach ($row in @($state.RunnerFiles)) {
        $relative = ([string]$row.RelativePath).Replace('/',[IO.Path]::DirectorySeparatorChar)
        if ([IO.Path]::IsPathRooted($relative) -or @($relative -split '[\\/]' | Where-Object { $_ -in @('', '.', '..') }).Count -gt 0) { Fail-RunnerReview 'runner manifest path is invalid.' }
        if ($expected.ContainsKey($relative)) { Fail-RunnerReview 'runner manifest contains a duplicate path.' }
        $expected[$relative] = $row
    }
    $queue = [Collections.Generic.Queue[string]]::new(); $queue.Enqueue($runnerRoot)
    $seen = @{}
    while ($queue.Count -gt 0) {
        $directory = $queue.Dequeue()
        foreach ($path in [IO.Directory]::EnumerateFileSystemEntries($directory)) {
            $attributes = [IO.File]::GetAttributes($path)
            if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Fail-RunnerReview 'runner tree contains a reparse entry.' }
            if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) { $queue.Enqueue($path); continue }
            $relative = [IO.Path]::GetRelativePath($runnerRoot, $path)
            if (-not $expected.ContainsKey($relative)) { Fail-RunnerReview "runner tree contains an unapproved file: $relative" }
            $row = $expected[$relative]
            $item = Get-Item -LiteralPath $path
            $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([long]$row.Length -ne [long]$item.Length -or [string]$row.Sha256 -cne $hash) { Fail-RunnerReview "runner file drifted: $relative" }
            $seen[$relative] = $true
        }
    }
    if ($seen.Count -ne $expected.Count) { Fail-RunnerReview 'runner tree is incomplete.' }

    $arguments = @('-RepoRoot',$repo,'-Trigger',$Trigger)
    foreach ($pair in @(@('OldRev',$OldRev),@('NewRev',$NewRev),@('CheckoutFlag',$CheckoutFlag),@('RewriteCommand',$RewriteCommand),@('RevisionFile',$RevisionFile))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$pair[1])) { $arguments += @("-$($pair[0])", [string]$pair[1]) }
    }
    if ($Force) { $arguments += '-Force' }
    & pwsh -NoProfile -ExecutionPolicy Bypass -File $entry @arguments
    exit $LASTEXITCODE
}
catch { Fail-RunnerReview $_.Exception.Message }
