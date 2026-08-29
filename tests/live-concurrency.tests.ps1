#requires -Version 7.0
[CmdletBinding()]
param([ValidateSet('all','bootstrap','crash','concurrency')][string]$Section='all')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
. (Join-Path $RepoRoot 'tests/helpers/home-authority-test-host.ps1')
. (Join-Path $RepoRoot 'tests/helpers/process-tree.ps1')

function Test-Section([string]$Name) { return $Section -ceq 'all' -or $Section -ceq $Name }
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
function Write-TestCreateNewFile([string]$Path,[byte[]]$Bytes) {
    $stream = [IO.File]::Open([IO.Path]::GetFullPath($Path),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try { $stream.Write($Bytes,0,$Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
}
function Write-TestMarker([string]$Path) { Write-TestCreateNewFile -Path $Path -Bytes ([Text.Encoding]::ASCII.GetBytes('go')) }
function Write-TestIntent([string]$Path,$Intent) { Write-TestCreateNewFile -Path $Path -Bytes (ConvertTo-SemanticJsonBytes -InputObject $Intent) }
function Wait-TestPath([string]$Path,[int]$TimeoutMilliseconds=15000,[Diagnostics.Process]$Process) {
    $watch = [Diagnostics.Stopwatch]::StartNew()
    while ($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        if ($null -ne $Process -and $Process.HasExited) { return $false }
        Start-Sleep -Milliseconds 10
    }
    return $false
}
function Wait-TestExit([Diagnostics.Process]$Process,[int]$TimeoutMilliseconds=15000) {
    if ($Process.WaitForExit($TimeoutMilliseconds)) { return $true }
    $null = Stop-ProcessTree -Process $Process
    return $false
}
function Read-TestMarkerText([string]$Path,[int]$TimeoutMilliseconds=5000) {
    $watch=[Diagnostics.Stopwatch]::StartNew()
    while($watch.ElapsedMilliseconds -lt $TimeoutMilliseconds) {
        try {
            $stream=[IO.File]::Open($Path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
            try { $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::UTF8,$true,1024,$true); try{$value=$reader.ReadToEnd()}finally{$reader.Dispose()} }
            finally { $stream.Dispose() }
            if(-not [string]::IsNullOrWhiteSpace($value)){return $value}
        }
        catch [IO.IOException] { }
        Start-Sleep -Milliseconds 10
    }
    throw "marker did not become readable: $Path"
}
function New-TestAuthorityFixture([string]$Root,[string]$ProfileName='profile',[switch]$DeferIntent) {
    $profile = Join-Path $Root $ProfileName
    $roaming = Join-Path $Root 'roaming'
    $local = Join-Path $Root 'local'
    foreach ($path in @($profile,$roaming,$local)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $context = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $profile -RoamingAppDataRoot $roaming -LocalAppDataRoot $local
    $intent = if($DeferIntent){$null}else{New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)}
    return [pscustomobject][ordered]@{ Root=$Root; Profile=$profile; Roaming=$roaming; Local=$local; Context=$context; Intent=$intent }
}
function Get-TestTreeHash([string]$Root,[string[]]$ExcludeRelativePaths=@()) { return [string](Get-SafeTreeSnapshot -Root $Root -ExcludeRelativePaths $ExcludeRelativePaths).TreeHash }
function New-TestCanonicalRouteFixture([string]$Root,[string]$Name,$AuthorityContext) {
    $repo = Join-Path $Root ($Name + '-repo')
    $probe = Join-Path $Root ($Name + '-probe')
    $recoveryParent = Join-Path $Root ($Name + '-recovery-parent')
    $recovery = Join-Path $recoveryParent 'recovery'
    [IO.Directory]::CreateDirectory($repo) | Out-Null
    [IO.Directory]::CreateDirectory($probe) | Out-Null
    [IO.Directory]::CreateDirectory($recoveryParent) | Out-Null
    Set-TestDirectoryCurrentUserOnly -Path $recoveryParent
    [IO.File]::WriteAllText((Join-Path $repo 'fixture.txt'),'canonical route fixture',[Text.UTF8Encoding]::new($false))
    & git init --quiet $repo
    if ($LASTEXITCODE -ne 0) { throw 'canonical route fixture git init failed' }
    & git -C $repo add fixture.txt
    if ($LASTEXITCODE -ne 0) { throw 'canonical route fixture git add failed' }
    & git -C $repo -c 'user.name=Canonical Route Fixture' -c 'user.email=canonical-route-fixture@example.invalid' commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'canonical route fixture git commit failed' }
    $payload = New-CanonicalSetupPlanPayload -RepoRoot $repo -CanonicalRecoveryRoot $recovery -ControlBase ([string]$AuthorityContext.ControlBase) -BackupRoot ([string]$AuthorityContext.BackupRoot) -ProbeRoot $probe -ToolchainRoot $RepoRoot
    [IO.Directory]::CreateDirectory($recovery) | Out-Null
    Set-TestDirectoryCurrentUserOnly -Path $recovery
    $git = Get-CanonicalGitContext -RepoRoot $repo
    $paths = Get-CanonicalTransactionContractPaths -GitContext $git
    $claimPath = Join-Path ([string]$AuthorityContext.CanonicalRootsRoot) ([string]$payload.ExpectedRootClaim.RepoId + '.json')
    $null = Write-TestCreateNewFile -Path $claimPath -Bytes ([byte[]](ConvertTo-SemanticJsonBytes -InputObject $payload.ExpectedRootClaim))
    $state = New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $repo
    $stateLock = Enter-CanonicalRepoLock -LockPath ([string]$paths.LockPath) -AllowCreate
    try { $null = Write-TestCreateNewFile -Path ([string]$paths.SetupStatePath) -Bytes ([byte[]](ConvertTo-SemanticJsonBytes -InputObject $state)) }
    finally { Exit-CanonicalRepoLock -LockHandle $stateLock }
    return [pscustomobject][ordered]@{
        RepoRoot=$repo; RepoId=[string]$payload.ExpectedRootClaim.RepoId
        LockPath=[string]$paths.LockPath; ClaimPath=$claimPath
    }
}
function Set-TestDirectoryCurrentUserOnly([string]$Path) {
    $sidText = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true,$false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inheritance,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}
function Set-TestDirectorySddl([string]$Path,[string]$Sddl) {
    $security = Get-Acl -LiteralPath $Path
    $security.SetSecurityDescriptorSddlForm($Sddl,[Security.AccessControl.AccessControlSections]::Access)
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new([IO.Path]::GetFullPath($Path)),$security)
}
function Start-TestHost {
    param(
        [Parameter(Mandatory)]$Fixture,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$OutputBase,
        [string]$IntentPath,
        [string]$ReadyMarker,
        [string]$StartMarker,
        [string]$AcquiredMarker,
        [string]$ContendedMarker,
        [string]$ReleaseMarker,
        [string]$CrashStage,
        [int]$CrashOrder,
        [int]$WaitSeconds,
        [string]$WorkingDirectory,
        [string]$CanonicalRepoRoot
    )
    $arguments = @('-NoProfile','-File',(Join-Path $RepoRoot 'tests/helpers/home-authority-bootstrap-host.ps1'),'-ToolchainRoot',$RepoRoot,'-ProfileRoot',$Fixture.Profile,'-RoamingAppDataRoot',$Fixture.Roaming,'-LocalAppDataRoot',$Fixture.Local,'-Operation',$Operation)
    foreach ($pair in @(
        @('IntentPath',$IntentPath),@('ReadyMarker',$ReadyMarker),@('StartMarker',$StartMarker),
        @('AcquiredMarker',$AcquiredMarker),@('ContendedMarker',$ContendedMarker),
        @('ReleaseMarker',$ReleaseMarker),@('CrashStage',$CrashStage),@('RepoRoot',$CanonicalRepoRoot)
    )) { if (-not [string]::IsNullOrWhiteSpace([string]$pair[1])) { $arguments += @("-$($pair[0])",[string]$pair[1]) } }
    if ($PSBoundParameters.ContainsKey('CrashOrder')) { $arguments += @('-CrashOrder',[string]$CrashOrder) }
    if ($PSBoundParameters.ContainsKey('WaitSeconds')) { $arguments += @('-WaitSeconds',[string]$WaitSeconds) }
    $start = @{
        FilePath=(Get-Command pwsh).Source; ArgumentList=$arguments; PassThru=$true; WindowStyle='Hidden'
        RedirectStandardOutput="$OutputBase.out"; RedirectStandardError="$OutputBase.err"
    }
    if ($WorkingDirectory) {
        $start.WorkingDirectory=$WorkingDirectory
        $arguments += @('-ExpectedWorkingDirectory',$WorkingDirectory)
        $start.ArgumentList=$arguments
    }
    return Start-Process @start
}
function Read-TestProcessError([string]$OutputBase) {
    if (-not (Test-Path -LiteralPath "$OutputBase.err" -PathType Leaf)) { return '' }
    return ([IO.File]::ReadAllText("$OutputBase.err")).Trim()
}

$tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([char]92,[char]47)
$work = Join-Path $tempRoot ('.ai-agent-dotfiles-live-concurrency-' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($work) | Out-Null
$processes = [Collections.Generic.List[Diagnostics.Process]]::new()
$testFailure = $null
try {
    if (Test-Section 'bootstrap') {
        Write-Host '[sealed bootstrap completion and existing-only global lock]'
        $homeSource=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/home-authority-common.ps1'))
        $safeTreeSource=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/safe-tree-walker.ps1'))
        Assert-TestCondition ($homeSource -notmatch '(?im)\bSet-Acl\b|Directory\]\:\:CreateDirectory') 'bootstrap implementation has no create-then-SetAcl or path-based directory creation fallback'
        Assert-TestCondition ($safeTreeSource -match 'CreateChildDirectoryWithSecurityDescriptor[\s\S]*?FILE_CREATE[\s\S]*?securityDescriptorSddl' -and $safeTreeSource -match 'SecurityDescriptor\s*=\s*securityDescriptorPointer') 'secured directory creation is one held-parent-relative FILE_CREATE with the final descriptor'
        $globalCommand=Get-Command Enter-HomeAuthorityGlobalLiveLock -ErrorAction Stop
        $globalExplicitParameters = @($globalCommand.ScriptBlock.Ast.Body.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
        Assert-TestCondition (($globalExplicitParameters -join ',') -ceq 'AuthorityContext,RequiredCanonicalWitness') 'global acquisition exposes only AuthorityContext plus the optional caller-held canonical witness'
        $fixture = New-TestAuthorityFixture -Root (Join-Path $work 'bootstrap')
        Assert-TestCondition ([string]$fixture.Intent.InitialBootstrapStatus -ceq 'MISSING' -and [long]$fixture.Intent.InitialCompletePrefixLength -eq 0) 'fresh reviewed intent binds a wholly missing deterministic prefix'
        Assert-TestCondition (-not (Test-Path -LiteralPath $fixture.Context.ControlBootstrapLockPath) -and -not (Test-Path -LiteralPath $fixture.Context.PrivateRootBase)) 'read-only intent creates no bootstrap lock or private prefix'
        $beforeMissing = Get-TestTreeHash -Root $fixture.Local
        Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixture.Context | Out-Null } 'global-live-lock-missing|bootstrap-incomplete' 'existing-only global acquisition rejects a missing prefix'
        Assert-TestCondition ((Get-TestTreeHash -Root $fixture.Local) -ceq $beforeMissing) 'missing existing-only acquisition has zero filesystem side effects'

        $lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $fixture.Context -Intent $fixture.Intent
        try {
            $complete = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $fixture.Context
            Assert-TestCondition ([string]$complete.Status -ceq 'COMPLETE' -and [long]$complete.CompletePrefixLength -eq 7) 'six fixed directories plus the global lock form one COMPLETE prefix'
            Assert-TestCondition ([string](Resolve-SealedHomeAuthorityTestContext -TokenSid ([string]$fixture.Context.TokenSid) -ProfileRoot $fixture.Profile -RoamingAppDataRoot $fixture.Roaming -LocalAppDataRoot $fixture.Local).PrivateRootBootstrapStatus -ceq 'PARTIAL') 'production read-only metadata status still does not grant COMPLETE from existence alone'
            $watch = [Diagnostics.Stopwatch]::StartNew()
            Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixture.Context | Out-Null } '^operation-lock-busy$' 'a concurrent global loser is exact zero-wait busy'
            Assert-TestCondition ($watch.ElapsedMilliseconds -lt 1000) 'zero-wait lock loss returns within one second'
            $deleteBlocked = $false
            try { [IO.File]::Delete([string]$fixture.Context.GlobalLiveLockPath) }
            catch [IO.IOException] { $deleteBlocked = $true }
            Assert-TestCondition $deleteBlocked 'held global lock metadata cannot be deleted to steal the lock'
            $firstIdentity = [string]$lock.Info.Identity
        }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
        $reopened = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $fixture.Context
        try { Assert-TestCondition ([string]$reopened.Info.Identity -ceq $firstIdentity) 'existing-only reopen preserves the global lock identity' }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $reopened }
        $idempotent = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $fixture.Context -Intent $fixture.Intent
        try { Assert-TestCondition ([string]$idempotent.Info.Identity -ceq $firstIdentity) 'the same reviewed intent idempotently re-enters the complete prefix' }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $idempotent }

        Write-Host '[bootstrap fail-closed topology and security]'
        $wrongAcl = New-TestAuthorityFixture -Root (Join-Path $work 'wrong-acl')
        $bootstrapOnly = Enter-SealedHomeAuthorityBootstrapLock -AuthorityContext $wrongAcl.Context -Intent $wrongAcl.Intent
        Exit-HomeAuthorityLockHandle -LockHandle $bootstrapOnly
        [IO.Directory]::CreateDirectory([string]$wrongAcl.Context.PrivateRootBase) | Out-Null
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $wrongAcl.Context -Intent $wrongAcl.Intent | Out-Null } 'manual-recovery-required|owner-dacl-mismatch' 'an inherited or wrong ACL is manual recovery, never silent repair'

        $callbackAcl = New-TestAuthorityFixture -Root (Join-Path $work 'callback-acl')
        $callbackLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $callbackAcl.Context -Intent $callbackAcl.Intent
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $callbackLock
        $callbackSid = [string]$callbackAcl.Context.TokenSid
        $callbackDacl = "D:P(XA;OICI;FA;;;$callbackSid;(Member_of {SID(WD)}))"
        $callbackSddl = "O:$callbackSid" + "G:$callbackSid" + $callbackDacl
        $syntheticCallbackSnapshot = [pscustomobject]@{ Identity='synthetic-callback'; LinkCount=1L; Sddl=$callbackSddl }
        Assert-ThrowsPattern { Assert-HomeAuthoritySecuritySnapshot -Snapshot $syntheticCallbackSnapshot -SecurityTemplate $callbackAcl.Intent.DirectorySecurityTemplate -ExpectedIdentity 'synthetic-callback' | Out-Null } 'security-entry-unsupported' 'a synthetic callback or opaque ACE cannot normalize to an ordinary allow ACE'
        Set-TestDirectorySddl -Path ([string]$callbackAcl.Context.PrivateRootBase) -Sddl $callbackDacl
        Assert-ThrowsPattern { Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $callbackAcl.Context | Out-Null } 'manual-recovery-required.*security-entry-unsupported' 'a real NTFS callback ACE is rejected as manual recovery'

        $extra = New-TestAuthorityFixture -Root (Join-Path $work 'extra')
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $extra.Context -Intent $extra.Intent -AfterCreate { param($entry); if([long]$entry.Order -eq 0){throw 'fixture-stop'} } | Out-Null } '^fixture-stop$' 'fixture stops after the first atomically secured directory'
        [IO.File]::WriteAllText((Join-Path $extra.Context.PrivateRootBase 'foreign.txt'),'foreign',[Text.UTF8Encoding]::new($false))
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $extra.Context -Intent $extra.Intent | Out-Null } 'manual-recovery-required.*unexpected children' 'an extra private-prefix child is manual recovery'

        $hole = New-TestAuthorityFixture -Root (Join-Path $work 'hole')
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $hole.Context -Intent $hole.Intent -AfterCreate { param($entry); if([long]$entry.Order -eq 0){throw 'fixture-stop'} } | Out-Null } '^fixture-stop$' 'hole fixture retains one exact secure prefix entry'
        [IO.Directory]::CreateDirectory([string]$hole.Context.ControlBase) | Out-Null
        Set-TestDirectoryCurrentUserOnly -Path ([string]$hole.Context.ControlBase)
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $hole.Context -Intent $hole.Intent | Out-Null } 'manual-recovery-required.*non-prefix' 'a bootstrap hole cannot be completed or reclassified as partial'

        $wrongType = New-TestAuthorityFixture -Root (Join-Path $work 'wrong-type')
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $wrongType.Context -Intent $wrongType.Intent -AfterCreate { param($entry); if([long]$entry.Order -eq 5){throw 'fixture-stop'} } | Out-Null } '^fixture-stop$' 'wrong-type fixture reaches the final lock slot only'
        [IO.Directory]::CreateDirectory([string]$wrongType.Context.GlobalLiveLockPath) | Out-Null
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $wrongType.Context -Intent $wrongType.Intent | Out-Null } 'manual-recovery-required.*wrong type' 'a directory at the global lock slot is manual recovery'

        $wrongBootstrapType = New-TestAuthorityFixture -Root (Join-Path $work 'wrong-bootstrap-type') -DeferIntent
        [IO.Directory]::CreateDirectory([string]$wrongBootstrapType.Context.ControlBootstrapLockPath) | Out-Null
        Assert-ThrowsPattern { New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $wrongBootstrapType.Context -FilesystemCapabilityHash ('a'*64) | Out-Null } 'manual-recovery-required.*wrong type' 'a directory at the external bootstrap-lock slot is manual recovery'

        $wrongBootstrapAcl = New-TestAuthorityFixture -Root (Join-Path $work 'wrong-bootstrap-acl') -DeferIntent
        [IO.File]::WriteAllBytes([string]$wrongBootstrapAcl.Context.ControlBootstrapLockPath,[byte[]]@())
        Assert-ThrowsPattern { New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $wrongBootstrapAcl.Context -FilesystemCapabilityHash ('a'*64) | Out-Null } 'manual-recovery-required.*owner-dacl-mismatch' 'a pre-existing bootstrap lock with inherited ACL is rejected read-only'

        $reparse = New-TestAuthorityFixture -Root (Join-Path $work 'reparse') -DeferIntent
        $reparseTarget = Join-Path $reparse.Root 'outside-target'; [IO.Directory]::CreateDirectory($reparseTarget)|Out-Null
        $null = New-Item -ItemType Junction -Path ([string]$reparse.Context.PrivateRootBase) -Target $reparseTarget
        Assert-ThrowsPattern { New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $reparse.Context -FilesystemCapabilityHash ('a'*64) | Out-Null } 'manual-recovery-required.*wrong type' 'a reparse point at a deterministic directory slot is rejected without traversal'
        [IO.Directory]::Delete([string]$reparse.Context.PrivateRootBase)

        $hardlink = New-TestAuthorityFixture -Root (Join-Path $work 'hardlink')
        $hardlinkLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $hardlink.Context -Intent $hardlink.Intent
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $hardlinkLock
        $hardlinkAlias = Join-Path $hardlink.Local 'lock-alias'
        $null = New-Item -ItemType HardLink -Path $hardlinkAlias -Target ([string]$hardlink.Context.GlobalLiveLockPath)
        Assert-ThrowsPattern { Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $hardlink.Context | Out-Null } 'manual-recovery-required.*lock file contract mismatch' 'a second hard link invalidates the global lock contract'
        [IO.File]::Delete($hardlinkAlias)

        $ads = New-TestAuthorityFixture -Root (Join-Path $work 'ads')
        $adsLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $ads.Context -Intent $ads.Intent
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $adsLock
        [IO.File]::WriteAllText(([string]$ads.Context.GlobalLiveLockPath + ':foreign'),'foreign',[Text.UTF8Encoding]::new($false))
        Assert-ThrowsPattern { Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $ads.Context | Out-Null } 'manual-recovery-required.*named streams' 'an alternate data stream invalidates the global lock contract'

        $identityDrift = New-TestAuthorityFixture -Root (Join-Path $work 'identity-drift')
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $identityDrift.Context -Intent $identityDrift.Intent -AfterCreate { param($entry); if([long]$entry.Order -eq 0){throw 'fixture-stop'} } | Out-Null } '^fixture-stop$' 'identity fixture records one completed reviewed entry'
        $reviewedAgain = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $identityDrift.Context -FilesystemCapabilityHash ('a' * 64)
        [IO.Directory]::Delete([string]$identityDrift.Context.PrivateRootBase,$true)
        [IO.Directory]::CreateDirectory([string]$identityDrift.Context.PrivateRootBase) | Out-Null
        Set-TestDirectoryCurrentUserOnly -Path ([string]$identityDrift.Context.PrivateRootBase)
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $identityDrift.Context -Intent $reviewedAgain | Out-Null } 'reviewed-entry-drift' 'delete-and-recreate identity drift is rejected despite matching ACL'
    }

    if (Test-Section 'crash') {
        Write-Host '[hard-kill before/after every deterministic bootstrap creation]'
        foreach ($stage in @('before','after')) {
            foreach ($order in 0..6) {
                $caseRoot = Join-Path $work ("crash-$stage-$order")
                $fixture = New-TestAuthorityFixture -Root $caseRoot
                $intentPath = Join-Path $caseRoot 'intent.json'
                Write-TestIntent -Path $intentPath -Intent $fixture.Intent
                $marker = Join-Path $caseRoot 'checkpoint.marker'
                $output = Join-Path $caseRoot 'host'
                $process = Start-TestHost -Fixture $fixture -Operation crash-complete -OutputBase $output -IntentPath $intentPath -AcquiredMarker $marker -CrashStage $stage -CrashOrder $order
                $processes.Add($process)
                if (-not (Wait-TestPath -Path $marker -Process $process)) { throw "FAIL: crash host did not reach $stage/$order ($(Read-TestProcessError $output))" }
                $process.Refresh()
                Assert-TestCondition (-not $process.HasExited) "crash host remains alive at the durable $stage/$order checkpoint"
                Assert-TestCondition ((Read-TestMarkerText $marker) -ceq "$stage/$order") "crash marker exactly identifies the $stage/$order boundary"
                $atCheckpoint = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $fixture.Context
                $expectedPrefixLength = if ($stage -ceq 'before') { [long]$order } else { [long]$order + 1L }
                $expectedCheckpointStatus = if ($expectedPrefixLength -eq 7L) { 'COMPLETE' } else { 'PARTIAL' }
                Assert-TestCondition ([string]$atCheckpoint.BootstrapLock.Status -ceq 'COMPLETE') "external bootstrap lock is complete at $stage/$order"
                Assert-TestCondition ([long]$atCheckpoint.CompletePrefixLength -eq $expectedPrefixLength -and [string]$atCheckpoint.Status -ceq $expectedCheckpointStatus) "disk state is the exact deterministic prefix at $stage/$order"
                Assert-TestCondition (Stop-ProcessTree -Process $process) "hard kill releases all bootstrap handles at $stage/$order"
                $beforeResume = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $fixture.Context
                Assert-TestCondition ([string]$beforeResume.SnapshotHash -ceq [string]$atCheckpoint.SnapshotHash) "hard kill leaves the durable prefix unchanged at $stage/$order"
                $heldIdentities = @{}
                foreach ($entry in @($beforeResume.Entries | Where-Object { [string]$_.Status -ceq 'COMPLETE' })) { $heldIdentities[[string]$entry.Name]=[string]$entry.Identity }
                $resumed = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $fixture.Context -Intent $fixture.Intent
                try { $afterResume = Get-SealedHomeAuthorityBootstrapSnapshot -AuthorityContext $fixture.Context -DirectorySecurityTemplate $fixture.Intent.DirectorySecurityTemplate -FileSecurityTemplate $fixture.Intent.LockFileSecurityTemplate -HeldGlobalLock $resumed }
                finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $resumed }
                Assert-TestCondition ([string]$afterResume.Status -ceq 'COMPLETE') "same reviewed intent completes the exact $stage/$order crash prefix"
                foreach ($name in $heldIdentities.Keys) {
                    $afterEntry = @($afterResume.Entries | Where-Object { [string]$_.Name -ceq $name })[0]
                    Assert-TestCondition ([string]$afterEntry.Identity -ceq [string]$heldIdentities[$name]) "pre-crash identity $name is preserved at $stage/$order"
                }
            }
        }
    }

    if (Test-Section 'concurrency') {
        Write-Host '[two-repository first bootstrap contention]'
        $raceRoot = Join-Path $work 'two-repo-race'
        $fixture = New-TestAuthorityFixture -Root $raceRoot
        $repoA = Join-Path $raceRoot 'repo-a'; $repoB = Join-Path $raceRoot 'repo-b'
        [IO.Directory]::CreateDirectory($repoA)|Out-Null; [IO.Directory]::CreateDirectory($repoB)|Out-Null
        & git -C $repoA init -q; if($LASTEXITCODE -ne 0){throw 'fixture repo A init failed'}
        & git -C $repoB init -q; if($LASTEXITCODE -ne 0){throw 'fixture repo B init failed'}
        $intentPath = Join-Path $raceRoot 'intent.json'; Write-TestIntent -Path $intentPath -Intent $fixture.Intent
        $start = Join-Path $raceRoot 'start.marker'; $release = Join-Path $raceRoot 'release.marker'
        $readyA = Join-Path $raceRoot 'ready-a'; $readyB = Join-Path $raceRoot 'ready-b'
        $acquiredA = Join-Path $raceRoot 'acquired-a'; $acquiredB = Join-Path $raceRoot 'acquired-b'
        $outputA = Join-Path $raceRoot 'race-a'; $outputB = Join-Path $raceRoot 'race-b'
        $processA = Start-TestHost -Fixture $fixture -Operation complete-hold -OutputBase $outputA -IntentPath $intentPath -ReadyMarker $readyA -StartMarker $start -AcquiredMarker $acquiredA -ReleaseMarker $release -WorkingDirectory $repoA
        $processB = Start-TestHost -Fixture $fixture -Operation complete-hold -OutputBase $outputB -IntentPath $intentPath -ReadyMarker $readyB -StartMarker $start -AcquiredMarker $acquiredB -ReleaseMarker $release -WorkingDirectory $repoB
        $processes.Add($processA); $processes.Add($processB)
        Assert-TestCondition ((Wait-TestPath $readyA -Process $processA) -and (Wait-TestPath $readyB -Process $processB)) 'both repository processes become ready before first bootstrap'
        $readyEvidenceA = @((Read-TestMarkerText $readyA) -split '\|')
        $readyEvidenceB = @((Read-TestMarkerText $readyB) -split '\|')
        Assert-TestCondition ($readyEvidenceA.Count -eq 5 -and $readyEvidenceB.Count -eq 5 -and $readyEvidenceA[0] -ceq 'ready' -and $readyEvidenceB[0] -ceq 'ready') 'both repository ready markers carry complete reviewed evidence'
        Assert-TestCondition ($readyEvidenceA[1] -ceq [string]$fixture.Intent.IntentHash -and $readyEvidenceB[1] -ceq [string]$fixture.Intent.IntentHash -and $readyEvidenceA[2] -ceq 'MISSING' -and $readyEvidenceB[2] -ceq 'MISSING' -and $readyEvidenceA[3] -ceq '0' -and $readyEvidenceB[3] -ceq '0') 'both repository processes validate the same reviewed missing intent before start'
        Assert-TestCondition (-not $readyEvidenceA[4].Equals($readyEvidenceB[4],[StringComparison]::OrdinalIgnoreCase)) 'the contenders are two distinct Git repository identities'
        $loserWatch = [Diagnostics.Stopwatch]::StartNew()
        Write-TestMarker $start
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while ($watch.ElapsedMilliseconds -lt 15000 -and -not (Test-Path $acquiredA) -and -not (Test-Path $acquiredB) -and -not ($processA.HasExited -and $processB.HasExited)) { Start-Sleep -Milliseconds 10 }
        $winnerA = Test-Path -LiteralPath $acquiredA -PathType Leaf
        $winnerB = Test-Path -LiteralPath $acquiredB -PathType Leaf
        Assert-TestCondition ($winnerA -xor $winnerB) 'exactly one repository acquires the first global lock handoff'
        $loser = if($winnerA){$processB}else{$processA}; $loserOutput = if($winnerA){$outputB}else{$outputA}
        $postWinnerLoserWatch = [Diagnostics.Stopwatch]::StartNew()
        Assert-TestCondition (Wait-TestExit -Process $loser) 'the losing repository exits without waiting for the winner'
        Assert-TestCondition ($loser.ExitCode -eq 1 -and (Read-TestProcessError $loserOutput) -ceq 'operation-lock-busy') 'the first-bootstrap loser returns exact operation-lock-busy'
        Assert-TestCondition ($postWinnerLoserWatch.ElapsedMilliseconds -lt 1500) 'the first-bootstrap loser remains zero-wait after winner acquisition is observed'
        Assert-TestCondition ($loserWatch.ElapsedMilliseconds -lt 3000) 'the whole first-bootstrap loser path is bounded after the coordinated start'
        Write-TestMarker $release
        $winner = if($winnerA){$processA}else{$processB}
        Assert-TestCondition ((Wait-TestExit -Process $winner) -and $winner.ExitCode -eq 0) 'the first-bootstrap winner releases the completed global lock normally'
        $raceComplete = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $fixture.Context
        Assert-TestCondition ([string]$raceComplete.Status -ceq 'COMPLETE' -and [long]$raceComplete.CompletePrefixLength -eq 7) 'the race leaves only the exact sealed bootstrap topology'

        Write-Host '[cross-authority zero-wait, bounded wait, and owner death]'
        $otherProfile = Join-Path $raceRoot 'other-profile'; [IO.Directory]::CreateDirectory($otherProfile)|Out-Null
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $otherContext = Resolve-SealedHomeAuthorityTestContext -TokenSid $sid -ProfileRoot $otherProfile -RoamingAppDataRoot $fixture.Roaming -LocalAppDataRoot $fixture.Local
        Assert-TestCondition ([string]$otherContext.HomeAuthorityKey -cne [string]$fixture.Context.HomeAuthorityKey -and [string]$otherContext.GlobalLiveLockPath -ceq [string]$fixture.Context.GlobalLiveLockPath) 'different authorities share the one ControlBase global lock'

        $ownerReady = Join-Path $raceRoot 'owner-ready'; $ownerRelease = Join-Path $raceRoot 'owner-release'; $ownerOutput=Join-Path $raceRoot 'owner'
        $owner = Start-TestHost -Fixture $fixture -Operation global-hold -OutputBase $ownerOutput -AcquiredMarker $ownerReady -ReleaseMarker $ownerRelease
        $processes.Add($owner)
        Assert-TestCondition (Wait-TestPath $ownerReady -Process $owner) 'global owner publishes an acquired marker from the held handle'
        $lockIdentity = Read-TestMarkerText $ownerReady
        $activeLockRelative = [IO.Path]::GetRelativePath([string]$fixture.Local,[string]$fixture.Context.GlobalLiveLockPath).Replace([char]92,[char]47)
        $snapshotBeforeBusy = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $fixture.Context
        $treeBeforeBusy = Get-TestTreeHash -Root $fixture.Local -ExcludeRelativePaths @($activeLockRelative)
        Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $otherContext | Out-Null } '^operation-lock-busy$' 'another HomeAuthority loses the same global lock with zero wait'
        $snapshotAfterBusy = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $fixture.Context
        $treeAfterBusy = Get-TestTreeHash -Root $fixture.Local -ExcludeRelativePaths @($activeLockRelative)
        Assert-TestCondition ($treeAfterBusy -ceq $treeBeforeBusy -and [string]$snapshotAfterBusy.SnapshotHash -ceq [string]$snapshotBeforeBusy.SnapshotHash) 'a global-lock loser makes zero writes anywhere in the controlled fake home'

        $timeoutMarker=Join-Path $raceRoot 'timeout-waiter-acquired';$timeoutOutput=Join-Path $raceRoot 'timeout-waiter'
        $timeoutReady=Join-Path $raceRoot 'timeout-waiter-ready';$timeoutStart=Join-Path $raceRoot 'timeout-waiter-start';$timeoutContended=Join-Path $raceRoot 'timeout-waiter-contended'
        $otherFixture=[pscustomobject]@{Profile=$otherProfile;Roaming=$fixture.Roaming;Local=$fixture.Local}
        $timeoutWaiter=Start-TestHost -Fixture $otherFixture -Operation global-wait -OutputBase $timeoutOutput -ReadyMarker $timeoutReady -StartMarker $timeoutStart -AcquiredMarker $timeoutMarker -ContendedMarker $timeoutContended -WaitSeconds 1
        $processes.Add($timeoutWaiter)
        Assert-TestCondition (Wait-TestPath $timeoutReady -Process $timeoutWaiter) 'sealed timeout waiter is prewarmed before the measured interval'
        $timeoutWatch=[Diagnostics.Stopwatch]::StartNew()
        Write-TestMarker $timeoutStart
        Assert-TestCondition ((Wait-TestPath $timeoutContended -Process $timeoutWaiter) -and (Read-TestMarkerText $timeoutContended) -ceq 'operation-lock-busy' -and -not $owner.HasExited) 'sealed timeout waiter proves contention while the owner remains alive'
        Assert-TestCondition ((Wait-TestExit $timeoutWaiter) -and $timeoutWaiter.ExitCode -eq 1 -and (Read-TestProcessError $timeoutOutput) -ceq 'operation-lock-busy') 'sealed bounded waiter times out with exact busy while the owner remains alive'
        Assert-TestCondition (-not (Test-Path $timeoutMarker) -and $timeoutWatch.ElapsedMilliseconds -ge 800 -and $timeoutWatch.ElapsedMilliseconds -lt 2500) 'bounded-wait timeout never enters and honors the one-second test-only wait interval'

        $waiterMarker=Join-Path $raceRoot 'waiter-acquired';$waiterOutput=Join-Path $raceRoot 'waiter'
        $waiterReady=Join-Path $raceRoot 'waiter-ready';$waiterStart=Join-Path $raceRoot 'waiter-start';$waiterContended=Join-Path $raceRoot 'waiter-contended'
        $waiter=Start-TestHost -Fixture $otherFixture -Operation global-wait -OutputBase $waiterOutput -ReadyMarker $waiterReady -StartMarker $waiterStart -AcquiredMarker $waiterMarker -ContendedMarker $waiterContended -WaitSeconds 3
        $processes.Add($waiter)
        Assert-TestCondition (Wait-TestPath $waiterReady -Process $waiter) 'sealed success waiter is prewarmed before contention'
        Write-TestMarker $waiterStart
        Assert-TestCondition ((Wait-TestPath $waiterContended -Process $waiter) -and (Read-TestMarkerText $waiterContended) -ceq 'operation-lock-busy' -and -not $owner.HasExited -and -not (Test-Path -LiteralPath $waiterMarker)) 'sealed bounded waiter does not enter while the owner is alive'
        Write-TestMarker $ownerRelease
        Assert-TestCondition ((Wait-TestExit $owner) -and (Wait-TestPath $waiterMarker -Process $waiter) -and (Wait-TestExit $waiter) -and $waiter.ExitCode -eq 0) 'sealed bounded waiter acquires only after normal owner release'
        Assert-TestCondition ((Read-TestMarkerText $waiterMarker) -ceq $lockIdentity) 'bounded wait reopens the same immutable lock file'

        $deathReady=Join-Path $raceRoot 'death-ready';$deathOutput=Join-Path $raceRoot 'death-owner'
        $deathOwner=Start-TestHost -Fixture $fixture -Operation global-hold -OutputBase $deathOutput -AcquiredMarker $deathReady
        $processes.Add($deathOwner)
        Assert-TestCondition (Wait-TestPath $deathReady -Process $deathOwner) 'owner-death fixture holds the existing global lock'
        Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $otherContext | Out-Null } '^operation-lock-busy$' 'global lock remains busy until the owner process dies'
        $deathOwner.Refresh()
        Assert-TestCondition (-not $deathOwner.HasExited) 'global lock owner is alive immediately before the forced process-tree kill'
        Assert-TestCondition (Stop-ProcessTree -Process $deathOwner) 'hard kill terminates the global lock owner process tree'
        $afterDeath=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $otherContext
        try { Assert-TestCondition ([string]$afterDeath.Info.Identity -ceq $lockIdentity) 'OS owner death releases the handle without recreating lock metadata' }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $afterDeath }

        $bootstrapDeathRoot=Join-Path $work 'bootstrap-owner-death';$bootstrapFixture=New-TestAuthorityFixture -Root $bootstrapDeathRoot
        $bootstrapIntentPath=Join-Path $bootstrapDeathRoot 'intent.json';Write-TestIntent $bootstrapIntentPath $bootstrapFixture.Intent
        $bootstrapReady=Join-Path $bootstrapDeathRoot 'ready';$bootstrapOutput=Join-Path $bootstrapDeathRoot 'owner'
        $bootstrapOwner=Start-TestHost -Fixture $bootstrapFixture -Operation bootstrap-hold -OutputBase $bootstrapOutput -IntentPath $bootstrapIntentPath -AcquiredMarker $bootstrapReady
        $processes.Add($bootstrapOwner)
        Assert-TestCondition (Wait-TestPath $bootstrapReady -Process $bootstrapOwner) 'bootstrap owner holds the no-follow pre-ControlBase lock'
        $bootstrapIdentity=Read-TestMarkerText $bootstrapReady
        Assert-ThrowsPattern { Complete-SealedHomeAuthorityBootstrap -AuthorityContext $bootstrapFixture.Context -Intent $bootstrapFixture.Intent | Out-Null } '^operation-lock-busy$' 'bootstrap contention is also zero-wait'
        $bootstrapOwner.Refresh()
        Assert-TestCondition (-not $bootstrapOwner.HasExited) 'bootstrap lock owner is alive immediately before the forced process-tree kill'
        Assert-TestCondition (Stop-ProcessTree -Process $bootstrapOwner) 'hard kill terminates the bootstrap lock owner'
        $afterBootstrapDeath=Complete-SealedHomeAuthorityBootstrap -AuthorityContext $bootstrapFixture.Context -Intent $bootstrapFixture.Intent
        try { Assert-TestCondition ((Get-NoFollowRootEntryMarker -Path $bootstrapFixture.Context.ControlBootstrapLockPath).Identity -ceq $bootstrapIdentity) 'bootstrap owner death releases the same external lock identity' }
        finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $afterBootstrapDeath }

        Write-Host '[canonical-bound global lock versus live and second-repository routes]'
        $canonicalRaceRoot = Join-Path $work 'canonical-global-race'
        $canonicalFixture = New-TestAuthorityFixture -Root $canonicalRaceRoot
        $canonicalBootstrap = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $canonicalFixture.Context -Intent $canonicalFixture.Intent
        Exit-HomeAuthorityGlobalLiveLock -LockHandle $canonicalBootstrap
        $canonicalRepoA = New-TestCanonicalRouteFixture -Root $canonicalRaceRoot -Name 'route-a' -AuthorityContext $canonicalFixture.Context
        $canonicalRepoB = New-TestCanonicalRouteFixture -Root $canonicalRaceRoot -Name 'route-b' -AuthorityContext $canonicalFixture.Context
        Assert-TestCondition ($canonicalRepoA.RepoId -cne $canonicalRepoB.RepoId -and $canonicalRepoA.ClaimPath -cne $canonicalRepoB.ClaimPath) 'the two canonical route fixtures are distinct repository identities with distinct claims'
        $holderReady = Join-Path $canonicalRaceRoot 'holder-ready'
        $holderStart = Join-Path $canonicalRaceRoot 'holder-start'
        $holderAcquired = Join-Path $canonicalRaceRoot 'holder-acquired'
        $holderRelease = Join-Path $canonicalRaceRoot 'holder-release'
        $holderOutput = Join-Path $canonicalRaceRoot 'holder'
        $holder = Start-TestHost -Fixture $canonicalFixture -Operation canonical-global-hold -OutputBase $holderOutput -CanonicalRepoRoot $canonicalRepoA.RepoRoot -ReadyMarker $holderReady -StartMarker $holderStart -AcquiredMarker $holderAcquired -ReleaseMarker $holderRelease
        $processes.Add($holder)
        Assert-TestCondition (Wait-TestPath $holderReady -Process $holder) 'the canonical-bound holder becomes ready before acquisition'
        Write-TestMarker $holderStart
        Assert-TestCondition (Wait-TestPath $holderAcquired -Process $holder) 'the canonical-bound holder acquires the global lock through its held canonical witness'
        $canonicalGlobalIdentity = Read-TestMarkerText $holderAcquired
        $canonicalLockRelative = [IO.Path]::GetRelativePath([string]$canonicalFixture.Local,[string]$canonicalFixture.Context.GlobalLiveLockPath).Replace([char]92,[char]47)
        $canonicalTreeBefore = Get-TestTreeHash -Root $canonicalFixture.Local -ExcludeRelativePaths @($canonicalLockRelative)
        Assert-ThrowsPattern { Enter-CanonicalRepoLock -LockPath ([string]$canonicalRepoA.LockPath) | Out-Null } '^operation-lock-busy$' 'the holder keeps its canonical repository lock while holding global'
        $liveRouteWatch = [Diagnostics.Stopwatch]::StartNew()
        Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $canonicalFixture.Context | Out-Null } '^operation-lock-busy$' 'a live-route global acquisition loses to the canonical-bound holder with exact zero-wait busy'
        Assert-TestCondition ($liveRouteWatch.ElapsedMilliseconds -lt 1000) 'the losing live route is zero-wait bounded'
        Assert-TestCondition ((Get-TestTreeHash -Root $canonicalFixture.Local -ExcludeRelativePaths @($canonicalLockRelative)) -ceq $canonicalTreeBefore) 'the losing live route makes zero writes in the controlled fake home'
        $secondLock = Enter-CanonicalRepoLock -LockPath ([string]$canonicalRepoB.LockPath)
        $secondWitness = $null
        try {
            $secondWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$canonicalRepoB.RepoRoot) -CanonicalLockHandle $secondLock -ToolchainRoot $RepoRoot
            Assert-ThrowsPattern { Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $canonicalFixture.Context -RequiredCanonicalWitness $secondWitness | Out-Null } '^operation-lock-busy$' 'a second-repository canonical route acquires its own canonical lock and contends only at the global lock'
        }
        finally {
            if ($null -ne $secondWitness) { Close-CanonicalHeldNamespaceWitness -Witness $secondWitness }
            Exit-CanonicalRepoLock -LockHandle $secondLock
        }
        Assert-TestCondition ((Get-TestTreeHash -Root $canonicalFixture.Local -ExcludeRelativePaths @($canonicalLockRelative)) -ceq $canonicalTreeBefore) 'the losing second-repository canonical route also makes zero writes in the controlled fake home'
        Write-TestMarker $holderRelease
        Assert-TestCondition ((Wait-TestExit $holder) -and $holder.ExitCode -eq 0) 'the canonical-bound holder releases global before canonical and exits cleanly'
        $successorLock = Enter-CanonicalRepoLock -LockPath ([string]$canonicalRepoB.LockPath)
        $successorWitness = $null
        try {
            $successorWitness = Open-CanonicalHeldNamespaceWitness -RepoRoot ([string]$canonicalRepoB.RepoRoot) -CanonicalLockHandle $successorLock -ToolchainRoot $RepoRoot
            $successorGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $canonicalFixture.Context -RequiredCanonicalWitness $successorWitness
            try { Assert-TestCondition ([string]$successorGlobal.Info.Identity -ceq $canonicalGlobalIdentity) 'after release the second-repository canonical route acquires the same immutable global lock through its own witness' }
            finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $successorGlobal }
        }
        finally {
            if ($null -ne $successorWitness) { Close-CanonicalHeldNamespaceWitness -Witness $successorWitness }
            Exit-CanonicalRepoLock -LockHandle $successorLock
        }
    }

}
catch { $testFailure = $_ }
finally {
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    foreach ($process in $processes) {
        if ($null -eq $process) { continue }
        try {
            $process.Refresh()
            if (-not $process.HasExited) {
                if (-not (Stop-ProcessTree -Process $process -WaitMilliseconds 10000)) { throw "failed to stop fixture process $($process.Id)" }
            }
            $process.Refresh()
            if (-not $process.HasExited -or -not $process.WaitForExit(10000)) { throw "fixture process $($process.Id) remained alive after cleanup" }
        }
        catch { $cleanupErrors.Add("fixture process cleanup failed: $($_.Exception.Message)") }
        finally { $process.Dispose() }
    }
    $fullWork=[IO.Path]::GetFullPath($work)
    try {
        if (-not $fullWork.StartsWith($tempRoot+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)) { throw 'unsafe live-concurrency cleanup root' }
        if ([IO.Directory]::Exists($fullWork)) {
            foreach ($readOnlyCandidate in [IO.Directory]::EnumerateFiles($fullWork,'*',[IO.SearchOption]::AllDirectories)) {
                $attributes = [IO.File]::GetAttributes($readOnlyCandidate)
                if (($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0) { [IO.File]::SetAttributes($readOnlyCandidate,$attributes -band (-bnot [IO.FileAttributes]::ReadOnly)) }
            }
            $cleanupDeadline=[Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                try { [IO.Directory]::Delete($fullWork,$true); break }
                catch [IO.IOException] { if($cleanupDeadline.ElapsedMilliseconds -ge 5000){throw}; Start-Sleep -Milliseconds 25 }
            }
        }
    }
    catch { $cleanupErrors.Add("fixture directory cleanup failed: $($_.Exception.Message)") }
    if ($cleanupErrors.Count -gt 0) {
        $primary = if ($null -ne $testFailure) { " primary failure: $($testFailure.Exception.Message);" } else { '' }
        throw "FAIL:$primary cleanup failure(s): $($cleanupErrors -join '; ')"
    }
}
if ($null -ne $testFailure) { throw $testFailure }
Write-Host 'live concurrency tests: PASS'
