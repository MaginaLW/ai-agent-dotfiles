#requires -Version 7.0

Set-StrictMode -Version Latest

$script:ApprovedRunnerAuthorityRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$script:ApprovedRunnerMaximumFileBytes = [long] [int]::MaxValue
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
    return Invoke-FixedJsonSchemaValidation -SchemaPath (Get-ArtifactSchemaPath -ArtifactKind $ArtifactKind) -InstancePath $Path
}

function Write-ImmutableRunnerArtifactCapture {
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
    try {
        $validation = Assert-RunnerArtifactValid -Path $path -ArtifactKind ([string] $Document.ArtifactKind)
        return Assert-ExactJsonArtifactCapture -Capture $validation.ArtifactCapture
    }
    catch { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue; throw }
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

    $capture = Write-ImmutableRunnerArtifactCapture -Directory $Directory -Prefix $Prefix -Document $Document -TimestampUtc $TimestampUtc -ArtifactId $ArtifactId
    return [string] $capture.FullPath
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
    $null = Assert-RunnerArtifactValid -Path $PlanPath -ArtifactKind 'pending-prune-plan'
    return [pscustomobject]$document
}

function Read-PendingPrunePlan {
    param([Parameter(Mandatory)] [string] $PlanPath, [Parameter(Mandatory)] $StorageContext)
    Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $StorageContext.RepoRoot -ForbiddenRoots @($StorageContext.CommonPrivateRoot, $StorageContext.WorktreePrivateRoot) | Out-Null
    $validation = Assert-RunnerArtifactValid -Path $PlanPath -ArtifactKind 'pending-prune-plan'
    $capture = Assert-ExactJsonArtifactCapture -Capture $validation.ArtifactCapture
    $document = $capture.Document
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
                    $validation = Assert-RunnerArtifactValid -Path $file.FullName -ArtifactKind 'pending-sync-event'
                    $capture = Assert-ExactJsonArtifactCapture -Capture $validation.ArtifactCapture
                    $existing = $capture.Document
                    if ([string]$existing.ContextHash -ceq [string]$Document.ContextHash -and [string]$existing.EventKind -ceq [string]$Document.EventKind) { return $file.FullName }
                }
                catch { throw "Pending namespace contains an invalid registered event: $($file.FullName)" }
            }
        }
        return Write-ImmutableRunnerArtifact -Directory $StorageContext.PendingEventsRoot -Prefix ([string]$Document.EventKind) -Document $Document
    }
}

function Open-ApprovedRunnerHeldFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [long] $MaximumBytes = $script:ApprovedRunnerMaximumFileBytes
    )

    if ($MaximumBytes -lt 0) { throw 'Approved runner file maximum byte length must be non-negative.' }
    $full = [System.IO.Path]::GetFullPath($Path)
    $parent = [System.IO.Path]::GetDirectoryName($full)
    $leaf = [System.IO.Path]::GetFileName($full)
    if ([string]::IsNullOrWhiteSpace($parent) -or [string]::IsNullOrWhiteSpace($leaf)) { throw "Approved runner file path is invalid: $full" }
    $parentHandles = $null
    $fileHandle = $null
    try {
        $parentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $parent -OwnershipReceiver $parentHandlesReceiver
        $parentHandles = $parentHandlesReceiver.GetDeliveredExact()
        $fileHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parentHandles[$parentHandles.Count - 1], $leaf)
        $bytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($fileHandle, $MaximumBytes)
        return [pscustomobject][ordered]@{
            FullPath = $full
            Bytes = [byte[]] $bytes
            Sha256 = [string] $fileHandle.ReadResult.Sha256
            Identity = [string] $fileHandle.ReadResult.Identity
            Length = [long] $fileHandle.ReadResult.Length
            ParentHandles = $parentHandles
            FileHandle = $fileHandle
        }
    }
    catch {
        if ($null -ne $fileHandle) { $fileHandle.Dispose() }
        if ($null -ne $parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
        throw
    }
}

function Close-ApprovedRunnerHeldFile {
    param([Parameter(Mandatory)] $Capture)
    try {
        if ($null -ne $Capture.FileHandle) { $Capture.FileHandle.Dispose() }
    }
    finally {
        if ($null -ne $Capture.ParentHandles) { Close-SafeDirectoryContainmentChain -Handles $Capture.ParentHandles }
    }
}

function New-ApprovedRunnerDestinationTree {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $DestinationRoot)

    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    $existingAncestor = $null
    $ancestorReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    Open-SafeExistingDirectoryContainmentChain -Path $destination -ExistingPath ([ref] $existingAncestor) -OwnershipReceiver $ancestorReceiver
    $handles = $ancestorReceiver.GetDeliveredExact()
    try {
        $existingKey = [System.IO.Path]::GetFullPath($existingAncestor).TrimEnd([char]92, [char]47)
        $destinationKey = $destination.TrimEnd([char]92, [char]47)
        if ($existingKey.Equals($destinationKey, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Runner materialization must be create-new: $destination"
        }
        $parentHandle = $handles[$handles.Count - 1]
        foreach ($segment in @([System.IO.Path]::GetRelativePath($existingAncestor, $destination) -split '[\\/]')) {
            if ($segment -in @('', '.', '..')) { throw "Unsafe runner materialization path segment: $destination" }
            $childHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($parentHandle, $segment)
            $handles.Add($childHandle)
            $parentHandle = $childHandle
        }
        $directoryHandles = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $directoryHandles.Add('', $parentHandle)
        return [pscustomobject][ordered]@{
            Root = $destination
            Handles = $handles
            DirectoryHandlesByRelativePath = $directoryHandles
        }
    }
    catch {
        Close-SafeDirectoryContainmentChain -Handles $handles
        throw
    }
}

function Close-ApprovedRunnerDestinationTree {
    param([Parameter(Mandatory)] $DestinationTree)
    Close-SafeDirectoryContainmentChain -Handles $DestinationTree.Handles
}

function Get-ApprovedRunnerDestinationDirectoryHandle {
    param(
        [Parameter(Mandatory)] $DestinationTree,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $RelativeDirectory
    )

    $relative = ConvertTo-SafeRelativePath -Path $RelativeDirectory
    if ($DestinationTree.DirectoryHandlesByRelativePath.ContainsKey($relative)) {
        return $DestinationTree.DirectoryHandlesByRelativePath[$relative]
    }
    $cursor = ''
    $parentHandle = $DestinationTree.DirectoryHandlesByRelativePath['']
    foreach ($segment in @($relative -split '/')) {
        $next = if ($cursor) { "$cursor/$segment" } else { $segment }
        if ($DestinationTree.DirectoryHandlesByRelativePath.ContainsKey($next)) {
            $parentHandle = $DestinationTree.DirectoryHandlesByRelativePath[$next]
        }
        else {
            $childHandle = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($parentHandle, $segment)
            $DestinationTree.Handles.Add($childHandle)
            $DestinationTree.DirectoryHandlesByRelativePath.Add($next, $childHandle)
            $parentHandle = $childHandle
        }
        $cursor = $next
    }
    return $parentHandle
}

function Copy-ApprovedRunnerHeldFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $SourceCapture,
        [Parameter(Mandatory)] $DestinationTree,
        [Parameter(Mandatory)] [string] $RelativePath
    )

    $relative = ConvertTo-SafeRelativePath -Path $RelativePath
    if ([string]::IsNullOrWhiteSpace($relative)) { throw 'Approved runner destination file path must not be empty.' }
    $parentRelative = ConvertTo-SafeRelativePath -Path ([System.IO.Path]::GetDirectoryName($relative))
    $leaf = [System.IO.Path]::GetFileName($relative)
    $destinationParent = Get-ApprovedRunnerDestinationDirectoryHandle -DestinationTree $DestinationTree -RelativeDirectory $parentRelative
    $copy = [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($SourceCapture.FileHandle, $destinationParent, $leaf)
    if ([string] $copy.Identity -cne [string] $SourceCapture.Identity -or
        [long] $copy.Length -ne [long] $SourceCapture.Length -or
        [string] $copy.Sha256 -cne [string] $SourceCapture.Sha256) {
        throw "Approved runner held source changed during copy: $relative"
    }
    return $copy
}

function ConvertFrom-RunnerPolicyBytes {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [byte[]] $Bytes)

    try { $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($Bytes) }
    catch { throw 'runner-review-required: runner policy is not strict UTF-8.' }
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $parseErrors)
    if (@($parseErrors).Count -ne 0 -or $null -eq $ast.EndBlock -or @($ast.EndBlock.Statements).Count -ne 1) {
        throw 'runner-review-required: runner policy is not one literal data hashtable.'
    }
    $statement = $ast.EndBlock.Statements[0]
    if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or
        @($statement.PipelineElements).Count -ne 1 -or
        $statement.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
        $statement.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
        throw 'runner-review-required: runner policy is not one literal data hashtable.'
    }
    try { $policy = $statement.PipelineElements[0].Expression.SafeGetValue() }
    catch { throw 'runner-review-required: runner policy contains a non-literal expression.' }
    if ($policy -isnot [System.Collections.IDictionary]) { throw 'runner-review-required: runner policy root must be a hashtable.' }
    if ([long] $policy.SchemaVersion -ne 1) { throw 'runner-review-required: unsupported runner policy version.' }
    foreach ($field in @('DataPathspecs', 'ToolchainPaths')) {
        if (-not $policy.Contains($field)) { throw "runner-review-required: policy is missing $field." }
    }
    $policySelf = @($policy.ToolchainPaths | ForEach-Object { Normalize-ScanRelativePath -RelativePath ([string] $_) } | Where-Object { $_ -ceq 'scripts/runner-policy.psd1' })
    if ($policySelf.Count -ne 1) { throw 'runner-review-required: runner policy must bind scripts/runner-policy.psd1 exactly once.' }
    return $policy
}

function Open-RunnerPolicyCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = [System.IO.Path]::GetFullPath($RepoRoot)
    $held = Open-ApprovedRunnerHeldFile -Path (Join-Path $repo 'scripts/runner-policy.psd1')
    try {
        $policy = ConvertFrom-RunnerPolicyBytes -Bytes $held.Bytes
        return [pscustomobject][ordered]@{ RepoRoot=$repo; Policy=$policy; HeldFile=$held }
    }
    catch {
        Close-ApprovedRunnerHeldFile -Capture $held
        throw
    }
}

function Close-RunnerPolicyCapture {
    param([Parameter(Mandatory)] $Capture)
    Close-ApprovedRunnerHeldFile -Capture $Capture.HeldFile
}

function Get-GitBlobOidFromBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $RelativePath,
        [Parameter(Mandatory)] [byte[]] $Bytes,
        [int] $TimeoutMilliseconds = 30000,
        [int] $ReapTimeoutMilliseconds = 5000
    )

    $gitCommand = Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1
    if ($null -eq $gitCommand -or [string]::IsNullOrWhiteSpace([string] $gitCommand.Source)) { throw 'runner-review-required: Git executable is unavailable.' }
    $relative = Normalize-ScanRelativePath -RelativePath $RelativePath
    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = [string] $gitCommand.Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardInput = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.ArgumentList.Add('-C')
    $start.ArgumentList.Add([System.IO.Path]::GetFullPath($RepoRoot))
    $start.ArgumentList.Add('hash-object')
    $start.ArgumentList.Add("--path=$relative")
    $start.ArgumentList.Add('--stdin')
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $start
    $started = $false
    $stdoutTask = $null
    $stderrTask = $null
    $failure = $null
    $oid = $null
    try {
        if (-not $process.Start()) { throw 'Unable to start Git hash-object.' }
        $started = $true
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.BaseStream.Write($Bytes, 0, $Bytes.Length)
        $process.StandardInput.BaseStream.Flush()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) { throw 'Git hash-object timed out.' }
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ($process.ExitCode -ne 0 -or $stdout -cnotmatch '^[0-9a-f]{40,64}$') {
            throw "Git hash-object failed for $relative`: $stderr"
        }
        $oid = $stdout
    }
    catch {
        $failure = $_
        if ($started) {
            try { $process.StandardInput.Close() } catch {}
            try { if (-not $process.HasExited) { $process.Kill($true) } } catch {}
            try { $null = $process.WaitForExit($ReapTimeoutMilliseconds) } catch {}
            foreach ($task in @($stdoutTask, $stderrTask)) {
                if ($null -eq $task) { continue }
                try { if ($task.Wait($ReapTimeoutMilliseconds)) { $null = $task.GetAwaiter().GetResult() } } catch {}
            }
        }
    }
    finally { $process.Dispose() }
    if ($null -ne $failure) { throw $failure }
    return $oid
}

function Get-RunnerPolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $capture = Open-RunnerPolicyCapture -RepoRoot $RepoRoot
    try { return $capture.Policy }
    finally { Close-RunnerPolicyCapture -Capture $capture }
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
    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    $policyCapture = $null
    $destinationTree = $null
    $succeeded = $false
    try {
        $policyCapture = Open-RunnerPolicyCapture -RepoRoot $repo
        $policy = $policyCapture.Policy
        Assert-RunnerRelevantTreeClean -RepoRoot $repo -Policy $policy -IncludeData:$RequireCleanData
        $commit = ((& git -C $repo rev-parse HEAD 2>$null) | Select-Object -First 1).Trim()
        if ($LASTEXITCODE -ne 0 -or $commit -cnotmatch '^[0-9a-f]{40,64}$') { throw 'runner-review-required: selected commit is unavailable.' }
        if ([string]::IsNullOrWhiteSpace($BindingCommit)) { $BindingCommit = $commit }
        if ($BindingCommit -cnotmatch '^[0-9a-f]{40,64}$') { throw 'runner-review-required: invalid approval commit binding.' }
        $destinationTree = New-ApprovedRunnerDestinationTree -DestinationRoot $destination

        $rows = [System.Collections.Generic.List[object]]::new()
        $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($relative in @($policy.ToolchainPaths | Sort-Object -Unique)) {
            $normalized = Normalize-ScanRelativePath -RelativePath ([string] $relative)
            if (-not $seenPaths.Add($normalized)) { throw "runner-review-required: policy selects one toolchain path more than once: $normalized" }
            if ($normalized -in (Get-ProtectedReasonixRelativePaths) -or $normalized.StartsWith('.reasonix/', [StringComparison]::OrdinalIgnoreCase)) { throw 'runner-review-required: policy selects a protected Reasonix path.' }
            $tree = @(& git -C $repo ls-tree $commit -- $normalized)
            if ($LASTEXITCODE -ne 0 -or $tree.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string] $tree[0])) { throw "runner-review-required: policy path is not one committed blob: $normalized" }
            $match = [regex]::Match([string] $tree[0], '^(?<mode>[0-9]{6}) blob (?<oid>[0-9a-f]{40,64})\t(?<path>.+)$')
            if (-not $match.Success -or $match.Groups['mode'].Value -notin @('100644', '100755') -or $match.Groups['path'].Value -cne $normalized) {
                throw "runner-review-required: policy path is a symlink, gitlink, directory, or unexpected entry: $normalized"
            }
            $sourceCapture = $null
            $closeSourceCapture = $false
            try {
                if ($normalized -ceq 'scripts/runner-policy.psd1') { $sourceCapture = $policyCapture.HeldFile }
                else {
                    $sourceCapture = Open-ApprovedRunnerHeldFile -Path (Join-Path $repo $normalized)
                    $closeSourceCapture = $true
                }
                $oid = Get-GitBlobOidFromBytes -RepoRoot $repo -RelativePath $normalized -Bytes $sourceCapture.Bytes
                if ($oid -cne $match.Groups['oid'].Value) { throw "working-tree-review-required: policy bytes do not match the selected commit: $normalized" }
                $copy = Copy-ApprovedRunnerHeldFile -SourceCapture $sourceCapture -DestinationTree $destinationTree -RelativePath $normalized
                $rows.Add([ordered]@{ RelativePath = $normalized; GitMode = $match.Groups['mode'].Value; GitOid = $oid; Length = [long] $copy.Length; Sha256 = [string] $copy.Sha256 })
            }
            finally { if ($closeSourceCapture -and $null -ne $sourceCapture) { Close-ApprovedRunnerHeldFile -Capture $sourceCapture } }
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
        $result = [pscustomobject][ordered]@{
            CurrentCommit = $commit
            BindingCommit = $BindingCommit
            ToolchainPolicyHash = $policyHash
            RunnerTreeHash = $runnerTreeHash
            RunnerFiles = @($rows)
            ValidatorIdentityHash = $tools.ValidatorIdentityHash
            ScannerIdentityHash = $tools.ScannerIdentityHash
            ToolCacheRoot = $tools.ToolCacheRoot
            DataPathspecs = @($policy.DataPathspecs | Sort-Object -Unique)
            MaterializationRoot = $destination
        }
        $succeeded = $true
        return $result
    }
    finally {
        if ($null -ne $destinationTree) { Close-ApprovedRunnerDestinationTree -DestinationTree $destinationTree }
        if ($null -ne $policyCapture) { Close-RunnerPolicyCapture -Capture $policyCapture }
        if (-not $succeeded -and (Test-Path -LiteralPath $destination)) { Remove-Item -LiteralPath $destination -Recurse -Force }
    }
}

function Get-ApprovedRunnerState {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $context = Get-RunnerStorageContext -RepoRoot $RepoRoot
    if (-not (Test-Path -LiteralPath $context.ApprovedStatePath -PathType Leaf)) { throw 'runner-review-required: approved runner state is missing.' }
    Resolve-PrivateArtifactPath -Path $context.ApprovedStatePath -Role InternalContractPath -RepoRoot $context.RepoRoot -InternalRoot $context.CommonPrivateRoot | Out-Null
    $stateValidation = Assert-RunnerArtifactValid -Path $context.ApprovedStatePath -ArtifactKind 'approved-runner-state'
    $stateCapture = Assert-ExactJsonArtifactCapture -Capture $stateValidation.ArtifactCapture
    $state = $stateCapture.Document
    Resolve-PrivateArtifactPath -Path ([string]$state.ApprovalEventPath) -Role InternalContractPath -RepoRoot $context.RepoRoot -InternalRoot $context.ApprovalEventsRoot | Out-Null
    $eventValidation = Assert-RunnerArtifactValid -Path ([string]$state.ApprovalEventPath) -ArtifactKind 'runner-approval-event'
    $eventCapture = Assert-ExactJsonArtifactCapture -Capture $eventValidation.ArtifactCapture
    if ([string]$eventCapture.Sha256 -cne [string]$state.ApprovalEventHash) { throw 'runner-review-required: approval event hash mismatch.' }
    $event = $eventCapture.Document
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
        $null = Assert-RunnerArtifactValid -Path $temp -ArtifactKind 'approved-runner-state'
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
    $eventCapture = Write-ImmutableRunnerArtifactCapture -Directory $context.ApprovalEventsRoot -Prefix 'runner-approval' -Document $event
    $eventPath = [string] $eventCapture.FullPath
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
        ApprovalEventHash = [string] $eventCapture.Sha256
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
    if ($row.Count -ne 1) { throw 'runner-review-required: approved hook entry is not bound by state.' }
    $temp = Join-Path $context.CommonPrivateRoot "approved-hook-entry.$([Guid]::NewGuid().ToString('N')).tmp"
    try {
        $sourceCapture = $null
        $destinationHandles = $null
        try {
            $sourceCapture = Open-ApprovedRunnerHeldFile -Path $source
            if ([string] $sourceCapture.Sha256 -cne [string] $row[0].Sha256 -or [long] $sourceCapture.Length -ne [long] $row[0].Length) {
                throw 'runner-review-required: approved hook entry is not bound by state.'
            }
            $destinationHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SafeDirectoryContainmentChain -Path $context.CommonPrivateRoot -OwnershipReceiver $destinationHandlesReceiver
            $destinationHandles = $destinationHandlesReceiver.GetDeliveredExact()
            $copy = [AiAgentDotfiles.NoFollowFile]::CopyHeldRegularFile($sourceCapture.FileHandle, $destinationHandles[$destinationHandles.Count - 1], [System.IO.Path]::GetFileName($temp))
            if ([string] $copy.Identity -cne [string] $sourceCapture.Identity -or
                [long] $copy.Length -ne [long] $sourceCapture.Length -or
                [string] $copy.Sha256 -cne [string] $sourceCapture.Sha256) {
                throw 'runner-review-required: approved hook entry changed during held copy.'
            }
        }
        finally {
            if ($null -ne $destinationHandles) { Close-SafeDirectoryContainmentChain -Handles $destinationHandles }
            if ($null -ne $sourceCapture) { Close-ApprovedRunnerHeldFile -Capture $sourceCapture }
        }
        [System.IO.File]::Move($temp, $context.ApprovedHookEntryPath, $true)
    }
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
    $expected = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
    $expectedCaseFold = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in $treeLines) {
        $match = [regex]::Match([string]$line, '^(?<mode>[0-9]{6}) (?<type>\S+) (?<oid>[0-9a-f]{40,64}) (?<path>.+)$')
        if (-not $match.Success -or $match.Groups['type'].Value -cne 'blob' -or $match.Groups['mode'].Value -notin @('100644','100755')) { throw 'Committed data contains a symlink, gitlink, or unsupported mode.' }
        $relative = Normalize-ScanRelativePath -RelativePath $match.Groups['path'].Value
        if ($relative -in (Get-ProtectedReasonixRelativePaths) -or $relative.StartsWith('.reasonix/', [StringComparison]::OrdinalIgnoreCase)) { throw 'Committed data allowlist reached Reasonix private state.' }
        if (-not $expectedCaseFold.Add($relative) -or $expected.ContainsKey($relative)) { throw "Committed data contains a case-colliding or duplicate path: $relative" }
        $expected.Add($relative, [pscustomobject]@{ Mode=$match.Groups['mode'].Value; Oid=$match.Groups['oid'].Value })
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
        $rows = [System.Collections.Generic.List[object]]::new()
        $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $sourceTraversal = $null
        $destinationTree = $null
        try {
            $sourceTraversalReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SafeTreeRetainedTraversal -Root $extracted -OwnershipReceiver $sourceTraversalReceiver
            $sourceTraversal = $sourceTraversalReceiver.GetDeliveredExact()
            $destinationTree = New-ApprovedRunnerDestinationTree -DestinationRoot $DestinationRoot
            $evidenceByPath = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::Ordinal)
            foreach ($evidence in @($sourceTraversal.Snapshot.TraversalIdentityEvidence | Where-Object Type -eq 'File')) {
                $evidenceByPath.Add([string] $evidence.RelativePath, $evidence)
            }
            foreach ($fileRow in @($sourceTraversal.Snapshot.ContentTreeRows | Where-Object Type -eq 'File' | Sort-Object RelativePath)) {
                $relative = Normalize-ScanRelativePath -RelativePath ([string] $fileRow.RelativePath)
                if (-not $expected.ContainsKey($relative)) { throw "Archive produced an unapproved path: $relative" }
                if (-not $sourceTraversal.FileHandlesByRelativePath.ContainsKey($relative)) { throw "Extracted snapshot held file is missing: $relative" }
                if (-not $evidenceByPath.ContainsKey($relative)) { throw "Extracted snapshot identity evidence is missing: $relative" }
                $fileHandle = $sourceTraversal.FileHandlesByRelativePath[$relative]
                $read = $fileHandle.ReadResult
                $bytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($fileHandle, $script:ApprovedRunnerMaximumFileBytes)
                $oid = Get-GitBlobOidFromBytes -RepoRoot $repo -RelativePath $relative -Bytes $bytes
                if ($oid -cne [string] $expected[$relative].Oid) { throw "working-tree-review-required: snapshot bytes do not match the selected commit: $relative" }
                $sourceCapture = [pscustomobject][ordered]@{
                    FullPath = Join-Path $extracted $relative
                    Bytes = [byte[]] $bytes
                    Sha256 = [string] $read.Sha256
                    Identity = [string] $read.Identity
                    Length = [long] $read.Length
                    FileHandle = $fileHandle
                }
                $copy = Copy-ApprovedRunnerHeldFile -SourceCapture $sourceCapture -DestinationTree $destinationTree -RelativePath $relative
                $evidence = $evidenceByPath[$relative]
                if ([string] $evidence.Identity -cne [string] $read.Identity -or [long] $evidence.LinkCount -ne 1 -or [long] $evidence.NamedStreamCount -ne 0) {
                    throw "Extracted snapshot identity evidence changed before copy: $relative"
                }
                $rows.Add([ordered]@{ RelativePath=$relative; GitMode=$expected[$relative].Mode; GitOid=$oid; Length=[long]$copy.Length; Sha256=[string]$copy.Sha256; IdentityHash=[string]$read.Identity; LinkCount=1; NamedStreamCount=0 })
                if (-not $seen.Add($relative)) { throw "Archive produced a duplicate path: $relative" }
            }
        }
        finally {
            if ($null -ne $destinationTree) { Close-ApprovedRunnerDestinationTree -DestinationTree $destinationTree }
            if ($null -ne $sourceTraversal) {
                foreach ($heldFile in $sourceTraversal.FileHandlesByRelativePath.Values) { $heldFile.Dispose() }
                Close-SafeDirectoryContainmentChain -Handles $sourceTraversal.ContainmentHandles
            }
        }
        if ($seen.Count -ne $expected.Count) { throw 'Committed-data snapshot is incomplete.' }
        $manifest = [ordered]@{ SchemaVersion=1; ArtifactKind='committed-data-snapshot-manifest'; SourceCommit=$Commit; DataPolicyHash=(Get-SemanticJsonHash -InputObject $pathspecs); Pathspecs=$pathspecs; DestinationRoot=[System.IO.Path]::GetFullPath($DestinationRoot); Files=@($rows | Sort-Object RelativePath) }
        $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($ManifestPath)); [System.IO.Directory]::CreateDirectory($parent) | Out-Null
        $stream = [System.IO.File]::Open([System.IO.Path]::GetFullPath($ManifestPath), [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try { $bytes=ConvertTo-SemanticJsonBytes -InputObject $manifest; $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        $null = Assert-RunnerArtifactValid -Path $ManifestPath -ArtifactKind 'committed-data-snapshot-manifest'
        return [pscustomobject]$manifest
    }
    catch {
        if (Test-Path -LiteralPath $DestinationRoot) { Remove-Item -LiteralPath $DestinationRoot -Recurse -Force }
        if (Test-Path -LiteralPath $ManifestPath) { Remove-Item -LiteralPath $ManifestPath -Force }
        throw
    }
    finally { if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force } }
}
