#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$RepoRoot=(Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')

$script:pass=0; $script:fail=0
function Assert { param([bool]$Condition,[string]$Message) if($Condition){$script:pass++;Write-Host "  PASS  $Message" -ForegroundColor Green}else{$script:fail++;Write-Host "  FAIL  $Message" -ForegroundColor Red} }
function Assert-Throws { param([scriptblock]$Action,[string]$Message) try{&$Action;Assert $false $Message}catch{Assert $true $Message} }
function Set-File { param([string]$Path,[string]$Content) $parent=Split-Path -Parent $Path;if(-not(Test-Path -LiteralPath $parent)){[IO.Directory]::CreateDirectory($parent)|Out-Null};[IO.File]::WriteAllText($Path,$Content,[Text.UTF8Encoding]::new($false)) }
function New-Skill { param([string]$Path,[string]$Name=(Split-Path -Leaf $Path),[string]$Text='work') Set-File -Path (Join-Path $Path 'SKILL.md') -Content "---`nname: $Name`ndescription: test $Name`n---`n`n## Steps`n`n- $Text`n" }
function Invoke-Script { param([string]$Script,[string[]]$Arguments) $out=& pwsh -NoProfile -File $Script @Arguments 2>&1|Out-String;[pscustomobject]@{Code=$LASTEXITCODE;Out=$out} }
function Write-Json { param([string]$Path,$Document) Set-File -Path $Path -Content ((ConvertTo-Json -InputObject $Document -Depth 40)+"`n") }
function Set-CurrentUserOnlyAcl([string]$Path){
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$sid=[Security.Principal.SecurityIdentifier]::new([string]$template.OwnerSid)
    $security=[Security.AccessControl.DirectorySecurity]::new();$security.SetOwner($sid);$security.SetAccessRuleProtection($true,$false)
    $inherit=[Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid,[Security.AccessControl.FileSystemRights]::FullControl,$inherit,[Security.AccessControl.PropagationFlags]::None,[Security.AccessControl.AccessControlType]::Allow));Set-Acl -LiteralPath $Path -AclObject $security
}
function Copy-PlanWithMutation {
    param([string]$Source,[string]$Destination,[scriptblock]$Mutation,[switch]$Rehash)
    $doc=ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($Source)); & $Mutation $doc
    if($Rehash){$doc.PlanHash=Get-PlanHash -PlanPayload $doc.PlanPayload;$doc.DocumentHash=Get-DocumentHash -Document $doc}
    Write-Json -Path $Destination -Document $doc
}

$work=Join-Path $RepoRoot 'tmp/canonical-transaction-tests'
$external=Join-Path (Split-Path -Parent $RepoRoot) ('.ai-agent-dotfiles-canonical-plan-'+[Guid]::NewGuid().ToString('N'))
if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
if(Test-Path -LiteralPath $external){Remove-Item -LiteralPath $external -Recurse -Force}
[IO.Directory]::CreateDirectory($work)|Out-Null;[IO.Directory]::CreateDirectory($external)|Out-Null

try {
    Write-Host "`n[public message literal scan boundary]" -ForegroundColor Cyan
    $literalAssignmentPattern='(?i)(api_key|token|secret|password|client_secret|refresh_token|access_token)\s*[:=]\s*["''][^$][^"'']{8,}["'']'
    $indirectFixtureLine='MessageToken=$canonicalStatusMessageId'
    $directFixtureLine=$indirectFixtureLine.Replace('$canonicalStatusMessageId',"'canonical-recovery-status-retry'")
    Assert ($directFixtureLine -match $literalAssignmentPattern) 'message scan: fallback regex detects a direct public-message literal assignment'
    Assert ($indirectFixtureLine -notmatch $literalAssignmentPattern) 'message scan: fallback regex does not flag a MessageId variable assignment'

    $directFixtureRoot=Join-Path $external 'message-direct';$indirectFixtureRoot=Join-Path $external 'message-indirect'
    [IO.Directory]::CreateDirectory($directFixtureRoot)|Out-Null;[IO.Directory]::CreateDirectory($indirectFixtureRoot)|Out-Null
    Set-File -Path (Join-Path $directFixtureRoot 'fixture.ps1') -Content $directFixtureLine
    Set-File -Path (Join-Path $indirectFixtureRoot 'fixture.ps1') -Content $indirectFixtureLine
    $gitleaksLease=$null
    try{
        $gitleaksLease=Open-PinnedToolLease -LockPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json')
        $directScan=Invoke-PinnedToolProcess -ToolLease $gitleaksLease -Arguments @('detect','--no-git','--source',$directFixtureRoot,'--config',(Join-Path $RepoRoot '.gitleaks.toml'),'--redact','--no-banner') -Operation 'Pinned gitleaks message-literal fixture scan'
        $indirectScan=Invoke-PinnedToolProcess -ToolLease $gitleaksLease -Arguments @('detect','--no-git','--source',$indirectFixtureRoot,'--config',(Join-Path $RepoRoot '.gitleaks.toml'),'--redact','--no-banner') -Operation 'Pinned gitleaks MessageId fixture scan'
        Assert ($directScan.ExitCode -ne 0) 'message scan: pinned gitleaks detects the direct public-message literal fixture'
        Assert ($indirectScan.ExitCode -eq 0) 'message scan: pinned gitleaks accepts the MessageId variable fixture'
    }finally{if($gitleaksLease){Close-PinnedToolLease -ToolLease $gitleaksLease}}

    $directMessageValuePattern='(?im)\bMessageToken\s*=\s*\(?\s*["''][^"'']+["'']'
    $recoveryMessageSource=[IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1'))
    $transactionTestSource=[IO.File]::ReadAllText($PSCommandPath)
    $directMessageValueCount=[regex]::Matches($recoveryMessageSource,$directMessageValuePattern).Count+[regex]::Matches($transactionTestSource,$directMessageValuePattern).Count
    Assert ($directMessageValueCount -eq 0) 'message scan: public recovery and transaction fixture values use MessageId variables rather than direct literals'

    $fixture=Join-Path $work 'repo';[IO.Directory]::CreateDirectory($fixture)|Out-Null
    foreach($root in @('skills-source/shared','skills-source/claude-only','skills-source/codex-only','claude/skills','codex/skills','reasonix/skills','manifests')){[IO.Directory]::CreateDirectory((Join-Path $fixture $root))|Out-Null}
    New-Skill -Path (Join-Path $fixture 'skills-source/shared/base') -Name base -Text base
    foreach($platform in @('claude','codex','reasonix')){New-Skill -Path (Join-Path $fixture "$platform/skills/base") -Name base -Text base}
    foreach($name in @('managed-skills.claude.txt','managed-skills.codex.txt','managed-skills.reasonix.txt','managed-skills.txt')){Set-File -Path (Join-Path $fixture "manifests/$name") -Content "base`n"}
    & git -C $fixture init --quiet; & git -C $fixture config user.email test@example.invalid; & git -C $fixture config user.name canonical-test
    & git -C $fixture add -- .; & git -C $fixture commit --quiet -m baseline
    if($LASTEXITCODE -ne 0){throw 'Unable to create canonical transaction fixture repository.'}

    Write-Host "`n[exact context capture]" -ForegroundColor Cyan
    $captureRoot=Join-Path $external 'context-capture';[IO.Directory]::CreateDirectory($captureRoot)|Out-Null
    $captureFile=Join-Path $captureRoot 'same-length.txt';Set-File -Path $captureFile -Content 'AAAA'
    $captureHash=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $captureFile -Algorithm SHA256).Hash.ToLowerInvariant()
    $script:captureSwapPath=$captureFile;$script:captureSwapBytes=[Text.UTF8Encoding]::new($false).GetBytes('BBBB');$script:captureHashHookCalls=0
    function Get-FileHash {
        param([string]$LiteralPath,[string]$Algorithm)
        if([IO.Path]::GetFullPath($LiteralPath) -ceq [IO.Path]::GetFullPath($script:captureSwapPath)){
            [IO.File]::WriteAllBytes($LiteralPath,$script:captureSwapBytes);$script:captureHashHookCalls++
        }
        Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $LiteralPath -Algorithm $Algorithm
    }
    try{
        $fileState=Get-CanonicalPathState -Path $captureFile -Kind file
        Set-File -Path $captureFile -Content 'AAAA'
        $inputEvidence=Get-CanonicalInputEvidence -Path $captureFile
        $toolchainRoot=Join-Path $captureRoot 'toolchain';[IO.Directory]::CreateDirectory((Join-Path $toolchainRoot 'scripts'))|Out-Null
        $toolchainFile=Join-Path $toolchainRoot 'tool.txt';Set-File -Path $toolchainFile -Content 'AAAA'
        Set-File -Path (Join-Path $toolchainRoot 'scripts/runner-policy.psd1') -Content "@{ SchemaVersion=1; DataPathspecs=@('data'); ToolchainPaths=@('tool.txt') }"
        $script:captureSwapPath=$toolchainFile
        $toolchainFileHash=(Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $toolchainFile -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedToolchainHash=Get-SemanticJsonHash -InputObject ([ordered]@{SchemaVersion=1;DataPathspecs=@('data');ToolchainFiles=@([ordered]@{RelativePath='tool.txt';Length=4;Sha256=$toolchainFileHash})})
        $actualToolchainHash=Get-CanonicalToolchainPolicyHash -ToolchainRoot $toolchainRoot
        Assert ([string]$fileState.Hash -ceq $captureHash -and [string]$inputEvidence.Hash -ceq $captureHash -and [string]$actualToolchainHash -ceq $expectedToolchainHash -and $script:captureHashHookCalls -eq 0) 'capture: file state, input evidence, and toolchain rows derive from one held regular-file read'
    }finally{Remove-Item Function:\Get-FileHash -ErrorAction SilentlyContinue}

    $manifestPath=Join-Path $captureRoot 'managed.txt';Set-File -Path $manifestPath -Content "alpha`n"
    $script:manifestSwapPath=$manifestPath;$script:manifestTestHookCalls=0
    function Test-Path {
        param([string]$LiteralPath,[Microsoft.PowerShell.Commands.TestPathType]$PathType)
        $exists=Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
        if($exists -and [IO.Path]::GetFullPath($LiteralPath) -ceq [IO.Path]::GetFullPath($script:manifestSwapPath)){
            [IO.File]::WriteAllText($LiteralPath,"omega`n",[Text.UTF8Encoding]::new($false));$script:manifestTestHookCalls++
        }
        return $exists
    }
    try{
        $manifestNames=@(Read-CanonicalManifestNames -Path $manifestPath)
        Assert ($manifestNames.Count -eq 1 -and $manifestNames[0] -ceq 'alpha' -and $script:manifestTestHookCalls -eq 0) 'capture: manifest names come from one held byte capture rather than a post-check path reopen'
    }finally{Remove-Item Function:\Test-Path -ErrorAction SilentlyContinue}

    $originalSnapshotFunction=${function:Get-SafeTreeSnapshot}
    $script:directorySwapRoot=$null;$script:directoryReplacementRoot=$null;$script:directoryOldRoot=$null;$script:directorySnapshotHookCalls=0
    function Get-SafeTreeSnapshot {
        param([Parameter(Mandatory)][string]$Root,[string[]]$ExcludeRelativePaths=@(),[string[]]$ExcludePrefixes=@(),[scriptblock]$ShouldSkipEntry)
        if($script:directorySwapRoot -and [IO.Path]::GetFullPath($Root) -ceq [IO.Path]::GetFullPath($script:directorySwapRoot)){
            [IO.Directory]::Move($script:directorySwapRoot,$script:directoryOldRoot)
            [IO.Directory]::Move($script:directoryReplacementRoot,$script:directorySwapRoot)
            $script:directorySnapshotHookCalls++
        }
        & $script:originalSnapshotFunction -Root $Root -ExcludeRelativePaths $ExcludeRelativePaths -ExcludePrefixes $ExcludePrefixes -ShouldSkipEntry $ShouldSkipEntry
    }
    $script:originalSnapshotFunction=$originalSnapshotFunction
    try{
        foreach($case in @('state','input')){
            $directoryRoot=Join-Path $captureRoot "$case-root";$replacementRoot=Join-Path $captureRoot "$case-replacement";$oldRoot=Join-Path $captureRoot "$case-old"
            [IO.Directory]::CreateDirectory($directoryRoot)|Out-Null;Set-File -Path (Join-Path $directoryRoot 'a.txt') -Content 'A'
            [IO.Directory]::CreateDirectory($replacementRoot)|Out-Null;Set-File -Path (Join-Path $replacementRoot 'b.txt') -Content 'B'
            $expectedDirectoryHash=(& $originalSnapshotFunction -Root $directoryRoot).TreeHash
            $script:directorySwapRoot=$directoryRoot;$script:directoryReplacementRoot=$replacementRoot;$script:directoryOldRoot=$oldRoot
            $actualDirectory=if($case -ceq 'state'){Get-CanonicalPathState -Path $directoryRoot -Kind directory}else{Get-CanonicalInputEvidence -Path $directoryRoot}
            Assert ([string]$actualDirectory.Hash -ceq [string]$expectedDirectoryHash -and $script:directorySnapshotHookCalls -eq 0) "capture: canonical $case directory context comes from one retained traversal"
            $script:directorySwapRoot=$null
        }
    }finally{Set-Item Function:\Get-SafeTreeSnapshot -Value $originalSnapshotFunction}

    $pathStateSource=${function:Get-CanonicalPathState}.Ast.Extent.Text;$inputEvidenceSource=${function:Get-CanonicalInputEvidence}.Ast.Extent.Text;$manifestSource=${function:Read-CanonicalManifestNames}.Ast.Extent.Text;$toolchainSource=${function:Get-CanonicalToolchainPolicyHash}.Ast.Extent.Text
    Assert ($pathStateSource -notmatch 'Get-FileHash|GetNamedStreams|NoFollowFile\]::Inspect' -and $inputEvidenceSource -notmatch 'Resolve-Path|Get-FileHash|GetNamedStreams|NoFollowFile\]::Inspect' -and $manifestSource -notmatch 'Test-Path|ReadAllLines' -and $toolchainSource -notmatch 'Get-FileHash|GetNamedStreams|NoFollowFile\]::Inspect') 'capture: context helpers contain no split path read sequence'

    $candidate=Join-Path $fixture 'tmp/candidate';[IO.Directory]::CreateDirectory($candidate)|Out-Null
    $null=Copy-SafeTree -SourceRoot (Join-Path $fixture 'skills-source') -DestinationRoot (Join-Path $candidate 'skills-source')
    $input=Join-Path $candidate 'skills-source/shared/new-skill';New-Skill -Path $input -Name new-skill -Text candidate
    New-Skill -Path (Join-Path $candidate 'skills-source/reasonix-only/rx-skill') -Name rx-skill -Text reasonix
    $preflight=Join-Path $external 'preflight';$plan=Join-Path $external 'canonical-plan.json'
    $scriptPath=Join-Path $RepoRoot 'scripts/canonical-transaction.ps1'
    $dryArgs=@('-RepoRoot',$fixture,'-OperationKind','normalize','-DryRun','-PlanPath',$plan,'-CandidateWorkspace',$candidate,'-InputPath',$input,'-RewriteList','frontmatter-normalized','-CanonicalPreflightOutputRoot',$preflight)

    Write-Host "`n[plan generation and target closure]" -ForegroundColor Cyan
    $dry=Invoke-Script -Script $scriptPath -Arguments $dryArgs
    if($dry.Code -ne 0){Write-Host $dry.Out -ForegroundColor DarkYellow}
    Assert ($dry.Code -eq 0 -and (Test-Path -LiteralPath $plan)) 'dry-run: publishes one external create-new reviewed plan'
    $doc=Read-CanonicalTransactionPlan -PlanPath $plan -RepoRoot $fixture -ExpectedOperationKind normalize
    Assert ([string]$doc.PlanHash -ceq (Get-PlanHash -PlanPayload $doc.PlanPayload) -and [string]$doc.DocumentHash -ceq (Get-DocumentHash -Document $doc)) 'plan: PlanHash and DocumentHash bind the saved document'
    $roles=@($doc.PlanPayload.Targets|ForEach-Object Role|Sort-Object -Unique)
    Assert (@('canonical','generated','manifest','parent'|Where-Object{$_ -notin $roles}).Count -eq 0) 'plan: canonical, generated, manifest, and missing-parent targets are complete'
    Assert (@($doc.PlanPayload.Targets|Where-Object Role -eq manifest).Count -eq 4) 'plan: all per-platform and union manifests are bound'
    Assert (@($doc.PlanPayload.UnknownGeneratedInventory).Count -eq 0) 'plan: ordered unknown generated inventory is bound'
    Assert ([string]$doc.PlanPayload.BuildResultHash -cmatch '^[0-9a-f]{64}$' -and [string]$doc.PlanPayload.ScanResultHash -cmatch '^[0-9a-f]{64}$') 'plan: validated build and scan result hashes are bound'
    $again=Invoke-Script -Script $scriptPath -Arguments @('-RepoRoot',$fixture,'-OperationKind','normalize','-Apply','-PlanPath',$plan)
    Assert ($again.Code -eq 75 -and $again.Out -match [regex]::Escape([string]$doc.PlanHash) -and $again.Out -match 'canonical-apply-interlocked') 'plan: unchanged second process reproduces PlanHash while Apply remains interlocked'
    $existing=Invoke-Script -Script $scriptPath -Arguments $dryArgs
    Assert ($existing.Code -eq 1 -and $existing.Out -match 'canonical-plan-exists') 'plan: existing PlanPath is rejected before another preflight'

    Write-Host "`n[drift and dirty ownership]" -ForegroundColor Cyan
    $inputFile=Join-Path $input 'SKILL.md';$inputBytes=[IO.File]::ReadAllBytes($inputFile);[IO.File]::AppendAllText($inputFile,"drift`n")
    $r=Invoke-Script -Script $scriptPath -Arguments @('-RepoRoot',$fixture,'-OperationKind','normalize','-Apply','-PlanPath',$plan);Assert ($r.Code -ne 0 -and $r.Out -match 'stale') 'drift: changed input invalidates the reviewed plan';[IO.File]::WriteAllBytes($inputFile,$inputBytes)
    $canonicalFile=Join-Path $fixture 'skills-source/shared/base/SKILL.md';$canonicalBytes=[IO.File]::ReadAllBytes($canonicalFile);[IO.File]::AppendAllText($canonicalFile,"drift`n")
    $r=Invoke-Script -Script $scriptPath -Arguments @('-RepoRoot',$fixture,'-OperationKind','normalize','-Apply','-PlanPath',$plan);Assert ($r.Code -ne 0 -and $r.Out -match 'stale') 'drift: changed canonical source invalidates the reviewed plan';[IO.File]::WriteAllBytes($canonicalFile,$canonicalBytes)
    $generatedFile=Join-Path $fixture 'codex/skills/base/SKILL.md';$generatedBytes=[IO.File]::ReadAllBytes($generatedFile);[IO.File]::AppendAllText($generatedFile,"drift`n")
    $r=Invoke-Script -Script $scriptPath -Arguments @('-RepoRoot',$fixture,'-OperationKind','normalize','-Apply','-PlanPath',$plan);Assert ($r.Code -ne 0 -and $r.Out -match 'stale') 'drift: changed managed generated target invalidates the reviewed plan';[IO.File]::WriteAllBytes($generatedFile,$generatedBytes)
    $unknown=Join-Path $fixture 'codex/skills/unmanaged';[IO.Directory]::CreateDirectory($unknown)|Out-Null
    $r=Invoke-Script -Script $scriptPath -Arguments @('-RepoRoot',$fixture,'-OperationKind','normalize','-Apply','-PlanPath',$plan);Assert ($r.Code -ne 0 -and $r.Out -match 'stale') 'drift: unknown generated inventory invalidates the reviewed plan';Remove-Item -LiteralPath $unknown -Recurse -Force
    $manifestFile=Join-Path $fixture 'manifests/managed-skills.txt';$manifestBytes=[IO.File]::ReadAllBytes($manifestFile);[IO.File]::AppendAllText($manifestFile,"dirty`n")
    $r=Invoke-Script -Script $scriptPath -Arguments @('-RepoRoot',$fixture,'-OperationKind','normalize','-Apply','-PlanPath',$plan);Assert ($r.Code -eq 1 -and $r.Out -match 'canonical-plan-stale') 'ownership: dirty tracked manifest fails before mutation';[IO.File]::WriteAllBytes($manifestFile,$manifestBytes)

    Write-Host "`n[tamper, operation, and path roles]" -ForegroundColor Cyan
    $metaPlan=Join-Path $external 'tampered-metadata.json';Copy-PlanWithMutation $plan $metaPlan {param($d)$d.Metadata.CreatedAtUtc='2026-01-01T00:00:00Z'}
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $metaPlan -RepoRoot $fixture} 'tamper: metadata change without DocumentHash update is rejected'
    $payloadPlan=Join-Path $external 'tampered-payload.json';Copy-PlanWithMutation $plan $payloadPlan {param($d)$d.PlanPayload.RewriteList=@('tampered')}
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $payloadPlan -RepoRoot $fixture} 'tamper: payload change without PlanHash update is rejected'
    $hashPlan=Join-Path $external 'tampered-hash.json';Copy-PlanWithMutation $plan $hashPlan {param($d)$d.PlanHash=('0'*64)}
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $hashPlan -RepoRoot $fixture} 'tamper: saved hash change is rejected'
    $kindPlan=Join-Path $external 'wrong-kind.json';Copy-PlanWithMutation $plan $kindPlan {param($d)$d.PlanPayload.OperationKind='auto-merge'} -Rehash
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $kindPlan -RepoRoot $fixture} 'operation: unregistered auto-merge alias is rejected'
    $crossPlan=Join-Path $external 'cross-shape.json';Copy-PlanWithMutation $plan $crossPlan {param($d)$d.PlanPayload.ExpectedSetupStateProjection=@{}} -Rehash
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $crossPlan -RepoRoot $fixture} 'operation: skill plan rejects setup fields'
    Assert-Throws {Resolve-PrivateArtifactPath -Path (Join-Path $fixture 'plan.json') -Role ExternalUserArtifact -RepoRoot $fixture -AllowMissingLeaf} 'path: worktree PlanPath is rejected'
    $gitContext=Get-CanonicalGitContext -RepoRoot $fixture
    Assert-Throws {Resolve-PrivateArtifactPath -Path (Join-Path $gitContext.GitCommonDir 'ai-agent-dotfiles/plan.json') -Role ExternalUserArtifact -RepoRoot $fixture -AllowMissingLeaf} 'path: arbitrary GitCommonDir PlanPath is rejected'
    Assert-Throws {Resolve-PrivateArtifactPath -Path (Join-Path $gitContext.GitDir 'ai-agent-dotfiles/plan.json') -Role ExternalUserArtifact -RepoRoot $fixture -AllowMissingLeaf} 'path: arbitrary per-worktree GitDir PlanPath is rejected'
    Assert-Throws {Resolve-PrivateArtifactPath -Path (Join-Path $fixture '.reasonix/desktop-topic-created-at.json') -Role ExternalUserArtifact -RepoRoot $fixture -AllowMissingLeaf} 'path: protected Reasonix PlanPath is rejected without content access'
    $hardBase=Join-Path $external 'hard-base.json';Copy-Item -LiteralPath $plan -Destination $hardBase;$hardAlias=Join-Path $external 'hard-alias.json';New-Item -ItemType HardLink -Path $hardAlias -Target $hardBase|Out-Null
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $hardAlias -RepoRoot $fixture} 'path: hardlink PlanPath alias is rejected'
    $ads=Join-Path $external 'ads-plan.json';Copy-Item -LiteralPath $plan -Destination $ads;Set-Content -LiteralPath ($ads+':marker') -Value marker
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath $ads -RepoRoot $fixture} 'path: PlanPath with ADS is rejected'
    $junctionTarget=Join-Path $external 'junction-target';[IO.Directory]::CreateDirectory($junctionTarget)|Out-Null;Copy-Item -LiteralPath $plan -Destination (Join-Path $junctionTarget 'plan.json')
    $junction=Join-Path $external 'junction-alias';New-Item -ItemType Junction -Path $junction -Target $junctionTarget|Out-Null
    Assert-Throws {Read-CanonicalTransactionPlan -PlanPath (Join-Path $junction 'plan.json') -RepoRoot $fixture} 'path: reparse-ancestor PlanPath is rejected'

    Write-Host "`n[setup shape and result oneOf]" -ForegroundColor Cyan
    $setupRoot=Join-Path $external 'setup-roots';$probe=Join-Path $external 'setup-probe';[IO.Directory]::CreateDirectory($setupRoot)|Out-Null;Set-CurrentUserOnlyAcl $setupRoot;[IO.Directory]::CreateDirectory($probe)|Out-Null
    $setupPayload=New-CanonicalSetupPlanPayload -RepoRoot $fixture -CanonicalRecoveryRoot (Join-Path $setupRoot 'recovery') -ControlBase (Join-Path $setupRoot 'control') -BackupRoot (Join-Path $setupRoot 'backups') -ProbeRoot $probe
    Assert ([string]$setupPayload.ExpectedRootClaimHash -ceq (Get-SemanticJsonHash -InputObject $setupPayload.ExpectedRootClaim) -and [string]$setupPayload.ExpectedSetupStateProjectionHash -ceq (Get-SemanticJsonHash -InputObject $setupPayload.ExpectedSetupStateProjection) -and [string]$setupPayload.SetupIntentHash -ceq (Get-SemanticJsonHash -InputObject $setupPayload.PrivateRootBootstrapIntent)) 'setup: exact root claim, stable setup intent, and deterministic state projection are hash-bound'
    $setupPlan=Join-Path $external 'setup-plan.json';$setupDoc=Write-CanonicalTransactionPlan -PlanPayload $setupPayload -PlanPath $setupPlan -RepoRoot $fixture
    $null=Read-CanonicalTransactionPlan -PlanPath $setupPlan -RepoRoot $fixture -ExpectedOperationKind setup
    Assert ($null -ne $setupDoc -and -not $setupPayload.Contains('Targets')) 'setup: strict setup plan has no skill/candidate target fields'
    $disconnectedSetup=ConvertFrom-SemanticJson -Json ([Text.Encoding]::UTF8.GetString((ConvertTo-SemanticJsonBytes -InputObject $setupPayload)));$disconnectedSetup.ExpectedRootClaim.ExpectedSetupStateProjectionHash=('0'*64);$disconnectedSetup.ExpectedRootClaimHash=Get-SemanticJsonHash -InputObject $disconnectedSetup.ExpectedRootClaim
    Assert-Throws {New-CanonicalFinalSetupState -PlanPayload $disconnectedSetup -RepoRoot $fixture} 'setup: final state constructor rejects a disconnected claim/projection DAG'
    $interlockedMessageId='canonical-apply-interlocked'
    $commandResult=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='command';Result='FAIL';CommandKind='canonical-normalize';LifecycleKind='no-transaction';MessageToken=$interlockedMessageId}
    $commandPath=Join-Path $external 'command-result.json';Write-Json $commandPath $commandResult;$null=Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json') -InstancePath $commandPath
    Assert $true 'result: command no-transaction branch validates'
    $badResult=[ordered]@{};foreach($k in $commandResult.Keys){$badResult[$k]=$commandResult[$k]};$badResult.CanonicalOperationKind='normalize';$badPath=Join-Path $external 'bad-result.json';Write-Json $badPath $badResult
    Assert-Throws {Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json') -InstancePath $badPath} 'result: command/transaction scope crossing is rejected'
    $partial=[ordered]@{SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction';Result='PASS';TransactionId='tx';CanonicalOperationKind='normalize';OriginalDocumentHash=('1'*64);ResultBaseHeadHash=('2'*64);Outcome='abandoned';ArtifactStates=@([ordered]@{Name='journal';Status='PARTIAL';Hash=('3'*64)})}
    $partialPath=Join-Path $external 'bad-partial.json';Write-Json $partialPath $partial
    Assert-Throws {Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json') -InstancePath $partialPath} 'result: PARTIAL evidence cannot fabricate a future hash'

    Write-Host "`n[consumption key]" -ForegroundColor Cyan
    foreach($outcome in @('committed','abandoned','rolled-back','failed-restored')){
        Assert-Throws {Assert-CanonicalDocumentHashNotConsumed -DocumentHash ([string]$doc.DocumentHash) -TerminalEvidence @([pscustomobject]@{Outcome=$outcome;OriginalDocumentHash=[string]$doc.DocumentHash;AttemptDocumentHashes=@();ClosingDocumentHash=[string]$doc.DocumentHash})} "replay: $outcome terminal consumes DocumentHash even when context bytes are reconstructed"
    }

    Write-Host "`n[setup intent precompute]" -ForegroundColor Cyan
    $intentHashDirect=Get-CanonicalSetupIntentHash -PrivateRootBootstrapIntent $setupPayload.PrivateRootBootstrapIntent
    Assert ($intentHashDirect -ceq [string]$setupPayload.SetupIntentHash) 'precompute: intent hash matches the plan payload SetupIntentHash'
    $intentHashAgain=Get-CanonicalSetupIntentHash -PrivateRootBootstrapIntent $setupPayload.PrivateRootBootstrapIntent
    Assert ($intentHashAgain -ceq $intentHashDirect) 'precompute: same intent reproduces the same hash'
    $projectionHashDirect=Get-CanonicalExpectedSetupStateProjectionHash -ExpectedSetupStateProjection $setupPayload.ExpectedSetupStateProjection
    Assert ($projectionHashDirect -ceq [string]$setupPayload.ExpectedSetupStateProjectionHash) 'precompute: projection hash matches the plan payload ExpectedSetupStateProjectionHash'
    $reorderedIntent=[ordered]@{};foreach($k in @($setupPayload.PrivateRootBootstrapIntent.Keys)){ $reorderedIntent[$k]=$setupPayload.PrivateRootBootstrapIntent[$k] }
    $reversedIntent=[ordered]@{};foreach($k in @(@($setupPayload.PrivateRootBootstrapIntent.Keys) | Sort-Object -Descending)){ $reversedIntent[$k]=$setupPayload.PrivateRootBootstrapIntent[$k] }
    Assert ((Get-CanonicalSetupIntentHash -PrivateRootBootstrapIntent $reversedIntent) -ceq $intentHashDirect) 'precompute: intent key order does not change the hash'
    $mutatedOwner=[ordered]@{};foreach($k in @($setupPayload.PrivateRootBootstrapIntent.Keys)){ $mutatedOwner[$k]=$setupPayload.PrivateRootBootstrapIntent[$k] }
    $mutatedOwner['OwnerSid']='S-1-5-21-9999999999-9999999999-9999999999-9999'
    Assert ((Get-CanonicalSetupIntentHash -PrivateRootBootstrapIntent $mutatedOwner) -cne $intentHashDirect) 'precompute: OwnerSid change changes the intent hash'
    $missingField=[ordered]@{ OwnerSid=[string]$setupPayload.PrivateRootBootstrapIntent.OwnerSid }
    Assert-Throws {Get-CanonicalSetupIntentHash -PrivateRootBootstrapIntent $missingField} 'precompute: intent with missing fields is rejected'
    $extraField=[ordered]@{};foreach($k in @($setupPayload.PrivateRootBootstrapIntent.Keys)){ $extraField[$k]=$setupPayload.PrivateRootBootstrapIntent[$k] }
    $extraField['CanonicalRecoveryRootFinalContext']=[ordered]@{ TargetStatus='EXISTS' }
    Assert-Throws {Get-CanonicalSetupIntentHash -PrivateRootBootstrapIntent $extraField} 'precompute: intent with an unexpected field is rejected'
    $pollutedProjection=[ordered]@{};foreach($k in @($setupPayload.ExpectedSetupStateProjection.Keys)){ $pollutedProjection[$k]=$setupPayload.ExpectedSetupStateProjection[$k] }
    $pollutedProjection['RootClaimHash']=('e'*64)
    Assert-Throws {Get-CanonicalExpectedSetupStateProjectionHash -ExpectedSetupStateProjection $pollutedProjection} 'precompute: projection with Apply-derived RootClaimHash is rejected'
    $pollutedProjection2=[ordered]@{};foreach($k in @($setupPayload.ExpectedSetupStateProjection.Keys)){ $pollutedProjection2[$k]=$setupPayload.ExpectedSetupStateProjection[$k] }
    $pollutedProjection2['CanonicalRecoveryRootFinalContext']=[ordered]@{ TargetStatus='EXISTS' }
    Assert-Throws {Get-CanonicalExpectedSetupStateProjectionHash -ExpectedSetupStateProjection $pollutedProjection2} 'precompute: projection with Apply-derived FinalContext is rejected'
    $missingProjection=[ordered]@{ SchemaVersion=1; ArtifactKind='canonical-setup-state-projection' }
    Assert-Throws {Get-CanonicalExpectedSetupStateProjectionHash -ExpectedSetupStateProjection $missingProjection} 'precompute: projection with missing fields is rejected'

}
catch{$script:fail++;Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red}
finally{
    Write-Host '';Write-Host ("Results: {0} passed, {1} failed" -f $script:pass,$script:fail) -ForegroundColor Cyan
    if(Test-Path -LiteralPath $work){Remove-Item -LiteralPath $work -Recurse -Force}
    if(Test-Path -LiteralPath $external){Remove-Item -LiteralPath $external -Recurse -Force}
}
if($script:fail -ne 0){exit 1}
