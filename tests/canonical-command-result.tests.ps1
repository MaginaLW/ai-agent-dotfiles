#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,[ValidateSet('all','engine')][string]$Section='all')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:CommandResultClock = [Diagnostics.Stopwatch]::StartNew()
$script:CommandResultPhaseStart = 0.0
$script:CommandResultPhase = 'fixture initialization'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'tests/helpers/canonical-identity-fixture.ps1')
$identityFixture = New-CanonicalIdentityFixture -SourceRepoRoot $RepoRoot -Name 'command-result'
try {
$RepoRoot = $identityFixture.ToolchainRoot
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-command-result.ps1')
. (Join-Path $RepoRoot 'tests/helpers/safety-sandbox.ps1')

# Policy-state-aware behavioral pins (Phase 4 Task 8 Step 1 preparation): the
# same committed suite bytes assert the interlocked fail-closed contract while
# ReleaseState=interlocked, and each affected surface's observed released
# post-Assert contract once the reviewed release candidate flips the policy.
. (Join-Path $RepoRoot 'scripts/live-safety-interlock.ps1')
$policyState = [string] (Get-LiveSafetyPolicy).ReleaseState
$script:IsReleased = ($policyState -eq 'released')

$script:pass = 0
$script:fail = 0
$script:lastValidationError = ''

function Write-CommandResultTestPhase {
    param([Parameter(Mandatory)][string]$Name)
    $elapsed = $script:CommandResultClock.Elapsed.TotalSeconds
    Write-Host ('  timing: {0}={1:N1}s; elapsed={2:N1}s' -f $script:CommandResultPhase,($elapsed-$script:CommandResultPhaseStart),$elapsed)
    $script:CommandResultPhase = $Name
    $script:CommandResultPhaseStart = $elapsed
    Write-Host ("`n[{0}]" -f $Name) -ForegroundColor Cyan
}

function Assert {
    param([bool] $Condition, [string] $Message)
    if ($Condition) {
        $script:pass++
        Write-Host "  PASS  $Message" -ForegroundColor Green
    }
    else {
        $script:fail++
        Write-Host "  FAIL  $Message" -ForegroundColor Red
    }
}

function Set-TestFile {
    param([Parameter(Mandatory)] [string] $Path, [AllowNull()] [string] $Content)
    $parent = Split-Path -Parent $Path
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    [IO.File]::WriteAllText($Path, ($Content ?? ''), [Text.UTF8Encoding]::new($false))
}

function New-TestSkill {
    param([Parameter(Mandatory)] [string] $Path, [string] $Name = (Split-Path -Leaf $Path), [string] $Body = '## Steps')
    Set-TestFile -Path (Join-Path $Path 'SKILL.md') -Content ("---`nname: $Name`ndescription: Test skill for canonical command result coverage.`n---`n`n$Body`n")
}

function Initialize-TestRepo {
    param([Parameter(Mandatory)] [string] $Path, [switch] $SkillLayout)
    [IO.Directory]::CreateDirectory($Path) | Out-Null
    Set-TestFile -Path (Join-Path $Path '.gitignore') -Content "tmp/`n"
    Set-TestFile -Path (Join-Path $Path 'README.md') -Content "fixture`n"
    if ($SkillLayout) {
        foreach ($relative in @(
            'skills-source/shared',
            'skills-source/claude-only',
            'skills-source/codex-only',
            'skills-source/reasonix-only',
            'claude/skills',
            'codex/skills',
            'reasonix/skills',
            'imports/skills-inbox',
            'manifests'
        )) {
            Set-TestFile -Path (Join-Path $Path (Join-Path $relative '.keep')) -Content ''
        }
        foreach ($manifest in @('managed-skills.claude.txt', 'managed-skills.codex.txt', 'managed-skills.reasonix.txt', 'managed-skills.txt')) {
            Set-TestFile -Path (Join-Path $Path (Join-Path 'manifests' $manifest)) -Content ''
        }
    }
    & git -C $Path init --quiet
    & git -C $Path config user.email test@example.invalid
    & git -C $Path config user.name canonical-command-result-test
    & git -C $Path add -- .
    & git -C $Path commit --quiet -m baseline
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize disposable Git repository: $Path" }
}

function Invoke-ScriptStreams {
    param([Parameter(Mandatory)] [string] $Script, [string[]] $Arguments = @())
    return Invoke-CanonicalIdentityFixtureScript -Fixture $identityFixture -ScriptPath $Script -Arguments $Arguments
}

function Confirm-CanonicalCommandResultJson {
    param([Parameter(Mandatory)] [string] $Json, [Parameter(Mandatory)] [string] $EvidenceRoot)
    $instancePath = Join-Path $EvidenceRoot ("result-{0}.json" -f [Guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($instancePath, $Json, [Text.UTF8Encoding]::new($false))
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json') -InstancePath $instancePath
    $document = ConvertFrom-SemanticJson -Json $Json
    $semantic = [Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $document))
    if ($Json -cne $semantic) { throw 'stdout is not the exact semantic JSON encoding' }
    return $document
}

function Get-ValidatedCanonicalCommandResult {
    param([Parameter(Mandatory)] $Invocation, [Parameter(Mandatory)] [string] $EvidenceRoot)
    $script:lastValidationError = ''
    try {
        $match = [regex]::Match([string] $Invocation.Stdout, '\A(\{[^\r\n]*\})(?:\r?\n)?\z')
        if (-not $match.Success) { throw 'stdout is not exactly one compact JSON line' }
        $json = $match.Groups[1].Value
        return (Confirm-CanonicalCommandResultJson -Json $json -EvidenceRoot $EvidenceRoot)
    }
    catch {
        $script:lastValidationError = $_.Exception.Message
        return $null
    }
}

function Get-ValidatedSandboxCanonicalCommandResult {
    # The sandbox host merges the child's stdout and stderr into one stream
    # (Out): exactly one compact semantic JSON line plus an optional trailing
    # public diagnostic token line (typed failures write that token to stderr).
    param([Parameter(Mandatory)] $Invocation, [Parameter(Mandatory)] [string] $EvidenceRoot)
    $script:lastValidationError = ''
    $script:lastSandboxDiagnostic = ''
    try {
        $match = [regex]::Match([string] $Invocation.Out, '\A(\{[^\r\n]*\})(?:\r?\n([A-Za-z0-9-]+))?(?:\r?\n)?\z')
        if (-not $match.Success) { throw 'sandbox output is not one compact JSON line with an optional diagnostic token' }
        if ($match.Groups[2].Success) { $script:lastSandboxDiagnostic = $match.Groups[2].Value }
        return (Confirm-CanonicalCommandResultJson -Json $match.Groups[1].Value -EvidenceRoot $EvidenceRoot)
    }
    catch {
        $script:lastValidationError = $_.Exception.Message
        return $null
    }
}

function Test-ExactDiagnosticToken {
    param([AllowEmptyString()] [string] $Stderr, [AllowEmptyString()] [string] $ExpectedToken)
    if ([string]::IsNullOrEmpty($ExpectedToken)) { return $Stderr -ceq '' }
    return $Stderr -cmatch ("\A{0}(?:\r?\n)?\z" -f [regex]::Escape($ExpectedToken))
}

function Test-CommandResult {
    param(
        [Parameter(Mandatory)] [AllowNull()] $Document,
        [Parameter(Mandatory)] [string] $Result,
        [Parameter(Mandatory)] [string] $CommandKind,
        [Parameter(Mandatory)] [string] $MessageToken
    )
    return (
        $null -ne $Document -and
        [string] $Document.ArtifactKind -ceq 'canonical-transaction-result' -and
        [string] $Document.ResultScope -ceq 'command' -and
        [string] $Document.Result -ceq $Result -and
        [string] $Document.CommandKind -ceq $CommandKind -and
        [string] $Document.LifecycleKind -ceq 'no-transaction' -and
        [string] $Document.MessageToken -ceq $MessageToken
    )
}

function Assert-CanonicalCommandFailure {
    param(
        [Parameter(Mandatory)] $Invocation,
        [Parameter(Mandatory)] [string] $EvidenceRoot,
        [Parameter(Mandatory)] [string] $CommandKind,
        [Parameter(Mandatory)] [string] $MessageToken,
        [Parameter(Mandatory)] [string] $Message,
        [ValidateSet('FAIL', 'WARN')] [string] $Result = 'FAIL',
        [int] $ExitCode = 1
    )
    $document = Get-ValidatedCanonicalCommandResult -Invocation $Invocation -EvidenceRoot $EvidenceRoot
    Assert ($Invocation.Code -eq $ExitCode -and (Test-ExactDiagnosticToken -Stderr $Invocation.Stderr -ExpectedToken $MessageToken) -and (Test-CommandResult -Document $document -Result $Result -CommandKind $CommandKind -MessageToken $MessageToken)) $Message
}

function Set-TestCurrentUserOnlyAcl {
    param([Parameter(Mandatory)][string]$Path)
    $sidText = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $sid = [Security.Principal.SecurityIdentifier]::new($sidText)
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inherit, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
    Set-Acl -LiteralPath $Path -AclObject $security
}

function Get-TestDirectoryTreeHash {
    param([Parameter(Mandatory)][string]$Root, [string[]]$ExcludeRelativePaths = @())
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return 'ABSENT' }
    return [string](Get-SafeTreeSnapshot -Root $Root -ExcludeRelativePaths $ExcludeRelativePaths).TreeHash
}

function Get-TestControlBaseHash {
    param([Parameter(Mandatory)][string]$ControlBase)
    $exclude = [Collections.Generic.List[string]]::new()
    $lockPath = Join-Path $ControlBase 'live-mutation.lock'
    if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
        $exclude.Add(([IO.Path]::GetRelativePath($ControlBase, $lockPath)).Replace([char]92, [char]47))
    }
    return (Get-TestDirectoryTreeHash -Root $ControlBase -ExcludeRelativePaths @($exclude))
}

$testRoot = Join-Path $identityFixture.Root 'cases'
$evidenceRoot = Join-Path $testRoot 'evidence'
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null
$setupScript = Join-Path $RepoRoot 'scripts/setup-canonical-transaction.ps1'
$transactionScript = Join-Path $RepoRoot 'scripts/canonical-transaction.ps1'
$recoveryScript = Join-Path $RepoRoot 'scripts/recover-canonical-transaction.ps1'
$normalizeScript = Join-Path $RepoRoot 'scripts/normalize-skill.ps1'
$promoteScript = Join-Path $RepoRoot 'scripts/promote-skill.ps1'
$mergeScript = Join-Path $RepoRoot 'scripts/auto-merge-skills.ps1'
$agentScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
$emitterScript = Join-Path $RepoRoot 'scripts/canonical-command-result.ps1'

try {
    if ($Section -eq 'all') {
    # An explicit invalid partial prefix makes all early refusal cases stable.
    # It is owned by this fixture; no real user's existing state is consulted.
    $fixturePartialBase = Join-Path $identityFixture.Home 'AppData/Local/ai-agent-dotfiles'
    $null = Assert-CanonicalIdentityFixturePath -Fixture $identityFixture -Path $fixturePartialBase
    [IO.Directory]::CreateDirectory($fixturePartialBase) | Out-Null
    Set-TestCurrentUserOnlyAcl -Path $fixturePartialBase
    $fixturePartialMarker = Join-Path $fixturePartialBase 'unexpected-test-entry'
    Set-TestFile -Path $fixturePartialMarker -Content 'owned partial-prefix refusal fixture'

    Write-CommandResultTestPhase 'fixture launch and cleanup boundary'
    foreach ($boundaryCase in @(
        @{ Name='child outside copy'; Script=(Join-Path $identityFixture.SourceRepoRoot 'scripts/setup-canonical-transaction.ps1'); Args=@() },
        @{ Name='repo outside root'; Script=$setupScript; Args=@('-RepoRoot',$identityFixture.SourceRepoRoot,'-Status') },
        @{ Name='plan outside root'; Script=$setupScript; Args=@('-PlanPath',(Join-Path (Split-Path -Parent $identityFixture.Root) 'outside-plan.json')) },
        @{ Name='relative repo'; Script=$setupScript; Args=@('-RepoRoot','../../outside','-Status') },
        @{ Name='relative plan'; Script=$setupScript; Args=@('-PlanPath','../../outside-plan.json') }
    )) {
        $rejected=$false
        try { $null=New-CanonicalIdentityFixtureProcessStartInfo -Fixture $identityFixture -ScriptPath $boundaryCase.Script -Arguments $boundaryCase.Args }
        catch { $rejected=$_.Exception.Message -match '^fixture-' }
        Assert $rejected ("fixture refuses {0} before starting a child" -f $boundaryCase.Name)
    }
    $boundaryTarget=Join-Path $testRoot 'boundary-target'; $boundaryLink=Join-Path $testRoot 'boundary-link'
    [IO.Directory]::CreateDirectory($boundaryTarget) | Out-Null
    New-Item -ItemType Junction -Path $boundaryLink -Target $boundaryTarget -ErrorAction Stop | Out-Null
    try {
        $rejected=$false
        try { $null=New-CanonicalIdentityFixtureProcessStartInfo -Fixture $identityFixture -ScriptPath $setupScript -Arguments @('-PlanPath',(Join-Path $boundaryLink 'plan.json')) }
        catch { $rejected=$_.Exception.Message -ceq 'fixture-reparse-path-refused' }
        Assert $rejected 'fixture refuses a reparse ancestor before starting a child'
        [IO.Directory]::Delete($boundaryTarget)
        $rejected=$false
        try { $null=New-CanonicalIdentityFixtureProcessStartInfo -Fixture $identityFixture -ScriptPath $setupScript -Arguments @('-PlanPath',(Join-Path $boundaryLink 'plan.json')) }
        catch { $rejected=$_.Exception.Message -ceq 'fixture-reparse-path-refused' }
        Assert $rejected 'fixture refuses a dangling reparse ancestor before starting a child'
        $rejected=$false
        try { Remove-CanonicalIdentityFixture -Fixture ([pscustomobject]@{Root=$identityFixture.Root;OwnerToken='wrong';Children=@()}) }
        catch { $rejected=$_.Exception.Message -ceq 'fixture-ownership-marker-mismatch' }
        Assert ($rejected -and (Test-Path -LiteralPath $identityFixture.Root)) 'cleanup refuses a foreign ownership token without deleting fixture bytes'
    }
    finally { [IO.Directory]::Delete($boundaryLink) }

    Write-CommandResultTestPhase 'shared public emitter'
    Assert (Test-Path -LiteralPath $emitterScript -PathType Leaf) 'one shared canonical public command-result emitter exists'
    if (Test-Path -LiteralPath $emitterScript -PathType Leaf) {
        $emitterText = Get-Content -Raw -LiteralPath $emitterScript
        Assert ($emitterText -match 'ConvertTo-SemanticJsonBytes' -and $emitterText -match 'artifact-contracts\.psd1' -and $emitterText -match 'Invoke-CanonicalContractSchemaValidation') 'shared emitter uses semantic bytes and registry-bound schema validation before stdout'
    }
    else { Assert $false 'shared emitter uses semantic bytes and registry-bound schema validation before stdout' }
    $runnerPolicy = Import-PowerShellDataFile -LiteralPath (Join-Path $RepoRoot 'scripts/runner-policy.psd1')
    Assert (@($runnerPolicy.ToolchainPaths) -ccontains 'scripts/canonical-command-result.ps1') 'shared public emitter is bound into the approved toolchain hash'
    foreach ($publicScript in @($setupScript, $transactionScript, $recoveryScript, $normalizeScript, $promoteScript)) {
        $text = Get-Content -Raw -LiteralPath $publicScript
        Assert ($text -notmatch 'ConvertTo-Json') "public emitter has no ad-hoc ConvertTo-Json: $([IO.Path]::GetFileName($publicScript))"
    }
    $mergeScriptText = Get-Content -Raw -LiteralPath $mergeScript
    Assert ($mergeScriptText -match 'canonical-command-result\.ps1' -and $mergeScriptText -match 'Write-CanonicalPublicCommandResult') 'merge failure path uses the shared public emitter while retaining report serialization'

    Write-CommandResultTestPhase 'setup status and dispatcher'
    $setupRepo = Join-Path $testRoot 'setup-repo'
    Initialize-TestRepo -Path $setupRepo

    $directStatus = Invoke-ScriptStreams -Script $setupScript -Arguments @('-Status', '-RepoRoot', $setupRepo)
    $directStatusDocument = Get-ValidatedCanonicalCommandResult -Invocation $directStatus -EvidenceRoot $evidenceRoot
    Assert ($directStatus.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $directStatus.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $directStatusDocument -Result WARN -CommandKind canonical-status -MessageToken canonical-setup-required)) 'direct setup status emits one schema-valid semantic command result and empty stderr'

    $routedStatus = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'status', '-RepoRoot', $setupRepo)
    $routedStatusDocument = Get-ValidatedCanonicalCommandResult -Invocation $routedStatus -EvidenceRoot $evidenceRoot
    Assert ($routedStatus.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $routedStatus.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $routedStatusDocument -Result WARN -CommandKind canonical-status -MessageToken canonical-setup-required) -and $routedStatus.Stdout -notmatch 'Invoking script|Command result') 'agent-dotfiles canonical status forwards only the child JSON with no dispatcher banner'

    Write-CommandResultTestPhase 'setup finalize, DryRun, and Apply interlock'
    $finalizeProbeControl = Join-Path $testRoot 'finalize-probe-control'
    $finalizeProbeRepoId = ('a' * 64)
    Assert ((Resolve-CanonicalSetupFinalizePublicToken -StatusToken 'canonical-ready' -ControlBaseRoot $finalizeProbeControl -RepoId $finalizeProbeRepoId) -ceq 'canonical-ready') 'non setup-required status tokens pass through the finalize resolver unchanged'
    Assert ((Resolve-CanonicalSetupFinalizePublicToken -StatusToken 'canonical-setup-required' -ControlBaseRoot $finalizeProbeControl -RepoId $finalizeProbeRepoId) -ceq 'canonical-setup-required') 'setup-required stays when the control base carries no repo claim file'
    Assert ((Resolve-CanonicalSetupFinalizePublicToken -StatusToken 'canonical-setup-required' -ControlBaseRoot $finalizeProbeControl -RepoId 'not-a-hash') -ceq 'canonical-setup-required') 'a noncanonical repo id never promotes the setup-required token'
    [IO.Directory]::CreateDirectory((Join-Path $finalizeProbeControl 'canonical-roots')) | Out-Null
    [IO.File]::WriteAllText((Join-Path (Join-Path $finalizeProbeControl 'canonical-roots') ($finalizeProbeRepoId + '.json')),'{}',[Text.UTF8Encoding]::new($false))
    Assert ((Resolve-CanonicalSetupFinalizePublicToken -StatusToken 'canonical-setup-required' -ControlBaseRoot $finalizeProbeControl -RepoId $finalizeProbeRepoId) -ceq 'setup-finalize-required') 'setup-required promotes to setup-finalize-required when the exact repo claim file exists'
    Assert ((Resolve-CanonicalSetupFinalizePublicToken -StatusToken 'canonical-setup-required' -ControlBaseRoot $finalizeProbeControl -RepoId ('b' * 64)) -ceq 'canonical-setup-required') 'a foreign repo id does not promote the setup-required token'

    $setupMissingPlan = Invoke-ScriptStreams -Script $setupScript -Arguments @('-DryRun', '-RepoRoot', $setupRepo)
    Assert-CanonicalCommandFailure -Invocation $setupMissingPlan -EvidenceRoot $evidenceRoot -CommandKind canonical-setup -MessageToken canonical-plan-required -Message 'setup missing PlanPath emits one typed failure result and exact token'

    $setupMissingParentPlan = Join-Path $testRoot 'missing-setup-parent/setup.json'
    $setupMissingParent = Invoke-ScriptStreams -Script $setupScript -Arguments @('-DryRun', '-RepoRoot', $setupRepo, '-PlanPath', $setupMissingParentPlan)
    Assert-CanonicalCommandFailure -Invocation $setupMissingParent -EvidenceRoot $evidenceRoot -CommandKind canonical-setup -MessageToken canonical-plan-parent-missing -Message 'setup missing PlanPath parent emits one typed failure result and exact token'

    $setupMissingApplyPlan = Join-Path $evidenceRoot 'missing-setup-apply.json'
    $setupMissingApply = Invoke-ScriptStreams -Script $setupScript -Arguments @('-Apply', '-RepoRoot', $setupRepo, '-PlanPath', $setupMissingApplyPlan)
    Assert-CanonicalCommandFailure -Invocation $setupMissingApply -EvidenceRoot $evidenceRoot -CommandKind canonical-setup -MessageToken canonical-plan-not-found -Message 'setup Apply missing reviewed plan emits one typed failure result and exact token'

    $setupPlan = Join-Path $evidenceRoot 'setup-plan.json'
    $inheritedValues=@{}
    foreach ($name in @('AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT','AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH','AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN','AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT')) {
        $inheritedValues[$name]=[Environment]::GetEnvironmentVariable($name,'Process')
        [Environment]::SetEnvironmentVariable($name,'invalid-fixture-capability','Process')
    }
    try { $setupDryRun = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-DryRun', '-PlanPath', $setupPlan) }
    finally { foreach ($name in $inheritedValues.Keys) { [Environment]::SetEnvironmentVariable($name,$inheritedValues[$name],'Process') } }
    $setupDryRunDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupDryRun -EvidenceRoot $evidenceRoot
    Assert ($setupDryRun.Code -eq 0 -and (Test-Path -LiteralPath $setupPlan -PathType Leaf) -and (Test-ExactDiagnosticToken -Stderr $setupDryRun.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $setupDryRunDocument -Result PASS -CommandKind canonical-setup -MessageToken canonical-plan-created) -and -not [string]::IsNullOrWhiteSpace([string] $setupDryRunDocument.PlanHash)) 'routed setup DryRun emits one validated plan result and empty stderr'
    $setupBoundPlan=ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($setupPlan,[Text.UTF8Encoding]::new($false,$true)))
    foreach ($field in @('CanonicalRecoveryRoot','ControlBase','BackupRoot')) {
        $null=Assert-CanonicalIdentityFixturePath -Fixture $identityFixture -Path ([string]$setupBoundPlan.PlanPayload.ExpectedSetupStateProjection[$field])
    }
    Assert (Test-Path -LiteralPath (Join-Path $identityFixture.Root 'identity-called')) 'invalid inherited capability never substitutes the host identity for the copied fixture adapter'

    $setupCollision = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-DryRun', '-PlanPath', $setupPlan)
    $setupCollisionDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupCollision -EvidenceRoot $evidenceRoot
    Assert ($setupCollision.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $setupCollision.Stderr -ExpectedToken canonical-plan-exists) -and (Test-CommandResult -Document $setupCollisionDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-plan-exists)) 'routed setup PlanPath collision emits one typed failure result, exact token, and preserves exit 1'

    $setupApply = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-Apply', '-PlanPath', $setupPlan)
    $setupApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupApply -EvidenceRoot $evidenceRoot
    if ($script:IsReleased) {
        Assert ($setupApply.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $setupApply.Stderr -ExpectedToken manual-recovery-required) -and (Test-CommandResult -Document $setupApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken manual-recovery-required) -and [string] $setupApplyDocument.PlanHash -ceq [string] $setupDryRunDocument.PlanHash) 'routed setup Apply revalidates the reviewed plan, emits one result plus exact stderr token, and fails closed at the manual-recovery gate'
    }
    else {
        Assert ($setupApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $setupApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $setupApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-apply-interlocked) -and [string] $setupApplyDocument.PlanHash -ceq [string] $setupDryRunDocument.PlanHash) 'routed setup Apply revalidates the reviewed plan, emits one result plus exact stderr token, and remains interlocked'
    }

    Set-TestFile -Path (Join-Path $setupRepo 'README.md') -Content "fixture advanced after review`n"
    & git -C $setupRepo add -- README.md
    & git -C $setupRepo commit --quiet -m advance-after-review
    if ($LASTEXITCODE -ne 0) { throw 'Unable to advance the disposable setup repository.' }
    $setupStale = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-Apply', '-PlanPath', $setupPlan)
    $setupStaleDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupStale -EvidenceRoot $evidenceRoot
    Assert ($setupStale.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $setupStale.Stderr -ExpectedToken canonical-plan-stale) -and (Test-CommandResult -Document $setupStaleDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-plan-stale) -and [string] $setupStaleDocument.PlanHash -ceq [string] $setupDryRunDocument.PlanHash) 'routed setup stale Apply emits one typed failure result, exact token, and preserves exit 1'

    Write-CommandResultTestPhase 'canonical transaction negative outcomes'
    $transactionRepo = Join-Path $testRoot 'transaction-negative-repo'
    Initialize-TestRepo -Path $transactionRepo -SkillLayout
    $candidateWorkspace = Join-Path $transactionRepo 'tmp/canonical-candidates/preflight-failure'
    foreach ($relative in @('skills-source/shared', 'skills-source/claude-only', 'skills-source/codex-only', 'skills-source/reasonix-only')) {
        [IO.Directory]::CreateDirectory((Join-Path $candidateWorkspace $relative)) | Out-Null
    }
    $preflightToken = 'sk-' + 'ant-' + ('P' * 24)
    $preflightInput = Join-Path $candidateWorkspace 'skills-source/shared/preflight-failure'
    New-TestSkill -Path $preflightInput -Name preflight-failure -Body ("## Steps`n`n- token: `"$preflightToken`"")
    $preflightFailurePlan = Join-Path $evidenceRoot 'transaction-preflight-failure.json'
    $preflightFailureRoot = Join-Path $evidenceRoot 'transaction-preflight-failure'
    $preflightFailure = Invoke-ScriptStreams -Script $transactionScript -Arguments @(
        '-RepoRoot', $transactionRepo, '-OperationKind', 'normalize', '-DryRun', '-PlanPath', $preflightFailurePlan,
        '-CandidateWorkspace', $candidateWorkspace, '-InputPath', $preflightInput, '-CanonicalPreflightOutputRoot', $preflightFailureRoot
    )
    $preflightFailureDocument = Get-ValidatedCanonicalCommandResult -Invocation $preflightFailure -EvidenceRoot $evidenceRoot
    Assert ($preflightFailure.Code -eq 1 -and -not (Test-Path -LiteralPath $preflightFailurePlan) -and (Test-ExactDiagnosticToken -Stderr $preflightFailure.Stderr -ExpectedToken canonical-preflight-failed) -and (Test-CommandResult -Document $preflightFailureDocument -Result FAIL -CommandKind canonical-normalize -MessageToken canonical-preflight-failed)) 'direct canonical preflight child failure emits one typed failure result, exact token, and preserves exit 1'

    $missingCandidate = Join-Path $transactionRepo 'tmp/canonical-candidates/missing'
    $genericFailurePlan = Join-Path $evidenceRoot 'transaction-generic-failure.json'
    $genericFailure = Invoke-ScriptStreams -Script $transactionScript -Arguments @(
        '-RepoRoot', $transactionRepo, '-OperationKind', 'normalize', '-DryRun', '-PlanPath', $genericFailurePlan,
        '-CandidateWorkspace', $missingCandidate, '-InputPath', $preflightInput, '-CanonicalPreflightOutputRoot', (Join-Path $evidenceRoot 'transaction-generic-failure')
    )
    $genericFailureDocument = Get-ValidatedCanonicalCommandResult -Invocation $genericFailure -EvidenceRoot $evidenceRoot
    Assert ($genericFailure.Code -eq 1 -and -not (Test-Path -LiteralPath $genericFailurePlan) -and (Test-ExactDiagnosticToken -Stderr $genericFailure.Stderr -ExpectedToken canonical-command-failed) -and (Test-CommandResult -Document $genericFailureDocument -Result FAIL -CommandKind canonical-normalize -MessageToken canonical-command-failed)) 'unclassified canonical runtime failure emits one generic typed result, exact token, and preserves exit 1'

    Write-CommandResultTestPhase 'normalize/promote early public outcomes'
    $adapterRepo = Join-Path $testRoot 'adapter-repo'
    Initialize-TestRepo -Path $adapterRepo -SkillLayout

    $normalizeInput = Join-Path $testRoot 'reasonix-incompatible'
    Set-TestFile -Path (Join-Path $normalizeInput 'SKILL.md') -Content "---`nname: reasonix-incompatible`ndescription: Claude-only test candidate.`nallowed-tools: Read`n---`n`n## Steps`n"

    foreach ($surface in @(
        [pscustomobject]@{ Name='normalize'; Script=$normalizeScript; CommandKind='canonical-normalize'; BaseArguments=@('-RepoRoot',$adapterRepo,'-InputSkillPath',$normalizeInput,'-TargetType','shared') },
        [pscustomobject]@{ Name='promote'; Script=$promoteScript; CommandKind='canonical-promote'; BaseArguments=@('-RepoRoot',$adapterRepo,'-InputSkillPath',$normalizeInput,'-TargetType','shared') },
        [pscustomobject]@{ Name='merge'; Script=$mergeScript; CommandKind='canonical-merge'; BaseArguments=@('-RepoRoot',$adapterRepo) }
    )) {
        $modePlan = Join-Path $evidenceRoot ("{0}-mode.json" -f $surface.Name)
        $modeFailure = Invoke-ScriptStreams -Script $surface.Script -Arguments (@($surface.BaseArguments) + @('-PlanPath',$modePlan))
        Assert-CanonicalCommandFailure -Invocation $modeFailure -EvidenceRoot $evidenceRoot -CommandKind $surface.CommandKind -MessageToken canonical-mode-invalid -Message "$($surface.Name) invalid mode emits one typed failure result and exact token"

        $missingPlanFailure = Invoke-ScriptStreams -Script $surface.Script -Arguments (@($surface.BaseArguments) + @('-DryRun'))
        Assert-CanonicalCommandFailure -Invocation $missingPlanFailure -EvidenceRoot $evidenceRoot -CommandKind $surface.CommandKind -MessageToken canonical-plan-required -Message "$($surface.Name) missing PlanPath emits one typed failure result and exact token"

        $missingApplyPlan = Join-Path $evidenceRoot ("{0}-missing-apply.json" -f $surface.Name)
        $missingApplyFailure = Invoke-ScriptStreams -Script $surface.Script -Arguments (@($surface.BaseArguments) + @('-Apply','-PlanPath',$missingApplyPlan))
        Assert-CanonicalCommandFailure -Invocation $missingApplyFailure -EvidenceRoot $evidenceRoot -CommandKind $surface.CommandKind -MessageToken canonical-plan-not-found -Message "$($surface.Name) Apply missing reviewed plan emits one typed failure result and exact token"

        $collisionPlan = Join-Path $evidenceRoot ("{0}-collision.json" -f $surface.Name)
        Set-TestFile -Path $collisionPlan -Content "collision`n"
        $collisionFailure = Invoke-ScriptStreams -Script $surface.Script -Arguments (@($surface.BaseArguments) + @('-DryRun','-PlanPath',$collisionPlan))
        Assert-CanonicalCommandFailure -Invocation $collisionFailure -EvidenceRoot $evidenceRoot -CommandKind $surface.CommandKind -MessageToken canonical-plan-exists -Message "$($surface.Name) PlanPath collision emits one typed failure result and exact token"
    }

    $mergeReportsPlan = Join-Path $evidenceRoot 'merge-reports-collision.json'
    [IO.Directory]::CreateDirectory($mergeReportsPlan + '.reports') | Out-Null
    $mergeReportsCollision = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot',$adapterRepo,'-DryRun','-PlanPath',$mergeReportsPlan)
    Assert-CanonicalCommandFailure -Invocation $mergeReportsCollision -EvidenceRoot $evidenceRoot -CommandKind canonical-merge -MessageToken canonical-artifact-exists -Message 'merge report-root collision emits one typed failure result and exact token'

    $candidateFailureRepo = Join-Path $testRoot 'candidate-failure-repo'
    Initialize-TestRepo -Path $candidateFailureRepo -SkillLayout
    Set-TestFile -Path (Join-Path $candidateFailureRepo '.gitignore') -Content "not-tmp/`n"
    & git -C $candidateFailureRepo add -- .gitignore
    & git -C $candidateFailureRepo commit --quiet -m remove-tmp-ignore
    if ($LASTEXITCODE -ne 0) { throw 'Unable to prepare candidate-builder failure repository.' }
    $candidateFailurePlan = Join-Path $evidenceRoot 'merge-candidate-failure.json'
    $candidateFailure = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot',$candidateFailureRepo,'-DryRun','-PlanPath',$candidateFailurePlan)
    Assert-CanonicalCommandFailure -Invocation $candidateFailure -EvidenceRoot $evidenceRoot -CommandKind canonical-merge -MessageToken canonical-candidate-failed -Message 'merge candidate-builder failure emits one generic typed result without exception detail'

    $normalizePlan = Join-Path $evidenceRoot 'normalize-quarantine.json'
    $normalize = Invoke-ScriptStreams -Script $normalizeScript -Arguments @('-RepoRoot', $adapterRepo, '-InputSkillPath', $normalizeInput, '-TargetType', 'reasonix-only', '-DryRun', '-PlanPath', $normalizePlan)
    $normalizeDocument = Get-ValidatedCanonicalCommandResult -Invocation $normalize -EvidenceRoot $evidenceRoot
    Assert ($normalize.Code -eq 2 -and -not (Test-Path -LiteralPath $normalizePlan) -and (Test-ExactDiagnosticToken -Stderr $normalize.Stderr -ExpectedToken platform-incompatible) -and (Test-CommandResult -Document $normalizeDocument -Result FAIL -CommandKind canonical-normalize -MessageToken platform-incompatible)) 'normalize quarantine emits one typed failure result and exact reason token on stderr'

    $routedNormalizePlan = Join-Path $evidenceRoot 'routed-normalize-quarantine.json'
    $routedNormalize = Invoke-ScriptStreams -Script $agentScript -Arguments @('skills', 'normalize', '-RepoRoot', $adapterRepo, '-InputSkillPath', $normalizeInput, '-TargetType', 'reasonix-only', '-DryRun', '-PlanPath', $routedNormalizePlan)
    $routedNormalizeDocument = Get-ValidatedCanonicalCommandResult -Invocation $routedNormalize -EvidenceRoot $evidenceRoot
    Assert ($routedNormalize.Code -eq 2 -and (Test-ExactDiagnosticToken -Stderr $routedNormalize.Stderr -ExpectedToken platform-incompatible) -and (Test-CommandResult -Document $routedNormalizeDocument -Result FAIL -CommandKind canonical-normalize -MessageToken platform-incompatible) -and $routedNormalize.Stdout -notmatch 'Invoking script|Command result') 'agent-dotfiles normalize route preserves the single canonical result without banners'

    $retainedCanonical = Join-Path $adapterRepo 'skills-source/shared/retained-promote'
    $retainedInput = Join-Path $testRoot 'retained-promote'
    New-TestSkill -Path $retainedCanonical -Name retained-promote
    New-TestSkill -Path $retainedInput -Name retained-promote
    $retainedPlan = Join-Path $evidenceRoot 'promote-retained.json'
    $retained = Invoke-ScriptStreams -Script $promoteScript -Arguments @('-RepoRoot', $adapterRepo, '-InputSkillPath', $retainedInput, '-TargetType', 'shared', '-DryRun', '-PlanPath', $retainedPlan)
    $retainedDocument = Get-ValidatedCanonicalCommandResult -Invocation $retained -EvidenceRoot $evidenceRoot
    Assert ($retained.Code -eq 3 -and -not (Test-Path -LiteralPath $retainedPlan) -and (Test-ExactDiagnosticToken -Stderr $retained.Stderr -ExpectedToken canonical-retained) -and (Test-CommandResult -Document $retainedDocument -Result WARN -CommandKind canonical-promote -MessageToken canonical-retained)) 'promote retained emits one typed warning result and exact diagnostic token'

    $quarantineInput = Join-Path $testRoot 'promote-quarantine'
    $fakeToken = 'sk-' + 'ant-' + ('Q' * 24)
    New-TestSkill -Path $quarantineInput -Name promote-quarantine -Body ("## Steps`n`n- token: `"$fakeToken`"")
    $quarantinePlan = Join-Path $evidenceRoot 'promote-quarantine.json'
    $quarantine = Invoke-ScriptStreams -Script $promoteScript -Arguments @('-RepoRoot', $adapterRepo, '-InputSkillPath', $quarantineInput, '-TargetType', 'shared', '-DryRun', '-PlanPath', $quarantinePlan)
    $quarantineDocument = Get-ValidatedCanonicalCommandResult -Invocation $quarantine -EvidenceRoot $evidenceRoot
    Assert ($quarantine.Code -eq 2 -and -not (Test-Path -LiteralPath $quarantinePlan) -and (Test-ExactDiagnosticToken -Stderr $quarantine.Stderr -ExpectedToken possible-secret) -and (Test-CommandResult -Document $quarantineDocument -Result FAIL -CommandKind canonical-promote -MessageToken possible-secret)) 'promote quarantine emits one typed failure result and exact reason token on stderr'

    Write-CommandResultTestPhase 'canonical merge outcomes and aliases'
    $normalMergeRepo = Join-Path $testRoot 'normal-merge-repo'
    Initialize-TestRepo -Path $normalMergeRepo -SkillLayout
    New-TestSkill -Path (Join-Path $normalMergeRepo 'imports/skills-inbox/machine/claude/merge-promote') -Name merge-promote
    $normalMergePlan = Join-Path $evidenceRoot 'normal-merge.json'
    $normalMerge = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $normalMergeRepo, '-DryRun', '-PlanPath', $normalMergePlan)
    $normalMergeDocument = Get-ValidatedCanonicalCommandResult -Invocation $normalMerge -EvidenceRoot $evidenceRoot
    Assert ($normalMerge.Code -eq 0 -and (Test-Path -LiteralPath $normalMergePlan -PathType Leaf) -and (Test-ExactDiagnosticToken -Stderr $normalMerge.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $normalMergeDocument -Result PASS -CommandKind canonical-merge -MessageToken canonical-plan-created)) 'merge normal path emits one child result and empty stderr'

    $normalMergeApply = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $normalMergeRepo, '-Apply', '-PlanPath', $normalMergePlan)
    $normalMergeApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $normalMergeApply -EvidenceRoot $evidenceRoot
    if ($script:IsReleased) {
        Assert ($normalMergeApply.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $normalMergeApply.Stderr -ExpectedToken canonical-setup-required) -and (Test-CommandResult -Document $normalMergeApplyDocument -Result WARN -CommandKind canonical-merge -MessageToken canonical-setup-required)) 'merge Apply emits one closed result and exact diagnostic token at the setup gate'
    }
    else {
        Assert ($normalMergeApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $normalMergeApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $normalMergeApplyDocument -Result FAIL -CommandKind canonical-merge -MessageToken canonical-apply-interlocked)) 'merge Apply emits one interlocked result and exact diagnostic token'
    }

    $retainedMergeRepo = Join-Path $testRoot 'retained-merge-repo'
    Initialize-TestRepo -Path $retainedMergeRepo -SkillLayout
    New-TestSkill -Path (Join-Path $retainedMergeRepo 'skills-source/shared/retained-merge') -Name retained-merge -Body "## Canonical`n"
    New-TestSkill -Path (Join-Path $retainedMergeRepo 'imports/skills-inbox/machine/claude/retained-merge') -Name retained-merge -Body "## Candidate`n"
    $retainedMergePlan = Join-Path $evidenceRoot 'retained-merge.json'
    $retainedMerge = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $retainedMergeRepo, '-DryRun', '-PlanPath', $retainedMergePlan)
    $retainedMergeDocument = Get-ValidatedCanonicalCommandResult -Invocation $retainedMerge -EvidenceRoot $evidenceRoot
    $retainedMergeReport = if (Test-Path -LiteralPath ($retainedMergePlan + '.reports/auto-merge-report.json')) { Get-Content -Raw -LiteralPath ($retainedMergePlan + '.reports/auto-merge-report.json') | ConvertFrom-Json -Depth 50 } else { $null }
    Assert ($retainedMerge.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $retainedMerge.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $retainedMergeDocument -Result PASS -CommandKind canonical-merge -MessageToken canonical-plan-created) -and @($retainedMergeReport.decisions | Where-Object status -eq 'CANONICAL_RETAINED').Count -eq 1) 'merge retained path keeps its report decision and emits only one canonical result'

    $quarantineMergeRepo = Join-Path $testRoot 'quarantine-merge-repo'
    Initialize-TestRepo -Path $quarantineMergeRepo -SkillLayout
    $mergeToken = 'sk-' + 'ant-' + ('M' * 24)
    New-TestSkill -Path (Join-Path $quarantineMergeRepo 'imports/skills-inbox/machine/claude/quarantine-merge') -Name quarantine-merge -Body ("## Steps`n`n- token: `"$mergeToken`"")
    $quarantineMergePlan = Join-Path $evidenceRoot 'quarantine-merge.json'
    $quarantineMerge = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $quarantineMergeRepo, '-DryRun', '-PlanPath', $quarantineMergePlan)
    $quarantineMergeDocument = Get-ValidatedCanonicalCommandResult -Invocation $quarantineMerge -EvidenceRoot $evidenceRoot
    $quarantineMergeReport = if (Test-Path -LiteralPath ($quarantineMergePlan + '.reports/auto-merge-report.json')) { Get-Content -Raw -LiteralPath ($quarantineMergePlan + '.reports/auto-merge-report.json') | ConvertFrom-Json -Depth 50 } else { $null }
    Assert ($quarantineMerge.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $quarantineMerge.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $quarantineMergeDocument -Result PASS -CommandKind canonical-merge -MessageToken canonical-plan-created) -and @($quarantineMergeReport.decisions | Where-Object status -eq 'QUARANTINED').Count -eq 1) 'merge quarantine path keeps its report decision and emits only one canonical result'

    $noActionMergeRepo = Join-Path $testRoot 'no-action-merge-repo'
    Initialize-TestRepo -Path $noActionMergeRepo -SkillLayout
    $noActionMergePlan = Join-Path $evidenceRoot 'no-action-merge.json'
    $noActionMerge = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $noActionMergeRepo, '-DryRun', '-PlanPath', $noActionMergePlan)
    $noActionMergeDocument = Get-ValidatedCanonicalCommandResult -Invocation $noActionMerge -EvidenceRoot $evidenceRoot
    $noActionMergeReport = if (Test-Path -LiteralPath ($noActionMergePlan + '.reports/auto-merge-report.json')) { Get-Content -Raw -LiteralPath ($noActionMergePlan + '.reports/auto-merge-report.json') | ConvertFrom-Json -Depth 50 } else { $null }
    Assert ($noActionMerge.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $noActionMerge.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $noActionMergeDocument -Result PASS -CommandKind canonical-merge -MessageToken canonical-plan-created) -and [long] $noActionMergeReport.scanned_skill_count -eq 0) 'merge no-action path emits one canonical result and preserves the empty report'

    $failureMergeRepo = Join-Path $testRoot 'failure-merge-repo'
    Initialize-TestRepo -Path $failureMergeRepo -SkillLayout
    $canonicalToken = 'sk-' + 'ant-' + ('F' * 24)
    New-TestSkill -Path (Join-Path $failureMergeRepo 'skills-source/shared/failure-merge') -Name failure-merge -Body ("## Steps`n`n- token: `"$canonicalToken`"")
    New-TestSkill -Path (Join-Path $failureMergeRepo 'imports/skills-inbox/machine/claude/failure-merge') -Name failure-merge
    $failureMergePlan = Join-Path $evidenceRoot 'failure-merge.json'
    $failureMerge = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $failureMergeRepo, '-DryRun', '-PlanPath', $failureMergePlan)
    $failureMergeDocument = Get-ValidatedCanonicalCommandResult -Invocation $failureMerge -EvidenceRoot $evidenceRoot
    Assert ($failureMerge.Code -eq 1 -and -not (Test-Path -LiteralPath $failureMergePlan) -and (Test-ExactDiagnosticToken -Stderr $failureMerge.Stderr -ExpectedToken canonical-merge-preflight-failed) -and (Test-CommandResult -Document $failureMergeDocument -Result FAIL -CommandKind canonical-merge -MessageToken canonical-merge-preflight-failed)) 'merge preflight failure emits one typed failure result and exact diagnostic token'

    foreach ($alias in @(
        [pscustomobject]@{ Name = 'top-level'; Prefix = @('merge') },
        [pscustomobject]@{ Name = 'skills'; Prefix = @('skills', 'merge') }
    )) {
        $aliasRepo = Join-Path $testRoot ("alias-{0}-merge-repo" -f $alias.Name)
        Initialize-TestRepo -Path $aliasRepo -SkillLayout
        $aliasPlan = Join-Path $evidenceRoot ("alias-{0}-merge.json" -f $alias.Name)
        $aliasArguments = @($alias.Prefix) + @('-RepoRoot', $aliasRepo, '-DryRun', '-PlanPath', $aliasPlan)
        $aliasInvocation = Invoke-ScriptStreams -Script $agentScript -Arguments $aliasArguments
        $aliasDocument = Get-ValidatedCanonicalCommandResult -Invocation $aliasInvocation -EvidenceRoot $evidenceRoot
        Assert ($aliasInvocation.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $aliasInvocation.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $aliasDocument -Result PASS -CommandKind canonical-merge -MessageToken canonical-plan-created) -and $aliasInvocation.Stdout -notmatch 'Invoking script|Command result') "agent-dotfiles $($alias.Name) merge alias emits only the child canonical result"
    }

    Write-CommandResultTestPhase 'production apply with a known invalid partial prefix'
    . (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
    . (Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1')

    $lockWait = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'status', '-RepoRoot', $setupRepo, '-LockWaitSeconds', '1')
    Assert ($lockWait.Code -ne 0) 'public protocol still rejects -LockWaitSeconds 1'

    $missingRepo = Join-Path $testRoot 'lock-order-missing-repo'
    Initialize-TestRepo -Path $missingRepo
    $missingPlan = Join-Path $evidenceRoot 'lock-order-missing-setup.json'
    $missingDry = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $missingRepo, '-DryRun', '-PlanPath', $missingPlan)
    $missingDryDocument = Get-ValidatedCanonicalCommandResult -Invocation $missingDry -EvidenceRoot $evidenceRoot
    Assert ($missingDry.Code -eq 0 -and (Test-CommandResult -Document $missingDryDocument -Result PASS -CommandKind canonical-setup -MessageToken canonical-plan-created)) 'lock-order MISSING fixture publishes a reviewed setup plan'
    $missingSelection = Get-CanonicalPrivateRootSelection -RepoRoot $missingRepo
    $missingControlBefore = Get-TestControlBaseHash -ControlBase ([string]$missingSelection.ControlBase)
    $missingPrivateBefore = Get-TestDirectoryTreeHash -Root ([string](Split-Path -Parent $missingSelection.ControlBase))
    $missingStatusBefore = Get-TestDirectoryTreeHash -Root $missingRepo
    $missingStatus = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'status', '-RepoRoot', $missingRepo)
    $missingStatusDocument = Get-ValidatedCanonicalCommandResult -Invocation $missingStatus -EvidenceRoot $evidenceRoot
    $missingStatusAfter = Get-TestDirectoryTreeHash -Root $missingRepo
    $missingPrivateAfterStatus = Get-TestDirectoryTreeHash -Root ([string](Split-Path -Parent $missingSelection.ControlBase))
    Assert ($missingStatus.Code -eq 0 -and $missingStatusBefore -ceq $missingStatusAfter -and $missingPrivateBefore -ceq $missingPrivateAfterStatus -and (Test-CommandResult -Document $missingStatusDocument -Result WARN -CommandKind canonical-status -MessageToken canonical-setup-required)) 'status remains MetadataOnly: zero-write on the repo and private prefix'
    $missingApply = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $missingRepo, '-Apply', '-PlanPath', $missingPlan)
    $missingApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $missingApply -EvidenceRoot $evidenceRoot
    $missingControlAfter = Get-TestControlBaseHash -ControlBase ([string]$missingSelection.ControlBase)
    $missingPrivateAfter = Get-TestDirectoryTreeHash -Root ([string](Split-Path -Parent $missingSelection.ControlBase))
    if ($script:IsReleased) {
        Assert ($missingApply.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $missingApply.Stderr -ExpectedToken manual-recovery-required) -and (Test-CommandResult -Document $missingApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken manual-recovery-required) -and [string]$missingApplyDocument.PlanHash -ceq [string]$missingDryDocument.PlanHash) 'MISSING setup Apply fails closed at the manual-recovery gate with the same PlanHash'
    }
    else {
        Assert ($missingApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $missingApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $missingApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-apply-interlocked) -and [string]$missingApplyDocument.PlanHash -ceq [string]$missingDryDocument.PlanHash) 'MISSING setup Apply stays interlocked with the same PlanHash'
    }
    Assert ($missingControlBefore -ceq $missingControlAfter -and $missingPrivateBefore -ceq $missingPrivateAfter) 'MISSING setup Apply creates no ControlBase or private prefix'

    $partialContext = Resolve-HomeAuthorityContextFromIdentity -Identity (Get-WindowsHomeAuthorityIdentity)

    $completeRepo = Join-Path $testRoot 'lock-order-complete-repo'
    Initialize-TestRepo -Path $completeRepo
    $completePlan = Join-Path $evidenceRoot 'lock-order-complete-setup.json'
    $completeDry = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $completeRepo, '-DryRun', '-PlanPath', $completePlan)
    $completeDryDocument = Get-ValidatedCanonicalCommandResult -Invocation $completeDry -EvidenceRoot $evidenceRoot
    Assert ($completeDry.Code -eq 0 -and (Test-CommandResult -Document $completeDryDocument -Result PASS -CommandKind canonical-setup -MessageToken canonical-plan-created)) 'the explicit partial-prefix fixture with an existing lock publishes a reviewed setup plan'
    $completeGit = Get-CanonicalGitContext -RepoRoot $completeRepo
    $completePaths = Get-CanonicalTransactionContractPaths -GitContext $completeGit
    $completeCreatedLock = Enter-CanonicalRepoLock -LockPath ([string]$completePaths.LockPath) -AllowCreate
    Exit-CanonicalRepoLock -LockHandle $completeCreatedLock
    $completeClaimBefore = Get-TestDirectoryTreeHash -Root ([string]$partialContext.CanonicalRootsRoot)
    $completeStateBefore = if (Test-Path -LiteralPath ([string]$completePaths.SetupStatePath) -PathType Leaf) { [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$completePaths.SetupStatePath)).ToLowerInvariant() } else { 'ABSENT' }
    $completeApply = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $completeRepo, '-Apply', '-PlanPath', $completePlan)
    $completeApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $completeApply -EvidenceRoot $evidenceRoot
    $completeClaimAfter = Get-TestDirectoryTreeHash -Root ([string]$partialContext.CanonicalRootsRoot)
    $completeStateAfter = if (Test-Path -LiteralPath ([string]$completePaths.SetupStatePath) -PathType Leaf) { [Convert]::ToHexString([IO.File]::ReadAllBytes([string]$completePaths.SetupStatePath)).ToLowerInvariant() } else { 'ABSENT' }
    if ($script:IsReleased) {
        Assert ($completeApply.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $completeApply.Stderr -ExpectedToken manual-recovery-required) -and (Test-CommandResult -Document $completeApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken manual-recovery-required) -and [string]$completeApplyDocument.PlanHash -ceq [string]$completeDryDocument.PlanHash) 'setup Apply with an existing canonical.lock fails closed at the manual-recovery gate and keeps the PlanHash'
    }
    else {
        Assert ($completeApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $completeApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $completeApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-apply-interlocked) -and [string]$completeApplyDocument.PlanHash -ceq [string]$completeDryDocument.PlanHash) 'setup Apply with an existing canonical.lock still interlocks and keeps the PlanHash'
    }
    Assert ($completeClaimBefore -ceq $completeClaimAfter -and $completeStateBefore -ceq $completeStateAfter) 'setup Apply is zero-write on claims and setup-state'


        $heldCanonical = Enter-CanonicalRepoLock -LockPath ([string]$completePaths.LockPath)
        try {
            $nonCompleteBusy = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $completeRepo, '-Apply', '-PlanPath', $completePlan)
            $nonCompleteBusyDocument = Get-ValidatedCanonicalCommandResult -Invocation $nonCompleteBusy -EvidenceRoot $evidenceRoot
            if ($script:IsReleased) {
                Assert ($nonCompleteBusy.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $nonCompleteBusy.Stderr -ExpectedToken manual-recovery-required) -and (Test-CommandResult -Document $nonCompleteBusyDocument -Result FAIL -CommandKind canonical-setup -MessageToken manual-recovery-required)) 'without a COMPLETE live prefix, a held canonical.lock still fails closed at the manual-recovery gate'
            }
            else {
                Assert ($nonCompleteBusy.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $nonCompleteBusy.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $nonCompleteBusyDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-apply-interlocked)) 'without a COMPLETE live prefix, a held canonical.lock does not change the interlock token'
            }
        }
        finally { Exit-CanonicalRepoLock -LockHandle $heldCanonical }
        $afterHoldApply = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $completeRepo, '-Apply', '-PlanPath', $completePlan)
        $afterHoldApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $afterHoldApply -EvidenceRoot $evidenceRoot
        if ($script:IsReleased) {
            Assert ($afterHoldApply.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $afterHoldApply.Stderr -ExpectedToken manual-recovery-required) -and (Test-CommandResult -Document $afterHoldApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken manual-recovery-required)) 'after releasing the repo lock, setup Apply fails closed at the manual-recovery gate'
        }
        else {
            Assert ($afterHoldApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $afterHoldApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $afterHoldApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-apply-interlocked)) 'after releasing the repo lock, setup Apply remains canonical-apply-interlocked'
        }


    # The deliberately invalid prefix was never accepted by any Apply above.
    # Remove only the exact seeded bytes, after checking ownership and shape.
    $null = Assert-CanonicalIdentityFixturePath -Fixture $identityFixture -Path $fixturePartialBase
    $partialEntries = @([IO.Directory]::EnumerateFileSystemEntries($fixturePartialBase))
    if ($partialEntries.Count -ne 1 -or $partialEntries[0] -cne $fixturePartialMarker -or
        [IO.File]::ReadAllText($fixturePartialMarker) -cne 'owned partial-prefix refusal fixture') {
        throw 'partial-prefix-fixture-changed-unexpectedly'
    }
    $null = Assert-CanonicalIdentityFixturePath -Fixture $identityFixture -Path $fixturePartialMarker
    [IO.File]::Delete($fixturePartialMarker)
    [IO.Directory]::Delete($fixturePartialBase)

    $recoverRepo = Join-Path $testRoot 'lock-order-recover-repo'
    Initialize-TestRepo -Path $recoverRepo
    $recoverPrivate = Join-Path $testRoot 'lock-order-recover-private'
    $recoverRecovery = Join-Path $recoverPrivate 'recovery'
    $recoverControl = Join-Path $recoverPrivate 'control'
    $recoverBackup = Join-Path $recoverPrivate 'backups'
    $recoverProbe = Join-Path $testRoot 'lock-order-recover-probe'
    foreach ($path in @($recoverRecovery, $recoverControl, $recoverBackup, $recoverProbe)) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    foreach ($path in @($recoverRecovery, $recoverControl, $recoverBackup)) { Set-TestCurrentUserOnlyAcl -Path $path }
    $recoverPayload = New-CanonicalSetupPlanPayload -RepoRoot $recoverRepo -CanonicalRecoveryRoot $recoverRecovery -ControlBase $recoverControl -BackupRoot $recoverBackup -ProbeRoot $recoverProbe -ToolchainRoot $RepoRoot
    $recoverGit = Get-CanonicalGitContext -RepoRoot $recoverRepo
    $recoverPaths = Get-CanonicalTransactionContractPaths -GitContext $recoverGit
    $recoverCreatedLock = Enter-CanonicalRepoLock -LockPath ([string]$recoverPaths.LockPath) -AllowCreate
    Exit-CanonicalRepoLock -LockHandle $recoverCreatedLock
    $recoverId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $recoverNamespace = Join-Path $recoverPaths.TransactionsRoot (Join-Path $recoverGit.WorktreeId $recoverId)
    $recoverHeader = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'canonical-journal-header'
        TransactionId = $recoverId
        CanonicalOperationKind = 'setup'
        OriginalDocumentHash = (Get-SemanticJsonHash -InputObject ([ordered]@{ TransactionId = $recoverId; Kind = 'setup' }))
        OriginalPlanHash = ('2' * 64)
        RepoId = [string]$recoverPayload.ExpectedSetupStateProjection.RepoId
        GitCommonDirHash = [string]$recoverGit.GitCommonDirHash
        WorktreeId = [string]$recoverGit.WorktreeId
        TransactionNamespace = [IO.Path]::GetFullPath($recoverNamespace)
        RecoveryTransactionRoot = Join-Path $recoverRecovery (Join-Path $recoverGit.WorktreeId $recoverId)
        ExpectedPostconditionsHash = [string]$recoverPayload.ExpectedPostconditionsHash
        Targets = @()
        SetupRecovery = [ordered]@{
            ClaimPath = Join-Path $recoverControl (Join-Path 'canonical-roots' ([string]$recoverPayload.ExpectedSetupStateProjection.RepoId + '.json'))
            StatePath = [string]$recoverPaths.SetupStatePath
            ExpectedClaim = $recoverPayload.ExpectedRootClaim
            ExpectedClaimHash = [string]$recoverPayload.ExpectedRootClaimHash
            ExpectedStateProjection = $recoverPayload.ExpectedSetupStateProjection
            ExpectedStateProjectionHash = [string]$recoverPayload.ExpectedSetupStateProjectionHash
        }
    }
    $null = New-CanonicalJournalHeader -Document $recoverHeader -TransactionNamespace $recoverNamespace
    $recoverPlan = Join-Path $evidenceRoot 'lock-order-recover.json'
    $recoverDry = Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot', $recoverRepo, '-Action', 'abandon', '-TransactionId', $recoverId, '-DryRun', '-PlanPath', $recoverPlan)
    $recoverDryDocument = Get-ValidatedCanonicalCommandResult -Invocation $recoverDry -EvidenceRoot $evidenceRoot
    Assert ($recoverDry.Code -eq 0 -and (Test-CommandResult -Document $recoverDryDocument -Result PASS -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-plan-created)) 'recover DryRun still writes one plan without taking global'
    $recoverControlBefore = Get-TestControlBaseHash -ControlBase ([string]$partialContext.ControlBase)
    $recoverApply = Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot', $recoverRepo, '-Action', 'abandon', '-TransactionId', $recoverId, '-Apply', '-PlanPath', $recoverPlan)
    $recoverApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $recoverApply -EvidenceRoot $evidenceRoot
    $recoverControlAfter = Get-TestControlBaseHash -ControlBase ([string]$partialContext.ControlBase)
    if ($script:IsReleased) {
        Assert ($recoverApply.Code -eq 0 -and [string] $recoverApply.Stderr -ceq '' -and (Test-CommandResult -Document $recoverApplyDocument -Result PASS -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-applied)) 'recover Apply completes the reviewed abandon under the released policy'
    }
    else {
        Assert ($recoverApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $recoverApply.Stderr -ExpectedToken canonical-recovery-apply-interlocked) -and (Test-CommandResult -Document $recoverApplyDocument -Result FAIL -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-apply-interlocked)) 'recover Apply stays interlocked'
    }
    Assert ($recoverControlBefore -ceq $recoverControlAfter) 'recover Apply is zero-write on ControlBase claims and prefix'


        $recoverLockBusy = Enter-CanonicalRepoLock -LockPath ([string]$recoverPaths.LockPath)
        try {
            $recoverHeld = Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot', $recoverRepo, '-Action', 'abandon', '-TransactionId', $recoverId, '-Apply', '-PlanPath', $recoverPlan)
            Assert-CanonicalCommandFailure -Invocation $recoverHeld -EvidenceRoot $evidenceRoot -CommandKind canonical-recover-abandon -MessageToken operation-lock-busy -Message 'recover Apply against a held canonical.lock emits operation-lock-busy' -Result WARN -ExitCode 1
        }
        finally { Exit-CanonicalRepoLock -LockHandle $recoverLockBusy }
        $recoverAfterHold = Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot', $recoverRepo, '-Action', 'abandon', '-TransactionId', $recoverId, '-Apply', '-PlanPath', $recoverPlan)
        $recoverAfterHoldDocument = Get-ValidatedCanonicalCommandResult -Invocation $recoverAfterHold -EvidenceRoot $evidenceRoot
        if ($script:IsReleased) {
            Assert ($recoverAfterHold.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $recoverAfterHold.Stderr -ExpectedToken reviewed-plan-consumed) -and (Test-CommandResult -Document $recoverAfterHoldDocument -Result FAIL -CommandKind canonical-recover-abandon -MessageToken reviewed-plan-consumed)) 'after releasing the repo lock, recover Apply returns reviewed-plan-consumed because the released Apply already completed the abandon'
        }
        else {
            Assert ($recoverAfterHold.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $recoverAfterHold.Stderr -ExpectedToken canonical-recovery-apply-interlocked) -and (Test-CommandResult -Document $recoverAfterHoldDocument -Result FAIL -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-apply-interlocked)) 'after releasing the repo lock, recover Apply returns to canonical-recovery-apply-interlocked'
        }


    }
    else {
        . (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
        . (Join-Path $RepoRoot 'scripts/canonical-recovery-common.ps1')
    }
    Write-CommandResultTestPhase 'production engine fixture preparation'
    # The capability covers the whole owned fixture, including the identity's
    # private prefix, bootstrap lock, recovery root and copied tool cache.
    $engineSandboxRoot = Join-Path $testRoot 'engine'
    $engineRepo = Join-Path $engineSandboxRoot 'repo'
    [IO.Directory]::CreateDirectory($engineSandboxRoot) | Out-Null
    Initialize-TestRepo -Path $engineRepo -SkillLayout
    New-TestSkill -Path (Join-Path $engineRepo 'skills-source/shared/engine-skill') -Name engine-skill -Body "## Steps`n`n- before"
    & git -C $engineRepo add -- .
    & git -C $engineRepo commit --quiet -m engine-fixture
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the engine sandbox fixture.' }

    Write-CommandResultTestPhase 'recover apply engine'
    $engineRecoverPrivate = Join-Path $engineSandboxRoot 'recover-private'
    $engineRecoverRecovery = Join-Path $engineRecoverPrivate 'recovery'
    $engineRecoverControl = Join-Path $engineRecoverPrivate 'control'
    $engineRecoverBackup = Join-Path $engineRecoverPrivate 'backups'
    $engineRecoverProbe = Join-Path $engineSandboxRoot 'recover-probe'
    foreach ($path in @($engineRecoverRecovery, $engineRecoverControl, $engineRecoverBackup, $engineRecoverProbe)) {
        [IO.Directory]::CreateDirectory($path) | Out-Null
    }
    foreach ($path in @($engineRecoverRecovery, $engineRecoverControl, $engineRecoverBackup)) { Set-TestCurrentUserOnlyAcl -Path $path }
    $engineRecoverPayload = New-CanonicalSetupPlanPayload -RepoRoot $engineRepo -CanonicalRecoveryRoot $engineRecoverRecovery -ControlBase $engineRecoverControl -BackupRoot $engineRecoverBackup -ProbeRoot $engineRecoverProbe -ToolchainRoot $RepoRoot
    $engineRecoverGit = Get-CanonicalGitContext -RepoRoot $engineRepo
    $engineRecoverPaths = Get-CanonicalTransactionContractPaths -GitContext $engineRecoverGit
    $engineRecoverCreatedLock = Enter-CanonicalRepoLock -LockPath ([string]$engineRecoverPaths.LockPath) -AllowCreate
    Exit-CanonicalRepoLock -LockHandle $engineRecoverCreatedLock
    $engineRecoverId = [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    $engineRecoverNamespace = Join-Path $engineRecoverPaths.TransactionsRoot (Join-Path $engineRecoverGit.WorktreeId $engineRecoverId)
    $engineRecoverHeader = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'canonical-journal-header'
        TransactionId = $engineRecoverId
        CanonicalOperationKind = 'setup'
        OriginalDocumentHash = ('1' * 64)
        OriginalPlanHash = ('2' * 64)
        RepoId = [string]$engineRecoverPayload.ExpectedSetupStateProjection.RepoId
        GitCommonDirHash = [string]$engineRecoverGit.GitCommonDirHash
        WorktreeId = [string]$engineRecoverGit.WorktreeId
        TransactionNamespace = [IO.Path]::GetFullPath($engineRecoverNamespace)
        RecoveryTransactionRoot = Join-Path $engineRecoverRecovery (Join-Path $engineRecoverGit.WorktreeId $engineRecoverId)
        ExpectedPostconditionsHash = [string]$engineRecoverPayload.ExpectedPostconditionsHash
        Targets = @()
        SetupRecovery = [ordered]@{
            ClaimPath = Join-Path $engineRecoverControl (Join-Path 'canonical-roots' ([string]$engineRecoverPayload.ExpectedSetupStateProjection.RepoId + '.json'))
            StatePath = [string]$engineRecoverPaths.SetupStatePath
            ExpectedClaim = $engineRecoverPayload.ExpectedRootClaim
            ExpectedClaimHash = [string]$engineRecoverPayload.ExpectedRootClaimHash
            ExpectedStateProjection = $engineRecoverPayload.ExpectedSetupStateProjection
            ExpectedStateProjectionHash = [string]$engineRecoverPayload.ExpectedSetupStateProjectionHash
        }
    }
    $null = New-CanonicalJournalHeader -Document $engineRecoverHeader -TransactionNamespace $engineRecoverNamespace
    $engineRecoverPlan = Join-Path $engineSandboxRoot 'recover-abandon-plan.json'
    $engineRecoverDry = Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot', $engineRepo, '-Action', 'abandon', '-TransactionId', $engineRecoverId, '-DryRun', '-PlanPath', $engineRecoverPlan)
    $engineRecoverDryDocument = Get-ValidatedCanonicalCommandResult -Invocation $engineRecoverDry -EvidenceRoot $evidenceRoot
    Assert ($engineRecoverDry.Code -eq 0 -and (Test-CommandResult -Document $engineRecoverDryDocument -Result PASS -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-plan-created)) 'the sandboxed fixture publishes a reviewed recovery plan'
    $engineRecoverApply = Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $recoveryScript -Arguments @('-RepoRoot', $engineRepo, '-Action', 'abandon', '-TransactionId', $engineRecoverId, '-Apply', '-PlanPath', $engineRecoverPlan)
    $engineRecoverApplyDocument = Get-ValidatedSandboxCanonicalCommandResult -Invocation $engineRecoverApply -EvidenceRoot $evidenceRoot
    Assert ($engineRecoverApply.Code -eq 0 -and (Test-CommandResult -Document $engineRecoverApplyDocument -Result PASS -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-applied) -and [string]$engineRecoverApplyDocument.PlanHash -ceq [string]$engineRecoverDryDocument.PlanHash) 'recover Apply under a held capability reaches the promoted recovery engine and publishes the committed PASS result'
    $engineRecoverStates = @(Get-CanonicalAllTransactionStates -TransactionsRoot ([string]$engineRecoverPaths.TransactionsRoot))
    Assert (@($engineRecoverStates | Where-Object { -not [bool]$_.IsTerminal }).Count -eq 0 -and @($engineRecoverStates | Where-Object { [string]$_.Outcome -ceq 'abandoned' }).Count -eq 1) 'the recovery engine closed the reviewed transaction terminal and abandoned under the held repo lock'
    $engineRecoverStatus = Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot', $engineRepo, '-Status')
    $engineRecoverStatusDocument = Get-ValidatedCanonicalCommandResult -Invocation $engineRecoverStatus -EvidenceRoot $evidenceRoot
    Assert ($engineRecoverStatus.Code -eq 0 -and (Test-CommandResult -Document $engineRecoverStatusDocument -Result PASS -CommandKind canonical-recover-status -MessageToken no-canonical-transaction)) 'after the engine run, recover status reports no unfinished transaction'

    Write-CommandResultTestPhase 'setup apply engine'
    $engineContext = Resolve-HomeAuthorityContextFromIdentity -Identity (Get-WindowsHomeAuthorityIdentity)
    $engineClaimPath = $null
    & {
        $engineSetupPlan = Join-Path $engineSandboxRoot 'setup-plan.json'
        $engineSetupDry = Invoke-ScriptStreams -Script $setupScript -Arguments @('-DryRun', '-RepoRoot', $engineRepo, '-PlanPath', $engineSetupPlan)
        $engineSetupDryDocument = Get-ValidatedCanonicalCommandResult -Invocation $engineSetupDry -EvidenceRoot $evidenceRoot
        Assert ($engineSetupDry.Code -eq 0 -and (Test-CommandResult -Document $engineSetupDryDocument -Result PASS -CommandKind canonical-setup -MessageToken canonical-plan-created)) 'engine fixture publishes a reviewed setup plan'
        $engineSelection = Get-CanonicalPrivateRootSelection -RepoRoot $engineRepo
        $null = Assert-CanonicalIdentityFixturePath -Fixture $identityFixture -Path ([string]$engineSelection.CanonicalRecoveryRoot)
        Assert (-not (Test-Path -LiteralPath ([string]$engineSelection.CanonicalRecoveryRoot))) 'pristine setup starts with no canonical recovery root'
        $engineSetupApply = Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $setupScript -Arguments @('-Apply', '-RepoRoot', $engineRepo, '-PlanPath', $engineSetupPlan)
        $engineSetupApplyDocument = Get-ValidatedSandboxCanonicalCommandResult -Invocation $engineSetupApply -EvidenceRoot $evidenceRoot
        Assert ($engineSetupApply.Code -eq 0) 'pristine isolated setup Apply must succeed; refusal is not an alternate passing outcome'
        if ($engineSetupApply.Code -eq 0) {
            Assert ((Test-CommandResult -Document $engineSetupApplyDocument -Result PASS -CommandKind canonical-setup -MessageToken canonical-apply-committed) -and [string]$engineSetupApplyDocument.PlanHash -ceq [string]$engineSetupDryDocument.PlanHash) 'first-time setup Apply under a held capability completes the SetupBootstrap sequence with a committed PASS result'
            $engineBootstrapStatus = Get-SealedHomeAuthorityBootstrapCompletionStatus -AuthorityContext $engineContext
            Assert (([string]$engineBootstrapStatus.Status -ceq 'COMPLETE') -and ([long]$engineBootstrapStatus.CompletePrefixLength -eq 7)) 'the sandboxed setup Apply bootstrapped the complete seven-directory private prefix'
            $engineGit = Get-CanonicalGitContext -RepoRoot $engineRepo
            $enginePaths = Get-CanonicalTransactionContractPaths -GitContext $engineGit
            $engineRepoId = Get-CanonicalRepoIdentity -GitContext $engineGit
            $engineClaimPath = Join-Path (Join-Path ([string]$engineContext.ControlBase) 'canonical-roots') ($engineRepoId + '.json')
            $enginePlanDocument = Read-CanonicalTransactionPlan -PlanPath $engineSetupPlan -RepoRoot $engineRepo -ExpectedOperationKind setup
            $engineClaimDocument = if (Test-Path -LiteralPath $engineClaimPath -PathType Leaf) { ConvertFrom-SemanticJson -Json ([IO.File]::ReadAllText($engineClaimPath, [Text.UTF8Encoding]::new($false, $true))) } else { $null }
            Assert (($null -ne $engineClaimDocument) -and ((Get-SemanticJsonHash -InputObject $engineClaimDocument) -ceq [string]$enginePlanDocument.PlanPayload.ExpectedRootClaimHash)) 'the deferred root claim is published exactly at the journal-bound control-base locator'
            $claimAclAccepted = $false
            $claimParentHandles = $null
            $claimCapture = $null
            try {
                $null = Assert-CanonicalIdentityFixturePath -Fixture $identityFixture -Path $engineClaimPath
                $claimParentReceiver = [AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
                Open-SafeDirectoryContainmentChain -Path ([IO.Path]::GetDirectoryName($engineClaimPath)) -OwnershipReceiver $claimParentReceiver
                $claimParentHandles = $claimParentReceiver.GetDeliveredExact()
                $claimCapture = Open-SealedRegistryJsonCapture -ParentHandle $claimParentHandles[$claimParentHandles.Count-1] -Name ([IO.Path]::GetFileName($engineClaimPath)) -TokenSid ([string]$identityFixture.Identity.TokenSid) -Label 'public setup claim'
                $claimAclAccepted = $true
            }
            catch { Write-Host ("claim security diagnostic: {0}" -f $_.Exception.Message) }
            finally {
                if ($null -ne $claimCapture) { $claimCapture.Handle.Dispose() }
                if ($null -ne $claimParentHandles) { Close-SafeDirectoryContainmentChain -Handles $claimParentHandles }
            }
            Assert $claimAclAccepted 'the public setup claim has a held current-user-only file ACL after publication'
            Assert ((Test-Path -LiteralPath ([string]$enginePaths.SetupStatePath) -PathType Leaf) -and ((Get-CanonicalSetupStatus -RepoRoot $engineRepo) -ceq 'canonical-ready')) 'the final setup state is published and the repository reports canonical-ready'
            $engineSetupStates = @(Get-CanonicalAllTransactionStates -TransactionsRoot ([string]$enginePaths.TransactionsRoot))
            Assert (@($engineSetupStates | Where-Object { -not [bool]$_.IsTerminal }).Count -eq 0 -and @($engineSetupStates | Where-Object { [string]$_.Outcome -ceq 'committed' }).Count -eq 1) 'the setup journal closes terminal and committed'
            Write-CommandResultTestPhase 'complete authority recovery and lock contention'
            $completeRecoverId=[Guid]::NewGuid().ToString('D').ToLowerInvariant()
            $completeRecoverNamespace=Join-Path $enginePaths.TransactionsRoot (Join-Path $engineGit.WorktreeId $completeRecoverId)
            $completeRecoverHeader=[ordered]@{
                SchemaVersion=1;ArtifactKind='canonical-journal-header';TransactionId=$completeRecoverId;CanonicalOperationKind='normalize'
                OriginalDocumentHash=('b'*64);OriginalPlanHash=('c'*64);RepoId=$engineRepoId
                GitCommonDirHash=[string]$engineGit.GitCommonDirHash;WorktreeId=[string]$engineGit.WorktreeId
                TransactionNamespace=[IO.Path]::GetFullPath($completeRecoverNamespace)
                RecoveryTransactionRoot=Join-Path $engineSelection.CanonicalRecoveryRoot (Join-Path $engineGit.WorktreeId $completeRecoverId)
                ExpectedPostconditionsHash=('d'*64);Targets=@()
            }
            $null=New-CanonicalJournalHeader -Document $completeRecoverHeader -TransactionNamespace $completeRecoverNamespace
            $completeRecoverPlan=Join-Path $engineSandboxRoot 'complete-authority-recover.json'
            $completeRecoverDry=Invoke-ScriptStreams -Script $recoveryScript -Arguments @('-RepoRoot',$engineRepo,'-Action','abandon','-TransactionId',$completeRecoverId,'-DryRun','-PlanPath',$completeRecoverPlan)
            Assert ($completeRecoverDry.Code -eq 0) 'complete authority produces a reviewed abandon plan for an unfinished reservation'
            $completeRecoverBefore=Get-TestDirectoryTreeHash -Root $completeRecoverNamespace
            $recoverHolder=Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $engineContext
            try {
                $completeRecoverBusy=Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $recoveryScript -Arguments @('-RepoRoot',$engineRepo,'-Action','abandon','-TransactionId',$completeRecoverId,'-Apply','-PlanPath',$completeRecoverPlan)
                Assert ($completeRecoverBusy.Code -eq 1 -and $completeRecoverBusy.Out -match 'operation-lock-busy' -and (Get-TestDirectoryTreeHash -Root $completeRecoverNamespace) -ceq $completeRecoverBefore) 'complete authority recovery refuses a global lock contender without changing its journal'
            }
            finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $recoverHolder }
            $completeRecoverApply=Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $recoveryScript -Arguments @('-RepoRoot',$engineRepo,'-Action','abandon','-TransactionId',$completeRecoverId,'-Apply','-PlanPath',$completeRecoverPlan)
            $completeRecoverResult=Get-ValidatedSandboxCanonicalCommandResult -Invocation $completeRecoverApply -EvidenceRoot $evidenceRoot
            Assert ($completeRecoverApply.Code -eq 0 -and (Test-CommandResult -Document $completeRecoverResult -Result PASS -CommandKind canonical-recover-abandon -MessageToken canonical-recovery-applied)) 'complete authority recovery succeeds with one typed PASS after the global holder releases'
            $completeRecoverState=Read-CanonicalJournalDirectory -TransactionNamespace $completeRecoverNamespace
            Assert ($completeRecoverState.IsTerminal -and [string]$completeRecoverState.Outcome -ceq 'abandoned') 'complete authority recovery closes the same isolated journal terminal and abandoned'
            $completeRecoverReplay=Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $recoveryScript -Arguments @('-RepoRoot',$engineRepo,'-Action','abandon','-TransactionId',$completeRecoverId,'-Apply','-PlanPath',$completeRecoverPlan)
            Assert ($completeRecoverReplay.Code -ne 0 -and $completeRecoverReplay.Out -match 'reviewed-plan-consumed') 'complete authority rejects replay of the consumed recovery plan'
            # With the complete bootstrap held by this section, the skill route
            # can also prove the promoted engine end to end.
            Write-CommandResultTestPhase 'normalize planning and registry recomputation'
            $engineCandidate = Join-Path $engineSandboxRoot 'normalize-candidate'
            $null = Copy-SafeTree -SourceRoot (Join-Path $engineRepo 'skills-source') -DestinationRoot (Join-Path $engineCandidate 'skills-source')
            New-TestSkill -Path (Join-Path $engineCandidate 'skills-source/shared/engine-new') -Name engine-new
            $engineNormalizePlan = Join-Path $engineSandboxRoot 'normalize-plan.json'
            $engineNormalizePreflight = Join-Path $engineSandboxRoot 'normalize-preflight'
            $engineNormalizeDry = Invoke-ScriptStreams -Script $transactionScript -Arguments @(
                '-RepoRoot', $engineRepo, '-OperationKind', 'normalize', '-DryRun', '-PlanPath', $engineNormalizePlan,
                '-CandidateWorkspace', $engineCandidate, '-InputPath', (Join-Path $engineCandidate 'skills-source/shared/engine-new'),
                '-CanonicalPreflightOutputRoot', $engineNormalizePreflight
            )
            $engineNormalizeDryDocument = Get-ValidatedCanonicalCommandResult -Invocation $engineNormalizeDry -EvidenceRoot $evidenceRoot
            Assert ($engineNormalizeDry.Code -eq 0 -and (Test-CommandResult -Document $engineNormalizeDryDocument -Result PASS -CommandKind canonical-normalize -MessageToken canonical-plan-created)) 'engine fixture publishes a reviewed normalize plan'
            $registryProbe = $null
            $registryAccepted = $false
            try {
                $registryProbe = Enter-SealedHeldCanonicalLiveLockOrder -RepoRoot $engineRepo -RouteKind normalize -AcquisitionMode ExistingOnly -AuthorityContext $engineContext -ToolchainRoot $RepoRoot
                $null = Get-SealedHeldLockOrderRecompute -LockOrderHandle $registryProbe -ExpectedOperationKind normalize
                $registryAccepted = $true
            }
            catch {
                Write-Host ("registry diagnostic: {0}; stack: {1}" -f $_.Exception.Message,$_.ScriptStackTrace)
                Write-Host ("claim ACL diagnostic: {0}" -f (Get-Acl -LiteralPath $engineClaimPath).Sddl)
            }
            finally { if ($null -ne $registryProbe) { Exit-SealedHeldCanonicalLiveLockOrder -LockOrderHandle $registryProbe } }
            Assert $registryAccepted 'the public setup claim is accepted by the next held registry recomputation'
            # Exercise contention before consuming the reviewed plan. Both
            # canonical and global holders belong to this same fixture identity.
            Write-CommandResultTestPhase 'normalize lock contention'
            $contenderState = {
                [string]::Join('|', @(
                    (Get-TestDirectoryTreeHash -Root ([string]$enginePaths.TransactionsRoot)),
                    (Get-TestControlBaseHash -ControlBase ([string]$engineContext.ControlBase)),
                    (Get-TestDirectoryTreeHash -Root (Join-Path $engineRepo 'skills-source')),
                    (Get-TestDirectoryTreeHash -Root (Join-Path $engineRepo 'codex/skills'))
                ))
            }
            $beforeContenders = & $contenderState
            $holderCanonical = Enter-CanonicalRepoLock -LockPath ([string]$enginePaths.LockPath)
            try {
                $busyNormalize = Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $transactionScript -Arguments @('-Apply','-RepoRoot',$engineRepo,'-OperationKind','normalize','-PlanPath',$engineNormalizePlan)
                $busyNormalizeResult = Get-ValidatedSandboxCanonicalCommandResult -Invocation $busyNormalize -EvidenceRoot $evidenceRoot
                Assert ($busyNormalize.Code -eq 1 -and $script:lastSandboxDiagnostic -ceq 'operation-lock-busy' -and (Test-CommandResult -Document $busyNormalizeResult -Result WARN -CommandKind canonical-normalize -MessageToken operation-lock-busy)) 'complete isolated authority refuses a canonical lock contender'
            }
            finally { Exit-CanonicalRepoLock -LockHandle $holderCanonical }
            $holderGlobal = Enter-HomeAuthorityGlobalLiveLock -AuthorityContext $engineContext
            try {
                $busyNormalize = Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $transactionScript -Arguments @('-Apply','-RepoRoot',$engineRepo,'-OperationKind','normalize','-PlanPath',$engineNormalizePlan)
                if ($busyNormalize.Code -ne 1 -or $busyNormalize.Out -notmatch 'operation-lock-busy') { Write-Host ("global contender diagnostic: code={0}; {1}" -f $busyNormalize.Code,$busyNormalize.Out) }
                $busyNormalizeResult = Get-ValidatedSandboxCanonicalCommandResult -Invocation $busyNormalize -EvidenceRoot $evidenceRoot
                Assert ($busyNormalize.Code -eq 1 -and $script:lastSandboxDiagnostic -ceq 'operation-lock-busy' -and (Test-CommandResult -Document $busyNormalizeResult -Result WARN -CommandKind canonical-normalize -MessageToken operation-lock-busy)) 'complete isolated authority refuses a global lock contender'
            }
            finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $holderGlobal }
            Assert ($beforeContenders -ceq (& $contenderState)) 'lock contenders leave the registry, journals, source, and generated skill trees unchanged'
            Write-CommandResultTestPhase 'normalize Apply and replay'
            $engineNormalizeApply = Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $transactionScript -Arguments @(
                '-Apply', '-RepoRoot', $engineRepo, '-OperationKind', 'normalize', '-PlanPath', $engineNormalizePlan
            )
            $engineNormalizeApplyDocument = Get-ValidatedSandboxCanonicalCommandResult -Invocation $engineNormalizeApply -EvidenceRoot $evidenceRoot
            if ($engineNormalizeApply.Code -ne 0) { Write-Host ("normalize Apply diagnostic: code={0}; {1}" -f $engineNormalizeApply.Code,$engineNormalizeApply.Out) }
            Assert ($engineNormalizeApply.Code -eq 0 -and (Test-CommandResult -Document $engineNormalizeApplyDocument -Result PASS -CommandKind canonical-normalize -MessageToken canonical-apply-committed) -and [string]$engineNormalizeApplyDocument.PlanHash -ceq [string]$engineNormalizeDryDocument.PlanHash) 'skill Apply under a held capability reaches the promoted engine and publishes the committed PASS result'
            Assert ((Test-Path -LiteralPath (Join-Path $engineRepo 'skills-source/shared/engine-new/SKILL.md')) -and (Test-Path -LiteralPath (Join-Path $engineRepo 'codex/skills/engine-new/SKILL.md'))) 'the promoted engine installed the reviewed canonical and generated bytes together'
            $engineNormalizeStates = @(Get-CanonicalAllTransactionStates -TransactionsRoot ([string]$enginePaths.TransactionsRoot))
            Assert (@($engineNormalizeStates | Where-Object { -not [bool]$_.IsTerminal }).Count -eq 0 -and @($engineNormalizeStates | Where-Object { [string]$_.Outcome -ceq 'committed' -and [string]$_.Header.CanonicalOperationKind -ceq 'normalize' }).Count -eq 1) 'the skill journal closes exactly one terminal committed normalize transaction under the held lock order'
            $normalizeReplay = Invoke-CanonicalIdentityFixtureSandboxScript -Fixture $identityFixture -ScriptPath $transactionScript -Arguments @('-Apply','-RepoRoot',$engineRepo,'-OperationKind','normalize','-PlanPath',$engineNormalizePlan)
            Assert ($normalizeReplay.Code -ne 0 -and $normalizeReplay.Out -match 'reviewed-plan-consumed|canonical-plan-stale') 'a committed reviewed plan cannot be replayed after lock release'
        }
    }
}
catch {
    $script:fail++
    Write-Host "  FAIL  unexpected exception: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host "`ncanonical command result tests: $script:pass passed, $script:fail failed" -ForegroundColor Cyan
}

if ($script:fail -gt 0) { exit 1 }
exit 0
}
finally {
    $cleanupStarted = $script:CommandResultClock.Elapsed.TotalSeconds
    try { Remove-CanonicalIdentityFixture -Fixture $identityFixture }
    finally {
        # Module loading can fail before the phase-reporting function exists.
        # Timing must not prevent cleanup or replace its primary exception.
        try {
            $elapsed = $script:CommandResultClock.Elapsed.TotalSeconds
            Write-Host ('  timing: {0}={1:N1}s; elapsed={2:N1}s' -f $script:CommandResultPhase,($cleanupStarted-$script:CommandResultPhaseStart),$cleanupStarted)
            Write-Host ('  timing: fixture cleanup={0:N1}s; total={1:N1}s' -f ($elapsed-$cleanupStarted),$elapsed)
        }
        catch { }
    }
}
