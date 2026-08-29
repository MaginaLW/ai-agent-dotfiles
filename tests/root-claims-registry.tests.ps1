#requires -Version 7.0
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
. (Join-Path $RepoRoot 'tests/helpers/home-authority-test-host.ps1')
. (Join-Path $RepoRoot 'tests/helpers/path-safety-fixtures.ps1')

if (-not ('AiAgentDotfiles.ReceiptReleaseProbe' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Reflection;
using System.Threading;
using System.Threading.Tasks;

namespace AiAgentDotfiles {
    public sealed class ReceiptReleaseProbe : IDisposable {
        private readonly ManualResetEventSlim entered = new ManualResetEventSlim(false);
        private readonly ManualResetEventSlim release;
        private int failRemaining;
        private int disposeCount;
        private int successfulDisposeCount;

        public ReceiptReleaseProbe(bool block, bool failOnce) {
            release = new ManualResetEventSlim(!block);
            failRemaining = failOnce ? 1 : 0;
        }
        public int DisposeCount { get { return Volatile.Read(ref disposeCount); } }
        public int SuccessfulDisposeCount { get { return Volatile.Read(ref successfulDisposeCount); } }
        public bool IsDisposed { get { return SuccessfulDisposeCount != 0; } }
        public bool WaitUntilEntered(int milliseconds) { return entered.Wait(milliseconds); }
        public void AllowRelease() { release.Set(); }
        public void Dispose() {
            Interlocked.Increment(ref disposeCount);
            entered.Set();
            release.Wait();
            if (Interlocked.Exchange(ref failRemaining, 0) != 0)
                throw new InvalidOperationException("injected-dispose-failure");
            Interlocked.Increment(ref successfulDisposeCount);
        }

        private static Type FindRequiredType(string typeName) {
            foreach (Assembly assembly in AppDomain.CurrentDomain.GetAssemblies()) {
                Type candidate = assembly.GetType(typeName, false, false);
                if (candidate != null) return candidate;
            }
            throw new InvalidOperationException("test receipt type unavailable: " + typeName);
        }
        public static Task StartRelease(string typeName, string methodName, object wrapper) {
            return Task.Run(() => {
                MethodInfo method = FindRequiredType(typeName).GetMethod(methodName, BindingFlags.Public | BindingFlags.Static);
                if (method == null) throw new InvalidOperationException("test release method unavailable: " + methodName);
                try { method.Invoke(null, new object[] { wrapper }); }
                catch (TargetInvocationException error) { throw error.InnerException ?? error; }
            });
        }
    }
}
'@
}

function Assert-TestCondition([bool]$Condition,[string]$Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Assert-ThrowsPattern([scriptblock]$Action,[string]$Pattern,[string]$Message) {
    try { & $Action; throw "FAIL: $Message (did not throw)" }
    catch {
        if ($_.Exception.Message -like 'FAIL:*') { throw }
        if ($_.Exception.Message -notmatch $Pattern) { throw "FAIL: $Message (unexpected: $($_.Exception.Message))" }
        Write-Host "  PASS  $Message"
    }
}

function Assert-TestCurrentRouteMutationFailsClosed {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)]$CanonicalWitness,
        [Parameter(Mandatory)]$RootSet,
        [Parameter(Mandatory)][scriptblock]$Mutation,
        [Parameter(Mandatory)][string]$Message
    )
    $capture = Open-SealedRegistryCurrentRouteCapture -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness -CurrentRouteRootSet $RootSet -Reservations @()
    $routeBindings = @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetRouteLeaseRows($capture))
    $fixedLeases = @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetFixedLeases($capture))
    $liveSetLease = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($capture)
    $liveReceipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($liveSetLease)
    try {
        Assert-ThrowsPattern {
            & $Mutation $RootSet $capture
            Close-SealedRegistryCurrentRouteCapture -Capture $capture
        } 'route-witness-required' $Message
    }
    finally {
        if ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($capture)) {
            Close-SealedRegistryCurrentRouteCapture -Capture $capture
        }
    }
    Assert-TestCondition ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($capture) -and
        [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($liveReceipt) -and
        @($fixedLeases | Where-Object {
            -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact(
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($_))
        }).Count -eq 0 -and
        @($routeBindings | Where-Object {
            $lease = [AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetLease($_)
            -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact(
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($lease))
        }).Count -eq 0) "$Message cleanup releases every private held lease"
}

function Write-TestCreateNewFile([string]$Path,[byte[]]$Bytes) {
    $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $stream.Write($Bytes,0,$Bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

function Write-TestSemanticDocument([string]$Path,[System.Collections.IDictionary]$Document) {
    $bytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $Document)
    Write-TestCreateNewFile -Path $Path -Bytes $bytes
    return $bytes
}

function Set-TestDirectoryCurrentUserOnly([string]$Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true,$false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path)),$security)
}

function Set-TestDirectoryInheritedCurrentUserOnly([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $security = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($full))
    $security.SetAccessRuleProtection($false,$false)
    $accessRules = @($security.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier]))
    foreach ($rule in @($accessRules | Where-Object { -not $_.IsInherited })) { $security.RemoveAccessRuleSpecific($rule) }
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($full),$security)
    $snapshot = [AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($full)
    $evidence = ConvertFrom-HomeAuthoritySecuritySnapshot -Snapshot $snapshot -ResourceKind Directory
    $rules = @($evidence.AccessRules)
    if ([bool]$evidence.AreAccessRulesProtected -or $rules.Count -ne 1 -or -not [bool]$rules[0].IsInherited -or [string]$rules[0].Sid -cne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) {
        throw 'fixture failed to establish inherited-only current-user directory ACL'
    }
}

function Copy-TestSemanticDocument([System.Collections.IDictionary]$Document) {
    $bytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $Document)
    return ConvertFrom-SemanticJson -Json ([Text.UTF8Encoding]::new($false,$true).GetString($bytes))
}

function New-TestSyntheticTargetReceiptLease {
    param([Parameter(Mandatory)][object[]]$Handles)
    $wrapper = [pscustomobject]@{ IsClosed=$false }
    $rows = @($Handles | ForEach-Object { [pscustomobject]@{ Marker=[guid]::NewGuid().ToString('N') } })
    $receipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::BindExact(
        $wrapper,[pscustomobject]@{Kind='projection'},[pscustomobject]@{Kind='legacy'},
        [object[]]$rows,[object[]]$Handles,$null,$null)
    return [pscustomobject]@{ Wrapper=$wrapper; Receipt=$receipt; Handles=[object[]]$Handles }
}

function New-TestSyntheticLiveReceiptLease {
    param([Parameter(Mandatory)][object[]]$TargetLeaseWrappers)
    if ($TargetLeaseWrappers.Count -ne 3) { throw 'synthetic live receipt requires exactly three target leases' }
    $wrapper = [pscustomobject]@{ IsClosed=$false }
    $receipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::BindExact(
        $wrapper,[pscustomobject]@{Kind='authority'},[pscustomobject]@{Kind='canonical'},
        [pscustomobject]@{Kind='global'},[pscustomobject]@{Kind='markers'},
        [object[]]$TargetLeaseWrappers,[pscustomobject]@{Kind='projection'})
    return [pscustomobject]@{ Wrapper=$wrapper; Receipt=$receipt; TargetLeases=[object[]]$TargetLeaseWrappers }
}

function New-TestRegistryFixture([string]$Parent,[string]$Name,[string]$ProfileName='profile') {
    $root = [IO.Path]::GetFullPath((Join-Path $Parent $Name))
    $profile = Join-Path $root $ProfileName
    $roaming = Join-Path $root 'roaming'
    $local = Join-Path $root 'local'
    foreach ($path in @($root,$profile,$roaming,$local)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $context = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
    $intent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)
    $lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $intent
    try { Assert-TestCondition ($null -ne $lock) "$Name bootstrap returns the held global lock" }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
    return [pscustomobject][ordered]@{ Root=$root; Profile=$profile; Roaming=$roaming; Local=$local; Context=$context; Intent=$intent }
}

function New-TestRootClaims([Parameter(Mandatory)]$Context) {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($liveTarget in @($Context.LiveTargets)) {
        $target = $liveTarget.TargetContext
        $exists = [string]$target.TargetStatus -ceq 'EXISTS'
        $rows.Add([ordered]@{
            Platform = [string]$liveTarget.Platform
            LocationKey = [string]$target.LocationKey
            RequestedPath = [string]$target.RequestedPath
            InitialState = if ($exists) { 'EXISTS' } else { 'ABSENT' }
            VolumeId = [string]$target.VolumeId
            DeepestExistingParentPath = [string]$target.DeepestExistingParentPath
            DeepestExistingParentIdentity = [string]$target.DeepestExistingParentIdentity
            MissingRemainder = @($target.MissingRemainder)
            InitialDirectoryIdentity = if ($exists) { [string]$target.DeepestExistingParentIdentity } else { $null }
            ExpectedPostState = 'EXISTS'
        })
    }
    return [ordered]@{
        SchemaVersion = 1L
        ArtifactKind = 'root-claims'
        HomeAuthorityKey = [string]$Context.HomeAuthorityKey
        TokenSid = [string]$Context.TokenSid
        ResolverVersion = 'windows-token-sid-known-folder-v1'
        HomeRootLocationKey = [string]$Context.HomeRootLocationKey
        LiveRootClaims = @($rows)
    }
}

function New-TestCurrentEnvState([System.Collections.IDictionary]$Claims,[byte[]]$ClaimsBytes) {
    $parentIdentities = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($claim in @($Claims.LiveRootClaims)) { $null = $parentIdentities.Add([string]$claim.DeepestExistingParentIdentity) }
    $finalIdentities = [Collections.Generic.List[object]]::new()
    for ($index=0; $index -lt @($Claims.LiveRootClaims).Count; $index++) {
        $claim = $Claims.LiveRootClaims[$index]
        $marker = Get-NoFollowRootEntryMarker -Path ([string]$claim.RequestedPath)
        if ([string]$marker.EntryType -ceq 'MISSING') {
            [IO.Directory]::CreateDirectory([string]$claim.RequestedPath) | Out-Null
            $marker = Get-NoFollowRootEntryMarker -Path ([string]$claim.RequestedPath)
        }
        if ([string]$marker.EntryType -cne 'Directory' -or [string]$marker.Identity -notmatch '^[0-9a-f]{8}:[0-9a-f]{16}$') { throw "fixture live root is not a no-follow directory: $($claim.Platform)" }
        $directoryIdentity = [string]$marker.Identity
        if (-not $directoryIdentity.StartsWith(([string]$claim.VolumeId + ':'),[StringComparison]::Ordinal) -or $parentIdentities.Contains($directoryIdentity)) { throw "fixture live root identity is invalid: $($claim.Platform)" }
        if ([string]$claim.InitialState -ceq 'EXISTS' -and $directoryIdentity -cne [string]$claim.InitialDirectoryIdentity) { throw "fixture existing live root identity drifted: $($claim.Platform)" }
        $finalIdentities.Add([ordered]@{
            Platform = [string]$claim.Platform
            LocationKey = [string]$claim.LocationKey
            ResolvedPath = [string]$claim.RequestedPath
            VolumeId = [string]$claim.VolumeId
            DirectoryIdentity = $directoryIdentity
            FilesystemCapabilityHash = ([string]($index + 1) * 64)
        })
    }
    $platforms = @('Claude','Codex','Reasonix')
    $taskRows = @($platforms | ForEach-Object { [ordered]@{ Platform=$_; Skills=@() } })
    $manifestRows = for ($index=0; $index -lt 3; $index++) { [ordered]@{ Platform=$platforms[$index]; Hash=([string]($index + 4) * 64) } }
    $managedRows = for ($index=0; $index -lt 3; $index++) { [ordered]@{ Platform=$platforms[$index]; Hash=([string]($index + 7) * 64) } }
    return [ordered]@{
        SchemaVersion = 3L
        ArtifactKind = 'current-env-state'
        HomeAuthorityKey = [string]$Claims.HomeAuthorityKey
        AuthorityGeneration = 1L
        RootClaimsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($ClaimsBytes)).ToLowerInvariant()
        SelectionKind = 'environment'
        EnvironmentName = 'full'
        EnvironmentLockHash = ('b' * 64)
        TaskOverlayHash = ('c' * 64)
        TaskOverlaySkills = @($taskRows)
        ManifestHashes = @($manifestRows)
        FinalManagedHashes = @($managedRows)
        FinalResolvedIdentities = @($finalIdentities)
        FinalTargetContextHash = Get-SemanticJsonHash -InputObject @($finalIdentities)
        ControllerRepoFingerprint = ('7' * 64)
        ApprovedToolchainHash = ('8' * 64)
        PlanHash = ('9' * 64)
        DocumentHash = ('a' * 64)
        JournalId = '22222222-2222-4222-8222-222222222222'
        PreStatePhaseHash = ('d' * 64)
        LastOperationKind = 'initial'
        ReceiptId = '11111111-1111-4111-8111-111111111111'
        ReceiptHash = ('e' * 64)
    }
}

function Add-TestAuthorityArtifacts {
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][System.Collections.IDictionary]$Claims,
        [AllowNull()][System.Collections.IDictionary]$State
    )
    [IO.Directory]::CreateDirectory([string]$Context.AuthorityRoot) | Out-Null
    $claimsBytes = Write-TestSemanticDocument -Path ([string]$Context.RootClaimsPath) -Document $Claims
    $stateBytes = $null
    if ($null -ne $State) { $stateBytes = Write-TestSemanticDocument -Path ([string]$Context.CurrentEnvStatePath) -Document $State }
    return [pscustomobject][ordered]@{ ClaimsBytes=[byte[]]$claimsBytes; StateBytes=if($null -eq $stateBytes){$null}else{[byte[]]$stateBytes} }
}

function Get-TestRegistryTreeHash([Parameter(Mandatory)]$Fixture) {
    $lockRelative = [IO.Path]::GetRelativePath([string]$Fixture.Root,[string]$Fixture.Context.GlobalLiveLockPath).Replace([char]92,[char]47)
    $excluded = [Collections.Generic.List[string]]::new()
    $excluded.Add($lockRelative)
    if ($Fixture.PSObject.Properties['AdditionalSnapshotExclusions']) {
        foreach ($path in @($Fixture.AdditionalSnapshotExclusions)) {
            $excluded.Add([IO.Path]::GetRelativePath([string]$Fixture.Root,[string]$path).Replace([char]92,[char]47))
        }
    }
    return [string](Get-SafeTreeSnapshot -Root ([string]$Fixture.Root) -ExcludeRelativePaths @($excluded)).TreeHash
}

function Replace-TestDirectoryWithDifferentIdentity([string]$Path,[string]$ExpectedIdentity,[string]$KeeperRoot) {
    $full = [IO.Path]::GetFullPath($Path)
    [IO.Directory]::Delete($full)
    for ($attempt=0; $attempt -lt 4; $attempt++) {
        [IO.Directory]::CreateDirectory($full) | Out-Null
        $marker = Get-NoFollowRootEntryMarker -Path $full
        if ([string]$marker.EntryType -cne 'Directory') { throw 'fixture replacement is not a directory' }
        if ([string]$marker.Identity -cne $ExpectedIdentity) { return [string]$marker.Identity }
        $keeper = Join-Path $KeeperRoot ('.identity-reuse-keeper-' + $attempt)
        [IO.Directory]::Move($full,$keeper)
    }
    throw 'fixture could not force a distinct replacement directory identity'
}

function Assert-TestRegistryReadIsZeroWrite {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][scriptblock]$Assertions,[Parameter(Mandatory)][string]$Message)
    $lock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $Fixture.Context
    try {
        $before = Get-TestRegistryTreeHash -Fixture $Fixture
        $view = Get-SealedHomeAuthorityRegistryView -AuthorityContext $Fixture.Context -GlobalLockHandle $lock
        & $Assertions $view
        $after = Get-TestRegistryTreeHash -Fixture $Fixture
        Assert-TestCondition ($before -ceq $after) $Message
        return $view
    }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
}

function New-TestCanonicalClaim([Parameter(Mandatory)]$Fixture,[string]$Name='canonical',[string]$RepoPath,[string]$RecoveryRootPath) {
    $repo = if ([string]::IsNullOrWhiteSpace($RepoPath)) { Join-Path $Fixture.Root ($Name + '-repo') } else { [IO.Path]::GetFullPath($RepoPath) }
    $probe = Join-Path $Fixture.Root ($Name + '-probe')
    $recovery = if ([string]::IsNullOrWhiteSpace($RecoveryRootPath)) { Join-Path (Join-Path $Fixture.Root ($Name + '-recovery-parent')) 'recovery' } else { [IO.Path]::GetFullPath($RecoveryRootPath) }
    $recoveryParent = Split-Path -Parent $recovery
    [IO.Directory]::CreateDirectory($repo) | Out-Null
    [IO.Directory]::CreateDirectory($probe) | Out-Null
    [IO.Directory]::CreateDirectory($recoveryParent) | Out-Null
    Set-TestDirectoryCurrentUserOnly -Path $recoveryParent
    [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'),'registry fixture',[Text.UTF8Encoding]::new($false))
    & git init --quiet $repo
    if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
    & git -C $repo add fixture.txt
    if ($LASTEXITCODE -ne 0) { throw 'fixture git add failed' }
    & git -C $repo -c 'user.name=Registry Fixture' -c 'user.email=registry-fixture@example.invalid' commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
    $payload = New-CanonicalSetupPlanPayload -RepoRoot $repo -CanonicalRecoveryRoot $recovery -ControlBase ([string]$Fixture.Context.ControlBase) -BackupRoot ([string]$Fixture.Context.BackupRoot) -ProbeRoot $probe -ToolchainRoot $RepoRoot
    [IO.Directory]::CreateDirectory($recovery) | Out-Null
    Set-TestDirectoryCurrentUserOnly -Path $recovery
    $git = Get-CanonicalGitContext -RepoRoot $repo
    $paths = Get-CanonicalTransactionContractPaths -GitContext $git
    return [pscustomobject][ordered]@{
        Claim=$payload.ExpectedRootClaim; RepoId=[string]$payload.ExpectedRootClaim.RepoId
        RecoveryRoot=$recovery; RecoveryParent=$recoveryParent; RepoRoot=$repo
        GitContext=$git; ContractPaths=$paths; PlanPayload=$payload
    }
}

function Complete-TestCanonicalSetupState {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)]$CanonicalFixture)
    $state = New-CanonicalFinalSetupState -PlanPayload $CanonicalFixture.PlanPayload -RepoRoot $CanonicalFixture.RepoRoot
    $lock = Enter-CanonicalRepoLock -LockPath ([string]$CanonicalFixture.ContractPaths.LockPath) -AllowCreate
    try {
        $null = Write-TestSemanticDocument -Path ([string]$CanonicalFixture.ContractPaths.SetupStatePath) -Document $state
    }
    finally { Exit-CanonicalRepoLock -LockHandle $lock }
    $Fixture | Add-Member -NotePropertyName AdditionalSnapshotExclusions -NotePropertyValue @([string]$CanonicalFixture.ContractPaths.LockPath) -Force
    return $state
}

function Invoke-TestRegistryFailure([Parameter(Mandatory)]$Fixture,[string]$Pattern,[string]$Message) {
    $lock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $Fixture.Context
    try {
        Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $Fixture.Context -GlobalLockHandle $lock | Out-Null } $Pattern $Message
    }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
}

$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47)
$workRoot = [IO.Path]::GetFullPath((Join-Path $tempParent ('.rcr-' + [guid]::NewGuid().ToString('N'))))
[IO.Directory]::CreateDirectory($workRoot) | Out-Null

try {
    Write-Host 'Root claims registry tests'

    $blockingTargetProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $blockingTargetLease = New-TestSyntheticTargetReceiptLease -Handles @($blockingTargetProbe)
    $blockingTargetTask = $null
    try {
        $blockingTargetTask = [AiAgentDotfiles.ReceiptReleaseProbe]::StartRelease(
            'AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt','ReleaseForWrapperExact',$blockingTargetLease.Wrapper)
        Assert-TestCondition ($blockingTargetProbe.WaitUntilEntered(5000) -and
            [string][AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetCloseStateExact($blockingTargetLease.Receipt) -ceq 'CLOSING' -and
            -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($blockingTargetLease.Receipt) -and
            -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($blockingTargetLease.Receipt)) 'target receipt publishes an exact CLOSING state while physical release is active'
        Assert-ThrowsPattern {
            [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($blockingTargetLease.Wrapper) | Out-Null
        } 'target-context-close-active' 'a concurrent second target receipt close cannot return success while the first cleanup is active'
    }
    finally {
        $blockingTargetProbe.AllowRelease()
        if ($null -ne $blockingTargetTask) { $blockingTargetTask.GetAwaiter().GetResult() }
    }
    Assert-TestCondition ([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($blockingTargetLease.Receipt) -and
        -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($blockingTargetLease.Receipt) -and
        $blockingTargetProbe.IsDisposed) 'target receipt becomes CLOSED only after its physical handle release completes'

    $targetFailureTail = [AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)
    $targetFailureHead = [AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$true)
    $retryableTargetLease = New-TestSyntheticTargetReceiptLease -Handles @($targetFailureTail,$targetFailureHead)
    Assert-ThrowsPattern {
        [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($retryableTargetLease.Wrapper) | Out-Null
    } 'injected-dispose-failure' 'target receipt surfaces the primary injected physical cleanup failure'
    Assert-TestCondition ([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($retryableTargetLease.Receipt) -and
        -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($retryableTargetLease.Receipt) -and
        $targetFailureHead.DisposeCount -eq 1 -and $targetFailureTail.DisposeCount -eq 1 -and $targetFailureTail.IsDisposed) 'failed target cleanup returns to retryable OPEN without claiming CLOSED and still attempts every physical handle'
    [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($retryableTargetLease.Wrapper) | Out-Null
    Assert-TestCondition ([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($retryableTargetLease.Receipt) -and
        $targetFailureHead.IsDisposed -and $targetFailureTail.IsDisposed) 'retry completes target cleanup without leaking a handle after an injected failure'

    $liveBlockingTargets = @(
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)))
    )
    $blockingLiveLease = New-TestSyntheticLiveReceiptLease -TargetLeaseWrappers @($liveBlockingTargets.Wrapper)
    $liveBlockingProbe = [AiAgentDotfiles.ReceiptReleaseProbe]$liveBlockingTargets[2].Handles[0]
    $blockingLiveTask = $null
    try {
        $blockingLiveTask = [AiAgentDotfiles.ReceiptReleaseProbe]::StartRelease(
            'AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt','ReleaseForWrapperExact',$blockingLiveLease.Wrapper)
        Assert-TestCondition ($liveBlockingProbe.WaitUntilEntered(5000) -and
            [string][AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetCloseStateExact($blockingLiveLease.Receipt) -ceq 'CLOSING' -and
            -not [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsOpenExact($blockingLiveLease.Receipt)) 'live-set receipt publishes CLOSING while exact nested cleanup is active'
        Assert-ThrowsPattern {
            [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($blockingLiveLease.Wrapper) | Out-Null
        } 'target-context-close-active' 'a concurrent second live-set close cannot return success during nested cleanup'
    }
    finally {
        $liveBlockingProbe.AllowRelease()
        if ($null -ne $blockingLiveTask) { $blockingLiveTask.GetAwaiter().GetResult() }
    }
    Assert-TestCondition ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($blockingLiveLease.Receipt) -and
        @($liveBlockingTargets | Where-Object { -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($_.Receipt) }).Count -eq 0) 'live-set receipt reaches CLOSED only after all exact nested receipts close'

    $liveFailureProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$true)
    $liveFailureTargets = @(
        (New-TestSyntheticTargetReceiptLease -Handles @($liveFailureProbe))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
    )
    $retryableLiveLease = New-TestSyntheticLiveReceiptLease -TargetLeaseWrappers @($liveFailureTargets.Wrapper)
    Assert-ThrowsPattern {
        [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($retryableLiveLease.Wrapper) | Out-Null
    } 'injected-dispose-failure' 'live-set receipt surfaces the primary injected nested cleanup failure'
    Assert-TestCondition ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsOpenExact($retryableLiveLease.Receipt) -and
        -not [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($retryableLiveLease.Receipt) -and
        @($liveFailureTargets | Where-Object { $_.Handles[0].DisposeCount -ne 1 }).Count -eq 0) 'failed live-set cleanup is retryable, does not claim CLOSED, and attempts every nested lease'
    [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($retryableLiveLease.Wrapper) | Out-Null
    Assert-TestCondition ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($retryableLiveLease.Receipt) -and
        @($liveFailureTargets | Where-Object { -not $_.Handles[0].IsDisposed }).Count -eq 0) 'retry completes live-set cleanup without leaking a nested physical resource'

    $registryFailureProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$true)
    $registryReservation = New-TestSyntheticTargetReceiptLease -Handles @($registryFailureProbe)
    $registryFixed = New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false))
    $registryRoute = New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false))
    $registryLiveTargets = @(
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
    )
    $registryLive = New-TestSyntheticLiveReceiptLease -TargetLeaseWrappers @($registryLiveTargets.Wrapper)
    $registryRouteBinding = [AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::new(
        0L,[pscustomobject]@{Kind='spec'},$registryRoute.Wrapper,[pscustomobject]@{Kind='context'},
        'RepoRoot','PRESENT','D:\synthetic-route',('a' * 64),('b' * 64))
    $retryableRegistryCapture = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::new(
        $registryLive.Wrapper,[pscustomobject]@{Kind='live-projection'},
        [AiAgentDotfiles.SealedRegistryRouteLeaseBinding[]]@($registryRouteBinding),
        [object[]]@($registryReservation.Wrapper),[object[]]@($registryFixed.Wrapper),
        [pscustomobject]@{Kind='original'},[pscustomobject]@{Kind='canonical'},[pscustomobject]@{Kind='snapshot'},
        ('c' * 64),('d' * 64),('e' * 64))
    Assert-ThrowsPattern {
        [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($retryableRegistryCapture) | Out-Null
    } 'injected-dispose-failure' 'registry capture surfaces the primary injected reservation cleanup failure'
    Assert-TestCondition ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($retryableRegistryCapture) -and
        -not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($retryableRegistryCapture) -and
        $registryFailureProbe.DisposeCount -eq 1 -and $registryFixed.Handles[0].IsDisposed -and
        $registryRoute.Handles[0].IsDisposed -and @($registryLiveTargets | Where-Object { -not $_.Handles[0].IsDisposed }).Count -eq 0) 'failed registry cleanup returns to OPEN, does not claim CLOSED, and best-effort closes every other private resource'
    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($retryableRegistryCapture) | Out-Null
    Assert-TestCondition ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($retryableRegistryCapture) -and
        -not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($retryableRegistryCapture) -and
        $registryFailureProbe.IsDisposed) 'registry capture retry reaches CLOSED without leaking the initially failed resource'
    $markClosedMethod = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture].GetMethod('MarkClosed',[Reflection.BindingFlags]'Public,Instance,Static')
    Assert-TestCondition ($null -eq $markClosedMethod) 'registry capture exposes no public state-only API that can claim CLOSED before exact release'

    $registryBlockingProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $registryBlockingReservation = New-TestSyntheticTargetReceiptLease -Handles @($registryBlockingProbe)
    $registryBlockingLiveTargets = @(
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
        (New-TestSyntheticTargetReceiptLease -Handles @([AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)))
    )
    $registryBlockingLive = New-TestSyntheticLiveReceiptLease -TargetLeaseWrappers @($registryBlockingLiveTargets.Wrapper)
    $blockingRegistryCapture = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::new(
        $registryBlockingLive.Wrapper,[pscustomobject]@{Kind='live-projection'},
        [AiAgentDotfiles.SealedRegistryRouteLeaseBinding[]]@(),[object[]]@($registryBlockingReservation.Wrapper),[object[]]@(),
        [pscustomobject]@{Kind='original'},[pscustomobject]@{Kind='canonical'},[pscustomobject]@{Kind='snapshot'},
        ('f' * 64),('1' * 64),('2' * 64))
    $blockingRegistryTask = $null
    try {
        $blockingRegistryTask = [AiAgentDotfiles.ReceiptReleaseProbe]::StartRelease(
            'AiAgentDotfiles.SealedRegistryCurrentRouteCapture','ReleaseExact',$blockingRegistryCapture)
        Assert-TestCondition ($registryBlockingProbe.WaitUntilEntered(5000) -and
            [string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCloseStateExact($blockingRegistryCapture) -ceq 'CLOSING' -and
            -not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($blockingRegistryCapture)) 'registry capture publishes CLOSING during private cleanup'
        Assert-ThrowsPattern {
            [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($blockingRegistryCapture) | Out-Null
        } 'route-close-active' 'a concurrent second registry close cannot return success while the first cleanup is active'
    }
    finally {
        $registryBlockingProbe.AllowRelease()
        if ($null -ne $blockingRegistryTask) { $blockingRegistryTask.GetAwaiter().GetResult() }
    }
    Assert-TestCondition ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($blockingRegistryCapture) -and
        $registryBlockingProbe.IsDisposed) 'registry capture reaches CLOSED only after its physical release completes'

    $syntheticAliasLeft = [pscustomobject][ordered]@{
        RequestedPath='D:\synthetic-left\leaf'; MissingRemainder=@()
        Ancestors=@(
            [pscustomobject][ordered]@{Path='D:\';Identity='11111111:0000000000000001'},
            [pscustomobject][ordered]@{Path='D:\synthetic-left';Identity='11111111:0000000000000010'},
            [pscustomobject][ordered]@{Path='D:\synthetic-left\leaf';Identity='11111111:00000000000000ff'}
        )
    }
    $syntheticAliasRight = [pscustomobject][ordered]@{
        RequestedPath='D:\synthetic-right\leaf'; MissingRemainder=@()
        Ancestors=@(
            [pscustomobject][ordered]@{Path='D:\';Identity='11111111:0000000000000001'},
            [pscustomobject][ordered]@{Path='D:\synthetic-right';Identity='11111111:0000000000000020'},
            [pscustomobject][ordered]@{Path='D:\synthetic-right\leaf';Identity='11111111:00000000000000ff'}
        )
    }
    Assert-TestCondition (Test-SealedRegistryTargetContextsOverlap -Left $syntheticAliasLeft -Right $syntheticAliasRight) 'full target-context matrix detects identity alias across lexically disjoint paths'

    $pristine = New-TestRegistryFixture -Parent $workRoot -Name 'pristine'
    $fakeLock = [pscustomobject]@{}
    Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $fakeLock | Out-Null } '^home-authority-registry-lock-required$' 'registry rejects an untrusted lock-shaped caller value'

    $foreignLockRoot = Join-Path $pristine.Root 'foreign-lock-root'
    [IO.Directory]::CreateDirectory($foreignLockRoot) | Out-Null
    Set-TestDirectoryCurrentUserOnly -Path $foreignLockRoot
    $foreignLockPath = Join-Path $foreignLockRoot 'foreign.lock'
    $foreignTemplate = Get-HomeAuthorityCurrentUserOnlySecurityTemplate -TokenSid ([string]$pristine.Context.TokenSid) -ResourceKind File
    $foreignLock = Enter-HomeAuthorityLockFileCore -ParentPath $foreignLockRoot -LockPath $foreignLockPath -FileSecurityTemplate $foreignTemplate -Mode CreateNew -MissingToken 'foreign-lock-missing'
    $foreignControlParents = $null
    $foreignOriginalPath = $foreignLock.PSObject.Properties['Path'].Value
    $foreignOriginalParents = $foreignLock.PSObject.Properties['ParentHandles'].Value
    try {
        $foreignControlParents = Open-SafeDirectoryContainmentChain -Path ([string]$pristine.Context.ControlBase)
        $foreignLock | Add-Member -Force -MemberType NoteProperty -Name Path -Value ([IO.Path]::GetFullPath([string]$pristine.Context.GlobalLiveLockPath))
        $foreignLock | Add-Member -Force -MemberType NoteProperty -Name ParentHandles -Value $foreignControlParents
        $foreignLock | Add-Member -Force -MemberType NoteProperty -Name FixedEnvelopeHash -Value ('0' * 64)
        Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $foreignLock | Out-Null } '^home-authority-registry-lock-required$' 'registry rejects a genuine owner-bound lock wrapper acquired from a different file even when its mutable display claims the global path and parent'
    }
    finally {
        $foreignLock | Add-Member -Force -MemberType NoteProperty -Name Path -Value $foreignOriginalPath
        $foreignLock | Add-Member -Force -MemberType NoteProperty -Name ParentHandles -Value $foreignOriginalParents
        if ($null -ne $foreignControlParents) { Close-SafeDirectoryContainmentChain -Handles $foreignControlParents }
        Exit-HomeAuthorityLockHandle -LockHandle $foreignLock
    }

    $pristineLock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $pristine.Context
    try {
        Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $pristine.Context | Out-Null } '^operation-lock-busy$' 'global registry lock is zero-wait busy for a second caller'

        $clonedGlobalWrapper = [pscustomobject][ordered]@{
            Path=$pristineLock.Path; HeldLock=$pristineLock.HeldLock; ParentHandles=$pristineLock.ParentHandles
            Info=$pristineLock.Info; SecurityHash=$pristineLock.SecurityHash; FixedEnvelopeHash=$pristineLock.FixedEnvelopeHash
        }
        $clonedGlobalWrapper.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.HomeAuthorityLockHandle')
        Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $clonedGlobalWrapper | Out-Null } '^home-authority-registry-lock-required$' 'registry rejects a cloned wrapper even when it displays the exact acquired global handle and parent chain'

        $originalGlobalInfo = $pristineLock.PSObject.Properties['Info'].Value
        $originalGlobalParents = $pristineLock.PSObject.Properties['ParentHandles'].Value
        $alternateParentRoot = Join-Path $pristine.Root 'alternate-output-parent'
        [IO.Directory]::CreateDirectory($alternateParentRoot) | Out-Null
        $alternateParents = Open-SafeDirectoryContainmentChain -Path $alternateParentRoot
        try {
            $infoReads = [pscustomobject]@{Count=0L}
            $parentReads = [pscustomobject]@{Count=0L}
            $forgedInfo = [pscustomobject]@{Identity=[string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($alternateParents[$alternateParents.Count-1])}
            $infoGetter = {
                $infoReads.Count++
                if ($infoReads.Count -le 4) { return $originalGlobalInfo }
                return $forgedInfo
            }.GetNewClosure()
            $parentGetter = {
                $parentReads.Count++
                if ($parentReads.Count -le 4) { return $originalGlobalParents }
                return $alternateParents
            }.GetNewClosure()
            $pristineLock | Add-Member -Force -MemberType ScriptProperty -Name Info -Value $infoGetter
            $pristineLock | Add-Member -Force -MemberType ScriptProperty -Name ParentHandles -Value $parentGetter
            $statefulView = Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $pristineLock
            Assert-TestCondition ([string]$statefulView.GlobalLiveLockIdentity -ceq [string][AiAgentDotfiles.SafeLockFileHandle]::GetAcquiredIdentityExact($pristineLock.HeldLock) -and
                [string]$statefulView.ControlBaseIdentity -ceq [string][AiAgentDotfiles.SafeDirectoryHandle]::GetAcquiredIdentityExact($originalGlobalParents[$originalGlobalParents.Count-1])) 'registry output identities come from sealed exact evidence rather than post-validation stateful wrapper getters'
        }
        finally {
            $pristineLock | Add-Member -Force -MemberType NoteProperty -Name Info -Value $originalGlobalInfo
            $pristineLock | Add-Member -Force -MemberType NoteProperty -Name ParentHandles -Value $originalGlobalParents
            Close-SafeDirectoryContainmentChain -Handles $alternateParents
        }

        $before = Get-TestRegistryTreeHash -Fixture $pristine
        $first = Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $pristineLock
        $middle = Get-TestRegistryTreeHash -Fixture $pristine
        $second = Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $pristineLock
        $after = Get-TestRegistryTreeHash -Fixture $pristine
        Assert-TestCondition ([string]$first.MutationGate -ceq 'READY') 'pristine empty registry is READY'
        Assert-TestCondition (@($first.CanonicalClaims).Count -eq 0 -and @($first.Authorities).Count -eq 0 -and @($first.LiveTransactionMarkers).Count -eq 0 -and @($first.RootReservations).Count -eq 0) 'pristine registry enumerates no dynamic records'
        Assert-TestCondition ([string]$first.CanonicalNamespaceCoverage -ceq 'NO_CLAIMS' -and [string]$first.LiveTransactionCoverage -ceq 'EMPTY') 'pristine registry coverage is explicit'
        Assert-TestCondition ([string]$first.RegistryHash -cmatch '^[0-9a-f]{64}$' -and [string]$first.RegistryHash -ceq [string]$second.RegistryHash) 'pristine registry hash is stable under one held lock'
        Assert-TestCondition ($before -ceq $middle -and $middle -ceq $after) 'pristine repeated registry reads leave the fake private root byte-identical'
    }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $pristineLock }
    Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $pristine.Context -GlobalLockHandle $pristineLock | Out-Null } '^home-authority-registry-lock-required$' 'registry rejects a disposed genuine lock witness'

    $lockAds = New-TestRegistryFixture -Parent $workRoot -Name 'global-lock-ads'
    $lockAdsHandle = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $lockAds.Context
    $lockStreamName = 'registry-lock-test'
    try {
        Add-PathSafetyNamedStream -Path ([string]$lockAds.Context.GlobalLiveLockPath) -Name $lockStreamName
        Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $lockAds.Context -GlobalLockHandle $lockAdsHandle | Out-Null } '^home-authority-registry-lock-required$' 'held global lock with an injected ADS is no longer a trusted witness'
    }
    finally {
        try { Remove-Item -LiteralPath ([string]$lockAds.Context.GlobalLiveLockPath) -Stream $lockStreamName -Force -ErrorAction SilentlyContinue }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lockAdsHandle }
    }

    $claimsOnly = New-TestRegistryFixture -Parent $workRoot -Name 'claims-only'
    $claimsOnlyDocument = New-TestRootClaims -Context $claimsOnly.Context
    $null = Add-TestAuthorityArtifacts -Context $claimsOnly.Context -Claims $claimsOnlyDocument
    Assert-ThrowsPattern { Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $claimsOnly.Context | Out-Null } 'home-authority-bootstrap-manual-recovery-required:.*unexpected children' 'pristine bootstrap validator still rejects a legal dynamic authority child'
    $claimsOnlyView = Assert-TestRegistryReadIsZeroWrite -Fixture $claimsOnly -Message 'claims-only registry read is zero-write on the fake private root' -Assertions {
        param($view)
        Assert-TestCondition (@($view.Authorities).Count -eq 1 -and [string]$view.Authorities[0].StateStatus -ceq 'MISSING') 'claims-only authority state is MISSING'
        Assert-TestCondition ([string]$view.MutationGate -ceq 'REPAIR_ADOPT_ONLY' -and @($view.RepairOnlyAuthorities).Count -eq 1) 'claims-only authority is repair/adopt gated'
    }
    Assert-TestCondition (@($claimsOnlyView.RootReservations).Count -eq 3) 'claims-only authority retains all three immutable root reservations'

    $validState = New-TestRegistryFixture -Parent $workRoot -Name 'valid-state'
    $validClaims = New-TestRootClaims -Context $validState.Context
    $validClaimsBytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $validClaims)
    $validStateDocument = New-TestCurrentEnvState -Claims $validClaims -ClaimsBytes $validClaimsBytes
    $null = Add-TestAuthorityArtifacts -Context $validState.Context -Claims $validClaims -State $validStateDocument
    $validView = Assert-TestRegistryReadIsZeroWrite -Fixture $validState -Message 'valid-state registry read is zero-write on the fake private root' -Assertions {
        param($view)
        Assert-TestCondition ([string]$view.Authorities[0].StateStatus -ceq 'VALID') 'bound current-env state is VALID'
        Assert-TestCondition ([string]$view.MutationGate -ceq 'READY' -and @($view.RepairOnlyAuthorities).Count -eq 0) 'valid authority leaves the mutation gate READY'
    }
    Assert-TestCondition (@($validView.RootReservations | Where-Object { $null -ne $_.DirectoryIdentity }).Count -eq 3) 'valid state supplies all three final root identities'
    for ($index=0; $index -lt 3; $index++) {
        $actualMarker = Get-NoFollowRootEntryMarker -Path ([string]$validClaims.LiveRootClaims[$index].RequestedPath)
        Assert-TestCondition ([string]$actualMarker.EntryType -ceq 'Directory' -and [string]$actualMarker.Identity -ceq [string]$validStateDocument.FinalResolvedIdentities[$index].DirectoryIdentity) "valid state binds the actual no-follow $($validClaims.LiveRootClaims[$index].Platform) root identity"
    }

    $missingLiveRoot = New-TestRegistryFixture -Parent $workRoot -Name 'vslr-missing'
    $missingLiveClaims = New-TestRootClaims -Context $missingLiveRoot.Context
    $missingLiveClaimsBytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $missingLiveClaims)
    $missingLiveState = New-TestCurrentEnvState -Claims $missingLiveClaims -ClaimsBytes $missingLiveClaimsBytes
    $null = Add-TestAuthorityArtifacts -Context $missingLiveRoot.Context -Claims $missingLiveClaims -State $missingLiveState
    [IO.Directory]::Delete([string]$missingLiveClaims.LiveRootClaims[0].RequestedPath)
    Invoke-TestRegistryFailure -Fixture $missingLiveRoot -Pattern 'manual-recovery-required:.*(?:missing|Unable to open)' -Message 'VALID state with a deleted live root fails closed'

    $reparseLiveRoot = New-TestRegistryFixture -Parent $workRoot -Name 'vslr-reparse'
    $reparseLiveClaims = New-TestRootClaims -Context $reparseLiveRoot.Context
    $reparseLiveClaimsBytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $reparseLiveClaims)
    $reparseLiveState = New-TestCurrentEnvState -Claims $reparseLiveClaims -ClaimsBytes $reparseLiveClaimsBytes
    $null = Add-TestAuthorityArtifacts -Context $reparseLiveRoot.Context -Claims $reparseLiveClaims -State $reparseLiveState
    $reparsePath = [string]$reparseLiveClaims.LiveRootClaims[0].RequestedPath
    [IO.Directory]::Delete($reparsePath)
    $reparseTarget = Join-Path $reparseLiveRoot.Root 'live-root-junction-target'
    [IO.Directory]::CreateDirectory($reparseTarget) | Out-Null
    $null = New-PathSafetyJunction -Path $reparsePath -Target $reparseTarget
    Invoke-TestRegistryFailure -Fixture $reparseLiveRoot -Pattern 'manual-recovery-required:.*(?:reparse|no-follow directory)' -Message 'VALID state live root replaced by a junction fails closed without traversal'

    $driftLiveRoot = New-TestRegistryFixture -Parent $workRoot -Name 'vslr-identity-drift'
    $driftLiveClaims = New-TestRootClaims -Context $driftLiveRoot.Context
    $driftLiveClaimsBytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $driftLiveClaims)
    $driftLiveState = New-TestCurrentEnvState -Claims $driftLiveClaims -ClaimsBytes $driftLiveClaimsBytes
    $null = Add-TestAuthorityArtifacts -Context $driftLiveRoot.Context -Claims $driftLiveClaims -State $driftLiveState
    $driftPath = [string]$driftLiveClaims.LiveRootClaims[0].RequestedPath
    $expectedDriftIdentity = [string]$driftLiveState.FinalResolvedIdentities[0].DirectoryIdentity
    $replacementIdentity = Replace-TestDirectoryWithDifferentIdentity -Path $driftPath -ExpectedIdentity $expectedDriftIdentity -KeeperRoot ([string]$driftLiveRoot.Root)
    Assert-TestCondition ($replacementIdentity -cne $expectedDriftIdentity) 'delete/recreate fixture has a distinct live-root identity'
    Invoke-TestRegistryFailure -Fixture $driftLiveRoot -Pattern 'manual-recovery-required:.*identity differs from valid state' -Message 'VALID state live root delete/recreate identity drift fails closed'

    $invalidState = New-TestRegistryFixture -Parent $workRoot -Name 'invalid-state'
    $invalidClaims = New-TestRootClaims -Context $invalidState.Context
    $invalidClaimsBytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $invalidClaims)
    $invalidStateDocument = New-TestCurrentEnvState -Claims $invalidClaims -ClaimsBytes $invalidClaimsBytes
    $invalidStateDocument.RootClaimsHash = ('0' * 64)
    $invalidArtifacts = Add-TestAuthorityArtifacts -Context $invalidState.Context -Claims $invalidClaims -State $invalidStateDocument
    $invalidView = Assert-TestRegistryReadIsZeroWrite -Fixture $invalidState -Message 'invalid-state registry read is zero-write on the fake private root' -Assertions {
        param($view)
        Assert-TestCondition ([string]$view.Authorities[0].StateStatus -ceq 'INVALID') 'semantic state corruption is classified INVALID without erasing claims'
        Assert-TestCondition ([string]$view.MutationGate -ceq 'REPAIR_ADOPT_ONLY' -and @($view.RepairOnlyAuthorities) -contains [string]$invalidState.Context.HomeAuthorityKey) 'invalid state forces REPAIR_ADOPT_ONLY'
    }
    $invalidPaths = @($invalidView.RootReservations | ForEach-Object { [string]$_.RequestedPath } | Sort-Object -CaseSensitive)
    $claimedPaths = @($invalidClaims.LiveRootClaims | ForEach-Object { [string]$_.RequestedPath } | Sort-Object -CaseSensitive)
    Assert-TestCondition (($invalidPaths -join "`0") -ceq ($claimedPaths -join "`0")) 'invalid state preserves the immutable claims root set'
    $expectedInvalidBytesHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$invalidArtifacts.StateBytes)).ToLowerInvariant()
    Assert-TestCondition ([string]$invalidView.Authorities[0].StateBytesHash -ceq $expectedInvalidBytesHash -and [long]$invalidView.Authorities[0].StateLength -eq $invalidArtifacts.StateBytes.LongLength) 'invalid state exposes only raw held-file evidence'

    $canonical = New-TestRegistryFixture -Parent $workRoot -Name 'canonical'
    $canonicalFixture = New-TestCanonicalClaim -Fixture $canonical
    $claimPath = Join-Path $canonical.Context.CanonicalRootsRoot ($canonicalFixture.RepoId + '.json')
    $claimBytes = Write-TestSemanticDocument -Path $claimPath -Document $canonicalFixture.Claim
    $canonicalView = Assert-TestRegistryReadIsZeroWrite -Fixture $canonical -Message 'canonical-claim registry read is zero-write on the fake private root' -Assertions {
        param($view)
        Assert-TestCondition (@($view.CanonicalClaims).Count -eq 1 -and [string]$view.CanonicalClaims[0].RepoId -ceq $canonicalFixture.RepoId) 'dynamically generated canonical claim is accepted'
        Assert-TestCondition ([string]$view.CanonicalNamespaceCoverage -ceq 'CALLER_WITNESS_REQUIRED' -and [string]$view.CanonicalClaims[0].SetupStateStatus -ceq 'UNRESOLVED') 'canonical setup-state coverage remains explicitly unresolved'
        Assert-TestCondition ([string]$view.MutationGate -ceq 'CANONICAL_WITNESS_REQUIRED' -and @($view.MutationBlockers) -contains 'CANONICAL_WITNESS_REQUIRED') 'unwitnessed canonical claim blocks mutation explicitly'
        Assert-TestCondition ($null -eq $view.CanonicalClaims[0].CanonicalRecoveryRootInitialIdentity -and [string]$view.CanonicalClaims[0].CanonicalRecoveryRootIdentity -cmatch '^[0-9a-f]{8}:[0-9a-f]{16}$') 'post-plan recovery root is bound by its current held identity'
    }
    Assert-TestCondition ([string]$canonicalView.CanonicalClaims[0].ClaimBytesHash -ceq ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$claimBytes)).ToLowerInvariant())) 'canonical row binds the exact claim bytes'
    Assert-TestCondition ([string]$canonicalView.RootReservations[0].DirectoryIdentity -ceq [string]$canonicalView.CanonicalClaims[0].CanonicalRecoveryRootIdentity) 'canonical reservation uses the current recovery-root identity'
    Set-TestDirectoryInheritedCurrentUserOnly -Path ([string]$canonicalFixture.RecoveryRoot)
    Invoke-TestRegistryFailure -Fixture $canonical -Pattern 'manual-recovery-required:.*claimed protected template' -Message 'canonical recovery root with inherited-only current-user ACL fails closed'
    Set-TestDirectoryCurrentUserOnly -Path ([string]$canonicalFixture.RecoveryRoot)
    $wrongRepoId = if ($canonicalFixture.RepoId -cne ('0' * 64)) { '0' * 64 } else { 'f' * 64 }
    $wrongNamePath = Join-Path $canonical.Context.CanonicalRootsRoot ($wrongRepoId + '.json')
    $null = Write-TestSemanticDocument -Path $wrongNamePath -Document $canonicalFixture.Claim
    Invoke-TestRegistryFailure -Fixture $canonical -Pattern 'manual-recovery-required:.*filename/repository identity mismatch' -Message 'canonical claim filename tampering fails closed'
    [IO.File]::Delete($wrongNamePath)
    [IO.File]::Delete($claimPath)
    $tamperedClaim = Copy-TestSemanticDocument -Document $canonicalFixture.Claim
    $tamperedClaim.SetupIntentHash = if ([string]$tamperedClaim.SetupIntentHash -cne ('0' * 64)) { '0' * 64 } else { 'f' * 64 }
    $null = Write-TestSemanticDocument -Path $claimPath -Document $tamperedClaim
    Invoke-TestRegistryFailure -Fixture $canonical -Pattern 'manual-recovery-required:.*setup intent graph mismatch' -Message 'canonical claim semantic-hash tampering fails closed'

    $witnessed = New-TestRegistryFixture -Parent $workRoot -Name 'canonical-witnessed'
    $witnessedCanonical = New-TestCanonicalClaim -Fixture $witnessed
    $witnessedClaimPath = Join-Path $witnessed.Context.CanonicalRootsRoot ($witnessedCanonical.RepoId + '.json')
    $witnessedClaimBytes = Write-TestSemanticDocument -Path $witnessedClaimPath -Document $witnessedCanonical.Claim
    $witnessedState = Complete-TestCanonicalSetupState -Fixture $witnessed -CanonicalFixture $witnessedCanonical
    $reverseGlobalLock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $witnessed.Context
    $reverseCanonicalLock = $null
    $reverseCanonicalWitness = $null
    try {
        $reverseCanonicalLock = Enter-CanonicalRepoLock -LockPath ([string]$witnessedCanonical.ContractPaths.LockPath)
        $reverseCanonicalWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$witnessedCanonical.RepoRoot) -CanonicalLockHandle $reverseCanonicalLock -ToolchainRoot $RepoRoot
        $reverseRouteRootSet = New-SealedCurrentRouteRootSet -CanonicalWitness $reverseCanonicalWitness
        $reverseGlobalLock | Add-Member -NotePropertyName CanonicalWitnessHash -NotePropertyValue ([string]$reverseCanonicalWitness.WitnessHash)
        Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $reverseGlobalLock -CanonicalWitness $reverseCanonicalWitness -CurrentRouteRootSet $reverseRouteRootSet | Out-Null } '^canonical-witness-required$' 'a forged property cannot convert global-before-canonical acquisition into an issued lock-order binding'
    }
    finally {
        if ($null -ne $reverseCanonicalWitness) { Close-CanonicalHeldNamespaceWitness -Witness $reverseCanonicalWitness }
        if ($null -ne $reverseCanonicalLock) { Exit-CanonicalRepoLock -LockHandle $reverseCanonicalLock }
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $reverseGlobalLock
    }
    $canonicalLock = Enter-CanonicalRepoLock -LockPath ([string]$witnessedCanonical.ContractPaths.LockPath)
    $canonicalWitness = $null
    try {
        Assert-TestCondition ('AiAgentDotfiles.CanonicalRepoLockHandle' -cin @($canonicalLock.PSObject.TypeNames)) 'canonical lock acquisition returns the genuine typed handle'
        $canonicalWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$witnessedCanonical.RepoRoot) -CanonicalLockHandle $canonicalLock -ToolchainRoot $RepoRoot
        Assert-TestCondition ('AiAgentDotfiles.CanonicalNamespaceWitness' -cin @($canonicalWitness.PSObject.TypeNames)) 'canonical namespace witness is a typed held object'
        Assert-TestCondition ([string]$canonicalWitness.RepoId -ceq [string]$witnessedCanonical.RepoId -and [string]$canonicalWitness.GitCommonDirHash -ceq [string]$witnessedCanonical.Claim.GitCommonDirHash) 'canonical witness binds held GitCommonDir identity and path hash'
        Assert-TestCondition ([string]$canonicalWitness.SetupStateStatus -ceq 'VALID' -and [string]$canonicalWitness.SetupStateBytesHash -cmatch '^[0-9a-f]{64}$') 'canonical witness retains exact schema-valid setup-state bytes'
        $routeRootSet = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness
        Assert-TestCondition ('AiAgentDotfiles.SealedCurrentRouteRootSet' -cin @($routeRootSet.PSObject.TypeNames) -and @($routeRootSet.Roots).Count -eq 12) 'current route root set records every fixed and optional role explicitly'
        Assert-TestCondition (@($routeRootSet.Roots | Where-Object { [string]$_.Applicability -ceq 'NOT_APPLICABLE' }).Count -eq 8 -and [string]$routeRootSet.FilesystemCapabilityCoverage -ceq 'UNPROBED_READ_ONLY') 'canonical read route marks workspace/materialization/source/staging roles not applicable and capability unprobed'

        $shapedWitness = [pscustomobject]@{}
        $shapedWitness.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalNamespaceWitness')
        $globalLock = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $witnessed.Context -RequiredCanonicalWitness $canonicalWitness
        try {
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $shapedWitness | Out-Null } '^canonical-witness-required$' 'registry rejects a shaped canonical witness without held resources'
            $shapedRouteRootSet = [pscustomobject]@{}
            $shapedRouteRootSet.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedCurrentRouteRootSet')
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $shapedRouteRootSet | Out-Null } '^route-witness-required$' 'registry rejects a shaped current-route root set with an exact stable token'

            $cleanupConflictRoute = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -CandidateWorkspaceRoot ([string]$witnessed.Context.LiveTargets[0].TargetContext.RequestedPath)
            $originalRouteCleanup = (Get-Command Close-SealedRegistryCurrentRouteResources -CommandType Function).ScriptBlock
            $injectedRouteCleanup = {
                param($LiveSetLease,[object[]]$RouteLeases,[object[]]$FixedLeases,[object[]]$ReservationLeases)
                & $originalRouteCleanup -LiveSetLease $LiveSetLease -RouteLeases $RouteLeases -FixedLeases $FixedLeases -ReservationLeases $ReservationLeases
                throw 'injected-route-cleanup-error'
            }.GetNewClosure()
            Set-Item -LiteralPath 'Function:Close-SealedRegistryCurrentRouteResources' -Value $injectedRouteCleanup
            try {
                try {
                    Open-SealedRegistryCurrentRouteCapture -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $cleanupConflictRoute -Reservations @() | Out-Null
                    throw 'FAIL: route acquisition primary error survives cleanup failure (did not throw)'
                }
                catch {
                    if ($_.Exception.Message -like 'FAIL:*') { throw }
                    Assert-TestCondition ($_.Exception.Message -match 'current-route-forbidden-path-overlap' -and
                        [string]$_.Exception.Data['SealedRegistryRouteCleanupError'] -ceq 'injected-route-cleanup-error') 'route acquisition preserves its primary error and records cleanup failure as secondary evidence'
                }
            }
            finally { Set-Item -LiteralPath 'Function:Close-SealedRegistryCurrentRouteResources' -Value $originalRouteCleanup }

            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $mutableRootSet.Roots[4].Path = Join-Path $witnessed.Root 'post-capture-path-tamper'
            } -Message 'held current route rejects caller Path mutation after entry validation'
            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $mutableRootSet.Roots[4].Role = 'SourceRoot'
            } -Message 'held current route rejects caller Role mutation after entry validation'
            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $mutableRootSet.Roots[0].TargetContext = $mutableRootSet.Roots[1].TargetContext
            } -Message 'held current route rejects caller TargetContext replacement after entry validation'
            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $mutableRootSet.Roots[0].TargetContext.TargetStatus = 'MISSING'
            } -Message 'held current route rejects caller TargetContext status mutation after entry validation'
            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $mutableRootSet.Roots[0].TargetContext.RequestedInitialRootContextHash = ('0' * 64)
            } -Message 'held current route rejects caller TargetContext hash mutation after entry validation'
            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $mutableRootSet.RouteRootSetHash = ('0' * 64)
            } -Message 'held current route rejects caller route-result hash mutation after entry validation'
            Assert-TestCurrentRouteMutationFailsClosed -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -RootSet (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness) -Mutation {
                param($mutableRootSet,$capture)
                $capture.CurrentRouteRootSetHash = ('0' * 64)
            } -Message 'held current route rejects capture-result hash mutation before final assertion'
            $sealedRouteRootSet = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness
            $sealedRouteCapture = Open-SealedRegistryCurrentRouteCapture -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $sealedRouteRootSet -Reservations @()
            try {
                Assert-TestCondition ($sealedRouteCapture -is [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]) 'current-route capture is a genuine CLR-sealed object'
                foreach ($case in @(
                    [pscustomobject]@{Property='OriginalCurrentRouteRootSet';Value=(New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness)},
                    [pscustomobject]@{Property='CurrentRouteRootSetSnapshot';Value=(New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness)},
                    [pscustomobject]@{Property='CanonicalWitness';Value=$canonicalWitness},
                    [pscustomobject]@{Property='EntryCurrentRouteRootSetHash';Value=('0' * 64)},
                    [pscustomobject]@{Property='CurrentRouteRootSetSnapshotHash';Value=('0' * 64)}
                )) {
                    $property = [string]$case.Property
                    $value = $case.Value
                    Assert-ThrowsPattern { $sealedRouteCapture.$property = $value } 'route-witness-required' "CLR seal rejects replacement of $property"
                }
                $null = Assert-SealedRegistryCurrentRouteCaptureStable -Capture $sealedRouteCapture
                Assert-TestCondition $true 'sealed current-route capture remains stable after rejected replacement attempts'

                $sealedRouteBindings = @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetRouteLeaseRows($sealedRouteCapture))
                $sealedFixedLeases = @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetFixedLeases($sealedRouteCapture))
                $sealedLiveSetLease = [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($sealedRouteCapture)
                $sealedRouteCapture | Add-Member -Force -NotePropertyName OriginalCurrentRouteRootSet -NotePropertyValue (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness)
                $sealedRouteCapture | Add-Member -Force -NotePropertyName CurrentRouteRootSetSnapshot -NotePropertyValue (New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness)
                $sealedRouteCapture | Add-Member -Force -NotePropertyName CanonicalWitness -NotePropertyValue ([pscustomobject]@{})
                $sealedRouteCapture | Add-Member -Force -NotePropertyName EntryCurrentRouteRootSetHash -NotePropertyValue ('0' * 64)
                $sealedRouteCapture | Add-Member -Force -NotePropertyName CurrentRouteRootSetSnapshotHash -NotePropertyValue ('0' * 64)
                $sealedRouteCapture | Add-Member -Force -NotePropertyName RouteLeaseRows -NotePropertyValue @()
                $sealedRouteCapture | Add-Member -Force -NotePropertyName LiveSetLease -NotePropertyValue ([pscustomobject]@{})
                $sealedRouteCapture | Add-Member -Force -NotePropertyName LiveProjection -NotePropertyValue ([pscustomobject]@{})
                $sealedRouteCapture | Add-Member -Force -NotePropertyName HeldTargetSetHash -NotePropertyValue ('0' * 64)
                $sealedRouteCapture | Add-Member -Force -NotePropertyName IsClosed -NotePropertyValue $true
                $sealedRouteCapture | Add-Member -Force -MemberType ScriptMethod -Name MarkClosed -Value { throw 'forged-close-method' }
                $sealedRouteBindings[0] | Add-Member -Force -NotePropertyName RouteIndex -NotePropertyValue 5L
                $sealedRouteBindings[0] | Add-Member -Force -NotePropertyName Role -NotePropertyValue 'EnvironmentMaterializationRoot'
                $sealedRouteBindings[0] | Add-Member -Force -NotePropertyName Path -NotePropertyValue (Join-Path $witnessed.Root 'ets-shadow')
                $sealedRouteBindings[0] | Add-Member -Force -NotePropertyName Lease -NotePropertyValue ([pscustomobject]@{})
                $sealedRouteBindings[0] | Add-Member -Force -NotePropertyName Context -NotePropertyValue ([pscustomobject]@{})
                $sealedRouteBindings[0] | Add-Member -Force -NotePropertyName HeldMetadataHash -NotePropertyValue ('0' * 64)

                $sealedLiveReceipt = [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($sealedLiveSetLease)
                $sealedLiveTargetLeases = @([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($sealedLiveReceipt))
                $sealedAllTargetLeases = @($sealedLiveTargetLeases) + @($sealedFixedLeases) + @($sealedRouteBindings | ForEach-Object { [AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetLease($_) })
                $sealedAllTargetHandles = [Collections.Generic.List[object]]::new()
                foreach ($targetLease in $sealedAllTargetLeases) {
                    $targetReceipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($targetLease)
                    Assert-TestCondition ($targetReceipt -is [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt] -and
                        [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($targetReceipt)) 'nested target lease has a genuine open CLR receipt before forged cleanup displays'
                    foreach ($targetHandle in @([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($targetReceipt))) {
                        $sealedAllTargetHandles.Add($targetHandle)
                    }
                    $targetLease | Add-Member -Force -MemberType ScriptProperty -Name IsClosed -Value { $true }
                    $targetLease | Add-Member -Force -MemberType ScriptProperty -Name Handles -Value { @() }
                }
                $sealedLiveSetLease | Add-Member -Force -MemberType ScriptProperty -Name IsClosed -Value { $true }
                $sealedLiveSetLease | Add-Member -Force -MemberType ScriptProperty -Name TargetLeases -Value { @() }
                $null = Assert-SealedRegistryCurrentRouteCaptureStable -Capture $sealedRouteCapture
                Assert-TestCondition $true 'static CLR access ignores ETS shadows on capture, route bindings, and nested lease cleanup displays'
                Close-SealedRegistryCurrentRouteCapture -Capture $sealedRouteCapture
                Assert-TestCondition ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($sealedRouteCapture) -and
                    [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($sealedLiveReceipt) -and
                    @($sealedFixedLeases | Where-Object {
                        -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact(
                            [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($_))
                    }).Count -eq 0 -and
                    @($sealedRouteBindings | Where-Object {
                        $lease = [AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetLease($_)
                        -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact(
                            [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($lease))
                    }).Count -eq 0) 'static CLR cleanup releases private held leases despite forged closed and method shadows'
                Assert-TestCondition ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($sealedLiveReceipt) -and
                    @($sealedAllTargetLeases | Where-Object {
                        $targetReceipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($_)
                        -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($targetReceipt)
                    }).Count -eq 0 -and
                    @($sealedAllTargetHandles | Where-Object { [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'private nested receipts close every acquisition-time directory handle despite stateful IsClosed/Handles/TargetLeases shadows'
            }
            finally {
                if ($null -ne $sealedRouteCapture -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($sealedRouteCapture)) {
                    Close-SealedRegistryCurrentRouteCapture -Capture $sealedRouteCapture
                }
            }

            $beforeWitnessRead = Get-TestRegistryTreeHash -Fixture $witnessed
            $witnessedView = Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $routeRootSet
            $afterWitnessRead = Get-TestRegistryTreeHash -Fixture $witnessed
            Assert-TestCondition ($beforeWitnessRead -ceq $afterWitnessRead) 'canonical witness registry read is zero-write across private and Git namespaces'
            Assert-TestCondition ([string]$witnessedView.CanonicalClaims[0].SetupStateStatus -ceq 'VALID' -and [string]$witnessedView.CanonicalClaims[0].SetupStateRootClaimHash -ceq (Get-SemanticJsonHash -InputObject $witnessedCanonical.Claim)) 'registry pairs held setup state with the globally held exact claim'
            Assert-TestCondition ([string]$witnessedView.CanonicalClaims[0].SetupStateBytesHash -ceq [string]$canonicalWitness.SetupStateBytesHash -and [string]$witnessedView.CanonicalClaims[0].ClaimBytesHash -ceq ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$witnessedClaimBytes)).ToLowerInvariant())) 'registry projection binds both held claim and setup-state raw hashes'
            Assert-TestCondition ([string]$witnessedView.CanonicalClaims[0].SetupStateSemanticHash -ceq (Get-SemanticJsonHash -InputObject $canonicalWitness.SetupStateDocument)) 'registry derives setup-state semantics from the validated held capture'
            Assert-TestCondition ([string]$witnessedView.CanonicalNamespaceCoverage -ceq 'CURRENT_ROUTE_WITNESSED' -and [string]$witnessedView.CanonicalClaims[0].CanonicalTransactionCoverage -ceq 'WITNESSED') 'current canonical namespace coverage is explicit and witnessed'
            Assert-TestCondition ([string]$witnessedView.MutationGate -ceq 'READY' -and @($witnessedView.MutationBlockers).Count -eq 0) 'one valid witnessed canonical claim leaves the isolated registry gate READY'
            Assert-TestCondition ([string]$witnessedView.CurrentRouteCoverage -ceq 'HELD_METADATA_VERIFIED' -and [string]$witnessedView.FilesystemCapabilityCoverage -ceq 'UNPROBED_READ_ONLY' -and [string]$witnessedView.CurrentRouteRootSetHash -ceq [string]$routeRootSet.RouteRootSetHash) 'registry exposes held current-route metadata coverage without overstating capability validation'

            $originalSetupCapture = $canonicalWitness.PSObject.Properties['SetupStateCapture'].Value
            $originalSetupDocument = $canonicalWitness.PSObject.Properties['SetupStateDocument'].Value
            $originalRepoId = $canonicalWitness.PSObject.Properties['RepoId'].Value
            $originalGitCommonDirHash = $canonicalWitness.PSObject.Properties['GitCommonDirHash'].Value
            $originalTransactionSetHash = $canonicalWitness.PSObject.Properties['CanonicalTransactionSetHash'].Value
            $originalSetupIdentity = $originalSetupCapture.PSObject.Properties['Identity'].Value
            $originalSetupLength = $originalSetupCapture.PSObject.Properties['Length'].Value
            $originalSetupBytesHash = $originalSetupCapture.PSObject.Properties['BytesHash'].Value
            $originalSetupSemanticHash = $originalSetupCapture.PSObject.Properties['SemanticHash'].Value
            $abaTrap = [pscustomobject]@{Reads=0L}
            $directOutputGetter = {
                param($Original,$Poison)
                $stackNames = @((Get-PSCallStack) | ForEach-Object { [string]$_.FunctionName })
                if ('Get-SealedHomeAuthorityRegistryView' -cin $stackNames -and
                    'New-SealedRegistryCanonicalOutputEvidence' -cnotin $stackNames -and
                    'Assert-CanonicalHeldNamespaceWitness' -cnotin $stackNames -and
                    'Assert-CanonicalHeldSetupStateCapture' -cnotin $stackNames) {
                    $abaTrap.Reads++
                    return $Poison
                }
                return $Original
            }.GetNewClosure()
            $poisonSetupCapture = [pscustomobject]@{Identity='00000000:0000000000000000';Length=0L;BytesHash=('0' * 64);SemanticHash=('0' * 64)}
            $poisonSetupDocument = Copy-TestSemanticDocument -Document $witnessedState
            $poisonSetupDocument.RepoId = ('0' * 64)
            try {
                foreach ($case in @(
                    [pscustomobject]@{Owner=$canonicalWitness;Name='SetupStateCapture';Original=$originalSetupCapture;Poison=$poisonSetupCapture},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='SetupStateDocument';Original=$originalSetupDocument;Poison=$poisonSetupDocument},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='RepoId';Original=$originalRepoId;Poison=('0' * 64)},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='GitCommonDirHash';Original=$originalGitCommonDirHash;Poison=('0' * 64)},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='CanonicalTransactionSetHash';Original=$originalTransactionSetHash;Poison=('0' * 64)},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='Identity';Original=$originalSetupIdentity;Poison='00000000:0000000000000000'},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='Length';Original=$originalSetupLength;Poison=0L},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='BytesHash';Original=$originalSetupBytesHash;Poison=('0' * 64)},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='SemanticHash';Original=$originalSetupSemanticHash;Poison=('0' * 64)}
                )) {
                    $original = $case.Original
                    $poison = $case.Poison
                    $getter = { & $directOutputGetter $original $poison }.GetNewClosure()
                    $case.Owner | Add-Member -Force -MemberType ScriptProperty -Name ([string]$case.Name) -Value $getter
                }
                Assert-ThrowsPattern {
                    Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $routeRootSet | Out-Null
                } 'canonical-witness-required' 'stateful ABA canonical/setup getters fail closed instead of injecting identity, length, or hash output'
                Assert-TestCondition ($abaTrap.Reads -eq 0) 'registry never reaches post-validation output reads through stateful canonical/setup getters'
            }
            finally {
                foreach ($case in @(
                    [pscustomobject]@{Owner=$canonicalWitness;Name='SetupStateCapture';Value=$originalSetupCapture},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='SetupStateDocument';Value=$originalSetupDocument},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='RepoId';Value=$originalRepoId},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='GitCommonDirHash';Value=$originalGitCommonDirHash},
                    [pscustomobject]@{Owner=$canonicalWitness;Name='CanonicalTransactionSetHash';Value=$originalTransactionSetHash},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='Identity';Value=$originalSetupIdentity},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='Length';Value=$originalSetupLength},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='BytesHash';Value=$originalSetupBytesHash},
                    [pscustomobject]@{Owner=$originalSetupCapture;Name='SemanticHash';Value=$originalSetupSemanticHash}
                )) { $case.Owner | Add-Member -Force -MemberType NoteProperty -Name ([string]$case.Name) -Value $case.Value }
            }

            $claudePath = [string]$witnessed.Context.LiveTargets[0].TargetContext.RequestedPath
            $routeOverlapCases = @(
                [pscustomobject]@{Name='exact';Path=$claudePath},
                [pscustomobject]@{Name='descendant';Path=(Join-Path $claudePath 'candidate-workspace')},
                [pscustomobject]@{Name='ancestor';Path=(Split-Path -Parent $claudePath)}
            )
            foreach ($case in $routeOverlapCases) {
                $conflictingRoute = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -CandidateWorkspaceRoot ([string]$case.Path)
                Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $conflictingRoute | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' "current route rejects CandidateWorkspace $($case.Name) overlap with a live target"
            }

            $materializationConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -EnvironmentMaterializationRoot $claudePath
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $materializationConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects EnvironmentMaterializationRoot overlap with a live target'

            $fixedConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -CandidateWorkspaceRoot ([string]$witnessed.Context.BackupRoot)
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $fixedConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects CandidateWorkspace overlap with fixed BackupRoot infrastructure'

            $optionalConflictRoot = Join-Path $witnessed.Root 'optional-route-conflict'
            $optionalConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -CandidateWorkspaceRoot $optionalConflictRoot -LiveMutationStagingRoots @(
                [ordered]@{Platform='Claude';Path=(Join-Path $optionalConflictRoot 'staging')},
                [ordered]@{Platform='Codex';Path=(Join-Path $witnessed.Root 'staging-codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $witnessed.Root 'staging-reasonix')}
            )
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $optionalConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects overlap between optional candidate and staging roles'

            $safeMaterializationRoot = Join-Path $witnessed.Root 'safe-materialization'
            $safeSourceRoots = @(
                [ordered]@{Platform='Claude';Path=(Join-Path $safeMaterializationRoot 'claude')},
                [ordered]@{Platform='Codex';Path=(Join-Path $safeMaterializationRoot 'codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $safeMaterializationRoot 'reasonix')}
            )
            $safeStagingRoots = @(
                [ordered]@{Platform='Claude';Path=(Join-Path $witnessed.Root 'safe-staging-claude')},
                [ordered]@{Platform='Codex';Path=(Join-Path $witnessed.Root 'safe-staging-codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $witnessed.Root 'safe-staging-reasonix')}
            )
            $safeOptionalRoute = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -EnvironmentMaterializationRoot $safeMaterializationRoot -SourceRoots $safeSourceRoots -LiveMutationStagingRoots $safeStagingRoots
            $safeOptionalView = Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $safeOptionalRoute
            Assert-TestCondition ([string]$safeOptionalView.CurrentRouteRootSetHash -ceq [string]$safeOptionalRoute.RouteRootSetHash) 'current route permits one materialization root to contain three disjoint source roots while staging roots remain disjoint'

            $sourceStagingConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -SourceRoots $safeSourceRoots -LiveMutationStagingRoots @(
                [ordered]@{Platform='Claude';Path=([string]$safeSourceRoots[0].Path)},
                [ordered]@{Platform='Codex';Path=(Join-Path $witnessed.Root 'conflict-staging-codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $witnessed.Root 'conflict-staging-reasonix')}
            )
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $sourceStagingConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects SourceRoot overlap with LiveMutationStagingRoot'

            $materializationStagingConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -EnvironmentMaterializationRoot $safeMaterializationRoot -LiveMutationStagingRoots @(
                [ordered]@{Platform='Claude';Path=(Join-Path $safeMaterializationRoot 'staging')},
                [ordered]@{Platform='Codex';Path=(Join-Path $witnessed.Root 'materialization-staging-codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $witnessed.Root 'materialization-staging-reasonix')}
            )
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $materializationStagingConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects EnvironmentMaterializationRoot overlap with LiveMutationStagingRoot'

            $safeSourceBase = Join-Path $witnessed.Root 'source-fixtures'
            $sourceConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -SourceRoots @(
                [ordered]@{Platform='Claude';Path=$claudePath},
                [ordered]@{Platform='Codex';Path=(Join-Path $safeSourceBase 'codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $safeSourceBase 'reasonix')}
            )
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $sourceConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects a platform SourceRoot overlap with a live target'

            $safeStagingBase = Join-Path $witnessed.Root 'staging-fixtures'
            $stagingConflict = New-SealedCurrentRouteRootSet -CanonicalWitness $canonicalWitness -LiveMutationStagingRoots @(
                [ordered]@{Platform='Claude';Path=$claudePath},
                [ordered]@{Platform='Codex';Path=(Join-Path $safeStagingBase 'codex')},
                [ordered]@{Platform='Reasonix';Path=(Join-Path $safeStagingBase 'reasonix')}
            )
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $stagingConflict | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'current route rejects a LiveMutationStagingRoot overlap with a live target'
        }
        finally {
            Exit-HomeAuthorityGlobalLiveLock -LockHandle $globalLock
        }

        Close-CanonicalHeldNamespaceWitness -Witness $canonicalWitness
        $closedWitness = $canonicalWitness
        $canonicalWitness = $null
        Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $witnessed.Context -RequiredCanonicalWitness $closedWitness | Out-Null } '^canonical-witness-required$' 'global acquisition rejects a disposed genuine canonical witness before lock-order handoff'
    }
    finally {
        if ($null -ne $canonicalWitness) { Close-CanonicalHeldNamespaceWitness -Witness $canonicalWitness }
        Exit-CanonicalRepoLock -LockHandle $canonicalLock
    }

    $missingSetup = New-TestRegistryFixture -Parent $workRoot -Name 'cw-missing-state'
    $missingSetupCanonical = New-TestCanonicalClaim -Fixture $missingSetup
    $missingSetupClaimPath = Join-Path $missingSetup.Context.CanonicalRootsRoot ($missingSetupCanonical.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $missingSetupClaimPath -Document $missingSetupCanonical.Claim
    $missingSetupLock = Enter-CanonicalRepoLock -LockPath ([string]$missingSetupCanonical.ContractPaths.LockPath) -AllowCreate
    try {
        Assert-ThrowsPattern { Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$missingSetupCanonical.RepoRoot) -CanonicalLockHandle $missingSetupLock -ToolchainRoot $RepoRoot | Out-Null } '^canonical-setup-required$' 'claim-only current repository cannot fabricate a canonical setup-state witness'
    }
    finally { Exit-CanonicalRepoLock -LockHandle $missingSetupLock }

    $overlap = New-TestRegistryFixture -Parent $workRoot -Name 'cross-authority'
    $overlapClaimsA = New-TestRootClaims -Context $overlap.Context
    $null = Add-TestAuthorityArtifacts -Context $overlap.Context -Claims $overlapClaimsA
    $profileB = Join-Path $overlap.Root 'profile-b'
    [IO.Directory]::CreateDirectory($profileB) | Out-Null
    $contextB = Resolve-SealedHomeAuthorityTestContext -TokenSid ([string]$overlap.Context.TokenSid) -ProfileRoot $profileB -RoamingAppDataRoot ([string]$overlap.Roaming) -LocalAppDataRoot ([string]$overlap.Local) -ReasonixLiveSkillsPath ([string]$overlapClaimsA.LiveRootClaims[0].RequestedPath)
    $overlapClaimsB = New-TestRootClaims -Context $contextB
    $null = Add-TestAuthorityArtifacts -Context $contextB -Claims $overlapClaimsB
    Invoke-TestRegistryFailure -Fixture $overlap -Pattern 'manual-recovery-required:.*registry reserved roots overlap' -Message 'cross-authority reserved path overlap fails closed'

    $infrastructureOverlap = New-TestRegistryFixture -Parent $workRoot -Name 'fixed-infra-overlap'
    $infrastructureClaims = New-TestRootClaims -Context $infrastructureOverlap.Context
    $controlTarget = Resolve-TargetContext -Path ([string]$infrastructureOverlap.Context.ControlBase) -Mode MetadataOnly
    $reasonixClaim = $infrastructureClaims.LiveRootClaims[2]
    $reasonixClaim.LocationKey = [string]$controlTarget.LocationKey
    $reasonixClaim.RequestedPath = [string]$controlTarget.RequestedPath
    $reasonixClaim.InitialState = 'EXISTS'
    $reasonixClaim.VolumeId = [string]$controlTarget.VolumeId
    $reasonixClaim.DeepestExistingParentPath = [string]$controlTarget.DeepestExistingParentPath
    $reasonixClaim.DeepestExistingParentIdentity = [string]$controlTarget.DeepestExistingParentIdentity
    $reasonixClaim.MissingRemainder = @()
    $reasonixClaim.InitialDirectoryIdentity = [string]$controlTarget.DeepestExistingParentIdentity
    $null = Add-TestAuthorityArtifacts -Context $infrastructureOverlap.Context -Claims $infrastructureClaims
    Invoke-TestRegistryFailure -Fixture $infrastructureOverlap -Pattern 'manual-recovery-required:.*registry reservation overlaps fixed infrastructure' -Message 'home claim overlapping ControlBase fails closed'

    $insideLive = New-TestRegistryFixture -Parent $workRoot -Name 'tracked-tree-in-live'
    $insideLiveClaudePath = [string]$insideLive.Context.LiveTargets[0].TargetContext.RequestedPath
    $insideLiveRepo = Join-Path $insideLiveClaudePath 'cloned-repo-inside-live-root'
    $insideLiveCanonical = New-TestCanonicalClaim -Fixture $insideLive -Name 'inside-live' -RepoPath $insideLiveRepo
    $insideLiveContext = Resolve-SealedHomeAuthorityTestContext -TokenSid ([string]$insideLive.Context.TokenSid) -ProfileRoot ([string]$insideLive.Profile) -RoamingAppDataRoot ([string]$insideLive.Roaming) -LocalAppDataRoot ([string]$insideLive.Local)
    Assert-TestCondition ([string]$insideLiveContext.LiveTargets[0].TargetContext.TargetStatus -ceq 'EXISTS') 'fixture precondition: the Claude live target exists with the tracked tree inside it'
    $insideLiveClaimPath = Join-Path $insideLiveContext.CanonicalRootsRoot ($insideLiveCanonical.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $insideLiveClaimPath -Document $insideLiveCanonical.Claim
    $null = Complete-TestCanonicalSetupState -Fixture $insideLive -CanonicalFixture $insideLiveCanonical
    $insideLiveLock = Enter-CanonicalRepoLock -LockPath ([string]$insideLiveCanonical.ContractPaths.LockPath)
    $insideLiveWitness = $null
    try {
        $insideLiveWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$insideLiveCanonical.RepoRoot) -CanonicalLockHandle $insideLiveLock -ToolchainRoot $RepoRoot
        Assert-TestCondition (Test-TargetPathOverlap -Left ([string]$insideLiveWitness.GitCommonDir) -Right $insideLiveClaudePath) 'fixture precondition: the tracked GitCommonDir really is inside the Claude live root'
        $insideLiveRoute = New-SealedCurrentRouteRootSet -CanonicalWitness $insideLiveWitness
        $insideLiveGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $insideLiveContext -RequiredCanonicalWitness $insideLiveWitness
        try {
            Assert-ThrowsPattern { Get-SealedHomeAuthorityRegistryView -AuthorityContext $insideLiveContext -GlobalLockHandle $insideLiveGlobal -CanonicalWitness $insideLiveWitness -CurrentRouteRootSet $insideLiveRoute | Out-Null } 'manual-recovery-required:.*current-route-forbidden-path-overlap' 'a tracked Git working tree and GitCommonDir inside a live target root fail closed as forbidden route overlap'
        }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $insideLiveGlobal }
    }
    finally {
        if ($null -ne $insideLiveWitness) { Close-CanonicalHeldNamespaceWitness -Witness $insideLiveWitness }
        Exit-CanonicalRepoLock -LockHandle $insideLiveLock
    }

    $claimCollision = New-TestRegistryFixture -Parent $workRoot -Name 'claim-collision'
    $collisionA = New-TestCanonicalClaim -Fixture $claimCollision -Name 'collision-a'
    $collisionClaimPathA = Join-Path $claimCollision.Context.CanonicalRootsRoot ($collisionA.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $collisionClaimPathA -Document $collisionA.Claim
    $collisionB = New-TestCanonicalClaim -Fixture $claimCollision -Name 'collision-b' -RecoveryRootPath (Join-Path $collisionA.RecoveryRoot 'nested-recovery')
    Assert-TestCondition ($collisionB.RepoId -cne $collisionA.RepoId) 'fixture precondition: the colliding claim comes from a second repository identity'
    $collisionClaimPathB = Join-Path $claimCollision.Context.CanonicalRootsRoot ($collisionB.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $collisionClaimPathB -Document $collisionB.Claim
    Invoke-TestRegistryFailure -Fixture $claimCollision -Pattern 'manual-recovery-required:.*registry reserved roots overlap' -Message 'a second repository claim nested inside an existing claim recovery root fails closed'
    [IO.File]::Delete($collisionClaimPathB)
    $collisionDuplicate = New-TestCanonicalClaim -Fixture $claimCollision -Name 'collision-dup' -RecoveryRootPath ([string]$collisionA.RecoveryRoot)
    Assert-TestCondition ($collisionDuplicate.RepoId -cne $collisionA.RepoId) 'fixture precondition: the duplicate claim also comes from a second repository identity'
    $collisionClaimPathDup = Join-Path $claimCollision.Context.CanonicalRootsRoot ($collisionDuplicate.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $collisionClaimPathDup -Document $collisionDuplicate.Claim
    Invoke-TestRegistryFailure -Fixture $claimCollision -Pattern 'manual-recovery-required:.*registry reserved roots overlap' -Message 'a second repository claiming the exact same recovery root fails closed'

    $repoIdentity = New-TestRegistryFixture -Parent $workRoot -Name 'repo-identity'
    $identityMain = New-TestCanonicalClaim -Fixture $repoIdentity -Name 'identity-main'
    $identityWorktree = Join-Path $repoIdentity.Root 'identity-worktree'
    & git -C $identityMain.RepoRoot worktree add --quiet -b identity-wt $identityWorktree
    if ($LASTEXITCODE -ne 0) { throw 'fixture git worktree add failed' }
    $identityWorktreeGit = Get-CanonicalGitContext -RepoRoot $identityWorktree
    $identityWorktreePaths = Get-CanonicalTransactionContractPaths -GitContext $identityWorktreeGit
    Assert-TestCondition ([string]$identityWorktreePaths.LockPath -ceq [string]$identityMain.ContractPaths.LockPath) 'a linked worktree shares the main repository canonical contract namespace'
    Assert-TestCondition ((Get-CanonicalRepoIdentity -GitContext $identityWorktreeGit) -ceq $identityMain.RepoId) 'a linked worktree resolves the same canonical repository identity'
    $identityClone = Join-Path $repoIdentity.Root 'identity-clone'
    & git clone --quiet $identityMain.RepoRoot $identityClone
    if ($LASTEXITCODE -ne 0) { throw 'fixture git clone failed' }
    $identityCloneGit = Get-CanonicalGitContext -RepoRoot $identityClone
    $identityClonePaths = Get-CanonicalTransactionContractPaths -GitContext $identityCloneGit
    $identityCloneRepoId = Get-CanonicalRepoIdentity -GitContext $identityCloneGit
    Assert-TestCondition ($identityCloneRepoId -cne $identityMain.RepoId -and [string]$identityClonePaths.LockPath -cne [string]$identityMain.ContractPaths.LockPath) 'a second clone derives its own canonical identity and contract namespace'
    Assert-TestCondition ((Join-Path $repoIdentity.Context.CanonicalRootsRoot ($identityCloneRepoId + '.json')) -cne (Join-Path $repoIdentity.Context.CanonicalRootsRoot ($identityMain.RepoId + '.json'))) 'a second clone cannot collide with the existing canonical claim file'
    $identityMainLock = Enter-CanonicalRepoLock -LockPath ([string]$identityMain.ContractPaths.LockPath) -AllowCreate
    try {
        Assert-ThrowsPattern { Enter-CanonicalRepoLock -LockPath ([string]$identityWorktreePaths.LockPath) | Out-Null } '^operation-lock-busy$' 'a linked worktree contends on the one shared canonical lock'
        $identityCloneLock = Enter-CanonicalRepoLock -LockPath ([string]$identityClonePaths.LockPath) -AllowCreate
        try { Assert-TestCondition $true 'a second clone holds its own canonical lock concurrently with the main repository' }
        finally { Exit-CanonicalRepoLock -LockHandle $identityCloneLock }
    }
    finally { Exit-CanonicalRepoLock -LockHandle $identityMainLock }

    $partialOverlap = New-TestRegistryFixture -Parent $workRoot -Name 'partial-home-overlap'
    $partialClaimsA = New-TestRootClaims -Context $partialOverlap.Context
    $null = Add-TestAuthorityArtifacts -Context $partialOverlap.Context -Claims $partialClaimsA
    $partialProfileB = Join-Path $partialOverlap.Root 'profile-partial-b'
    [IO.Directory]::CreateDirectory($partialProfileB) | Out-Null
    $partialContextB = Resolve-SealedHomeAuthorityTestContext -TokenSid ([string]$partialOverlap.Context.TokenSid) -ProfileRoot $partialProfileB -RoamingAppDataRoot ([string]$partialOverlap.Roaming) -LocalAppDataRoot ([string]$partialOverlap.Local) -ReasonixLiveSkillsPath (Join-Path $partialClaimsA.LiveRootClaims[0].RequestedPath 'nested-reasonix-override')
    $partialClaimsB = New-TestRootClaims -Context $partialContextB
    $null = Add-TestAuthorityArtifacts -Context $partialContextB -Claims $partialClaimsB
    Invoke-TestRegistryFailure -Fixture $partialOverlap -Pattern 'manual-recovery-required:.*registry reserved roots overlap' -Message 'two HomeRoots with ancestor/descendant live-root overlap fail closed'

    foreach ($commandName in @(
        'Get-SealedHomeAuthorityRegistryView','Open-SealedRegistryCurrentRouteCapture',
        'Close-SealedRegistryCurrentRouteCapture','Assert-SealedRegistryCurrentRouteCaptureStable',
        'New-SealedCurrentRouteRootSet'
    )) {
        $registryCommand = Get-Command $commandName -ErrorAction Stop
        foreach ($publicSelector in @('HomeRoot','BackupRoot','LockWaitSeconds','TestMode')) {
            Assert-TestCondition (-not $registryCommand.Parameters.ContainsKey($publicSelector)) "$commandName rejects public -$publicSelector"
        }
    }

    $capabilityFixture = New-TestRegistryFixture -Parent $workRoot -Name 'capability-preflight'
    $capabilityCanonical = New-TestCanonicalClaim -Fixture $capabilityFixture -Name 'capability-canonical'
    $capabilityClaimPath = Join-Path $capabilityFixture.Context.CanonicalRootsRoot ($capabilityCanonical.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $capabilityClaimPath -Document $capabilityCanonical.Claim
    $null = Complete-TestCanonicalSetupState -Fixture $capabilityFixture -CanonicalFixture $capabilityCanonical
    $capabilityProbeRoot = Join-Path $capabilityFixture.Root 'capability-probe-root'
    $capabilityAlternateProbeRoot = Join-Path $capabilityFixture.Root 'capability-probe-root-alternate'
    foreach ($path in @($capabilityProbeRoot,$capabilityAlternateProbeRoot)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $capabilityLock = Enter-CanonicalRepoLock -LockPath ([string]$capabilityCanonical.ContractPaths.LockPath)
    $capabilityWitness = $null
    try {
        $capabilityWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$capabilityCanonical.RepoRoot) -CanonicalLockHandle $capabilityLock -ToolchainRoot $RepoRoot
        $capabilityGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $capabilityFixture.Context -RequiredCanonicalWitness $capabilityWitness
        try {
            $capabilityTreeBefore = Get-TestRegistryTreeHash -Fixture $capabilityFixture
            $capabilityProbeMetadata = Resolve-TargetContext -Path $capabilityProbeRoot -Mode MetadataOnly
            $capabilityEvidence = Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                [ordered]@{ Path = [string]$capabilityFixture.Context.ControlBase; ProbeRoot = $capabilityProbeRoot }
                [ordered]@{ Path = [string]$capabilityFixture.Context.BackupRoot; ProbeRoot = $capabilityProbeRoot }
                [ordered]@{ Path = [string]$capabilityCanonical.RecoveryRoot; ProbeRoot = $capabilityProbeRoot; ExpectedFilesystemCapabilityHash = [string]$capabilityCanonical.Claim.FilesystemCapabilityHash }
            )
            Assert-TestCondition ('AiAgentDotfiles.SealedCapabilityPreflightEvidence' -cin @($capabilityEvidence.PSObject.TypeNames)) 'held capability preflight returns a genuine CLR-sealed evidence object'
            Assert-TestCondition ($null -eq [AiAgentDotfiles.SealedCapabilityPreflightEvidence].GetMethod('GetProbeRootPathExact')) 'top-level single ProbeRootPath evidence is absent from the per-target mapping contract'
            Assert-TestCondition ([int][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowCountExact($capabilityEvidence) -eq 3) 'held capability preflight records one sealed row per requested target'
            $capabilityRows = @([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($capabilityEvidence))
            $capabilityRecoveryRow = @($capabilityRows | Where-Object {
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($_) -ceq
                    ([IO.Path]::GetFullPath([string]$capabilityCanonical.RecoveryRoot).TrimEnd([char]92,[char]47).ToLowerInvariant().Replace([char]92,[char]47))
            })[0]
            Assert-TestCondition ([string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($capabilityRecoveryRow) -ceq [string]$capabilityCanonical.Claim.FilesystemCapabilityHash -and
                [bool][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVerifiedAgainstExpectedExact($capabilityRecoveryRow)) 'the under-lock capability probe reproduces the plan-bound recovery root capability hash exactly'
            $capabilityControlRow = @($capabilityRows | Where-Object {
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($_) -ceq
                    ([IO.Path]::GetFullPath([string]$capabilityFixture.Context.ControlBase).TrimEnd([char]92,[char]47).ToLowerInvariant().Replace([char]92,[char]47))
            })[0]
            Assert-TestCondition ($null -eq [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetExpectedCapabilityHashExact($capabilityControlRow) -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetDriveTypeExact($capabilityControlRow) -ceq 'Fixed' -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFileSystemTypeExact($capabilityControlRow) -ceq 'NTFS' -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetTargetStatusExact($capabilityControlRow) -ceq 'EXISTS') 'control and backup rows carry real probed volume evidence without expected-hash claims'
            Assert-TestCondition ([string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($capabilityControlRow) -ceq [IO.Path]::GetFullPath($capabilityProbeRoot) -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootLocationKeyExact($capabilityControlRow) -ceq [IO.Path]::GetFullPath($capabilityProbeRoot).TrimEnd([char]92,[char]47).ToLowerInvariant().Replace([char]92,[char]47) -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($capabilityControlRow) -ceq [string]$capabilityProbeMetadata.DeepestExistingParentIdentity -and
                @($capabilityRows | Where-Object {
                    [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($_) -cne [IO.Path]::GetFullPath($capabilityProbeRoot) -or
                    [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($_) -cne [string]$capabilityProbeMetadata.DeepestExistingParentIdentity
                }).Count -eq 0) 'each sealed row binds its exact normalized shared-root mapping and no-follow root identity'
            Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $capabilityTreeBefore) 'the capability preflight writes nothing inside the controlled authority area'
            Assert-TestCondition (@([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'the capability preflight leaves zero probe slot residue in every approved probe root'
            Assert-TestCondition ((Get-SealedCapabilityPreflightProjectionHash -Evidence $capabilityEvidence) -ceq [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($capabilityEvidence)) 'the sealed preflight evidence projection hash is reproducible from its exact getters'
            $capabilityEvidence | Add-Member -Force -NotePropertyName ProjectionHash -NotePropertyValue ('0' * 64)
            $capabilityEvidence | Add-Member -Force -NotePropertyName Rows -NotePropertyValue @()
            $capabilityControlRow | Add-Member -Force -NotePropertyName ProbeRootPath -NotePropertyValue 'C:\forged-probe-root'
            $capabilityControlRow | Add-Member -Force -NotePropertyName ProbeRootLocationKey -NotePropertyValue 'c:/forged-probe-root'
            $capabilityControlRow | Add-Member -Force -NotePropertyName ProbeRootIdentity -NotePropertyValue 'ffffffff:ffffffffffffffff'
            $capabilityForgedRow = [pscustomobject]@{}
            $capabilityForgedRow.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedCapabilityPreflightRow')
            $capabilityEvidence | Add-Member -Force -NotePropertyName ForgedRow -NotePropertyValue $capabilityForgedRow
            Assert-TestCondition ((Get-SealedCapabilityPreflightProjectionHash -Evidence $capabilityEvidence) -ceq [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($capabilityEvidence) -and
                [int][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowCountExact($capabilityEvidence) -eq 3 -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($capabilityControlRow) -ceq [IO.Path]::GetFullPath($capabilityProbeRoot) -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($capabilityControlRow) -ceq [string]$capabilityProbeMetadata.DeepestExistingParentIdentity) 'ETS note-property forgeries cannot alter the sealed preflight evidence or target-to-probe mapping projection'

            Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path = [string]$capabilityFixture.Context.ControlBase; ProbeRoot = $capabilityProbeRoot; ExpectedFilesystemCapabilityHash = ('0' * 64) }) | Out-Null } '^capability-evidence-mismatch$' 'a capability preflight expected-hash mismatch fails closed after the real probe'

            $capabilityPrimarySingle = Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                [ordered]@{ Path = [string]$capabilityFixture.Context.ControlBase; ProbeRoot = $capabilityProbeRoot }
            )
            $capabilityAlternateSingle = Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                [ordered]@{ Path = [string]$capabilityFixture.Context.ControlBase; ProbeRoot = $capabilityAlternateProbeRoot }
            )
            $capabilityPrimaryRow = [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowExact($capabilityPrimarySingle,0)
            $capabilityAlternateRow = [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowExact($capabilityAlternateSingle,0)
            Assert-TestCondition ([string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($capabilityPrimaryRow) -ceq
                    [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($capabilityAlternateRow) -and
                [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($capabilityPrimarySingle) -cne
                    [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($capabilityAlternateSingle)) 'alternate same-volume probe roots preserve capability semantics while changing the sealed mapping projection'

            $permutationOriginalCapabilityProbe = (Get-Command Invoke-TargetFilesystemCapabilityProbe -CommandType Function -ErrorAction Stop).ScriptBlock
            $permutationProbeState = [pscustomobject]@{ Count=0L }
            $permutationProbeShadow = {
                param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                $permutationProbeState.Count++
                & $permutationOriginalCapabilityProbe -ProbeRoot $ProbeRoot -VolumeInfo $VolumeInfo -ExpectedProbeRootIdentity $ExpectedProbeRootIdentity
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $permutationProbeShadow
                $capabilityPermutationA = Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path = [string]$capabilityFixture.Context.ControlBase; ProbeRoot = $capabilityProbeRoot },
                    [ordered]@{ Path = [string]$capabilityFixture.Context.BackupRoot; ProbeRoot = $capabilityProbeRoot }
                )
                $capabilityPermutationB = Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path = [string]$capabilityFixture.Context.BackupRoot; ProbeRoot = $capabilityProbeRoot },
                    [ordered]@{ Path = [string]$capabilityFixture.Context.ControlBase; ProbeRoot = $capabilityProbeRoot }
                )
            }
            finally { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $permutationOriginalCapabilityProbe }
            Assert-TestCondition ([string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($capabilityPermutationA) -ceq
                    [string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetProjectionHashExact($capabilityPermutationB) -and
                (@([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($capabilityPermutationA) | ForEach-Object { [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($_) }) -join "`0") -ceq
                    (@([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($capabilityPermutationB) | ForEach-Object { [AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($_) }) -join "`0") -and
                [long]$permutationProbeState.Count -eq 4L) 'target input permutations produce one canonical row order and projection hash while probing every binding independently'

            $capabilityProbeFile = Join-Path $capabilityFixture.Root 'capability-probe-file'
            [IO.File]::WriteAllText($capabilityProbeFile,'not a directory',[Text.UTF8Encoding]::new($false))
            $capabilityTopologyOutside = Join-Path $capabilityFixture.Root 'capability-topology-outside'
            $capabilityProbeLeafJunction = Join-Path $capabilityFixture.Root 'capability-probe-leaf-junction'
            $capabilityProbeAncestorAlias = Join-Path $capabilityFixture.Root 'capability-probe-ancestor-alias'
            $capabilityTargetAncestorAlias = Join-Path $capabilityFixture.Root 'capability-target-ancestor-alias'
            $capabilityProbeOverlapParent = Join-Path $capabilityFixture.Root 'capability-probe-overlap-parent'
            $capabilityProbeOverlapChild = Join-Path $capabilityProbeOverlapParent 'child'
            $capabilityTargetOverlapParent = Join-Path $capabilityFixture.Root 'capability-target-overlap-parent'
            $capabilityTargetOverlapChild = Join-Path $capabilityTargetOverlapParent 'child'
            foreach ($path in @($capabilityTopologyOutside,(Join-Path $capabilityTopologyOutside 'probe-child'),(Join-Path $capabilityTopologyOutside 'target-child'),$capabilityProbeOverlapChild,$capabilityTargetOverlapChild)) {
                [IO.Directory]::CreateDirectory($path) | Out-Null
            }
            [IO.File]::WriteAllText((Join-Path $capabilityTopologyOutside 'outside-sentinel.bin'),'outside bytes',[Text.UTF8Encoding]::new($false))
            New-PathSafetyJunction -Path $capabilityProbeLeafJunction -Target (Join-Path $capabilityTopologyOutside 'probe-child') | Out-Null
            New-PathSafetyJunction -Path $capabilityProbeAncestorAlias -Target $capabilityTopologyOutside | Out-Null
            New-PathSafetyJunction -Path $capabilityTargetAncestorAlias -Target $capabilityTopologyOutside | Out-Null
            $capabilityResidueSlot = Join-Path $capabilityAlternateProbeRoot '.target-capability-preexisting-foreign'
            $capabilityResidueFile = Join-Path $capabilityResidueSlot 'foreign.bin'
            $capabilityResidueBytes = [Text.Encoding]::UTF8.GetBytes('preexisting foreign residue')
            [IO.Directory]::CreateDirectory($capabilityResidueSlot) | Out-Null
            [IO.File]::WriteAllBytes($capabilityResidueFile,$capabilityResidueBytes)

            $originalCapabilityProbe = (Get-Command Invoke-TargetFilesystemCapabilityProbe -CommandType Function -ErrorAction Stop).ScriptBlock
            $guardedCapabilityProbeState = [pscustomobject]@{ Count=0L }
            $guardedCapabilityProbe = {
                param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                $guardedCapabilityProbeState.Count++
                throw 'unexpected-capability-probe-invocation'
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $guardedCapabilityProbe
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @() | Out-Null } '^capability-preflight-target-required$' 'a capability preflight without targets fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @($null) | Out-Null } '^capability-preflight-target-required$' 'a null capability binding fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^capability-preflight-target-contract-invalid$' 'a capability binding missing Path fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase }) | Out-Null } '^capability-preflight-target-contract-invalid$' 'a capability binding missing ProbeRoot fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot; Extra='x' }) | Out-Null } '^capability-preflight-target-contract-invalid$' 'a capability binding with an extra property fails closed before any probe'
                $controlAlias = ([string]$capabilityFixture.Context.ControlBase).ToUpperInvariant().Replace([char]92,[char]47) + '/'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot },
                    [ordered]@{ Path=$controlAlias; ProbeRoot=$capabilityAlternateProbeRoot }
                ) | Out-Null } '^capability-preflight-target-duplicate$' 'case and separator aliases cannot duplicate one capability target'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path=$capabilityTargetOverlapParent; ProbeRoot=$capabilityProbeRoot },
                    [ordered]@{ Path=$capabilityTargetOverlapChild; ProbeRoot=$capabilityProbeRoot }
                ) | Out-Null } '^capability-preflight-target-duplicate$' 'existing ancestor and descendant capability targets cannot enter one preflight map'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=(Join-Path $capabilityFixture.Root 'capability-missing-probe-root') }) | Out-Null } '^capability-probe-root-invalid$' 'a missing probe root fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeFile }) | Out-Null } '^capability-probe-root-invalid$' 'a file probe root fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=$capabilityProbeFile; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^capability-preflight-target-contract-invalid$' 'an existing file cannot be supplied as a root capability target'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeLeafJunction }) | Out-Null } '^capability-probe-root-invalid$' 'a leaf reparse probe root fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=(Join-Path $capabilityProbeAncestorAlias 'probe-child') }) | Out-Null } '^capability-probe-root-invalid$' 'a probe root below a reparse ancestor fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=(Join-Path $capabilityTargetAncestorAlias 'target-child'); ProbeRoot=$capabilityProbeRoot }) | Out-Null } 'reparse' 'a capability target below a reparse ancestor fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.BackupRoot; ProbeRoot=[string]$capabilityFixture.Context.ControlBase }) | Out-Null } '^capability-probe-root-forbidden-overlap$' 'a probe root inside the authority area fails closed before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot },
                    [ordered]@{ Path=(Join-Path $capabilityProbeRoot 'nested-target'); ProbeRoot=$capabilityAlternateProbeRoot }
                ) | Out-Null } '^capability-probe-root-forbidden-overlap$' 'every probe root is checked against every capability target before any probe'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeOverlapParent },
                    [ordered]@{ Path=[string]$capabilityFixture.Context.BackupRoot; ProbeRoot=$capabilityProbeOverlapChild }
                ) | Out-Null } '^capability-probe-root-forbidden-overlap$' 'unique probe roots cannot overlap each other'
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                    [ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot },
                    [ordered]@{ Path=[string]$capabilityFixture.Context.BackupRoot; ProbeRoot=$capabilityAlternateProbeRoot }
                ) | Out-Null } '^capability-probe-root-residue$' 'residue in a later unique probe root fails the complete map before any probe'
                Assert-TestCondition ([long]$guardedCapabilityProbeState.Count -eq 0L) 'all contract, topology, overlap, and late-root residue failures occur before the first filesystem probe'
                Assert-TestCondition ((Test-Path -LiteralPath $capabilityResidueFile -PathType Leaf) -and
                    [Convert]::ToHexString([IO.File]::ReadAllBytes($capabilityResidueFile)) -ceq [Convert]::ToHexString($capabilityResidueBytes)) 'pre-existing late-root residue remains byte-identical after fail-closed validation'
            }
            finally {
                try { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $originalCapabilityProbe }
                finally {
                    foreach ($junctionPath in @($capabilityProbeLeafJunction,$capabilityProbeAncestorAlias,$capabilityTargetAncestorAlias)) {
                        if ([string](Get-NoFollowRootEntryMarker -Path $junctionPath).EntryType -ceq 'ReparsePoint') { Remove-Item -LiteralPath $junctionPath -Force }
                    }
                    if (Test-Path -LiteralPath $capabilityResidueSlot) { [IO.Directory]::Delete($capabilityResidueSlot,$true) }
                }
            }

            $foreignResidueSlot = Join-Path $capabilityProbeRoot '.target-capability-foreign-owned-by-test'
            $foreignResidueFile = Join-Path $foreignResidueSlot 'foreign.bin'
            $foreignResidueBytes = [Text.Encoding]::UTF8.GetBytes('foreign-capability-residue')
            $shadowCapabilityProbe = {
                param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                $capabilityHash = & $originalCapabilityProbe -ProbeRoot $ProbeRoot -VolumeInfo $VolumeInfo -ExpectedProbeRootIdentity $ExpectedProbeRootIdentity
                [IO.Directory]::CreateDirectory($foreignResidueSlot) | Out-Null
                [IO.File]::WriteAllBytes($foreignResidueFile,$foreignResidueBytes)
                return $capabilityHash
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $shadowCapabilityProbe
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^capability-probe-root-residue$' 'foreign matching residue created after the initial check fails closed at the post-probe check'
                $matchingResidue = @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot,'.target-capability-*'))
                Assert-TestCondition ($matchingResidue.Count -eq 1 -and [IO.Path]::GetFullPath($matchingResidue[0]) -ceq [IO.Path]::GetFullPath($foreignResidueSlot)) 'the real probe cleans only its owned slot and leaves the foreign matching residue'
                Assert-TestCondition ((Test-Path -LiteralPath $foreignResidueFile -PathType Leaf) -and
                    [Convert]::ToHexString([IO.File]::ReadAllBytes($foreignResidueFile)) -ceq [Convert]::ToHexString($foreignResidueBytes)) 'the post-probe residue failure preserves the foreign file bytes'
            }
            finally {
                try { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $originalCapabilityProbe }
                finally {
                    if (Test-Path -LiteralPath $foreignResidueSlot) { [IO.Directory]::Delete($foreignResidueSlot,$true) }
                }
            }

            $probeSwapKeeperRoot = Join-Path $capabilityFixture.Root 'capability-probe-swap-keepers'
            [IO.Directory]::CreateDirectory($probeSwapKeeperRoot) | Out-Null
            $probeSwapState = [pscustomobject]@{ ReplacementIdentity=$null }
            $probeSwapShadow = {
                param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                $capabilityHash = & $originalCapabilityProbe -ProbeRoot $ProbeRoot -VolumeInfo $VolumeInfo -ExpectedProbeRootIdentity $ExpectedProbeRootIdentity
                $probeSwapState.ReplacementIdentity = Replace-TestDirectoryWithDifferentIdentity -Path $ProbeRoot -ExpectedIdentity $ExpectedProbeRootIdentity -KeeperRoot $probeSwapKeeperRoot
                return $capabilityHash
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $probeSwapShadow
                Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^capability-probe-root-stale$' 'probe-root identity replacement after the real probe fails closed with the stable stale token'
                Assert-TestCondition (-not [string]::IsNullOrWhiteSpace([string]$probeSwapState.ReplacementIdentity) -and
                    [string]$probeSwapState.ReplacementIdentity -cne [string]$capabilityProbeMetadata.DeepestExistingParentIdentity -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0) 'post-probe root replacement is detected after exact owned-slot cleanup without leaving residue'
            }
            finally {
                try { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $originalCapabilityProbe }
                finally { if (Test-Path -LiteralPath $probeSwapKeeperRoot) { [IO.Directory]::Delete($probeSwapKeeperRoot,$true) } }
            }

            $mixedVolumeRoot = $null
            $mixedVolumeParent = [IO.Path]::GetFullPath((Split-Path -Parent $RepoRoot)).TrimEnd([char]92,[char]47)
            $mixedVolumeLeaf = '.rcr-mv-' + [guid]::NewGuid().ToString('N')
            $mixedVolumeCandidate = [IO.Path]::GetFullPath((Join-Path $mixedVolumeParent $mixedVolumeLeaf))
            $tempVolumeInfo = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($tempParent)
            $repoParentVolumeInfo = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($mixedVolumeParent)
            $mixedVolumeAvailable = [string]$tempVolumeInfo.DriveType -ceq 'Fixed' -and [string]$tempVolumeInfo.FileSystemType -ceq 'NTFS' -and
                [string]$repoParentVolumeInfo.DriveType -ceq 'Fixed' -and [string]$repoParentVolumeInfo.FileSystemType -ceq 'NTFS' -and
                [string]$tempVolumeInfo.VolumeSerial -cne [string]$repoParentVolumeInfo.VolumeSerial -and
                -not (Test-TargetPathOverlap -Left $mixedVolumeCandidate -Right $RepoRoot)
            if ($mixedVolumeAvailable) {
                try {
                    try { [IO.Directory]::CreateDirectory($mixedVolumeCandidate) | Out-Null; $mixedVolumeRoot=$mixedVolumeCandidate }
                    catch { $mixedVolumeAvailable=$false; Write-Host "  SKIP  capability-mixed-volume-unavailable: $($_.Exception.Message)" }
                    if ($mixedVolumeAvailable) {
                        $mixedTarget = Join-Path $mixedVolumeRoot 'target'
                        $mixedProbeRoot = Join-Path $mixedVolumeRoot 'probe'
                        foreach ($path in @($mixedTarget,$mixedProbeRoot)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
                        $mixedTargetVolume = [AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($mixedTarget)
                        $mixedProbeMetadata = Resolve-TargetContext -Path $mixedProbeRoot -Mode MetadataOnly
                        $mixedExpectedHash = Invoke-TargetFilesystemCapabilityProbe -ProbeRoot $mixedProbeRoot -VolumeInfo $mixedTargetVolume -ExpectedProbeRootIdentity ([string]$mixedProbeMetadata.DeepestExistingParentIdentity)
                        $mixedAuthorityBefore = Get-TestRegistryTreeHash -Fixture $capabilityFixture
                        $mixedExternalBefore = [string](Get-SafeTreeSnapshot -Root $mixedVolumeRoot).TreeHash
                        $mixedProbeState = [pscustomobject]@{ Calls=[Collections.Generic.List[object]]::new() }
                        $mixedProbeShadow = {
                            param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                            $mixedProbeState.Calls.Add([pscustomobject]@{ProbeRoot=[IO.Path]::GetFullPath($ProbeRoot);VolumeSerial=[string]$VolumeInfo.VolumeSerial;ProbeRootIdentity=$ExpectedProbeRootIdentity})
                            & $originalCapabilityProbe -ProbeRoot $ProbeRoot -VolumeInfo $VolumeInfo -ExpectedProbeRootIdentity $ExpectedProbeRootIdentity
                        }.GetNewClosure()
                        try {
                            Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $mixedProbeShadow
                            $mixedEvidence = Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                                [ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot },
                                [ordered]@{ Path=[string]$capabilityFixture.Context.BackupRoot; ProbeRoot=$capabilityProbeRoot },
                                [ordered]@{ Path=$mixedTarget; ProbeRoot=$mixedProbeRoot; ExpectedFilesystemCapabilityHash=[string]$mixedExpectedHash }
                            )
                            $mixedCallsAfterSuccess = $mixedProbeState.Calls.Count
                            Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=$mixedTarget; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^capability-probe-target-volume-mismatch$' 'a target cannot use a probe root from a different physical volume'
                            Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$mixedProbeRoot }) | Out-Null } '^capability-probe-target-volume-mismatch$' 'the reverse cross-volume target-to-probe mapping also fails closed'
                            Assert-TestCondition ($mixedProbeState.Calls.Count -eq $mixedCallsAfterSuccess) 'both wrong-volume mappings fail before invoking any filesystem probe'
                        }
                        finally { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $originalCapabilityProbe }

                        $mixedRows = @([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($mixedEvidence))
                        $mixedRow = @($mixedRows | Where-Object { [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetRequestedPathExact($_) -ceq [IO.Path]::GetFullPath($mixedTarget) })[0]
                        $mixedControlRow = @($mixedRows | Where-Object { [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($_) -ceq
                            ([IO.Path]::GetFullPath([string]$capabilityFixture.Context.ControlBase).TrimEnd([char]92,[char]47).ToLowerInvariant().Replace([char]92,[char]47)) })[0]
                        $mixedBackupRow = @($mixedRows | Where-Object { [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($_) -ceq
                            ([IO.Path]::GetFullPath([string]$capabilityFixture.Context.BackupRoot).TrimEnd([char]92,[char]47).ToLowerInvariant().Replace([char]92,[char]47)) })[0]
                        Assert-TestCondition ([string]$tempVolumeInfo.VolumeSerial -cne [string]$repoParentVolumeInfo.VolumeSerial -and
                            [string]$mixedTargetVolume.VolumeSerial -ceq [string]$repoParentVolumeInfo.VolumeSerial) 'mixed-volume fixture uses two distinct physical Fixed/NTFS volume serials'
                        Assert-TestCondition ($mixedRows.Count -eq 3 -and $mixedProbeState.Calls.Count -eq 3) 'mixed-volume preflight probes every target independently'
                        Assert-TestCondition (@($mixedProbeState.Calls | Where-Object { [string]$_.ProbeRoot -ceq [IO.Path]::GetFullPath($capabilityProbeRoot) -and [string]$_.VolumeSerial -ceq [string]$tempVolumeInfo.VolumeSerial }).Count -eq 2 -and
                            @($mixedProbeState.Calls | Where-Object { [string]$_.ProbeRoot -ceq [IO.Path]::GetFullPath($mixedProbeRoot) -and [string]$_.VolumeSerial -ceq [string]$repoParentVolumeInfo.VolumeSerial }).Count -eq 1) 'mixed-volume calls preserve the exact per-target probe-root and volume mapping'
                        Assert-TestCondition ([string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($mixedControlRow) -ceq [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($mixedBackupRow) -and
                            [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($mixedRow) -cne [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($mixedControlRow)) 'same-volume rows share capability semantics while a different physical volume has a distinct hash'
                        Assert-TestCondition ([bool][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVerifiedAgainstExpectedExact($mixedRow) -and
                            [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($mixedRow) -ceq [IO.Path]::GetFullPath($mixedProbeRoot) -and
                            [string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($mixedRow) -ceq [string]$mixedProbeMetadata.DeepestExistingParentIdentity -and
                            @($mixedProbeState.Calls | Where-Object { [string]$_.ProbeRoot -ceq [IO.Path]::GetFullPath($mixedProbeRoot) -and [string]$_.ProbeRootIdentity -ceq [string]$mixedProbeMetadata.DeepestExistingParentIdentity }).Count -eq 1) 'mixed-volume sealed evidence binds and verifies the external target against its own-volume probe root identity'
                        Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $mixedAuthorityBefore -and
                            [string](Get-SafeTreeSnapshot -Root $mixedVolumeRoot).TreeHash -ceq $mixedExternalBefore) 'mixed-volume preflight is zero-write in both authority and external fixture trees after owned-slot cleanup'
                        Assert-TestCondition (@([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                            @([IO.Directory]::EnumerateFileSystemEntries($mixedProbeRoot)).Count -eq 0) 'mixed-volume success leaves every physical-volume probe root empty'
                    }
                }
                finally {
                    if ($null -ne $mixedVolumeRoot -and (Test-Path -LiteralPath $mixedVolumeRoot)) {
                        $resolvedMixedRoot = [IO.Path]::GetFullPath($mixedVolumeRoot)
                        if ([IO.Path]::GetDirectoryName($resolvedMixedRoot).TrimEnd([char]92,[char]47) -cne $mixedVolumeParent -or
                            [IO.Path]::GetFileName($resolvedMixedRoot) -cnotmatch '^\.rcr-mv-[0-9a-f]{32}$' -or
                            [bool][AiAgentDotfiles.NoFollowFile]::Inspect($resolvedMixedRoot).IsReparsePoint) { throw "unsafe mixed-volume test cleanup target: $resolvedMixedRoot" }
                        Remove-Item -LiteralPath $resolvedMixedRoot -Recurse -Force
                    }
                }
            }
            else { Write-Host '  SKIP  capability-mixed-volume-unavailable: two distinct writable Fixed/NTFS volumes were not discovered' }
        }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $capabilityGlobal }

        $capabilityPlainGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $capabilityFixture.Context
        try {
            Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityPlainGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^canonical-witness-required$' 'a capability preflight cannot bind a canonical witness onto a global lock acquired without one'
        }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $capabilityPlainGlobal }
        Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $null -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^home-authority-registry-lock-required$' 'a capability preflight without a genuine global lock fails closed'
    }
    finally {
        if ($null -ne $capabilityWitness) { Close-CanonicalHeldNamespaceWitness -Witness $capabilityWitness }
        Exit-CanonicalRepoLock -LockHandle $capabilityLock
    }

    $live = New-TestRegistryFixture -Parent $workRoot -Name 'live-transaction'
    $liveId = '33333333-3333-4333-8333-333333333333'
    [IO.Directory]::CreateDirectory((Join-Path $live.Context.LiveTransactionsRoot $liveId)) | Out-Null
    $liveView = Assert-TestRegistryReadIsZeroWrite -Fixture $live -Message 'live-transaction registry read is zero-write on the fake private root' -Assertions {
        param($view)
        Assert-TestCondition ([string]$view.MutationGate -ceq 'RECOVERY_REQUIRED') 'a canonical live transaction marker forces RECOVERY_REQUIRED'
        Assert-TestCondition ([string]$view.LiveTransactionCoverage -ceq 'UNRESOLVED_UNTIL_TASK_4') 'live transaction coverage remains explicitly unresolved'
        Assert-TestCondition (@($view.LiveTransactionMarkers).Count -eq 1 -and [string]$view.LiveTransactionMarkers[0].TransactionId -ceq $liveId -and [string]$view.LiveTransactionMarkers[0].ContractStatus -ceq 'UNRESOLVED_UNTIL_TASK_4') 'canonical UUID directory is enumerated as an unresolved marker'
    }
    Assert-TestCondition (@($liveView.LiveTransactionMarkers[0].ImmediateChildren).Count -eq 0) 'empty live transaction marker captures exact immediate inventory'

    $badLive = New-TestRegistryFixture -Parent $workRoot -Name 'bad-live-name'
    [IO.Directory]::CreateDirectory((Join-Path $badLive.Context.LiveTransactionsRoot 'NOT-A-UUID')) | Out-Null
    Invoke-TestRegistryFailure -Fixture $badLive -Pattern 'manual-recovery-required:.*live-transactions contains an unsupported child' -Message 'noncanonical live transaction directory name fails closed'

    $extra = New-TestRegistryFixture -Parent $workRoot -Name 'authority-extra'
    $extraClaims = New-TestRootClaims -Context $extra.Context
    $null = Add-TestAuthorityArtifacts -Context $extra.Context -Claims $extraClaims
    Write-TestCreateNewFile -Path (Join-Path $extra.Context.AuthorityRoot 'unexpected.bin') -Bytes ([Text.Encoding]::ASCII.GetBytes('x'))
    Invoke-TestRegistryFailure -Fixture $extra -Pattern 'manual-recovery-required:.*registry inventory drift' -Message 'extra authority child fails closed'

    $wrongType = New-TestRegistryFixture -Parent $workRoot -Name 'authority-wrong-type'
    [IO.Directory]::CreateDirectory([string]$wrongType.Context.AuthorityRoot) | Out-Null
    [IO.Directory]::CreateDirectory([string]$wrongType.Context.RootClaimsPath) | Out-Null
    Invoke-TestRegistryFailure -Fixture $wrongType -Pattern 'manual-recovery-required:.*(?:regular file|wrong.*type|Unable to open child)' -Message 'directory at root-claims.json fails closed as the wrong type'

    $hardlink = New-TestRegistryFixture -Parent $workRoot -Name 'authority-hardlink'
    $hardlinkClaims = New-TestRootClaims -Context $hardlink.Context
    $null = Add-TestAuthorityArtifacts -Context $hardlink.Context -Claims $hardlinkClaims
    $null = New-PathSafetyHardLink -Path (Join-Path $hardlink.Root 'root-claims-alias.json') -Target ([string]$hardlink.Context.RootClaimsPath)
    Invoke-TestRegistryFailure -Fixture $hardlink -Pattern 'manual-recovery-required:.*multiple hard links' -Message 'hard-linked authority claim fails closed'

    $ads = New-TestRegistryFixture -Parent $workRoot -Name 'authority-ads'
    $adsClaims = New-TestRootClaims -Context $ads.Context
    $null = Add-TestAuthorityArtifacts -Context $ads.Context -Claims $adsClaims
    Add-PathSafetyNamedStream -Path ([string]$ads.Context.RootClaimsPath) -Name 'registry-test'
    Invoke-TestRegistryFailure -Fixture $ads -Pattern 'manual-recovery-required:.*alternate data stream' -Message 'authority claim with an ADS fails closed'

    Write-Host 'Root claims registry tests passed.'
}
finally {
    $resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
    $resolvedParent = [IO.Path]::GetDirectoryName($resolvedWorkRoot).TrimEnd([char]92,[char]47)
    $leaf = [IO.Path]::GetFileName($resolvedWorkRoot)
    if ($resolvedParent -cne $tempParent -or $leaf -cnotmatch '^\.rcr-[0-9a-f]{32}$') {
        throw "unsafe registry test cleanup target: $resolvedWorkRoot"
    }
    if (Test-Path -LiteralPath $resolvedWorkRoot) { Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force }
}
