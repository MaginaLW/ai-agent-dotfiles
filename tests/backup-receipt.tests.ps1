#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-backup-receipt-$([Guid]::NewGuid().ToString('N'))"
$backupRoot = Join-Path $work 'backups'
$controlBase = Join-Path $work 'control'
$homeAuthorityKey = 'a' * 64
$receiptHost = Join-Path $PSScriptRoot 'helpers/backup-receipt-host.ps1'
$internalHost = Join-Path $RepoRoot 'scripts/internal/live-transaction-host.ps1'
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
. (Join-Path $PSScriptRoot 'helpers/failpoint-controller.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')

$script:pass = 0

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:pass++
    Write-Host "  PASS  $Message"
}

function Assert-ThrowsToken {
    param(
        [Parameter(Mandatory)] [scriptblock] $Action,
        [Parameter(Mandatory)] [string] $Token,
        [Parameter(Mandatory)] [string] $Message
    )
    $threw = $false
    $actual = ''
    try { & $Action }
    catch {
        $threw = $true
        $actual = [string] $_.Exception.Message
    }
    if (-not $threw) { throw "FAIL: $Message (did not throw)" }
    if ($actual.IndexOf($Token, [System.StringComparison]::Ordinal) -lt 0) {
        throw "FAIL: $Message (unexpected: $actual)"
    }
    $script:pass++
    Write-Host "  PASS  $Message"
}

function Write-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-ReceiptIntent {
    param([Parameter(Mandatory)] [string] $BackupRoot)
    $receiptId = [Guid]::NewGuid().ToString()
    return [ordered]@{
        TransactionId = [Guid]::NewGuid().ToString()
        ReceiptId = $receiptId
        ReceiptPath = (Join-Path $BackupRoot $receiptId)
    }
}

function New-ProducerSplat {
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Intent,
        [Parameter(Mandatory)] [string] $SourceOperationKind
    )
    $platforms = @(
        [ordered]@{
            Platform = 'Claude'
            LiveRoot = (Join-Path $work 'live/claude/skills')
            Targets = @(
                [ordered]@{ Name = 'kept-claude'; LivePath = (Join-Path $work 'live/claude/skills/kept-claude'); PlannedTreeHash = $script:claudeTreeHash }
            )
        },
        [ordered]@{
            Platform = 'Codex'
            LiveRoot = (Join-Path $work 'live/codex/skills')
            Targets = @(
                [ordered]@{ Name = 'kept-codex'; LivePath = (Join-Path $work 'live/codex/skills/kept-codex'); PlannedTreeHash = $script:codexTreeHash },
                [ordered]@{ Name = 'added-codex'; LivePath = (Join-Path $work 'live/codex/skills/added-codex'); PlannedTreeHash = $null }
            )
        },
        [ordered]@{
            Platform = 'Reasonix'
            LiveRoot = (Join-Path $work 'reasonix-override')
            Targets = @(
                [ordered]@{ Name = 'gone-reasonix'; LivePath = (Join-Path $work 'reasonix-override/gone-reasonix'); PlannedTreeHash = $script:reasonixTreeHash }
            )
        }
    )
    return @{
        ReservationIntent = $Intent
        SourceOperationKind = $SourceOperationKind
        PlanHash = ('1' * 64)
        DocumentHash = ('2' * 64)
        ExecutionContextHash = ('3' * 64)
        ControlBaseHash = ('4' * 64)
        FilesystemCapabilityHash = ('5' * 64)
        HomeAuthorityKey = $homeAuthorityKey
        BackupRoot = $BackupRoot
        Platforms = $platforms
        AuthorityStatePath = (Join-Path $controlBase "homes/$homeAuthorityKey/current-env.json")
        RootClaimsPath = (Join-Path $controlBase "homes/$homeAuthorityKey/root-claims.json")
        ForbiddenRoots = @((Join-Path $work 'live'), $controlBase, (Join-Path $work 'repo-tree'))
    }
}

function New-HappyReceipt {
    param([Parameter(Mandatory)] [string] $SourceOperationKind)
    $intent = New-ReceiptIntent -BackupRoot $backupRoot
    $splat = New-ProducerSplat -Intent $intent -SourceOperationKind $SourceOperationKind
    $result = Invoke-SealedManagedBackupReceipt @splat
    return @{ Intent = $intent; Splat = $splat; Result = $result }
}

function ConvertTo-ReceiptOrderedValue {
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) {
        # PowerShell 7 parses ISO 8601 JSON strings into DateTime; the receipt
        # documents spell them with the round-trip 'o' format.
        return ([datetime] $Value).ToString('o')
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-ReceiptOrderedValue -Value $property.Value }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]) {
        return @([object[]] ($Value | ForEach-Object { ConvertTo-ReceiptOrderedValue -Value $_ }))
    }
    return $Value
}

function ConvertTo-ReceiptOrdered {
    # JSON round-trip a producer result so tamper cases can rebuild a document.
    param([Parameter(Mandatory)] [string] $Json)
    return [System.Collections.IDictionary] (ConvertTo-ReceiptOrderedValue -Value (ConvertFrom-Json -InputObject $Json))
}

try {
    New-Item -ItemType Directory -Force -Path $backupRoot, $controlBase | Out-Null

    # --- fixtures -----------------------------------------------------------
    $statePath = Join-Path $controlBase "homes/$homeAuthorityKey/current-env.json"
    $claimsPath = Join-Path $controlBase "homes/$homeAuthorityKey/root-claims.json"
    Write-TextFile -Path $statePath -Content ('{"artifact":"current-env-state","sentinel":' + (Get-Random) + '}')
    Write-TextFile -Path $claimsPath -Content ('{"artifact":"root-claims","sentinel":' + (Get-Random) + '}')

    foreach ($dir in @(
        'live/claude/skills/kept-claude',
        'live/codex/skills/kept-codex',
        'live/codex/skills/.system',
        'live/codex/skills/unknown-local',
        'reasonix-override/gone-reasonix'
    )) {
        New-Item -ItemType Directory -Force -Path (Join-Path $work $dir) | Out-Null
    }
    Write-TextFile -Path (Join-Path $work 'live/claude/skills/kept-claude/SKILL.md') -Content 'claude-sentinel'
    Write-TextFile -Path (Join-Path $work 'live/codex/skills/kept-codex/SKILL.md') -Content 'codex-sentinel'
    Write-TextFile -Path (Join-Path $work 'live/codex/skills/.system/.codex-system-skills.marker') -Content 'system-sentinel'
    Write-TextFile -Path (Join-Path $work 'live/codex/skills/unknown-local/SKILL.md') -Content 'unknown-sentinel'
    Write-TextFile -Path (Join-Path $work 'reasonix-override/gone-reasonix/SKILL.md') -Content 'reasonix-sentinel'
    $unknownSentinel = Get-Item -LiteralPath (Join-Path $work 'live/codex/skills/unknown-local/SKILL.md')
    $systemSentinel = Get-Item -LiteralPath (Join-Path $work 'live/codex/skills/.system/.codex-system-skills.marker')
    $unknownSentinelBefore = [ordered]@{ Length = $unknownSentinel.Length; Write = $unknownSentinel.LastWriteTimeUtc }
    $systemSentinelBefore = [ordered]@{ Length = $systemSentinel.Length; Write = $systemSentinel.LastWriteTimeUtc }
    $script:claudeTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $work 'live/claude/skills/kept-claude')).TreeHash
    $script:codexTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $work 'live/codex/skills/kept-codex')).TreeHash
    $script:reasonixTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $work 'reasonix-override/gone-reasonix')).TreeHash

    # live-transaction-host only accepts scripts under scripts/ or the sandbox;
    # copy the receipt host into the sandbox for capability-gated child runs.
    $sandboxedReceiptHost = Join-Path $work 'backup-receipt-host.ps1'
    Copy-Item -LiteralPath $receiptHost -Destination $sandboxedReceiptHost -Force

    Write-Host '[receipt producer happy path]'
    $happy = New-HappyReceipt -SourceOperationKind 'retirement'
    $result = $happy.Result
    Assert ($result.SourceTransactionId -ne $result.ReceiptId) 'producer returns distinct transaction and receipt ids'
    Assert ($result.ReceiptPath -ceq [string] $happy.Intent.ReceiptPath) 'producer returns the exact declared receipt path'
    Assert ([string] $result.ReceiptHash -match '^[0-9a-f]{64}$') 'producer returns a ReceiptHash'
    Assert ($result.SourceOperationKind -ceq 'retirement') 'producer binds the exact SourceOperationKind'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath $result.ReceiptPath) -ceq 'COMPLETE') 'published slot classifies COMPLETE'
    $snapshotClaude = Join-Path $result.ReceiptPath 'snapshot/claude/kept-claude'
    Assert ((Get-Content -Raw -LiteralPath (Join-Path $snapshotClaude 'SKILL.md')) -eq 'claude-sentinel') 'managed snapshot copies the planned target content'
    Assert (-not (Test-Path -LiteralPath (Join-Path $result.ReceiptPath 'snapshot/codex/added-codex'))) 'planned-missing target records no fake directory'
    Assert (-not (Test-Path -LiteralPath (Join-Path $result.ReceiptPath 'snapshot/claude/unknown-local'))) 'unknown live skill is not copied'
    Assert (-not (Test-Path -LiteralPath (Join-Path $result.ReceiptPath 'snapshot/codex/.system'))) 'Codex .system is never copied'
    $unknownSentinelAfter = Get-Item -LiteralPath $unknownSentinel.FullName
    Assert ($unknownSentinelAfter.Length -eq [long] $unknownSentinelBefore.Length -and $unknownSentinelAfter.LastWriteTimeUtc -eq [datetime] $unknownSentinelBefore.Write) 'unknown sentinel bytes and timestamps unchanged'
    $systemSentinelAfter = Get-Item -LiteralPath $systemSentinel.FullName
    Assert ($systemSentinelAfter.Length -eq [long] $systemSentinelBefore.Length -and $systemSentinelAfter.LastWriteTimeUtc -eq [datetime] $systemSentinelBefore.Write) '.system sentinel bytes and timestamps unchanged'
    $codexRow = @([object[]] $result.ManagedSnapshots | Where-Object { [string] $_.Platform -ceq 'Codex' })[0]
    Assert ((@([object[]] $codexRow.Targets | Where-Object { [string] $_.Name -ceq 'added-codex' })[0].Status) -ceq 'MISSING') 'planned-missing target recorded MISSING'
    Assert ((@([object[]] $result.UnknownMarkers | Where-Object { [string] $_.Name -ceq 'unknown-local' })).Count -eq 1) 'unknown root-entry marker recorded once'
    Assert ($result.SystemMarker.Present -and $null -ne $result.SystemMarker.Identity) '.system root-entry marker recorded with identity'
    $statePreimage = Get-Content -Raw -LiteralPath (Join-Path $result.ReceiptPath 'authority-preimage/current-env.json')
    Assert ($statePreimage -ceq (Get-Content -Raw -LiteralPath $statePath)) 'authority state preimage is byte-identical'
    Assert ($result.AuthorityStatePreimage.Status -ceq 'COPIED' -and $null -ne $result.AuthorityStatePreimage.Hash) 'authority state preimage binds hash and status'
    $linkedSnapshotFile = Join-Path $snapshotClaude 'SKILL.md'
    Assert (([AiAgentDotfiles.NoFollowFile]::Inspect($linkedSnapshotFile)).LinkCount -eq 1) 'snapshot files are fresh copies, not hardlinks'
    Assert ([string] $result.ManagedSnapshots[2].LiveRoot -ceq ([System.IO.Path]::GetFullPath((Join-Path $work 'reasonix-override')))) 'custom Reasonix live root is bound exactly'

    Write-Host '[receipt artifact validation and consumer verification]'
    $schemaValidation = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/backup-receipt.schema.json') -InstancePath (Join-Path $result.ReceiptPath '_meta/receipt.json')
    Assert $true 'published receipt passes the registered schema'
    Test-BackupReceiptSemantics -Document $schemaValidation.ArtifactCapture.Document
    Assert $true 'published receipt passes the semantic validator'
    $null = Assert-SealedBackupReceiptValid -ReceiptPath $result.ReceiptPath -ReservationIntent $happy.Intent -BackupRoot $backupRoot -ExpectedSourceOperationKind 'retirement' -ExpectedPlanHash ('1' * 64) -ExpectedDocumentHash ('2' * 64)
    Assert $true 'consumer verification passes with the exact bindings'
    $null = Assert-SealedBackupReceiptValid -ReceiptPath $result.ReceiptPath -ReservationIntent $happy.Intent -BackupRoot $backupRoot
    Assert $true 'consumer verification passes without optional bindings'

    Write-Host '[restart classification]'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath (Join-Path $backupRoot 'absent-slot')) -ceq 'MISSING') 'absent declared slot classifies MISSING'
    $decoy = Join-Path $backupRoot 'decoy-slot'
    New-Item -ItemType Directory -Force -Path (Join-Path $decoy '_meta') | Out-Null
    Write-TextFile -Path (Join-Path $decoy '_meta/receipt.json') -Content '{}'
    Write-TextFile -Path (Join-Path $decoy '_meta/COMPLETE') -Content 'decoy'
    $freshState = Invoke-TestProcess -ScriptPath $receiptHost -Arguments @('-Mode', 'classify', '-ReceiptPath', ([string] $happy.Result.ReceiptPath), '-RepoRoot', $RepoRoot)
    Assert ($freshState.Code -eq 0 -and $freshState.Out -match 'COMPLETE') 'fresh-process classification reads only the declared slot'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $happy.Result.ReceiptPath)) -ceq 'COMPLETE') 'decoy sibling does not influence the declared slot'

    Write-Host '[producer failure matrix]'
    $again = New-HappyReceipt -SourceOperationKind 'retirement'
    $duplicateSplat = $again.Splat
    $duplicateSplat.ReservationIntent = $happy.Intent
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @duplicateSplat } 'backup-receipt-slot-collision' 'a second producer on the same declared slot fails with the collision token'
    $occupiedIntent = New-ReceiptIntent -BackupRoot $backupRoot
    New-Item -ItemType Directory -Force -Path ([string] $occupiedIntent.ReceiptPath) | Out-Null
    $occupiedSplat = New-ProducerSplat -Intent $occupiedIntent -SourceOperationKind 'retirement'
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @occupiedSplat } 'backup-receipt-slot-collision' 'an existing destination directory fails with the collision token'

    $driftSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $backupRoot) -SourceOperationKind 'retirement'
    $driftPlatforms = @($driftSplat.Platforms)
    $driftPlatforms[0].Targets[0].PlannedTreeHash = ('e' * 64)
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @driftSplat } 'backup-receipt-source-drift' 'a drifted planned tree hash fails closed'
    $absentSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $backupRoot) -SourceOperationKind 'retirement'
    $absentPlatforms = @($absentSplat.Platforms)
    $absentPlatforms[2].Targets[0].LivePath = (Join-Path $work 'reasonix-override/vanished-reasonix')
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @absentSplat } 'backup-receipt-source-drift' 'a planned-present target that is missing fails closed'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'live/codex/skills/added-codex') | Out-Null
    Write-TextFile -Path (Join-Path $work 'live/codex/skills/added-codex/SKILL.md') -Content 'unexpected-addition'
    $presentSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $backupRoot) -SourceOperationKind 'retirement'
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @presentSplat } 'backup-receipt-target-state-drift' 'a planned-missing target that now exists fails closed'
    Remove-Item -LiteralPath (Join-Path $work 'live/codex/skills/added-codex') -Recurse -Force

    $reparseRoot = Join-Path $work 'reparse-live'
    New-Item -ItemType Directory -Force -Path (Join-Path $reparseRoot 'kept/SKILL.md' | Split-Path -Parent) | Out-Null
    Write-TextFile -Path (Join-Path $reparseRoot 'kept/SKILL.md') -Content 'reparse-parent'
    New-Item -ItemType Directory -Force -Path (Join-Path $work 'reparse-target-dir') | Out-Null
    $null = New-Item -ItemType Junction -Path (Join-Path $reparseRoot 'kept/link') -Target (Join-Path $work 'reparse-target-dir') -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath (Join-Path $reparseRoot 'kept/link')) {
        $reparseSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $backupRoot) -SourceOperationKind 'retirement'
        $reparsePlatforms = @($reparseSplat.Platforms)
        $reparsePlatforms[0].LiveRoot = $reparseRoot
        $reparsePlatforms[0].Targets[0] = [ordered]@{ Name = 'kept'; LivePath = (Join-Path $reparseRoot 'kept'); PlannedTreeHash = ('0' * 64) }
        $reparseIntent = New-ReceiptIntent -BackupRoot $backupRoot
        $reparseSplat.ReservationIntent = $reparseIntent
        $threw = $false
        try { Invoke-SealedManagedBackupReceipt @reparseSplat } catch { $threw = $true }
        Assert $threw 'a reparse entry inside a live target fails closed'
        Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $reparseIntent.ReceiptPath)) -ceq 'PARTIAL') 'the rejected producer leaves only a partial slot'
    }

    $missingRootSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $backupRoot) -SourceOperationKind 'retirement'
    $missingRootSplat.BackupRoot = (Join-Path $backupRoot 'never-created')
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @missingRootSplat } 'backup-receipt-backup-root-invalid' 'a missing BackupRoot fails closed'
    $overlapSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $backupRoot) -SourceOperationKind 'retirement'
    $overlapSplat.BackupRoot = (Join-Path $work 'live/claude/inside-live')
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @overlapSplat } 'backup-receipt-backup-root-invalid' 'a BackupRoot inside a live root fails closed'
    $broadRoot = Join-Path $work 'broad-backups'
    New-Item -ItemType Directory -Force -Path $broadRoot | Out-Null
    $acl = Get-Acl -LiteralPath $broadRoot
    $rule = [System.Security.AccessControl.FileSystemAccessRule]::new('Everyone', 'Modify', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
    $acl.AddAccessRule($rule)
    Set-Acl -LiteralPath $broadRoot -AclObject $acl
    $broadSplat = New-ProducerSplat -Intent (New-ReceiptIntent -BackupRoot $broadRoot) -SourceOperationKind 'retirement'
    $broadSplat.BackupRoot = $broadRoot
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @broadSplat } 'backup-receipt-backup-root-invalid' 'a broad-write BackupRoot DACL fails closed'

    $badLeafIntent = [ordered]@{
        TransactionId = [Guid]::NewGuid().ToString()
        ReceiptId = [Guid]::NewGuid().ToString()
        ReceiptPath = (Join-Path $backupRoot 'not-the-receipt-id')
    }
    $badLeafSplat = New-ProducerSplat -Intent $badLeafIntent -SourceOperationKind 'retirement'
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @badLeafSplat } 'backup-receipt-intent-mismatch' 'a receipt path whose leaf is not the ReceiptId fails closed'
    $elsewhereIntent = [ordered]@{
        TransactionId = [Guid]::NewGuid().ToString()
        ReceiptId = [Guid]::NewGuid().ToString()
        ReceiptPath = (Join-Path $work 'elsewhere-slot')
    }
    $elsewhereSplat = New-ProducerSplat -Intent $elsewhereIntent -SourceOperationKind 'retirement'
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @elsewhereSplat } 'backup-receipt-intent-mismatch' 'a receipt path outside the resolved BackupRoot fails closed'
    $aliasedIntent = [ordered]@{
        TransactionId = [Guid]::NewGuid().ToString()
        ReceiptId = [Guid]::NewGuid().ToString()
        ReceiptPath = (Join-Path $backupRoot 'aliased')
    }
    $aliasedIntent.TransactionId = $aliasedIntent.ReceiptId
    $aliasedSplat = New-ProducerSplat -Intent $aliasedIntent -SourceOperationKind 'retirement'
    Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @aliasedSplat } 'backup-receipt-intent-mismatch' 'aliased transaction and receipt ids fail closed'

    Write-Host '[concurrent same-slot producers]'
    $raceIntent = New-ReceiptIntent -BackupRoot $backupRoot
    $raceArgs = New-ProducerSplat -Intent $raceIntent -SourceOperationKind 'retirement'
    $requestJson = ConvertTo-Json -InputObject ([ordered]@{
        ReservationIntent = $raceIntent
        SourceOperationKind = 'retirement'
        PlanHash = ('1' * 64)
        DocumentHash = ('2' * 64)
        ExecutionContextHash = ('3' * 64)
        ControlBaseHash = ('4' * 64)
        FilesystemCapabilityHash = ('5' * 64)
        HomeAuthorityKey = $homeAuthorityKey
        BackupRoot = $backupRoot
        Platforms = $raceArgs.Platforms
        AuthorityStatePath = $raceArgs.AuthorityStatePath
        RootClaimsPath = $raceArgs.RootClaimsPath
        ForbiddenRoots = $raceArgs.ForbiddenRoots
    }) -Depth 20 -Compress
    $encoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes($requestJson))
    $hostArguments = @('-Mode', 'produce', '-ProducerArgsJson', $requestJson, '-RepoRoot', $RepoRoot)
    $hostArgumentsEncoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $hostArguments -Compress)))
    $processes = @(1..2 | ForEach-Object {
        $outFile = Join-Path $work ("race-out-$_.txt")
        $errFile = Join-Path $work ("race-err-$_.txt")
        Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $internalHost, '-SandboxRoot', $work, '-ScriptPath', $sandboxedReceiptHost, '-ArgumentsBase64', $hostArgumentsEncoded) -PassThru -WindowStyle Hidden -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    })
    foreach ($process in $processes) { Wait-Process -Id $process.Id -Timeout 120 -ErrorAction SilentlyContinue }
    $exitCodes = @($processes | ForEach-Object { $_.ExitCode })
    if ((@($exitCodes | Where-Object { $_ -eq 0 }).Count -ne 1) -or (@($exitCodes | Where-Object { $_ -ne 0 }).Count -ne 1)) {
        for ($i = 0; $i -lt 2; $i++) {
            Write-Host "--- child $i exit $($exitCodes[$i]) stderr ---"
            Write-Host (Get-Content -Raw -LiteralPath (Join-Path $work "race-err-$($i + 1).txt") -ErrorAction SilentlyContinue)
        }
        throw 'FAIL: concurrent race outcome assertion (see child output above)'
    }
    Assert $true 'two concurrent producers on one declared slot yield exactly one winner'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath ([string] $raceIntent.ReceiptPath)) -ceq 'COMPLETE') 'the race winner publishes a complete receipt'

    Write-Host '[crash windows and restart classification]'
    foreach ($window in @(
        @{ Checkpoint = 'slot-created'; Expected = 'PARTIAL' },
        @{ Checkpoint = 'snapshot-published'; Expected = 'PARTIAL' },
        @{ Checkpoint = 'preimage-published'; Expected = 'PARTIAL' },
        @{ Checkpoint = 'receipt-published'; Expected = 'PARTIAL' },
        @{ Checkpoint = 'complete-published'; Expected = 'COMPLETE' }
    )) {
        $intent = New-ReceiptIntent -BackupRoot $backupRoot
        $splat = New-ProducerSplat -Intent $intent -SourceOperationKind 'retirement'
        $requestJson = ConvertTo-Json -InputObject ([ordered]@{
            ReservationIntent = $intent
            SourceOperationKind = 'retirement'
            PlanHash = ('1' * 64)
            DocumentHash = ('2' * 64)
            ExecutionContextHash = ('3' * 64)
            ControlBaseHash = ('4' * 64)
            FilesystemCapabilityHash = ('5' * 64)
            HomeAuthorityKey = $homeAuthorityKey
            BackupRoot = $backupRoot
            Platforms = $splat.Platforms
            AuthorityStatePath = $splat.AuthorityStatePath
            RootClaimsPath = $splat.RootClaimsPath
            ForbiddenRoots = $splat.ForbiddenRoots
        }) -Depth 20 -Compress
        $controller = New-FailpointController
        $failpointsJson = ConvertTo-Json -InputObject @(@{ Checkpoint = $window.Checkpoint; PipeName = $controller.Name }) -Compress
        $hostArguments = @('-Mode', 'produce', '-ProducerArgsJson', $requestJson, '-FailpointsJson', $failpointsJson, '-RepoRoot', $RepoRoot)
        $hostArgumentsEncoded = [Convert]::ToBase64String([System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $hostArguments -Compress)))
        $child = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-File', $internalHost, '-SandboxRoot', $work, '-ScriptPath', $sandboxedReceiptHost, '-ArgumentsBase64', $hostArgumentsEncoded) -PassThru -WindowStyle Hidden
        try {
            Wait-FailpointController -Controller $controller -ExpectedCheckpoint $window.Checkpoint -TimeoutSeconds 60
            Stop-FailpointProcessTree -Process $child
        }
        finally {
            Close-FailpointController -Controller $controller
        }
        Wait-Process -Id $child.Id -Timeout 30 -ErrorAction SilentlyContinue
        $state = Invoke-TestProcess -ScriptPath $receiptHost -Arguments @('-Mode', 'classify', '-ReceiptPath', ([string] $intent.ReceiptPath), '-RepoRoot', $RepoRoot)
        Assert ($state.Code -eq 0 -and $state.Out -match $window.Expected) "restart after '$($window.Checkpoint)' classifies the declared slot as $($window.Expected)"
        if ($window.Checkpoint -ne 'complete-published') {
            $retrySplat = New-ProducerSplat -Intent $intent -SourceOperationKind 'retirement'
            Assert-ThrowsToken { Invoke-SealedManagedBackupReceipt @retrySplat } 'backup-receipt-slot-collision' "a killed producer's slot refuses a second create-new"
        }
    }

    Write-Host '[tamper and verifier matrix]'
    $byteTamper = New-HappyReceipt -SourceOperationKind 'retirement'
    $bytePath = Join-Path ([string] $byteTamper.Result.ReceiptPath) '_meta/receipt.json'
    $originalBytes = [System.IO.File]::ReadAllBytes($bytePath)
    $originalBytes[60] = 0x58
    [System.IO.File]::WriteAllBytes($bytePath, $originalBytes)
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $byteTamper.Result.ReceiptPath) -ReservationIntent $byteTamper.Intent -BackupRoot $backupRoot } 'backup-receipt-verifier-invalid' 'a byte-tampered receipt document fails verification'

    $wrongVersion = New-HappyReceipt -SourceOperationKind 'retirement'
    $wrongVersionPath = Join-Path ([string] $wrongVersion.Result.ReceiptPath) '_meta/receipt.json'
    $wrongVersionDoc = ConvertTo-ReceiptOrdered -Json (Get-Content -Raw -LiteralPath $wrongVersionPath)
    $wrongVersionDoc['SchemaVersion'] = 2
    $wrongVersionDoc['ReceiptHash'] = Get-BackupReceiptSelfExcludedHash -Document $wrongVersionDoc
    Write-TextFile -Path $wrongVersionPath -Content (ConvertTo-Json -InputObject $wrongVersionDoc -Depth 40)
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $wrongVersion.Result.ReceiptPath) -ReservationIntent $wrongVersion.Intent -BackupRoot $backupRoot } 'backup-receipt-verifier-invalid' 'a wrong SchemaVersion fails verification'

    $wrongKind = New-HappyReceipt -SourceOperationKind 'retirement'
    $wrongKindPath = Join-Path ([string] $wrongKind.Result.ReceiptPath) '_meta/receipt.json'
    $wrongKindDoc = ConvertTo-ReceiptOrdered -Json (Get-Content -Raw -LiteralPath $wrongKindPath)
    $wrongKindDoc['SourceOperationKind'] = 'environment'
    $wrongKindDoc['ReceiptHash'] = Get-BackupReceiptSelfExcludedHash -Document $wrongKindDoc
    Write-TextFile -Path $wrongKindPath -Content (ConvertTo-Json -InputObject $wrongKindDoc -Depth 40)
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $wrongKind.Result.ReceiptPath) -ReservationIntent $wrongKind.Intent -BackupRoot $backupRoot -ExpectedSourceOperationKind 'retirement' } 'backup-receipt-verifier-invalid' 'a drifted SourceOperationKind fails the binding check'

    $driftedHashes = New-HappyReceipt -SourceOperationKind 'retirement'
    $driftedPath = Join-Path ([string] $driftedHashes.Result.ReceiptPath) '_meta/receipt.json'
    $driftedDoc = ConvertTo-ReceiptOrdered -Json (Get-Content -Raw -LiteralPath $driftedPath)
    $driftedDoc['PlanHash'] = ('9' * 64)
    $driftedDoc['ReceiptHash'] = Get-BackupReceiptSelfExcludedHash -Document $driftedDoc
    Write-TextFile -Path $driftedPath -Content (ConvertTo-Json -InputObject $driftedDoc -Depth 40)
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $driftedHashes.Result.ReceiptPath) -ReservationIntent $driftedHashes.Intent -BackupRoot $backupRoot -ExpectedPlanHash ('1' * 64) } 'backup-receipt-verifier-invalid' 'drifted plan hashes fail the binding check'

    $snapshotTamper = New-HappyReceipt -SourceOperationKind 'retirement'
    Write-TextFile -Path (Join-Path ([string] $snapshotTamper.Result.ReceiptPath) 'snapshot/claude/kept-claude/SKILL.md') -Content 'tampered-snapshot'
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $snapshotTamper.Result.ReceiptPath) -ReservationIntent $snapshotTamper.Intent -BackupRoot $backupRoot } 'backup-receipt-verifier-invalid' 'a tampered managed snapshot fails verification'

    $preimageRemoval = New-HappyReceipt -SourceOperationKind 'retirement'
    Remove-Item -LiteralPath (Join-Path ([string] $preimageRemoval.Result.ReceiptPath) 'authority-preimage/current-env.json') -Force
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $preimageRemoval.Result.ReceiptPath) -ReservationIntent $preimageRemoval.Intent -BackupRoot $backupRoot } 'backup-receipt-verifier-invalid' 'a missing authority preimage fails verification'

    $markerTamper = New-HappyReceipt -SourceOperationKind 'retirement'
    Write-TextFile -Path (Join-Path ([string] $markerTamper.Result.ReceiptPath) '_meta/COMPLETE') -Content ('f' * 64)
    Assert-ThrowsToken { Assert-SealedBackupReceiptValid -ReceiptPath ([string] $markerTamper.Result.ReceiptPath) -ReservationIntent $markerTamper.Intent -BackupRoot $backupRoot } 'backup-receipt-verifier-invalid' 'a tampered COMPLETE marker fails verification'

    Write-Host '[missing authority preimages]'
    $intent = New-ReceiptIntent -BackupRoot $backupRoot
    $splat = New-ProducerSplat -Intent $intent -SourceOperationKind 'initial'
    $null = $splat.Remove('AuthorityStatePath')
    $null = $splat.Remove('RootClaimsPath')
    $missingPreimageResult = Invoke-SealedManagedBackupReceipt @splat
    Assert ($missingPreimageResult.AuthorityStatePreimage.Status -ceq 'MISSING' -and $missingPreimageResult.RootClaimsPreimage.Status -ceq 'MISSING') 'absent authority sources are recorded MISSING'
    Assert (-not (Test-Path -LiteralPath (Join-Path ([string] $missingPreimageResult.ReceiptPath) 'authority-preimage/current-env.json'))) 'MISSING preimages create no fake file'
    $null = Assert-SealedBackupReceiptValid -ReceiptPath ([string] $missingPreimageResult.ReceiptPath) -ReservationIntent $intent -BackupRoot $backupRoot -ExpectedSourceOperationKind 'initial'
    Assert $true 'MISSING preimage receipts pass consumer verification'

    Write-Host 'backup receipt tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
