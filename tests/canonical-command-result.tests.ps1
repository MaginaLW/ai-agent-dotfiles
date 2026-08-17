#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')

$script:pass = 0
$script:fail = 0
$script:lastValidationError = ''

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
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-File', $Script) + @($Arguments)) {
        [void] $start.ArgumentList.Add([string] $argument)
    }
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw "Unable to start public script: $Script" }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        return [pscustomobject]@{
            Code = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

function Get-ValidatedCanonicalCommandResult {
    param([Parameter(Mandatory)] $Invocation, [Parameter(Mandatory)] [string] $EvidenceRoot)
    $script:lastValidationError = ''
    try {
        $match = [regex]::Match([string] $Invocation.Stdout, '\A(\{[^\r\n]*\})(?:\r?\n)?\z')
        if (-not $match.Success) { throw 'stdout is not exactly one compact JSON line' }
        $json = $match.Groups[1].Value
        $instancePath = Join-Path $EvidenceRoot ("result-{0}.json" -f [Guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($instancePath, $json, [Text.UTF8Encoding]::new($false))
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/canonical-transaction-result.schema.json') -InstancePath $instancePath
        $document = ConvertFrom-SemanticJson -Json $json
        $semantic = [Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $document))
        if ($json -cne $semantic) { throw 'stdout is not the exact semantic JSON encoding' }
        return $document
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

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ai-agent-dotfiles-command-result-' + [Guid]::NewGuid().ToString('N'))
$evidenceRoot = Join-Path $testRoot 'evidence'
[IO.Directory]::CreateDirectory($evidenceRoot) | Out-Null

try {
    $setupScript = Join-Path $RepoRoot 'scripts/setup-canonical-transaction.ps1'
    $transactionScript = Join-Path $RepoRoot 'scripts/canonical-transaction.ps1'
    $recoveryScript = Join-Path $RepoRoot 'scripts/recover-canonical-transaction.ps1'
    $normalizeScript = Join-Path $RepoRoot 'scripts/normalize-skill.ps1'
    $promoteScript = Join-Path $RepoRoot 'scripts/promote-skill.ps1'
    $mergeScript = Join-Path $RepoRoot 'scripts/auto-merge-skills.ps1'
    $agentScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
    $emitterScript = Join-Path $RepoRoot 'scripts/canonical-command-result.ps1'

    Write-Host "`n[shared public emitter]" -ForegroundColor Cyan
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

    Write-Host "`n[setup status, DryRun, Apply interlock, and dispatcher]" -ForegroundColor Cyan
    $setupRepo = Join-Path $testRoot 'setup-repo'
    Initialize-TestRepo -Path $setupRepo

    $directStatus = Invoke-ScriptStreams -Script $setupScript -Arguments @('-Status', '-RepoRoot', $setupRepo)
    $directStatusDocument = Get-ValidatedCanonicalCommandResult -Invocation $directStatus -EvidenceRoot $evidenceRoot
    Assert ($directStatus.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $directStatus.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $directStatusDocument -Result WARN -CommandKind canonical-status -MessageToken canonical-setup-required)) 'direct setup status emits one schema-valid semantic command result and empty stderr'

    $routedStatus = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'status', '-RepoRoot', $setupRepo)
    $routedStatusDocument = Get-ValidatedCanonicalCommandResult -Invocation $routedStatus -EvidenceRoot $evidenceRoot
    Assert ($routedStatus.Code -eq 0 -and (Test-ExactDiagnosticToken -Stderr $routedStatus.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $routedStatusDocument -Result WARN -CommandKind canonical-status -MessageToken canonical-setup-required) -and $routedStatus.Stdout -notmatch 'Invoking script|Command result') 'agent-dotfiles canonical status forwards only the child JSON with no dispatcher banner'

    $setupMissingPlan = Invoke-ScriptStreams -Script $setupScript -Arguments @('-DryRun', '-RepoRoot', $setupRepo)
    Assert-CanonicalCommandFailure -Invocation $setupMissingPlan -EvidenceRoot $evidenceRoot -CommandKind canonical-setup -MessageToken canonical-plan-required -Message 'setup missing PlanPath emits one typed failure result and exact token'

    $setupMissingParentPlan = Join-Path $testRoot 'missing-setup-parent/setup.json'
    $setupMissingParent = Invoke-ScriptStreams -Script $setupScript -Arguments @('-DryRun', '-RepoRoot', $setupRepo, '-PlanPath', $setupMissingParentPlan)
    Assert-CanonicalCommandFailure -Invocation $setupMissingParent -EvidenceRoot $evidenceRoot -CommandKind canonical-setup -MessageToken canonical-plan-parent-missing -Message 'setup missing PlanPath parent emits one typed failure result and exact token'

    $setupMissingApplyPlan = Join-Path $evidenceRoot 'missing-setup-apply.json'
    $setupMissingApply = Invoke-ScriptStreams -Script $setupScript -Arguments @('-Apply', '-RepoRoot', $setupRepo, '-PlanPath', $setupMissingApplyPlan)
    Assert-CanonicalCommandFailure -Invocation $setupMissingApply -EvidenceRoot $evidenceRoot -CommandKind canonical-setup -MessageToken canonical-plan-not-found -Message 'setup Apply missing reviewed plan emits one typed failure result and exact token'

    $setupPlan = Join-Path $evidenceRoot 'setup-plan.json'
    $setupDryRun = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-DryRun', '-PlanPath', $setupPlan)
    $setupDryRunDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupDryRun -EvidenceRoot $evidenceRoot
    Assert ($setupDryRun.Code -eq 0 -and (Test-Path -LiteralPath $setupPlan -PathType Leaf) -and (Test-ExactDiagnosticToken -Stderr $setupDryRun.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $setupDryRunDocument -Result PASS -CommandKind canonical-setup -MessageToken canonical-plan-created) -and -not [string]::IsNullOrWhiteSpace([string] $setupDryRunDocument.PlanHash)) 'routed setup DryRun emits one validated plan result and empty stderr'

    $setupCollision = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-DryRun', '-PlanPath', $setupPlan)
    $setupCollisionDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupCollision -EvidenceRoot $evidenceRoot
    Assert ($setupCollision.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $setupCollision.Stderr -ExpectedToken canonical-plan-exists) -and (Test-CommandResult -Document $setupCollisionDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-plan-exists)) 'routed setup PlanPath collision emits one typed failure result, exact token, and preserves exit 1'

    $setupApply = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-Apply', '-PlanPath', $setupPlan)
    $setupApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupApply -EvidenceRoot $evidenceRoot
    Assert ($setupApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $setupApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $setupApplyDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-apply-interlocked) -and [string] $setupApplyDocument.PlanHash -ceq [string] $setupDryRunDocument.PlanHash) 'routed setup Apply revalidates the reviewed plan, emits one result plus exact stderr token, and remains interlocked'

    Set-TestFile -Path (Join-Path $setupRepo 'README.md') -Content "fixture advanced after review`n"
    & git -C $setupRepo add -- README.md
    & git -C $setupRepo commit --quiet -m advance-after-review
    if ($LASTEXITCODE -ne 0) { throw 'Unable to advance the disposable setup repository.' }
    $setupStale = Invoke-ScriptStreams -Script $agentScript -Arguments @('canonical', 'setup', '-RepoRoot', $setupRepo, '-Apply', '-PlanPath', $setupPlan)
    $setupStaleDocument = Get-ValidatedCanonicalCommandResult -Invocation $setupStale -EvidenceRoot $evidenceRoot
    Assert ($setupStale.Code -eq 1 -and (Test-ExactDiagnosticToken -Stderr $setupStale.Stderr -ExpectedToken canonical-plan-stale) -and (Test-CommandResult -Document $setupStaleDocument -Result FAIL -CommandKind canonical-setup -MessageToken canonical-plan-stale) -and [string] $setupStaleDocument.PlanHash -ceq [string] $setupDryRunDocument.PlanHash) 'routed setup stale Apply emits one typed failure result, exact token, and preserves exit 1'

    Write-Host "`n[canonical transaction negative outcomes]" -ForegroundColor Cyan
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

    Write-Host "`n[normalize/promote early public outcomes]" -ForegroundColor Cyan
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

    Write-Host "`n[canonical merge outcomes and aliases]" -ForegroundColor Cyan
    $normalMergeRepo = Join-Path $testRoot 'normal-merge-repo'
    Initialize-TestRepo -Path $normalMergeRepo -SkillLayout
    New-TestSkill -Path (Join-Path $normalMergeRepo 'imports/skills-inbox/machine/claude/merge-promote') -Name merge-promote
    $normalMergePlan = Join-Path $evidenceRoot 'normal-merge.json'
    $normalMerge = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $normalMergeRepo, '-DryRun', '-PlanPath', $normalMergePlan)
    $normalMergeDocument = Get-ValidatedCanonicalCommandResult -Invocation $normalMerge -EvidenceRoot $evidenceRoot
    Assert ($normalMerge.Code -eq 0 -and (Test-Path -LiteralPath $normalMergePlan -PathType Leaf) -and (Test-ExactDiagnosticToken -Stderr $normalMerge.Stderr -ExpectedToken '') -and (Test-CommandResult -Document $normalMergeDocument -Result PASS -CommandKind canonical-merge -MessageToken canonical-plan-created)) 'merge normal path emits one child result and empty stderr'

    $normalMergeApply = Invoke-ScriptStreams -Script $mergeScript -Arguments @('-RepoRoot', $normalMergeRepo, '-Apply', '-PlanPath', $normalMergePlan)
    $normalMergeApplyDocument = Get-ValidatedCanonicalCommandResult -Invocation $normalMergeApply -EvidenceRoot $evidenceRoot
    Assert ($normalMergeApply.Code -eq 75 -and (Test-ExactDiagnosticToken -Stderr $normalMergeApply.Stderr -ExpectedToken canonical-apply-interlocked) -and (Test-CommandResult -Document $normalMergeApplyDocument -Result FAIL -CommandKind canonical-merge -MessageToken canonical-apply-interlocked)) 'merge Apply emits one interlocked result and exact diagnostic token'

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
}
catch {
    $script:fail++
    Write-Host "  FAIL  unexpected exception: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host "`ncanonical command result tests: $script:pass passed, $script:fail failed" -ForegroundColor Cyan
    if ($script:fail -eq 0 -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
}

if ($script:fail -gt 0) { exit 1 }
exit 0
