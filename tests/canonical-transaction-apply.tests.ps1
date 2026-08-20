#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path,[string]$ProgressPath,[ValidateSet('all','failed','primitive','staging')][string]$Section='all')

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
. (Join-Path $RepoRoot 'tests/helpers/canonical-reviewed-transaction-engine.ps1')

$script:pass=0;$script:fail=0
function Assert([bool]$Condition,[string]$Message){if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red}}
function Mark([string]$Value){if($ProgressPath){[IO.File]::AppendAllText([IO.Path]::GetFullPath($ProgressPath),((Get-Date -Format o)+" "+$Value+"`n"),[Text.UTF8Encoding]::new($false))}}
function Set-File([string]$Path,[string]$Content){$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false))}
function New-Skill([string]$Path,[string]$Name,[string]$Text){Set-File (Join-Path $Path 'SKILL.md') "---`nname: $Name`ndescription: test $Name`n---`n`n## Steps`n`n- $Text`n"}
function Invoke-Script([string]$Script,[string[]]$Arguments){$out=& pwsh -NoProfile -File $Script @Arguments 2>&1|Out-String;[pscustomobject]@{Code=$LASTEXITCODE;Out=$out}}
function Write-SemanticJson([string]$Path,$Document){$parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllBytes($Path,(ConvertTo-SemanticJsonBytes -InputObject $Document))}
function Set-CurrentUserOnlyAcl([string]$Path){
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$sid=[Security.Principal.SecurityIdentifier]::new([string]$template.OwnerSid)
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($sid);$security.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $Path -AclObject $security
}

Assert ($null -eq (Get-Command Invoke-CanonicalReviewedSkillTransaction -ErrorAction SilentlyContinue)) 'production common does not expose a reviewed mutation orchestrator with injectable callbacks'
Assert (-not (Get-Command Enter-CanonicalRepoLock).Parameters.ContainsKey('InternalWaitSeconds')) 'production lock surface is fixed zero-wait without an injectable wait parameter'
$sealedCommand=Get-Command Invoke-SealedCanonicalReviewedSkillTransaction -ErrorAction Stop
Assert ([IO.Path]::GetFullPath([string]$sealedCommand.ScriptBlock.File) -ceq [IO.Path]::GetFullPath((Join-Path $RepoRoot 'tests/helpers/canonical-reviewed-transaction-engine.ps1')) -and -not $sealedCommand.Parameters.ContainsKey('FailpointProvider')) 'reviewed transaction engine is defined only by the sealed test helper and exposes no failpoint provider'

function New-ReviewedPlan {
    param([string]$Fixture,[string]$External,[string]$Name,[scriptblock]$PopulateCandidate)
    Mark "plan:$Name:copy-source"
    $candidate=Join-Path $Fixture ("tmp/{0}-candidate" -f $Name);$null=Copy-SafeTree -SourceRoot (Join-Path $Fixture 'skills-source') -DestinationRoot (Join-Path $candidate 'skills-source')
    &$PopulateCandidate $candidate
    $plan=Join-Path $External ("{0}-plan.json" -f $Name);$preflight=Join-Path $External ("{0}-preflight" -f $Name)
    $input=Join-Path $candidate 'skills-source/shared/base'
    Mark "plan:$Name:dryrun"
    $run=Invoke-Script -Script (Join-Path $RepoRoot 'scripts/canonical-transaction.ps1') -Arguments @('-RepoRoot',$Fixture,'-OperationKind','normalize','-DryRun','-PlanPath',$plan,'-CandidateWorkspace',$candidate,'-InputPath',$input,'-CanonicalPreflightOutputRoot',$preflight)
    if($run.Code -ne 0){throw "reviewed plan generation failed: $($run.Out)"}
    Mark "plan:$Name:read"
    return [pscustomobject]@{Path=$plan;Document=Read-CanonicalTransactionPlan -PlanPath $plan -RepoRoot $Fixture -ExpectedOperationKind normalize}
}
function Assert-StagingReservation {
    param($Plan,$SetupState,$Git,$Paths,[string]$RecoveryRoot)
    $id=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$namespace=Join-Path $Paths.TransactionsRoot (Join-Path $Git.WorktreeId $id);$transactionRecovery=Join-Path $RecoveryRoot (Join-Path $Git.WorktreeId $id)
    $targets=@(New-CanonicalJournalTargetsFromPlan -PlanPayload $Plan.Document.PlanPayload -RecoveryTransactionRoot $transactionRecovery)
    $header=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$id;CanonicalOperationKind='normalize';OriginalDocumentHash=[string]$Plan.Document.DocumentHash;OriginalPlanHash=[string]$Plan.Document.PlanHash;RepoId=[string]$SetupState.RepoId;GitCommonDirHash=[string]$Git.GitCommonDirHash;WorktreeId=[string]$Git.WorktreeId;TransactionNamespace=[IO.Path]::GetFullPath($namespace);RecoveryTransactionRoot=[IO.Path]::GetFullPath($transactionRecovery);ExpectedPostconditionsHash=[string]$Plan.Document.PlanPayload.ExpectedPostconditionsHash;Targets=$targets}
    $null=New-CanonicalJournalHeader -Document $header -TransactionNamespace $namespace
    $null=Initialize-CanonicalReviewedStaging -PlanPayload $Plan.Document.PlanPayload -RecoveryTransactionRoot $transactionRecovery -Targets $targets
    $state=Read-CanonicalJournalDirectory -TransactionNamespace $namespace -AllowUnfinished;$stagedEntries=@(Get-ChildItem -LiteralPath (Join-Path $transactionRecovery 'staged') -Force)
    Assert (-not $state.IsTerminal -and $stagedEntries.Count -gt 0) 'reviewed staging bytes retain a discoverable create-new journal reservation before mutation'
}

$work=Join-Path $RepoRoot 'tmp/canonical-transaction-apply-tests'
$external=Join-Path (Split-Path -Parent $RepoRoot) ('.ai-agent-dotfiles-canonical-transaction-apply-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
if(Test-Path -LiteralPath $external){Remove-Item -LiteralPath $external -Recurse -Force}
[IO.Directory]::CreateDirectory($work)|Out-Null;[IO.Directory]::CreateDirectory($external)|Out-Null

try{
    Mark 'fixture:start'
    Write-Host "`n[reviewed multi-target apply orchestration]" -ForegroundColor Cyan
    $fixture=Join-Path $work 'repo';foreach($path in @('skills-source/shared','skills-source/claude-only','skills-source/codex-only','skills-source/reasonix-only','claude/skills','codex/skills','reasonix/skills','manifests')){[IO.Directory]::CreateDirectory((Join-Path $fixture $path))|Out-Null}
    New-Skill (Join-Path $fixture 'skills-source/shared/base') base old
    foreach($platform in @('claude','codex','reasonix')){New-Skill (Join-Path $fixture "$platform/skills/base") base old}
    foreach($name in @('managed-skills.claude.txt','managed-skills.codex.txt','managed-skills.reasonix.txt','managed-skills.txt')){Set-File (Join-Path $fixture "manifests/$name") "base`n"}
    &git -C $fixture init --quiet;&git -C $fixture config user.email test@example.invalid;&git -C $fixture config user.name canonical-test;&git -C $fixture add -- .;&git -C $fixture commit --quiet -m baseline
    if($LASTEXITCODE -ne 0){throw 'fixture commit failed'}

    $unknownGeneratedDir=Join-Path $fixture 'codex/skills/unmanaged-generated-dir';$unknownGeneratedFile=Join-Path $fixture 'reasonix/skills/unmanaged-generated-file.txt'
    Set-File (Join-Path $unknownGeneratedDir 'nested/sentinel.txt') 'unknown-directory-bytes';[IO.Directory]::CreateDirectory((Join-Path $unknownGeneratedDir 'empty'))|Out-Null
    Set-File $unknownGeneratedFile 'unknown-file-bytes'
    $unknownDirBefore=Get-SafeTreeSnapshot -Root $unknownGeneratedDir;$unknownDirMarkerBefore=Get-NoFollowRootEntryMarker -Path $unknownGeneratedDir
    $unknownFileBytesBefore=[IO.File]::ReadAllBytes($unknownGeneratedFile);$unknownFileMarkerBefore=Get-NoFollowRootEntryMarker -Path $unknownGeneratedFile

    $private=Join-Path $external 'private';$recovery=Join-Path $private 'recovery';$control=Join-Path $private 'control';$backup=Join-Path $private 'backup';$probe=Join-Path $external 'setup-probe'
    foreach($path in @($recovery,$control,$backup,$probe)){[IO.Directory]::CreateDirectory($path)|Out-Null};foreach($path in @($recovery,$control,$backup)){Set-CurrentUserOnlyAcl $path};[IO.Directory]::CreateDirectory((Join-Path $control 'canonical-roots'))|Out-Null
    $setupPayload=New-CanonicalSetupPlanPayload -RepoRoot $fixture -CanonicalRecoveryRoot $recovery -ControlBase $control -BackupRoot $backup -ProbeRoot $probe
    $setupState=New-CanonicalFinalSetupState -PlanPayload $setupPayload -RepoRoot $fixture;$git=Get-CanonicalGitContext -RepoRoot $fixture;$paths=Get-CanonicalTransactionContractPaths -GitContext $git
    Write-SemanticJson $paths.SetupStatePath $setupState;Write-SemanticJson (Join-Path $control (Join-Path 'canonical-roots' ($setupState.RepoId+'.json'))) $setupPayload.ExpectedRootClaim
    $lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath -AllowCreate;Exit-CanonicalRepoLock $lock
    Assert ((Get-CanonicalSetupStatus -RepoRoot $fixture) -ceq 'canonical-ready') 'setup state and root claim are ready before skill transaction'

    Mark 'first-plan:start';$first=New-ReviewedPlan -Fixture $fixture -External $external -Name first -PopulateCandidate {param($candidate)New-Skill (Join-Path $candidate 'skills-source/shared/new-skill') new-skill candidate};Mark 'first-plan:done'
    $projectionRoot=Join-Path $recovery (Join-Path $git.WorktreeId ([Guid]::NewGuid().ToString('D').ToLowerInvariant()));$rows=@(New-CanonicalJournalTargetsFromPlan -PlanPayload $first.Document.PlanPayload -RecoveryTransactionRoot $projectionRoot)
    $idsValid=$true;foreach($row in $rows){$platform=if($row.Contains('Platform')){[string]$row.Platform}else{$null};$expected=Get-CanonicalJournalTargetId -Order ([long]$row.Order) -TargetKind ([string]$row.TargetKind) -Role ([string]$row.Role) -Platform $platform -TargetPath ([string]$row.TargetPath);if([string]$row.TargetId -cne $expected){$idsValid=$false;break}}
    Assert $idsValid 'final plan order is deterministically projected into journal TargetId values'
    if($Section -eq 'staging'){Assert-StagingReservation -Plan $first -SetupState $setupState -Git $git -Paths $paths -RecoveryRoot $recovery;Mark 'test:done';if($script:fail){exit 1}else{exit 0}}

    $primitivePlan=$first
    $primitiveId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$primitiveMessage=''
    try{
        $null=Invoke-SealedCanonicalReviewedSkillTransaction -RepoRoot $fixture -PlanPath $primitivePlan.Path -OperationKind normalize -TransactionId $primitiveId -InternalPostconditionVerifier {throw 'natural-postcondition-verification-failure'}
    }catch{$primitiveMessage=$_.Exception.Message}
    $primitiveNs=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $primitiveId);$primitiveState=Read-CanonicalJournalDirectory -TransactionNamespace $primitiveNs -AllowUnfinished
    $primitiveRestored=$true;foreach($target in @($primitivePlan.Document.PlanPayload.Targets)){$kind=if([string]$target.TargetKind -ceq 'file'){'file'}else{'directory'};$actual=Get-CanonicalObservedPathState -Path ([string]$target.TargetPath) -ExpectedKind $kind;if(-not(Test-CanonicalObservedMatchesContractState -Actual $actual -Contract $target.Current)){$primitiveRestored=$false;break}}
    if(-not($primitiveMessage -match 'apply-failed-but-restored' -and $primitiveState.IsTerminal -and [string]$primitiveState.Result.Outcome -ceq 'failed-restored' -and $primitiveRestored)){
        Write-Host ("  diagnostic message={0}; terminal={1}; outcome={2}; restored={3}; phases={4}" -f $primitiveMessage,$primitiveState.IsTerminal,[string]$primitiveState.Outcome,$primitiveRestored,(@($primitiveState.Records|ForEach-Object Phase)-join ',')) -ForegroundColor DarkYellow
    }
    Assert ($primitiveMessage -match 'apply-failed-but-restored' -and $primitiveState.IsTerminal -and [string]$primitiveState.Result.Outcome -ceq 'failed-restored' -and $primitiveRestored) 'natural postcondition failure after target primitives restores every target and closes failed-restored'

    if($Section -eq 'primitive'){Mark 'test:done';if($script:fail){exit 1}else{exit 0}}

    $failedPlan=New-ReviewedPlan -Fixture $fixture -External $external -Name failed-gate -PopulateCandidate {param($candidate)New-Skill (Join-Path $candidate 'skills-source/shared/new-skill') new-skill candidate}
    $failedId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$failedMessage=''
    Mark 'failed-apply:start';try{$null=Invoke-SealedCanonicalReviewedSkillTransaction -RepoRoot $fixture -PlanPath $failedPlan.Path -OperationKind normalize -TransactionId $failedId -InternalPostconditionVerifier {throw 'postcondition-gate-failure'} -InternalProgressProvider {param($stage)Mark ("orchestrator:"+$stage)}}catch{$failedMessage=$_.Exception.Message};Mark 'failed-apply:done'
    $failedNs=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $failedId);$failed=Read-CanonicalJournalDirectory -TransactionNamespace $failedNs -AllowUnfinished
    if($failedMessage -notmatch 'apply-failed-but-restored'){Write-Host ("  diagnostic message={0}; terminal={1}; outcome={2}; phases={3}" -f $failedMessage,$failed.IsTerminal,[string]$failed.Result.Outcome,(@($failed.Records|ForEach-Object Phase)-join ',')) -ForegroundColor DarkYellow}
    Assert ($failedMessage -match 'apply-failed-but-restored' -and $failed.IsTerminal -and [string]$failed.Result.Outcome -ceq 'failed-restored') 'caught failure before commit boundary restores and closes failed-restored'
    $restored=$true;foreach($target in @($failedPlan.Document.PlanPayload.Targets)){$kind=if([string]$target.TargetKind -ceq 'file'){'file'}else{'directory'};$actual=Get-CanonicalObservedPathState -Path ([string]$target.TargetPath) -ExpectedKind $kind;if(-not(Test-CanonicalObservedMatchesContractState -Actual $actual -Contract $target.Current)){$restored=$false;break}}
    Assert $restored 'caught failure restores every target to reviewed Current bytes/state'

    if($Section -eq 'all'){
    Mark 'success-plan:start';$success=New-ReviewedPlan -Fixture $fixture -External $external -Name success -PopulateCandidate {param($candidate)New-Skill (Join-Path $candidate 'skills-source/shared/new-skill') new-skill candidate};Mark 'success-plan:done'
    $plannedUnknown=@($success.Document.PlanPayload.UnknownGeneratedInventory)
    Assert ($plannedUnknown.Count -eq 2 -and @($plannedUnknown|Where-Object{[string]$_.Name -ceq 'unmanaged-generated-dir' -and [string]$_.EntryType -ceq 'Directory'}).Count -eq 1 -and @($plannedUnknown|Where-Object{[string]$_.Name -ceq 'unmanaged-generated-file.txt' -and [string]$_.EntryType -ceq 'File'}).Count -eq 1) 'reviewed plan binds the pre-existing generated unknown directory and file'
    $successId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();Mark 'success-apply:start';$successState=Invoke-SealedCanonicalReviewedSkillTransaction -RepoRoot $fixture -PlanPath $success.Path -OperationKind normalize -TransactionId $successId -InternalPostconditionVerifier {param($payload,$id)[pscustomobject]@{PostconditionsHash=[string]$payload.ExpectedPostconditionsHash}};Mark 'success-apply:done'
    Assert ($successState.IsTerminal -and [string]$successState.Result.Outcome -ceq 'committed') 'all reviewed targets publish committed result and COMPLETE'
    Assert ((Test-Path -LiteralPath (Join-Path $fixture 'skills-source/shared/new-skill/SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $fixture 'codex/skills/new-skill/SKILL.md'))) 'canonical and managed generated bytes are installed together'
    $unknownDirAfter=Get-SafeTreeSnapshot -Root $unknownGeneratedDir;$unknownDirMarkerAfter=Get-NoFollowRootEntryMarker -Path $unknownGeneratedDir
    $unknownFileBytesAfter=[IO.File]::ReadAllBytes($unknownGeneratedFile);$unknownFileMarkerAfter=Get-NoFollowRootEntryMarker -Path $unknownGeneratedFile
    Assert ([string]$unknownDirAfter.TreeHash -ceq [string]$unknownDirBefore.TreeHash -and [string]$unknownDirMarkerAfter.Identity -ceq [string]$unknownDirMarkerBefore.Identity -and [Convert]::ToBase64String($unknownFileBytesAfter) -ceq [Convert]::ToBase64String($unknownFileBytesBefore) -and [string]$unknownFileMarkerAfter.Identity -ceq [string]$unknownFileMarkerBefore.Identity) 'successful transaction preserves generated unknown directory tree, file bytes, and root-entry identities'
    Mark 'real-postconditions:start';$post=Test-CanonicalCommittedPostconditions -PlanPayload $success.Document.PlanPayload -TransactionId $successId;Mark 'real-postconditions:done'
    Assert ([string]$post.PostconditionsHash -ceq [string]$success.Document.PlanPayload.ExpectedPostconditionsHash) 'isolated rebuild, scan, real-target and unknown-inventory postconditions pass'
    $postManifest=ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText([string]$post.ArtifactManifestPath,[Text.UTF8Encoding]::new($false,$true)))
    $postSummary=ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText([string]$post.ArtifactValidationSummaryPath,[Text.UTF8Encoding]::new($false,$true)))
    $postExpectedRoot=Join-Path ([string]$success.Document.PlanPayload.CanonicalPreflightOutputRoot) (Join-Path 'postconditions' $successId)
    Assert (
        [string]$post.OutputRoot -ceq [IO.Path]::GetFullPath($postExpectedRoot) -and
        [string]$post.BuildResultPath -ceq (Join-Path $postExpectedRoot 'build-result.json') -and
        [string]$post.ScanResultPath -ceq (Join-Path $postExpectedRoot 'scan-result.json') -and
        [string]$post.ArtifactManifestPath -ceq (Join-Path $postExpectedRoot 'artifact-manifest.json') -and
        [string]$post.ArtifactValidationSummaryPath -ceq (Join-Path $postExpectedRoot 'artifact-validation-summary.json') -and
        -not (Test-PathInsideRoot -Path $post.OutputRoot -Root $fixture) -and
        -not (Test-PathInsideRoot -Path $post.ArtifactManifestPath -Root $post.Workspace)
    ) 'postcondition result, manifest, and summary paths are exact external artifacts, never candidate/worktree artifacts'
    Assert (
        @($postManifest.Artifacts).Count -eq 2 -and
        [string]$postManifest.Artifacts[0].ArtifactKind -ceq 'canonical-build-result' -and
        [string]$postManifest.Artifacts[0].Path -ceq [string]$post.BuildResultPath -and
        [string]$postManifest.Artifacts[0].Sha256 -ceq [string]$post.BuildResultHash -and
        [string]$postManifest.Artifacts[1].ArtifactKind -ceq 'canonical-secret-scan-result' -and
        [string]$postManifest.Artifacts[1].Path -ceq [string]$post.ScanResultPath -and
        [string]$postManifest.Artifacts[1].Sha256 -ceq [string]$post.ScanResultHash -and
        [string]$post.ArtifactManifestHash -ceq (Get-FileHash -LiteralPath $post.ArtifactManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    ) 'postcondition child manifest binds exact ordered build/scan paths and hashes'
    Assert (
        [string]$postSummary.Mode -ceq 'Manifest' -and
        [string]$postSummary.Result -ceq 'PASS' -and
        [long]$postSummary.Counts.ArtifactsValidated -eq 2 -and
        [long]$postSummary.Counts.Failed -eq 0 -and
        [string]$post.ArtifactValidationSummaryHash -ceq (Get-FileHash -LiteralPath $post.ArtifactValidationSummaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    ) 'postcondition validation summary proves PASS/2/0 and its returned hash is exact'
    $postCollisionMessage='';try{$null=Publish-CanonicalPreflightArtifactValidation -ToolchainRoot $RepoRoot -RepoRoot $fixture -CanonicalPreflightOutputRoot $post.OutputRoot -BuildResultPath $post.BuildResultPath -ScanResultPath $post.ScanResultPath -ArtifactManifestPath $post.ArtifactManifestPath -ArtifactValidationSummaryPath $post.ArtifactValidationSummaryPath -ForbiddenRoots @($post.Workspace)}catch{$postCollisionMessage=$_.Exception.Message}
    Assert ($postCollisionMessage -match 'create-new') 'postcondition manifest/summary collision rejects replay before overwrite'
    $invalidPostSummary=Join-Path $post.OutputRoot 'invalid-artifact-validation-summary.json';$postSummary.Counts.ArtifactsValidated=0;Write-SemanticJson -Path $invalidPostSummary -Document $postSummary
    $postInvalidMessage='';try{$null=Confirm-CanonicalPreflightArtifactValidation -ToolchainRoot $RepoRoot -RepoRoot $fixture -CanonicalPreflightOutputRoot $post.OutputRoot -BuildResultPath $post.BuildResultPath -ScanResultPath $post.ScanResultPath -ArtifactManifestPath $post.ArtifactManifestPath -ArtifactValidationSummaryPath $invalidPostSummary -ForbiddenRoots @($post.Workspace)}catch{$postInvalidMessage=$_.Exception.Message}
    Assert ($postInvalidMessage -match 'does not exactly prove two validated PASS artifacts') 'postcondition invalid artifact-validation summary fails closed before POSTCONDITIONS_OK'

    $postconditionCommand=Get-Command Test-CanonicalCommittedPostconditions -ErrorAction Stop
    Assert (-not $postconditionCommand.Parameters.ContainsKey('FailpointProvider')) 'validated build/scan postcondition gate exposes no executable failpoint provider'

    &git -C $fixture add -- skills-source claude/skills codex/skills reasonix/skills manifests
    &git -C $fixture commit --quiet -m committed-canonical-test-state
    if($LASTEXITCODE -ne 0){throw 'unable to commit the disposable fixture canonical state'}
    $terminalPlan=New-ReviewedPlan -Fixture $fixture -External $external -Name terminal-boundary -PopulateCandidate {param($candidate)}
    $terminalId=[Guid]::NewGuid().ToString('D').ToLowerInvariant();$terminalReturn=Invoke-SealedCanonicalReviewedSkillTransaction -RepoRoot $fixture -PlanPath $terminalPlan.Path -OperationKind normalize -TransactionId $terminalId -InternalPostconditionVerifier {param($payload,$id)[pscustomobject]@{PostconditionsHash=[string]$payload.ExpectedPostconditionsHash}}
    $terminalNs=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $terminalId);$terminalDisk=Read-CanonicalJournalDirectory -TransactionNamespace $terminalNs
    Assert ($terminalReturn.IsTerminal -and $terminalDisk.IsTerminal -and [string]$terminalDisk.Outcome -ceq 'committed') 'durable COMPLETE returns and remains a terminal transaction'

    $stagingPlan=New-ReviewedPlan -Fixture $fixture -External $external -Name staging-crash -PopulateCandidate {param($candidate)}
    Assert-StagingReservation -Plan $stagingPlan -SetupState $setupState -Git $git -Paths $paths -RecoveryRoot $recovery

    }
    Mark 'test:done'
}catch{Mark ("test:error:"+$_.Exception.Message);$script:fail++;Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red}
finally{Write-Host '';Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan;if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force};if(Test-Path -LiteralPath $external){Remove-Item -LiteralPath $external -Recurse -Force}}
if($script:fail){exit 1}
