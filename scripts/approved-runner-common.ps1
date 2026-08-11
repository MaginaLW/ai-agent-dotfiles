#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ApprovedRunnerAuthorityRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'semantic-json.ps1')
. (Join-Path $PSScriptRoot 'scan-input-common.ps1')
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')

function Get-LowerSha256Text {
    param([Parameter(Mandatory)] [string] $Text)
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Get-LowerSha256File {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PrivateRunnerAcl {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)
    $acl = Get-Acl -LiteralPath $Path
    foreach ($rule in @($acl.Access)) {
        $identity = [string] $rule.IdentityReference
        $broad = $identity -in @('Everyone','WORLD\Everyone','S-1-1-0') -or $identity.EndsWith('\Everyone', [StringComparison]::OrdinalIgnoreCase)
        $writeRights = ([System.Security.AccessControl.FileSystemRights] $rule.FileSystemRights) -band ([System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl)
        if ($broad -and $rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Allow -and $writeRights -ne 0) { throw "Git-private runner namespace grants broad write access: $Path" }
    }
}

function Get-RunnerStorageContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [switch] $EnsureDirectories)

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $gitDir = ((& git -C $repo rev-parse --path-format=absolute --absolute-git-dir 2>$null) | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($gitDir)) { throw "Unable to resolve GitDir for $repo" }
    $commonDir = ((& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null) | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($commonDir)) { throw "Unable to resolve GitCommonDir for $repo" }
    $perWorktree = ((& git -C $repo rev-parse --path-format=absolute --git-path ai-agent-dotfiles 2>$null) | Select-Object -First 1)
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($perWorktree)) { throw "Unable to resolve per-worktree private root for $repo" }

    $gitDir = [System.IO.Path]::GetFullPath(([string] $gitDir).Trim())
    $commonDir = [System.IO.Path]::GetFullPath(([string] $commonDir).Trim())
    $perWorktree = [System.IO.Path]::GetFullPath(([string] $perWorktree).Trim())
    $commonPrivate = Join-Path $commonDir 'ai-agent-dotfiles'
    $context = [pscustomobject][ordered]@{
        RepoRoot = $repo
        GitDir = $gitDir
        GitCommonDir = $commonDir
        GitCommonDirHash = Get-LowerSha256Text -Text $commonDir.ToLowerInvariant()
        WorktreeId = Get-LowerSha256Text -Text $gitDir.ToLowerInvariant()
        CommonPrivateRoot = $commonPrivate
        WorktreePrivateRoot = $perWorktree
        PendingLockPath = Join-Path $commonPrivate 'pending.lock'
        PendingEventsRoot = Join-Path $perWorktree 'pending/events'
        PendingPreviewsRoot = Join-Path $perWorktree 'pending/previews'
        RetiredRoot = Join-Path $perWorktree 'retired'
        ApprovalEventsRoot = Join-Path $commonPrivate 'approval-events'
        ApprovedRunnersRoot = Join-Path $commonPrivate 'r'
        ApprovedStatePath = Join-Path $commonPrivate 'approved-runner-state.json'
        ApprovedHookEntryPath = Join-Path $commonPrivate 'approved-hook-entry.ps1'
    }
    if ($EnsureDirectories) {
        foreach ($path in @($context.CommonPrivateRoot, $context.WorktreePrivateRoot, $context.PendingEventsRoot, $context.PendingPreviewsRoot, $context.RetiredRoot, $context.ApprovalEventsRoot, $context.ApprovedRunnersRoot)) {
            [System.IO.Directory]::CreateDirectory($path) | Out-Null
            Assert-NoReparseExistingChain -Path $path
            Assert-PrivateRunnerAcl -Path $path
        }
    }
    return $context
}

function Invoke-WithPendingLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $StorageContext, [Parameter(Mandatory)] [scriptblock] $Action, [int] $WaitSeconds = 10)

    [System.IO.Directory]::CreateDirectory($StorageContext.CommonPrivateRoot) | Out-Null
    Assert-NoReparseExistingChain -Path $StorageContext.CommonPrivateRoot
    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    $stream = $null
    do {
        try {
            $stream = [System.IO.File]::Open($StorageContext.PendingLockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            break
        }
        catch [System.IO.IOException] {
            if ([DateTime]::UtcNow -ge $deadline) { throw 'pending-storage-lock-timeout' }
            Start-Sleep -Milliseconds 50
        }
    } while ($true)
    try { return & $Action }
    finally { $stream.Dispose() }
}

function Get-ArtifactSchemaPath {
    param([Parameter(Mandatory)] [string] $ArtifactKind)
    $name = switch ($ArtifactKind) {
        'pending-sync-event' { 'pending-sync-event.schema.json' }
        'runner-approval-event' { 'runner-approval-event.schema.json' }
        'approved-runner-state' { 'approved-runner-state.schema.json' }
        'committed-data-snapshot-manifest' { 'committed-data-snapshot-manifest.schema.json' }
        'pending-prune-plan' { 'pending-prune-plan.schema.json' }
        default { throw "Unsupported runner artifact kind: $ArtifactKind" }
    }
    return Join-Path $script:ApprovedRunnerAuthorityRoot "schemas/$name"
}

function Assert-RunnerArtifactValid {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $ArtifactKind)
    Invoke-FixedJsonSchemaValidation -SchemaPath (Get-ArtifactSchemaPath -ArtifactKind $ArtifactKind) -InstancePath $Path | Out-Null
}

function Write-ImmutableRunnerArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Prefix,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [DateTimeOffset] $TimestampUtc = [DateTimeOffset]::UtcNow,
        [string] $ArtifactId = ([Guid]::NewGuid().ToString('N'))
    )

    if ($ArtifactId -cnotmatch '^[0-9a-f]{32}$') { throw 'ArtifactId must be 32 lowercase hexadecimal characters.' }
    [System.IO.Directory]::CreateDirectory($Directory) | Out-Null
    Assert-NoReparseExistingChain -Path $Directory
    $name = '{0}-{1}-{2}.json' -f $Prefix, $TimestampUtc.UtcDateTime.ToString('yyyyMMddTHHmmssfffZ'), $ArtifactId
    $path = Join-Path $Directory $name
    try {
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    }
    catch [System.IO.IOException] { throw "Immutable artifact collision; target already exists: $path" }
    try {
        $bytes = ConvertTo-SemanticJsonBytes -InputObject $Document
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    try { Assert-RunnerArtifactValid -Path $path -ArtifactKind ([string] $Document.ArtifactKind) }
    catch { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; throw }
    return $path
}

function Get-PendingRegistrySnapshotHash {
    param([Parameter(Mandatory)] $StorageContext)
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($root in @($StorageContext.PendingEventsRoot, $StorageContext.PendingPreviewsRoot)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File | Sort-Object FullName)) {
            $rows.Add([ordered]@{ Path = $file.FullName; ContentHash = Get-LowerSha256File -Path $file.FullName })
        }
    }
    return Get-SemanticJsonHash -InputObject @($rows)
}

function Assert-PendingArtifactPath {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $StorageContext)
    $full = [System.IO.Path]::GetFullPath($Path)
    $allowed = (Test-PathInsideRoot -Path $full -Root $StorageContext.PendingEventsRoot) -or (Test-PathInsideRoot -Path $full -Root $StorageContext.PendingPreviewsRoot)
    if (-not $allowed) { throw "Pending artifact is outside the current worktree namespace: $full" }
    Resolve-PrivateArtifactPath -Path $full -Role InternalContractPath -RepoRoot $StorageContext.RepoRoot -InternalRoot $StorageContext.WorktreePrivateRoot | Out-Null
    return $full
}

function New-PendingPrunePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string[]] $ArtifactPaths, [Parameter(Mandatory)] [string] $PlanPath)

    if ($ArtifactPaths.Count -eq 0) { throw 'At least one exact pending artifact is required.' }
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $context.RepoRoot -ForbiddenRoots @($context.CommonPrivateRoot, $context.WorktreePrivateRoot) -AllowMissingLeaf | Out-Null
    $items = @($ArtifactPaths | ForEach-Object {
        $full = Assert-PendingArtifactPath -Path $_ -StorageContext $context
        [ordered]@{ Path = $full; ContentHash = Get-LowerSha256File -Path $full }
    } | Sort-Object Path)
    $payload = [ordered]@{
        WorktreeNamespace = $context.WorktreeId
        SelectionTimestampUtc = [DateTime]::UtcNow.ToString('o')
        RegistrySnapshotHash = Get-PendingRegistrySnapshotHash -StorageContext $context
        Items = @($items)
    }
    $document = [ordered]@{ SchemaVersion = 1; ArtifactKind = 'pending-prune-plan'; PlanPayload = $payload; PlanHash = Get-PlanHash -PlanPayload $payload }
    $document.DocumentHash = Get-DocumentHash -Document $document
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($PlanPath))
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($PlanPath), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $bytes = ConvertTo-SemanticJsonBytes -InputObject $document; $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    Assert-RunnerArtifactValid -Path $PlanPath -ArtifactKind 'pending-prune-plan'
    return [pscustomobject]$document
}

function Read-PendingPrunePlan {
    param([Parameter(Mandatory)] [string] $PlanPath, [Parameter(Mandatory)] $StorageContext)
    Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $StorageContext.RepoRoot -ForbiddenRoots @($StorageContext.CommonPrivateRoot, $StorageContext.WorktreePrivateRoot) | Out-Null
    Assert-RunnerArtifactValid -Path $PlanPath -ArtifactKind 'pending-prune-plan'
    $document = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($PlanPath, [System.Text.UTF8Encoding]::new($false, $true)))
    if ([string] $document.PlanHash -cne (Get-PlanHash -PlanPayload $document.PlanPayload)) { throw 'Pending prune PlanHash mismatch.' }
    if ([string] $document.DocumentHash -cne (Get-DocumentHash -Document $document)) { throw 'Pending prune DocumentHash mismatch.' }
    if ([string] $document.PlanPayload.WorktreeNamespace -cne $StorageContext.WorktreeId) { throw 'Pending prune plan belongs to another worktree namespace.' }
    return $document
}

function Invoke-PendingPrunePlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $PlanPath)

    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $document = Read-PendingPrunePlan -PlanPath $PlanPath -StorageContext $context
    return Invoke-WithPendingLock -StorageContext $context -Action {
        $current = Read-PendingPrunePlan -PlanPath $PlanPath -StorageContext $context
        foreach ($item in @($current.PlanPayload.Items)) {
            $full = Assert-PendingArtifactPath -Path ([string] $item.Path) -StorageContext $context
            if ((Get-LowerSha256File -Path $full) -cne [string] $item.ContentHash) { throw "Pending artifact drifted after review: $full" }
        }
        $moved = [System.Collections.Generic.List[string]]::new()
        foreach ($item in @($current.PlanPayload.Items)) {
            $full = [System.IO.Path]::GetFullPath([string] $item.Path)
            $destination = Join-Path $context.RetiredRoot ([System.IO.Path]::GetFileName($full))
            if (Test-Path -LiteralPath $destination) { throw "Retired artifact collision: $destination" }
            [System.IO.File]::Move($full, $destination)
            $moved.Add($destination)
        }
        return @($moved)
    }
}

function Write-DeduplicatedPendingEvent {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $StorageContext, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    return Invoke-WithPendingLock -StorageContext $StorageContext -Action {
        if (Test-Path -LiteralPath $StorageContext.PendingEventsRoot -PathType Container) {
            foreach ($file in @(Get-ChildItem -LiteralPath $StorageContext.PendingEventsRoot -File | Sort-Object FullName)) {
                try {
                    Assert-RunnerArtifactValid -Path $file.FullName -ArtifactKind 'pending-sync-event'
                    $existing = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($file.FullName, [System.Text.UTF8Encoding]::new($false, $true)))
                    if ([string]$existing.ContextHash -ceq [string]$Document.ContextHash -and [string]$existing.EventKind -ceq [string]$Document.EventKind) { return $file.FullName }
                }
                catch { throw "Pending namespace contains an invalid registered event: $($file.FullName)" }
            }
        }
        return Write-ImmutableRunnerArtifact -Directory $StorageContext.PendingEventsRoot -Prefix ([string]$Document.EventKind) -Document $Document
    }
}

function Get-RunnerPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $path = Join-Path ([System.IO.Path]::GetFullPath($RepoRoot)) 'scripts/runner-policy.psd1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'runner-review-required: runner policy is missing.' }
    $policy = Import-PowerShellDataFile -LiteralPath $path
    if ([long] $policy.SchemaVersion -ne 1) { throw 'runner-review-required: unsupported runner policy version.' }
    foreach ($field in @('DataPathspecs', 'ToolchainPaths')) { if (-not $policy.ContainsKey($field)) { throw "runner-review-required: policy is missing $field." } }
    return $policy
}

function Assert-RunnerRelevantTreeClean {
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] $Policy, [switch] $IncludeData)
    $paths = @($Policy.ToolchainPaths)
    if ($IncludeData) { $paths += @($Policy.DataPathspecs) }
    $status = @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all -- @paths)
    if ($LASTEXITCODE -ne 0) { throw 'working-tree-review-required: unable to inspect policy paths.' }
    if (@($status | Where-Object { $_ }).Count -gt 0) { throw 'working-tree-review-required: relevant policy or data paths differ from the selected commit.' }
}

function Get-PinnedRunnerToolIdentities {
    param([string] $ToolCacheRoot)
    $resolvedCache = Get-PinnedToolCacheRoot -CacheRoot $ToolCacheRoot
    $validator = Assert-PinnedToolInstalled -LockPath (Join-Path $script:ApprovedRunnerAuthorityRoot 'tools/schema-validator/validator.lock.json') -CacheRoot $resolvedCache
    $scanner = Assert-PinnedToolInstalled -LockPath (Join-Path $script:ApprovedRunnerAuthorityRoot 'tools/gitleaks/gitleaks.lock.json') -CacheRoot $resolvedCache
    return [pscustomobject]@{
        ToolCacheRoot = $resolvedCache
        ValidatorIdentityHash = Get-SemanticJsonHash -InputObject ([ordered]@{ Version = [string] $validator.Lock.Version; ExecutableSha256 = [string] $validator.ExecutableSha256 })
        ScannerIdentityHash = Get-SemanticJsonHash -InputObject ([ordered]@{ Version = [string] $scanner.Lock.Version; ExecutableSha256 = [string] $scanner.ExecutableSha256 })
    }
}

function Get-RunnerPolicySnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $DestinationRoot,
        [string] $BindingCommit,
        [string] $ToolCacheRoot,
        [switch] $RequireCleanData
    )

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $policy = Get-RunnerPolicy -RepoRoot $repo
    Assert-RunnerRelevantTreeClean -RepoRoot $repo -Policy $policy -IncludeData:$RequireCleanData
    $commit = ((& git -C $repo rev-parse HEAD 2>$null) | Select-Object -First 1).Trim()
    if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40,64}$') { throw 'runner-review-required: selected commit is unavailable.' }
    if ([string]::IsNullOrWhiteSpace($BindingCommit)) { $BindingCommit = $commit }
    if ($BindingCommit -cnotmatch '^[0-9a-f]{40,64}$') { throw 'runner-review-required: invalid approval commit binding.' }
    if (Test-Path -LiteralPath $DestinationRoot) { throw "Runner materialization must be create-new: $DestinationRoot" }
    [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null

    $rows = [System.Collections.Generic.List[object]]::new()
    try {
        foreach ($relative in @($policy.ToolchainPaths | Sort-Object -Unique)) {
            $normalized = Normalize-ScanRelativePath -RelativePath ([string] $relative)
            if ($normalized -in (Get-ProtectedReasonixRelativePaths)) { throw 'runner-review-required: policy selects a protected Reasonix path.' }
            $tree = @(& git -C $repo ls-tree $commit -- $normalized)
            if ($LASTEXITCODE -ne 0 -or $tree.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string] $tree[0])) { throw "runner-review-required: policy path is not one committed blob: $normalized" }
            $match = [regex]::Match([string] $tree[0], '^(?<mode>[0-9]{6}) blob (?<oid>[0-9a-f]{40,64})\t(?<path>.+)$')
            if (-not $match.Success -or $match.Groups['mode'].Value -notin @('100644', '100755') -or $match.Groups['path'].Value -cne $normalized) {
                throw "runner-review-required: policy path is a symlink, gitlink, directory, or unexpected entry: $normalized"
            }
            $source = Join-Path $repo $normalized
            Assert-NoFollowDirectoryChain -RepoRoot $repo -FilePath $source
            $before = [AiAgentDotfiles.NoFollowFile]::Inspect($source)
            if ($before.IsDirectory -or $before.IsReparsePoint -or $before.LinkCount -ne 1) { throw "runner-review-required: policy source is not a unique regular file: $normalized" }
            if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($source)).Count -ne 0) { throw "runner-review-required: policy source has named streams: $normalized" }
            $destination = Join-Path $DestinationRoot $normalized
            [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
            $copy = [AiAgentDotfiles.NoFollowFile]::CopyRegularFile($source, $destination)
            $after = [AiAgentDotfiles.NoFollowFile]::Inspect($source)
            if ($after.Identity -cne $before.Identity -or $after.Length -ne $before.Length -or $copy.Identity -cne $before.Identity) { throw "runner-review-required: policy source changed during copy: $normalized" }
            $oid = ((& git -C $repo hash-object "--path=$normalized" -- $destination 2>$null) | Select-Object -First 1).Trim()
            if ($LASTEXITCODE -ne 0 -or $oid -cne $match.Groups['oid'].Value) { throw "working-tree-review-required: policy bytes do not match the selected commit: $normalized" }
            $rows.Add([ordered]@{ RelativePath = $normalized; GitMode = $match.Groups['mode'].Value; GitOid = $oid; Length = [long] $copy.Length; Sha256 = [string] $copy.Sha256 })
        }
        $tools = Get-PinnedRunnerToolIdentities -ToolCacheRoot $ToolCacheRoot
        $runnerTreeHash = Get-SemanticJsonHash -InputObject @($rows)
        $policyHash = Get-SemanticJsonHash -InputObject ([ordered]@{
            PolicyVersion = 1
            BindingCommit = $BindingCommit
            DataPathspecs = @($policy.DataPathspecs | Sort-Object -Unique)
            ToolchainFiles = @($rows)
            ValidatorIdentityHash = $tools.ValidatorIdentityHash
            ScannerIdentityHash = $tools.ScannerIdentityHash
        })
        return [pscustomobject][ordered]@{
            CurrentCommit = $commit
            BindingCommit = $BindingCommit
            ToolchainPolicyHash = $policyHash
            RunnerTreeHash = $runnerTreeHash
            RunnerFiles = @($rows)
            ValidatorIdentityHash = $tools.ValidatorIdentityHash
            ScannerIdentityHash = $tools.ScannerIdentityHash
            ToolCacheRoot = $tools.ToolCacheRoot
            DataPathspecs = @($policy.DataPathspecs | Sort-Object -Unique)
            MaterializationRoot = [System.IO.Path]::GetFullPath($DestinationRoot)
        }
    }
    catch {
        if (Test-Path -LiteralPath $DestinationRoot) { Remove-Item -LiteralPath $DestinationRoot -Recurse -Force }
        throw
    }
}

function Get-ApprovedRunnerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $context.ApprovedStatePath -PathType Leaf)) { throw 'runner-review-required: approved runner state is missing.' }
    Resolve-PrivateArtifactPath -Path $context.ApprovedStatePath -Role InternalContractPath -RepoRoot $context.RepoRoot -InternalRoot $context.CommonPrivateRoot | Out-Null
    Assert-RunnerArtifactValid -Path $context.ApprovedStatePath -ArtifactKind 'approved-runner-state'
    $state = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($context.ApprovedStatePath, [System.Text.UTF8Encoding]::new($false, $true)))
    Resolve-PrivateArtifactPath -Path ([string]$state.ApprovalEventPath) -Role InternalContractPath -RepoRoot $context.RepoRoot -InternalRoot $context.ApprovalEventsRoot | Out-Null
    if ((Get-LowerSha256File -Path ([string]$state.ApprovalEventPath)) -cne [string]$state.ApprovalEventHash) { throw 'runner-review-required: approval event hash mismatch.' }
    Assert-RunnerArtifactValid -Path ([string]$state.ApprovalEventPath) -ArtifactKind 'runner-approval-event'
    $event = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText([string]$state.ApprovalEventPath, [System.Text.UTF8Encoding]::new($false, $true)))
    foreach ($field in @('ApprovedCommit','ToolchainPolicyHash','RunnerTreeHash','ValidatorIdentityHash','ScannerIdentityHash','ToolCacheRoot','GitCommonDirHash','PointerGeneration')) {
        if ([string]$event[$field] -cne [string]$state[$field]) { throw "runner-review-required: approval event/state mismatch for $field." }
    }
    return $state
}

function Write-AtomicRunnerState {
    param([Parameter(Mandatory)] $StorageContext, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    [System.IO.Directory]::CreateDirectory($StorageContext.CommonPrivateRoot) | Out-Null
    $temp = Join-Path $StorageContext.CommonPrivateRoot "approved-runner-state.$([Guid]::NewGuid().ToString('N')).tmp"
    $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try { $bytes = ConvertTo-SemanticJsonBytes -InputObject $Document; $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    try {
        Assert-RunnerArtifactValid -Path $temp -ArtifactKind 'approved-runner-state'
        [System.IO.File]::Move($temp, $StorageContext.ApprovedStatePath, $true)
    }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
}

function Approve-RunnerSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [string] $ToolCacheRoot)
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $candidate = Join-Path $context.ApprovedRunnersRoot ".candidate-$([Guid]::NewGuid().ToString('N'))"
    $snapshot = Get-RunnerPolicySnapshot -RepoRoot $context.RepoRoot -DestinationRoot $candidate -ToolCacheRoot $ToolCacheRoot -RequireCleanData
    $runnerRoot = Join-Path $context.ApprovedRunnersRoot $snapshot.ToolchainPolicyHash.Substring(0, 32)
    if (Test-Path -LiteralPath $runnerRoot) {
        Remove-Item -LiteralPath $candidate -Recurse -Force
    }
    else { [System.IO.Directory]::Move($candidate, $runnerRoot) }
    $generation = 1
    if (Test-Path -LiteralPath $context.ApprovedStatePath -PathType Leaf) {
        try { $generation = [long] (Get-ApprovedRunnerState -RepoRoot $context.RepoRoot).PointerGeneration + 1 } catch { throw 'runner-review-required: existing approved state is invalid.' }
    }
    $event = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'runner-approval-event'
        ApprovedCommit = $snapshot.CurrentCommit
        ToolchainPolicyHash = $snapshot.ToolchainPolicyHash
        RunnerTreeHash = $snapshot.RunnerTreeHash
        ValidatorIdentityHash = $snapshot.ValidatorIdentityHash
        ScannerIdentityHash = $snapshot.ScannerIdentityHash
        ToolCacheRoot = $snapshot.ToolCacheRoot
        GitCommonDirHash = $context.GitCommonDirHash
        WorktreeNamespace = $context.WorktreeId
        PointerGeneration = $generation
    }
    $eventPath = Write-ImmutableRunnerArtifact -Directory $context.ApprovalEventsRoot -Prefix 'runner-approval' -Document $event
    $state = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'approved-runner-state'
        ApprovedCommit = $snapshot.CurrentCommit
        ToolchainPolicyHash = $snapshot.ToolchainPolicyHash
        RunnerTreeHash = $snapshot.RunnerTreeHash
        RunnerRoot = $runnerRoot
        RunnerEntryPath = Join-Path $runnerRoot 'scripts/auto-sync-after-git.ps1'
        RunnerFiles = @($snapshot.RunnerFiles | ForEach-Object { [ordered]@{ RelativePath = $_.RelativePath; Length = $_.Length; Sha256 = $_.Sha256 } })
        ApprovalEventPath = $eventPath
        ApprovalEventHash = Get-LowerSha256File -Path $eventPath
        ValidatorIdentityHash = $snapshot.ValidatorIdentityHash
        ScannerIdentityHash = $snapshot.ScannerIdentityHash
        ToolCacheRoot = $snapshot.ToolCacheRoot
        GitCommonDirHash = $context.GitCommonDirHash
        PointerGeneration = $generation
    }
    Write-AtomicRunnerState -StorageContext $context -Document $state
    return [pscustomobject]$state
}

function Publish-ApprovedHookEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] $State)
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot -EnsureDirectories
    $source = Join-Path ([string] $State.RunnerRoot) 'scripts/approved-hook-entry.ps1'
    $row = @($State.RunnerFiles | Where-Object { [string] $_.RelativePath -ceq 'scripts/approved-hook-entry.ps1' })
    if ($row.Count -ne 1 -or (Get-LowerSha256File -Path $source) -cne [string] $row[0].Sha256) { throw 'runner-review-required: approved hook entry is not bound by state.' }
    $temp = Join-Path $context.CommonPrivateRoot "approved-hook-entry.$([Guid]::NewGuid().ToString('N')).tmp"
    [System.IO.File]::Copy($source, $temp, $false)
    try { [System.IO.File]::Move($temp, $context.ApprovedHookEntryPath, $true) }
    finally { if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force } }
    return $context.ApprovedHookEntryPath
}

function New-CommittedDataSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $DestinationRoot,
        [Parameter(Mandatory)] [string] $ManifestPath,
        [string] $Commit
    )
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $policy = Get-RunnerPolicy -RepoRoot $repo
    Assert-RunnerRelevantTreeClean -RepoRoot $repo -Policy $policy -IncludeData
    if ([string]::IsNullOrWhiteSpace($Commit)) { $Commit = ((& git -C $repo rev-parse HEAD) | Select-Object -First 1).Trim() }
    if ($Commit -cnotmatch '^[0-9a-f]{40,64}$') { throw 'Invalid committed-data snapshot commit.' }
    if (Test-Path -LiteralPath $DestinationRoot) { throw 'Committed-data DestinationRoot must be create-new.' }
    Resolve-PrivateArtifactPath -Path $ManifestPath -Role ExternalUserArtifact -RepoRoot $repo -ForbiddenRoots @($DestinationRoot) -AllowMissingLeaf | Out-Null
    $pathspecs = @($policy.DataPathspecs | Sort-Object -Unique)
    $treeLines = @(& git -C $repo ls-tree -r "--format=%(objectmode) %(objecttype) %(objectname) %(path)" $Commit -- @pathspecs)
    if ($LASTEXITCODE -ne 0) { throw 'Unable to enumerate the committed data allowlist.' }
    $expected = [ordered]@{}
    foreach ($line in $treeLines) {
        $match = [regex]::Match([string]$line, '^(?<mode>[0-9]{6}) (?<type>\S+) (?<oid>[0-9a-f]{40,64}) (?<path>.+)$')
        if (-not $match.Success -or $match.Groups['type'].Value -cne 'blob' -or $match.Groups['mode'].Value -notin @('100644','100755')) { throw 'Committed data contains a symlink, gitlink, or unsupported mode.' }
        $relative = Normalize-ScanRelativePath -RelativePath $match.Groups['path'].Value
        if ($relative -in (Get-ProtectedReasonixRelativePaths) -or $relative.StartsWith('.reasonix/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Committed data allowlist reached Reasonix private state.' }
        $expected[$relative] = [pscustomobject]@{ Mode=$match.Groups['mode'].Value; Oid=$match.Groups['oid'].Value }
    }
    $archivePathspecs = @($pathspecs | Where-Object {
        $candidate = ([string]$_).TrimEnd('/')
        @($expected.Keys | Where-Object { $_ -eq $candidate -or $_.StartsWith($candidate + '/', [StringComparison]::Ordinal) }).Count -gt 0
    })
    $scratch = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-data-snapshot-$([Guid]::NewGuid().ToString('N'))"
    $archive = Join-Path $scratch 'allowlisted.zip'
    $extracted = Join-Path $scratch 'extracted'
    [System.IO.Directory]::CreateDirectory($scratch) | Out-Null
    try {
        if ($archivePathspecs.Count -gt 0) {
            & git -C $repo archive --format=zip "--output=$archive" $Commit -- @archivePathspecs
            if ($LASTEXITCODE -ne 0) { throw 'Failed to archive the explicit committed-data allowlist.' }
            Expand-Archive -LiteralPath $archive -DestinationPath $extracted
        }
        else { [System.IO.Directory]::CreateDirectory($extracted) | Out-Null }
        [System.IO.Directory]::CreateDirectory($DestinationRoot) | Out-Null
        $rows = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $queue = [System.Collections.Generic.Queue[string]]::new(); $queue.Enqueue($extracted)
        while ($queue.Count -gt 0) {
            $directory = $queue.Dequeue()
            foreach ($entry in [System.IO.Directory]::EnumerateFileSystemEntries($directory)) {
                $relative = Normalize-ScanRelativePath -RelativePath ([System.IO.Path]::GetRelativePath($extracted, $entry))
                $info = [AiAgentDotfiles.NoFollowFile]::Inspect($entry)
                if ($info.IsReparsePoint) { throw "Extracted snapshot contains a reparse entry: $relative" }
                if ($info.IsDirectory) { $queue.Enqueue($entry); continue }
                if (-not $expected.Contains($relative)) { throw "Archive produced an unapproved path: $relative" }
                if ($info.LinkCount -ne 1 -or @([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($entry)).Count -ne 0) { throw "Extracted snapshot file has unsafe identity metadata: $relative" }
                $destination = Join-Path $DestinationRoot $relative
                [System.IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
                $copy = [AiAgentDotfiles.NoFollowFile]::CopyRegularFile($entry, $destination)
                $after = [AiAgentDotfiles.NoFollowFile]::Inspect($entry)
                if ($after.Identity -cne $info.Identity -or $copy.Identity -cne $info.Identity) { throw "Extracted snapshot file drifted during copy: $relative" }
                $rows.Add([ordered]@{ RelativePath=$relative; GitMode=$expected[$relative].Mode; GitOid=$expected[$relative].Oid; Length=[long]$copy.Length; Sha256=$copy.Sha256; IdentityHash=$info.Identity; LinkCount=1; NamedStreamCount=0 })
                $null = $seen.Add($relative)
            }
        }
        if ($seen.Count -ne $expected.Count) { throw 'Committed-data snapshot is incomplete.' }
        $manifest = [ordered]@{ SchemaVersion=1; ArtifactKind='committed-data-snapshot-manifest'; SourceCommit=$Commit; DataPolicyHash=(Get-SemanticJsonHash -InputObject $pathspecs); Pathspecs=$pathspecs; DestinationRoot=[System.IO.Path]::GetFullPath($DestinationRoot); Files=@($rows | Sort-Object RelativePath) }
        $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($ManifestPath)); [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($ManifestPath), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $bytes=ConvertTo-SemanticJsonBytes -InputObject $manifest; $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        Assert-RunnerArtifactValid -Path $ManifestPath -ArtifactKind 'committed-data-snapshot-manifest'
        return [pscustomobject]$manifest
    }
    catch {
        if (Test-Path -LiteralPath $DestinationRoot) { Remove-Item -LiteralPath $DestinationRoot -Recurse -Force }
        if (Test-Path -LiteralPath $ManifestPath) { Remove-Item -LiteralPath $ManifestPath -Force }
        throw
    }
    finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
}
