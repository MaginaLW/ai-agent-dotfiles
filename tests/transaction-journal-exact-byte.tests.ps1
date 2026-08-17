#requires -Version 7.0

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/transaction-journal-common.ps1')

$script:pass = 0
$script:fail = 0
$work = Join-Path $RepoRoot 'tmp/transaction-journal-exact-byte-tests'
$raceHost = Join-Path $RepoRoot 'tests/helpers/journal-boundary-race-host.ps1'
$utf8 = [System.Text.UTF8Encoding]::new($false)

function Assert-TestCondition {
    param(
        [Parameter(Mandatory)] [bool] $Condition,
        [Parameter(Mandatory)] [string] $Message
    )

    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

function Write-TestMarker {
    param([Parameter(Mandatory)] [string] $Path)

    $bytes = [System.Text.Encoding]::ASCII.GetBytes('ready')
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Wait-TestMarker {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [int] $TimeoutMilliseconds = 15000
    )

    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    while (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path -PathType Leaf)) {
        if ($clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) {
            throw "Timed out waiting for test marker: $Path"
        }
        Start-Sleep -Milliseconds 10
    }
}

function Start-JournalRaceHost {
    param([Parameter(Mandatory)] [string[]] $Arguments)

    $start = [System.Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pwsh).Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.ArgumentList.Add('-NoProfile')
    $start.ArgumentList.Add('-File')
    $start.ArgumentList.Add($raceHost)
    foreach ($argument in $Arguments) { $start.ArgumentList.Add($argument) }
    return [System.Diagnostics.Process]::Start($start)
}

function Wait-JournalRaceHost {
    param(
        [Parameter(Mandatory)] [System.Diagnostics.Process] $Process,
        [Parameter(Mandatory)] [string] $ResultPath,
        [int] $TimeoutMilliseconds = 20000
    )

    if (-not $Process.WaitForExit($TimeoutMilliseconds)) {
        try { $Process.Kill($true) } catch {}
        throw 'Journal boundary race host did not exit before the timeout.'
    }
    if (-not (Microsoft.PowerShell.Management\Test-Path -LiteralPath $ResultPath -PathType Leaf)) {
        throw "Journal boundary race host produced no result (exit $($Process.ExitCode))."
    }
    return (Get-Content -Raw -LiteralPath $ResultPath | ConvertFrom-Json)
}

function New-TestJournalHeader {
    param(
        [Parameter(Mandatory)] [string] $Namespace,
        [Parameter(Mandatory)] [string] $TransactionId,
        [Parameter(Mandatory)] [string] $RecoveryRoot
    )

    return [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'canonical-journal-header'
        TransactionId = $TransactionId
        CanonicalOperationKind = 'normalize'
        OriginalDocumentHash = ('1' * 64)
        OriginalPlanHash = ('2' * 64)
        RepoId = ('3' * 64)
        GitCommonDirHash = ('4' * 64)
        WorktreeId = ('5' * 64)
        TransactionNamespace = [System.IO.Path]::GetFullPath($Namespace)
        RecoveryTransactionRoot = [System.IO.Path]::GetFullPath($RecoveryRoot)
        ExpectedPostconditionsHash = ('6' * 64)
        Targets = @()
    }
}

function New-RacePaths {
    param([Parameter(Mandatory)] [string] $Name)

    $root = Join-Path $work $Name
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    return [pscustomobject][ordered]@{
        Root = $root
        Ready = Join-Path $root 'ready.marker'
        Done = Join-Path $root 'done.marker'
        Result = Join-Path $root 'race-result.json'
    }
}

if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $work) {
    Remove-Item -LiteralPath $work -Recurse -Force
}
[System.IO.Directory]::CreateDirectory($work) | Out-Null

try {
    Write-Host '[production boundary surface]'
    $journalTokens=$null;$journalErrors=$null
    $journalAst=[System.Management.Automation.Language.Parser]::ParseFile((Join-Path $RepoRoot 'scripts/transaction-journal-common.ps1'),[ref]$journalTokens,[ref]$journalErrors)
    $journalScriptBlockParameters=@($journalAst.FindAll({param($node)$node -is [System.Management.Automation.Language.ParameterAst] -and $node.StaticType -eq [scriptblock]},$true))
    $journalTestSeamParameters=@($journalAst.FindAll({param($node)$node -is [System.Management.Automation.Language.ParameterAst] -and $node.Name.VariablePath.UserPath -match 'Hook|Callback|Failpoint|TestSeam|Internal'},$true))
    $journalPathScanCommands=@($journalAst.FindAll({param($node)$node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Get-ChildItem','Get-Item','Test-Path')},$true))
    $journalSource=$journalAst.Extent.Text
    $journalNoMemoState=(
        $null -eq (Get-Variable -Name CanonicalJournalSchemaValidationMemo -Scope Script -ErrorAction SilentlyContinue) -and
        $journalSource -notmatch '\$script:[A-Za-z0-9_]*(?:Memo|Cache|Gate)' -and
        $journalSource -notmatch 'GetNewClosure|Set-Item\s+-LiteralPath\s+Function:'
    )
    $journalSurfaceSafe=($journalErrors.Count -eq 0 -and $journalScriptBlockParameters.Count -eq 0 -and $journalTestSeamParameters.Count -eq 0 -and $journalPathScanCommands.Count -eq 0 -and $journalNoMemoState -and $journalSource -notmatch '\[System\.IO\.Directory\]::(?:Enumerate|Get)(?:Files|Directories|FileSystemEntries)')
    Assert-TestCondition $journalSurfaceSafe 'production journal exposes no injected seam and performs no path-based inventory scan'
    $journalCleanupRelative=($journalSource -match 'DeleteChildRegularFileIfIdentity' -and $journalSource -match 'DeleteChildEmptyDirectoryIfIdentity' -and $journalSource -notmatch '\[System\.IO\.(?:File|Directory)\]::(?:Exists|Delete)')
    Assert-TestCondition $journalCleanupRelative 'production journal cleanup uses only held-parent-relative identity deletion and no path fallback'

    Write-Host '[aggregate root/worktree held scan]'
    $getAllRoot = Join-Path $work 'get-all'
    $getAllTransactions = Join-Path $getAllRoot 'canonical-transactions'
    $getAllWorktreeName = ('a' * 64)
    $getAllWorktree = Join-Path $getAllTransactions $getAllWorktreeName
    $getAllId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $getAllNamespace = Join-Path $getAllWorktree $getAllId
    $getAllHeader = New-TestJournalHeader -Namespace $getAllNamespace -TransactionId $getAllId -RecoveryRoot (Join-Path $getAllRoot 'recovery')
    $getAllHeader.WorktreeId = $getAllWorktreeName
    $null = New-CanonicalJournalHeader -Document $getAllHeader -TransactionNamespace $getAllNamespace
    $getAllRace = New-RacePaths -Name 'get-all-parent-race'
    $getAllMoved = Join-Path $work 'get-all-moved'
    $getAllProcess = Start-JournalRaceHost -Arguments @(
        '-Mode', 'SwapDirectory',
        '-ReadyMarker', $getAllRace.Ready,
        '-DoneMarker', $getAllRace.Done,
        '-ResultPath', $getAllRace.Result,
        '-TargetPath', $getAllRoot,
        '-MovedPath', $getAllMoved,
        '-ReplacementRelativeDirectory', (Join-Path 'canonical-transactions' $getAllWorktreeName)
    )
    $script:GetAllOriginalSnapshot = (Get-Command Open-CanonicalJournalSnapshot -CommandType Function).ScriptBlock
    $script:GetAllTargetNamespace = [System.IO.Path]::GetFullPath($getAllNamespace)
    $script:GetAllRaceReady = $getAllRace.Ready
    $script:GetAllRaceDone = $getAllRace.Done
    $script:GetAllRaceSignaled = $false
    Set-Item -LiteralPath Function:\Open-CanonicalJournalSnapshot -Value {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$TransactionNamespace,[switch]$AllowUnfinished)
        if(-not $script:GetAllRaceSignaled -and [System.IO.Path]::GetFullPath($TransactionNamespace) -ceq $script:GetAllTargetNamespace){
            $script:GetAllRaceSignaled=$true
            Write-TestMarker -Path $script:GetAllRaceReady
            Wait-TestMarker -Path $script:GetAllRaceDone
        }
        return & $script:GetAllOriginalSnapshot -TransactionNamespace $TransactionNamespace -AllowUnfinished:$AllowUnfinished
    }
    $getAllStates=$null;$getAllError=$null
    try{$getAllStates=@(Get-CanonicalAllTransactionStates -TransactionsRoot $getAllTransactions)}
    catch{$getAllError=$_.Exception.Message}
    finally{Set-Item -LiteralPath Function:\Open-CanonicalJournalSnapshot -Value $script:GetAllOriginalSnapshot}
    $getAllRaceResult=Wait-JournalRaceHost -Process $getAllProcess -ResultPath $getAllRace.Result
    Write-Host ("  EVIDENCE signaled={0}; attempted={1}; parent-swapped={2}; blocked={3}; states={4}; error={5}" -f $script:GetAllRaceSignaled,$getAllRaceResult.Attempted,$getAllRaceResult.Succeeded,$getAllRaceResult.Blocked,@($getAllStates).Count,$getAllError)
    $getAllSource=(Get-Command Get-CanonicalAllTransactionStates -CommandType Function).ScriptBlock.Ast.Extent.Text
    $getAllStaticBoundary=(
        $getAllSource -notmatch 'Test-Path|EnumerateFileSystemEntries|\]::Inspect\(' -and
        ([regex]::Matches($getAllSource,'TryHoldPathChildDirectory').Count -ge 2) -and
        $getAllSource -match 'NamespaceHandle\.Info\.Identity' -and
        $getAllSource -match 'Assert-CanonicalJournalSnapshotInventory' -and
        $getAllSource -match 'Compare-CanonicalJournalNames'
    )
    Assert-TestCondition ($script:GetAllRaceSignaled -and [bool]$getAllRaceResult.Attempted -and [bool]$getAllRaceResult.Blocked -and $null -eq $getAllError -and @($getAllStates).Count -eq 1 -and $getAllStaticBoundary) 'global journal scan holds root/worktree/transaction identities until its full inventory is revalidated'

    Write-Host '[aggregate namespace inventory snapshot]'
    $aggregateRoot = Join-Path $work 'aggregate'
    $aggregateId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $aggregateNamespace = Join-Path $aggregateRoot $aggregateId
    $aggregateHeader = New-TestJournalHeader -Namespace $aggregateNamespace -TransactionId $aggregateId -RecoveryRoot (Join-Path $aggregateRoot 'recovery')
    $null = New-CanonicalJournalHeader -Document $aggregateHeader -TransactionNamespace $aggregateNamespace
    $script:AggregateNamespace = $aggregateNamespace
    $script:AggregateMutationRan = $false
    $script:AggregateOriginalRead = (Get-Command Read-CanonicalHeldJsonContractFile -CommandType Function).ScriptBlock
    Set-Item -LiteralPath Function:\Read-CanonicalHeldJsonContractFile -Value {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] $ParentHandle,
            [Parameter(Mandatory)] [string] $Name,
            [Parameter(Mandatory)] [string] $DisplayPath,
            [Parameter(Mandatory)] [string] $SchemaPath
        )

        $capture = & $script:AggregateOriginalRead -ParentHandle $ParentHandle -Name $Name -DisplayPath $DisplayPath -SchemaPath $SchemaPath
        if (-not $script:AggregateMutationRan -and $Name -ceq 'header.json') {
            $script:AggregateMutationRan = $true
            [System.IO.File]::WriteAllBytes((Join-Path $script:AggregateNamespace '000001.json'), $utf8.GetBytes('{}'))
        }
        return $capture
    }
    $aggregateRejected = $false
    $aggregateError = $null
    $aggregateState = $null
    try {
        $aggregateState = Read-CanonicalJournalDirectory -TransactionNamespace $aggregateNamespace -AllowUnfinished
    }
    catch {
        $aggregateRejected = $true
        $aggregateError = $_.Exception.Message
    }
    finally {
        Set-Item -LiteralPath Function:\Read-CanonicalHeldJsonContractFile -Value $script:AggregateOriginalRead
    }
    Write-Host ("  EVIDENCE mutation={0}; rejected={1}; returned-records={2}; returned-pending={3}; error={4}" -f
        $script:AggregateMutationRan, $aggregateRejected,
        $(if ($aggregateState) { @($aggregateState.Records).Count } else { -1 }),
        $(if ($aggregateState) { @($aggregateState.PendingEntries).Count } else { -1 }),
        $aggregateError)
    Assert-TestCondition ($script:AggregateMutationRan -and $aggregateRejected -and $aggregateError -ceq 'manual-recovery-required: canonical transaction inventory changed during held snapshot') 'journal aggregate rejects namespace inventory drift with its exact held-snapshot error'

    Write-Host '[aggregate pending inventory snapshot]'
    $pendingRoot = Join-Path $work 'aggregate-pending'
    $pendingId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $pendingNamespace = Join-Path $pendingRoot $pendingId
    $pendingHeader = New-TestJournalHeader -Namespace $pendingNamespace -TransactionId $pendingId -RecoveryRoot (Join-Path $pendingRoot 'recovery')
    $null = New-CanonicalJournalHeader -Document $pendingHeader -TransactionNamespace $pendingNamespace
    $script:PendingNamespace = $pendingNamespace
    $script:PendingMutationRan = $false
    $script:PendingOriginalRead = (Get-Command Read-CanonicalHeldJsonContractFile -CommandType Function).ScriptBlock
    Set-Item -LiteralPath Function:\Read-CanonicalHeldJsonContractFile -Value {
        [CmdletBinding()]
        param([Parameter(Mandatory)]$ParentHandle,[Parameter(Mandatory)][string]$Name,[Parameter(Mandatory)][string]$DisplayPath,[Parameter(Mandatory)][string]$SchemaPath)
        $capture=& $script:PendingOriginalRead -ParentHandle $ParentHandle -Name $Name -DisplayPath $DisplayPath -SchemaPath $SchemaPath
        if(-not $script:PendingMutationRan -and $Name -ceq 'header.json'){
            $script:PendingMutationRan=$true
            $pendingName='record-000001-{0}.tmp' -f [Guid]::NewGuid().ToString('N')
            [System.IO.File]::WriteAllBytes((Join-Path (Join-Path $script:PendingNamespace '_pending') $pendingName),$utf8.GetBytes('{}'))
        }
        return $capture
    }
    $pendingRejected=$false;$pendingError=$null
    try{$null=Read-CanonicalJournalDirectory -TransactionNamespace $pendingNamespace -AllowUnfinished}
    catch{$pendingRejected=$true;$pendingError=$_.Exception.Message}
    finally{Set-Item -LiteralPath Function:\Read-CanonicalHeldJsonContractFile -Value $script:PendingOriginalRead}
    Write-Host ("  EVIDENCE mutation={0}; rejected={1}; error={2}" -f $script:PendingMutationRan,$pendingRejected,$pendingError)
    Assert-TestCondition ($script:PendingMutationRan -and $pendingRejected -and $pendingError -ceq 'manual-recovery-required: canonical pending inventory changed during held snapshot') 'journal aggregate rejects pending inventory drift with its exact held-snapshot error'

    Write-Host '[atomic publish retains the exact held temp bytes]'
    $atomicRace = New-RacePaths -Name 'atomic-race'
    $atomicRoot = Join-Path $work 'atomic-publish'
    $atomicPending = Join-Path $atomicRoot '_pending'
    [System.IO.Directory]::CreateDirectory($atomicPending) | Out-Null
    $atomicFinal = Join-Path $atomicRoot 'result.json'
    $atomicTemp = Join-Path $atomicPending 'result-race.tmp'
    $atomicFixture = Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-transaction-result.valid.json'
    $atomicDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($atomicFixture, [System.Text.UTF8Encoding]::new($false, $true)))
    $atomicBytes = ConvertTo-SemanticJsonBytes -InputObject $atomicDocument
    $atomicText = $utf8.GetString($atomicBytes)
    $atomicReplacementText = $atomicText.Replace('"Result":"FAIL"', '"Result":"PASS"')
    if ($atomicReplacementText -ceq $atomicText -or $utf8.GetByteCount($atomicReplacementText) -ne $atomicBytes.Length) {
        throw 'Unable to construct a same-length atomic journal replacement fixture.'
    }
    $atomicReplacement = $utf8.GetBytes($atomicReplacementText)
    $atomicProcess = Start-JournalRaceHost -Arguments @(
        '-Mode', 'RewriteFile',
        '-ReadyMarker', $atomicRace.Ready,
        '-DoneMarker', $atomicRace.Done,
        '-ResultPath', $atomicRace.Result,
        '-TargetPath', $atomicTemp,
        '-ReplacementBase64', [Convert]::ToBase64String($atomicReplacement)
    )
    $script:AtomicPublishOriginal = (Get-Command Publish-CanonicalPreparedJsonArtifact -CommandType Function).ScriptBlock
    $script:AtomicFinalPath = [System.IO.Path]::GetFullPath($atomicFinal)
    $script:AtomicRaceReady = $atomicRace.Ready
    $script:AtomicRaceDone = $atomicRace.Done
    $script:AtomicRaceSignaled = $false
    $script:AtomicPreparedIdentity=$null;$script:AtomicPreparedSha=$null;$script:AtomicHandleIdentity=$null;$script:AtomicReadIdentity=$null;$script:AtomicPublishedIdentity=$null;$script:AtomicPublishedSha=$null;$script:AtomicFinalRelativeIdentity=$null
    Set-Item -LiteralPath Function:\Publish-CanonicalPreparedJsonArtifact -Value {
        [CmdletBinding()]
        param([Parameter(Mandatory)]$PreparedArtifact,[Parameter(Mandatory)]$FinalParent,[Parameter(Mandatory)][string]$FinalPath)
        if (-not $script:AtomicRaceSignaled -and [System.IO.Path]::GetFullPath($FinalPath) -ceq $script:AtomicFinalPath) {
            $script:AtomicPreparedIdentity=[string]$PreparedArtifact.Identity
            $script:AtomicPreparedSha=[string]$PreparedArtifact.Sha256
            $script:AtomicHandleIdentity=[string]$PreparedArtifact.HeldHandle.Info.Identity
            $script:AtomicReadIdentity=[string]$PreparedArtifact.HeldHandle.ReadResult.Identity
            $script:AtomicRaceSignaled = $true
            Write-TestMarker -Path $script:AtomicRaceReady
            Wait-TestMarker -Path $script:AtomicRaceDone
        }
        $published=& $script:AtomicPublishOriginal -PreparedArtifact $PreparedArtifact -FinalParent $FinalParent -FinalPath $FinalPath
        $script:AtomicPublishedIdentity=[string]$published.Identity
        $script:AtomicPublishedSha=[string]$published.Sha256
        $script:AtomicFinalRelativeIdentity=[string]([AiAgentDotfiles.NoFollowFile]::InspectChild($FinalParent,[System.IO.Path]::GetFileName($FinalPath))).Identity
        return $published
    }
    $atomicError = $null;$atomicPublish=$null
    try {
        $atomicPublish = Write-CanonicalAtomicJson -Document $atomicDocument -FinalPath $atomicFinal -PendingDirectory $atomicPending -PendingName 'result-race.tmp' -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json')
    }
    catch {
        $atomicError = $_.Exception.Message
    }
    finally {
        Set-Item -LiteralPath Function:\Publish-CanonicalPreparedJsonArtifact -Value $script:AtomicPublishOriginal
    }
    $atomicRaceResult = Wait-JournalRaceHost -Process $atomicProcess -ResultPath $atomicRace.Result
    $atomicFinalExists = Microsoft.PowerShell.Management\Test-Path -LiteralPath $atomicFinal -PathType Leaf
    $atomicFinalMatches = $false
    if ($atomicFinalExists) {
        $atomicFinalMatches = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($atomicFinal)) -ceq [Convert]::ToBase64String($atomicBytes)
    }
    $atomicPendingNames=@(Get-ChildItem -LiteralPath $atomicPending -Force)
    $atomicExpectedSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($atomicBytes)).ToLowerInvariant()
    $atomicIdentityMatches=@(@($script:AtomicPreparedIdentity,$script:AtomicHandleIdentity,$script:AtomicReadIdentity,$script:AtomicPublishedIdentity,$script:AtomicFinalRelativeIdentity,[string]$atomicPublish.Identity)|Where-Object{$_ -cne $script:AtomicPreparedIdentity}).Count -eq 0
    $atomicShaMatches=@(@($script:AtomicPreparedSha,$script:AtomicPublishedSha,[string]$atomicPublish.Sha256,$atomicExpectedSha)|Where-Object{$_ -cne $atomicExpectedSha}).Count -eq 0
    Write-Host ("  EVIDENCE signaled={0}; attempted={1}; rewrite-succeeded={2}; blocked={3}; publish-error={4}; final-exists={5}; final-exact={6}; pending={7}; identity={8}; sha={9}" -f
        $script:AtomicRaceSignaled, $atomicRaceResult.Attempted, $atomicRaceResult.Succeeded, $atomicRaceResult.Blocked, $atomicError, $atomicFinalExists, $atomicFinalMatches,$atomicPendingNames.Count,$atomicIdentityMatches,$atomicShaMatches)
    $atomicBoundarySafe = (
        $script:AtomicRaceSignaled -and
        [bool] $atomicRaceResult.Attempted -and
        [bool] $atomicRaceResult.Blocked -and
        $null -eq $atomicError -and
        $atomicFinalExists -and
        $atomicFinalMatches -and
        $atomicPendingNames.Count -eq 0 -and
        $atomicIdentityMatches -and
        $atomicShaMatches
    )
    Assert-TestCondition $atomicBoundarySafe 'journal publish holds and validates the exact temp bytes through atomic no-replace publication'

    Write-Host '[append keeps all prior published bytes held through publication]'
    $appendRoot = Join-Path $work 'append-prior'
    $appendId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $appendNamespace = Join-Path $appendRoot $appendId
    $appendHeader = New-TestJournalHeader -Namespace $appendNamespace -TransactionId $appendId -RecoveryRoot (Join-Path $appendRoot 'recovery')
    $null = New-CanonicalJournalHeader -Document $appendHeader -TransactionNamespace $appendNamespace
    $script:AppendHeaderPath = Join-Path $appendNamespace 'header.json'
    $script:AppendMutationAttempted = $false
    $script:AppendMutationBlocked = $false
    $script:AppendMutationSucceeded = $false
    $script:AppendMutationError = $null
    $script:AppendOriginalWrite = (Get-Command Publish-CanonicalHeldJson -CommandType Function).ScriptBlock
    Set-Item -LiteralPath Function:\Publish-CanonicalHeldJson -Value {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
            [Parameter(Mandatory)] $FinalParent,
            [Parameter(Mandatory)] [string] $FinalPath,
            [Parameter(Mandatory)] $PendingParent,
            [Parameter(Mandatory)] [string] $PendingPath,
            [Parameter(Mandatory)] [string] $PendingName,
            [Parameter(Mandatory)] [string] $SchemaPath
        )

        if (-not $script:AppendMutationAttempted -and [System.IO.Path]::GetFileName($FinalPath) -ceq '000001.json') {
            $script:AppendMutationAttempted = $true
            $before = [System.IO.File]::ReadAllBytes($script:AppendHeaderPath)
            $text = $utf8.GetString($before)
            $afterText = $text.Replace('"OriginalDocumentHash":"1', '"OriginalDocumentHash":"9')
            if ($afterText -ceq $text -or $utf8.GetByteCount($afterText) -ne $before.Length) {
                throw 'Unable to construct a same-length prior-header replacement fixture.'
            }
            try {
                [System.IO.File]::WriteAllBytes($script:AppendHeaderPath, $utf8.GetBytes($afterText))
                $script:AppendMutationSucceeded = $true
            }
            catch [System.IO.IOException] {
                $script:AppendMutationBlocked = $true
                $script:AppendMutationError = $_.Exception.Message
            }
            catch [System.UnauthorizedAccessException] {
                $script:AppendMutationBlocked = $true
                $script:AppendMutationError = $_.Exception.Message
            }
            catch {
                $script:AppendMutationError = $_.Exception.Message
            }
        }

        $arguments = @{
            Document = $Document
            FinalParent = $FinalParent
            FinalPath = $FinalPath
            PendingParent = $PendingParent
            PendingPath = $PendingPath
            PendingName = $PendingName
            SchemaPath = $SchemaPath
        }
        return & $script:AppendOriginalWrite @arguments
    }
    $appendError = $null
    try {
        $null = Add-CanonicalJournalRecord -TransactionNamespace $appendNamespace -Phase POSTCONDITIONS_OK -Data ([ordered]@{ PostconditionsHash = ('6' * 64) })
    }
    catch {
        $appendError = $_.Exception.Message
    }
    finally {
        Set-Item -LiteralPath Function:\Publish-CanonicalHeldJson -Value $script:AppendOriginalWrite
    }
    $appendFinalExists = Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $appendNamespace '000001.json') -PathType Leaf
    Write-Host ("  EVIDENCE attempted={0}; rewrite-succeeded={1}; blocked={2}; append-error={3}; new-final-exists={4}" -f
        $script:AppendMutationAttempted, $script:AppendMutationSucceeded, $script:AppendMutationBlocked, $appendError, $appendFinalExists)
    $appendBoundarySafe = (
        $script:AppendMutationAttempted -and
        $script:AppendMutationBlocked -and
        $null -eq $appendError -and
        $appendFinalExists
    )
    Assert-TestCondition $appendBoundarySafe 'journal append holds every prior published artifact until the new record is durably published'

    Write-Host '[schema validation batches one held snapshot by exact schema]'
    $batchRoot = Join-Path $work 'validation-batch'
    $batchId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $batchNamespace = Join-Path $batchRoot $batchId
    $batchHeader = New-TestJournalHeader -Namespace $batchNamespace -TransactionId $batchId -RecoveryRoot (Join-Path $batchRoot 'recovery')
    $script:BatchLaunches = [System.Collections.Generic.List[object]]::new()
    $script:BatchOriginalFilesValidator=(Get-Command Invoke-PinnedJsonSchemaValidatorFiles -CommandType Function).ScriptBlock
    Set-Item -LiteralPath Function:\Invoke-PinnedJsonSchemaValidatorFiles -Value {
        [CmdletBinding()]
        param($ToolLease,[string]$SchemaPath,[string[]]$InstancePaths,[int]$TimeoutMilliseconds=120000,[int]$ReapTimeoutMilliseconds=5000)
        $script:BatchLaunches.Add([pscustomobject]@{SchemaPath=$SchemaPath;InstancePaths=@($InstancePaths)})
        return & $script:BatchOriginalFilesValidator -ToolLease $ToolLease -SchemaPath $SchemaPath -InstancePaths $InstancePaths -TimeoutMilliseconds $TimeoutMilliseconds -ReapTimeoutMilliseconds $ReapTimeoutMilliseconds
    }
    $batchError = $null
    try {
        $null = New-CanonicalJournalHeader -Document $batchHeader -TransactionNamespace $batchNamespace
        $missingState = [ordered]@{ State = 'MISSING' }
        $emptyDirectoryHash = Get-CanonicalJournalEmptyDirectoryHash
        $preimagePath = Join-Path ([string]$batchHeader.RecoveryTransactionRoot) 'preimage'
        $swapOldPath = Join-Path ([string]$batchHeader.RecoveryTransactionRoot) 'swap-old'
        $null = Add-CanonicalJournalRecord -TransactionNamespace $batchNamespace -Phase WORKSPACE_CREATE_INTENT -Data ([ordered]@{ WorkspacePath=$preimagePath;WorkspaceRole='preimage';WorkspaceState=$missingState })
        $null = Add-CanonicalJournalRecord -TransactionNamespace $batchNamespace -Phase WORKSPACE_CREATED -Data ([ordered]@{ WorkspacePath=$preimagePath;WorkspaceRole='preimage';WorkspaceState=[ordered]@{State='PRESENT';Type='Directory';Hash=$emptyDirectoryHash;Identity='batch-preimage'};CreatedIdentity='batch-preimage' })
        $null = Add-CanonicalJournalRecord -TransactionNamespace $batchNamespace -Phase WORKSPACE_CREATE_INTENT -Data ([ordered]@{ WorkspacePath=$swapOldPath;WorkspaceRole='swap-old';WorkspaceState=$missingState })
        $null = Add-CanonicalJournalRecord -TransactionNamespace $batchNamespace -Phase WORKSPACE_CREATED -Data ([ordered]@{ WorkspacePath=$swapOldPath;WorkspaceRole='swap-old';WorkspaceState=[ordered]@{State='PRESENT';Type='Directory';Hash=$emptyDirectoryHash;Identity='batch-swap-old'};CreatedIdentity='batch-swap-old' })
        $null = Read-CanonicalJournalDirectory -TransactionNamespace $batchNamespace -AllowUnfinished
    }
    catch {
        $batchError = $_.Exception.Message
    }
    finally { Set-Item -LiteralPath Function:\Invoke-PinnedJsonSchemaValidatorFiles -Value $script:BatchOriginalFilesValidator }
    $batchFinalLaunches=@($script:BatchLaunches|Select-Object -Last 2)
    $batchHeaderInstanceCount=if($batchFinalLaunches.Count -ge 1){@($batchFinalLaunches[0].InstancePaths).Count}else{-1}
    $batchRecordInstanceCount=if($batchFinalLaunches.Count -ge 2){@($batchFinalLaunches[1].InstancePaths).Count}else{-1}
    $batchValidationSafe=($null -eq $batchError -and $batchFinalLaunches.Count -eq 2 -and $batchHeaderInstanceCount -eq 1 -and $batchRecordInstanceCount -eq 4)
    Write-Host ("  EVIDENCE total-group-launches={0}; final-snapshot-launches={1}; final-header-instances={2}; final-record-instances={3}; error={4}" -f $script:BatchLaunches.Count,$batchFinalLaunches.Count,$batchHeaderInstanceCount,$batchRecordInstanceCount,$batchError)
    Assert-TestCondition $batchValidationSafe 'journal validates one held snapshot with at most one external process per exact schema group'

    $batchTempBefore=@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'ai-agent-dotfiles-journal-batch-*' -ErrorAction SilentlyContinue|ForEach-Object Name)
    $batchFixturePath=Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-journal-record.valid.json'
    $batchRecordSchema=Join-Path $RepoRoot 'schemas/canonical-journal-record.schema.json'
    $batchValidBytes=[System.IO.File]::ReadAllBytes($batchFixturePath)
    $batchInvalidBytes=$utf8.GetBytes('{}')
    $batchCaptureRoot=Join-Path $work 'validation-batch-captures'
    [System.IO.Directory]::CreateDirectory($batchCaptureRoot)|Out-Null
    $batchCaptureParents=$null;$batchValidHandle=$null;$batchInvalidHandle=$null
    $batchWrongSchemaRejected=$false;$batchMixedError=$null;$batchUnknownError=$null;$batchUnknownResidueNames=@();$batchUnknownResidueChildren=@()
    try{
        $batchCaptureParents=Open-SafeDirectoryContainmentChain -Path $batchCaptureRoot
        $batchCaptureParent=$batchCaptureParents[$batchCaptureParents.Count-1]
        $batchValidHandle=[AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($batchCaptureParent,'valid.json',$batchValidBytes)
        $batchInvalidHandle=[AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($batchCaptureParent,'invalid.json',$batchInvalidBytes)
        $batchValidCapture=[pscustomobject]@{Path=(Join-Path $batchCaptureRoot 'valid.json');SchemaPath=$batchRecordSchema;Bytes=$batchValidBytes;Sha256=[string]$batchValidHandle.ReadResult.Sha256;Identity=[string]$batchValidHandle.ReadResult.Identity;Length=[long]$batchValidHandle.ReadResult.Length;Handle=$batchValidHandle}
        $batchInvalidCapture=[pscustomobject]@{Path=(Join-Path $batchCaptureRoot 'invalid.json');SchemaPath=$batchRecordSchema;Bytes=$batchInvalidBytes;Sha256=[string]$batchInvalidHandle.ReadResult.Sha256;Identity=[string]$batchInvalidHandle.ReadResult.Identity;Length=[long]$batchInvalidHandle.ReadResult.Length;Handle=$batchInvalidHandle}
        $batchWrongSchemaCapture=[pscustomobject]@{Path=$batchValidCapture.Path;SchemaPath=(Join-Path $RepoRoot 'schemas/canonical-journal-header.schema.json');Bytes=$batchValidBytes;Sha256=$batchValidCapture.Sha256;Identity=$batchValidCapture.Identity;Length=$batchValidCapture.Length;Handle=$batchValidHandle}
        try{Invoke-CanonicalJournalSchemaBatchValidation -SchemaPath $batchRecordSchema -Captures @($batchWrongSchemaCapture)}
        catch{$batchWrongSchemaRejected=$_.Exception.Message -cmatch 'belongs to a different schema'}
        try{Invoke-CanonicalJournalSchemaBatchValidation -SchemaPath $batchRecordSchema -Captures @($batchValidCapture,$batchInvalidCapture)}
        catch{$batchMixedError=$_.Exception.Message}

        $batchUnknownBefore=@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'ai-agent-dotfiles-journal-batch-*' -ErrorAction SilentlyContinue|ForEach-Object Name)
        $script:BatchCleanupOriginalFilesValidator=(Get-Command Invoke-PinnedJsonSchemaValidatorFiles -CommandType Function).ScriptBlock
        Set-Item -LiteralPath Function:\Invoke-PinnedJsonSchemaValidatorFiles -Value {
            [CmdletBinding()]
            param($ToolLease,[string]$SchemaPath,[string[]]$InstancePaths,[int]$TimeoutMilliseconds=120000,[int]$ReapTimeoutMilliseconds=5000)
            $unknownPath=Join-Path (Split-Path -Parent ([System.IO.Path]::GetFullPath($InstancePaths[0]))) 'unknown-race.json'
            [System.IO.File]::WriteAllBytes($unknownPath,[System.Text.Encoding]::ASCII.GetBytes('unknown cleanup sentinel'))
            return & $script:BatchCleanupOriginalFilesValidator -ToolLease $ToolLease -SchemaPath $SchemaPath -InstancePaths $InstancePaths -TimeoutMilliseconds $TimeoutMilliseconds -ReapTimeoutMilliseconds $ReapTimeoutMilliseconds
        }
        try{Invoke-CanonicalJournalSchemaBatchValidation -SchemaPath $batchRecordSchema -Captures @($batchValidCapture,$batchInvalidCapture)}
        catch{$batchUnknownError=$_.Exception}
        finally{Set-Item -LiteralPath Function:\Invoke-PinnedJsonSchemaValidatorFiles -Value $script:BatchCleanupOriginalFilesValidator}
        $batchUnknownAfter=@(Get-ChildItem -LiteralPath ([System.IO.Path]::GetTempPath()) -Directory -Filter 'ai-agent-dotfiles-journal-batch-*' -ErrorAction SilentlyContinue|ForEach-Object Name)
        $batchUnknownResidueNames=@($batchUnknownAfter|Where-Object{$_ -cnotin $batchUnknownBefore})
        if($batchUnknownResidueNames.Count -eq 1){$batchUnknownResidueChildren=@(Get-ChildItem -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) $batchUnknownResidueNames[0])|ForEach-Object Name)}
    }
    finally{
        if($batchInvalidHandle){$batchInvalidHandle.Dispose()}
        if($batchValidHandle){$batchValidHandle.Dispose()}
        if($batchCaptureParents){Close-SafeDirectoryContainmentChain -Handles $batchCaptureParents}
    }
    Assert-TestCondition ($batchWrongSchemaRejected -and $batchMixedError -cmatch 'JSON Schema validation failed with exit code' -and @(Compare-Object $batchTempBefore $batchUnknownBefore -CaseSensitive).Count -eq 0) 'journal schema batch binds every capture to its exact schema, rejects a mixed valid-invalid group, and removes its controlled copies'
    $batchCleanupDetail=if($batchUnknownError){[string]$batchUnknownError.Data['CanonicalJournalCleanupFailure']}else{''}
    $batchUnknownCleanupSafe=($batchUnknownError -and $batchUnknownError.Message -cmatch 'JSON Schema validation failed with exit code' -and $batchCleanupDetail -cmatch 'unknown or missing entry' -and $batchUnknownResidueNames.Count -eq 1 -and $batchUnknownResidueChildren.Count -eq 3 -and 'unknown-race.json' -cin $batchUnknownResidueChildren)
    foreach($residueName in $batchUnknownResidueNames){Remove-Item -LiteralPath (Join-Path ([System.IO.Path]::GetTempPath()) $residueName) -Recurse -Force}
    Assert-TestCondition $batchUnknownCleanupSafe 'journal batch preserves the primary validator error and leaves an unknown cleanup entry for manual inspection'

    Write-Host '[repo lock binds the exact acquired handle to a held parent]'
    $lockRace = New-RacePaths -Name 'lock-parent-race'
    $lockParent = Join-Path $work 'lock-contract'
    $lockMoved = Join-Path $work 'lock-contract-moved'
    [System.IO.Directory]::CreateDirectory($lockParent) | Out-Null
    $lockPath = Join-Path $lockParent 'canonical.lock'
    $lockHandle = $null
    $lockError = $null
    try {
        $lockHandle = Enter-CanonicalRepoLock -LockPath $lockPath -AllowCreate
    }
    catch {
        $lockError = $_.Exception.Message
    }
    finally {}
    $lockIdentityMatches=$false
    if($lockHandle){
        $lockRelativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($lockHandle.ParentHandles[$lockHandle.ParentHandles.Count-1],[System.IO.Path]::GetFileName($lockPath))
        $lockIdentityMatches=([string]$lockHandle.Info.Identity -ceq [string]$lockHandle.HeldLock.Info.Identity -and [string]$lockHandle.Info.Identity -ceq [string]$lockRelativeInfo.Identity)
    }
    $lockProcess = Start-JournalRaceHost -Arguments @(
        '-Mode', 'SwapDirectory',
        '-ReadyMarker', $lockRace.Ready,
        '-DoneMarker', $lockRace.Done,
        '-ResultPath', $lockRace.Result,
        '-TargetPath', $lockParent,
        '-MovedPath', $lockMoved,
        '-ReplacementLeafName', 'canonical.lock'
    )
    Write-TestMarker -Path $lockRace.Ready
    $lockRaceResult = Wait-JournalRaceHost -Process $lockProcess -ResultPath $lockRace.Result
    if ($lockHandle) { Exit-CanonicalRepoLock -LockHandle $lockHandle }
    $postExitSwapSucceeded=$false
    try{[System.IO.Directory]::Move($lockParent,$lockMoved);$postExitSwapSucceeded=$true}
    catch{}
    Write-Host ("  EVIDENCE attempted={0}; parent-swapped={1}; blocked={2}; lock-acquired={3}; identity-matches={4}; post-exit-swap={5}; lock-error={6}" -f
        $lockRaceResult.Attempted, $lockRaceResult.Succeeded, $lockRaceResult.Blocked, [bool]$lockHandle, $lockIdentityMatches, $postExitSwapSucceeded, $lockError)
    $lockBoundarySafe = (
        [bool] $lockRaceResult.Attempted -and
        [bool] $lockRaceResult.Blocked -and
        $null -ne $lockHandle -and
        $lockIdentityMatches -and
        $postExitSwapSucceeded -and
        $null -eq $lockError
    )
    Assert-TestCondition $lockBoundarySafe 'repo lock holds its parent and validates the identity of the exact acquired lock handle'

    Write-Host '[new transaction namespace remains under its held worktree parent]'
    $namespaceRace = New-RacePaths -Name 'namespace-parent-race'
    $namespaceParentRoot = Join-Path $work 'namespace-contract'
    $namespaceWorktree = Join-Path $namespaceParentRoot ('7' * 64)
    $namespaceMoved = Join-Path $work 'namespace-contract-moved'
    [System.IO.Directory]::CreateDirectory($namespaceWorktree) | Out-Null
    $namespaceId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $newNamespace = Join-Path $namespaceWorktree $namespaceId
    $newHeader = New-TestJournalHeader -Namespace $newNamespace -TransactionId $namespaceId -RecoveryRoot (Join-Path $work 'namespace-recovery')
    $namespaceProcess = Start-JournalRaceHost -Arguments @(
        '-Mode', 'SwapDirectory',
        '-ReadyMarker', $namespaceRace.Ready,
        '-DoneMarker', $namespaceRace.Done,
        '-ResultPath', $namespaceRace.Result,
        '-TargetPath', $namespaceParentRoot,
        '-MovedPath', $namespaceMoved,
        '-ReplacementRelativeDirectory', (Join-Path ('7' * 64) (Join-Path $namespaceId '_pending'))
    )
    $script:NamespaceWriteOriginal = (Get-Command Publish-CanonicalPreparedJsonArtifact -CommandType Function).ScriptBlock
    $script:NamespaceFinalPath = [System.IO.Path]::GetFullPath((Join-Path $newNamespace 'header.json'))
    $script:NamespaceRaceReady = $namespaceRace.Ready
    $script:NamespaceRaceDone = $namespaceRace.Done
    $script:NamespaceRaceSignaled = $false
    Set-Item -LiteralPath Function:\Publish-CanonicalPreparedJsonArtifact -Value {
        [CmdletBinding()]
        param(
            [Parameter(Mandatory)] $PreparedArtifact,
            [Parameter(Mandatory)] $FinalParent,
            [Parameter(Mandatory)] [string] $FinalPath
        )

        if (-not $script:NamespaceRaceSignaled -and [System.IO.Path]::GetFullPath($FinalPath) -ceq $script:NamespaceFinalPath) {
            $script:NamespaceRaceSignaled = $true
            Write-TestMarker -Path $script:NamespaceRaceReady
            Wait-TestMarker -Path $script:NamespaceRaceDone
        }
        $arguments = @{
            PreparedArtifact = $PreparedArtifact
            FinalParent = $FinalParent
            FinalPath = $FinalPath
        }
        return & $script:NamespaceWriteOriginal @arguments
    }
    $namespacePublish = $null
    $namespaceError = $null
    try {
        $namespacePublish = New-CanonicalJournalHeader -Document $newHeader -TransactionNamespace $newNamespace
    }
    catch {
        $namespaceError = $_.Exception.Message
    }
    finally {
        Set-Item -LiteralPath Function:\Publish-CanonicalPreparedJsonArtifact -Value $script:NamespaceWriteOriginal
    }
    $namespaceRaceResult = Wait-JournalRaceHost -Process $namespaceProcess -ResultPath $namespaceRace.Result
    $replacementHeaderExists = Microsoft.PowerShell.Management\Test-Path -LiteralPath (Join-Path $newNamespace 'header.json') -PathType Leaf
    $movedHeaderPath = Join-Path $namespaceMoved (Join-Path ('7' * 64) (Join-Path $namespaceId 'header.json'))
    $movedHeaderExists = Microsoft.PowerShell.Management\Test-Path -LiteralPath $movedHeaderPath -PathType Leaf
    $namespacePendingNames=@(Get-ChildItem -LiteralPath (Join-Path $newNamespace '_pending') -Force)
    $namespaceFinalBytes=if($replacementHeaderExists){[System.IO.File]::ReadAllBytes((Join-Path $newNamespace 'header.json'))}else{[byte[]]::new(0)}
    $namespaceExpectedBytes=ConvertTo-SemanticJsonBytes -InputObject $newHeader
    $namespaceExact=([Convert]::ToBase64String($namespaceFinalBytes) -ceq [Convert]::ToBase64String($namespaceExpectedBytes))
    $namespaceSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($namespaceFinalBytes)).ToLowerInvariant()
    $namespaceFinalHandles=$null;$namespaceIdentityMatches=$false
    try{
        $namespaceFinalHandles=Open-SafeDirectoryContainmentChain -Path $newNamespace
        $namespaceFinalInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($namespaceFinalHandles[$namespaceFinalHandles.Count-1],'header.json')
        $namespaceIdentityMatches=([string]$namespacePublish.Identity -ceq [string]$namespaceFinalInfo.Identity)
    }finally{if($namespaceFinalHandles){Close-SafeDirectoryContainmentChain -Handles $namespaceFinalHandles}}
    Write-Host ("  EVIDENCE signaled={0}; attempted={1}; parent-swapped={2}; blocked={3}; publish-succeeded={4}; final-header={5}; moved-header={6}; pending={7}; exact={8}; identity={9}; sha={10}; error={11}" -f
        $script:NamespaceRaceSignaled, $namespaceRaceResult.Attempted, $namespaceRaceResult.Succeeded, $namespaceRaceResult.Blocked,
        [bool]$namespacePublish, $replacementHeaderExists, $movedHeaderExists, $namespacePendingNames.Count, $namespaceExact, $namespaceIdentityMatches, $namespaceSha, $namespaceError)
    $namespaceBoundarySafe = (
        $script:NamespaceRaceSignaled -and
        [bool] $namespaceRaceResult.Attempted -and
        [bool] $namespaceRaceResult.Blocked -and
        $null -ne $namespacePublish -and
        $replacementHeaderExists -and
        -not $movedHeaderExists -and
        $namespacePendingNames.Count -eq 0 -and
        $namespaceExact -and
        $namespaceIdentityMatches -and
        [string]$namespacePublish.Sha256 -ceq $namespaceSha -and
        $null -eq $namespaceError
    )
    Assert-TestCondition $namespaceBoundarySafe 'new journal namespace and header publish stay under one held worktree parent identity'
}
finally {
    Write-Host ''
    Write-Host ("Transaction journal exact-byte tests: {0} passed, {1} failed" -f $script:pass, $script:fail)
    if (Microsoft.PowerShell.Management\Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}

if ($script:fail -gt 0) { exit 1 }
