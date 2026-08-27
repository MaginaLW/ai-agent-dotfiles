#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1')
. (Join-Path $RepoRoot 'tests/helpers/canonical-reviewed-recovery-engine.ps1')

$script:pass=0;$script:fail=0
function Assert{param([bool]$Condition,[string]$Message)if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red}}
function Assert-Throws{param([scriptblock]$Action,[string]$Pattern,[string]$Message)try{&$Action;Assert $false $Message}catch{Assert ($_.Exception.Message -match $Pattern) $Message}}

Assert ($null -eq (Get-Command Invoke-CanonicalReviewedRecovery -ErrorAction SilentlyContinue)) 'production recovery common does not expose an injectable reviewed mutation engine'
$sealedRecoveryCommand=Get-Command Invoke-SealedCanonicalReviewedRecovery -ErrorAction Stop
Assert ([IO.Path]::GetFullPath([string]$sealedRecoveryCommand.ScriptBlock.File) -ceq [IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests/helpers/canonical-reviewed-recovery-engine.ps1')) -and -not $sealedRecoveryCommand.Parameters.ContainsKey('FailpointProvider')) 'reviewed recovery engine is defined only by the sealed test helper and exposes no failpoint provider'
$sealedRecoverySource=$sealedRecoveryCommand.ScriptBlock.Ast.Extent.Text
$appliedIndex=$sealedRecoverySource.IndexOf('RECOVERY_ACTION_APPLIED',[StringComparison]::Ordinal)
$firstReadyIndex=$sealedRecoverySource.IndexOf('Assert-CanonicalRecoveryOutcomeReady',$appliedIndex,[StringComparison]::Ordinal)
$resultIndex=$sealedRecoverySource.IndexOf('Publish-CanonicalTransactionResult',$firstReadyIndex,[StringComparison]::Ordinal)
$secondReadyIndex=$sealedRecoverySource.IndexOf('Assert-CanonicalRecoveryOutcomeReady',$resultIndex,[StringComparison]::Ordinal)
$completeIndex=$sealedRecoverySource.IndexOf('-Phase COMPLETE',$secondReadyIndex,[StringComparison]::Ordinal)
Assert ($appliedIndex -ge 0 -and $firstReadyIndex -gt $appliedIndex -and $resultIndex -gt $firstReadyIndex -and $secondReadyIndex -gt $resultIndex -and $completeIndex -gt $secondReadyIndex) 'reviewed recovery revalidates disk tuples after ACTION_APPLIED before result and again before COMPLETE'

function Invoke-Script{param([string]$Script,[string[]]$Arguments)$out=& pwsh -NoProfile -File $Script @Arguments 2>&1|Out-String;[pscustomobject]@{Code=$LASTEXITCODE;Out=$out}}
function Invoke-ScriptStreams{
    param([string]$Script,[string[]]$Arguments)
    $start=[Diagnostics.ProcessStartInfo]::new();$start.FileName=(Get-Command pwsh).Source;$start.UseShellExecute=$false;$start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true;$start.RedirectStandardError=$true
    foreach($argument in @('-NoProfile','-File',$Script)+@($Arguments)){[void]$start.ArgumentList.Add([string]$argument)}
    $process=[Diagnostics.Process]::new();$process.StartInfo=$start
    try{
        if(-not $process.Start()){throw 'Unable to start public canonical recovery command.'}
        $stdoutTask=$process.StandardOutput.ReadToEndAsync();$stderrTask=$process.StandardError.ReadToEndAsync();$process.WaitForExit()
        return [pscustomobject]@{Code=$process.ExitCode;Stdout=$stdoutTask.GetAwaiter().GetResult();Stderr=$stderrTask.GetAwaiter().GetResult()}
    }finally{$process.Dispose()}
}
function Get-ValidatedCanonicalCommandResult{
    param($Invocation,[string]$Path)
    $match=[regex]::Match([string]$Invocation.Stdout,'\A(\{[^\r\n]*\})(?:\r?\n)?\z')
    if(-not $match.Success){throw 'public command stdout must contain exactly one compact JSON line'}
    $json=$match.Groups[1].Value
    [IO.File]::WriteAllText($Path,$json,[Text.UTF8Encoding]::new($false))
    $null=Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json') -InstancePath $Path
    $document=ConvertFrom-SemanticJson -Json $json
    $semantic=[Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $document))
    if($json -cne $semantic){throw 'public command stdout is not the exact semantic JSON encoding'}
    return $document
}
function Test-ExactPropertySet{
    param($Document,[string[]]$Expected)
    $actual=@($Document.Keys|ForEach-Object{[string]$_}|Sort-Object)
    $wanted=@($Expected|Sort-Object)
    return (($actual -join "`n") -ceq ($wanted -join "`n"))
}
function Initialize-TestRepo{
    param([string]$Path)
    [IO.Directory]::CreateDirectory($Path)|Out-Null
    [IO.File]::WriteAllText((Join-Path $Path 'README.md'),'fixture',[Text.UTF8Encoding]::new($false))
    & git -C $Path init --quiet;& git -C $Path config user.email test@example.invalid;& git -C $Path config user.name canonical-test
    & git -C $Path add -- README.md;& git -C $Path commit --quiet -m baseline
    if($LASTEXITCODE -ne 0){throw 'Unable to create canonical recovery fixture repository.'}
}
function Write-TestSemanticJson{param([string]$Path,$Document)$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllBytes($Path,(ConvertTo-SemanticJsonBytes -InputObject $Document))}
function Copy-SemanticObject{param($Object)ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString((ConvertTo-SemanticJsonBytes -InputObject $Object)))}
function Set-TestCurrentUserOnlyAcl{
    param([Parameter(Mandatory)][string]$Path)
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$sid=[Security.Principal.SecurityIdentifier]::new([string]$template.OwnerSid)
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($sid);$security.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}
function Set-TestBroadWriteAcl{
    param([Parameter(Mandatory)][string]$Path)
    & icacls.exe $Path /grant '*S-1-1-0:(OI)(CI)F' /Q | Out-Null
    if($LASTEXITCODE -ne 0){throw "Unable to grant broad-write test ACL: $Path"}
}
function Remove-TestBroadWriteAcl{
    param([Parameter(Mandatory)][string]$Path)
    & icacls.exe $Path /remove:g '*S-1-1-0' /Q | Out-Null
    if($LASTEXITCODE -ne 0){throw "Unable to remove broad-write test ACL: $Path"}
}
function New-TestSetupJournalHeader{
    param($Payload,$Git,$Paths,[string]$TransactionId)
    $namespace=Join-Path $Paths.TransactionsRoot (Join-Path $Git.WorktreeId $TransactionId)
    return [ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$TransactionId;CanonicalOperationKind='setup';OriginalDocumentHash=(Get-SemanticJsonHash -InputObject ([ordered]@{TransactionId=$TransactionId;Kind='setup'}))
        OriginalPlanHash=('2'*64);RepoId=[string]$Payload.ExpectedSetupStateProjection.RepoId;GitCommonDirHash=[string]$Git.GitCommonDirHash;WorktreeId=[string]$Git.WorktreeId
        TransactionNamespace=[IO.Path]::GetFullPath($namespace);RecoveryTransactionRoot=Join-Path ([string]$Payload.ExpectedSetupStateProjection.CanonicalRecoveryRoot) (Join-Path $Git.WorktreeId $TransactionId)
        ExpectedPostconditionsHash=[string]$Payload.ExpectedPostconditionsHash;Targets=@();SetupRecovery=[ordered]@{
            ClaimPath=Join-Path ([string]$Payload.ExpectedSetupStateProjection.ControlBase) (Join-Path 'canonical-roots' ([string]$Payload.ExpectedSetupStateProjection.RepoId+'.json'))
            StatePath=[string]$Paths.SetupStatePath;ExpectedClaim=$Payload.ExpectedRootClaim;ExpectedClaimHash=[string]$Payload.ExpectedRootClaimHash
            ExpectedStateProjection=$Payload.ExpectedSetupStateProjection;ExpectedStateProjectionHash=[string]$Payload.ExpectedSetupStateProjectionHash
        }
    }
}
function Publish-TestReviewedRecoveryResultPrefix {
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)]$State,[Parameter(Mandatory)][string]$RepoRoot)
    $null=Assert-CanonicalRecoveryStateContext -State $State -RepoRoot $RepoRoot
    $action=[string]$Document.PlanPayload.PlannedAction
    $classification=Get-CanonicalTransactionRecoveryClassification -State $State -RepoRoot $RepoRoot
    if([string]$classification.AllowedAction -cne $action){throw 'test recovery prefix action mismatch'}
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase RECOVERY_ACTION_INTENT -Data ([ordered]@{
        PlanKind=[string]$Document.PlanPayload.PlanKind;DocumentHash=[string]$Document.DocumentHash;PriorHeadHash=[string]$State.DerivedJournalHeadHash
        ExpectedOutcome=[string]$Document.PlanPayload.ExpectedOutcome;ExpectedTerminalProjectionHash=[string]$Document.PlanPayload.ExpectedTerminalProjectionHash
    })
    if($action -ceq 'finalize' -and [string]$State.Header.CanonicalOperationKind -ceq 'setup' -and $classification.SetupState){
        $null=Publish-CanonicalSetupFinalStateForRecovery -State $State -Classification $classification
    }else{throw 'test recovery result prefix supports only setup finalize'}
    $null=Add-CanonicalJournalRecord -TransactionNamespace $State.TransactionNamespace -Phase RECOVERY_ACTION_APPLIED -Data ([ordered]@{Action=$action;DocumentHash=[string]$Document.DocumentHash})
    $afterAction=Get-CanonicalJournalStateForAppend -TransactionNamespace $State.TransactionNamespace
    $null=Assert-CanonicalRecoveryOutcomeReady -State $afterAction -RepoRoot $RepoRoot -ExpectedOutcome ([string]$Document.PlanPayload.ExpectedOutcome)
    $resultDocument=[ordered]@{}
    foreach($name in $Document.PlanPayload.ExpectedTerminalProjection.Keys){$resultDocument[$name]=$Document.PlanPayload.ExpectedTerminalProjection[$name]}
    $resultDocument.Insert(7,'ResultBaseHeadHash',[string]$afterAction.DerivedJournalHeadHash)
    $null=Publish-CanonicalTransactionResult -TransactionNamespace $State.TransactionNamespace -Document $resultDocument
    return Read-CanonicalJournalDirectory -TransactionNamespace $State.TransactionNamespace -AllowUnfinished
}

$root=Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-canonical-recovery-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $fixture=Join-Path $root 'repo';Initialize-TestRepo $fixture
    $setupScript=Join-Path $RepoRoot 'scripts/setup-canonical-transaction.ps1'
    $recoverScript=Join-Path $RepoRoot 'scripts/recover-canonical-transaction.ps1'
    $agentScript=Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'

    Write-Host "`n[canonical status and setup surface]" -ForegroundColor Cyan
    $recoverScriptText=Get-Content -Raw -LiteralPath $recoverScript
    $commandResultEmitterText=Get-Content -Raw -LiteralPath (Join-Path $RepoRoot 'scripts/canonical-command-result.ps1')
    Assert ($recoverScriptText -match 'canonical-command-result\.ps1' -and $recoverScriptText -match 'Write-CanonicalPublicCommandResult' -and $commandResultEmitterText -match 'ConvertTo-SemanticJsonBytes' -and $commandResultEmitterText -match 'artifact-contracts\.psd1' -and $commandResultEmitterText -match 'Invoke-CanonicalContractSchemaValidation') 'recovery emitter: shared helper self-validates semantic JSON against the registered schema before public stdout'
    $before=(Get-SafeTreeSnapshot -Root $fixture).TreeHash
    $status=Invoke-Script $agentScript @('canonical','status','-RepoRoot',$fixture)
    $after=(Get-SafeTreeSnapshot -Root $fixture).TreeHash
    Assert ($status.Code -eq 0 -and $status.Out -match 'canonical-setup-required') 'status: fresh repository reports canonical-setup-required'
    Assert ($before -ceq $after) 'status: fresh repository query is byte-for-byte zero-write'
    $recoverBefore=(Get-SafeTreeSnapshot -Root $fixture).TreeHash;$recoverFresh=Invoke-Script $agentScript @('canonical','recover','status','-RepoRoot',$fixture);$recoverAfter=(Get-SafeTreeSnapshot -Root $fixture).TreeHash
    Assert ($recoverFresh.Code -eq 0 -and $recoverFresh.Out -match 'no-canonical-transaction' -and $recoverBefore -ceq $recoverAfter) 'recovery status: absent lock+namespace is metadata-double-checked and zero-write'
    $freshStreams=Invoke-ScriptStreams $recoverScript @('-Status','-RepoRoot',$fixture);$freshResult=$null
    try{$freshResult=Get-ValidatedCanonicalCommandResult -Invocation $freshStreams -Path (Join-Path $root 'fresh-status-result.json')}catch{}
    Assert ($freshStreams.Code -eq 0 -and $freshStreams.Stderr -ceq '' -and $freshResult -and (Test-ExactPropertySet $freshResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken')) -and [string]$freshResult.Result -ceq 'PASS' -and [string]$freshResult.CommandKind -ceq 'canonical-recover-status' -and [string]$freshResult.LifecycleKind -ceq 'no-transaction' -and [string]$freshResult.MessageToken -ceq 'no-canonical-transaction') 'recovery emitter: clean status is one strict self-validating command result with empty stderr and exit 0'
    $missingSetupAction=Invoke-ScriptStreams $recoverScript @('-RepoRoot',$fixture,'-Action','abandon','-TransactionId',([Guid]::NewGuid().ToString('D').ToLowerInvariant()),'-DryRun','-PlanPath',(Join-Path $root 'missing-setup-plan.json'));$missingSetupResult=$null
    try{$missingSetupResult=Get-ValidatedCanonicalCommandResult -Invocation $missingSetupAction -Path (Join-Path $root 'missing-setup-result.json')}catch{}
    Assert ($missingSetupAction.Code -eq 1 -and $missingSetupAction.Stderr -cmatch '\Acanonical-setup-required(?:\r?\n)?\z' -and $missingSetupResult -and (Test-ExactPropertySet $missingSetupResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken')) -and [string]$missingSetupResult.Result -ceq 'WARN' -and [string]$missingSetupResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$missingSetupResult.LifecycleKind -ceq 'no-transaction' -and [string]$missingSetupResult.MessageToken -ceq 'canonical-setup-required') 'recovery emitter: action before canonical setup emits one strict setup-required result, exact token, and exit 1'
    $corruptRepo=Join-Path $root 'corrupt-status-repo';Initialize-TestRepo $corruptRepo;$corruptGit=Get-CanonicalGitContext $corruptRepo;$corruptPaths=Get-CanonicalTransactionContractPaths $corruptGit
    [IO.Directory]::CreateDirectory((Join-Path $corruptPaths.TransactionsRoot (Join-Path $corruptGit.WorktreeId 'corrupt-transaction')))|Out-Null;[IO.File]::WriteAllText($corruptPaths.LockPath,'',[Text.UTF8Encoding]::new($false))
    $corruptBefore=(Get-SafeTreeSnapshot -Root $corruptPaths.ContractRoot).TreeHash;$corruptStatus=Invoke-Script $agentScript @('canonical','recover','status','-RepoRoot',$corruptRepo);$corruptAfter=(Get-SafeTreeSnapshot -Root $corruptPaths.ContractRoot).TreeHash
    $corruptJsonLine=@($corruptStatus.Out -split "`r?`n"|Where-Object{$_.TrimStart().StartsWith('{')})[0];$corruptDocument=$corruptJsonLine|ConvertFrom-Json -Depth 20
    Assert ($corruptStatus.Code -eq 0 -and [string]$corruptDocument.ArtifactKind -ceq 'canonical-transaction-result' -and [string]$corruptDocument.ResultScope -ceq 'command' -and [string]$corruptDocument.Result -ceq 'FAIL' -and [string]$corruptDocument.CommandKind -ceq 'canonical-recover-status' -and [string]$corruptDocument.MessageToken -ceq 'manual-recovery-required' -and $corruptBefore -ceq $corruptAfter) 'recovery status: corrupt namespace returns a typed zero-write manual diagnostic instead of throwing'
    $corruptAction=Invoke-ScriptStreams $recoverScript @('-RepoRoot',$corruptRepo,'-Action','abandon','-TransactionId',([Guid]::NewGuid().ToString('D').ToLowerInvariant()),'-DryRun','-PlanPath',(Join-Path $root 'corrupt-action-plan.json'));$corruptActionResult=$null
    try{$corruptActionResult=Get-ValidatedCanonicalCommandResult -Invocation $corruptAction -Path (Join-Path $root 'corrupt-action-result.json')}catch{}
    Assert ($corruptAction.Code -eq 1 -and $corruptAction.Stderr -cmatch '\Amanual-recovery-required(?:\r?\n)?\z' -and $corruptActionResult -and (Test-ExactPropertySet $corruptActionResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken')) -and [string]$corruptActionResult.Result -ceq 'FAIL' -and [string]$corruptActionResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$corruptActionResult.LifecycleKind -ceq 'no-transaction' -and [string]$corruptActionResult.MessageToken -ceq 'manual-recovery-required') 'recovery emitter: corrupt transaction inventory emits one strict manual result, exact token, and exit 1'
    $selection1=Get-CanonicalPrivateRootSelection -RepoRoot $fixture;$selection2=Get-CanonicalPrivateRootSelection -RepoRoot $fixture
    Assert ($selection1.RepoId -ceq $selection2.RepoId -and $selection1.CanonicalRecoveryRoot -ceq $selection2.CanonicalRecoveryRoot) 'setup: restart recomputes the same deterministic RepoId and recovery root'
    Assert (-not(Test-TargetPathOverlap -Left $selection1.CanonicalRecoveryRoot -Right $fixture)) 'setup: selected recovery root is working-tree external'

    $linked=Join-Path $root 'linked';& git -C $fixture worktree add --quiet --detach $linked HEAD
    if($LASTEXITCODE -ne 0){throw 'Unable to create linked worktree fixture.'}
    $mainGit=Get-CanonicalGitContext $fixture;$linkedGit=Get-CanonicalGitContext $linked
    Assert ((Get-CanonicalRepoIdentity $mainGit) -ceq (Get-CanonicalRepoIdentity $linkedGit)) 'setup: linked worktrees share RepoId'
    Assert ((Get-CanonicalTransactionContractPaths $mainGit).SetupStatePath -ceq (Get-CanonicalTransactionContractPaths $linkedGit).SetupStatePath -and $mainGit.WorktreeId -cne $linkedGit.WorktreeId) 'setup: linked worktrees share setup state but retain distinct transaction namespaces'
    $fresh=Join-Path $root 'fresh';& git clone --quiet --no-local $fixture $fresh
    if($LASTEXITCODE -ne 0){throw 'Unable to create fresh clone fixture.'}
    Assert ((Get-CanonicalRepoIdentity (Get-CanonicalGitContext $fresh)) -cne (Get-CanonicalRepoIdentity $mainGit)) 'setup: fresh clone receives a distinct RepoId'

    $planRoot=Join-Path $root 'plans';[IO.Directory]::CreateDirectory($planRoot)|Out-Null;$plan=Join-Path $planRoot 'setup.json'
    $dry=Invoke-Script $agentScript @('canonical','setup','-RepoRoot',$fixture,'-DryRun','-PlanPath',$plan)
    Assert ($dry.Code -eq 0 -and (Test-Path -LiteralPath $plan)) 'setup: public DryRun publishes one external create-new setup plan'
    $doc=Read-CanonicalTransactionPlan -PlanPath $plan -RepoRoot $fixture -ExpectedOperationKind setup
    Assert ([string]$doc.PlanPayload.ExpectedRootClaim.ExpectedSetupStateProjectionHash -ceq [string]$doc.PlanPayload.ExpectedSetupStateProjectionHash -and [string]$doc.PlanPayload.ExpectedRootClaim.SetupIntentHash -ceq [string]$doc.PlanPayload.SetupIntentHash) 'setup: immutable root claim binds deterministic intent and setup-state projection'
    $apply=Invoke-Script $agentScript @('canonical','setup','-RepoRoot',$fixture,'-Apply','-PlanPath',$plan)
    Assert ($apply.Code -eq 75 -and $apply.Out -match 'canonical-apply-interlocked') 'setup: production Apply revalidates then remains interlocked'
    $missingPlan=Invoke-Script $agentScript @('canonical','setup','-RepoRoot',$fixture,'-Apply')
    Assert ($missingPlan.Code -ne 0) 'setup: Apply without reviewed PlanPath is rejected'
    $crossRunner=Invoke-Script $setupScript @('-RepoRoot',$fixture,'-DryRun','-PlanPath',(Join-Path $planRoot 'cross.json'),'-ApproveRunner')
    Assert ($crossRunner.Code -ne 0) 'setup: canonical setup rejects runner approval switches'
    $legacySetup=Invoke-Script (Join-Path $RepoRoot 'scripts/setup.ps1') @('-RepoRoot',$fixture,'-DryRun')
    Assert ($legacySetup.Code -ne 0) 'setup: runner setup rejects canonical DryRun switches'
    $publicWait=Invoke-Script $agentScript @('canonical','status','-RepoRoot',$fixture,'-LockWaitSeconds','1')
    Assert ($publicWait.Code -ne 0) 'lock: public protocol rejects LockWaitSeconds'
    Assert-Throws {New-CanonicalSetupPlanPayload -RepoRoot $fixture -CanonicalRecoveryRoot (Join-Path $fixture 'inside') -ControlBase (Join-Path $root 'c') -BackupRoot (Join-Path $root 'b') -ProbeRoot $planRoot} 'overlap' 'setup: repository-descendant recovery root is rejected'
    Assert-Throws {Resolve-TargetContext -Path ([IO.Path]::GetPathRoot($fixture)) -Mode MetadataOnly} 'volume root' 'setup: volume-root recovery target is rejected'
    $defaultLiveRoots=@(Get-CanonicalDefaultLiveRoots)
    Assert-Throws {New-CanonicalSetupPlanPayload -RepoRoot $fixture -CanonicalRecoveryRoot (Join-Path $root 'external-recovery') -ControlBase $defaultLiveRoots[0] -BackupRoot (Join-Path $root 'external-backup') -ProbeRoot $planRoot} 'overlap' 'setup: payload independently rejects overlap with a default live root'
    $inheritedParent=Join-Path $root 'inherited-broad-parent';$inheritedRecovery=Join-Path $inheritedParent 'recovery';[IO.Directory]::CreateDirectory($inheritedParent)|Out-Null;Set-TestBroadWriteAcl -Path $inheritedParent;[IO.Directory]::CreateDirectory($inheritedRecovery)|Out-Null
    Assert-Throws {New-CanonicalSetupPlanPayload -RepoRoot $fixture -CanonicalRecoveryRoot $inheritedRecovery -ControlBase (Join-Path $root 'inherited-control') -BackupRoot (Join-Path $root 'inherited-backup') -ProbeRoot $planRoot} 'broad write|owner/DACL' 'setup: inherited Everyone broad-write ACL is rejected'
    Assert-Throws {Assert-CanonicalRecoveryVolumeMatch -RepositoryVolumeId 'volume-a' -RecoveryVolumeId 'volume-b'} 'cross-volume' 'setup: payload volume guard rejects a different recovery volume deterministically'
    $securityTemplateV2=Get-CanonicalCurrentUserOnlySecurityTemplate
    Assert ([string]$securityTemplateV2.ResolverVersion -ceq 'windows-token-sid-current-user-only-v2') 'setup: current-user-only security template resolver version is v2'
    $ancestorTokenSid=Get-CanonicalTokenSid;$ancestorDefaultOwnerSid=Get-CanonicalTokenDefaultOwnerSid
    $ancestorEvidence=[ordered]@{}
    foreach($templateKey in @($securityTemplateV2.Keys)){$ancestorEvidence[$templateKey]=$securityTemplateV2[$templateKey]}
    $ancestorEvidence.OwnerSid=$ancestorDefaultOwnerSid
    $ancestorAccepted=$false
    try{Assert-CanonicalControlledPrivateAncestorSecurity -Evidence $ancestorEvidence -Path $root -TokenSid $ancestorTokenSid;$ancestorAccepted=$true}catch{}
    Assert $ancestorAccepted 'setup: ancestor owner check accepts the access-token default owner'
    $ancestorEvidenceForeign=[ordered]@{}
    foreach($templateKey in @($securityTemplateV2.Keys)){$ancestorEvidenceForeign[$templateKey]=$securityTemplateV2[$templateKey]}
    $ancestorEvidenceForeign.OwnerSid='S-1-5-32-545'
    Assert-Throws {Assert-CanonicalControlledPrivateAncestorSecurity -Evidence $ancestorEvidenceForeign -Path $root -TokenSid $ancestorTokenSid} 'ancestor is not owned' 'setup: ancestor owner check still rejects a foreign owner'
    $reparseTarget=Join-Path $root 'reparse-target';$reparseAlias=Join-Path $root 'reparse-alias';[IO.Directory]::CreateDirectory($reparseTarget)|Out-Null
    $null=New-Item -ItemType Junction -Path $reparseAlias -Target $reparseTarget
    Assert-Throws {Get-CanonicalTransactionContractPaths ([pscustomobject]@{GitCommonDir=$reparseAlias})} 'reparse' 'setup: contract-root ancestor reparse fails closed'
    $reparseRepoTarget=Join-Path $reparseTarget 'repo';Initialize-TestRepo $reparseRepoTarget
    Assert-Throws {Get-CanonicalGitContext -RepoRoot (Join-Path $reparseAlias 'repo')} 'reparse' 'setup: repository/common-dir discovery rejects reparse ancestry'

    Write-Host "`n[sealed full critical section]" -ForegroundColor Cyan
    $criticalId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$criticalPaths=Get-CanonicalTransactionContractPaths $mainGit
    $validatedMarker=Join-Path $root 'critical-validated.txt';$terminalMarker=Join-Path $root 'critical-terminal.txt';$releaseMarker=Join-Path $root 'critical-release.txt'
    $criticalOut=Join-Path $root 'critical.out';$criticalErr=Join-Path $root 'critical.err';$criticalHost=Join-Path $RepoRoot 'tests/helpers/canonical-critical-section-host.ps1'
    $criticalProcess=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile','-File',$criticalHost,'-ToolchainRoot',$RepoRoot,'-RepoRoot',$fixture,'-PlanPath',$plan,'-TransactionId',$criticalId,'-ValidatedMarker',$validatedMarker,'-TerminalMarker',$terminalMarker,'-ReleaseMarker',$releaseMarker) -RedirectStandardOutput $criticalOut -RedirectStandardError $criticalErr -PassThru -WindowStyle Hidden
    $criticalDeadline=[DateTime]::UtcNow.AddSeconds(20)
    while(-not(Test-Path -LiteralPath $terminalMarker) -and -not $criticalProcess.HasExited -and [DateTime]::UtcNow -lt $criticalDeadline){Start-Sleep -Milliseconds 50}
    Assert ((Test-Path -LiteralPath $validatedMarker) -and (Test-Path -LiteralPath $terminalMarker)) 'lock: sealed host revalidates saved plan, scans all worktrees, and reaches terminal under one lock'
    Assert-Throws {Enter-CanonicalRepoLock -LockPath $criticalPaths.LockPath} 'operation-lock-busy' 'lock: repo lock remains held after terminal journal publication'
    [IO.File]::WriteAllText($releaseMarker,'release',[Text.UTF8Encoding]::new($false))
    $criticalProcess.WaitForExit(10000)|Out-Null
    if(-not $criticalProcess.HasExited){Stop-Process -Id $criticalProcess.Id -Force}
    $criticalStdout=if(Test-Path $criticalOut){Get-Content $criticalOut -Raw}else{''}
    $criticalStderr=if(Test-Path $criticalErr){Get-Content $criticalErr -Raw}else{''}
    $criticalDetail=$criticalStdout+$criticalStderr
    Assert ($criticalProcess.HasExited -and $criticalProcess.ExitCode -eq 0) "lock: sealed full critical-section host exits cleanly ($criticalDetail)"
    $criticalNamespace=Join-Path $criticalPaths.TransactionsRoot (Join-Path $mainGit.WorktreeId $criticalId)
    Assert ((Read-CanonicalJournalDirectory -TransactionNamespace $criticalNamespace).IsTerminal) 'lock: terminal journal remains valid after lock release'
    Assert-Throws {Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $criticalPaths.TransactionsRoot -DocumentHash ([string]$doc.DocumentHash)} 'reviewed-plan-consumed' 'lock: sealed terminal permanently consumes the reviewed setup plan'

    Write-Host "`n[setup-state locator and zero-write ready status]" -ForegroundColor Cyan
    $ready=Join-Path $root 'ready-repo';Initialize-TestRepo $ready
    $private=Join-Path $root 'ready-private';$recovery=Join-Path $private 'recovery';$control=Join-Path $private 'control';$backups=Join-Path $private 'backups';$probe=Join-Path $root 'ready-probe'
    foreach($path in @($recovery,$control,$backups,$probe)){[IO.Directory]::CreateDirectory($path)|Out-Null}
    foreach($path in @($recovery,$control,$backups)){Set-TestCurrentUserOnlyAcl -Path $path}
    [IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots'))|Out-Null
    $payload=New-CanonicalSetupPlanPayload -RepoRoot $ready -CanonicalRecoveryRoot $recovery -ControlBase $control -BackupRoot $backups -ProbeRoot $probe
    $finalState=New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $ready
    $readyGit=Get-CanonicalGitContext $ready;$readyPaths=Get-CanonicalTransactionContractPaths $readyGit
    $readyLock=Enter-CanonicalRepoLock -LockPath $readyPaths.LockPath -AllowCreate;Exit-CanonicalRepoLock $readyLock
    Write-TestSemanticJson $readyPaths.SetupStatePath $finalState
    $claimPath=Join-Path $control (Join-Path 'canonical-roots' ($payload.ExpectedSetupStateProjection.RepoId+'.json'));Write-TestSemanticJson $claimPath $payload.ExpectedRootClaim
    $readyBefore=(Get-SafeTreeSnapshot -Root $ready).TreeHash;$readyToken=Get-CanonicalSetupStatus -RepoRoot $ready;$readyAfter=(Get-SafeTreeSnapshot -Root $ready).TreeHash
    Assert ($readyToken -ceq 'canonical-ready' -and $readyBefore -ceq $readyAfter) 'status: final state+claim+roots report canonical-ready with zero content writes'
    Assert-Throws {Get-CanonicalDirectorySecurityEvidence -Path $backups -ExpectedIdentity '00000000:0000000000000000'} 'identity changed' 'status: owner/DACL evidence is bound to the same no-follow handle identity'
    [IO.Directory]::Delete($backups)
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: setup state with BackupRoot MISSING fails closed'
    [IO.Directory]::CreateDirectory($backups)|Out-Null;Set-TestCurrentUserOnlyAcl -Path $backups
    $extra=Join-Path (Split-Path -Parent $readyPaths.SetupStatePath) 'canonical-setup-state.extra';[IO.File]::WriteAllText($extra,'x')
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: extra setup-state entry is manual recovery'
    Remove-Item -LiteralPath $extra -Force
    $claimBytes=[IO.File]::ReadAllBytes($claimPath);$badClaim=Copy-SemanticObject $payload.ExpectedRootClaim;$badClaim.ExpectedSetupStateProjectionHash=('0'*64);Write-TestSemanticJson $claimPath $badClaim
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: mismatched global claim is manual recovery'
    [IO.File]::WriteAllBytes($claimPath,$claimBytes)
    $stateBytes=[IO.File]::ReadAllBytes($readyPaths.SetupStatePath);$badState=Copy-SemanticObject $finalState;$badState.BackupRootIntentHash=('0'*64)
    Write-TestSemanticJson $readyPaths.SetupStatePath $badState
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: stale root intent hash fails closed'
    [IO.File]::WriteAllBytes($readyPaths.SetupStatePath,$stateBytes);[IO.File]::WriteAllBytes($claimPath,$claimBytes)
    $missingState=Copy-SemanticObject $finalState;$missingContext=Copy-SemanticObject $missingState.BackupRootFinalContext;$missingContext.TargetStatus='MISSING';$missingContext.MissingRemainder=@('backups');$missingContext.FinalDirectoryIdentity=$null;$missingContext.FinalOwnerSid=$null;$missingContext.FinalDaclHash=$null
    $missingState.BackupRootFinalContext=$missingContext;$missingState.BackupRootFinalContextHash=Get-SemanticJsonHash -InputObject $missingContext
    Write-TestSemanticJson $readyPaths.SetupStatePath $missingState
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: precomputed MISSING intent cannot masquerade as final ready evidence'
    [IO.File]::WriteAllBytes($readyPaths.SetupStatePath,$stateBytes);[IO.File]::WriteAllBytes($claimPath,$claimBytes)
    $ownerState=Copy-SemanticObject $finalState;$ownerState.OwnerSid='S-1-5-18'
    Write-TestSemanticJson $readyPaths.SetupStatePath $ownerState
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: owner SID drift fails closed'
    [IO.File]::WriteAllBytes($readyPaths.SetupStatePath,$stateBytes);[IO.File]::WriteAllBytes($claimPath,$claimBytes)
    Set-TestBroadWriteAcl -Path $backups
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: explicit Everyone broad-write ACL fails closed'
    Remove-TestBroadWriteAcl -Path $backups
    [IO.Directory]::Delete($backups);[IO.Directory]::CreateDirectory($backups)|Out-Null;Set-TestCurrentUserOnlyAcl -Path $backups
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'manual-recovery-required') 'status: delete-and-recreate directory identity drift fails closed despite matching owner/DACL'
    $payload=New-CanonicalSetupPlanPayload -RepoRoot $ready -CanonicalRecoveryRoot $recovery -ControlBase $control -BackupRoot $backups -ProbeRoot $probe
    $finalState=New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $ready
    Write-TestSemanticJson $readyPaths.SetupStatePath $finalState;$claimPath=Join-Path $control (Join-Path 'canonical-roots' ($payload.ExpectedSetupStateProjection.RepoId+'.json'));Write-TestSemanticJson $claimPath $payload.ExpectedRootClaim
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'canonical-ready') 'status: refreshed isolated fixture binds new final directory identity'

    Write-Host "`n[missing-to-existing setup artifact graph]" -ForegroundColor Cyan
    $dagRepo=Join-Path $root 'dag-repo';Initialize-TestRepo $dagRepo
    $dagPrivate=Join-Path $root 'dag-private';[IO.Directory]::CreateDirectory($dagPrivate)|Out-Null;Set-TestCurrentUserOnlyAcl -Path $dagPrivate
    $dagRecovery=Join-Path $dagPrivate 'recovery';$dagControl=Join-Path $dagPrivate 'control';$dagBackup=Join-Path $dagPrivate 'backups';$dagProbe=Join-Path $root 'dag-probe';[IO.Directory]::CreateDirectory($dagProbe)|Out-Null
    $dagPayload=New-CanonicalSetupPlanPayload -RepoRoot $dagRepo -CanonicalRecoveryRoot $dagRecovery -ControlBase $dagControl -BackupRoot $dagBackup -ProbeRoot $dagProbe
    Assert (@($dagPayload.ExpectedSetupStateProjection.CanonicalRecoveryRootIntent.TargetStatus,$dagPayload.ExpectedSetupStateProjection.ControlBaseIntent.TargetStatus,$dagPayload.ExpectedSetupStateProjection.BackupRootIntent.TargetStatus) -notcontains 'EXISTS') 'setup DAG: DryRun binds MISSING intents without pretending final identities exist'
    Assert ([string]$dagPayload.ExpectedRootClaim.ExpectedSetupStateProjectionHash -ceq [string]$dagPayload.ExpectedSetupStateProjectionHash -and [string]$dagPayload.ExpectedRootClaimHash -ceq (Get-SemanticJsonHash -InputObject $dagPayload.ExpectedRootClaim)) 'setup DAG: immutable claim binds intent and deterministic projection'
    foreach($path in @($dagRecovery,$dagControl,$dagBackup)){[IO.Directory]::CreateDirectory($path)|Out-Null;Set-TestCurrentUserOnlyAcl -Path $path}
    [IO.Directory]::CreateDirectory((Join-Path $dagControl 'canonical-roots'))|Out-Null
    $dagFinal=New-CanonicalFinalSetupState -PlanPayload $dagPayload -RepoRoot $dagRepo
    Assert (@($dagFinal.CanonicalRecoveryRootFinalContext.TargetStatus,$dagFinal.ControlBaseFinalContext.TargetStatus,$dagFinal.BackupRootFinalContext.TargetStatus) -notcontains 'MISSING' -and [string]$dagFinal.SetupStateProjectionHash -ceq [string]$dagPayload.ExpectedSetupStateProjectionHash) 'setup DAG: Apply-derived final state adds EXISTING identities while preserving the reviewed projection'
    $dagGit=Get-CanonicalGitContext $dagRepo;$dagPaths=Get-CanonicalTransactionContractPaths $dagGit;$dagLock=Enter-CanonicalRepoLock -LockPath $dagPaths.LockPath -AllowCreate;Exit-CanonicalRepoLock $dagLock
    Write-TestSemanticJson $dagPaths.SetupStatePath $dagFinal;Write-TestSemanticJson (Join-Path $dagControl (Join-Path 'canonical-roots' ($dagFinal.RepoId+'.json'))) $dagPayload.ExpectedRootClaim
    Assert ((Get-CanonicalSetupStatus -RepoRoot $dagRepo) -ceq 'canonical-ready') 'setup DAG: status validates intent, claim, final state, and actual MISSING-to-EXISTS roots'

    Write-Host "`n[canonical setup recovery matrix]" -ForegroundColor Cyan
    $srRepo=Join-Path $root 'setup-recovery-repo';Initialize-TestRepo $srRepo
    $srPrivate=Join-Path $root 'setup-recovery-private';$srRecovery=Join-Path $srPrivate 'recovery';$srControl=Join-Path $srPrivate 'control';$srBackup=Join-Path $srPrivate 'backups';$srProbe=Join-Path $root 'setup-recovery-probe'
    foreach($path in @($srRecovery,$srControl,$srBackup,$srProbe)){[IO.Directory]::CreateDirectory($path)|Out-Null}
    foreach($path in @($srRecovery,$srControl,$srBackup)){Set-TestCurrentUserOnlyAcl -Path $path}
    [IO.Directory]::CreateDirectory((Join-Path $srControl 'canonical-roots'))|Out-Null
    $srPayload=New-CanonicalSetupPlanPayload -RepoRoot $srRepo -CanonicalRecoveryRoot $srRecovery -ControlBase $srControl -BackupRoot $srBackup -ProbeRoot $srProbe
    $srGit=Get-CanonicalGitContext $srRepo;$srPaths=Get-CanonicalTransactionContractPaths $srGit;$srLock=Enter-CanonicalRepoLock -LockPath $srPaths.LockPath -AllowCreate;Exit-CanonicalRepoLock $srLock
    $srId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$srHeader=New-TestSetupJournalHeader -Payload $srPayload -Git $srGit -Paths $srPaths -TransactionId $srId
    $null=New-CanonicalJournalHeader -Document $srHeader -TransactionNamespace $srHeader.TransactionNamespace;Write-TestSemanticJson $srHeader.SetupRecovery.ClaimPath $srPayload.ExpectedRootClaim
    $srState=Read-CanonicalJournalDirectory -TransactionNamespace $srHeader.TransactionNamespace -AllowUnfinished;$srClass=Get-CanonicalTransactionRecoveryClassification -State $srState -RepoRoot $srRepo
    Assert ([string]$srClass.AllowedAction -ceq 'finalize' -and [string]$srClass.Reason -ceq 'claim-present-state-missing') 'setup recovery: exact claim with MISSING state permits only finalize'
    $srPlans=Join-Path $root 'setup-recovery-plans';[IO.Directory]::CreateDirectory($srPlans)|Out-Null;$srPlanPayload=Get-CanonicalRecoveryEvidencePayload -State $srState -RepoRoot $srRepo -Action finalize;$srDoc=Write-CanonicalRecoveryPlan -PlanPayload $srPlanPayload -PlanPath (Join-Path $srPlans 'claim-only.json') -RepoRoot $srRepo
    $srLock=Enter-CanonicalRepoLock -LockPath $srPaths.LockPath;try{$srTerminal=Invoke-SealedCanonicalReviewedRecovery -Document $srDoc -State $srState -RepoRoot $srRepo}finally{Exit-CanonicalRepoLock $srLock}
    Assert ($srTerminal.IsTerminal -and [string]$srTerminal.Outcome -ceq 'committed' -and (Test-Path -LiteralPath $srPaths.SetupStatePath)) 'setup recovery: finalize publishes the unique actual-identity state and COMPLETE'
    $srStateBytes=[IO.File]::ReadAllBytes($srPaths.SetupStatePath)

    $srId2=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$srHeader2=New-TestSetupJournalHeader -Payload $srPayload -Git $srGit -Paths $srPaths -TransactionId $srId2;$null=New-CanonicalJournalHeader -Document $srHeader2 -TransactionNamespace $srHeader2.TransactionNamespace
    $srState2=Read-CanonicalJournalDirectory -TransactionNamespace $srHeader2.TransactionNamespace -AllowUnfinished;$srClass2=Get-CanonicalTransactionRecoveryClassification -State $srState2 -RepoRoot $srRepo
    Assert ([string]$srClass2.AllowedAction -ceq 'finalize' -and [string]$srClass2.Reason -ceq 'claim-state-present-terminal-missing') 'setup recovery: exact claim+state with terminal missing permits record/result finalize only'
    $srPayload2=Get-CanonicalRecoveryEvidencePayload -State $srState2 -RepoRoot $srRepo -Action finalize;$srDoc2=Write-CanonicalRecoveryPlan -PlanPayload $srPayload2 -PlanPath (Join-Path $srPlans 'claim-state.json') -RepoRoot $srRepo
    $srLock=Enter-CanonicalRepoLock -LockPath $srPaths.LockPath;try{$null=Invoke-SealedCanonicalReviewedRecovery -Document $srDoc2 -State $srState2 -RepoRoot $srRepo}finally{Exit-CanonicalRepoLock $srLock}
    Assert ([Convert]::ToHexString([IO.File]::ReadAllBytes($srPaths.SetupStatePath)) -ceq [Convert]::ToHexString($srStateBytes)) 'setup recovery: claim+state finalize reuses state byte-for-byte and performs no target primitive'

    $srId3=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$srHeader3=New-TestSetupJournalHeader -Payload $srPayload -Git $srGit -Paths $srPaths -TransactionId $srId3;$null=New-CanonicalJournalHeader -Document $srHeader3 -TransactionNamespace $srHeader3.TransactionNamespace
    $srState3=Read-CanonicalJournalDirectory -TransactionNamespace $srHeader3.TransactionNamespace -AllowUnfinished;$srPayload3=Get-CanonicalRecoveryEvidencePayload -State $srState3 -RepoRoot $srRepo -Action finalize;$srDoc3=Write-CanonicalRecoveryPlan -PlanPayload $srPayload3 -PlanPath (Join-Path $srPlans 'setup-result-crash.json') -RepoRoot $srRepo
    $srLock=Enter-CanonicalRepoLock -LockPath $srPaths.LockPath;try{$srAfterResult=Publish-TestReviewedRecoveryResultPrefix -Document $srDoc3 -State $srState3 -RepoRoot $srRepo}finally{Exit-CanonicalRepoLock $srLock}
    $srClass3=Get-CanonicalTransactionRecoveryClassification -State $srAfterResult -RepoRoot $srRepo
    Assert ($srAfterResult.Result -and -not $srAfterResult.IsTerminal -and [string]$srClass3.AllowedAction -ceq 'finalize' -and [string]$srClass3.ExpectedOutcome -ceq 'committed') 'setup recovery: durable fixed-result prefix without COMPLETE preserves the result and offers finalize only'
    $srPayload4=Get-CanonicalRecoveryEvidencePayload -State $srAfterResult -RepoRoot $srRepo -Action finalize;$srDoc4=Write-CanonicalRecoveryPlan -PlanPayload $srPayload4 -PlanPath (Join-Path $srPlans 'setup-result-finalize.json') -RepoRoot $srRepo
    $srLock=Enter-CanonicalRepoLock -LockPath $srPaths.LockPath;try{$srTerminal3=Invoke-SealedCanonicalReviewedRecovery -Document $srDoc4 -State $srAfterResult -RepoRoot $srRepo}finally{Exit-CanonicalRepoLock $srLock}
    Assert ($srTerminal3.IsTerminal -and [string]$srTerminal3.Outcome -ceq 'committed') 'setup recovery: fixed setup result finalizes without requiring SetupState projection metadata'

    $srDriftId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$srDriftHeader=New-TestSetupJournalHeader -Payload $srPayload -Git $srGit -Paths $srPaths -TransactionId $srDriftId;$null=New-CanonicalJournalHeader -Document $srDriftHeader -TransactionNamespace $srDriftHeader.TransactionNamespace
    $srDriftState=Read-CanonicalJournalDirectory -TransactionNamespace $srDriftHeader.TransactionNamespace -AllowUnfinished;$srDriftPayload=Get-CanonicalRecoveryEvidencePayload -State $srDriftState -RepoRoot $srRepo -Action finalize;$srDriftDoc=Write-CanonicalRecoveryPlan -PlanPayload $srDriftPayload -PlanPath (Join-Path $srPlans 'setup-root-drift.json') -RepoRoot $srRepo
    $srLock=Enter-CanonicalRepoLock -LockPath $srPaths.LockPath;try{$srDriftFixed=Publish-TestReviewedRecoveryResultPrefix -Document $srDriftDoc -State $srDriftState -RepoRoot $srRepo}finally{Exit-CanonicalRepoLock $srLock}
    Assert ($srDriftFixed.Result -and -not $srDriftFixed.IsTerminal) 'setup recovery: fixed committed result prefix is isolated before COMPLETE for drift testing'
    [IO.Directory]::Delete($srBackup,$true);[IO.Directory]::CreateDirectory($srBackup)|Out-Null;Set-TestCurrentUserOnlyAcl -Path $srBackup
    $srDriftClass=Get-CanonicalTransactionRecoveryClassification -State $srDriftFixed -RepoRoot $srRepo
    Assert ([string]$srDriftClass.Status -ceq 'manual' -and [string]$srDriftClass.Reason -ceq 'fixed-setup-result-final-state-mismatch') 'setup recovery: fixed committed result revalidates actual setup root identity before COMPLETE'

    $srLocatorId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$srLocatorHeader=New-TestSetupJournalHeader -Payload $srPayload -Git $srGit -Paths $srPaths -TransactionId $srLocatorId;$srLocatorHeader.SetupRecovery.ClaimPath=Join-Path $srControl 'wrong-claim.json'
    $null=New-CanonicalJournalHeader -Document $srLocatorHeader -TransactionNamespace $srLocatorHeader.TransactionNamespace;$srLocatorState=Read-CanonicalJournalDirectory -TransactionNamespace $srLocatorHeader.TransactionNamespace -AllowUnfinished
    Assert-Throws {Assert-CanonicalRecoveryStateContext -State $srLocatorState -RepoRoot $srRepo} 'setup claim/state locator mismatch' 'setup recovery: journal claim/state locators must equal the trusted setup contract before content recovery'

    $zaRepo=Join-Path $root 'setup-zero-repo';Initialize-TestRepo $zaRepo;$zaPrivate=Join-Path $root 'setup-zero-private';[IO.Directory]::CreateDirectory($zaPrivate)|Out-Null;Set-TestCurrentUserOnlyAcl -Path $zaPrivate;$zaProbe=Join-Path $root 'setup-zero-probe';[IO.Directory]::CreateDirectory($zaProbe)|Out-Null
    $zaPayload=New-CanonicalSetupPlanPayload -RepoRoot $zaRepo -CanonicalRecoveryRoot (Join-Path $zaPrivate 'recovery') -ControlBase (Join-Path $zaPrivate 'control') -BackupRoot (Join-Path $zaPrivate 'backups') -ProbeRoot $zaProbe
    $zaGit=Get-CanonicalGitContext $zaRepo;$zaPaths=Get-CanonicalTransactionContractPaths $zaGit;$zaLock=Enter-CanonicalRepoLock -LockPath $zaPaths.LockPath -AllowCreate;Exit-CanonicalRepoLock $zaLock
    $zaId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$zaHeader=New-TestSetupJournalHeader -Payload $zaPayload -Git $zaGit -Paths $zaPaths -TransactionId $zaId;$null=New-CanonicalJournalHeader -Document $zaHeader -TransactionNamespace $zaHeader.TransactionNamespace
    $zaState=Read-CanonicalJournalDirectory -TransactionNamespace $zaHeader.TransactionNamespace -AllowUnfinished;$zaClass=Get-CanonicalTransactionRecoveryClassification -State $zaState -RepoRoot $zaRepo
    Assert ([string]$zaClass.AllowedAction -ceq 'abandon') 'setup recovery: zero claim/state primitive permits only abandon'
    $zaPlanPayload=Get-CanonicalRecoveryEvidencePayload -State $zaState -RepoRoot $zaRepo -Action abandon;$zaDoc=Write-CanonicalRecoveryPlan -PlanPayload $zaPlanPayload -PlanPath (Join-Path $srPlans 'zero-abandon.json') -RepoRoot $zaRepo
    $zaLock=Enter-CanonicalRepoLock -LockPath $zaPaths.LockPath;try{$null=Invoke-SealedCanonicalReviewedRecovery -Document $zaDoc -State $zaState -RepoRoot $zaRepo}finally{Exit-CanonicalRepoLock $zaLock}
    $zaId2=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$zaHeader2=New-TestSetupJournalHeader -Payload $zaPayload -Git $zaGit -Paths $zaPaths -TransactionId $zaId2;$null=New-CanonicalJournalHeader -Document $zaHeader2 -TransactionNamespace $zaHeader2.TransactionNamespace;Write-TestSemanticJson $zaPaths.SetupStatePath ([ordered]@{unexpected='state-without-claim'})
    $zaState2=Read-CanonicalJournalDirectory -TransactionNamespace $zaHeader2.TransactionNamespace -AllowUnfinished;$zaClass2=Get-CanonicalTransactionRecoveryClassification -State $zaState2 -RepoRoot $zaRepo
    Assert ([string]$zaClass2.Status -ceq 'manual' -and [string]$zaClass2.Reason -ceq 'setup-state-without-claim') 'setup recovery: state without claim is manual and never offered forward resume'

    Write-Host "`n[repo lock]" -ForegroundColor Cyan
    $held=Enter-CanonicalRepoLock -LockPath $readyPaths.LockPath
    try{
        Assert-Throws {Enter-CanonicalRepoLock -LockPath $readyPaths.LockPath} 'operation-lock-busy' 'lock: public zero-wait acquisition fails immediately while busy'
        Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'canonical-recovery-required') 'lock: read-only status maps an active exclusive owner to recovery-required'
        $busyAction=Invoke-ScriptStreams $recoverScript @('-RepoRoot',$ready,'-Action','abandon','-TransactionId',([Guid]::NewGuid().ToString('D').ToLowerInvariant()),'-DryRun','-PlanPath',(Join-Path $root 'busy-recovery-plan.json'));$busyActionResult=$null
        try{$busyActionResult=Get-ValidatedCanonicalCommandResult -Invocation $busyAction -Path (Join-Path $root 'busy-action-result.json')}catch{}
        Assert ($busyAction.Code -eq 1 -and $busyAction.Stderr -cmatch '\Aoperation-lock-busy(?:\r?\n)?\z' -and $busyActionResult -and (Test-ExactPropertySet $busyActionResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken')) -and [string]$busyActionResult.Result -ceq 'WARN' -and [string]$busyActionResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$busyActionResult.LifecycleKind -ceq 'no-transaction' -and [string]$busyActionResult.MessageToken -ceq 'operation-lock-busy') 'recovery emitter: public zero-wait lock loser emits one strict lock-busy result, exact token, and exit 1'
        $marker=Join-Path $root 'bounded-wait-acquired.txt';$lockHostScript=Join-Path $RepoRoot 'tests/helpers/canonical-lock-host.ps1';$lockHostOut=Join-Path $root 'bounded-wait.out';$lockHostErr=Join-Path $root 'bounded-wait.err'
        $process=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile','-File',$lockHostScript,'-ToolchainRoot',$RepoRoot,'-LockPath',$readyPaths.LockPath,'-WaitSeconds','3','-AcquiredMarker',$marker) -RedirectStandardOutput $lockHostOut -RedirectStandardError $lockHostErr -PassThru -WindowStyle Hidden
        Start-Sleep -Milliseconds 300
    }finally{Exit-CanonicalRepoLock $held}
    $lockHostDeadline=[DateTime]::UtcNow.AddSeconds(30);while(-not $process.HasExited -and [DateTime]::UtcNow -lt $lockHostDeadline){Start-Sleep -Milliseconds 50}
    if(-not $process.HasExited){Stop-Process -Id $process.Id -Force;$process.WaitForExit(5000)|Out-Null}
    $lockHostDetail=$(if(Test-Path $lockHostOut){Get-Content $lockHostOut -Raw}else{''})+$(if(Test-Path $lockHostErr){Get-Content $lockHostErr -Raw}else{''})
    Assert ($process.HasExited -and $process.ExitCode -eq 0 -and (Test-Path -LiteralPath $marker)) "lock: sealed host bounded waiter acquires only after owner releases ($lockHostDetail)"

    Write-Host "`n[hash-chained journal and fixed result]" -ForegroundColor Cyan
    $transactionId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$transactionRoot=Join-Path $readyPaths.TransactionsRoot (Join-Path $readyGit.WorktreeId $transactionId);$recoveryTx=Join-Path $recovery $transactionId
    $header=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$transactionId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);OriginalPlanHash=('2'*64);RepoId=$payload.ExpectedSetupStateProjection.RepoId;GitCommonDirHash=$readyGit.GitCommonDirHash;WorktreeId=$readyGit.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($transactionRoot);RecoveryTransactionRoot=[IO.Path]::GetFullPath($recoveryTx);ExpectedPostconditionsHash=('3'*64);Targets=@()}
    $headerPublish=New-CanonicalJournalHeader -Document $header -TransactionNamespace $transactionRoot
    $initial=Read-CanonicalJournalDirectory -TransactionNamespace $transactionRoot -AllowUnfinished
    Assert (-not $initial.IsTerminal -and $initial.DerivedJournalHeadHash -ceq $headerPublish.Hash) 'journal: header is the initial derived chain head'
    Assert (-not(Test-Path -LiteralPath (Join-Path $readyPaths.ContractRoot '_schema-validation'))) 'journal: long-path read/schema validation creates no alias directory'
    $headerPath=Join-Path $transactionRoot 'header.json';$sameLengthBytes=[IO.File]::ReadAllBytes($headerPath);$sameLengthBytes[$sameLengthBytes.Length-2]=$sameLengthBytes[$sameLengthBytes.Length-2] -bxor 1
    $headerParents=$null;$headerHandle=$null
    try{
        $headerParents=Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $headerPath)
        $headerHandle=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($headerParents[$headerParents.Count-1],[IO.Path]::GetFileName($headerPath))
        Assert-Throws {try{[IO.File]::WriteAllBytes($headerPath,$sameLengthBytes)}catch [IO.IOException]{throw 'canonical-race-write-blocked'}} 'canonical-race-write-blocked' 'journal: deterministic same-length in-place race is blocked by the shared held exact-byte primitive'
    }
    finally{if($headerHandle){$headerHandle.Dispose()};if($headerParents){Close-SafeDirectoryContainmentChain -Handles $headerParents}}
    $null=Read-CanonicalJsonContractFile -Path $headerPath -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-journal-header.schema.json')
    $post=Add-CanonicalJournalRecord -TransactionNamespace $transactionRoot -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=('3'*64)})
    $result=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId=$transactionId;CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=$post.Hash;Outcome='committed';PlanHash=('2'*64);PostconditionsHash=('3'*64);ArtifactStates=@([ordered]@{Name='targets';Status='COMPLETE';Hash=(Get-SemanticJsonHash -InputObject @())})}
    $resultPublish=Publish-CanonicalTransactionResult -TransactionNamespace $transactionRoot -Document $result
    $withResult=Read-CanonicalJournalDirectory -TransactionNamespace $transactionRoot -AllowUnfinished
    Assert (-not $withResult.IsTerminal -and $withResult.ResultHash -ceq $resultPublish.Hash) 'journal: fixed result without COMPLETE remains unfinished'
    Assert-Throws {Add-CanonicalJournalRecord -TransactionNamespace $transactionRoot -Phase POSTCONDITIONS_OK -Data ([ordered]@{PostconditionsHash=('3'*64)})} 'non-closing record after the fixed result' 'journal: non-closing record after fixed result is rejected before publish'
    Assert ((Read-CanonicalJournalDirectory -TransactionNamespace $transactionRoot -AllowUnfinished).Records.Count -eq 1) 'journal: rejected post-result append publishes no record'
    $complete=Add-CanonicalJournalRecord -TransactionNamespace $transactionRoot -Phase COMPLETE -Data ([ordered]@{ResultHash=$resultPublish.Hash;OriginalDocumentHash=('1'*64);Outcome='committed';ClosingKind='original';ClosingDocumentHash=('1'*64)})
    $terminal=Read-CanonicalJournalDirectory -TransactionNamespace $transactionRoot
    Assert ($terminal.IsTerminal -and $terminal.Outcome -ceq 'committed' -and $terminal.DerivedJournalHeadHash -ceq $complete.Hash) 'journal: matching fixed result plus COMPLETE is the sole terminal state'
    Assert-Throws {Publish-CanonicalTransactionResult -TransactionNamespace $transactionRoot -Document $result} 'manual|terminal|exists' 'journal: fixed result cardinality is one'
    Assert-Throws {Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $readyPaths.TransactionsRoot -DocumentHash ('1'*64)} 'reviewed-plan-consumed' 'journal: all-worktree scan permanently consumes original DocumentHash'
    $badRecord=Copy-SemanticObject $terminal.Records[0];$badRecord.PreviousHash=('0'*64)
    Assert-Throws {Test-CanonicalJournalChain -Header $header -Records @($badRecord) -Results @()} 'chain break' 'journal: published hash break is rejected'
    $gapRecord=Copy-SemanticObject $terminal.Records[0];$gapRecord.Sequence=2
    Assert-Throws {Test-CanonicalJournalChain -Header $header -Records @($gapRecord) -Results @()} 'gap or duplicate' 'journal: published sequence gap is rejected'
    Assert-Throws {Test-CanonicalJournalChain -Header $header -Records @() -Results @($result,$result)} 'cardinality' 'journal: multiple fixed results are rejected'
    $incompleteTargetRecord=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$transactionId;Sequence=1;PreviousHash=$headerPublish.Hash;Phase='PREPARED';Data=[ordered]@{TargetId=('a'*64)}}
    Assert-Throws {Test-CanonicalJournalChain -Header $header -Records @($incompleteTargetRecord) -Results @()} 'missing TargetKind' 'journal: target records must bind paths and all reconciled state tuples'
    $orphanRecovery=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-record';TransactionId=$transactionId;Sequence=1;PreviousHash=$headerPublish.Hash;Phase='RECOVERY_ACTION_APPLIED';Data=[ordered]@{Action='rollback';DocumentHash=('9'*64)}}
    Assert-Throws {Test-CanonicalJournalChain -Header $header -Records @($orphanRecovery) -Results @()} 'no prior intent' 'journal: recovery action without a prior consumed intent is rejected'

    $duplicateRoot=Join-Path $root 'duplicate-transactions';$duplicateId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$duplicateWorktrees=@(('a'*64),('b'*64))
    foreach($duplicateWorktree in $duplicateWorktrees){
        $duplicateNamespace=Join-Path $duplicateRoot (Join-Path $duplicateWorktree $duplicateId);$duplicateHeader=[ordered]@{};foreach($key in $header.Keys){$duplicateHeader[$key]=$header[$key]}
        $duplicateHeader.TransactionId=$duplicateId;$duplicateHeader.WorktreeId=$duplicateWorktree;$duplicateHeader.TransactionNamespace=[IO.Path]::GetFullPath($duplicateNamespace);$duplicateHeader.OriginalDocumentHash=(Get-SemanticJsonHash -InputObject $duplicateWorktree)
        $null=New-CanonicalJournalHeader -Document $duplicateHeader -TransactionNamespace $duplicateNamespace
    }
    Assert-Throws {Get-CanonicalUniqueTransactionState -TransactionsRoot $duplicateRoot -TransactionId $duplicateId} 'duplicate canonical TransactionId' 'recovery: duplicate TransactionId across worktree namespaces is manual'
    Assert-Throws {Get-CanonicalUniqueTransactionState -TransactionsRoot $duplicateRoot -TransactionId ([Guid]::NewGuid().ToString('D').ToLowerInvariant())} 'not-found' 'recovery: missing TransactionId is rejected without fabricating operation context'

    $otherWorktree=$readyGit.WorktreeId;$unfinishedId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$unfinishedRoot=Join-Path $readyPaths.TransactionsRoot (Join-Path $otherWorktree $unfinishedId)
    $linkedKillMarker=Join-Path $root 'linked-kill.marker';$linkedKillOut=Join-Path $root 'linked-kill.out';$linkedKillErr=Join-Path $root 'linked-kill.err';$linkedKillHost=Join-Path $RepoRoot 'tests/helpers/canonical-linked-kill-host.ps1'
    $linkedKill=Start-Process -FilePath (Get-Command pwsh).Source -ArgumentList @('-NoProfile','-File',$linkedKillHost,'-ToolchainRoot',$RepoRoot,'-RepoRoot',$ready,'-CanonicalRecoveryRoot',$recovery,'-TransactionId',$unfinishedId,'-MarkerPath',$linkedKillMarker) -RedirectStandardOutput $linkedKillOut -RedirectStandardError $linkedKillErr -PassThru -WindowStyle Hidden
    $linkedDeadline=[DateTime]::UtcNow.AddSeconds(30);while(-not(Test-Path -LiteralPath $linkedKillMarker) -and -not $linkedKill.HasExited -and [DateTime]::UtcNow -lt $linkedDeadline){Start-Sleep -Milliseconds 50}
    Assert ((Test-Path -LiteralPath $linkedKillMarker) -and -not $linkedKill.HasExited) 'journal: linked worktree A publishes a reservation while holding the common lock'
    if(-not $linkedKill.HasExited){Stop-Process -Id $linkedKill.Id -Force;$linkedKill.WaitForExit(5000)|Out-Null}
    Assert ((Test-Path -LiteralPath $unfinishedRoot -PathType Container)) 'journal: hard-kill releases the OS lock but retains A durable namespace'
    Assert-Throws {Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $readyPaths.TransactionsRoot -DocumentHash ('5'*64)} 'canonical-recovery-required' 'journal: unfinished reservation in another worktree blocks new mutation'
    Assert ((Get-CanonicalSetupStatus -RepoRoot $ready) -ceq 'canonical-recovery-required') 'status: all-worktree unfinished journal is discoverable from the caller worktree'

    Write-Host "`n[reviewed canonical recovery surface]" -ForegroundColor Cyan
    $readyLinked=Join-Path $root 'ready-linked';& git -C $ready worktree add --quiet --detach $readyLinked HEAD
    if($LASTEXITCODE -ne 0){throw 'Unable to create linked recovery worktree fixture.'}
    $recoverStatus=Invoke-Script $agentScript @('canonical','recover','status','-RepoRoot',$readyLinked)
    Assert ($recoverStatus.Code -eq 0 -and $recoverStatus.Out -match $unfinishedId -and $recoverStatus.Out -match 'canonical-recover-abandon') 'recovery: linked worktree B discovers A namespace and the unique abandon action'
    $requiredStreams=Invoke-ScriptStreams $recoverScript @('-Status','-RepoRoot',$readyLinked);$requiredResult=$null
    try{$requiredResult=Get-ValidatedCanonicalCommandResult -Invocation $requiredStreams -Path (Join-Path $root 'recovery-required-result.json')}catch{}
    Assert ($requiredStreams.Code -eq 0 -and $requiredStreams.Stderr -ceq '' -and $requiredResult -and (Test-ExactPropertySet $requiredResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','TransactionId','DerivedJournalHeadHash','OriginalOperationKind','MessageToken')) -and [string]$requiredResult.Result -ceq 'WARN' -and [string]$requiredResult.CommandKind -ceq 'canonical-recover-status' -and [string]$requiredResult.LifecycleKind -ceq 'unfinished' -and [string]$requiredResult.TransactionId -ceq $unfinishedId -and [string]$requiredResult.OriginalOperationKind -ceq 'normalize' -and [string]$requiredResult.MessageToken -ceq 'canonical-recover-abandon') 'recovery emitter: recovery-required status is one strict unfinished result with exact route and exit 0'
    $wrongId=Invoke-ScriptStreams $agentScript @('canonical','recover','abandon','-RepoRoot',$readyLinked,'-TransactionId',([Guid]::NewGuid().ToString('D').ToLowerInvariant()),'-DryRun','-PlanPath',(Join-Path $planRoot 'wrong-id.json'));$wrongIdResult=$null
    try{$wrongIdResult=Get-ValidatedCanonicalCommandResult -Invocation $wrongId -Path (Join-Path $root 'wrong-id-result.json')}catch{}
    Assert ($wrongId.Code -eq 1 -and $wrongId.Stderr -cmatch '\Acanonical-transaction-not-found(?:\r?\n)?\z' -and $wrongIdResult -and (Test-ExactPropertySet $wrongIdResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken')) -and [string]$wrongIdResult.Result -ceq 'FAIL' -and [string]$wrongIdResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$wrongIdResult.LifecycleKind -ceq 'no-transaction' -and [string]$wrongIdResult.MessageToken -ceq 'canonical-transaction-not-found') 'recovery emitter: wrong TransactionId emits one strict not-found result without fabricated operation context'
    $recoveryPlan=Join-Path $planRoot 'recover-abandon.json'
    $recoverDry=Invoke-ScriptStreams $recoverScript @('-RepoRoot',$readyLinked,'-Action','abandon','-TransactionId',$unfinishedId,'-DryRun','-PlanPath',$recoveryPlan);$recoverDryResult=$null
    try{$recoverDryResult=Get-ValidatedCanonicalCommandResult -Invocation $recoverDry -Path (Join-Path $root 'recovery-dry-run-result.json')}catch{}
    Assert ($recoverDry.Code -eq 0 -and $recoverDry.Stderr -ceq '' -and (Test-Path -LiteralPath $recoveryPlan) -and $recoverDryResult -and (Test-ExactPropertySet $recoverDryResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken','PlanHash')) -and [string]$recoverDryResult.Result -ceq 'PASS' -and [string]$recoverDryResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$recoverDryResult.LifecycleKind -ceq 'no-transaction' -and [string]$recoverDryResult.MessageToken -ceq 'canonical-recovery-plan-created') 'recovery emitter: DryRun writes one plan and one strict self-validating command result with empty stderr and exit 0'
    $recoveryDocument=Read-CanonicalRecoveryPlan -PlanPath $recoveryPlan -RepoRoot $readyLinked -ExpectedAction abandon -ExpectedTransactionId $unfinishedId
    Assert ([string]$recoveryDocument.PlanPayload.SourceWorktreeId -ceq $otherWorktree -and [string]$recoveryDocument.PlanPayload.PlannedAction -ceq 'abandon') 'recovery: plan binds source worktree namespace and exact action'
    $blockerId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$blockerNamespace=Join-Path $readyPaths.TransactionsRoot (Join-Path $readyGit.WorktreeId $blockerId)
    $blockerHeader=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$blockerId;CanonicalOperationKind='normalize';OriginalDocumentHash=('e'*64);OriginalPlanHash=('f'*64);RepoId=(Get-CanonicalRepoIdentity $readyGit);GitCommonDirHash=[string]$readyGit.GitCommonDirHash;WorktreeId=[string]$readyGit.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($blockerNamespace);RecoveryTransactionRoot=Join-Path $recovery (Join-Path $readyGit.WorktreeId $blockerId);ExpectedPostconditionsHash=('a'*64);Targets=@()}
    $null=New-CanonicalJournalHeader -Document $blockerHeader -TransactionNamespace $blockerNamespace
    $blockedApply=Invoke-ScriptStreams $recoverScript @('-RepoRoot',$readyLinked,'-Action','abandon','-TransactionId',$unfinishedId,'-Apply','-PlanPath',$recoveryPlan);$blockedResult=$null
    try{$blockedResult=Get-ValidatedCanonicalCommandResult -Invocation $blockedApply -Path (Join-Path $root 'recovery-blocked-result.json')}catch{}
    Assert ($blockedApply.Code -eq 1 -and $blockedApply.Stderr -cmatch '\Acanonical-recovery-required(?:\r?\n)?\z' -and $blockedResult -and (Test-ExactPropertySet $blockedResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken','PlanHash')) -and [string]$blockedResult.Result -ceq 'FAIL' -and [string]$blockedResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$blockedResult.LifecycleKind -ceq 'no-transaction' -and [string]$blockedResult.MessageToken -ceq 'canonical-recovery-required' -and [string]$blockedResult.PlanHash -ceq [string]$recoveryDocument.PlanHash) 'recovery emitter: another unfinished transaction returns one strict recovery-required result, exact stderr token, and exit 1'
    Remove-Item -LiteralPath $blockerNamespace -Recurse -Force
    $recoverApply=Invoke-ScriptStreams $recoverScript @('-RepoRoot',$readyLinked,'-Action','abandon','-TransactionId',$unfinishedId,'-Apply','-PlanPath',$recoveryPlan);$recoverApplyResult=$null
    try{$recoverApplyResult=Get-ValidatedCanonicalCommandResult -Invocation $recoverApply -Path (Join-Path $root 'recovery-apply-result.json')}catch{}
    Assert ($recoverApply.Code -eq 75 -and $recoverApply.Stderr -cmatch '\Acanonical-recovery-apply-interlocked(?:\r?\n)?\z' -and $recoverApplyResult -and (Test-ExactPropertySet $recoverApplyResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken','PlanHash')) -and [string]$recoverApplyResult.Result -ceq 'FAIL' -and [string]$recoverApplyResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$recoverApplyResult.LifecycleKind -ceq 'no-transaction' -and [string]$recoverApplyResult.MessageToken -ceq 'canonical-recovery-apply-interlocked' -and [string]$recoverApplyResult.PlanHash -ceq [string]$recoveryDocument.PlanHash) 'recovery emitter: production Apply revalidates, emits one strict result plus exact stderr token, and exits 75 interlocked'
    $recoveryLock=Enter-CanonicalRepoLock -LockPath $readyPaths.LockPath
    try{
        $unfinishedState=Get-CanonicalUniqueTransactionState -TransactionsRoot $readyPaths.TransactionsRoot -TransactionId $unfinishedId
        $null=Assert-CanonicalRecoveryPlanCurrent -Document $recoveryDocument -State $unfinishedState -RepoRoot $readyLinked
        $recovered=Invoke-SealedCanonicalReviewedRecovery -Document $recoveryDocument -State $unfinishedState -RepoRoot $readyLinked
    }finally{Exit-CanonicalRepoLock $recoveryLock}
    Assert ($recovered.IsTerminal -and [string]$recovered.Outcome -ceq 'abandoned') 'recovery: sealed host publishes intent, fixed abandoned result, and recovery COMPLETE'
    Assert-Throws {Assert-CanonicalTransactionSetAllowsDocument -TransactionsRoot $readyPaths.TransactionsRoot -DocumentHash ([string]$recoveryDocument.DocumentHash)} 'reviewed-plan-consumed' 'recovery: closing reviewed recovery document is globally consumed'
    $replay=Invoke-ScriptStreams $agentScript @('canonical','recover','abandon','-RepoRoot',$readyLinked,'-TransactionId',$unfinishedId,'-Apply','-PlanPath',$recoveryPlan);$replayResult=$null
    try{$replayResult=Get-ValidatedCanonicalCommandResult -Invocation $replay -Path (Join-Path $root 'recovery-replay-result.json')}catch{}
    Assert ($replay.Code -eq 1 -and $replay.Stderr -cmatch '\Areviewed-plan-consumed(?:\r?\n)?\z' -and $replayResult -and (Test-ExactPropertySet $replayResult @('SchemaVersion','ArtifactKind','ResultScope','Result','CommandKind','LifecycleKind','MessageToken')) -and [string]$replayResult.Result -ceq 'FAIL' -and [string]$replayResult.CommandKind -ceq 'canonical-recover-abandon' -and [string]$replayResult.LifecycleKind -ceq 'no-transaction' -and [string]$replayResult.MessageToken -ceq 'reviewed-plan-consumed') 'recovery emitter: terminal closing-plan replay emits one strict consumed result, exact token, and exit 1'

    Write-Host "`n[recovery action-applied drift gate]" -ForegroundColor Cyan
    $appliedTarget=Join-Path $ready 'manifests/managed-skills.txt';[IO.Directory]::CreateDirectory((Split-Path -Parent $appliedTarget))|Out-Null
    [IO.File]::WriteAllText($appliedTarget,"old`n",[Text.UTF8Encoding]::new($false))
    $appliedId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$appliedNamespace=Join-Path $readyPaths.TransactionsRoot (Join-Path $readyGit.WorktreeId $appliedId)
    $appliedRecovery=Join-Path $recovery (Join-Path $readyGit.WorktreeId $appliedId);[IO.Directory]::CreateDirectory((Join-Path $appliedRecovery 'staged'))|Out-Null
    $appliedTargetId=Get-CanonicalJournalTargetId -Order 0 -TargetKind file -Role manifest -Platform Union -TargetPath $appliedTarget
    $appliedStaged=Join-Path $appliedRecovery ("staged/$appliedTargetId");[IO.File]::WriteAllText($appliedStaged,"new`n",[Text.UTF8Encoding]::new($false))
    $appliedCurrentObserved=Get-CanonicalObservedPathState -Path $appliedTarget -ExpectedKind file;$appliedCandidateObserved=Get-CanonicalObservedPathState -Path $appliedStaged -ExpectedKind file
    $appliedCurrent=[ordered]@{State='PRESENT';Hash=[string]$appliedCurrentObserved.Hash};$appliedCandidate=[ordered]@{State='PRESENT';Hash=[string]$appliedCandidateObserved.Hash}
    $appliedRow=[ordered]@{
        TargetId=$appliedTargetId;Order=0;TargetKind='file';Role='manifest';Platform='Union';TargetPath=[IO.Path]::GetFullPath($appliedTarget)
        PreimagePath=Join-Path $appliedRecovery ("preimage/$appliedTargetId");SwapOldPath=Join-Path $appliedRecovery ("swap-old/$appliedTargetId");StagedPath=[IO.Path]::GetFullPath($appliedStaged)
        Current=$appliedCurrent;Candidate=$appliedCandidate;TargetContextHash=[string](Resolve-TargetContext -Path $appliedTarget -Mode MetadataOnly).RequestedInitialRootContextHash
    }
    $appliedHeader=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$appliedId;CanonicalOperationKind='normalize';OriginalDocumentHash=('6'*64);OriginalPlanHash=('7'*64)
        RepoId=(Get-CanonicalRepoIdentity $readyGit);GitCommonDirHash=[string]$readyGit.GitCommonDirHash;WorktreeId=[string]$readyGit.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($appliedNamespace)
        RecoveryTransactionRoot=[IO.Path]::GetFullPath($appliedRecovery);ExpectedPostconditionsHash=('8'*64);Targets=@($appliedRow)
    }
    $null=New-CanonicalJournalHeader -Document $appliedHeader -TransactionNamespace $appliedNamespace
    $null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $appliedNamespace
    $null=Invoke-CanonicalFileReplacement -TransactionNamespace $appliedNamespace -Target $appliedRow
    $appliedMutated=Read-CanonicalJournalDirectory -TransactionNamespace $appliedNamespace -AllowUnfinished
    $appliedClassification=Get-CanonicalTransactionRecoveryClassification -State $appliedMutated -RepoRoot $ready
    Assert ([string]$appliedClassification.AllowedAction -ceq 'rollback') 'recovery drift: installed file tuple requires reviewed rollback before the applied-prefix test'
    $appliedPayload=Get-CanonicalRecoveryEvidencePayload -State $appliedMutated -RepoRoot $ready -Action rollback
    $appliedDocument=Write-CanonicalRecoveryPlan -PlanPayload $appliedPayload -PlanPath (Join-Path $planRoot 'applied-drift-rollback.json') -RepoRoot $ready
    $appliedLock=Enter-CanonicalRepoLock -LockPath $readyPaths.LockPath
    try{
        $null=Add-CanonicalJournalRecord -TransactionNamespace $appliedNamespace -Phase RECOVERY_ACTION_INTENT -Data ([ordered]@{
            PlanKind=[string]$appliedDocument.PlanPayload.PlanKind;DocumentHash=[string]$appliedDocument.DocumentHash;PriorHeadHash=[string]$appliedMutated.DerivedJournalHeadHash
            ExpectedOutcome=[string]$appliedDocument.PlanPayload.ExpectedOutcome;ExpectedTerminalProjectionHash=[string]$appliedDocument.PlanPayload.ExpectedTerminalProjectionHash
        })
        $restoreState=Get-CanonicalJournalStateForAppend -TransactionNamespace $appliedNamespace
        $restoreReconciliation=Get-CanonicalTargetReconciliation -Target $appliedRow -Records @($restoreState.Records)
        $null=Restore-CanonicalMutationTarget -Target $appliedRow -Reconciliation $restoreReconciliation
        $null=Add-CanonicalJournalRecord -TransactionNamespace $appliedNamespace -Phase RECOVERY_ACTION_APPLIED -Data ([ordered]@{Action='rollback';DocumentHash=[string]$appliedDocument.DocumentHash})
        $afterApplied=Get-CanonicalJournalStateForAppend -TransactionNamespace $appliedNamespace
        $null=Assert-CanonicalRecoveryOutcomeReady -State $afterApplied -RepoRoot $ready -ExpectedOutcome rolled-back
        [IO.File]::WriteAllText($appliedTarget,"external-drift`n",[Text.UTF8Encoding]::new($false))
        $driftedAfterApplied=Get-CanonicalJournalStateForAppend -TransactionNamespace $appliedNamespace
        Assert-Throws {Assert-CanonicalRecoveryOutcomeReady -State $driftedAfterApplied -RepoRoot $ready -ExpectedOutcome rolled-back} 'manual-recovery-required' 'recovery drift: external edit after ACTION_APPLIED is rejected before fixed result publication'
        Assert (-not $driftedAfterApplied.Result -and -not(Test-Path -LiteralPath (Join-Path $appliedNamespace 'result.json'))) 'recovery drift: rejected post-action tuple drift publishes no fixed result or COMPLETE'
    }finally{Exit-CanonicalRepoLock $appliedLock}

    Write-Host "`n[trusted target resolver rejects before observation]" -ForegroundColor Cyan
    $outsideId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$outsideNamespace=Join-Path $readyPaths.TransactionsRoot (Join-Path $readyGit.WorktreeId $outsideId)
    $outsideRecovery=Join-Path $recovery (Join-Path $readyGit.WorktreeId $outsideId);[IO.Directory]::CreateDirectory((Join-Path $outsideRecovery 'staged'))|Out-Null
    $outsideTarget=Join-Path $root 'outside-reviewed-target.txt';[IO.File]::WriteAllText($outsideTarget,'outside-old',[Text.UTF8Encoding]::new($false))
    $outsideTargetId=Get-CanonicalJournalTargetId -Order 0 -TargetKind file -Role manifest -Platform Union -TargetPath $outsideTarget
    $outsideStaged=Join-Path $outsideRecovery ("staged/$outsideTargetId");[IO.File]::WriteAllText($outsideStaged,'outside-new',[Text.UTF8Encoding]::new($false))
    $outsideCurrent=[ordered]@{State='PRESENT';Hash=[string](Get-CanonicalObservedPathState $outsideTarget).Hash};$outsideCandidate=[ordered]@{State='PRESENT';Hash=[string](Get-CanonicalObservedPathState $outsideStaged).Hash}
    $outsideRow=[ordered]@{
        TargetId=$outsideTargetId;Order=0;TargetKind='file';Role='manifest';Platform='Union';TargetPath=[IO.Path]::GetFullPath($outsideTarget)
        PreimagePath=Join-Path $outsideRecovery ("preimage/$outsideTargetId");SwapOldPath=Join-Path $outsideRecovery ("swap-old/$outsideTargetId");StagedPath=[IO.Path]::GetFullPath($outsideStaged)
        Current=$outsideCurrent;Candidate=$outsideCandidate;TargetContextHash=[string](Resolve-TargetContext -Path $outsideTarget -Mode MetadataOnly).RequestedInitialRootContextHash
    }
    $outsideHeader=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$outsideId;CanonicalOperationKind='normalize';OriginalDocumentHash=('7'*64);OriginalPlanHash=('8'*64)
        RepoId=(Get-CanonicalRepoIdentity $readyGit);GitCommonDirHash=[string]$readyGit.GitCommonDirHash;WorktreeId=[string]$readyGit.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($outsideNamespace)
        RecoveryTransactionRoot=[IO.Path]::GetFullPath($outsideRecovery);ExpectedPostconditionsHash=('9'*64);Targets=@($outsideRow)
    }
    $null=New-CanonicalJournalHeader -Document $outsideHeader -TransactionNamespace $outsideNamespace
    $null=Invoke-CanonicalFileReplacement -TransactionNamespace $outsideNamespace -Target $outsideRow
    $outsideState=Read-CanonicalJournalDirectory -TransactionNamespace $outsideNamespace -AllowUnfinished
    $outsideSentinel=[IO.File]::Open($outsideTarget,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::None)
    try{
        Assert-Throws {Assert-CanonicalRecoveryStateContext -State $outsideState -RepoRoot $ready} 'canonical target resolver rejects a target outside' 'recovery context: recomputed mutated outside target is rejected while its content is access-locked'
        Assert ($outsideSentinel.ReadByte() -ge 0) 'recovery context: trusted lexical/header binding rejects without requiring target content access'
    }finally{$outsideSentinel.Dispose()}

    $poisonId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$poisonNamespace=Join-Path $readyPaths.TransactionsRoot (Join-Path $readyGit.WorktreeId $poisonId);$poisonRecovery=Join-Path $recovery (Join-Path $readyGit.WorktreeId $poisonId)
    $poisonTarget=Join-Path $ready '.git/objects/recovery-parent-poison';$poisonTargetId=Get-CanonicalJournalTargetId -Order 0 -TargetKind parent-directory -Role parent -TargetPath $poisonTarget
    $poisonRow=[ordered]@{
        TargetId=$poisonTargetId;Order=0;TargetKind='parent-directory';Role='parent';TargetPath=[IO.Path]::GetFullPath($poisonTarget)
        PreimagePath=Join-Path $poisonRecovery ("preimage/$poisonTargetId");SwapOldPath=Join-Path $poisonRecovery ("swap-old/$poisonTargetId");StagedPath=Join-Path $poisonRecovery ("staged/$poisonTargetId")
        Current=[ordered]@{State='MISSING'};Candidate=[ordered]@{State='PRESENT';Hash=('a'*64)};TargetContextHash=[string](Resolve-TargetContext -Path $poisonTarget -Mode MetadataOnly).RequestedInitialRootContextHash
    }
    $poisonHeader=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$poisonId;CanonicalOperationKind='normalize';OriginalDocumentHash=('b'*64);OriginalPlanHash=('c'*64)
        RepoId=(Get-CanonicalRepoIdentity $readyGit);GitCommonDirHash=[string]$readyGit.GitCommonDirHash;WorktreeId=[string]$readyGit.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($poisonNamespace)
        RecoveryTransactionRoot=[IO.Path]::GetFullPath($poisonRecovery);ExpectedPostconditionsHash=('d'*64);Targets=@($poisonRow)
    }
    $null=New-CanonicalJournalHeader -Document $poisonHeader -TransactionNamespace $poisonNamespace;$poisonState=Read-CanonicalJournalDirectory -TransactionNamespace $poisonNamespace -AllowUnfinished
    Assert-Throws {Assert-CanonicalRecoveryStateContext -State $poisonState -RepoRoot $ready} 'parent target is not a required ancestor' 'recovery context: arbitrary in-repo .git parent target is rejected before recovery classification'
}
catch{$script:fail++;Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red;Write-Host $_.ScriptStackTrace -ForegroundColor DarkYellow}
finally{
    Write-Host '';Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan
    if(Test-Path -LiteralPath $root){Remove-Item -LiteralPath $root -Recurse -Force}
}
if($script:fail -ne 0){exit 1}
