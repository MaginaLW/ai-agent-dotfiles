#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $RepoRoot 'scripts/approved-runner-common.ps1')

function Write-SameLengthBytes {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [byte[]] $Bytes
    )

    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        if ($stream.Length -ne $Bytes.Length) { throw 'Exact-byte race fixture replacement length changed.' }
        $stream.Position = 0
        $stream.Write($Bytes, 0, $Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function New-PendingPruneFixtureDocument {
    param(
        [Parameter(Mandatory)] [string] $WorktreeNamespace,
        [Parameter(Mandatory)] [string] $ItemPath
    )

    $payload = [ordered]@{
        WorktreeNamespace = $WorktreeNamespace
        SelectionTimestampUtc = '2026-08-13T00:00:00.0000000Z'
        RegistrySnapshotHash = ('c' * 64)
        Items = @([ordered]@{ Path = $ItemPath; ContentHash = ('d' * 64) })
    }
    $document = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'pending-prune-plan'
        PlanPayload = $payload
        PlanHash = Get-PlanHash -PlanPayload $payload
    }
    $document.DocumentHash = Get-DocumentHash -Document $document
    return $document
}

function New-PendingEventFixtureDocument {
    param(
        [Parameter(Mandatory)] [string] $WorktreeNamespace,
        [Parameter(Mandatory)] [string] $ContextHash
    )

    return [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'pending-sync-event'
        EventKind = 'preview'
        WorktreeNamespace = $WorktreeNamespace
        Trigger = 'exact-byte-test'
        ApprovedToolchainHash = ('1' * 64)
        CurrentToolchainHash = ('1' * 64)
        Commit = ('2' * 40)
        ContextHash = $ContextHash
        PreviewStatus = 'non-consumable'
        RedactedContext = 'fixture'
        ContentHashes = @()
        ExternalDryRunCommand = 'pwsh -NoProfile -File scripts/sync.ps1 -DryRun -PlanPath <external>'
    }
}

function New-RunnerApprovalEventFixtureDocument {
    param(
        [Parameter(Mandatory)] [string] $ApprovedCommit,
        [Parameter(Mandatory)] [string] $WorktreeNamespace
    )

    return [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'runner-approval-event'
        ApprovedCommit = $ApprovedCommit
        ToolchainPolicyHash = ('3' * 64)
        RunnerTreeHash = ('4' * 64)
        ValidatorIdentityHash = ('5' * 64)
        ScannerIdentityHash = ('6' * 64)
        ToolCacheRoot = 'C:\fixture-cache'
        GitCommonDirHash = ('7' * 64)
        WorktreeNamespace = $WorktreeNamespace
        PointerGeneration = 1
    }
}

function New-ApprovedRunnerStateFixtureDocument {
    param(
        [Parameter(Mandatory)] [string] $ApprovedCommit,
        [Parameter(Mandatory)] [string] $ApprovalEventPath,
        [Parameter(Mandatory)] [string] $ApprovalEventHash,
        [Parameter(Mandatory)] [string] $RunnerRoot
    )

    return [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'approved-runner-state'
        ApprovedCommit = $ApprovedCommit
        ToolchainPolicyHash = ('3' * 64)
        RunnerTreeHash = ('4' * 64)
        RunnerRoot = $RunnerRoot
        RunnerEntryPath = Join-Path $RunnerRoot 'scripts/auto-sync-after-git.ps1'
        RunnerFiles = @([ordered]@{ RelativePath = 'scripts/auto-sync-after-git.ps1'; Length = 1; Sha256 = ('8' * 64) })
        ApprovalEventPath = $ApprovalEventPath
        ApprovalEventHash = $ApprovalEventHash
        ValidatorIdentityHash = ('5' * 64)
        ScannerIdentityHash = ('6' * 64)
        ToolCacheRoot = 'C:\fixture-cache'
        GitCommonDirHash = ('7' * 64)
        PointerGeneration = 1
    }
}

$temporaryBase = [System.IO.Path]::GetTempPath().TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar)
$work = Join-Path $temporaryBase "ai-agent-dotfiles-approved-runner-exact-byte-$([Guid]::NewGuid().ToString('N'))"
$repo = Join-Path $work 'repo'
$external = Join-Path $work 'external'
[System.IO.Directory]::CreateDirectory($repo) | Out-Null
[System.IO.Directory]::CreateDirectory($external) | Out-Null

try {
    & git -C $repo init -q
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize exact-byte approved-runner fixture.' }
    $storage = Get-RunnerStorageContext -RepoRoot $repo -EnsureDirectories

    Write-Host '[pending prune plan exact-byte schema/semantic binding]'
    $planPath = Join-Path $external 'pending-prune-plan.json'
    $namespaceA = [string] $storage.WorktreeId
    $replacementNibble = if ($namespaceA[0] -cne 'f') { 'f' } else { 'e' }
    $namespaceB = $replacementNibble + $namespaceA.Substring(1)
    $planA = New-PendingPruneFixtureDocument -WorktreeNamespace $namespaceA -ItemPath (Join-Path $storage.PendingEventsRoot 'fixture.json')
    $planB = New-PendingPruneFixtureDocument -WorktreeNamespace $namespaceB -ItemPath (Join-Path $storage.PendingEventsRoot 'fixture.json')
    $planABytes = ConvertTo-SemanticJsonBytes -InputObject $planA
    $planBBytes = ConvertTo-SemanticJsonBytes -InputObject $planB
    Assert-TestCondition ($planABytes.Length -eq $planBBytes.Length) 'pending prune race vectors have identical byte lengths'
    [System.IO.File]::WriteAllBytes($planPath, $planABytes)

    $realAssertRunnerArtifactValid = ${function:Assert-RunnerArtifactValid}
    $script:ApprovedRunnerReplacementBytes = $planBBytes
    $script:ApprovedRunnerReplacementCount = 0
    function Assert-RunnerArtifactValid {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $ArtifactKind)
        $result = & $realAssertRunnerArtifactValid -Path $Path -ArtifactKind $ArtifactKind
        if ($ArtifactKind -ceq 'pending-prune-plan') {
            Write-SameLengthBytes -Path $Path -Bytes $script:ApprovedRunnerReplacementBytes
            $script:ApprovedRunnerReplacementCount++
        }
        return $result
    }
    try {
        $capturedPlan = Read-PendingPrunePlan -PlanPath $planPath -StorageContext $storage
        Assert-TestCondition ([string] $capturedPlan.PlanPayload.WorktreeNamespace -ceq $namespaceA) 'prune semantics consume the exact bytes accepted by schema validation'
        Assert-TestCondition ($script:ApprovedRunnerReplacementCount -eq 1) 'pending prune fixture changes exactly once after schema validation'
    }
    finally {
        Set-Item -LiteralPath Function:Assert-RunnerArtifactValid -Value $realAssertRunnerArtifactValid
        Remove-Variable -Name ApprovedRunnerReplacementBytes, ApprovedRunnerReplacementCount -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[pending event exact-byte deduplication binding]'
    $pendingA = New-PendingEventFixtureDocument -WorktreeNamespace ([string] $storage.WorktreeId) -ContextHash ('a' * 64)
    $pendingB = New-PendingEventFixtureDocument -WorktreeNamespace ([string] $storage.WorktreeId) -ContextHash ('b' * 64)
    $pendingABytes = ConvertTo-SemanticJsonBytes -InputObject $pendingA
    $pendingBBytes = ConvertTo-SemanticJsonBytes -InputObject $pendingB
    Assert-TestCondition ($pendingABytes.Length -eq $pendingBBytes.Length) 'pending event race vectors have identical byte lengths'
    $pendingPath = Write-ImmutableRunnerArtifact -Directory $storage.PendingEventsRoot -Prefix 'preview' -Document $pendingA -TimestampUtc ([DateTimeOffset]::Parse('2026-08-13T00:00:00Z')) -ArtifactId '11111111111111111111111111111111'
    $realAssertRunnerArtifactValid = ${function:Assert-RunnerArtifactValid}
    $script:ApprovedRunnerReplacementBytes = $pendingBBytes
    function Assert-RunnerArtifactValid {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $ArtifactKind)
        $result = & $realAssertRunnerArtifactValid -Path $Path -ArtifactKind $ArtifactKind
        if ($ArtifactKind -ceq 'pending-sync-event' -and [System.IO.Path]::GetFullPath($Path) -ceq [System.IO.Path]::GetFullPath($pendingPath)) {
            Write-SameLengthBytes -Path $Path -Bytes $script:ApprovedRunnerReplacementBytes
        }
        return $result
    }
    try {
        $deduplicated = Write-DeduplicatedPendingEvent -StorageContext $storage -Document $pendingB
        Assert-TestCondition ([System.IO.Path]::GetFullPath($deduplicated) -cne [System.IO.Path]::GetFullPath($pendingPath)) 'deduplication compares the schema-validated pending event snapshot, not later path bytes'
    }
    finally {
        Set-Item -LiteralPath Function:Assert-RunnerArtifactValid -Value $realAssertRunnerArtifactValid
        Remove-Variable -Name ApprovedRunnerReplacementBytes -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[approved state and approval event exact-byte binding]'
    $eventPath = Join-Path $storage.ApprovalEventsRoot 'runner-approval-exact-byte.json'
    $runnerRoot = Join-Path $storage.ApprovedRunnersRoot 'exact-byte-runner'
    $eventA = New-RunnerApprovalEventFixtureDocument -ApprovedCommit ('a' * 40) -WorktreeNamespace ([string] $storage.WorktreeId)
    $eventB = New-RunnerApprovalEventFixtureDocument -ApprovedCommit ('b' * 40) -WorktreeNamespace ([string] $storage.WorktreeId)
    $eventABytes = ConvertTo-SemanticJsonBytes -InputObject $eventA
    $eventBBytes = ConvertTo-SemanticJsonBytes -InputObject $eventB
    Assert-TestCondition ($eventABytes.Length -eq $eventBBytes.Length) 'approval event race vectors have identical byte lengths'
    [System.IO.File]::WriteAllBytes($eventPath, $eventABytes)
    $eventAHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($eventABytes)).ToLowerInvariant()
    $stateA = New-ApprovedRunnerStateFixtureDocument -ApprovedCommit ('a' * 40) -ApprovalEventPath $eventPath -ApprovalEventHash $eventAHash -RunnerRoot $runnerRoot
    $stateB = New-ApprovedRunnerStateFixtureDocument -ApprovedCommit ('b' * 40) -ApprovalEventPath $eventPath -ApprovalEventHash $eventAHash -RunnerRoot $runnerRoot
    $stateABytes = ConvertTo-SemanticJsonBytes -InputObject $stateA
    $stateBBytes = ConvertTo-SemanticJsonBytes -InputObject $stateB
    Assert-TestCondition ($stateABytes.Length -eq $stateBBytes.Length) 'approved state race vectors have identical byte lengths'
    [System.IO.File]::WriteAllBytes($storage.ApprovedStatePath, $stateABytes)

    $realAssertRunnerArtifactValid = ${function:Assert-RunnerArtifactValid}
    $script:ApprovedRunnerReplacementBytes = $stateBBytes
    $script:ApprovedRunnerReplacementKind = 'approved-runner-state'
    function Assert-RunnerArtifactValid {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $ArtifactKind)
        $result = & $realAssertRunnerArtifactValid -Path $Path -ArtifactKind $ArtifactKind
        if ($ArtifactKind -ceq $script:ApprovedRunnerReplacementKind) { Write-SameLengthBytes -Path $Path -Bytes $script:ApprovedRunnerReplacementBytes }
        return $result
    }
    try {
        $capturedState = Get-ApprovedRunnerState -RepoRoot $repo
        Assert-TestCondition ([string] $capturedState.ApprovedCommit -ceq ('a' * 40)) 'approved pointer semantics consume the exact state bytes accepted by schema validation'
    }
    finally {
        Set-Item -LiteralPath Function:Assert-RunnerArtifactValid -Value $realAssertRunnerArtifactValid
        Remove-Variable -Name ApprovedRunnerReplacementBytes, ApprovedRunnerReplacementKind -Scope Script -ErrorAction SilentlyContinue
    }

    [System.IO.File]::WriteAllBytes($storage.ApprovedStatePath, $stateABytes)
    [System.IO.File]::WriteAllBytes($eventPath, $eventABytes)
    $realAssertRunnerArtifactValid = ${function:Assert-RunnerArtifactValid}
    $script:ApprovedRunnerReplacementBytes = $eventBBytes
    $script:ApprovedRunnerReplacementKind = 'runner-approval-event'
    function Assert-RunnerArtifactValid {
        param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $ArtifactKind)
        $result = & $realAssertRunnerArtifactValid -Path $Path -ArtifactKind $ArtifactKind
        if ($ArtifactKind -ceq $script:ApprovedRunnerReplacementKind) { Write-SameLengthBytes -Path $Path -Bytes $script:ApprovedRunnerReplacementBytes }
        return $result
    }
    try {
        $capturedState = Get-ApprovedRunnerState -RepoRoot $repo
        Assert-TestCondition ([string] $capturedState.ApprovedCommit -ceq ('a' * 40)) 'event hash and state cross-check consume the exact approval-event bytes accepted by schema validation'
    }
    finally {
        Set-Item -LiteralPath Function:Assert-RunnerArtifactValid -Value $realAssertRunnerArtifactValid
        Remove-Variable -Name ApprovedRunnerReplacementBytes, ApprovedRunnerReplacementKind -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[policy materialization exact-byte SHA/GitOid binding]'
    $policyRepo = Join-Path $work 'policy-repo'
    $materialization = Join-Path $work 'policy-materialization'
    [System.IO.Directory]::CreateDirectory((Join-Path $policyRepo 'scripts')) | Out-Null
    & git -C $policyRepo init -q
    & git -C $policyRepo config user.email 'tests@example.invalid'
    & git -C $policyRepo config user.name 'Exact Byte Tests'
    & git -C $policyRepo config core.autocrlf false
    $policyPath = Join-Path $policyRepo 'scripts/runner-policy.psd1'
    $policyCommittedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("@{ SchemaVersion = 1; DataPathspecs = @(); ToolchainPaths = @('scripts/runner-policy.psd1') } # committed-b`n")
    $policyReplacementBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("@{ SchemaVersion = 1; DataPathspecs = @(); ToolchainPaths = @('scripts/runner-policy.psd1') } # replaced--a`n")
    Assert-TestCondition ($policyCommittedBytes.Length -eq $policyReplacementBytes.Length) 'policy race vectors have identical byte lengths'
    [System.IO.File]::WriteAllBytes($policyPath, $policyCommittedBytes)
    & git -C $policyRepo add -- scripts/runner-policy.psd1
    & git -C $policyRepo commit -qm 'policy fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit exact-byte policy fixture.' }

    $realAssertRunnerRelevantTreeClean = ${function:Assert-RunnerRelevantTreeClean}
    $realGetPinnedRunnerToolIdentities = ${function:Get-PinnedRunnerToolIdentities}
    $script:ApprovedRunnerPolicyPath = $policyPath
    $script:ApprovedRunnerPolicyReplacementBytes = $policyReplacementBytes
    $script:ApprovedRunnerPolicyCommittedBytes = $policyCommittedBytes
    $script:ApprovedRunnerPolicyDestination = Join-Path $materialization 'scripts/runner-policy.psd1'
    $script:ApprovedRunnerGitApplication = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $script:ApprovedRunnerHeldPolicyMutationBlocked = $false
    function Assert-RunnerRelevantTreeClean {
        param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] $Policy, [switch] $IncludeData)
        & $realAssertRunnerRelevantTreeClean -RepoRoot $RepoRoot -Policy $Policy -IncludeData:$IncludeData
        try { Write-SameLengthBytes -Path $script:ApprovedRunnerPolicyPath -Bytes $script:ApprovedRunnerPolicyReplacementBytes }
        catch {
            if ($_.Exception -is [System.IO.IOException] -or $_.Exception.InnerException -is [System.IO.IOException]) {
                $script:ApprovedRunnerHeldPolicyMutationBlocked = $true
            }
            else { throw }
        }
    }
    function Get-PinnedRunnerToolIdentities {
        param([string] $ToolCacheRoot)
        return [pscustomobject]@{ ToolCacheRoot='C:\fixture-cache'; ValidatorIdentityHash=('1' * 64); ScannerIdentityHash=('2' * 64) }
    }
    function git {
        if (@($args | ForEach-Object { [string] $_ }) -contains 'hash-object') {
            Write-SameLengthBytes -Path $script:ApprovedRunnerPolicyDestination -Bytes $script:ApprovedRunnerPolicyCommittedBytes
        }
        & $script:ApprovedRunnerGitApplication @args
    }
    try {
        $policySnapshot = Get-RunnerPolicySnapshot -RepoRoot $policyRepo -DestinationRoot $materialization
        $materializedSha = (Get-FileHash -LiteralPath $script:ApprovedRunnerPolicyDestination -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-TestCondition $script:ApprovedRunnerHeldPolicyMutationBlocked 'policy source remains write-locked throughout clean-check, Git OID proof, and held copy'
        Assert-TestCondition ([string] $policySnapshot.RunnerFiles[0].Sha256 -ceq $materializedSha) 'policy row SHA and materialized bytes come from the same held source capture'
    }
    finally {
        Set-Item -LiteralPath Function:Assert-RunnerRelevantTreeClean -Value $realAssertRunnerRelevantTreeClean
        Set-Item -LiteralPath Function:Get-PinnedRunnerToolIdentities -Value $realGetPinnedRunnerToolIdentities
        Remove-Item -LiteralPath Function:git -ErrorAction SilentlyContinue
        Remove-Variable -Name ApprovedRunnerPolicyPath, ApprovedRunnerPolicyReplacementBytes, ApprovedRunnerPolicyCommittedBytes, ApprovedRunnerPolicyDestination, ApprovedRunnerGitApplication, ApprovedRunnerHeldPolicyMutationBlocked -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[approved hook held-copy binding]'
    $runnerRootForHook = Join-Path $work 'approved-hook-runner'
    $hookSource = Join-Path $runnerRootForHook 'scripts/approved-hook-entry.ps1'
    [System.IO.Directory]::CreateDirectory((Split-Path -Parent $hookSource)) | Out-Null
    $hookABytes = [System.Text.UTF8Encoding]::new($false).GetBytes("# approved hook A`n")
    $hookBBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("# replaced hook B`n")
    Assert-TestCondition ($hookABytes.Length -eq $hookBBytes.Length) 'hook race vectors have identical byte lengths'
    [System.IO.File]::WriteAllBytes($hookSource, $hookABytes)
    $hookAHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($hookABytes)).ToLowerInvariant()
    $hookState = [pscustomobject]@{
        RunnerRoot = $runnerRootForHook
        RunnerFiles = @([pscustomobject]@{ RelativePath='scripts/approved-hook-entry.ps1'; Length=[long]$hookABytes.Length; Sha256=$hookAHash })
    }
    $realGetLowerSha256File = ${function:Get-LowerSha256File}
    $realOpenApprovedRunnerHeldFile = ${function:Open-ApprovedRunnerHeldFile}
    $script:ApprovedRunnerHookSource = $hookSource
    $script:ApprovedRunnerHookReplacementBytes = $hookBBytes
    $script:ApprovedRunnerHeldHookMutationBlocked = $false
    function Get-LowerSha256File {
        param([Parameter(Mandatory)] [string] $Path)
        $hash = & $realGetLowerSha256File -Path $Path
        if ([System.IO.Path]::GetFullPath($Path) -ceq [System.IO.Path]::GetFullPath($script:ApprovedRunnerHookSource)) {
            Write-SameLengthBytes -Path $Path -Bytes $script:ApprovedRunnerHookReplacementBytes
        }
        return $hash
    }
    function Open-ApprovedRunnerHeldFile {
        param(
            [Parameter(Mandatory)] [string] $Path,
            [long] $MaximumBytes = $script:ApprovedRunnerMaximumFileBytes
        )
        $capture = & $realOpenApprovedRunnerHeldFile -Path $Path -MaximumBytes $MaximumBytes
        if ([System.IO.Path]::GetFullPath($Path) -ceq [System.IO.Path]::GetFullPath($script:ApprovedRunnerHookSource)) {
            try { Write-SameLengthBytes -Path $Path -Bytes $script:ApprovedRunnerHookReplacementBytes }
            catch {
                if ($_.Exception -is [System.IO.IOException] -or $_.Exception.InnerException -is [System.IO.IOException]) {
                    $script:ApprovedRunnerHeldHookMutationBlocked = $true
                }
                else { throw }
            }
        }
        return $capture
    }
    try {
        $publishedHook = Publish-ApprovedHookEntry -RepoRoot $repo -State $hookState
        $publishedHookHash = (Get-FileHash -LiteralPath $publishedHook -Algorithm SHA256).Hash.ToLowerInvariant()
        Assert-TestCondition $script:ApprovedRunnerHeldHookMutationBlocked 'approved hook source remains write-locked until held copy completes'
        Assert-TestCondition ($publishedHookHash -ceq $hookAHash) 'published hook bytes are copied from the same held source capture authorized by state'
    }
    finally {
        Set-Item -LiteralPath Function:Get-LowerSha256File -Value $realGetLowerSha256File
        Set-Item -LiteralPath Function:Open-ApprovedRunnerHeldFile -Value $realOpenApprovedRunnerHeldFile
        Remove-Variable -Name ApprovedRunnerHookSource, ApprovedRunnerHookReplacementBytes, ApprovedRunnerHeldHookMutationBlocked -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host '[committed-data snapshot exact-byte GitOid binding]'
    $dataRepo = Join-Path $work 'data-repo'
    $dataSnapshotRoot = Join-Path $work 'data-snapshot'
    $dataManifestPath = Join-Path $external 'data-snapshot-manifest.json'
    [System.IO.Directory]::CreateDirectory((Join-Path $dataRepo 'scripts')) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $dataRepo 'data')) | Out-Null
    & git -C $dataRepo init -q
    & git -C $dataRepo config user.email 'tests@example.invalid'
    & git -C $dataRepo config user.name 'Exact Byte Tests'
    & git -C $dataRepo config core.autocrlf false
    $dataPolicyPath = Join-Path $dataRepo 'scripts/runner-policy.psd1'
    [System.IO.File]::WriteAllText($dataPolicyPath, "@{ SchemaVersion = 1; DataPathspecs = @('data'); ToolchainPaths = @('scripts/runner-policy.psd1') }`n", [System.Text.UTF8Encoding]::new($false))
    $dataSourcePath = Join-Path $dataRepo 'data/fixture.txt'
    $dataCommittedBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("committed-b`n")
    $dataReplacementBytes = [System.Text.UTF8Encoding]::new($false).GetBytes("replaced--a`n")
    Assert-TestCondition ($dataCommittedBytes.Length -eq $dataReplacementBytes.Length) 'committed-data race vectors have identical byte lengths'
    [System.IO.File]::WriteAllBytes($dataSourcePath, $dataCommittedBytes)
    & git -C $dataRepo add -- scripts/runner-policy.psd1 data/fixture.txt
    & git -C $dataRepo commit -qm 'committed data fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit exact-byte data fixture.' }

    $null = Get-Command Expand-Archive
    $realExpandArchive = ${function:Expand-Archive}
    $script:ApprovedRunnerExtractedReplacementBytes = $dataReplacementBytes
    function Expand-Archive {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [string] $LiteralPath,
            [Parameter(Mandatory)] [string] $DestinationPath
        )
        Microsoft.PowerShell.Archive\Expand-Archive -LiteralPath $LiteralPath -DestinationPath $DestinationPath
        Write-SameLengthBytes -Path (Join-Path $DestinationPath 'data/fixture.txt') -Bytes $script:ApprovedRunnerExtractedReplacementBytes
    }
    $snapshotRejected = $false
    try {
        try { $null = New-CommittedDataSnapshot -RepoRoot $dataRepo -DestinationRoot $dataSnapshotRoot -ManifestPath $dataManifestPath }
        catch {
            if ($_.Exception.Message -match 'snapshot bytes do not match the selected commit') { $snapshotRejected = $true }
            else { throw }
        }
        Assert-TestCondition $snapshotRejected 'committed-data snapshot rejects extracted bytes whose same-byte Git OID differs from the selected commit'
        Assert-TestCondition (-not (Test-Path -LiteralPath $dataSnapshotRoot)) 'rejected committed-data snapshot removes its partial destination'
        Assert-TestCondition (-not (Test-Path -LiteralPath $dataManifestPath)) 'rejected committed-data snapshot publishes no manifest'
    }
    finally {
        Set-Item -LiteralPath Function:Expand-Archive -Value $realExpandArchive
        Remove-Variable -Name ApprovedRunnerExtractedReplacementBytes -Scope Script -ErrorAction SilentlyContinue
    }

    Write-Host 'approved-runner exact-byte tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
