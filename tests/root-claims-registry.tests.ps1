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
using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Threading;
using System.Threading.Tasks;

namespace AiAgentDotfiles {
    public sealed class ReceiptReleaseProbe : IDisposable {
        private readonly ManualResetEventSlim entered = new ManualResetEventSlim(false);
        private readonly ManualResetEventSlim release;
        private int failRemaining;
        private int disposeCount;
        private int successfulDisposeCount;
        private object capturedValue;

        public ReceiptReleaseProbe(bool block, bool failOnce) {
            release = new ManualResetEventSlim(!block);
            failRemaining = failOnce ? 1 : 0;
        }
        public int DisposeCount { get { return Volatile.Read(ref disposeCount); } }
        public int SuccessfulDisposeCount { get { return Volatile.Read(ref successfulDisposeCount); } }
        public bool IsDisposed { get { return SuccessfulDisposeCount != 0; } }
        public object CapturedValue { get { return Volatile.Read(ref capturedValue); } }
        public bool WaitUntilEntered(int milliseconds) { return entered.Wait(milliseconds); }
        public void AllowRelease() { release.Set(); }
        public void SignalOnly() { entered.Set(); }
        public void CaptureAndWait(object value) {
            if (value == null) throw new ArgumentNullException("value");
            Interlocked.CompareExchange(ref capturedValue,value,null);
            entered.Set();
            release.Wait();
        }
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
        public static string InvokeExpectPipelineStopped(object scriptBlockValue, object[] arguments) {
            ScriptBlock scriptBlock = scriptBlockValue as ScriptBlock;
            if (scriptBlock == null) throw new InvalidOperationException("test script block unavailable");
            try {
                scriptBlock.Invoke(arguments);
                return "test invocation unexpectedly completed";
            }
            catch (PipelineStoppedException) { return "pipeline-stopped"; }
        }
        public static bool HasExactRouteResourceReservation(object resource) {
            if (resource == null) throw new ArgumentNullException("resource");
            Type captureType = FindRequiredType("AiAgentDotfiles.SealedRegistryCurrentRouteCapture");
            FieldInfo reservationsField = captureType.GetField("ExactResourceReservations",
                BindingFlags.NonPublic | BindingFlags.Static);
            if (reservationsField == null)
                throw new InvalidOperationException("test route reservation registry unavailable");
            object reservations = reservationsField.GetValue(null);
            MethodInfo tryGetValue = reservations.GetType().GetMethod("TryGetValue");
            if (tryGetValue == null)
                throw new InvalidOperationException("test route reservation lookup unavailable");
            object[] lookup = new object[] { resource, null };
            return Convert.ToBoolean(tryGetValue.Invoke(reservations,lookup));
        }
        public static Task StartRelease(string typeName, string methodName, object wrapper) {
            return Task.Run(() => {
                MethodInfo method = FindRequiredType(typeName).GetMethod(methodName, BindingFlags.Public | BindingFlags.Static);
                if (method == null) throw new InvalidOperationException("test release method unavailable: " + methodName);
                try { method.Invoke(null, new object[] { wrapper }); }
                catch (TargetInvocationException error) { throw error.InnerException ?? error; }
            });
        }
        public static Task StartPowerShellStop(PowerShell powerShell, ReceiptReleaseProbe callProbe) {
            if (powerShell == null) throw new ArgumentNullException("powerShell");
            if (callProbe == null) throw new ArgumentNullException("callProbe");
            return Task.Run(() => {
                callProbe.SignalOnly();
                IAsyncResult stop = powerShell.BeginStop(null,null);
                powerShell.EndStop(stop);
            });
        }
        public static Task StartReleaseInOwnerRunspace(string typeName, string methodName,
            object wrapper, object ownerRunspaceValue) {
            Runspace ownerRunspace = ownerRunspaceValue as Runspace;
            if (ownerRunspace == null) throw new InvalidOperationException("test owner runspace unavailable");
            return Task.Run(() => {
                Runspace previous = Runspace.DefaultRunspace;
                try {
                    Runspace.DefaultRunspace = ownerRunspace;
                    MethodInfo method = FindRequiredType(typeName).GetMethod(methodName, BindingFlags.Public | BindingFlags.Static);
                    if (method == null) throw new InvalidOperationException("test release method unavailable: " + methodName);
                    try { method.Invoke(null, new object[] { wrapper }); }
                    catch (TargetInvocationException error) { throw error.InnerException ?? error; }
                }
                finally { Runspace.DefaultRunspace = previous; }
            });
        }
        public static Task<string> StartExpectedFailureAfterEnterInOwnerRunspace(string typeName,
            string methodName, object wrapper, object ownerRunspaceValue, ReceiptReleaseProbe probe) {
            Runspace ownerRunspace = ownerRunspaceValue as Runspace;
            if (ownerRunspace == null) throw new InvalidOperationException("test owner runspace unavailable");
            if (probe == null) throw new ArgumentNullException("probe");
            return Task.Run<string>(() => {
                if (!probe.WaitUntilEntered(30000)) {
                    probe.AllowRelease();
                    throw new InvalidOperationException("test blocked operation was not entered");
                }
                Runspace previous = Runspace.DefaultRunspace;
                try {
                    Runspace.DefaultRunspace = ownerRunspace;
                    MethodInfo method = FindRequiredType(typeName).GetMethod(methodName,
                        BindingFlags.Public | BindingFlags.Static);
                    if (method == null) throw new InvalidOperationException("test release method unavailable: " + methodName);
                    try {
                        method.Invoke(null, new object[] { wrapper });
                        return "test operation unexpectedly succeeded";
                    }
                    catch (TargetInvocationException error) {
                        return (error.InnerException ?? error).Message;
                    }
                }
                finally {
                    Runspace.DefaultRunspace = previous;
                    probe.AllowRelease();
                }
            });
        }
        public static Task<string> StartObservedExpectedFailureAfterEnterInOwnerRunspace(string typeName,
            string methodName, string stateTypeName, object wrapper, object ownerRunspaceValue,
            ReceiptReleaseProbe probe) {
            Runspace ownerRunspace = ownerRunspaceValue as Runspace;
            if (ownerRunspace == null) throw new InvalidOperationException("test owner runspace unavailable");
            if (probe == null) throw new ArgumentNullException("probe");
            return Task.Run<string>(() => {
                if (!probe.WaitUntilEntered(30000)) {
                    probe.AllowRelease();
                    throw new InvalidOperationException("test blocked operation was not entered");
                }
                Runspace previous = Runspace.DefaultRunspace;
                try {
                    Runspace.DefaultRunspace = ownerRunspace;
                    Type stateType = FindRequiredType(stateTypeName);
                    MethodInfo stateMethod = stateType.GetMethod("GetCloseStateExact",
                        BindingFlags.Public | BindingFlags.Static);
                    MethodInfo openMethod = stateType.GetMethod("GetIsOpenExact",
                        BindingFlags.Public | BindingFlags.Static);
                    MethodInfo method = FindRequiredType(typeName).GetMethod(methodName,
                        BindingFlags.Public | BindingFlags.Static);
                    if (stateMethod == null || openMethod == null || method == null)
                        throw new InvalidOperationException("test observed release method unavailable");
                    string state = Convert.ToString(stateMethod.Invoke(null, new object[] { wrapper }));
                    bool isOpen = Convert.ToBoolean(openMethod.Invoke(null, new object[] { wrapper }));
                    string outcome;
                    try {
                        method.Invoke(null, new object[] { wrapper });
                        outcome = "test operation unexpectedly succeeded";
                    }
                    catch (TargetInvocationException error) {
                        outcome = (error.InnerException ?? error).Message;
                    }
                    return state + "|" + isOpen.ToString() + "|" + outcome;
                }
                finally {
                    Runspace.DefaultRunspace = previous;
                    probe.AllowRelease();
                }
            });
        }
        public static object IssueSyntheticRouteCapture(object liveSetLease,
            object liveTargetLeases, object claimedResources, object liveProjection,
            object routeLeaseRows, object reservationLeases,
            object fixedLeases, object originalCurrentRouteRootSet, object canonicalWitness,
            object currentRouteRootSetSnapshot, string entryCurrentRouteRootSetHash,
            string currentRouteRootSetSnapshotHash, string heldTargetSetHash) {
            Type issuerType = FindRequiredType("AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer");
            Type captureType = FindRequiredType("AiAgentDotfiles.SealedRegistryCurrentRouteCapture");
            FieldInfo tokenField = issuerType.GetField("IssuanceToken",
                BindingFlags.NonPublic | BindingFlags.Static);
            MethodInfo beginMethod = captureType.GetMethod("BeginOpenForIssuerExact",
                BindingFlags.NonPublic | BindingFlags.Static);
            MethodInfo claimMethod = captureType.GetMethod("ClaimResourcesForIssuerExact",
                BindingFlags.NonPublic | BindingFlags.Static);
            MethodInfo issueMethod = captureType.GetMethod("IssueForIssuerExact",
                BindingFlags.NonPublic | BindingFlags.Static);
            if (tokenField == null || beginMethod == null || claimMethod == null || issueMethod == null)
                throw new InvalidOperationException("test route issuer unavailable");
            try {
                object token = tokenField.GetValue(null);
                object operation = beginMethod.Invoke(null,new object[] { token });
                claimMethod.Invoke(null,new object[] { token,operation,claimedResources });
                return issueMethod.Invoke(null,new object[] { token,operation,liveSetLease,
                    liveTargetLeases,liveProjection,routeLeaseRows,reservationLeases,fixedLeases,
                    originalCurrentRouteRootSet,canonicalWitness,currentRouteRootSetSnapshot,
                    entryCurrentRouteRootSetHash,currentRouteRootSetSnapshotHash,heldTargetSetHash });
            }
            catch (TargetInvocationException error) { throw error.InnerException ?? error; }
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

function Invoke-TestPowerShellStopAtProbe {
    param(
        [Parameter(Mandatory)][PowerShell]$PowerShell,
        [Parameter(Mandatory)][AiAgentDotfiles.ReceiptReleaseProbe]$Probe,
        [ValidateRange(1000,180000)][int]$BarrierTimeoutMilliseconds=30000
    )

    $invocation = $PowerShell.BeginInvoke()
    $stopTask = $null
    $stopCallProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)
    $endError = $null
    $stopStateBeforeRelease = $null
    try {
        $barrierDeadline=[DateTime]::UtcNow.AddMilliseconds($BarrierTimeoutMilliseconds)
        while(-not $Probe.WaitUntilEntered(1000)){
            if($invocation.IsCompleted){
                try { $null=$PowerShell.EndInvoke($invocation) }
                catch {
                    throw [InvalidOperationException]::new(
                        'test PowerShell.Stop invocation ended before the barrier was entered',
                        $_.Exception)
                }
                throw 'test PowerShell.Stop invocation completed before the barrier was entered'
            }
            if([DateTime]::UtcNow -ge $barrierDeadline){
                throw 'test PowerShell.Stop barrier was not entered'
            }
        }
        $stopTask=[AiAgentDotfiles.ReceiptReleaseProbe]::StartPowerShellStop(
            $PowerShell,$stopCallProbe)
        if(-not $stopCallProbe.WaitUntilEntered(5000)){
            throw 'test PowerShell.Stop call task did not start'
        }
        $stopDeadline=[DateTime]::UtcNow.AddSeconds(5)
        do {
            $stopStateBeforeRelease=[string]$PowerShell.InvocationStateInfo.State
            if($stopStateBeforeRelease -in @('Stopping','Stopped')){break}
            $null=[Threading.Thread]::Yield()
        } while([DateTime]::UtcNow -lt $stopDeadline)
        if($stopStateBeforeRelease -notin @('Stopping','Stopped')){
            throw 'test PowerShell.Stop invocation did not enter Stopping before barrier release'
        }
        $Probe.AllowRelease()
        if(-not $stopTask.Wait(30000)){throw 'test PowerShell.Stop call did not complete'}
        $stopTask.GetAwaiter().GetResult()
        $stopTask = $null
        if(-not $invocation.AsyncWaitHandle.WaitOne(30000)){
            throw 'test PowerShell.Stop invocation did not complete'
        }
        try { $null = $PowerShell.EndInvoke($invocation) }
        catch { $endError = $_.Exception }
        return [pscustomobject]@{
            State = [string]$PowerShell.InvocationStateInfo.State
            EndError = $endError
            StateBeforeRelease = $stopStateBeforeRelease
        }
    }
    finally {
        $Probe.AllowRelease()
        if ($null -ne $stopTask) {
            try { $null=$stopTask.Wait(30000) }
            catch { }
        }
        $activeStopTask=$null -ne $stopTask -and -not $stopTask.IsCompleted
        if (-not $invocation.IsCompleted -and -not $activeStopTask) {
            try {
                $fallbackStopProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)
                $fallbackStopTask=[AiAgentDotfiles.ReceiptReleaseProbe]::StartPowerShellStop(
                    $PowerShell,$fallbackStopProbe)
                if($fallbackStopProbe.WaitUntilEntered(5000)){
                    $null=$fallbackStopTask.Wait(30000)
                }
            }
            catch { }
        }
    }
}

function Open-TestSealedRegistryCurrentRouteCapture {
    param(
        [Parameter(Mandatory)]$AuthorityContext,
        [Parameter(Mandatory)]$GlobalLockHandle,
        [Parameter(Mandatory)]$CanonicalWitness,
        [Parameter(Mandatory)]$CurrentRouteRootSet,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reservations
    )

    $receiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    $capture=$null
    $registered=$false
    try {
        Open-SealedRegistryCurrentRouteCapture -AuthorityContext $AuthorityContext `
            -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness `
            -CurrentRouteRootSet $CurrentRouteRootSet -Reservations @($Reservations) `
            -OwnershipReceiver $receiver
        $capture=$receiver.GetDeliveredExact()
        $registered=$true
        return $capture
    }
    finally {
        if(-not $registered -and [string]$receiver.GetStateExact() -ceq 'DELIVERED'){
            $unregistered=$receiver.GetDeliveredExact()
            $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($unregistered)
        }
    }
}

function Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation {
    param(
        [Parameter(Mandatory)]$CurrentRouteCapture,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][object[]]$CapabilityProbeBindings
    )

    $receiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    $observation=$null
    $registered=$false
    try {
        Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
            -CurrentRouteCapture $CurrentRouteCapture `
            -CapabilityProbeBindings @($CapabilityProbeBindings) `
            -OwnershipReceiver $receiver
        $observation=$receiver.GetDeliveredExact()
        $registered=$true
        return $observation
    }
    finally {
        if(-not $registered -and [string]$receiver.GetStateExact() -ceq 'DELIVERED'){
            $unregistered=$receiver.GetDeliveredExact()
            if([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($unregistered)){
                $null=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]::CloseObservationExact($unregistered)
            }
        }
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
    $capture = Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness -CurrentRouteRootSet $RootSet -Reservations @()
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
$testPrimaryError = $null

try {
    Write-Host 'Root claims registry tests'

    $fixedDomainError=[InvalidOperationException]::new('fixed domain primary; cleanup: fixed domain cleanup')
    $fixedDomainError.Data['Primary']='fixed-domain-primary'
    $fixedDomainError.Data['Cleanup']='fixed-domain-cleanup'
    $fixedRuntimeWrapper=[System.Management.Automation.RuntimeException]::new('runtime-wrapper',$fixedDomainError)
    $fixedMethodWrapper=[System.Management.Automation.MethodInvocationException]::new('method-wrapper',$fixedRuntimeWrapper)
    try {
        Throw-SealedFixedInfrastructureCapabilityIssuerException -Exception $fixedMethodWrapper
        throw 'FAIL: exact issuer exception unwrapping preserves the first domain exception (did not throw)'
    }
    catch {
        if($_.Exception.Message -like 'FAIL:*'){throw}
        Assert-TestCondition ($_.Exception -is [InvalidOperationException] -and
            $_.Exception.Message -ceq 'fixed domain primary; cleanup: fixed domain cleanup' -and
            [string]$_.Exception.Data['Primary'] -ceq 'fixed-domain-primary' -and
            [string]$_.Exception.Data['Cleanup'] -ceq 'fixed-domain-cleanup') 'exact issuer exception unwrapping preserves domain type, combined message, and primary/cleanup Data'
    }

    $fixedAggregateBoundary=[AggregateException]::new('fixed aggregate boundary',[Exception[]]@($fixedDomainError))
    $fixedAggregateWrapper=[System.Management.Automation.RuntimeException]::new('runtime-wrapper',$fixedAggregateBoundary)
    try {
        Throw-SealedFixedInfrastructureCapabilityIssuerException -Exception $fixedAggregateWrapper
        throw 'FAIL: exact issuer exception unwrapping stops at AggregateException (did not throw)'
    }
    catch {
        if($_.Exception.Message -like 'FAIL:*'){throw}
        Assert-TestCondition ($_.Exception -is [AggregateException] -and $_.Exception.Message -like 'fixed aggregate boundary*') 'exact issuer exception unwrapping does not descend into AggregateException'
    }

    $ownershipReceiverMethods=@([AiAgentDotfiles.SealedOwnershipTransferReceiver].GetMethods(
        ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Instance -bor
        [Reflection.BindingFlags]::DeclaredOnly)).Name | Sort-Object -CaseSensitive)
    $expectedOwnershipReceiverMethods=@(
        'AssertEmptyExact','DeliverExact','GetDeliveredExact','GetStateExact','HoldsExact'
    ) | Sort-Object -CaseSensitive
    Assert-TestCondition (($ownershipReceiverMethods -join "`0") -ceq
        ($expectedOwnershipReceiverMethods -join "`0") -and
        @([AiAgentDotfiles.SealedOwnershipTransferReceiver].GetProperties(
            ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Instance -bor
            [Reflection.BindingFlags]::DeclaredOnly))).Count -eq 0 -and
        @([AiAgentDotfiles.SealedOwnershipTransferReceiver].GetFields(
            ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Instance -bor
            [Reflection.BindingFlags]::DeclaredOnly))).Count -eq 0) 'ownership receiver exposes only empty-check, one-shot publish, exact-reference hold, read, and state methods without Take or acknowledge gaps'
    $ownershipReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    $ownershipReceiverValue=[object]::new()
    $ownershipReceiver.AssertEmptyExact()
    $ownershipReceiver.DeliverExact($ownershipReceiverValue)
    Assert-TestCondition ([string]$ownershipReceiver.GetStateExact() -ceq 'DELIVERED' -and
        $ownershipReceiver.HoldsExact($ownershipReceiverValue) -and
        -not $ownershipReceiver.HoldsExact([object]::new()) -and
        -not $ownershipReceiver.HoldsExact($null) -and
        [object]::ReferenceEquals($ownershipReceiver.GetDeliveredExact(),$ownershipReceiverValue)) 'ownership receiver retains and authoritatively identifies the exact published reference without success-stream output'
    Assert-ThrowsPattern {
        $ownershipReceiver.DeliverExact([object]::new())
    } 'ownership-transfer-receiver-stale' 'ownership receiver rejects a second publication without replacing its retained owner reference'

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

    $safeTreeScriptPath=Join-Path $RepoRoot 'scripts/safe-tree-walker.ps1'
    $safeTreeTokens=$null
    $safeTreeParseErrors=$null
    $safeTreeAst=[Management.Automation.Language.Parser]::ParseFile(
        $safeTreeScriptPath,[ref]$safeTreeTokens,[ref]$safeTreeParseErrors)
    if($safeTreeParseErrors.Count -ne 0){throw 'safe containment Stop fixture could not parse its reviewed provider'}
    $safeContainmentFunction=$safeTreeAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Open-SafeDirectoryContainmentChain'
    },$true)
    $safeContainmentPendingAdd=@($safeContainmentFunction.Body.FindAll({
        param($node)
        $node.Extent.Text -ceq '$handles.Add($pendingHandle)'
    },$true) | Sort-Object {$_.Extent.StartOffset})[0]
    $safeContainmentStopProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $safeContainmentStopPowerShell=[PowerShell]::Create()
    try {
        $null=$safeContainmentStopPowerShell.AddScript({
            param($SafeTreeScriptPath,$TargetPath,[long]$BreakLine,$Probe)
            . $SafeTreeScriptPath
            $null=Set-PSBreakpoint -Script $SafeTreeScriptPath -Line ([int]$BreakLine) -Action {
                $Probe.CaptureAndWait($pendingHandle)
            }
            Open-SafeDirectoryContainmentChain -Path $TargetPath
        }).AddArgument($safeTreeScriptPath).AddArgument($workRoot).AddArgument(
            [long]$safeContainmentPendingAdd.Extent.StartLineNumber).AddArgument($safeContainmentStopProbe)
        $safeContainmentStopResult=Invoke-TestPowerShellStopAtProbe -PowerShell $safeContainmentStopPowerShell -Probe $safeContainmentStopProbe
    }
    finally {$safeContainmentStopPowerShell.Dispose()}
    $safeContainmentStoppedHandle=$safeContainmentStopProbe.CapturedValue
    Assert-TestCondition ($safeContainmentStopResult.State -ceq 'Stopped' -and
        $null -ne $safeContainmentStopResult.EndError -and
        $safeContainmentStoppedHandle -is [AiAgentDotfiles.SafeDirectoryHandle] -and
        -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($safeContainmentStoppedHandle)) 'real PowerShell.Stop inside containment acquisition closes the pending directory handle through finally'

    $targetRawStopProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $targetRawStopPowerShell = [PowerShell]::Create()
    try {
        $null = $targetRawStopPowerShell.AddScript({
            param($TargetScriptPath,$TargetPath,$Probe)
            . $TargetScriptPath
            $originalEvidence = (Get-Command Get-SealedHeldTargetDirectoryEvidence -CommandType Function -ErrorAction Stop).ScriptBlock
            $blockingEvidence = {
                param($Handle,[string]$Path,$ParentHandle,[string]$LeafName,[string]$VolumeId)
                $Probe.CaptureAndWait($Handle)
                & $originalEvidence -Handle $Handle -Path $Path -ParentHandle $ParentHandle -LeafName $LeafName -VolumeId $VolumeId
            }.GetNewClosure()
            Set-Item -LiteralPath Function:\Get-SealedHeldTargetDirectoryEvidence -Value $blockingEvidence
            Open-SealedHeldTargetContextLease -Path $TargetPath
        }).AddArgument((Join-Path $RepoRoot 'scripts/target-context-common.ps1')).AddArgument($workRoot).AddArgument($targetRawStopProbe)
        $targetRawStopResult = Invoke-TestPowerShellStopAtProbe -PowerShell $targetRawStopPowerShell -Probe $targetRawStopProbe
    }
    finally { $targetRawStopPowerShell.Dispose() }
    $targetRawStoppedHandle = $targetRawStopProbe.CapturedValue
    Assert-TestCondition ($targetRawStopResult.State -ceq 'Stopped' -and
        $null -ne $targetRawStopResult.EndError -and
        $targetRawStoppedHandle -is [AiAgentDotfiles.SafeDirectoryHandle] -and
        -not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($targetRawStoppedHandle)) 'real PowerShell.Stop before target receipt binding runs finally and closes the acquired directory handle'

    $targetReceiptStopProbe = [AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $targetReceiptStopPowerShell = [PowerShell]::Create()
    try {
        $null = $targetReceiptStopPowerShell.AddScript({
            param($TargetScriptPath,$TargetPath,$Probe)
            . $TargetScriptPath
            $originalAssert = (Get-Command Assert-SealedHeldTargetContextLease -CommandType Function -ErrorAction Stop).ScriptBlock
            $blockingAssert = {
                param($Lease)
                $Probe.CaptureAndWait($Lease)
                & $originalAssert -Lease $Lease
            }.GetNewClosure()
            Set-Item -LiteralPath Function:\Assert-SealedHeldTargetContextLease -Value $blockingAssert
            Open-SealedHeldTargetContextLease -Path $TargetPath
        }).AddArgument((Join-Path $RepoRoot 'scripts/target-context-common.ps1')).AddArgument($workRoot).AddArgument($targetReceiptStopProbe)
        $targetReceiptStopResult = Invoke-TestPowerShellStopAtProbe -PowerShell $targetReceiptStopPowerShell -Probe $targetReceiptStopProbe
    }
    finally { $targetReceiptStopPowerShell.Dispose() }
    $targetReceiptStoppedLease = $targetReceiptStopProbe.CapturedValue
    $targetReceiptStoppedReceipt = [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($targetReceiptStoppedLease)
    $targetReceiptStoppedHandles = @([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($targetReceiptStoppedReceipt))
    Assert-TestCondition ($targetReceiptStopResult.State -ceq 'Stopped' -and
        $null -ne $targetReceiptStopResult.EndError -and
        [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($targetReceiptStoppedReceipt) -and
        $targetReceiptStoppedHandles.Count -gt 0 -and
        @($targetReceiptStoppedHandles | Where-Object { [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_) }).Count -eq 0) 'real PowerShell.Stop after target receipt binding closes the receipt and every frozen directory handle'

    $safeReceiverTransferAssignments=@($safeContainmentFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$ownershipTransferred' -and
        $node.Right.Extent.Text -ceq '$true'
    },$true) | Sort-Object {$_.Extent.StartOffset})
    $safeReceiverStopProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $safeReceiverRunspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $safeReceiverRunspace.Open()
    $safeReceiverSetupPowerShell=[PowerShell]::Create()
    $safeReceiverStopPowerShell=[PowerShell]::Create()
    $safeReceiverInspectPowerShell=[PowerShell]::Create()
    try {
        $safeReceiverSetupPowerShell.Runspace=$safeReceiverRunspace
        $null=$safeReceiverSetupPowerShell.AddScript({
            param($SafeTreeScriptPath)
            . $SafeTreeScriptPath
            $global:__SafeReceiverStopOwner=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        }).AddArgument($safeTreeScriptPath)
        $null=$safeReceiverSetupPowerShell.Invoke()
        if($safeReceiverSetupPowerShell.HadErrors){throw 'safe receiver Stop setup failed'}
        $safeReceiverStopPowerShell.Runspace=$safeReceiverRunspace
        $null=$safeReceiverStopPowerShell.AddScript({
            param($SafeTreeScriptPath,$TargetPath,[long]$BreakLine,$Probe)
            $null=Set-PSBreakpoint -Script $SafeTreeScriptPath -Line ([int]$BreakLine) -Action {
                $Probe.CaptureAndWait($global:__SafeReceiverStopOwner.GetDeliveredExact())
            }
            Open-SafeDirectoryContainmentChain -Path $TargetPath `
                -OwnershipReceiver $global:__SafeReceiverStopOwner
        }).AddArgument($safeTreeScriptPath).AddArgument($workRoot).AddArgument(
            [long]$safeReceiverTransferAssignments[0].Extent.StartLineNumber).AddArgument($safeReceiverStopProbe)
        $safeReceiverStopResult=Invoke-TestPowerShellStopAtProbe -PowerShell $safeReceiverStopPowerShell -Probe $safeReceiverStopProbe
        $safeReceiverInspectPowerShell.Runspace=$safeReceiverRunspace
        $null=$safeReceiverInspectPowerShell.AddScript({
            Get-PSBreakpoint | Remove-PSBreakpoint
            $handles=@($global:__SafeReceiverStopOwner.GetDeliveredExact())
            $before=@($handles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count
            Close-SafeDirectoryContainmentChain -Handles $handles
            "state=$($global:__SafeReceiverStopOwner.GetStateExact())"
            "count=$($handles.Count)"
            "before=$before"
            "after=$(@($handles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count)"
            Remove-Variable -Name __SafeReceiverStopOwner -Scope Global
        })
        $safeReceiverStopInspection=@($safeReceiverInspectPowerShell.Invoke())
    }
    finally {
        $safeReceiverSetupPowerShell.Dispose()
        $safeReceiverStopPowerShell.Dispose()
        $safeReceiverInspectPowerShell.Dispose()
        $safeReceiverRunspace.Dispose()
    }
    $safeReceiverStoppedHandles=@($safeReceiverStopProbe.CapturedValue)
    Assert-TestCondition ($safeReceiverStopResult.State -ceq 'Stopped' -and
        $null -ne $safeReceiverStopResult.EndError -and
        [string]$safeReceiverStopResult.StateBeforeRelease -cin @('Stopping','Stopped') -and
        $safeReceiverStoppedHandles.Count -gt 0 -and
        'state=DELIVERED' -cin @($safeReceiverStopInspection | ForEach-Object {[string]$_}) -and
        "count=$($safeReceiverStoppedHandles.Count)" -cin @($safeReceiverStopInspection | ForEach-Object {[string]$_}) -and
        "before=$($safeReceiverStoppedHandles.Count)" -cin @($safeReceiverStopInspection | ForEach-Object {[string]$_}) -and
        'after=0' -cin @($safeReceiverStopInspection | ForEach-Object {[string]$_})) 'real PowerShell.Stop after safe-chain publication leaves an exact durable receiver whose held handles are fully recoverable'

    $targetScriptPath=Join-Path $RepoRoot 'scripts/target-context-common.ps1'
    $targetSourceTokens=$null
    $targetSourceParseErrors=$null
    $targetSourceAst=[Management.Automation.Language.Parser]::ParseFile(
        $targetScriptPath,[ref]$targetSourceTokens,[ref]$targetSourceParseErrors)
    if($targetSourceParseErrors.Count -ne 0){throw 'target receiver Stop fixture could not parse its reviewed provider'}
    $targetOpenFunction=$targetSourceAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Open-SealedHeldTargetContextLease'
    },$true)
    $targetReceiverTransferAssignments=@($targetOpenFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$ownershipTransferred' -and
        $node.Right.Extent.Text -ceq '$true'
    },$true) | Sort-Object {$_.Extent.StartOffset})
    $targetReceiverStopProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
    $targetReceiverRunspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $targetReceiverRunspace.Open()
    $targetReceiverSetupPowerShell=[PowerShell]::Create()
    $targetReceiverStopPowerShell=[PowerShell]::Create()
    $targetReceiverInspectPowerShell=[PowerShell]::Create()
    try {
        $targetReceiverSetupPowerShell.Runspace=$targetReceiverRunspace
        $null=$targetReceiverSetupPowerShell.AddScript({
            param($TargetScriptPath)
            . $TargetScriptPath
            $global:__TargetReceiverStopOwner=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        }).AddArgument($targetScriptPath)
        $null=$targetReceiverSetupPowerShell.Invoke()
        if($targetReceiverSetupPowerShell.HadErrors){throw 'target receiver Stop setup failed'}
        $targetReceiverStopPowerShell.Runspace=$targetReceiverRunspace
        $null=$targetReceiverStopPowerShell.AddScript({
            param($TargetScriptPath,$TargetPath,[long]$BreakLine,$Probe)
            $null=Set-PSBreakpoint -Script $TargetScriptPath -Line ([int]$BreakLine) -Action {
                $Probe.CaptureAndWait($global:__TargetReceiverStopOwner.GetDeliveredExact())
            }
            Open-SealedHeldTargetContextLease -Path $TargetPath `
                -OwnershipReceiver $global:__TargetReceiverStopOwner
        }).AddArgument($targetScriptPath).AddArgument($workRoot).AddArgument(
            [long]$targetReceiverTransferAssignments[0].Extent.StartLineNumber).AddArgument($targetReceiverStopProbe)
        $targetReceiverStopResult=Invoke-TestPowerShellStopAtProbe -PowerShell $targetReceiverStopPowerShell -Probe $targetReceiverStopProbe
        $targetReceiverInspectPowerShell.Runspace=$targetReceiverRunspace
        $null=$targetReceiverInspectPowerShell.AddScript({
            Get-PSBreakpoint | Remove-PSBreakpoint
            $lease=$global:__TargetReceiverStopOwner.GetDeliveredExact()
            $receipt=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($lease)
            $handles=@([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($receipt))
            "receiver=$($global:__TargetReceiverStopOwner.GetStateExact())"
            "before=$([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetCloseStateExact($receipt))"
            if([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($receipt)){
                $null=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($lease)
            }
            "after=$([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetCloseStateExact($receipt))"
            "open-handles=$(@($handles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count)"
            Remove-Variable -Name __TargetReceiverStopOwner -Scope Global
        })
        $targetReceiverStopInspection=@($targetReceiverInspectPowerShell.Invoke())
    }
    finally {
        $targetReceiverSetupPowerShell.Dispose()
        $targetReceiverStopPowerShell.Dispose()
        $targetReceiverInspectPowerShell.Dispose()
        $targetReceiverRunspace.Dispose()
    }
    $targetReceiverStoppedLease=$targetReceiverStopProbe.CapturedValue
    $targetReceiverStopInspectionText=@($targetReceiverStopInspection | ForEach-Object {[string]$_})
    Assert-TestCondition ($targetReceiverStopResult.State -ceq 'Stopped' -and
        $null -ne $targetReceiverStopResult.EndError -and
        [string]$targetReceiverStopResult.StateBeforeRelease -cin @('Stopping','Stopped') -and
        $null -ne $targetReceiverStoppedLease -and
        'receiver=DELIVERED' -cin $targetReceiverStopInspectionText -and
        'before=OPEN' -cin $targetReceiverStopInspectionText -and
        'after=CLOSED' -cin $targetReceiverStopInspectionText -and
        'open-handles=0' -cin $targetReceiverStopInspectionText) 'real PowerShell.Stop after target publication leaves an exact durable receiver whose receipt and handles are fully recoverable'

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
    $retryableRegistryCapture = [AiAgentDotfiles.ReceiptReleaseProbe]::IssueSyntheticRouteCapture(
        $registryLive.Wrapper,[object[]]@($registryLiveTargets.Wrapper),
        [object[]](@($registryLive.Wrapper) + @($registryLiveTargets.Wrapper) +
            @($registryRoute.Wrapper) + @($registryReservation.Wrapper) + @($registryFixed.Wrapper)),
        [pscustomobject]@{Kind='live-projection'},
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
    $blockingRegistryCapture = [AiAgentDotfiles.ReceiptReleaseProbe]::IssueSyntheticRouteCapture(
        $registryBlockingLive.Wrapper,[object[]]@($registryBlockingLiveTargets.Wrapper),
        [object[]](@($registryBlockingLive.Wrapper) + @($registryBlockingLiveTargets.Wrapper) +
            @($registryBlockingReservation.Wrapper)),[pscustomobject]@{Kind='live-projection'},
        [AiAgentDotfiles.SealedRegistryRouteLeaseBinding[]]@(),[object[]]@($registryBlockingReservation.Wrapper),[object[]]@(),
        [pscustomobject]@{Kind='original'},[pscustomobject]@{Kind='canonical'},[pscustomobject]@{Kind='snapshot'},
        ('f' * 64),('1' * 64),('2' * 64))
    $blockingRegistryTask = $null
    try {
        $blockingRegistryTask = [AiAgentDotfiles.ReceiptReleaseProbe]::StartReleaseInOwnerRunspace(
            'AiAgentDotfiles.SealedRegistryCurrentRouteCapture','ReleaseExact',$blockingRegistryCapture,
            [Management.Automation.Runspaces.Runspace]::DefaultRunspace)
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
            $routeCleanupShadowState = [pscustomobject]@{Calls=0L}
            $injectedRouteCleanup = {
                param($LiveSetLease,[object[]]$RouteLeases,[object[]]$FixedLeases,[object[]]$ReservationLeases)
                $routeCleanupShadowState.Calls++
                throw 'injected-route-cleanup-error'
            }.GetNewClosure()
            Set-Item -LiteralPath 'Function:Close-SealedRegistryCurrentRouteResources' -Value $injectedRouteCleanup
            try {
                try {
                    Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $cleanupConflictRoute -Reservations @() | Out-Null
                    throw 'FAIL: route acquisition primary error survives cleanup failure (did not throw)'
                }
                catch {
                    if ($_.Exception.Message -like 'FAIL:*') { throw }
                    Assert-TestCondition ($_.Exception.Message -match 'current-route-forbidden-path-overlap' -and
                        $null -eq $_.Exception.Data['SealedRegistryRouteCleanupError'] -and
                        [long]$routeCleanupShadowState.Calls -eq 0L) 'route acquisition preserves its primary error and bypasses a shadowed cleanup provider'
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
            $sealedRouteCapture = Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $witnessed.Context -GlobalLockHandle $globalLock -CanonicalWitness $canonicalWitness -CurrentRouteRootSet $sealedRouteRootSet -Reservations @()
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
        'New-SealedCurrentRouteRootSet',
        'Invoke-SealedHeldCapabilityPreflight',
        'Invoke-SealedHeldFixedInfrastructureCapabilityCapture',
        'Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation',
        'Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation',
        'Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation'
    )) {
        $registryCommand = Get-Command $commandName -ErrorAction Stop
        foreach ($publicSelector in @('HomeRoot','BackupRoot','LockWaitSeconds','TestMode')) {
            Assert-TestCondition (-not $registryCommand.Parameters.ContainsKey($publicSelector)) "$commandName rejects public -$publicSelector"
        }
    }
    $routeIssuerPublicMethods=@([AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer].GetMethods(
        [Reflection.BindingFlags]'Public,Static,DeclaredOnly') | ForEach-Object Name | Sort-Object -CaseSensitive)
    Assert-TestCondition (($routeIssuerPublicMethods -join "`0") -ceq ((@(
        'AbandonOpenExact','BeginOpenExact','ClaimResourceSetExact','InitializeExact','IssueExact',
        'OpenLiveSetExact','OpenTargetExact'
    ) | Sort-Object -CaseSensitive) -join "`0")) 'the route issuer exposes only the reviewed one-shot operation surface'

    $capabilityFixture = New-TestRegistryFixture -Parent $workRoot -Name 'capability-preflight'
    $capabilityCanonical = New-TestCanonicalClaim -Fixture $capabilityFixture -Name 'capability-canonical'
    $capabilityClaimPath = Join-Path $capabilityFixture.Context.CanonicalRootsRoot ($capabilityCanonical.RepoId + '.json')
    $null = Write-TestSemanticDocument -Path $capabilityClaimPath -Document $capabilityCanonical.Claim
    $null = Complete-TestCanonicalSetupState -Fixture $capabilityFixture -CanonicalFixture $capabilityCanonical
    $capabilityProbeRoot = Join-Path $capabilityFixture.Root 'capability-probe-root'
    $capabilityAlternateProbeRoot = Join-Path $capabilityFixture.Root 'capability-probe-root-alternate'
    foreach ($path in @($capabilityProbeRoot,$capabilityAlternateProbeRoot)) { [IO.Directory]::CreateDirectory($path) | Out-Null }

    $rootReceiverStopSourcePath=Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1'
    $rootReceiverStopTokens=$null
    $rootReceiverStopParseErrors=$null
    $rootReceiverStopAst=[Management.Automation.Language.Parser]::ParseFile(
        $rootReceiverStopSourcePath,[ref]$rootReceiverStopTokens,[ref]$rootReceiverStopParseErrors)
    if($rootReceiverStopParseErrors.Count -ne 0){throw 'root ownership receiver Stop fixture could not parse its reviewed provider'}
    $rootReceiverStopRouteFunction=$rootReceiverStopAst.Find({
        param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Open-SealedRegistryCurrentRouteCapture'
    },$true)
    $rootReceiverStopRouteDeliver=@($rootReceiverStopRouteFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.InvokeMemberExpressionAst] -and
        $node.Extent.Text -ceq '$OwnershipReceiver.DeliverExact($routeCapture)'
    },$true))
    $rootReceiverStopRouteBoundaries=@($rootReceiverStopRouteFunction.Body.FindAll({
        param($node)
        $node -is [Management.Automation.Language.AssignmentStatementAst] -and
        $node.Left.Extent.Text -ceq '$routeOwnershipTransferred' -and
        $node.Right.Extent.Text -ceq '$true'
    },$true) | Where-Object {
        $rootReceiverStopRouteDeliver.Count -eq 1 -and
        $_.Extent.StartOffset -gt $rootReceiverStopRouteDeliver[0].Extent.EndOffset
    })
    if($null -eq $rootReceiverStopRouteFunction -or
        $rootReceiverStopRouteDeliver.Count -ne 1 -or
        $rootReceiverStopRouteBoundaries.Count -ne 1){
        throw 'root ownership receiver Stop fixture boundaries changed'
    }

    $rootReceiverStopRunspace=$null
    $rootReceiverStopPowerShells=[Collections.Generic.List[PowerShell]]::new()
    $rootReceiverStopPrimaryError=$null
    try {
        $rootReceiverStopRunspace=[Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rootReceiverStopRunspace.Open()

        $rootReceiverStopSetupPowerShell=[PowerShell]::Create()
        $rootReceiverStopPowerShells.Add($rootReceiverStopSetupPowerShell)
        $rootReceiverStopSetupPowerShell.Runspace=$rootReceiverStopRunspace
        $null=$rootReceiverStopSetupPowerShell.AddScript({
            param(
                $RegistrySourcePath,$TestHostPath,[string]$TokenSid,
                [string]$ProfileRoot,[string]$RoamingRoot,[string]$LocalRoot,
                [string]$CanonicalRepoRoot,[string]$CanonicalLockPath,[string]$ToolchainRoot,
                [string]$ProbeRoot,[string]$AlternateProbeRoot)

            $ErrorActionPreference='Stop'
            . $RegistrySourcePath
            . $TestHostPath
            $global:__RootReceiverStopOwner=[pscustomobject][ordered]@{
                Context=$null
                CanonicalLock=$null
                CanonicalWitness=$null
                GlobalLock=$null
                RouteRootSet=$null
                RouteReceiver=$null
                RouteBreakpoint=$null
                RouteProbe=$null
                RouteBoundaryTransferred=$null
                RouteBoundaryHolds=$null
                RouteOwningOutputCount=0L
                BorrowedRouteRootSet=$null
                BorrowedRouteReceiver=$null
                BorrowedRoute=$null
                ObservationReceiver=$null
                ObservationProbe=$null
                ObservationBoundaryReached=$false
                ObservationBoundaryHolds=$null
                ObservationOwningOutputCount=0L
                CapabilityProbeBindings=[object[]]@(
                    [ordered]@{Role='BackupRoot';ProbeRoot=$AlternateProbeRoot}
                    [ordered]@{Role='ControlBase';ProbeRoot=$ProbeRoot}
                )
                ProbeRoot=$ProbeRoot
                AlternateProbeRoot=$AlternateProbeRoot
            }
            $state=$global:__RootReceiverStopOwner
            $state.Context=Resolve-SealedHomeAuthorityTestContext -TokenSid $TokenSid `
                -ProfileRoot $ProfileRoot -RoamingAppDataRoot $RoamingRoot -LocalAppDataRoot $LocalRoot
            $state.CanonicalLock=Enter-CanonicalRepoLock -LockPath $CanonicalLockPath
            $state.CanonicalWitness=Open-CanonicalHeldNamespaceWitness -RepoRoot $CanonicalRepoRoot `
                -CanonicalLockHandle $state.CanonicalLock -ToolchainRoot $ToolchainRoot
            $state.GlobalLock=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $state.Context `
                -RequiredCanonicalWitness $state.CanonicalWitness
            $state.RouteRootSet=New-SealedCurrentRouteRootSet -CanonicalWitness $state.CanonicalWitness
            $state.RouteReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        }).AddArgument($rootReceiverStopSourcePath).AddArgument(
            (Join-Path $RepoRoot 'tests/helpers/home-authority-test-host.ps1')).AddArgument(
            ([string]$capabilityFixture.Context.TokenSid)).AddArgument(
            ([string]$capabilityFixture.Profile)).AddArgument(
            ([string]$capabilityFixture.Roaming)).AddArgument(
            ([string]$capabilityFixture.Local)).AddArgument(
            ([string]$capabilityCanonical.RepoRoot)).AddArgument(
            ([string]$capabilityCanonical.ContractPaths.LockPath)).AddArgument(
            $RepoRoot).AddArgument($capabilityProbeRoot).AddArgument($capabilityAlternateProbeRoot)
        $rootReceiverStopSetupOutput=@($rootReceiverStopSetupPowerShell.Invoke())
        if($rootReceiverStopSetupPowerShell.HadErrors -or $rootReceiverStopSetupOutput.Count -ne 0){
            throw 'root ownership receiver Stop setup failed'
        }

        $routeRootReceiverStopProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
        $routeRootReceiverStopPowerShell=[PowerShell]::Create()
        $rootReceiverStopPowerShells.Add($routeRootReceiverStopPowerShell)
        $routeRootReceiverStopPowerShell.Runspace=$rootReceiverStopRunspace
        $null=$routeRootReceiverStopPowerShell.AddScript({
            param($SourcePath,[long]$BreakLine,$Probe)

            $ErrorActionPreference='Stop'
            $state=$global:__RootReceiverStopOwner
            $state.RouteProbe=$Probe
            $breakAction={
                $stopState=$global:__RootReceiverStopOwner
                $payload=$stopState.RouteReceiver.GetDeliveredExact()
                $stopState.RouteBoundaryTransferred=[bool]$routeOwnershipTransferred
                $stopState.RouteBoundaryHolds=$stopState.RouteReceiver.HoldsExact($payload)
                $stopState.RouteProbe.CaptureAndWait($payload)
            }
            $state.RouteBreakpoint=Set-PSBreakpoint -Script $SourcePath -Line ([int]$BreakLine) `
                -Action $breakAction
            Open-SealedRegistryCurrentRouteCapture -AuthorityContext $state.Context `
                -GlobalLockHandle $state.GlobalLock -CanonicalWitness $state.CanonicalWitness `
                -CurrentRouteRootSet $state.RouteRootSet -Reservations @() `
                -OwnershipReceiver $state.RouteReceiver |
                ForEach-Object { $state.RouteOwningOutputCount++ }
        }).AddArgument($rootReceiverStopSourcePath).AddArgument(
            [long]$rootReceiverStopRouteBoundaries[0].Extent.StartLineNumber).AddArgument(
            $routeRootReceiverStopProbe)
        $routeRootReceiverStopResult=Invoke-TestPowerShellStopAtProbe `
            -PowerShell $routeRootReceiverStopPowerShell -Probe $routeRootReceiverStopProbe

        $routeRootReceiverInspectPowerShell=[PowerShell]::Create()
        $rootReceiverStopPowerShells.Add($routeRootReceiverInspectPowerShell)
        $routeRootReceiverInspectPowerShell.Runspace=$rootReceiverStopRunspace
        $null=$routeRootReceiverInspectPowerShell.AddScript({
            $ErrorActionPreference='Stop'
            $state=$global:__RootReceiverStopOwner
            if($null -ne $state.RouteBreakpoint){
                $null=Remove-PSBreakpoint -Breakpoint $state.RouteBreakpoint
                $state.RouteBreakpoint=$null
            }
            $capture=$state.RouteReceiver.GetDeliveredExact()
            $liveSet=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($capture)
            $liveReceipt=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($liveSet)
            $targetLeases=[Collections.Generic.List[object]]::new()
            foreach($lease in @([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($liveReceipt))){
                $targetLeases.Add($lease)
            }
            foreach($binding in @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetRouteLeaseRows($capture))){
                $targetLeases.Add([AiAgentDotfiles.SealedRegistryRouteLeaseBinding]::GetLease($binding))
            }
            foreach($lease in @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetFixedLeases($capture))){
                $targetLeases.Add($lease)
            }
            foreach($lease in @([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetReservationLeases($capture))){
                $targetLeases.Add($lease)
            }
            $targetReceipts=[Collections.Generic.List[object]]::new()
            $handles=[Collections.Generic.List[object]]::new()
            foreach($lease in $targetLeases){
                $receipt=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($lease)
                $targetReceipts.Add($receipt)
                foreach($handle in @([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($receipt))){
                    $handles.Add($handle)
                }
            }
            $resources=[Collections.Generic.List[object]]::new()
            $resources.Add($liveSet)
            foreach($lease in $targetLeases){$resources.Add($lease)}
            $routeStateBefore=[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCloseStateExact($capture)
            $liveStateBefore=[string][AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetCloseStateExact($liveReceipt)
            $targetOpenBefore=@($targetReceipts | Where-Object {
                [string][AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetCloseStateExact($_) -ceq 'OPEN'
            }).Count
            $handleOpenBefore=@($handles | Where-Object {
                [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)
            }).Count
            $reservedBefore=@($resources | Where-Object {
                [AiAgentDotfiles.ReceiptReleaseProbe]::HasExactRouteResourceReservation($_)
            }).Count
            $stableBefore=((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $capture) -ne $false)
            $closedExplicitly=$false
            try {
                if([long]$state.RouteOwningOutputCount -ne 0L -or
                    [string]$state.RouteReceiver.GetStateExact() -cne 'DELIVERED' -or
                    -not $state.RouteReceiver.HoldsExact($capture) -or
                    -not [object]::ReferenceEquals($state.RouteProbe.CapturedValue,$capture) -or
                    $null -ne $state.RouteBoundaryTransferred -and [bool]$state.RouteBoundaryTransferred -or
                    -not [bool]$state.RouteBoundaryHolds -or
                    $routeStateBefore -cne 'OPEN' -or
                    -not [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::HasExactIssuanceReceipt($capture) -or
                    -not $stableBefore -or $liveStateBefore -cne 'OPEN' -or
                    $targetReceipts.Count -eq 0 -or $targetOpenBefore -ne $targetReceipts.Count -or
                    $handles.Count -eq 0 -or $handleOpenBefore -ne $handles.Count -or
                    $reservedBefore -ne $resources.Count){
                    throw 'route ownership receiver Stop payload was not exact OPEN before explicit close'
                }
                $null=Close-SealedRegistryCurrentRouteCapture -Capture $capture
                $closedExplicitly=$true
                $routeStateAfter=[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCloseStateExact($capture)
                $liveStateAfter=[string][AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetCloseStateExact($liveReceipt)
                $targetClosedAfter=@($targetReceipts | Where-Object {
                    [string][AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetCloseStateExact($_) -ceq 'CLOSED'
                }).Count
                $handleOpenAfter=@($handles | Where-Object {
                    [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)
                }).Count
                $reservedAfter=@($resources | Where-Object {
                    [AiAgentDotfiles.ReceiptReleaseProbe]::HasExactRouteResourceReservation($_)
                }).Count
                if($routeStateAfter -cne 'CLOSED' -or $liveStateAfter -cne 'CLOSED' -or
                    $targetClosedAfter -ne $targetReceipts.Count -or $handleOpenAfter -ne 0 -or
                    $reservedAfter -ne 0 -or
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::HasExactIssuanceReceipt($capture)){
                    throw 'route ownership receiver Stop payload did not close exactly'
                }
                [pscustomobject][ordered]@{
                    ReceiverState=[string]$state.RouteReceiver.GetStateExact()
                    BoundaryTransferred=[bool]$state.RouteBoundaryTransferred
                    BoundaryHolds=[bool]$state.RouteBoundaryHolds
                    OwningOutputCount=[long]$state.RouteOwningOutputCount
                    RouteBefore=$routeStateBefore
                    RouteAfter=$routeStateAfter
                    LiveBefore=$liveStateBefore
                    LiveAfter=$liveStateAfter
                    TargetReceiptCount=[long]$targetReceipts.Count
                    OpenTargetsBefore=[long]$targetOpenBefore
                    ClosedTargetsAfter=[long]$targetClosedAfter
                    HandleCount=[long]$handles.Count
                    OpenHandlesBefore=[long]$handleOpenBefore
                    OpenHandlesAfter=[long]$handleOpenAfter
                    ResourceCount=[long]$resources.Count
                    ReservedBefore=[long]$reservedBefore
                    ReservedAfter=[long]$reservedAfter
                }
            }
            finally {
                if(-not $closedExplicitly -and
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($capture)){
                    $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($capture)
                }
            }
        })
        $routeRootReceiverInspection=@($routeRootReceiverInspectPowerShell.Invoke())
        if($routeRootReceiverInspectPowerShell.HadErrors -or $routeRootReceiverInspection.Count -ne 1){
            throw 'route ownership receiver Stop inspection failed'
        }
        $routeRootReceiverInspection=$routeRootReceiverInspection[0]
        Assert-TestCondition ($routeRootReceiverStopResult.State -ceq 'Stopped' -and
            $null -ne $routeRootReceiverStopResult.EndError -and
            [string]$routeRootReceiverStopResult.StateBeforeRelease -cin @('Stopping','Stopped') -and
            [string]$routeRootReceiverInspection.ReceiverState -ceq 'DELIVERED' -and
            -not [bool]$routeRootReceiverInspection.BoundaryTransferred -and
            [bool]$routeRootReceiverInspection.BoundaryHolds -and
            [long]$routeRootReceiverInspection.OwningOutputCount -eq 0L -and
            [string]$routeRootReceiverInspection.RouteBefore -ceq 'OPEN' -and
            [string]$routeRootReceiverInspection.RouteAfter -ceq 'CLOSED' -and
            [string]$routeRootReceiverInspection.LiveBefore -ceq 'OPEN' -and
            [string]$routeRootReceiverInspection.LiveAfter -ceq 'CLOSED' -and
            [long]$routeRootReceiverInspection.TargetReceiptCount -gt 0L -and
            [long]$routeRootReceiverInspection.OpenTargetsBefore -eq [long]$routeRootReceiverInspection.TargetReceiptCount -and
            [long]$routeRootReceiverInspection.ClosedTargetsAfter -eq [long]$routeRootReceiverInspection.TargetReceiptCount -and
            [long]$routeRootReceiverInspection.HandleCount -gt 0L -and
            [long]$routeRootReceiverInspection.OpenHandlesBefore -eq [long]$routeRootReceiverInspection.HandleCount -and
            [long]$routeRootReceiverInspection.OpenHandlesAfter -eq 0L -and
            [long]$routeRootReceiverInspection.ResourceCount -gt 0L -and
            [long]$routeRootReceiverInspection.ReservedBefore -eq [long]$routeRootReceiverInspection.ResourceCount -and
            [long]$routeRootReceiverInspection.ReservedAfter -eq 0L) 'real PowerShell.Stop after route publication leaves the caller-owned receiver payload exactly OPEN until explicit close releases every nested receipt, handle, and reservation'

        $observationRootReceiverSetupPowerShell=[PowerShell]::Create()
        $rootReceiverStopPowerShells.Add($observationRootReceiverSetupPowerShell)
        $observationRootReceiverSetupPowerShell.Runspace=$rootReceiverStopRunspace
        $null=$observationRootReceiverSetupPowerShell.AddScript({
            $ErrorActionPreference='Stop'
            $state=$global:__RootReceiverStopOwner
            $state.BorrowedRouteRootSet=New-SealedCurrentRouteRootSet -CanonicalWitness $state.CanonicalWitness
            $state.BorrowedRouteReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            Open-SealedRegistryCurrentRouteCapture -AuthorityContext $state.Context `
                -GlobalLockHandle $state.GlobalLock -CanonicalWitness $state.CanonicalWitness `
                -CurrentRouteRootSet $state.BorrowedRouteRootSet -Reservations @() `
                -OwnershipReceiver $state.BorrowedRouteReceiver
            $state.BorrowedRoute=$state.BorrowedRouteReceiver.GetDeliveredExact()
            $state.ObservationReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        })
        $observationRootReceiverSetupOutput=@($observationRootReceiverSetupPowerShell.Invoke())
        if($observationRootReceiverSetupPowerShell.HadErrors -or
            $observationRootReceiverSetupOutput.Count -ne 0){
            throw 'observation ownership receiver Stop setup failed'
        }
        $observationRootReceiverStopProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
        $observationRootReceiverStopPowerShell=[PowerShell]::Create()
        $rootReceiverStopPowerShells.Add($observationRootReceiverStopPowerShell)
        $observationRootReceiverStopPowerShell.Runspace=$rootReceiverStopRunspace
        $null=$observationRootReceiverStopPowerShell.AddScript({
            param($Probe)

            $ErrorActionPreference='Stop'
            $state=$global:__RootReceiverStopOwner
            $state.ObservationProbe=$Probe
            Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
                -CurrentRouteCapture $state.BorrowedRoute `
                -CapabilityProbeBindings @($state.CapabilityProbeBindings) `
                -OwnershipReceiver $state.ObservationReceiver |
                ForEach-Object { $state.ObservationOwningOutputCount++ }
            $payload=$state.ObservationReceiver.GetDeliveredExact()
            $state.ObservationBoundaryReached=$true
            $state.ObservationBoundaryHolds=$state.ObservationReceiver.HoldsExact($payload)
            $state.ObservationProbe.CaptureAndWait($payload)
        }).AddArgument($observationRootReceiverStopProbe)
        $observationRootReceiverStopResult=Invoke-TestPowerShellStopAtProbe `
            -PowerShell $observationRootReceiverStopPowerShell `
            -Probe $observationRootReceiverStopProbe -BarrierTimeoutMilliseconds 120000

        $observationRootReceiverInspectPowerShell=[PowerShell]::Create()
        $rootReceiverStopPowerShells.Add($observationRootReceiverInspectPowerShell)
        $observationRootReceiverInspectPowerShell.Runspace=$rootReceiverStopRunspace
        $null=$observationRootReceiverInspectPowerShell.AddScript({
            $ErrorActionPreference='Stop'
            $state=$global:__RootReceiverStopOwner
            $observation=$state.ObservationReceiver.GetDeliveredExact()
            $fieldFlags=[Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic
            $envelopeLeaseField=$observation.GetType().GetField('outerFixedEnvelopeLease',$fieldFlags)
            $handleChainsField=$observation.GetType().GetField('outerFixedEnvelopeHandleChains',$fieldFlags)
            if($null -eq $envelopeLeaseField -or $null -eq $handleChainsField){
                throw 'observation ownership receiver Stop fixture could not inspect the frozen envelope'
            }
            $envelopeLease=$envelopeLeaseField.GetValue($observation)
            $handleChains=[object[][]]$handleChainsField.GetValue($observation)
            $handles=[Collections.Generic.List[object]]::new()
            for($chainIndex=0;$chainIndex -lt $handleChains.Length;$chainIndex++){
                foreach($handle in $handleChains[$chainIndex]){$handles.Add($handle)}
            }
            $observationStateBefore=[string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCloseStateExact($observation)
            $handleOpenBefore=@($handles | Where-Object {
                [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)
            }).Count
            $guardBefore=[AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard]::IsReservedExact($envelopeLease)
            $borrowedStateBefore=[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCloseStateExact($state.BorrowedRoute)
            $borrowedStableBefore=((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $state.BorrowedRoute) -ne $false)
            $observationClosedExplicitly=$false
            $borrowedClosedExplicitly=$false
            try {
                if([long]$state.ObservationOwningOutputCount -ne 0L -or
                    [string]$state.ObservationReceiver.GetStateExact() -cne 'DELIVERED' -or
                    -not $state.ObservationReceiver.HoldsExact($observation) -or
                    -not [object]::ReferenceEquals($state.ObservationProbe.CapturedValue,$observation) -or
                    -not [bool]$state.ObservationBoundaryReached -or
                    -not [bool]$state.ObservationBoundaryHolds -or
                    $observationStateBefore -cne 'OPEN' -or
                    $handleChains.Length -ne 6 -or $handles.Count -eq 0 -or
                    $handleOpenBefore -ne $handles.Count -or [bool]$envelopeLease.IsClosed -or
                    -not $guardBefore -or $borrowedStateBefore -cne 'OPEN' -or
                    -not $borrowedStableBefore -or
                    -not [object]::ReferenceEquals(
                        [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCurrentRouteCaptureExact($observation),
                        $state.BorrowedRoute)){
                    throw 'observation ownership receiver Stop payload was not exact OPEN before explicit close'
                }
                $null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
                    -Observation $observation
                $observationClosedExplicitly=$true
                $observationStateAfter=[string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCloseStateExact($observation)
                $handleOpenAfter=@($handles | Where-Object {
                    [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)
                }).Count
                $guardAfter=[AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard]::IsReservedExact($envelopeLease)
                $borrowedStateAfterObservationClose=[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCloseStateExact($state.BorrowedRoute)
                $borrowedStableAfterObservationClose=((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $state.BorrowedRoute) -ne $false)
                if($observationStateAfter -cne 'CLOSED' -or $handleOpenAfter -ne 0 -or
                    -not [bool]$envelopeLease.IsClosed -or $guardAfter -or
                    $borrowedStateAfterObservationClose -cne 'OPEN' -or
                    -not $borrowedStableAfterObservationClose){
                    throw 'observation ownership receiver Stop payload did not close exactly'
                }
                $null=Close-SealedRegistryCurrentRouteCapture -Capture $state.BorrowedRoute
                $borrowedClosedExplicitly=$true
                $borrowedStateFinal=[string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCloseStateExact($state.BorrowedRoute)
                if($borrowedStateFinal -cne 'CLOSED'){
                    throw 'observation ownership receiver Stop borrowed route did not close exactly'
                }
                [pscustomobject][ordered]@{
                    ReceiverState=[string]$state.ObservationReceiver.GetStateExact()
                    BoundaryReached=[bool]$state.ObservationBoundaryReached
                    BoundaryHolds=[bool]$state.ObservationBoundaryHolds
                    OwningOutputCount=[long]$state.ObservationOwningOutputCount
                    ObservationBefore=$observationStateBefore
                    ObservationAfter=$observationStateAfter
                    HandleChainCount=[long]$handleChains.Length
                    HandleCount=[long]$handles.Count
                    OpenHandlesBefore=[long]$handleOpenBefore
                    OpenHandlesAfter=[long]$handleOpenAfter
                    GuardBefore=[bool]$guardBefore
                    GuardAfter=[bool]$guardAfter
                    BorrowedBefore=$borrowedStateBefore
                    BorrowedAfterObservationClose=$borrowedStateAfterObservationClose
                    BorrowedFinal=$borrowedStateFinal
                    ProbeRootEntries=[long]@([IO.Directory]::EnumerateFileSystemEntries($state.ProbeRoot)).Count
                    AlternateProbeRootEntries=[long]@([IO.Directory]::EnumerateFileSystemEntries($state.AlternateProbeRoot)).Count
                }
            }
            finally {
                if(-not $observationClosedExplicitly -and
                    [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation)){
                    $null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
                        -Observation $observation
                }
                if(-not $borrowedClosedExplicitly -and
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($state.BorrowedRoute)){
                    $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($state.BorrowedRoute)
                }
            }
        })
        $observationRootReceiverInspection=@($observationRootReceiverInspectPowerShell.Invoke())
        if($observationRootReceiverInspectPowerShell.HadErrors -or
            $observationRootReceiverInspection.Count -ne 1){
            throw 'observation ownership receiver Stop inspection failed'
        }
        $observationRootReceiverInspection=$observationRootReceiverInspection[0]
        $observationRootReceiverCondition=$observationRootReceiverStopResult.State -ceq 'Stopped' -and
            [string]$observationRootReceiverStopResult.StateBeforeRelease -cin @('Stopping','Stopped') -and
            [string]$observationRootReceiverInspection.ReceiverState -ceq 'DELIVERED' -and
            [bool]$observationRootReceiverInspection.BoundaryReached -and
            [bool]$observationRootReceiverInspection.BoundaryHolds -and
            [long]$observationRootReceiverInspection.OwningOutputCount -eq 0L -and
            [string]$observationRootReceiverInspection.ObservationBefore -ceq 'OPEN' -and
            [string]$observationRootReceiverInspection.ObservationAfter -ceq 'CLOSED' -and
            [long]$observationRootReceiverInspection.HandleChainCount -eq 6L -and
            [long]$observationRootReceiverInspection.HandleCount -gt 0L -and
            [long]$observationRootReceiverInspection.OpenHandlesBefore -eq [long]$observationRootReceiverInspection.HandleCount -and
            [long]$observationRootReceiverInspection.OpenHandlesAfter -eq 0L -and
            [bool]$observationRootReceiverInspection.GuardBefore -and
            -not [bool]$observationRootReceiverInspection.GuardAfter -and
            [string]$observationRootReceiverInspection.BorrowedBefore -ceq 'OPEN' -and
            [string]$observationRootReceiverInspection.BorrowedAfterObservationClose -ceq 'OPEN' -and
            [string]$observationRootReceiverInspection.BorrowedFinal -ceq 'CLOSED' -and
            [long]$observationRootReceiverInspection.ProbeRootEntries -eq 0L -and
            [long]$observationRootReceiverInspection.AlternateProbeRootEntries -eq 0L
        if(-not $observationRootReceiverCondition){
            Write-Host ('  TRACE observation receiver Stop result: ' +
                ($observationRootReceiverStopResult | ConvertTo-Json -Compress -Depth 4))
            Write-Host ('  TRACE observation receiver inspection: ' +
                ($observationRootReceiverInspection | ConvertTo-Json -Compress -Depth 4))
        }
        Assert-TestCondition $observationRootReceiverCondition 'real PowerShell.Stop after observation publication leaves the caller-owned receiver payload and frozen envelope exactly OPEN until explicit close while the borrowed route remains OPEN'
    }
    catch {
        $rootReceiverStopPrimaryError=$_
        throw
    }
    finally {
        $rootReceiverStopCleanupError=$null
        if($null -ne $rootReceiverStopRunspace -and
            $rootReceiverStopRunspace.RunspaceStateInfo.State -eq
                [Management.Automation.Runspaces.RunspaceState]::Opened){
            $rootReceiverStopCleanupPowerShell=[PowerShell]::Create()
            try {
                $rootReceiverStopCleanupPowerShell.Runspace=$rootReceiverStopRunspace
                $null=$rootReceiverStopCleanupPowerShell.AddScript({
                    $ErrorActionPreference='Stop'
                    $cleanupErrors=[Collections.Generic.List[string]]::new()
                    try { Get-PSBreakpoint | Remove-PSBreakpoint -ErrorAction SilentlyContinue }
                    catch { $cleanupErrors.Add([string]$_.Exception.Message) }
                    $stateVariable=Get-Variable -Name __RootReceiverStopOwner -Scope Global `
                        -ErrorAction SilentlyContinue
                    if($null -ne $stateVariable){
                        $state=$stateVariable.Value
                        if($null -ne $state.ObservationReceiver){
                            try {
                                if([string]$state.ObservationReceiver.GetStateExact() -ceq 'DELIVERED'){
                                    $observation=$state.ObservationReceiver.GetDeliveredExact()
                                    if([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation)){
                                        $null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
                                            -Observation $observation
                                    }
                                }
                            }
                            catch { $cleanupErrors.Add([string]$_.Exception.Message) }
                        }
                        foreach($receiverName in @('BorrowedRouteReceiver','RouteReceiver')){
                            $receiver=$state.$receiverName
                            if($null -eq $receiver){continue}
                            try {
                                if([string]$receiver.GetStateExact() -ceq 'DELIVERED'){
                                    $capture=$receiver.GetDeliveredExact()
                                    if([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($capture)){
                                        $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($capture)
                                    }
                                }
                            }
                            catch { $cleanupErrors.Add([string]$_.Exception.Message) }
                        }
                        if($null -ne $state.GlobalLock){
                            try { Exit-HomeAuthorityGlobalLiveLock -LockHandle $state.GlobalLock }
                            catch { $cleanupErrors.Add([string]$_.Exception.Message) }
                        }
                        if($null -ne $state.CanonicalWitness){
                            try { Close-CanonicalHeldNamespaceWitness -Witness $state.CanonicalWitness }
                            catch { $cleanupErrors.Add([string]$_.Exception.Message) }
                        }
                        if($null -ne $state.CanonicalLock){
                            try { Exit-CanonicalRepoLock -LockHandle $state.CanonicalLock }
                            catch { $cleanupErrors.Add([string]$_.Exception.Message) }
                        }
                        Remove-Variable -Name __RootReceiverStopOwner -Scope Global `
                            -ErrorAction SilentlyContinue
                    }
                    if($cleanupErrors.Count -gt 0){throw ($cleanupErrors -join '; ')}
                })
                $null=$rootReceiverStopCleanupPowerShell.Invoke()
                if($rootReceiverStopCleanupPowerShell.HadErrors){
                    $rootReceiverStopCleanupError=[InvalidOperationException]::new(
                        [string]$rootReceiverStopCleanupPowerShell.Streams.Error[0].Exception.Message)
                }
            }
            catch { $rootReceiverStopCleanupError=$_.Exception }
            finally { $rootReceiverStopCleanupPowerShell.Dispose() }
        }
        foreach($powerShell in $rootReceiverStopPowerShells){$powerShell.Dispose()}
        if($null -ne $rootReceiverStopRunspace){$rootReceiverStopRunspace.Dispose()}
        if($null -ne $rootReceiverStopCleanupError){
            if($null -eq $rootReceiverStopPrimaryError){throw $rootReceiverStopCleanupError}
            try {
                $rootReceiverStopPrimaryError.Exception.Data['RootOwnershipReceiverStopCleanupError']=
                    [string]$rootReceiverStopCleanupError.Message
            }
            catch { }
        }
    }
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

            $fixedCaptureCommand = Get-Command Invoke-SealedHeldFixedInfrastructureCapabilityCapture -CommandType Function -ErrorAction Stop
            Assert-TestCondition (-not $fixedCaptureCommand.Parameters.ContainsKey('Path') -and
                -not $fixedCaptureCommand.Parameters.ContainsKey('SealedCapabilityPreflightEvidence') -and
                $fixedCaptureCommand.Parameters.ContainsKey('CapabilityProbeBindings')) 'fixed infrastructure capture accepts role bindings but no caller-selected target Path or preflight evidence'

            $fixedObservationOpenCommand=Get-Command Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CommandType Function -ErrorAction Stop
            $fixedObservationAssertCommand=Get-Command Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CommandType Function -ErrorAction Stop
            $fixedObservationCloseCommand=Get-Command Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CommandType Function -ErrorAction Stop
            Assert-TestCondition ((@($fixedObservationOpenCommand.ScriptBlock.Ast.Body.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath}) -join "`0") -ceq "CurrentRouteCapture`0CapabilityProbeBindings`0OwnershipReceiver" -and
                (@($fixedObservationAssertCommand.ScriptBlock.Ast.Body.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath}) -join "`0") -ceq 'Observation' -and
                (@($fixedObservationCloseCommand.ScriptBlock.Ast.Body.ParamBlock.Parameters | ForEach-Object {$_.Name.VariablePath.UserPath}) -join "`0") -ceq 'Observation' -and
                $fixedObservationOpenCommand.Parameters.ContainsKey('CurrentRouteCapture') -and
                $fixedObservationOpenCommand.Parameters.ContainsKey('CapabilityProbeBindings') -and
                $fixedObservationOpenCommand.Parameters.ContainsKey('OwnershipReceiver') -and
                $fixedObservationOpenCommand.Parameters['CurrentRouteCapture'].ParameterType -eq [object] -and
                $fixedObservationOpenCommand.Parameters['CapabilityProbeBindings'].ParameterType -eq [object[]] -and
                $fixedObservationOpenCommand.Parameters['OwnershipReceiver'].ParameterType -eq [AiAgentDotfiles.SealedOwnershipTransferReceiver] -and
                @($fixedObservationOpenCommand.Parameters['CurrentRouteCapture'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -eq 1 -and
                @($fixedObservationOpenCommand.Parameters['CapabilityProbeBindings'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -eq 1 -and
                @($fixedObservationOpenCommand.Parameters['OwnershipReceiver'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -eq 1 -and
                @($fixedObservationOpenCommand.Parameters['CapabilityProbeBindings'].Attributes | Where-Object {$_ -is [Management.Automation.AllowNullAttribute]}).Count -eq 1 -and
                @($fixedObservationOpenCommand.Parameters['CapabilityProbeBindings'].Attributes | Where-Object {$_ -is [Management.Automation.AllowEmptyCollectionAttribute]}).Count -eq 1 -and
                $fixedObservationAssertCommand.Parameters['Observation'].ParameterType -eq [object] -and
                $fixedObservationCloseCommand.Parameters['Observation'].ParameterType -eq [object] -and
                @($fixedObservationAssertCommand.Parameters['Observation'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -eq 1 -and
                @($fixedObservationCloseCommand.Parameters['Observation'].Attributes | Where-Object {$_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory}).Count -eq 1 -and
                @($fixedObservationAssertCommand.Parameters['Observation'].Attributes | Where-Object {$_ -is [Management.Automation.AllowNullAttribute]}).Count -eq 1 -and
                @($fixedObservationCloseCommand.Parameters['Observation'].Attributes | Where-Object {$_ -is [Management.Automation.AllowNullAttribute]}).Count -eq 1 -and
                @('AuthorityContext','GlobalLockHandle','CanonicalWitness','FixedEvidence','SealedCapabilityPreflightEvidence',
                    'Path','ControlBase','BackupRoot','HomeRoot','LockWaitSeconds','TestMode','Operation','Callback','ScriptBlock' |
                    Where-Object {$fixedObservationOpenCommand.Parameters.ContainsKey($_)}).Count -eq 0) 'held current-route observation exposes exact route-plus-bindings-plus-caller-owned-receiver Open and observation-only Assert/Close contracts with no caller-supplied path, evidence, callback, or test selector'

            $fixedOriginalRawPreflight = (Get-Command Invoke-SealedHeldCapabilityPreflight -CommandType Function -ErrorAction Stop).ScriptBlock
            $fixedOriginalCapabilityProbe = (Get-Command Invoke-TargetFilesystemCapabilityProbe -CommandType Function -ErrorAction Stop).ScriptBlock
            $fixedTreeBefore = Get-TestRegistryTreeHash -Fixture $capabilityFixture
            $fixedEvidence = Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot}
            )
            Assert-TestCondition ($fixedEvidence -is [AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence] -and
                'AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence' -cin @($fixedEvidence.PSObject.TypeNames)) 'fixed infrastructure capture returns genuine CLR-sealed evidence'
            $fixedRows=@([AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetRowsExact($fixedEvidence))
            Assert-TestCondition ($fixedRows.Count -eq 2 -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRoleExact($fixedRows[0]) -ceq 'ControlBase' -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRoleExact($fixedRows[1]) -ceq 'BackupRoot') 'input permutation produces the fixed ControlBase then BackupRoot role order'
            $fixedControlProbeMetadata=Resolve-TargetContext -Path $capabilityProbeRoot -Mode MetadataOnly
            $fixedBackupProbeMetadata=Resolve-TargetContext -Path $capabilityAlternateProbeRoot -Mode MetadataOnly
            Assert-TestCondition ([string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootPathExact($fixedRows[0]) -ceq [IO.Path]::GetFullPath($capabilityProbeRoot) -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootPathExact($fixedRows[1]) -ceq [IO.Path]::GetFullPath($capabilityAlternateProbeRoot) -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootIdentityExact($fixedRows[0]) -ceq [string]$fixedControlProbeMetadata.DeepestExistingParentIdentity -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootIdentityExact($fixedRows[1]) -ceq [string]$fixedBackupProbeMetadata.DeepestExistingParentIdentity -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootIdentityExact($fixedRows[0]) -cne
                    [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetProbeRootIdentityExact($fixedRows[1])) 'fixed roles retain independent exact probe-root mappings even when their filesystem capability hashes can match'
            Assert-TestCondition ([string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetCoverageExact($fixedEvidence) -ceq 'FIXED_INFRASTRUCTURE_PROBED' -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetAuthorityContextHashExact($fixedEvidence) -ceq (Get-SemanticJsonHash -InputObject $capabilityFixture.Context) -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRequestedPathExact($fixedRows[0]) -ceq [IO.Path]::GetFullPath([string]$capabilityFixture.Context.ControlBase) -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRequestedPathExact($fixedRows[1]) -ceq [IO.Path]::GetFullPath([string]$capabilityFixture.Context.BackupRoot)) 'fixed evidence binds its authority, coverage, roles, and derived target paths'
            Assert-TestCondition ((Get-SealedFixedInfrastructureCapabilityProjectionHash -Evidence $fixedEvidence) -ceq
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetProjectionHashExact($fixedEvidence)) 'fixed infrastructure projection hash is reproducible from exact getters'
            Assert-TestCondition ([string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFilesystemCapabilityHashExact($fixedRows[0]) -ceq
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFilesystemCapabilityHashExact($fixedRows[1])) 'same-volume fixed roles may share capability semantics without collapsing their role mapping'
            Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $fixedTreeBefore -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'successful fixed capture leaves the authority tree stable and no owned probe residue'

            $fixedRowsClone=[AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetRowsExact($fixedEvidence)
            $fixedRowsClone[0]=$fixedRowsClone[1]
            $fixedEvidence | Add-Member -Force -NotePropertyName Rows -NotePropertyValue @()
            $fixedEvidence | Add-Member -Force -NotePropertyName Coverage -NotePropertyValue 'FORGED'
            $fixedRows[0] | Add-Member -Force -NotePropertyName Role -NotePropertyValue 'BackupRoot'
            $fixedRowsAfterForgery=@([AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetRowsExact($fixedEvidence))
            Assert-TestCondition ($fixedRowsAfterForgery.Count -eq 2 -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetCoverageExact($fixedEvidence) -ceq 'FIXED_INFRASTRUCTURE_PROBED' -and
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetRoleExact($fixedRowsAfterForgery[0]) -ceq 'ControlBase') 'ETS shadows and mutation of a returned rows clone cannot alter sealed fixed evidence'

            $fixedExpectedBindings=@(
                [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot;ExpectedFilesystemCapabilityHash=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFilesystemCapabilityHashExact($fixedRows[1])}
                [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=[string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFilesystemCapabilityHashExact($fixedRows[0])}
            )
            $fixedExpectedEvidence=Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings $fixedExpectedBindings
            $fixedExpectedRows=@([AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetRowsExact($fixedExpectedEvidence))
            Assert-TestCondition (@($fixedExpectedRows | Where-Object {
                -not [bool][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetVerifiedAgainstExpectedExact($_) -or
                [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetExpectedCapabilityHashExact($_) -cne
                    [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityRoleRow]::GetFilesystemCapabilityHashExact($_)
            }).Count -eq 0) 'each fixed role independently preserves expected-hash and VerifiedAgainstExpected semantics'

            $fixedGuardProbeState=[pscustomobject]@{Count=0L}
            $fixedGuardProbe={
                param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                $fixedGuardProbeState.Count++
                throw 'unexpected-fixed-capability-probe'
            }.GetNewClosure()
            $fixedInvalidBindingCases=@(
                [pscustomobject]@{Name='missing role row';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot})}
                [pscustomobject]@{Name='null row';Bindings=@($null,[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='missing Role property';Bindings=@([ordered]@{ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='missing ProbeRoot property';Bindings=@([ordered]@{Role='ControlBase'},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='blank Role value';Bindings=@([ordered]@{Role='   ';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='duplicate role';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='ControlBase';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='extra role';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='RecoveryRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='extra property';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;Extra='x'},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='invalid hash';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash='not-a-hash'},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='null expected hash';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=$null},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='empty expected hash';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=''},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='whitespace expected hash';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash='  '},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
                [pscustomobject]@{Name='empty ProbeRoot value';Bindings=@([ordered]@{Role='ControlBase';ProbeRoot=''},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot})}
            )
            try {
                Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $fixedGuardProbe
                foreach($case in $fixedInvalidBindingCases){
                    Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings $case.Bindings | Out-Null } '^fixed-infrastructure-capability-binding-invalid$' "fixed role map rejects $($case.Name) before the first real probe"
                }
                Assert-TestCondition ([long]$fixedGuardProbeState.Count -eq 0L) 'the complete fixed role-map contract is validated before the first real probe'
            }
            finally { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $fixedOriginalCapabilityProbe }

            $fixedFailureTreeBefore=Get-TestRegistryTreeHash -Fixture $capabilityFixture
            Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=('0' * 64)}
                [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
            ) | Out-Null } '^capability-evidence-mismatch$' 'a real fixed-role expected-hash mismatch propagates the lower-level stable error'
            Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $fixedFailureTreeBefore -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'failed fixed capture closes its outer envelope and leaves no owned probe residue or authority drift'

            $fixedOriginalEnvelopeClose=(Get-Command Close-SealedHomeAuthorityFixedEnvelope -CommandType Function -ErrorAction Stop).ScriptBlock
            $fixedEnvelopeCloseState=[pscustomobject]@{OuterCalls=0L}
            $fixedEnvelopeCloseShadow={
                param([Parameter(Mandatory)]$EnvelopeLease)
                $directCaller=[string]@(Get-PSCallStack)[1].Command
                & $fixedOriginalEnvelopeClose -EnvelopeLease $EnvelopeLease
                if($directCaller -ceq 'Invoke-SealedHeldFixedInfrastructureCapabilityCapture'){
                    $fixedEnvelopeCloseState.OuterCalls++
                    throw 'injected-fixed-capability-close-error'
                }
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Close-SealedHomeAuthorityFixedEnvelope -Value $fixedEnvelopeCloseShadow
                $fixedPrimaryAndCleanupError=$null
                try {
                    Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                        [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=('0' * 64)}
                        [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                    ) | Out-Null
                    throw 'FAIL: fixed capture preserves primary and records outer cleanup failure (did not throw)'
                }
                catch {
                    if($_.Exception.Message -like 'FAIL:*'){throw}
                    $fixedPrimaryAndCleanupError=$_
                }
                Assert-TestCondition ($fixedPrimaryAndCleanupError.Exception.Message -ceq 'capability-evidence-mismatch' -and
                    [string]$fixedPrimaryAndCleanupError.Exception.Data['SealedFixedInfrastructureCapabilityCleanupError'] -ceq 'injected-fixed-capability-close-error') 'fixed capture preserves its primary exception and records outer-envelope cleanup failure as secondary Data'

                Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                    [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot}
                    [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                ) | Out-Null } '^injected-fixed-capability-close-error$' 'fixed capture surfaces outer-envelope cleanup failure when there is no primary error'
                Assert-TestCondition ([long]$fixedEnvelopeCloseState.OuterCalls -eq 2L -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'outer-envelope close failure regressions still release both leases and leave no owned probe residue'
            }
            finally { Set-Item -LiteralPath Function:\Close-SealedHomeAuthorityFixedEnvelope -Value $fixedOriginalEnvelopeClose }

            $fixedBaselineRaw=& $fixedOriginalRawPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @(
                [ordered]@{Path=[string]$capabilityFixture.Context.ControlBase;ProbeRoot=$capabilityProbeRoot}
                [ordered]@{Path=[string]$capabilityFixture.Context.BackupRoot;ProbeRoot=$capabilityAlternateProbeRoot}
            )
            $fixedEvidenceValidationArguments=@{
                AuthorityContext=$capabilityFixture.Context
                ExpectedAuthorityContextHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetAuthorityContextHashExact($fixedBaselineRaw)
                ExpectedFixedEnvelopeHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetFixedEnvelopeHashExact($fixedBaselineRaw)
                ExpectedLockSecurityHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetLockSecurityHashExact($fixedBaselineRaw)
                ControlBaseProbeRoot=$capabilityProbeRoot
                BackupRootProbeRoot=$capabilityAlternateProbeRoot
                ControlBaseExpectedCapabilityHash=$null
                BackupRootExpectedCapabilityHash=$null
            }
            $fixedValidatedBaselineRows=Assert-SealedFixedInfrastructureCapabilityEvidenceExact -Evidence $fixedBaselineRaw @fixedEvidenceValidationArguments
            Assert-TestCondition ($fixedValidatedBaselineRows.ControlBase -is [AiAgentDotfiles.SealedCapabilityPreflightRow] -and
                $fixedValidatedBaselineRows.BackupRoot -is [AiAgentDotfiles.SealedCapabilityPreflightRow]) 'the side-effect-free fixed evidence validator returns the exact two role-mapped raw rows for genuine evidence'

            $fixedForgedRaw=[pscustomobject]@{}
            $fixedForgedRaw.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedCapabilityPreflightEvidence')
            Assert-ThrowsPattern { Assert-SealedFixedInfrastructureCapabilityEvidenceExact -Evidence $fixedForgedRaw @fixedEvidenceValidationArguments | Out-Null } '^fixed-infrastructure-capability-evidence-invalid$' 'the fixed evidence validator rejects a type-name-forged lower-level evidence object'

            $fixedBadProjectionRaw=[AiAgentDotfiles.SealedCapabilityPreflightEvidence]::CreateExact(
                [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetAuthorityContextHashExact($fixedBaselineRaw),
                [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetFixedEnvelopeHashExact($fixedBaselineRaw),
                [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetLockSecurityHashExact($fixedBaselineRaw),
                [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($fixedBaselineRaw),('0' * 64))
            Assert-ThrowsPattern { Assert-SealedFixedInfrastructureCapabilityEvidenceExact -Evidence $fixedBadProjectionRaw @fixedEvidenceValidationArguments | Out-Null } '^fixed-infrastructure-capability-evidence-invalid$' 'the fixed evidence validator rejects genuine CLR evidence with an unreproducible projection hash'

            $newFixedRawMutation={
                param([AiAgentDotfiles.SealedCapabilityPreflightEvidence]$Source,[string]$Kind)
                $authorityHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetAuthorityContextHashExact($Source)
                $fixedHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetFixedEnvelopeHashExact($Source)
                $lockHash=[string][AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetLockSecurityHashExact($Source)
                $rowData=[Collections.Generic.List[object]]::new()
                foreach($row in @([AiAgentDotfiles.SealedCapabilityPreflightEvidence]::GetRowsExact($Source))){
                    $rowData.Add([ordered]@{
                        RequestedPath=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetRequestedPathExact($row)
                        LocationKey=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetLocationKeyExact($row)
                        TargetStatus=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetTargetStatusExact($row)
                        ProbeRootPath=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootPathExact($row)
                        ProbeRootLocationKey=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootLocationKeyExact($row)
                        ProbeRootIdentity=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetProbeRootIdentityExact($row)
                        DriveType=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetDriveTypeExact($row)
                        FileSystemType=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFileSystemTypeExact($row)
                        VolumeSerial=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVolumeSerialExact($row)
                        FilesystemCapabilityHash=[string][AiAgentDotfiles.SealedCapabilityPreflightRow]::GetFilesystemCapabilityHashExact($row)
                        ExpectedCapabilityHash=[AiAgentDotfiles.SealedCapabilityPreflightRow]::GetExpectedCapabilityHashExact($row)
                        VerifiedAgainstExpected=[AiAgentDotfiles.SealedCapabilityPreflightRow]::GetVerifiedAgainstExpectedExact($row)
                    })
                }
                switch($Kind){
                    'AuthorityHash' {$authorityHash='0' * 64}
                    'RowCount' {$rowData.RemoveAt(1)}
                    'TargetStatus' {$rowData[0].TargetStatus='MISSING'}
                    'TargetPath' {$rowData[0].RequestedPath=[IO.Path]::GetFullPath([string]$capabilityFixture.Root)}
                    'ProbeIdentity' {$rowData[0].ProbeRootIdentity='ffffffff:ffffffffffffffff'}
                    'VolumeSerial' {$rowData[0].VolumeSerial='ffffffff'}
                    'FilesystemType' {$rowData[0].FileSystemType='ReFS'}
                    'CapabilityHash' {foreach($data in $rowData){$data.FilesystemCapabilityHash='0' * 64}}
                    'ExpectedSemantics' {$rowData[0].ExpectedCapabilityHash='0' * 64;$rowData[0].VerifiedAgainstExpected=$false}
                    default {throw "unsupported fixed raw mutation: $Kind"}
                }
                $mutatedRows=[AiAgentDotfiles.SealedCapabilityPreflightRow[]]::new($rowData.Count)
                for($index=0;$index -lt $rowData.Count;$index++){
                    $data=$rowData[$index]
                    $mutatedRows[$index]=[AiAgentDotfiles.SealedCapabilityPreflightRow]::CreateExact(
                        $data.RequestedPath,$data.LocationKey,$data.TargetStatus,
                        $data.ProbeRootPath,$data.ProbeRootLocationKey,$data.ProbeRootIdentity,
                        $data.DriveType,$data.FileSystemType,$data.VolumeSerial,$data.FilesystemCapabilityHash,
                        $data.ExpectedCapabilityHash,$data.VerifiedAgainstExpected)
                }
                $rowProjections=foreach($row in $mutatedRows){Get-SealedCapabilityPreflightRowProjection -Row $row}
                $projectionHash=Get-SemanticJsonHash -InputObject ([ordered]@{
                    AuthorityContextHash=$authorityHash;FixedEnvelopeHash=$fixedHash;LockSecurityHash=$lockHash;Rows=@($rowProjections)
                })
                return [AiAgentDotfiles.SealedCapabilityPreflightEvidence]::CreateExact($authorityHash,$fixedHash,$lockHash,$mutatedRows,$projectionHash)
            }.GetNewClosure()

            $fixedExactIssuerRedFailures=[Collections.Generic.List[string]]::new()
            $fixedForgedSelfConsistentRaw=& $newFixedRawMutation $fixedBaselineRaw 'CapabilityHash'
            $fixedForgedRawShadowState=[pscustomobject]@{Called=$false}
            $fixedForgedSelfConsistentRawShadow={
                param($AuthorityContext,$GlobalLockHandle,$CanonicalWitness,$CapabilityTargets)
                $fixedForgedRawShadowState.Called=$true
                return $fixedForgedSelfConsistentRaw
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-SealedHeldCapabilityPreflight -Value $fixedForgedSelfConsistentRawShadow
                try {
                    Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                        [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                    ) | Out-Null
                    $fixedExactIssuerRedFailures.Add('self-consistent public-factory raw evidence was accepted')
                }
                catch {
                    if($_.Exception.Message -cne 'fixed-infrastructure-capability-evidence-invalid'){$fixedExactIssuerRedFailures.Add("raw evidence bypass returned unexpected token: $($_.Exception.Message)")}
                }
            }
            finally { Set-Item -LiteralPath Function:\Invoke-SealedHeldCapabilityPreflight -Value $fixedOriginalRawPreflight }

            $fixedFakeProbeShadowState=[pscustomobject]@{Calls=0L}
            $fixedFakeProbeShadow={
                param([Parameter(Mandatory)][string]$ProbeRoot,[Parameter(Mandatory)]$VolumeInfo,[Parameter(Mandatory)][string]$ExpectedProbeRootIdentity)
                $fixedFakeProbeShadowState.Calls++
                return '0' * 64
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $fixedFakeProbeShadow
                try {
                    Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                        [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                    ) | Out-Null
                    $fixedExactIssuerRedFailures.Add('shadowed lower probe arbitrary hash was accepted')
                }
                catch {
                    if($_.Exception.Message -cne 'fixed-infrastructure-capability-evidence-invalid'){$fixedExactIssuerRedFailures.Add("lower probe bypass returned unexpected token: $($_.Exception.Message)")}
                }
            }
            finally { Set-Item -LiteralPath Function:\Invoke-TargetFilesystemCapabilityProbe -Value $fixedOriginalCapabilityProbe }
            if($fixedExactIssuerRedFailures.Count -gt 0){
                throw "FAIL: fixed exact issuer bypass RED: $($fixedExactIssuerRedFailures -join '; '); rawShadowCalled=$($fixedForgedRawShadowState.Called); fakeProbeCalls=$($fixedFakeProbeShadowState.Calls); primaryEntries=$(@([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count); alternateEntries=$(@([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count)"
            }
            Assert-TestCondition (-not [bool]$fixedForgedRawShadowState.Called -and [long]$fixedFakeProbeShadowState.Calls -eq 0L -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'fixed capture rejects raw/probe command shadows before invocation and leaves both probe roots untouched'

            foreach($mutationKind in @('AuthorityHash','RowCount','TargetStatus','TargetPath','ProbeIdentity','VolumeSerial','FilesystemType','ExpectedSemantics')){
                $fixedMutatedRawEvidence=& $newFixedRawMutation $fixedBaselineRaw $mutationKind
                Assert-ThrowsPattern { Assert-SealedFixedInfrastructureCapabilityEvidenceExact -Evidence $fixedMutatedRawEvidence @fixedEvidenceValidationArguments | Out-Null } '^fixed-infrastructure-capability-evidence-invalid$' "the fixed evidence validator rejects genuine, self-consistent lower evidence with $mutationKind drift"
            }

            $fixedForeignSlot=Join-Path $capabilityProbeRoot '.target-capability-fixed-foreign-owned-by-test'
            $fixedForeignFile=Join-Path $fixedForeignSlot 'foreign.bin'
            $fixedForeignBytes=[Text.Encoding]::UTF8.GetBytes('fixed foreign residue')
            try {
                [IO.Directory]::CreateDirectory($fixedForeignSlot) | Out-Null
                [IO.File]::WriteAllBytes($fixedForeignFile,$fixedForeignBytes)
                Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                    [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                ) | Out-Null } '^capability-probe-root-residue$' 'fixed capture propagates lower-level foreign residue failure without trusting a probe shadow'
                Assert-TestCondition ((Test-Path -LiteralPath $fixedForeignFile -PathType Leaf) -and
                    [Convert]::ToHexString([IO.File]::ReadAllBytes($fixedForeignFile)) -ceq [Convert]::ToHexString($fixedForeignBytes)) 'fixed capture deletes only lower-level owned GUID slots and preserves foreign matching residue'
            }
            finally {
                if(Test-Path -LiteralPath $fixedForeignSlot){[IO.Directory]::Delete($fixedForeignSlot,$true)}
            }

            $fixedCanonicalBindingOriginal=(Get-Command Assert-HomeAuthorityCanonicalGlobalLockBinding -CommandType Function -ErrorAction Stop).ScriptBlock
            $fixedCanonicalWitnessHash=[string]$capabilityGlobal.CanonicalWitnessHash
            $fixedCanonicalBindingState=[pscustomobject]@{Calls=0L;Mutated=$false}
            $fixedCanonicalBindingShadow={
                param($AuthorityContext,$GlobalLockHandle,$CanonicalWitness)
                $fixedCanonicalBindingState.Calls++
                if([long]$fixedCanonicalBindingState.Calls -eq 3L){
                    $GlobalLockHandle.CanonicalWitnessHash=('0' * 64)
                    $fixedCanonicalBindingState.Mutated=$true
                }
                & $fixedCanonicalBindingOriginal -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Assert-HomeAuthorityCanonicalGlobalLockBinding -Value $fixedCanonicalBindingShadow
                Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                    [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                ) | Out-Null } '^fixed-infrastructure-capability-lock-drift$' 'final canonical/global binding validation fails closed after exact real probes when the binding display drifts'
            }
            finally {
                $capabilityGlobal.CanonicalWitnessHash=$fixedCanonicalWitnessHash
                Set-Item -LiteralPath Function:\Assert-HomeAuthorityCanonicalGlobalLockBinding -Value $fixedCanonicalBindingOriginal
            }
            Assert-TestCondition ([long]$fixedCanonicalBindingState.Calls -eq 3L -and [bool]$fixedCanonicalBindingState.Mutated -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'final canonical-binding drift is injected only after entry and exact raw binding checks and leaves no owned probe residue'

            $targetSelectFirstLease=Open-SealedHeldTargetContextLease -Path ([string]$capabilityFixture.Context.ControlBase) |
                Select-Object -First 1
            $targetSelectFirstReceipt=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($targetSelectFirstLease)
            $targetSelectFirstHandles=@([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($targetSelectFirstReceipt))
            try {
                Assert-TestCondition ([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($targetSelectFirstReceipt) -and
                    $targetSelectFirstHandles.Count -gt 0 -and
                    @($targetSelectFirstHandles | Where-Object {-not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0) 'Select-Object -First 1 receives an OPEN target lease after its ownership transfer point'
            }
            finally { $null=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($targetSelectFirstLease) }
            Assert-TestCondition ([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($targetSelectFirstReceipt) -and
                @($targetSelectFirstHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0) 'explicit target close releases every handle received through Select-Object -First 1'

            $liveSelectFirstLease=Open-SealedHeldLiveTargetContextSet -AuthorityContext $capabilityFixture.Context `
                -CanonicalWitness $capabilityWitness -GlobalLockHandle $capabilityGlobal | Select-Object -First 1
            $liveSelectFirstReceipt=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($liveSelectFirstLease)
            $liveSelectFirstTargetLeases=@([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($liveSelectFirstReceipt))
            $liveSelectFirstTargetReceipts=@($liveSelectFirstTargetLeases | ForEach-Object {
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($_)
            })
            try {
                Assert-TestCondition ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsOpenExact($liveSelectFirstReceipt) -and
                    $liveSelectFirstTargetReceipts.Count -eq 3 -and
                    @($liveSelectFirstTargetReceipts | Where-Object {-not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($_)}).Count -eq 0) 'Select-Object -First 1 receives an OPEN live-set lease with three OPEN nested receipts'
            }
            finally { $null=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($liveSelectFirstLease) }
            Assert-TestCondition ([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($liveSelectFirstReceipt) -and
                @($liveSelectFirstTargetReceipts | Where-Object {-not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($_)}).Count -eq 0) 'explicit live-set close releases every nested lease received through Select-Object -First 1'

            $liveStopAssertOriginal=(Get-Command Assert-SealedHeldLiveTargetContextSet -CommandType Function -ErrorAction Stop).ScriptBlock
            $liveStopState=[pscustomobject]@{Calls=0L;Lease=$null}
            $liveStoppingAssert={
                param($Lease)
                $liveStopState.Calls++
                $liveStopState.Lease=$Lease
                throw [System.Management.Automation.PipelineStoppedException]::new()
            }.GetNewClosure()
            $liveStopArguments=[object[]]@($capabilityFixture.Context,$capabilityWitness,$capabilityGlobal)
            $liveStopInvoker={
                param($AuthorityContext,$CanonicalWitness,$GlobalLockHandle)
                Open-SealedHeldLiveTargetContextSet -AuthorityContext $AuthorityContext `
                    -CanonicalWitness $CanonicalWitness -GlobalLockHandle $GlobalLockHandle
            }
            try {
                Set-Item -LiteralPath Function:\Assert-SealedHeldLiveTargetContextSet -Value $liveStoppingAssert
                $liveStopOutcome=[AiAgentDotfiles.ReceiptReleaseProbe]::InvokeExpectPipelineStopped(
                    $liveStopInvoker,$liveStopArguments)
            }
            finally { Set-Item -LiteralPath Function:\Assert-SealedHeldLiveTargetContextSet -Value $liveStopAssertOriginal }
            $liveStoppedReceipt=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($liveStopState.Lease)
            $liveStoppedTargetLeases=@([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($liveStoppedReceipt))
            $liveStoppedTargetReceipts=@($liveStoppedTargetLeases | ForEach-Object {
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($_)
            })
            $liveStoppedHandles=@($liveStoppedTargetReceipts | ForEach-Object {
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($_)
            })
            Assert-TestCondition ($liveStopOutcome -ceq 'pipeline-stopped' -and [long]$liveStopState.Calls -eq 1L -and
                [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($liveStoppedReceipt) -and
                $liveStoppedTargetReceipts.Count -eq 3 -and
                @($liveStoppedTargetReceipts | Where-Object {-not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($_)}).Count -eq 0 -and
                $liveStoppedHandles.Count -gt 0 -and
                @($liveStoppedHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                [AiAgentDotfiles.SafeLockFileHandle]::IsOpenExact($capabilityGlobal.HeldLock)) 'live-set finally closes its bound receipt, three nested receipts, and every handle when PipelineStoppedException skips catch before transfer'

            $observationBindings=@(
                [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot}
            )
            $pinnedRouteOpenCommand=Get-Command Open-SealedRegistryCurrentRouteCapture -CommandType Function -ErrorAction Stop
            $pinnedRouteOpenRunspace=[Management.Automation.Runspaces.Runspace]::DefaultRunspace
            $routeDefinitionsField=[AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer].GetField(
                'Definitions',([Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static))
            $routeDefinitions=$routeDefinitionsField.GetValue($null)
            $routeDefinitionArguments=[object[]]@($pinnedRouteOpenRunspace,$null)
            $routeDefinitionFound=$routeDefinitions.GetType().GetMethod('TryGetValue').Invoke(
                $routeDefinitions,$routeDefinitionArguments)
            $routeDefinition=$routeDefinitionArguments[1]
            Assert-TestCondition ([bool]$routeDefinitionFound -and $null -ne $routeDefinition) 'the route issuer retains one exact definition for its owner runspace'
            $routeDefinitionType=$routeDefinition.GetType()
            $pinnedRouteLiveOpen=$routeDefinitionType.GetField('OpenLiveSet',
                [Reflection.BindingFlags]'NonPublic,Instance').GetValue($routeDefinition)
            $pinnedRouteTargetOpen=$routeDefinitionType.GetField('OpenTarget',
                [Reflection.BindingFlags]'NonPublic,Instance').GetValue($routeDefinition)
            [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::InitializeExact(
                $pinnedRouteOpenCommand.ScriptBlock,$pinnedRouteLiveOpen,$pinnedRouteTargetOpen,
                $pinnedRouteOpenRunspace.InstanceId.ToString('D').ToLowerInvariant())
            $sameTextRouteOpen=[scriptblock]::Create($pinnedRouteOpenCommand.ScriptBlock.Ast.Extent.Text)
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::InitializeExact(
                    $sameTextRouteOpen,$pinnedRouteLiveOpen,$pinnedRouteTargetOpen,
                    $pinnedRouteOpenRunspace.InstanceId.ToString('D').ToLowerInvariant())
            } 'route-witness-required' 'the route issuer rejects a same-text ScriptBlock substitution in its pinned caller definition'
            [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::InitializeExact(
                $pinnedRouteOpenCommand.ScriptBlock,$pinnedRouteLiveOpen,$pinnedRouteTargetOpen,
                $pinnedRouteOpenRunspace.InstanceId.ToString('D').ToLowerInvariant())
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::BeginOpenExact() | Out-Null
            } 'route-witness-required' 'the route issuer rejects Begin outside the exact pinned Open caller'
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::OpenLiveSetExact(
                    $null,$null,$null,[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()) | Out-Null
            } 'route-witness-required' 'the route issuer rejects live-set acquisition outside the exact pinned Open caller'
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::OpenTargetExact(
                    '',[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()) | Out-Null
            } 'route-witness-required' 'the route issuer rejects target acquisition outside the exact pinned Open caller'
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::ClaimResourceSetExact(
                    [object]::new(),[object[]]@([object]::new())) | Out-Null
            } 'route-witness-required' 'the route issuer rejects resource claims outside the exact pinned Open caller'
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::AbandonOpenExact([object]::new()) | Out-Null
            } 'route-witness-required' 'the route issuer rejects operation abandonment outside the exact pinned Open caller'
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::IssueExact(
                    [object]::new(),[object]::new(),[object[]]@(),[object]::new(),
                    [AiAgentDotfiles.SealedRegistryRouteLeaseBinding[]]@(),[object[]]@(),[object[]]@(),
                    [object]::new(),[object]::new(),[object]::new(),('0' * 64),('0' * 64),('0' * 64)) | Out-Null
            } 'route-witness-required' 'the route issuer rejects capture issuance outside the exact pinned Open caller'
            $routeDefinitionFieldFlags=[Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Instance
            $routeLiveOpenField=$routeDefinitionType.GetField('OpenLiveSet',$routeDefinitionFieldFlags)
            $routeTargetOpenField=$routeDefinitionType.GetField('OpenTarget',$routeDefinitionFieldFlags)
            $routeStopState=[pscustomobject]@{
                LiveSet=$null
                LiveSetReceipt=$null
                LiveTargetLeases=[Collections.Generic.List[object]]::new()
                LiveTargetReceipts=[Collections.Generic.List[object]]::new()
                TargetLeases=[Collections.Generic.List[object]]::new()
                TargetReceipts=[Collections.Generic.List[object]]::new()
                TargetCalls=0L
                ReservationsBeforeStop=$false
            }
            $routeStoppingLiveOpen={
                param($AuthorityContext,$CanonicalWitness,$GlobalLockHandle,$OwnershipReceiver)
                & $pinnedRouteLiveOpen $AuthorityContext $CanonicalWitness $GlobalLockHandle $OwnershipReceiver
                $lease=$OwnershipReceiver.GetDeliveredExact()
                $receipt=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($lease)
                $routeStopState.LiveSet=$lease
                $routeStopState.LiveSetReceipt=$receipt
                foreach($targetLease in @([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($receipt))){
                    $routeStopState.LiveTargetLeases.Add($targetLease)
                    $routeStopState.LiveTargetReceipts.Add(
                        [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($targetLease))
                }
            }.GetNewClosure()
            $routeStoppingTargetOpen={
                param([string]$Path,$OwnershipReceiver)
                $routeStopState.TargetCalls++
                if([long]$routeStopState.TargetCalls -eq 2L){
                    $registeredResources=@($routeStopState.LiveSet)+
                        @($routeStopState.LiveTargetLeases)+@($routeStopState.TargetLeases)
                    $routeStopState.ReservationsBeforeStop=@($registeredResources | Where-Object {
                        -not [AiAgentDotfiles.ReceiptReleaseProbe]::HasExactRouteResourceReservation($_)
                    }).Count -eq 0
                    throw [System.Management.Automation.PipelineStoppedException]::new()
                }
                & $pinnedRouteTargetOpen $Path $OwnershipReceiver
                $lease=$OwnershipReceiver.GetDeliveredExact()
                $routeStopState.TargetLeases.Add($lease)
                $routeStopState.TargetReceipts.Add(
                    [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($lease))
            }.GetNewClosure()
            $routeStopRootSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
            $routeStopArguments=[object[]]::new(5)
            $routeStopArguments[0]=$capabilityFixture.Context
            $routeStopArguments[1]=$capabilityGlobal
            $routeStopArguments[2]=$capabilityWitness
            $routeStopArguments[3]=$routeStopRootSet
            $routeStopArguments[4]=[object[]]@()
            $routeStopInvoker={
                param($AuthorityContext,$GlobalLockHandle,$CanonicalWitness,$CurrentRouteRootSet,[object[]]$Reservations)
                Open-SealedRegistryCurrentRouteCapture -AuthorityContext $AuthorityContext `
                    -GlobalLockHandle $GlobalLockHandle -CanonicalWitness $CanonicalWitness `
                    -CurrentRouteRootSet $CurrentRouteRootSet -Reservations $Reservations `
                    -OwnershipReceiver ([AiAgentDotfiles.SealedOwnershipTransferReceiver]::new())
            }
            try {
                $routeLiveOpenField.SetValue($routeDefinition,$routeStoppingLiveOpen)
                $routeTargetOpenField.SetValue($routeDefinition,$routeStoppingTargetOpen)
                $routeStopOutcome=[AiAgentDotfiles.ReceiptReleaseProbe]::InvokeExpectPipelineStopped(
                    $routeStopInvoker,$routeStopArguments)
            }
            finally {
                $routeLiveOpenField.SetValue($routeDefinition,$pinnedRouteLiveOpen)
                $routeTargetOpenField.SetValue($routeDefinition,$pinnedRouteTargetOpen)
            }
            $routeStopResources=@($routeStopState.LiveSet)+@($routeStopState.LiveTargetLeases)+@($routeStopState.TargetLeases)
            $routeStopReceipts=@($routeStopState.LiveTargetReceipts)+@($routeStopState.TargetReceipts)
            $routeStopHandles=@($routeStopReceipts | ForEach-Object {
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($_)
            })
            Assert-TestCondition ($routeStopOutcome -ceq 'pipeline-stopped' -and
                $null -ne $routeStopState.LiveSetReceipt -and [long]$routeStopState.TargetCalls -eq 2L -and
                $routeStopState.TargetLeases.Count -eq 1 -and
                [bool]$routeStopState.ReservationsBeforeStop -and
                [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($routeStopState.LiveSetReceipt) -and
                $routeStopReceipts.Count -eq 4 -and
                @($routeStopReceipts | Where-Object {
                    -not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($_)
                }).Count -eq 0 -and
                $routeStopHandles.Count -gt 0 -and
                @($routeStopHandles | Where-Object {
                    [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)
                }).Count -eq 0 -and
                @($routeStopResources | Where-Object {
                    [AiAgentDotfiles.ReceiptReleaseProbe]::HasExactRouteResourceReservation($_)
                }).Count -eq 0) 'route Open finally releases every registered pre-transfer resource and reservation when PipelineStoppedException skips catch'

            $routePendingLiveState=[pscustomobject]@{LiveSet=$null}
            $routePendingLiveProvider={
                param($AuthorityContext,$CanonicalWitness,$GlobalLockHandle,$OwnershipReceiver)
                & $pinnedRouteLiveOpen $AuthorityContext $CanonicalWitness $GlobalLockHandle $OwnershipReceiver
                $routePendingLiveState.LiveSet=$OwnershipReceiver.GetDeliveredExact()
                throw [System.Management.Automation.PipelineStoppedException]::new()
            }.GetNewClosure()
            try {
                $routeLiveOpenField.SetValue($routeDefinition,$routePendingLiveProvider)
                $routePendingLiveArguments=[object[]]@(
                    $capabilityFixture.Context,$capabilityGlobal,$capabilityWitness,
                    (New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness),[object[]]@())
                $routePendingLiveOutcome=[AiAgentDotfiles.ReceiptReleaseProbe]::InvokeExpectPipelineStopped(
                    $routeStopInvoker,$routePendingLiveArguments)
            }
            finally { $routeLiveOpenField.SetValue($routeDefinition,$pinnedRouteLiveOpen) }
            $routePendingLiveReceipt=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact(
                $routePendingLiveState.LiveSet)
            $routePendingLiveTargetReceipts=@(
                [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact($routePendingLiveReceipt) |
                    ForEach-Object {[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($_)}
            )
            $routePendingLiveHandles=@($routePendingLiveTargetReceipts | ForEach-Object {
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact($_)
            })
            Assert-TestCondition ($routePendingLiveOutcome -ceq 'pipeline-stopped' -and
                [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsClosedExact($routePendingLiveReceipt) -and
                $routePendingLiveTargetReceipts.Count -eq 3 -and
                @($routePendingLiveTargetReceipts | Where-Object {-not [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($_)}).Count -eq 0 -and
                $routePendingLiveHandles.Count -gt 0 -and
                @($routePendingLiveHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                -not [AiAgentDotfiles.ReceiptReleaseProbe]::HasExactRouteResourceReservation($routePendingLiveState.LiveSet)) 'route finally closes a live-set delivered into its receiver when the provider stops before route ledger registration'

            $routePendingTargetState=[pscustomobject]@{Lease=$null}
            $routePendingTargetProvider={
                param([string]$Path,$OwnershipReceiver)
                & $pinnedRouteTargetOpen $Path $OwnershipReceiver
                $routePendingTargetState.Lease=$OwnershipReceiver.GetDeliveredExact()
                throw [System.Management.Automation.PipelineStoppedException]::new()
            }.GetNewClosure()
            try {
                $routeTargetOpenField.SetValue($routeDefinition,$routePendingTargetProvider)
                $routePendingTargetArguments=[object[]]@(
                    $capabilityFixture.Context,$capabilityGlobal,$capabilityWitness,
                    (New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness),[object[]]@())
                $routePendingTargetOutcome=[AiAgentDotfiles.ReceiptReleaseProbe]::InvokeExpectPipelineStopped(
                    $routeStopInvoker,$routePendingTargetArguments)
            }
            finally { $routeTargetOpenField.SetValue($routeDefinition,$pinnedRouteTargetOpen) }
            $routePendingTargetReceipt=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact(
                $routePendingTargetState.Lease)
            $routePendingTargetHandles=@([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetHandlesExact(
                $routePendingTargetReceipt))
            Assert-TestCondition ($routePendingTargetOutcome -ceq 'pipeline-stopped' -and
                [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsClosedExact($routePendingTargetReceipt) -and
                $routePendingTargetHandles.Count -gt 0 -and
                @($routePendingTargetHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                -not [AiAgentDotfiles.ReceiptReleaseProbe]::HasExactRouteResourceReservation($routePendingTargetState.Lease)) 'route finally closes a target delivered into its receiver when the provider stops before route ledger registration'

            $routeSelectFirstRootSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
            $routeSelectFirstReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
            $routeSelectFirstOutput=@(Open-SealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context `
                -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness `
                -CurrentRouteRootSet $routeSelectFirstRootSet -Reservations @() `
                -OwnershipReceiver $routeSelectFirstReceiver | Select-Object -First 1)
            $routeSelectFirstCapture=$routeSelectFirstReceiver.GetDeliveredExact()
            try {
                Assert-TestCondition ($routeSelectFirstOutput.Count -eq 0 -and
                    [string]$routeSelectFirstReceiver.GetStateExact() -ceq 'DELIVERED' -and
                    $routeSelectFirstCapture -is [AiAgentDotfiles.SealedRegistryCurrentRouteCapture] -and
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($routeSelectFirstCapture) -and
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::HasExactIssuanceReceipt($routeSelectFirstCapture) -and
                    ((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $routeSelectFirstCapture) -ne $false)) 'route Open emits no owned resource while its pre-held receiver retains the issued OPEN route'
            }
            finally {
                if($null -ne $routeSelectFirstCapture -and
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($routeSelectFirstCapture)){
                    $null=Close-SealedRegistryCurrentRouteCapture -Capture $routeSelectFirstCapture
                }
            }
            Assert-TestCondition ([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsClosed($routeSelectFirstCapture)) 'explicit route close releases the route retained by its ownership receiver'
            $observationTreeBefore=Get-TestRegistryTreeHash -Fixture $capabilityFixture
            $observationRouteSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
            $observationRoute=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $observationRouteSet -Reservations @()
            $originalLiveSetOpen=(Get-Command Open-SealedHeldLiveTargetContextSet -CommandType Function -ErrorAction Stop).ScriptBlock
            $originalTargetOpen=(Get-Command Open-SealedHeldTargetContextLease -CommandType Function -ErrorAction Stop).ScriptBlock
            $standaloneVictimLiveSet=& $originalLiveSetOpen -AuthorityContext $capabilityFixture.Context -CanonicalWitness $capabilityWitness -GlobalLockHandle $capabilityGlobal
            $standaloneVictimTarget=& $originalTargetOpen -Path $capabilityProbeRoot
            $standaloneVictimLiveReceipt=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact($standaloneVictimLiveSet)
            $standaloneVictimTargetReceipt=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetForWrapperExact($standaloneVictimTarget)
            $routeOpenShadowState=[pscustomobject]@{LiveCalls=0L;TargetCalls=0L}
            $borrowedLiveSetOpen={
                param($AuthorityContext,$CanonicalWitness,$GlobalLockHandle)
                $routeOpenShadowState.LiveCalls++
                return $standaloneVictimLiveSet
            }.GetNewClosure()
            $borrowedTargetOpen={
                param([string]$Path)
                $routeOpenShadowState.TargetCalls++
                return $standaloneVictimTarget
            }.GetNewClosure()
            $providerIsolationRoute=$null
            try {
                Set-Item -LiteralPath 'Function:Open-SealedHeldLiveTargetContextSet' -Value $borrowedLiveSetOpen
                Set-Item -LiteralPath 'Function:Open-SealedHeldTargetContextLease' -Value $borrowedTargetOpen
                $providerIsolationRoute=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $observationRouteSet -Reservations @()
                Assert-TestCondition ((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $providerIsolationRoute) -ne $false) 'route acquisition succeeds through its pinned live-set and target providers while ambient names are poisoned'
                $null=Close-SealedRegistryCurrentRouteCapture -Capture $providerIsolationRoute
                Assert-TestCondition ([long]$routeOpenShadowState.LiveCalls -eq 0L -and
                    [long]$routeOpenShadowState.TargetCalls -eq 0L -and
                    [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsOpenExact($standaloneVictimLiveReceipt) -and
                    [AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($standaloneVictimTargetReceipt)) 'route close releases only pinned-acquisition resources and leaves independent genuine provider victims OPEN'
            }
            finally {
                Set-Item -LiteralPath 'Function:Open-SealedHeldLiveTargetContextSet' -Value $originalLiveSetOpen
                Set-Item -LiteralPath 'Function:Open-SealedHeldTargetContextLease' -Value $originalTargetOpen
                if($null -ne $providerIsolationRoute -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($providerIsolationRoute)){
                    $null=Close-SealedRegistryCurrentRouteCapture -Capture $providerIsolationRoute
                }
                if([AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::GetIsOpenExact($standaloneVictimTargetReceipt)){
                    $null=[AiAgentDotfiles.SealedHeldTargetContextLeaseReceipt]::ReleaseForWrapperExact($standaloneVictimTarget)
                }
                if([AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetIsOpenExact($standaloneVictimLiveReceipt)){
                    $null=[AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::ReleaseForWrapperExact($standaloneVictimLiveSet)
                }
            }
            Assert-TestCondition ((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $observationRoute) -ne $false -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::HasExactIssuanceReceipt($observationRoute)) 'provider isolation neither closes nor invalidates the original route capture'
            $observation=$null
            $observationTestPrimaryError=$null
            try {
                $syntheticObservationRoute=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::new(
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveProjection($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetRouteLeaseRows($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetReservationLeases($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetFixedLeases($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetOriginalCurrentRouteRootSet($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCanonicalWitness($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCurrentRouteRootSetSnapshot($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetEntryCurrentRouteRootSetHash($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCurrentRouteRootSetSnapshotHash($observationRoute),
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetHeldTargetSetHash($observationRoute))
            Assert-ThrowsPattern { Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $syntheticObservationRoute -CapabilityProbeBindings $observationBindings | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'a public-constructor route clone cannot mint a runtime observation from borrowed genuine resources'
            Assert-ThrowsPattern { Assert-SealedRegistryCurrentRouteCaptureStable -Capture $syntheticObservationRoute | Out-Null } 'route-witness-required' 'a public-constructor route clone cannot pass the direct stable-capture API without an exact issuance receipt'
            Assert-ThrowsPattern { Close-SealedRegistryCurrentRouteCapture -Capture $syntheticObservationRoute | Out-Null } 'route-witness-required' 'a public-constructor route clone cannot release resources owned by the genuine route receipt'
            $observationOriginalExceptionTranslator=(Get-Command Throw-SealedFixedInfrastructureCapabilityIssuerException -CommandType Function -ErrorAction Stop).ScriptBlock
            $observationExceptionTranslatorShadowState=[pscustomobject]@{Calls=0L}
            $observationExceptionTranslatorShadow={
                param($Exception)
                $observationExceptionTranslatorShadowState.Calls++
                return $true
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Throw-SealedFixedInfrastructureCapabilityIssuerException -Value $observationExceptionTranslatorShadow
                Assert-ThrowsPattern {
                    Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $syntheticObservationRoute -CapabilityProbeBindings @() | Out-Null
                } '^held-current-route-fixed-infrastructure-observation-stale$' 'observation Open does not dynamically dispatch its public exception translator'
                Assert-ThrowsPattern {
                    Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $null | Out-Null
                } '^held-current-route-fixed-infrastructure-observation-stale$' 'observation Assert does not dynamically dispatch its public exception translator'
                Assert-ThrowsPattern {
                    Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $null | Out-Null
                } '^held-current-route-fixed-infrastructure-observation-stale$' 'observation Close does not dynamically dispatch its public exception translator'
            }
            finally {
                Set-Item -LiteralPath Function:\Throw-SealedFixedInfrastructureCapabilityIssuerException -Value $observationOriginalExceptionTranslator
            }
            Assert-TestCondition ([long]$observationExceptionTranslatorShadowState.Calls -eq 0L) 'public observation lifecycle failures bypass ambient exception-translator shadows'
            $observationAliasShadowState=[pscustomobject]@{Calls=0L}
            $observationAliasTrap={
                $observationAliasShadowState.Calls++
                throw 'observation-alias-trap-called'
            }.GetNewClosure()
            try {
                Set-Item -LiteralPath Function:\Invoke-ObservationAliasTrap -Value $observationAliasTrap
                Set-Alias -Name Assert-SealedHomeAuthorityGlobalLockWitness -Value Invoke-ObservationAliasTrap -Scope Global
                Assert-ThrowsPattern {
                    Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationRoute -CapabilityProbeBindings $observationBindings | Out-Null
                } '^held-current-route-fixed-infrastructure-observation-stale$' 'observation Open fails closed before an alias can override a pinned fixed-envelope provider'
            }
            finally {
                Remove-Item -LiteralPath Alias:\Assert-SealedHomeAuthorityGlobalLockWitness -ErrorAction SilentlyContinue
                Remove-Item -LiteralPath Function:\Invoke-ObservationAliasTrap -ErrorAction SilentlyContinue
            }
            Assert-TestCondition ([long]$observationAliasShadowState.Calls -eq 0L -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationRoute) -and
                (Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $observationTreeBefore -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'alias rejection closes the owned outer envelope without invoking the alias or disturbing borrowed state'
            Assert-ThrowsPattern {
                [AiAgentDotfiles.SealedRegistryCurrentRouteCaptureIssuer]::IssueExact(
                    [object]::new(),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($observationRoute),
                    [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetTargetLeasesExact(
                        [AiAgentDotfiles.SealedHeldLiveTargetContextSetReceipt]::GetForWrapperExact(
                            [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveSetLease($observationRoute))),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetLiveProjection($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetRouteLeaseRows($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetReservationLeases($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetFixedLeases($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetOriginalCurrentRouteRootSet($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCanonicalWitness($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCurrentRouteRootSetSnapshot($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetEntryCurrentRouteRootSetHash($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetCurrentRouteRootSetSnapshotHash($observationRoute),
                    [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetHeldTargetSetHash($observationRoute)) | Out-Null
            } 'route-witness-required' 'the public raw route issuer rejects an alternate reservation key paired with stolen genuine lease arrays outside the pinned Open caller'
            Assert-TestCondition ((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $observationRoute) -ne $false -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::HasExactIssuanceReceipt($observationRoute) -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'rejecting constructor and issuer route clones does not probe or disturb the genuine caller-owned route'
            $observationOpenFailureTreeBefore=Get-TestRegistryTreeHash -Fixture $capabilityFixture
            Assert-ThrowsPattern {
                Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationRoute -CapabilityProbeBindings @(
                    [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=('0' * 64)}
                    [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                ) | Out-Null
            } '^capability-evidence-mismatch$' 'observation Open preserves the fixed-capture primary failure after acquiring its owned envelope'
            Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $observationOpenFailureTreeBefore -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationRoute) -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'failed observation Open releases its owned envelope without closing the borrowed route or leaving probe residue'

            $observationIssuerType=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]
            $observationDefinitionsField=$observationIssuerType.GetField('Definitions',
                ([Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Static))
            $observationDefinitions=$observationDefinitionsField.GetValue($null)
            $observationOwnerRunspaceId=[Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString('D').ToLowerInvariant()
            $observationDefinition=$observationDefinitions[$observationOwnerRunspaceId]
            $observationDefinitionFieldFlags=[Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Instance
            $observationFixedCaptureField=$observationDefinition.GetType().GetField(
                'FixedCapture',$observationDefinitionFieldFlags)
            $observationOriginalFixedCapture=$observationFixedCaptureField.GetValue($observationDefinition)
            $observationStopState=[pscustomobject]@{Calls=0L;EnvelopeLease=$null}
            $observationStoppingFixedCapture={
                $observationStopState.Calls++
                $observationStopState.EnvelopeLease=$args[4]
                throw [System.Management.Automation.PipelineStoppedException]::new()
            }.GetNewClosure()
            $observationStopArguments=[object[]]::new(2)
            $observationStopArguments[0]=$observationRoute
            $observationStopArguments[1]=[object[]]@($observationBindings)
            $observationStopInvoker={
                param($CurrentRouteCapture,[object[]]$CapabilityProbeBindings)
                Open-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
                    -CurrentRouteCapture $CurrentRouteCapture `
                    -CapabilityProbeBindings $CapabilityProbeBindings `
                    -OwnershipReceiver ([AiAgentDotfiles.SealedOwnershipTransferReceiver]::new())
            }
            try {
                $observationFixedCaptureField.SetValue($observationDefinition,$observationStoppingFixedCapture)
                $observationStopOutcome=[AiAgentDotfiles.ReceiptReleaseProbe]::InvokeExpectPipelineStopped(
                    $observationStopInvoker,$observationStopArguments)
            }
            finally {
                $observationFixedCaptureField.SetValue($observationDefinition,$observationOriginalFixedCapture)
            }
            $observationStopDirectoryLeases=@(if($null -ne $observationStopState.EnvelopeLease){
                @($observationStopState.EnvelopeLease.DirectoryLeases)
            })
            $observationStopOpenHandles=@(
                foreach($directoryLease in $observationStopDirectoryLeases){
                    foreach($handle in @($directoryLease.Handles)){
                        if([AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($handle)){$handle}
                    }
                }
            )
            Assert-TestCondition ($observationStopOutcome -ceq 'pipeline-stopped' -and
                [long]$observationStopState.Calls -eq 1L -and
                $null -ne $observationStopState.EnvelopeLease -and
                $observationStopDirectoryLeases.Count -eq 6 -and
                $observationStopOpenHandles.Count -eq 0 -and
                -not [AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard]::IsReservedExact($observationStopState.EnvelopeLease) -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationRoute) -and
                (Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $observationOpenFailureTreeBefore -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'observation Open finally clears its pre-issue envelope reservation and handles when PipelineStoppedException skips catch'
            $observationRouteStableField=$observationDefinition.GetType().GetField(
                'RouteCaptureStable',$observationDefinitionFieldFlags)
            $observationOriginalRouteStable=$observationRouteStableField.GetValue($observationDefinition)
            $observationPostIssueStopState=[pscustomobject]@{RouteCalls=0L;EnvelopeLease=$null}
            $observationPostIssueFixedCapture={
                $observationPostIssueStopState.EnvelopeLease=$args[4]
                & $observationOriginalFixedCapture @args
            }.GetNewClosure()
            $observationPostIssueRouteStable={
                param($Capture)
                $observationPostIssueStopState.RouteCalls++
                if([long]$observationPostIssueStopState.RouteCalls -eq 9L){
                    throw [System.Management.Automation.PipelineStoppedException]::new()
                }
                & $observationOriginalRouteStable -Capture $Capture
            }.GetNewClosure()
            try {
                $observationFixedCaptureField.SetValue($observationDefinition,$observationPostIssueFixedCapture)
                $observationRouteStableField.SetValue($observationDefinition,$observationPostIssueRouteStable)
                $observationPostIssueStopOutcome=[AiAgentDotfiles.ReceiptReleaseProbe]::InvokeExpectPipelineStopped(
                    $observationStopInvoker,$observationStopArguments)
            }
            finally {
                $observationFixedCaptureField.SetValue($observationDefinition,$observationOriginalFixedCapture)
                $observationRouteStableField.SetValue($observationDefinition,$observationOriginalRouteStable)
            }
            $observationPostIssueDirectoryLeases=@($observationPostIssueStopState.EnvelopeLease.DirectoryLeases)
            $observationPostIssueHandles=@($observationPostIssueDirectoryLeases | ForEach-Object {@($_.Handles)})
            Assert-TestCondition ($observationPostIssueStopOutcome -ceq 'pipeline-stopped' -and
                [long]$observationPostIssueStopState.RouteCalls -eq 9L -and
                $null -ne $observationPostIssueStopState.EnvelopeLease -and
                $observationPostIssueDirectoryLeases.Count -eq 6 -and
                $observationPostIssueHandles.Count -gt 0 -and
                @($observationPostIssueHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                -not [AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard]::IsReservedExact($observationPostIssueStopState.EnvelopeLease) -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationRoute)) 'observation Open closes its issued pre-transfer observation, frozen handles, and envelope reservation when validation is stopped'
            $observationCloseField=$observationDefinition.GetType().GetField('FixedDirectoryClose',
                $observationDefinitionFieldFlags)
            $observationOriginalPinnedEnvelopeClose=$observationCloseField.GetValue($observationDefinition)
            $observationOpenCleanupState=[pscustomobject]@{
                Calls=0L
                HandleChains=[Collections.Generic.List[object[]]]::new()
            }
            $observationInjectedPinnedEnvelopeClose={
                param($Handles)
                $observationOpenCleanupState.Calls++
                $observationOpenCleanupState.HandleChains.Add([object[]]@($Handles))
                throw 'injected-observation-open-cleanup-error'
            }.GetNewClosure()
            $observationPrimaryAndCleanupError=$null
            try {
                $observationCloseField.SetValue($observationDefinition,$observationInjectedPinnedEnvelopeClose)
                Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationRoute -CapabilityProbeBindings @(
                    [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot;ExpectedFilesystemCapabilityHash=('0' * 64)}
                    [ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
                ) | Out-Null
                throw 'FAIL: observation Open preserves primary and records owned-envelope cleanup failure (did not throw)'
            }
            catch {
                if($_.Exception.Message -like 'FAIL:*'){throw}
                $observationPrimaryAndCleanupError=$_
            }
            finally { $observationCloseField.SetValue($observationDefinition,$observationOriginalPinnedEnvelopeClose) }
            Assert-TestCondition ($observationPrimaryAndCleanupError.Exception.Message -ceq 'capability-evidence-mismatch' -and
                [string]$observationPrimaryAndCleanupError.Exception.Data['SealedHeldCurrentRouteFixedInfrastructureObservationCleanupError'] -ceq 'injected-observation-open-cleanup-error' -and
                [long]$observationOpenCleanupState.Calls -eq 6L -and
                @($observationOpenCleanupState.HandleChains | ForEach-Object {@($_)} | Where-Object {
                    [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)
                }).Count -eq 0) 'observation Open preserves its primary exception and force-closes every frozen handle after a pre-dispose pinned cleanup failure'
            Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $observationOpenFailureTreeBefore -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationRoute) -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'primary-plus-cleanup failure closes the owned envelope and leaves borrowed route, authority tree, and probe roots stable'

            $observationPostIssueCleanupState=[pscustomobject]@{
                RouteCalls=0L
                CloseCalls=0L
                EnvelopeLease=$null
                Observation=$null
                HandleChains=[Collections.Generic.List[object[]]]::new()
            }
            $observationSourcePath=Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1'
            $observationSourceTokens=$null
            $observationSourceParseErrors=$null
            $observationSourceAst=[Management.Automation.Language.Parser]::ParseFile(
                $observationSourcePath,[ref]$observationSourceTokens,[ref]$observationSourceParseErrors)
            if($observationSourceParseErrors.Count -ne 0){throw 'post-issue observation fixture could not parse its reviewed provider'}
            $observationPostIssueBoundary=@($observationSourceAst.FindAll({
                param($node)
                $node.Extent.Text -ceq '$null=$Broker.AssertPinnedObservationExact($observation)'
            },$true))[0]
            $observationPostIssueCleanupFixedCapture={
                $observationPostIssueCleanupState.EnvelopeLease=$args[4]
                & $observationOriginalFixedCapture @args
            }.GetNewClosure()
            $observationPostIssueCleanupRouteStable={
                param($Capture)
                $observationPostIssueCleanupState.RouteCalls++
                if([long]$observationPostIssueCleanupState.RouteCalls -eq 9L){
                    throw 'injected-observation-post-issue-primary'
                }
                & $observationOriginalRouteStable -Capture $Capture
            }.GetNewClosure()
            $observationPostIssueCleanupClose={
                param($Handles)
                $observationPostIssueCleanupState.CloseCalls++
                $observationPostIssueCleanupState.HandleChains.Add([object[]]@($Handles))
                throw 'injected-observation-post-issue-cleanup-error'
            }.GetNewClosure()
            $observationPostIssuePrimaryAndCleanupError=$null
            $global:__SealedObservationPostIssueCleanupState=$observationPostIssueCleanupState
            $observationPostIssueBreakpoint=Set-PSBreakpoint -Script $observationSourcePath `
                -Line ([int]$observationPostIssueBoundary.Extent.StartLineNumber) -Action {
                    $global:__SealedObservationPostIssueCleanupState.Observation=$observation
                }
            try {
                $observationFixedCaptureField.SetValue($observationDefinition,$observationPostIssueCleanupFixedCapture)
                $observationRouteStableField.SetValue($observationDefinition,$observationPostIssueCleanupRouteStable)
                $observationCloseField.SetValue($observationDefinition,$observationPostIssueCleanupClose)
                Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation `
                    -CurrentRouteCapture $observationRoute `
                    -CapabilityProbeBindings $observationBindings | Out-Null
                throw 'FAIL: observation post-issue force-close preserves primary and records cleanup failure (did not throw)'
            }
            catch {
                if($_.Exception.Message -like 'FAIL:*'){throw}
                $observationPostIssuePrimaryAndCleanupError=$_
            }
            finally {
                Remove-PSBreakpoint -Breakpoint $observationPostIssueBreakpoint
                Remove-Variable -Name __SealedObservationPostIssueCleanupState -Scope Global -ErrorAction SilentlyContinue
                $observationFixedCaptureField.SetValue($observationDefinition,$observationOriginalFixedCapture)
                $observationRouteStableField.SetValue($observationDefinition,$observationOriginalRouteStable)
                $observationCloseField.SetValue($observationDefinition,$observationOriginalPinnedEnvelopeClose)
            }
            $observationPostIssueCleanupLeases=@(if($null -ne $observationPostIssueCleanupState.EnvelopeLease){
                @($observationPostIssueCleanupState.EnvelopeLease.DirectoryLeases)
            })
            $observationPostIssueCleanupHandles=@($observationPostIssueCleanupLeases | ForEach-Object {@($_.Handles)})
            Assert-TestCondition ($observationPostIssuePrimaryAndCleanupError.Exception.Message -ceq 'injected-observation-post-issue-primary' -and
                [string]$observationPostIssuePrimaryAndCleanupError.Exception.Data['SealedHeldCurrentRouteFixedInfrastructureObservationCleanupError'] -ceq 'injected-observation-post-issue-cleanup-error' -and
                [long]$observationPostIssueCleanupState.RouteCalls -eq 9L -and
                [long]$observationPostIssueCleanupState.CloseCalls -eq 6L -and
                $null -ne $observationPostIssueCleanupState.Observation -and
                [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCloseStateExact(
                    $observationPostIssueCleanupState.Observation) -ceq 'CLOSED' -and
                $observationPostIssueCleanupLeases.Count -eq 6 -and
                [bool]$observationPostIssueCleanupState.EnvelopeLease.IsClosed -and
                $observationPostIssueCleanupHandles.Count -gt 0 -and
                @($observationPostIssueCleanupHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                -not [AiAgentDotfiles.SealedFixedEnvelopeOwnershipGuard]::IsReservedExact($observationPostIssueCleanupState.EnvelopeLease) -and
                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationRoute)) 'post-issue observation failure force-closes every frozen handle and clears ownership even when pinned cleanup fails'

                $observation=Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationRoute -CapabilityProbeBindings $observationBindings
                Assert-TestCondition ($observation -is [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation] -and
                    [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation)) 'held current-route fixed-infrastructure observation is a genuine OPEN CLR lease'
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) 'held current-route fixed-infrastructure observation is current while every borrowed scope remains OPEN'
                Assert-TestCondition ([string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCoverageExact($observation) -ceq 'HELD_CURRENT_ROUTE_FIXED_INFRASTRUCTURE_PROBED' -and
                    [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetScopeExact($observation) -ceq 'RUNTIME_ONLY' -and
                    [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetMutationAuthorizationExact($observation) -ceq 'NONE') 'observation explicitly carries probed coverage without mutation authority'
                Assert-TestCondition ([object]::ReferenceEquals([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetAuthorityContextExact($observation),$capabilityFixture.Context) -and
                    [object]::ReferenceEquals([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetGlobalLockHandleExact($observation),$capabilityGlobal) -and
                    [object]::ReferenceEquals([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCanonicalWitnessExact($observation),$capabilityWitness) -and
                    [object]::ReferenceEquals([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCurrentRouteCaptureExact($observation),$observationRoute)) 'observation retains the exact caller-owned authority, canonical, global, and route objects'
                $observationFixed=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetFixedEvidenceExact($observation)
                Assert-TestCondition ($observationFixed -is [AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence] -and
                    [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetFixedCapabilityProjectionHashExact($observation) -ceq
                        [string][AiAgentDotfiles.SealedFixedInfrastructureCapabilityEvidence]::GetProjectionHashExact($observationFixed) -and
                    [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetCurrentRouteRootSetHashExact($observation) -ceq [string]$observationRouteSet.RouteRootSetHash -and
                    [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetHeldTargetSetHashExact($observation) -ceq
                        [string][AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetHeldTargetSetHash($observationRoute)) 'observation binds exact fixed capability, current-route, and held-live-target projections'
                Assert-TestCondition ([string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIssuerDefinitionDigestExact($observation) -match '\A[0-9a-f]{64}\z' -and
                    [string][AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIssuerRunspaceIdExact($observation) -ceq
                        [string][Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId) 'runtime observation binds its exact issuer definition and owner runspace scope'
                Assert-TestCondition (@([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetConstructors()).Count -eq 0 -and
                    $null -eq [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetMethod('CreateExact') -and
                    $null -eq [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetMethod('GetOuterFixedEnvelopeLeaseExact')) 'runtime observation exposes neither a public constructor, public evidence factory, nor raw owned-envelope getter'
                $observationFacadePublicMethods=@([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetMethods(
                    ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::DeclaredOnly)).Name | Sort-Object -CaseSensitive)
                $expectedObservationFacadePublicMethods=@(
                    'GetAuthorityContextExact','GetAuthorityContextHashExact','GetCanonicalWitnessExact',
                    'GetCloseStateExact','GetCoverageExact','GetCurrentRouteCaptureExact',
                    'GetCurrentRouteRootSetHashExact','GetEntryGlobalLockEvidenceExact',
                    'GetFixedCapabilityProjectionHashExact','GetFixedEnvelopeHashExact','GetFixedEvidenceExact',
                    'GetGlobalBindingExact','GetGlobalBindingHashExact','GetGlobalLockHandleExact',
                    'GetHeldTargetSetHashExact','GetIsClosedExact','GetIsOpenExact',
                    'GetIssuerDefinitionDigestExact','GetIssuerRunspaceIdExact','GetLiveProjectionExact',
                    'GetLiveSetLeaseExact','GetLiveSetReceiptExact','GetLockSecurityHashExact',
                    'GetMutationAuthorizationExact','GetObservationProjectionHashExact','GetScopeExact','IsGenuine'
                ) | Sort-Object -CaseSensitive
                $observationFacadePublicProperties=@([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetProperties(
                    ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::DeclaredOnly)))
                $observationFacadePublicFields=@([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetFields(
                    ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::DeclaredOnly)))
                Assert-TestCondition (($observationFacadePublicMethods -join "`0") -ceq ($expectedObservationFacadePublicMethods -join "`0") -and
                    $observationFacadePublicProperties.Count -eq 0 -and $observationFacadePublicFields.Count -eq 0) 'runtime observation CLR facade exposes only the exact reviewed read-only method table and no public properties or fields'
                $observationIssuerPublicMethods=@([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer].GetMethods(
                    ([Reflection.BindingFlags]::Public -bor [Reflection.BindingFlags]::Static -bor [Reflection.BindingFlags]::DeclaredOnly)).Name | Sort-Object -CaseSensitive)
                $expectedObservationIssuerPublicMethods=@(
                    'AssertObservationExact','CloseObservationExact','InitializeObservationExact',
                    'MatchesObservationDefinitionsExact','OpenObservationExact'
                ) | Sort-Object -CaseSensitive
                Assert-TestCondition (($observationIssuerPublicMethods -join "`0") -ceq ($expectedObservationIssuerPublicMethods -join "`0")) 'observation issuer exposes only the reviewed route-plus-bindings broker and lifecycle surface'
                $observationDefinitionScripts=@{}
                foreach($observationDefinitionScriptName in @(
                    'OpenCore','AssertCore','FixedCapture','FixedEnvelopeOpen','FixedEnvelopeProjection',
                    'FixedEnvelopeClose','FixedDirectoryOpen','FixedDirectoryClose','RouteCaptureStable',
                    'CanonicalGlobalBinding','GlobalLockWitness','FixedEvidenceCurrent','SemanticJsonHash','SecurityTemplate'
                )){
                    $observationDefinitionScripts[$observationDefinitionScriptName]=$observationDefinition.GetType().GetField(
                        $observationDefinitionScriptName,$observationDefinitionFieldFlags).GetValue($observationDefinition)
                }
                $observationSameTextOpenCore=[scriptblock]::Create(
                    [string]$observationDefinitionScripts.OpenCore.Ast.Extent.Text)
                Assert-TestCondition (-not [object]::ReferenceEquals(
                    $observationSameTextOpenCore,$observationDefinitionScripts.OpenCore) -and
                    -not [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]::MatchesObservationDefinitionsExact(
                        $observationSameTextOpenCore,$observationDefinitionScripts.AssertCore,
                        $observationDefinitionScripts.FixedCapture,$observationDefinitionScripts.FixedEnvelopeOpen,
                        $observationDefinitionScripts.FixedEnvelopeProjection,$observationDefinitionScripts.FixedEnvelopeClose,
                        $observationDefinitionScripts.FixedDirectoryOpen,$observationDefinitionScripts.FixedDirectoryClose,
                        $observationDefinitionScripts.RouteCaptureStable,$observationDefinitionScripts.CanonicalGlobalBinding,
                        $observationDefinitionScripts.GlobalLockWitness,$observationDefinitionScripts.FixedEvidenceCurrent,
                        $observationDefinitionScripts.SemanticJsonHash,$observationDefinitionScripts.SecurityTemplate,
                        $observationOwnerRunspaceId)) 'observation issuer rejects a same-text ScriptBlock substitution in its pinned definition'
                Assert-ThrowsPattern {
                    [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]::InitializeObservationExact(
                        $observationSameTextOpenCore,$observationDefinitionScripts.AssertCore,
                        $observationDefinitionScripts.FixedCapture,$observationDefinitionScripts.FixedEnvelopeOpen,
                        $observationDefinitionScripts.FixedEnvelopeProjection,$observationDefinitionScripts.FixedEnvelopeClose,
                        $observationDefinitionScripts.FixedDirectoryOpen,$observationDefinitionScripts.FixedDirectoryClose,
                        $observationDefinitionScripts.RouteCaptureStable,$observationDefinitionScripts.CanonicalGlobalBinding,
                        $observationDefinitionScripts.GlobalLockWitness,$observationDefinitionScripts.FixedEvidenceCurrent,
                        $observationDefinitionScripts.SemanticJsonHash,$observationDefinitionScripts.SecurityTemplate,
                        $observationOwnerRunspaceId)
                } 'held-current-route-fixed-infrastructure-observation-stale' 'observation initialization rejects a same-text replacement for an exact pinned definition'
                $observationClone=[object].GetMethod('MemberwiseClone',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic)).Invoke($observation,$null)
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationClone | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'a genuine CLR MemberwiseClone cannot copy issuer provenance'
                Assert-ThrowsPattern { Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationClone | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'closing a genuine CLR clone cannot release the original observation-owned envelope'
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) 'clone rejection leaves the original observation OPEN and current'
                $observationUninitialized=[Runtime.CompilerServices.RuntimeHelpers]::GetUninitializedObject(
                    [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation])
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationUninitialized | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'an uninitialized genuine CLR instance cannot forge observation provenance'
                Assert-ThrowsPattern { Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationUninitialized | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'closing an uninitialized CLR instance cannot release the original observation-owned envelope'
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) 'uninitialized-instance rejection leaves the original observation OPEN and current'
                $crossRunspacePowerShell=[PowerShell]::Create()
                try {
                    $null=$crossRunspacePowerShell.AddScript({
                        param($ForeignObservation,$ForeignRouteCapture)
                        "route-receipt=$([AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::HasExactIssuanceReceipt($ForeignRouteCapture))"
                        try {
                            [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($ForeignRouteCapture) | Out-Null
                            'cross-runspace-route-close-unexpectedly-succeeded'
                        }
                        catch {
                            $domainError=$_.Exception
                            while($null -ne $domainError.InnerException){$domainError=$domainError.InnerException}
                            [string]$domainError.Message
                        }
                        foreach($foreignRouteMethod in @(
                            'GetLiveSetLease','GetLiveProjection','GetRouteLeaseRows','GetReservationLeases',
                            'GetFixedLeases','GetOriginalCurrentRouteRootSet','GetCanonicalWitness',
                            'GetCurrentRouteRootSetSnapshot'
                        )){
                            try {
                                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture].GetMethod(
                                    $foreignRouteMethod).Invoke($null,@($ForeignRouteCapture)) | Out-Null
                                "cross-runspace-route-$foreignRouteMethod-unexpectedly-succeeded"
                            }
                            catch {
                                $domainError=$_.Exception
                                while($null -ne $domainError.InnerException){$domainError=$domainError.InnerException}
                                [string]$domainError.Message
                            }
                        }
                        foreach($foreignRouteProperty in @(
                            'LiveSetLease','LiveProjection','RouteLeaseRows','ReservationLeases','FixedLeases',
                            'OriginalCurrentRouteRootSet','CanonicalWitness','CurrentRouteRootSetSnapshot'
                        )){
                            try {
                                [AiAgentDotfiles.SealedRegistryCurrentRouteCapture].GetProperty(
                                    $foreignRouteProperty).GetValue($ForeignRouteCapture) | Out-Null
                                "cross-runspace-route-property-$foreignRouteProperty-unexpectedly-succeeded"
                            }
                            catch {
                                $domainError=$_.Exception
                                while($null -ne $domainError.InnerException){$domainError=$domainError.InnerException}
                                [string]$domainError.Message
                            }
                        }
                        "observation-genuine=$([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::IsGenuine($ForeignObservation))"
                        "observation-open=$([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($ForeignObservation))"
                        foreach($foreignFacadeMethod in @('GetIsClosedExact','GetCloseStateExact','GetCurrentRouteCaptureExact')){
                            try {
                                [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetMethod($foreignFacadeMethod).Invoke($null,@($ForeignObservation)) | Out-Null
                                "cross-runspace-$foreignFacadeMethod-unexpectedly-succeeded"
                            }
                            catch {
                                $domainError=$_.Exception
                                while($null -ne $domainError.InnerException){$domainError=$domainError.InnerException}
                                [string]$domainError.Message
                            }
                        }
                        try {
                            [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]::AssertObservationExact($ForeignObservation) | Out-Null
                            'cross-runspace-assert-unexpectedly-succeeded'
                        }
                        catch {
                            $domainError=$_.Exception
                            while($null -ne $domainError.InnerException){$domainError=$domainError.InnerException}
                            [string]$domainError.Message
                        }
                        try {
                            [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer]::CloseObservationExact($ForeignObservation) | Out-Null
                            return 'cross-runspace-close-unexpectedly-succeeded'
                        }
                        catch {
                            $domainError=$_.Exception
                            while($null -ne $domainError.InnerException){$domainError=$domainError.InnerException}
                            return [string]$domainError.Message
                        }
                    }).AddArgument($observation).AddArgument($observationRoute)
                    $crossRunspaceCloseResult=@($crossRunspacePowerShell.Invoke())
                    $crossRunspaceErrors=@($crossRunspacePowerShell.Streams.Error)
                }
                finally { $crossRunspacePowerShell.Dispose() }
                Assert-TestCondition ($crossRunspaceErrors.Count -eq 0 -and $crossRunspaceCloseResult.Count -eq 25 -and
                    [string]$crossRunspaceCloseResult[0] -ceq 'route-receipt=False' -and
                    [string]$crossRunspaceCloseResult[1] -ceq 'route-witness-required' -and
                    @($crossRunspaceCloseResult[2..17] | Where-Object {[string]$_ -cne 'route-witness-required'}).Count -eq 0 -and
                    [string]$crossRunspaceCloseResult[18] -ceq 'observation-genuine=False' -and
                    [string]$crossRunspaceCloseResult[19] -ceq 'observation-open=False' -and
                    @($crossRunspaceCloseResult[20..24] | Where-Object {[string]$_ -cne 'held-current-route-fixed-infrastructure-observation-stale'}).Count -eq 0) 'a foreign runspace cannot release the caller-owned route, extract route capabilities through static or instance getters, inspect observation state, or close an owner-runspace observation'
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) 'cross-runspace close rejection occurs before lifecycle transition or owned-envelope cleanup'
                Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $capabilityFixture) -ceq $observationTreeBefore -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'OPEN observation holds only handles and leaves the authority tree and probe roots unchanged'

                $observationCanonicalWitnessHash=[string]$capabilityGlobal.CanonicalWitnessHash
                try {
                    $capabilityGlobal.CanonicalWitnessHash=('0' * 64)
                    Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'canonical/global binding display drift independently invalidates the observation'
                }
                finally { $capabilityGlobal.CanonicalWitnessHash=$observationCanonicalWitnessHash }
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) 'restoring the exact canonical/global binding leaves the observation and all borrowed owners OPEN'

                $observationGlobalSecurityHash=[string]$capabilityGlobal.SecurityHash
                try {
                    $capabilityGlobal.SecurityHash=('0' * 64)
                    Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'global-lock witness display drift independently invalidates the observation'
                }
                finally { $capabilityGlobal.SecurityHash=$observationGlobalSecurityHash }
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) 'restoring the exact global-lock display leaves the observation and all borrowed owners OPEN'

                $ownedEnvelopeField=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetField(
                    'outerFixedEnvelopeLease',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
                $ownedEnvelopeLease=$ownedEnvelopeField.GetValue($observation)
                $ownedEnvelopeHandleChainsField=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetField(
                    'outerFixedEnvelopeHandleChains',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
                $ownedEnvelopeFrozenHandleChains=[object[][]]$ownedEnvelopeHandleChainsField.GetValue($observation)
                $ownedEnvelopeFrozenHandles=@($ownedEnvelopeFrozenHandleChains | ForEach-Object {@($_)})
                Assert-ThrowsPattern {
                    Close-SealedHomeAuthorityFixedEnvelope -EnvelopeLease $ownedEnvelopeLease
                } '^home-authority-fixed-envelope-lease-reserved$' 'the public raw outer-envelope close path rejects an observation-reserved lease before touching physical resources'
                Assert-TestCondition ((Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) -and
                    @($ownedEnvelopeFrozenHandles | Where-Object {-not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0) 'raw close rejection leaves every frozen owned handle OPEN and the observation current'

                $observationRouteStableField=$observationDefinition.GetType().GetField(
                    'RouteCaptureStable',$observationDefinitionFieldFlags)
                $observationOriginalPinnedRouteStable=$observationRouteStableField.GetValue($observationDefinition)
                $observationAssertCloseProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
                $observationAssertCloseState=[pscustomobject]@{Calls=0L}
                $observationBlockingRouteStable={
                    param($Capture)
                    $observationAssertCloseState.Calls++
                    $result=& $observationOriginalPinnedRouteStable -Capture $Capture
                    if([long]$observationAssertCloseState.Calls -eq 1L){
                        $observationAssertCloseProbe.Dispose()
                    }
                    return $result
                }.GetNewClosure()
                $observationCloseWhileAssertTask=$null
                try {
                    $observationRouteStableField.SetValue($observationDefinition,$observationBlockingRouteStable)
                    $observationCloseWhileAssertTask=[AiAgentDotfiles.ReceiptReleaseProbe]::StartExpectedFailureAfterEnterInOwnerRunspace(
                        'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer','CloseObservationExact',$observation,
                        [Management.Automation.Runspaces.Runspace]::DefaultRunspace,$observationAssertCloseProbe)
                    Assert-TestCondition ((Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation) -and
                        [long]$observationAssertCloseState.Calls -eq 2L) 'observation Assert holds an active lifecycle read while borrowed state is revalidated'
                    $observationCloseWhileAssertError=$observationCloseWhileAssertTask.GetAwaiter().GetResult()
                    Assert-TestCondition ($observationCloseWhileAssertError -ceq 'held-current-route-fixed-infrastructure-observation-close-active') 'observation Close cannot release owned handles while an Assert lifecycle read is active'
                    Assert-TestCondition ([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation) -and
                        @($ownedEnvelopeFrozenHandles | Where-Object {-not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0) 'Assert and rejected Close interleaving leaves the observation OPEN with every owned handle held'
                }
                finally {
                    $observationAssertCloseProbe.AllowRelease()
                    if($null -ne $observationCloseWhileAssertTask -and -not $observationCloseWhileAssertTask.IsCompleted){
                        $observationCloseWhileAssertTask.GetAwaiter().GetResult() | Out-Null
                    }
                    $observationRouteStableField.SetValue($observationDefinition,$observationOriginalPinnedRouteStable)
                }
                Assert-TestCondition ([long]$observationAssertCloseProbe.SuccessfulDisposeCount -eq 1L -and
                    (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation)) 'blocked Assert completes successfully before the observation can be closed'

                $ownedEnvelopeFailureState=[pscustomobject]@{Calls=0L}
                $ownedEnvelopeInjectedFailureClose={
                    param($Handles)
                    $ownedEnvelopeFailureState.Calls++
                    throw 'injected-observation-close-failure'
                }.GetNewClosure()
                try {
                    $observationCloseField.SetValue($observationDefinition,$ownedEnvelopeInjectedFailureClose)
                    Assert-ThrowsPattern { Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation | Out-Null } '^injected-observation-close-failure$' 'owned-envelope close failure is surfaced without claiming the observation CLOSED'
                }
                finally { $observationCloseField.SetValue($observationDefinition,$observationOriginalPinnedEnvelopeClose) }
                Assert-TestCondition ([AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation) -and
                    [long]$ownedEnvelopeFailureState.Calls -eq 6L -and
                    @($ownedEnvelopeFrozenHandles | Where-Object {-not [AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                    (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation)) 'failed observation cleanup restores retryable OPEN after attempting every frozen handle chain without trusting the mutable display graph'

                $ownedEnvelopeBlockingProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($true,$false)
                $ownedEnvelopeBlockingState=[pscustomobject]@{Calls=0L}
                $ownedEnvelopeBlockingClose={
                    param($Handles)
                    $ownedEnvelopeBlockingState.Calls++
                    if([long]$ownedEnvelopeBlockingState.Calls -eq 1L){$ownedEnvelopeBlockingProbe.Dispose()}
                    & $observationOriginalPinnedEnvelopeClose -Handles $Handles
                }.GetNewClosure()
                $ownedEnvelopeConcurrentCloseTask=$null
                try {
                    $observationCloseField.SetValue($observationDefinition,$ownedEnvelopeBlockingClose)
                    $ownedEnvelopeConcurrentCloseTask=[AiAgentDotfiles.ReceiptReleaseProbe]::StartObservedExpectedFailureAfterEnterInOwnerRunspace(
                        'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservationIssuer','CloseObservationExact',
                        'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation',$observation,
                        [Management.Automation.Runspaces.Runspace]::DefaultRunspace,$ownedEnvelopeBlockingProbe)
                    $ownedEnvelopeFirstClose=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation
                    $ownedEnvelopeConcurrentCloseResult=$ownedEnvelopeConcurrentCloseTask.GetAwaiter().GetResult()
                    Assert-TestCondition ($ownedEnvelopeConcurrentCloseResult -ceq 'CLOSING|False|held-current-route-fixed-infrastructure-observation-close-active') 'observation publishes CLOSING and a concurrent second Close cannot report success while owned cleanup is active'
                    Assert-TestCondition $ownedEnvelopeFirstClose 'the first observation Close completes after its blocked owned cleanup is released'
                }
                finally {
                    $ownedEnvelopeBlockingProbe.AllowRelease()
                    if($null -ne $ownedEnvelopeConcurrentCloseTask -and -not $ownedEnvelopeConcurrentCloseTask.IsCompleted){
                        $ownedEnvelopeConcurrentCloseTask.GetAwaiter().GetResult() | Out-Null
                    }
                    $observationCloseField.SetValue($observationDefinition,$observationOriginalPinnedEnvelopeClose)
                }
                Assert-TestCondition ([long]$ownedEnvelopeBlockingProbe.SuccessfulDisposeCount -eq 1L -and
                    [long]$ownedEnvelopeBlockingState.Calls -eq 6L -and
                    @($ownedEnvelopeFrozenHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                    -not [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation)) 'first observation Close reaches CLOSED only after every frozen owned handle is physically released'
                $observationSecondClose=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation
                Assert-TestCondition (-not $observationSecondClose -and [long]$ownedEnvelopeBlockingProbe.DisposeCount -eq 1L -and
                    [long]$ownedEnvelopeBlockingProbe.SuccessfulDisposeCount -eq 1L -and
                    [long]$ownedEnvelopeBlockingState.Calls -eq 6L) 'observation close is idempotent without repeating owned cleanup'
                Assert-TestCondition ((Assert-SealedRegistryCurrentRouteCaptureStable -Capture $observationRoute) -ne $false) 'closing the observation leaves the caller-owned current-route scope OPEN and stable'
                $null=Assert-SealedHomeAuthorityGlobalLockWitness -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal
                $null=Assert-HomeAuthorityCanonicalGlobalLockBinding -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness
                Assert-TestCondition $true 'closing the observation leaves the caller-owned canonical/global binding OPEN and current'
            }
            catch {
                $observationTestPrimaryError=$_
                throw
            }
            finally {
                $observationTestCleanupError=$null
                if($null -ne $observation -and [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation)){
                    try { $null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation }
                    catch { $observationTestCleanupError=$_ }
                }
                try { $null=Close-SealedRegistryCurrentRouteCapture -Capture $observationRoute }
                catch { if($null -eq $observationTestCleanupError){$observationTestCleanupError=$_} }
                if($null -ne $observationTestCleanupError){
                    if($null -eq $observationTestPrimaryError){throw $observationTestCleanupError}
                    try { $observationTestPrimaryError.Exception.Data['ObservationTestCleanupError']=[string]$observationTestCleanupError.Exception.Message }
                    catch { }
                }
            }
            Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'closed observation cannot be reused as runtime authority'
            Assert-TestCondition (-not [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observation)) 'observation close changes the private CLR lifecycle state'

            $routeStaleCapture=$null
            $routeStaleObservation=$null
            $routeStalePrimaryError=$null
            try {
                $routeStaleSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
                $routeStaleCapture=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $routeStaleSet -Reservations @()
                $routeStaleObservation=Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $routeStaleCapture -CapabilityProbeBindings $observationBindings
                $null=Close-SealedRegistryCurrentRouteCapture -Capture $routeStaleCapture
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $routeStaleObservation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'closing the borrowed current-route scope immediately invalidates the observation'
                Assert-TestCondition (Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $routeStaleObservation) 'observation Close releases only its owned envelope after the borrowed route becomes stale'
            }
            catch {
                $routeStalePrimaryError=$_
                throw
            }
            finally {
                $routeStaleCleanupError=$null
                if($null -ne $routeStaleObservation -and [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($routeStaleObservation)){
                    try {$null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $routeStaleObservation}
                    catch {$routeStaleCleanupError=$_}
                }
                if($null -ne $routeStaleCapture -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($routeStaleCapture)){
                    try {$null=Close-SealedRegistryCurrentRouteCapture -Capture $routeStaleCapture}
                    catch {if($null -eq $routeStaleCleanupError){$routeStaleCleanupError=$_}}
                }
                if($null -ne $routeStaleCleanupError){
                    if($null -eq $routeStalePrimaryError){throw $routeStaleCleanupError}
                    try {$routeStalePrimaryError.Exception.Data['RouteStaleTestCleanupError']=[string]$routeStaleCleanupError.Exception.Message}
                    catch { }
                }
            }

            $observationShadowOriginalRouteStable=(Get-Command Assert-SealedRegistryCurrentRouteCaptureStable -CommandType Function -ErrorAction Stop).ScriptBlock
            $observationShadowOriginalFixedCapture=(Get-Command Invoke-SealedHeldFixedInfrastructureCapabilityCapture -CommandType Function -ErrorAction Stop).ScriptBlock
            $observationShadowOriginalFixedEvidenceCurrent=(Get-Command Assert-SealedHeldCurrentRouteFixedInfrastructureFixedEvidenceCurrent -CommandType Function -ErrorAction Stop).ScriptBlock
            $observationShadowOriginalDirectoryClose=(Get-Command Close-SafeDirectoryContainmentChain -CommandType Function -ErrorAction Stop).ScriptBlock
            $observationDelegatingShadowNames=@(
                'Open-SealedHomeAuthorityFixedEnvelope','Get-SealedHomeAuthorityFixedEnvelopeProjection',
                'Close-SealedHomeAuthorityFixedEnvelope','Assert-HomeAuthorityCanonicalGlobalLockBinding',
                'Assert-SealedHomeAuthorityGlobalLockWitness','Get-SemanticJsonHash',
                'Get-HomeAuthorityCurrentUserOnlySecurityTemplate'
            )
            $observationDelegatingShadowOriginals=@{}
            foreach($observationDelegatingShadowName in $observationDelegatingShadowNames){
                $observationDelegatingShadowOriginals[$observationDelegatingShadowName]=
                    (Get-Command $observationDelegatingShadowName -CommandType Function -ErrorAction Stop).ScriptBlock
            }
            $observationShadowState=[pscustomobject]@{
                BorrowedStateCalls=0L;RouteStableCalls=0L;FixedCaptureCalls=0L;FixedEvidenceCurrentCalls=0L
                ProviderDirectCalls=0L;ProviderDelegatedCalls=0L;DirectoryCloseCalls=0L
            }
            $observationTrustedPinnedCallers=@(
                'Invoke-SealedHeldFixedInfrastructureCapabilityCapture',
                'Assert-SealedRegistryCurrentRouteCaptureStable',
                'Assert-SealedHeldCurrentRouteFixedInfrastructureFixedEvidenceCurrent',
                'Open-SealedHomeAuthorityFixedEnvelope','Get-SealedHomeAuthorityFixedEnvelopeProjection',
                'Close-SealedHomeAuthorityFixedEnvelope','Assert-HomeAuthorityCanonicalGlobalLockBinding',
                'Assert-SealedHomeAuthorityGlobalLockWitness'
            )
            $observationDelegatingShadows=@{}
            foreach($observationDelegatingShadowName in $observationDelegatingShadowNames){
                $shadowedProviderName=$observationDelegatingShadowName
                $shadowedProviderOriginal=$observationDelegatingShadowOriginals[$observationDelegatingShadowName]
                $observationDelegatingShadows[$observationDelegatingShadowName]={
                    param()
                    $trustedProviderCall=@(Get-PSCallStack | Select-Object -Skip 1 | Where-Object {
                        [string]$_.FunctionName -cin $observationTrustedPinnedCallers
                    }).Count -gt 0
                    if(-not $trustedProviderCall){
                        $observationShadowState.ProviderDirectCalls++
                        throw "provider-shadow-direct-call:$shadowedProviderName"
                    }
                    $observationShadowState.ProviderDelegatedCalls++
                    & $shadowedProviderOriginal @args
                }.GetNewClosure()
            }
            $observationBorrowedStateShadow={
                param($CurrentRouteCapture)
                $observationShadowState.BorrowedStateCalls++
                return [pscustomobject]@{CurrentRouteCapture=$CurrentRouteCapture;AuthorityContext=$capabilityFixture.Context}
            }.GetNewClosure()
            $observationRouteStableShadow={
                param($Capture)
                $observationShadowState.RouteStableCalls++
                throw 'provider-shadow-route-stable-called'
            }.GetNewClosure()
            $observationFixedCaptureShadow={
                param($AuthorityContext,$GlobalLockHandle,$CanonicalWitness,[object[]]$CapabilityProbeBindings)
                $observationShadowState.FixedCaptureCalls++
                throw 'provider-shadow-fixed-capture-called'
            }.GetNewClosure()
            $observationFixedEvidenceCurrentShadow={
                param($Evidence,$AuthorityContext,$AuthorityContextHash,$FixedEnvelopeHash,$LockSecurityHash,$ProjectionHash)
                $observationShadowState.FixedEvidenceCurrentCalls++
                throw 'provider-shadow-fixed-evidence-current-called'
            }.GetNewClosure()
            $observationDirectoryCloseNoOpShadow={
                param($Handles)
                $observationShadowState.DirectoryCloseCalls++
            }.GetNewClosure()
            $observationShadowRoute=$null
            $observationShadowObservation=$null
            $observationShadowOwnedCloseProbe=$null
            $observationShadowPrimaryError=$null
            try {
                $observationShadowRouteSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
                $observationShadowRoute=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $observationShadowRouteSet -Reservations @()
                Set-Item -LiteralPath Function:\Get-SealedHeldCurrentRouteFixedInfrastructureBorrowedState -Value $observationBorrowedStateShadow
                Set-Item -LiteralPath Function:\Assert-SealedRegistryCurrentRouteCaptureStable -Value $observationRouteStableShadow
                Set-Item -LiteralPath Function:\Invoke-SealedHeldFixedInfrastructureCapabilityCapture -Value $observationFixedCaptureShadow
                Set-Item -LiteralPath Function:\Assert-SealedHeldCurrentRouteFixedInfrastructureFixedEvidenceCurrent -Value $observationFixedEvidenceCurrentShadow
                foreach($observationDelegatingShadowName in $observationDelegatingShadowNames){
                    Set-Item -LiteralPath "Function:\$observationDelegatingShadowName" -Value $observationDelegatingShadows[$observationDelegatingShadowName]
                }
                $observationShadowObservation=Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationShadowRoute -CapabilityProbeBindings $observationBindings
                Assert-TestCondition (Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationShadowObservation) 'genuine observation Open and Assert invoke issuer-pinned route, capture, and evidence definitions instead of provider shadows'
                Assert-ThrowsPattern { Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $syntheticObservationRoute -CapabilityProbeBindings $observationBindings | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'a provider shadow cannot mint an observation from a receipt-free route clone'
                Assert-TestCondition ([long]$observationShadowState.BorrowedStateCalls -eq 0L -and
                    [long]$observationShadowState.RouteStableCalls -eq 0L -and
                    [long]$observationShadowState.FixedCaptureCalls -eq 0L -and
                    [long]$observationShadowState.FixedEvidenceCurrentCalls -eq 0L -and
                    [long]$observationShadowState.ProviderDirectCalls -eq 0L) 'observation lifecycle never directly resolves the removed borrowed-state helper or issuer-pinned provider entrypoints'
                $observationDelegatedCallsAfterCurrentAssert=[long]$observationShadowState.ProviderDelegatedCalls
                Assert-TestCondition ($observationDelegatedCallsAfterCurrentAssert -gt 0L) 'runtime observation checkpoint keeps transitive provider delegation explicitly outside its direct-pinning coverage'
                $observationShadowOwnedEnvelopeField=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetField(
                    'outerFixedEnvelopeLease',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
                $observationShadowOwnedEnvelope=$observationShadowOwnedEnvelopeField.GetValue($observationShadowObservation)
                $observationShadowOwnedHandleChainsField=[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation].GetField(
                    'outerFixedEnvelopeHandleChains',([Reflection.BindingFlags]::Instance -bor [Reflection.BindingFlags]::NonPublic))
                $observationShadowOwnedFrozenHandleChains=[object[][]]$observationShadowOwnedHandleChainsField.GetValue($observationShadowObservation)
                $observationShadowOwnedFrozenHandles=@($observationShadowOwnedFrozenHandleChains | ForEach-Object {@($_)})
                $observationShadowOwnedCloseProbe=[AiAgentDotfiles.ReceiptReleaseProbe]::new($false,$false)
                $observationShadowOwnedEnvelope.IsClosed=$true
                $observationShadowOwnedEnvelope.DirectoryLeases=@([pscustomobject]@{
                    Name='InjectedForeignDisplay';Path=$capabilityProbeRoot;Identity='foreign';
                    Handles=@($observationShadowOwnedCloseProbe);Held=$observationShadowOwnedCloseProbe
                })
                Set-Item -LiteralPath Function:\Close-SafeDirectoryContainmentChain -Value $observationDirectoryCloseNoOpShadow
                $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($observationShadowRoute)
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationShadowObservation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'provider shadows cannot keep an observation current after its exact borrowed route closes'
                Assert-TestCondition (Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationShadowObservation) 'provider-shadow rejection still permits independent cleanup of the observation-owned envelope'
                Assert-TestCondition ([long]$observationShadowState.BorrowedStateCalls -eq 0L -and
                    [long]$observationShadowState.RouteStableCalls -eq 0L -and
                    [long]$observationShadowState.FixedCaptureCalls -eq 0L -and
                    [long]$observationShadowState.FixedEvidenceCurrentCalls -eq 0L -and
                    [long]$observationShadowState.ProviderDirectCalls -eq 0L -and
                    [long]$observationShadowState.ProviderDelegatedCalls -eq $observationDelegatedCallsAfterCurrentAssert -and
                    [long]$observationShadowState.DirectoryCloseCalls -eq 0L -and
                    $null -ne $observationShadowOwnedCloseProbe -and -not $observationShadowOwnedCloseProbe.IsDisposed -and
                    @($observationShadowOwnedFrozenHandles | Where-Object {[AiAgentDotfiles.SafeDirectoryHandle]::IsOpenExact($_)}).Count -eq 0 -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityProbeRoot)).Count -eq 0 -and
                    @([IO.Directory]::EnumerateFileSystemEntries($capabilityAlternateProbeRoot)).Count -eq 0) 'provider-shadow lifecycle closes only the frozen owned handles, ignores the mutable display graph and foreign probe, and leaves no probe residue'
            }
            catch {
                $observationShadowPrimaryError=$_
                throw
            }
            finally {
                Set-Item -LiteralPath Function:\Assert-SealedRegistryCurrentRouteCaptureStable -Value $observationShadowOriginalRouteStable
                Set-Item -LiteralPath Function:\Invoke-SealedHeldFixedInfrastructureCapabilityCapture -Value $observationShadowOriginalFixedCapture
                Set-Item -LiteralPath Function:\Assert-SealedHeldCurrentRouteFixedInfrastructureFixedEvidenceCurrent -Value $observationShadowOriginalFixedEvidenceCurrent
                Set-Item -LiteralPath Function:\Close-SafeDirectoryContainmentChain -Value $observationShadowOriginalDirectoryClose
                foreach($observationDelegatingShadowName in $observationDelegatingShadowNames){
                    Set-Item -LiteralPath "Function:\$observationDelegatingShadowName" -Value $observationDelegatingShadowOriginals[$observationDelegatingShadowName]
                }
                Remove-Item -LiteralPath Function:\Get-SealedHeldCurrentRouteFixedInfrastructureBorrowedState -ErrorAction SilentlyContinue
                $observationShadowCleanupError=$null
                if($null -ne $observationShadowObservation -and [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observationShadowObservation)){
                    try {$null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationShadowObservation}
                    catch {$observationShadowCleanupError=$_}
                }
                if($null -ne $observationShadowRoute -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationShadowRoute)){
                    try {$null=Close-SealedRegistryCurrentRouteCapture -Capture $observationShadowRoute}
                    catch {if($null -eq $observationShadowCleanupError){$observationShadowCleanupError=$_}}
                }
                if($null -ne $observationShadowCleanupError){
                    if($null -eq $observationShadowPrimaryError){throw $observationShadowCleanupError}
                    try {$observationShadowPrimaryError.Exception.Data['ObservationShadowTestCleanupError']=[string]$observationShadowCleanupError.Exception.Message}
                    catch { }
                }
            }

            $observationExitProjectionField=$observationDefinition.GetType().GetField('FixedEnvelopeProjection',
                ([Reflection.BindingFlags]::NonPublic -bor [Reflection.BindingFlags]::Instance))
            $observationExitOriginalProjection=$observationExitProjectionField.GetValue($observationDefinition)
            $observationExitRoute=$null
            $observationExitObservation=$null
            $observationExitPrimaryError=$null
            $observationExitState=[pscustomobject]@{ProjectionCalls=0L;RouteReleased=$false;Route=$null}
            $observationExitProjection={
                param($AuthorityContext,$DirectorySecurityTemplate,$FileSecurityTemplate,$EnvelopeLease,$HeldGlobalLock)
                $observationExitState.ProjectionCalls++
                $projection=& $observationExitOriginalProjection -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $DirectorySecurityTemplate -FileSecurityTemplate $FileSecurityTemplate -EnvelopeLease $EnvelopeLease -HeldGlobalLock $HeldGlobalLock
                if(-not $observationExitState.RouteReleased){
                    $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($observationExitState.Route)
                    $observationExitState.RouteReleased=$true
                }
                return $projection
            }.GetNewClosure()
            try {
                $observationExitRouteSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
                $observationExitRoute=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $observationExitRouteSet -Reservations @()
                $observationExitState.Route=$observationExitRoute
                $observationExitObservation=Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationExitRoute -CapabilityProbeBindings $observationBindings
                $observationExitProjectionField.SetValue($observationDefinition,$observationExitProjection)
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationExitObservation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'final borrowed-state revalidation rejects a route closed after fixed evidence and outer-envelope projection checks'
                Assert-TestCondition ([bool]$observationExitState.RouteReleased) 'exit revalidation fixture closes the borrowed route at the envelope-projection boundary after every earlier observation check'
                Assert-TestCondition (Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationExitObservation) 'exit-revalidation failure still permits independent cleanup of the observation-owned envelope'
            }
            catch {
                $observationExitPrimaryError=$_
                throw
            }
            finally {
                $observationExitProjectionField.SetValue($observationDefinition,$observationExitOriginalProjection)
                $observationExitCleanupError=$null
                if($null -ne $observationExitObservation -and [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observationExitObservation)){
                    try {$null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationExitObservation}
                    catch {$observationExitCleanupError=$_}
                }
                if($null -ne $observationExitRoute -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationExitRoute)){
                    try {$null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($observationExitRoute)}
                    catch {if($null -eq $observationExitCleanupError){$observationExitCleanupError=$_}}
                }
                if($null -ne $observationExitCleanupError){
                    if($null -eq $observationExitPrimaryError){throw $observationExitCleanupError}
                    try {$observationExitPrimaryError.Exception.Data['ObservationExitTestCleanupError']=[string]$observationExitCleanupError.Exception.Message}
                    catch { }
                }
            }

            $observationProbeDriftRoute=$null
            $observationProbeDriftObservation=$null
            $observationProbeDriftPrimaryError=$null
            try {
                $observationProbeDriftRouteSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
                $observationProbeDriftRoute=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $observationProbeDriftRouteSet -Reservations @()
                $observationProbeDriftObservation=Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationProbeDriftRoute -CapabilityProbeBindings $observationBindings
                $observationProbeDriftEntryMarker=Get-NoFollowRootEntryMarker -Path $capabilityAlternateProbeRoot
                $observationProbeDriftReplacementIdentity=Replace-TestDirectoryWithDifferentIdentity -Path $capabilityAlternateProbeRoot -ExpectedIdentity ([string]$observationProbeDriftEntryMarker.Identity) -KeeperRoot $workRoot
                Assert-TestCondition ([string]$observationProbeDriftReplacementIdentity -cne [string]$observationProbeDriftEntryMarker.Identity) 'probe-root drift fixture replaces the exact entry identity while preserving the approved path'
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationProbeDriftObservation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'replacing an observation-bound probe-root identity invalidates fixed capability evidence'
                Assert-TestCondition (Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationProbeDriftObservation) 'fixed-evidence identity drift does not prevent independent cleanup of the observation-owned envelope'
                $null=Close-SealedRegistryCurrentRouteCapture -Capture $observationProbeDriftRoute
            }
            catch {
                $observationProbeDriftPrimaryError=$_
                throw
            }
            finally {
                $observationProbeDriftCleanupError=$null
                if($null -ne $observationProbeDriftObservation -and [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observationProbeDriftObservation)){
                    try {$null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationProbeDriftObservation}
                    catch {$observationProbeDriftCleanupError=$_}
                }
                if($null -ne $observationProbeDriftRoute -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationProbeDriftRoute)){
                    try {$null=Close-SealedRegistryCurrentRouteCapture -Capture $observationProbeDriftRoute}
                    catch {if($null -eq $observationProbeDriftCleanupError){$observationProbeDriftCleanupError=$_}}
                }
                if($null -ne $observationProbeDriftCleanupError){
                    if($null -eq $observationProbeDriftPrimaryError){throw $observationProbeDriftCleanupError}
                    try {$observationProbeDriftPrimaryError.Exception.Data['ObservationProbeDriftCleanupError']=[string]$observationProbeDriftCleanupError.Exception.Message}
                    catch { }
                }
            }

            $observationGlobalDriftRoute=$null
            $observationGlobalDriftObservation=$null
            $observationGlobalDriftReplacement=$null
            $observationGlobalDriftReleased=$false
            $observationGlobalDriftPrimaryError=$null
            try {
                $observationGlobalDriftRouteSet=New-SealedCurrentRouteRootSet -CanonicalWitness $capabilityWitness
                $observationGlobalDriftRoute=Open-TestSealedRegistryCurrentRouteCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityGlobal -CanonicalWitness $capabilityWitness -CurrentRouteRootSet $observationGlobalDriftRouteSet -Reservations @()
                $observationGlobalDriftObservation=Open-TestSealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -CurrentRouteCapture $observationGlobalDriftRoute -CapabilityProbeBindings $observationBindings
                Exit-HomeAuthorityGlobalLiveLock -LockHandle $capabilityGlobal
                $observationGlobalDriftReleased=$true
                $observationGlobalDriftReplacement=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $capabilityFixture.Context -RequiredCanonicalWitness $capabilityWitness
                $capabilityGlobal=$observationGlobalDriftReplacement
                Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationGlobalDriftObservation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'release and same-path reacquisition of the global lock invalidates the exact borrowed observation scope'
                Assert-TestCondition (Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationGlobalDriftObservation) 'global-lock identity drift does not prevent independent cleanup of the observation-owned envelope'
                $null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($observationGlobalDriftRoute)
                Assert-TestCondition (-not [object]::ReferenceEquals($observationGlobalDriftReplacement,[AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetGlobalLockHandleExact($observationGlobalDriftObservation))) 'same-path global reacquisition creates a distinct wrapper without transferring ownership to the observation'
            }
            catch {
                $observationGlobalDriftPrimaryError=$_
                throw
            }
            finally {
                $observationGlobalDriftCleanupError=$null
                if($observationGlobalDriftReleased -and $null -eq $observationGlobalDriftReplacement){
                    try {
                        $observationGlobalDriftReplacement=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $capabilityFixture.Context -RequiredCanonicalWitness $capabilityWitness
                        $capabilityGlobal=$observationGlobalDriftReplacement
                    }
                    catch {$observationGlobalDriftCleanupError=$_}
                }
                if($null -ne $observationGlobalDriftObservation -and [AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation]::GetIsOpenExact($observationGlobalDriftObservation)){
                    try {$null=Close-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $observationGlobalDriftObservation}
                    catch {if($null -eq $observationGlobalDriftCleanupError){$observationGlobalDriftCleanupError=$_}}
                }
                if($null -ne $observationGlobalDriftRoute -and [AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::GetIsOpenExact($observationGlobalDriftRoute)){
                    try {$null=[AiAgentDotfiles.SealedRegistryCurrentRouteCapture]::ReleaseExact($observationGlobalDriftRoute)}
                    catch {if($null -eq $observationGlobalDriftCleanupError){$observationGlobalDriftCleanupError=$_}}
                }
                if($null -ne $observationGlobalDriftCleanupError){
                    if($null -eq $observationGlobalDriftPrimaryError){throw $observationGlobalDriftCleanupError}
                    try {$observationGlobalDriftPrimaryError.Exception.Data['ObservationGlobalDriftCleanupError']=[string]$observationGlobalDriftCleanupError.Exception.Message}
                    catch { }
                }
            }

            $forgedObservation=[pscustomobject]@{}
            $forgedObservation.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation')
            Assert-ThrowsPattern { Assert-SealedHeldCurrentRouteFixedInfrastructureCapabilityObservation -Observation $forgedObservation | Out-Null } '^held-current-route-fixed-infrastructure-observation-stale$' 'a shaped PSCustomObject cannot forge an issued runtime observation'
        }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $capabilityGlobal }

        $capabilityPlainGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $capabilityFixture.Context
        try {
            Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityPlainGlobal -CanonicalWitness $capabilityWitness -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^canonical-witness-required$' 'a capability preflight cannot bind a canonical witness onto a global lock acquired without one'
            Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $capabilityPlainGlobal -CanonicalWitness $capabilityWitness -CapabilityProbeBindings @(
                [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
            ) | Out-Null } '^fixed-infrastructure-capability-lock-drift$' 'a plain global lock cannot be retroactively bound to a canonical witness for fixed capture'
        }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $capabilityPlainGlobal }
        Assert-ThrowsPattern { Invoke-SealedHeldCapabilityPreflight -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $null -CapabilityTargets @([ordered]@{ Path=[string]$capabilityFixture.Context.ControlBase; ProbeRoot=$capabilityProbeRoot }) | Out-Null } '^home-authority-registry-lock-required$' 'a capability preflight without a genuine global lock fails closed'
        foreach($invalidFixedLock in @($null,[pscustomobject]@{})){
            Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $capabilityFixture.Context -GlobalLockHandle $invalidFixedLock -CapabilityProbeBindings @(
                [ordered]@{Role='ControlBase';ProbeRoot=$capabilityProbeRoot},[ordered]@{Role='BackupRoot';ProbeRoot=$capabilityAlternateProbeRoot}
            ) | Out-Null } '^fixed-infrastructure-capability-lock-drift$' 'fixed capture rejects a null or forged global lock before probing'
        }
    }
    finally {
        if ($null -ne $capabilityWitness) { Close-CanonicalHeldNamespaceWitness -Witness $capabilityWitness }
        Exit-CanonicalRepoLock -LockHandle $capabilityLock
    }

    $fixedEnvelopeFixture=New-TestRegistryFixture -Parent $workRoot -Name 'fixed-capability-envelope-drift'
    $fixedEnvelopeProbeA=Join-Path $fixedEnvelopeFixture.Root 'probe-control'
    $fixedEnvelopeProbeB=Join-Path $fixedEnvelopeFixture.Root 'probe-backup'
    foreach($path in @($fixedEnvelopeProbeA,$fixedEnvelopeProbeB)){[IO.Directory]::CreateDirectory($path) | Out-Null}
    $fixedEnvelopeGlobal=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixedEnvelopeFixture.Context
    $fixedEnvelopeOriginalProjection=(Get-Command Get-SealedHomeAuthorityFixedEnvelopeProjection -CommandType Function -ErrorAction Stop).ScriptBlock
    $fixedEnvelopeState=[pscustomobject]@{ProjectionCount=0L;Lease=$null;SameLease=$false;Mutated=$false}
    $fixedEnvelopeProjectionShadow={
        param($AuthorityContext,$DirectorySecurityTemplate,$FileSecurityTemplate,$EnvelopeLease,$HeldGlobalLock)
        $fixedEnvelopeState.ProjectionCount++
        if([long]$fixedEnvelopeState.ProjectionCount -eq 1L){
            $fixedEnvelopeState.Lease=$EnvelopeLease
        }
        elseif([long]$fixedEnvelopeState.ProjectionCount -eq 2L){
            $fixedEnvelopeState.SameLease=[object]::ReferenceEquals($fixedEnvelopeState.Lease,$EnvelopeLease)
            Set-TestDirectoryInheritedCurrentUserOnly -Path ([string]$fixedEnvelopeFixture.Context.BackupRoot)
            $fixedEnvelopeState.Mutated=$true
        }
        & $fixedEnvelopeOriginalProjection -AuthorityContext $AuthorityContext -DirectorySecurityTemplate $DirectorySecurityTemplate -FileSecurityTemplate $FileSecurityTemplate -EnvelopeLease $EnvelopeLease -HeldGlobalLock $HeldGlobalLock
    }.GetNewClosure()
    try {
        Set-Item -LiteralPath Function:\Get-SealedHomeAuthorityFixedEnvelopeProjection -Value $fixedEnvelopeProjectionShadow
        Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $fixedEnvelopeFixture.Context -GlobalLockHandle $fixedEnvelopeGlobal -CapabilityProbeBindings @(
            [ordered]@{Role='BackupRoot';ProbeRoot=$fixedEnvelopeProbeB},[ordered]@{Role='ControlBase';ProbeRoot=$fixedEnvelopeProbeA}
        ) | Out-Null } '^fixed-infrastructure-capability-envelope-drift$' 'outer fixed envelope detects security drift created only after the real probe'
        Assert-TestCondition ([long]$fixedEnvelopeState.ProjectionCount -eq 2L -and [bool]$fixedEnvelopeState.SameLease -and [bool]$fixedEnvelopeState.Mutated) 'the same outer fixed-envelope lease is held from initial projection through both exact real probes and final projection'
        Assert-TestCondition (@([IO.Directory]::EnumerateFileSystemEntries($fixedEnvelopeProbeA)).Count -eq 0 -and
            @([IO.Directory]::EnumerateFileSystemEntries($fixedEnvelopeProbeB)).Count -eq 0) 'envelope-drift failure leaves no owned probe residue'
    }
    finally {
        Set-Item -LiteralPath Function:\Get-SealedHomeAuthorityFixedEnvelopeProjection -Value $fixedEnvelopeOriginalProjection
        if([bool]$fixedEnvelopeState.Mutated){Set-TestDirectoryCurrentUserOnly -Path ([string]$fixedEnvelopeFixture.Context.BackupRoot)}
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $fixedEnvelopeGlobal
    }

    $fixedLockFixture=New-TestRegistryFixture -Parent $workRoot -Name 'fixed-capability-lock-drift'
    $fixedLockProbeA=Join-Path $fixedLockFixture.Root 'probe-control'
    $fixedLockProbeB=Join-Path $fixedLockFixture.Root 'probe-backup'
    foreach($path in @($fixedLockProbeA,$fixedLockProbeB)){[IO.Directory]::CreateDirectory($path) | Out-Null}
    $fixedOldGlobal=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixedLockFixture.Context
    $fixedLockOriginalAssert=(Get-Command Assert-SealedHomeAuthorityGlobalLockWitness -CommandType Function -ErrorAction Stop).ScriptBlock
    $fixedLockState=[pscustomobject]@{AssertCalls=0L;OldReleased=$false;Replacement=$null}
    $fixedLockAssertShadow={
        param($AuthorityContext,$GlobalLockHandle)
        $fixedLockState.AssertCalls++
        if([long]$fixedLockState.AssertCalls -eq 3L){
            Exit-HomeAuthorityGlobalLiveLock -LockHandle $GlobalLockHandle
            $fixedLockState.OldReleased=$true
            $fixedLockState.Replacement=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $AuthorityContext
        }
        & $fixedLockOriginalAssert -AuthorityContext $AuthorityContext -GlobalLockHandle $GlobalLockHandle
    }.GetNewClosure()
    $fixedLockTreeBefore=Get-TestRegistryTreeHash -Fixture $fixedLockFixture
    try {
        Set-Item -LiteralPath Function:\Assert-SealedHomeAuthorityGlobalLockWitness -Value $fixedLockAssertShadow
        Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $fixedLockFixture.Context -GlobalLockHandle $fixedOldGlobal -CapabilityProbeBindings @(
            [ordered]@{Role='ControlBase';ProbeRoot=$fixedLockProbeA},[ordered]@{Role='BackupRoot';ProbeRoot=$fixedLockProbeB}
        ) | Out-Null } '^fixed-infrastructure-capability-lock-drift$' 'release and reacquire of the same global lock path fails the final exact lock-evidence comparison'
        Assert-TestCondition ([long]$fixedLockState.AssertCalls -eq 3L -and $null -ne $fixedLockState.Replacement -and
            -not [object]::ReferenceEquals($fixedOldGlobal,$fixedLockState.Replacement)) 'lock-drift fixture replaces the caller-held wrapper only at the final lock revalidation after exact real probes'
        Assert-TestCondition ((Get-TestRegistryTreeHash -Fixture $fixedLockFixture) -ceq $fixedLockTreeBefore -and
            @([IO.Directory]::EnumerateFileSystemEntries($fixedLockProbeA)).Count -eq 0 -and
            @([IO.Directory]::EnumerateFileSystemEntries($fixedLockProbeB)).Count -eq 0) 'lock-drift failure leaves the authority tree stable and no owned probe residue'
    }
    finally {
        Set-Item -LiteralPath Function:\Assert-SealedHomeAuthorityGlobalLockWitness -Value $fixedLockOriginalAssert
        if($null -ne $fixedLockState.Replacement){Exit-HomeAuthorityGlobalLiveLock -LockHandle $fixedLockState.Replacement}
        elseif(-not [bool]$fixedLockState.OldReleased){Exit-HomeAuthorityGlobalLiveLock -LockHandle $fixedOldGlobal}
    }

    $fixedReleasedFixture=New-TestRegistryFixture -Parent $workRoot -Name 'fixed-capability-released-lock'
    $fixedReleasedProbeA=Join-Path $fixedReleasedFixture.Root 'probe-control'
    $fixedReleasedProbeB=Join-Path $fixedReleasedFixture.Root 'probe-backup'
    foreach($path in @($fixedReleasedProbeA,$fixedReleasedProbeB)){[IO.Directory]::CreateDirectory($path) | Out-Null}
    $fixedReleasedOld=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixedReleasedFixture.Context
    Exit-HomeAuthorityGlobalLiveLock -LockHandle $fixedReleasedOld
    Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $fixedReleasedFixture.Context -GlobalLockHandle $fixedReleasedOld -CapabilityProbeBindings @(
        [ordered]@{Role='ControlBase';ProbeRoot=$fixedReleasedProbeA},[ordered]@{Role='BackupRoot';ProbeRoot=$fixedReleasedProbeB}
    ) | Out-Null } '^fixed-infrastructure-capability-lock-drift$' 'a released genuine global lock fails closed before fixed probing'
    $fixedReleasedReplacement=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixedReleasedFixture.Context
    try {
        Assert-ThrowsPattern { Invoke-SealedHeldFixedInfrastructureCapabilityCapture -AuthorityContext $fixedReleasedFixture.Context -GlobalLockHandle $fixedReleasedOld -CapabilityProbeBindings @(
            [ordered]@{Role='ControlBase';ProbeRoot=$fixedReleasedProbeA},[ordered]@{Role='BackupRoot';ProbeRoot=$fixedReleasedProbeB}
        ) | Out-Null } '^fixed-infrastructure-capability-lock-drift$' 'a released-and-reacquired lock path cannot authenticate the stale genuine wrapper'
    }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $fixedReleasedReplacement }

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
catch {
    $testPrimaryError = $_
    throw
}
finally {
    $resolvedWorkRoot = [IO.Path]::GetFullPath($workRoot)
    $resolvedParent = [IO.Path]::GetDirectoryName($resolvedWorkRoot).TrimEnd([char]92,[char]47)
    $leaf = [IO.Path]::GetFileName($resolvedWorkRoot)
    if ($resolvedParent -cne $tempParent -or $leaf -cnotmatch '^\.rcr-[0-9a-f]{32}$') {
        throw "unsafe registry test cleanup target: $resolvedWorkRoot"
    }
    if (Test-Path -LiteralPath $resolvedWorkRoot) {
        try { Remove-Item -LiteralPath $resolvedWorkRoot -Recurse -Force }
        catch {
            if ($null -eq $testPrimaryError) { throw }
            try { $testPrimaryError.Exception.Data['RootClaimsRegistryTestCleanupError'] = [string]$_.Exception.Message }
            catch { }
        }
    }
}
