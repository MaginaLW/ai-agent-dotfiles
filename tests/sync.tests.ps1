#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$syncScript = Join-Path $RepoRoot 'scripts/sync.ps1'
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-sync-tests-$([Guid]::NewGuid().ToString('N'))"
$v3Repo = Join-Path $work 'v3-repo'
$fakeHome = Join-Path $work 'home'
# The sandbox host derives the backup/control locators from the injected home
# exactly like the production home-authority layout.
$fakeBackups = Join-Path $fakeHome 'AppData\Local\ai-agent-dotfiles\backups'
$controlBase = Join-Path $fakeHome 'AppData\Local\ai-agent-dotfiles\control'
$plansRoot = Join-Path $work 'plans'
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/target-context-common.ps1')
. (Join-Path $RepoRoot 'scripts/canonical-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')

function Set-TestDirectoryCurrentUserOnly {
    param([Parameter(Mandatory)] [string] $Path)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($sid)
    $security.SetAccessRuleProtection($true, $false)
    $inheritance = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    $rule = [Security.AccessControl.FileSystemAccessRule]::new($sid, [Security.AccessControl.FileSystemRights]::FullControl, $inheritance, [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
    $security.AddAccessRule($rule)
    [System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new([System.IO.Path]::GetFullPath($Path)), $security)
}

function Write-TestSemanticDocument {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $parent = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($parent)) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    [System.IO.File]::WriteAllText($Path, [System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $Document)), [System.Text.UTF8Encoding]::new($false))
}

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Write-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function Write-RetirementManifest {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [string[]] $Claude = @(),
        [string[]] $Codex = @(),
        [string[]] $Reasonix = @()
    )
    $document = [ordered]@{
        SchemaVersion = 1
        Claude = @($Claude)
        Codex = @($Codex)
        Reasonix = @($Reasonix)
    }
    Write-TextFile -Path $Path -Content ((ConvertTo-Json -InputObject $document -Depth 5) + "`n")
}

function Invoke-Sync {
    param([string[]] $Arguments)
    return Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $syncScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
}

function Read-LivePlanDocument {
    param([Parameter(Mandatory)] [string] $Path)
    return ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)))
}

function Get-DefinitionSkillCounts {
    param([Parameter(Mandatory)] [string] $Repo)
    $definition = Import-PowerShellDataFile -LiteralPath (Join-Path $Repo 'harness-source/envs/full.psd1')
    return [ordered]@{
        Claude = @($definition.Skills.Claude).Count
        Codex = @($definition.Skills.Codex).Count
        Reasonix = @($definition.Skills.Reasonix).Count
    }
}

function Write-FixtureSkillPlaceholder {
    param([Parameter(Mandatory)] [string] $Repo, [Parameter(Mandatory)] [string] $Platform, [Parameter(Mandatory)] [string] $Name)
    Write-TextFile -Path (Join-Path $Repo "$Platform/skills/$Name/SKILL.md") -Content "---`nname: $Name`ndescription: Fixture placeholder for the sync plan producer fixture.`n---`n`n# $Name`n"
}

function New-SeededAuthorityState {
    # Seeds the control base with a complete schema 3 authority state derived
    # from the reviewed pristine-initial plan (the reviewed intent plus test
    # runtime refs). Task 2 never invokes an authority writer.
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $InitialPlan,
        [Parameter(Mandatory)] [string] $ControlBase,
        [string[]] $ClaudePostsetSkills = @(),
        [string[]] $CodexPostsetSkills = @(),
        [string[]] $ReasonixPostsetSkills = @()
    )

    $intent = Complete-LivePlanAuthorityStateIntent -Document $InitialPlan
    $rows = @($InitialPlan.PlanPayload.TargetContextIntent.Rows)
    $identities = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt 3; $index++) {
        $row = $rows[$index]
        $identities.Add([ordered]@{
            DirectoryIdentity = ([string] $row.VolumeId) + ':' + ('{0:x16}' -f (4000 + $index))
            FilesystemCapabilityHash = ('9' * 64)
            LocationKey = [string] $row.LocationKey
            Platform = [string] $row.Platform
            ResolvedPath = [string] $row.RequestedPath
            VolumeId = [string] $row.VolumeId
        })
    }
    $postsetSkills = [ordered]@{
        Claude = $ClaudePostsetSkills
        Codex = $CodexPostsetSkills
        Reasonix = $ReasonixPostsetSkills
    }
    $postimage = New-AuthorityStatePostimage -AuthorityStateIntent $intent -TargetContextIntent $InitialPlan.PlanPayload.TargetContextIntent -FinalResolvedIdentities @($identities) -RuntimeRefs ([ordered]@{
        JournalId = [Guid]::NewGuid().ToString()
        PreStatePhaseHash = ('1' * 64)
        ReceiptId = [Guid]::NewGuid().ToString()
        ReceiptHash = ('2' * 64)
    })
    # The seeded postset is the test-controlled active selection: rewrite the
    # postimage's TaskOverlaySkills rows after the serializer validated shape.
    $rewritten = [ordered]@{}
    foreach ($key in @($postimage.Keys)) { $rewritten[$key] = $postimage[$key] }
    $rewritten['TaskOverlaySkills'] = @(
        foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
            $skills = [string[]] @($postsetSkills[$platform])
            [Array]::Sort($skills, [System.StringComparer]::Ordinal)
            [ordered]@{ Platform = $platform; Skills = @([string[]] $skills) }
        }
    )
    $statePath = Join-Path (Join-Path $ControlBase 'homes') (Join-Path ([string] $intent.HomeAuthorityKey) 'current-env.json')
    Write-TextFile -Path $statePath -Content (([System.Text.UTF8Encoding]::new($false).GetString((ConvertTo-SemanticJsonBytes -InputObject $rewritten))) + "`n")
    return $statePath
}

try {
    New-Item -ItemType Directory -Force -Path $work, $fakeHome, $plansRoot | Out-Null

    # --- schema 3 producer fixture: in-sandbox git repository ---------------
    New-Item -ItemType Directory -Force -Path (Join-Path $v3Repo 'harness-source/envs') | Out-Null
    & git -C $v3Repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the external sync-plan fixture repository.' }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $v3Repo 'harness-source/profiles') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $v3Repo 'harness-source/components') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/envs/full.psd1') -Destination (Join-Path $v3Repo 'harness-source/envs/full.psd1') -Force
    New-Item -ItemType Directory -Force -Path (Join-Path $v3Repo 'manifests') | Out-Null
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "manifests/managed-skills.$platform.txt") -Destination (Join-Path $v3Repo "manifests/managed-skills.$platform.txt") -Force
    }
    New-Item -ItemType Directory -Force -Path (Join-Path $v3Repo 'tools/schema-validator'), (Join-Path $v3Repo 'tools/gitleaks') | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json') -Destination (Join-Path $v3Repo 'tools/schema-validator/validator.lock.json') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $v3Repo 'tools/gitleaks/gitleaks.lock.json') -Force
    # The sync repo carries the contract schemas; the host validates the
    # canonical setup state against the toolchain-root copy.
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'schemas') -Destination (Join-Path $v3Repo 'schemas') -Recurse -Force
    $definitionCounts = Get-DefinitionSkillCounts -Repo $v3Repo
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        $titlePlatform = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($platform)
        foreach ($name in (Import-PowerShellDataFile -LiteralPath (Join-Path $v3Repo 'harness-source/envs/full.psd1')).Skills[$titlePlatform]) {
            Write-FixtureSkillPlaceholder -Repo $v3Repo -Platform $platform -Name ([string] $name)
        }
    }
    & git -C $v3Repo add -A
    & git -C $v3Repo -c user.name='sync fixture' -c user.email='sync-fixture@ai-agent-dotfiles.invalid' commit --quiet -m 'schema 3 producer fixture'
    if ($LASTEXITCODE -ne 0) { throw 'Unable to commit the external sync-plan fixture repository.' }

    Write-Host '[mode gates]'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun')
    Assert ($result.Code -ne 0 -and $result.Out -match 'requires a create-new -PlanPath') 'dry-run requires a create-new plan path'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply')
    Assert ($result.Code -ne 0 -and $result.Out -match 'requires a reviewed.*PlanPath') 'apply requires a reviewed dry-run plan'

    $noCapabilityPlan = Join-Path $plansRoot 'no-capability-plan.json'
    $result = Invoke-TestProcess -ScriptPath $syncScript -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $noCapabilityPlan)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-host-resolution-required') 'dry-run without the internal capability fails closed'
    Assert (-not (Test-Path -LiteralPath $noCapabilityPlan)) 'failed host resolution creates zero plan bytes'

    Write-Host '[pristine initial producer]'
    $initialPlanPath = Join-Path $plansRoot 'initial-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $initialPlanPath)
    Assert ($result.Code -eq 0) 'pristine initial dry-run exits successfully'
    Assert ($result.Out -match 'Operation kind  : initial') 'pristine initial producer reports the initial kind'
    $initialPlan = Read-LivePlanDocument -Path $initialPlanPath
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/sync-plan.schema.json') -InstancePath $initialPlanPath
    Assert $true 'pristine initial plan passes the pinned schema 3'
    Test-LiveSyncPlanSemantics -Document $initialPlan
    Assert $true 'pristine initial plan passes full plan semantics'
    Assert ([string] $initialPlan.PlanPayload.OperationKind -ceq 'initial') 'plan OperationKind is initial'
    Assert ([string] $initialPlan.PlanPayload.Generator -ceq 'scripts/sync.ps1') 'plan Generator is scripts/sync.ps1'
    Assert ([string] $initialPlan.PlanPayload.EnvironmentName -ceq 'full') 'pristine initial selects the named full environment'
    foreach ($platform in @('Claude', 'Codex', 'Reasonix')) {
        $addCount = @($initialPlan.PlanPayload.OrderedActions | Where-Object { [string] $_.Platform -ceq $platform -and [string] $_.Action -ceq 'add' }).Count
        Assert ($addCount -eq [int] $definitionCounts[$platform]) "$platform add count equals the copied definition count"
    }
    $materializationPath = Join-Path $plansRoot 'initial-plan.materialization'
    Assert (Test-Path -LiteralPath (Join-Path $materializationPath 'env-build.json') -PathType Leaf) 'dry-run materializes the environment beside the plan'
    Assert (Test-Path -LiteralPath (Join-Path $materializationPath 'claude/skills') -PathType Container) 'materialized Claude root exists'
    $lockBytesHash = (Get-FileHash -LiteralPath (Join-Path $materializationPath 'env.lock.json') -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert ([string] $initialPlan.PlanPayload.AuthorityStateIntent.EnvironmentLockHash -ceq $lockBytesHash) 'plan binds the exact materialized lock bytes'
    Assert ([string] $initialPlan.PlanHash -ceq (Get-PlanHash -PlanPayload $initialPlan.PlanPayload)) 'written PlanHash matches Get-PlanHash'
    Assert ([string] $initialPlan.DocumentHash -ceq (Get-DocumentHash -Document $initialPlan)) 'written DocumentHash matches Get-DocumentHash'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $initialPlanPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-path-collision') 'second dry-run on the same plan path fails with the collision token'
    Assert (Test-Path -LiteralPath (Join-Path $materializationPath 'env.lock.json')) 'collision rejection preserves the bound materialization'

    $initialApplyPlan = Join-Path $plansRoot 'initial-apply-plan.json'
    $null = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $initialApplyPlan)

    Write-Host '[canonical setup for apply]'
    # The live transaction host requires the env-activation groundwork: the
    # home-authority prefix bootstrapped with the production template, then the
    # repo's canonical setup state and lock binding the sandbox locators.
    . (Join-Path $RepoRoot 'scripts/root-claims-registry-common.ps1')
    $authorityIdentity = [pscustomobject][ordered]@{
        ResolverVersion = 'windows-token-sid-known-folder-v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $fakeHome
        RoamingAppDataRoot = (Join-Path $fakeHome 'AppData\Roaming')
        LocalAppDataRoot = (Join-Path $fakeHome 'AppData\Local')
    }
    $authorityContext = Resolve-HomeAuthorityContextFromIdentity -Identity $authorityIdentity
    $authorityBootstrapIntent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $authorityContext -FilesystemCapabilityHash ('a' * 64)
    $authorityBootstrapLock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $authorityContext -Intent $authorityBootstrapIntent
    try { Assert ($null -ne $authorityBootstrapLock) 'sandbox authority bootstrap returns the held global lock' }
    finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $authorityBootstrapLock }
    $canonicalProbe = Join-Path $work 'canonical-probe'
    $canonicalRecoveryParent = Join-Path $work 'canonical-recovery-parent'
    foreach ($dir in @($canonicalProbe, $canonicalRecoveryParent)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    Set-TestDirectoryCurrentUserOnly -Path $canonicalRecoveryParent
    $canonicalRecovery = Join-Path $canonicalRecoveryParent 'recovery'
    New-Item -ItemType Directory -Force -Path $canonicalRecovery | Out-Null
    Set-TestDirectoryCurrentUserOnly -Path $canonicalRecovery
    $canonicalPayload = New-CanonicalSetupPlanPayload -RepoRoot $v3Repo -CanonicalRecoveryRoot $canonicalRecovery -ControlBase $controlBase -BackupRoot $fakeBackups -ProbeRoot $canonicalProbe -ToolchainRoot $RepoRoot
    $canonicalGit = Get-CanonicalGitContext -RepoRoot $v3Repo
    $canonicalPaths = Get-CanonicalTransactionContractPaths -GitContext $canonicalGit
    $canonicalState = New-CanonicalFinalSetupState -PlanPayload $canonicalPayload -RepoRoot $v3Repo
    $canonicalLock = Enter-CanonicalRepoLock -LockPath ([string] $canonicalPaths.LockPath) -AllowCreate
    try { Write-TestSemanticDocument -Path ([string] $canonicalPaths.SetupStatePath) -Document $canonicalState }
    finally { Exit-CanonicalRepoLock -LockHandle $canonicalLock }

    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $initialApplyPlan)
    if ($result.Code -ne 0) { Write-Host "----- initial apply child output -----"; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'pristine initial apply completes through the receipt-backed host'
    $initialApplyHomeKey = [string] $initialPlan.PlanPayload.AuthorityStateIntent.HomeAuthorityKey
    $initialApplyAuthorityArea = Join-Path (Join-Path $controlBase 'homes') $initialApplyHomeKey
    Assert (Test-Path -LiteralPath (Join-Path $initialApplyAuthorityArea 'root-claims.json') -PathType Leaf) 'initial apply publishes the reviewed root claims'
    Assert (Test-Path -LiteralPath (Join-Path $initialApplyAuthorityArea 'current-env.json') -PathType Leaf) 'initial apply publishes the schema 3 state postimage'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $controlBase 'live-transactions') -Force -ErrorAction SilentlyContinue).Count -ge 1) 'initial apply publishes a transaction journal namespace'
    $firstManagedSkill = $null
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        $liveRootForPlatform = switch ($platform) {
            'claude' { Join-Path $fakeHome '.claude\skills' }
            'codex' { Join-Path $fakeHome '.codex\skills' }
            default { Join-Path $fakeHome 'AppData\Roaming\reasonix\skills' }
        }
        $managedNamesForPlatform = @(Get-Content -LiteralPath (Join-Path $v3Repo "manifests\managed-skills.$platform.txt") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($managedNamesForPlatform.Count -gt 0) {
            $candidate = Join-Path $liveRootForPlatform ([string] $managedNamesForPlatform[0])
            if (-not (Test-Path -LiteralPath (Join-Path $candidate 'SKILL.md'))) { $firstManagedSkill = $false }
        }
    }
    Assert ($null -eq $firstManagedSkill) 'initial apply installs the planned managed skills into the live roots'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $initialApplyPlan)
    if ($result.Code -ne 0) { Write-Host "----- re-apply child output -----"; Write-Host $result.Out }
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-transaction-authority-present') 're-applying a completed initial plan fails closed on the installed authority'

    $tamperedPlanPath = Join-Path $plansRoot 'initial-apply-plan.json'
    $tampered = Read-LivePlanDocument -Path $tamperedPlanPath
    $tampered.Metadata.GeneratedAtUtc = '2000-01-01T00:00:00.0000000Z'
    Write-TextFile -Path $tamperedPlanPath -Content ((ConvertTo-Json -InputObject $tampered -Depth 40) + "`n")
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $tamperedPlanPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'apply rejects a tampered reviewed plan'

    Write-Host '[authority present gate]'
    # The real initial apply initialized the machine: the live roots are
    # populated, so a pristine initial dry-run now refuses before planning.
    $authorityPlanPath = Join-Path $plansRoot 'authority-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $authorityPlanPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-selection-mismatch') 'initial dry-run refuses initialized live roots'
    Assert (-not (Test-Path -LiteralPath $authorityPlanPath)) 'initialized-machine rejection creates zero plan bytes'

    Write-Host '[retirement producer]'
    $retiredTargets = [ordered]@{
        Claude = Join-Path $fakeHome '.claude/skills/retired-claude'
        Codex = Join-Path $fakeHome '.codex/skills/retired-codex'
        Reasonix = Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/retired-reasonix'
    }
    foreach ($target in $retiredTargets.Values) {
        Write-TextFile -Path (Join-Path $target 'SKILL.md') -Content "retired-sentinel`n"
    }
    Write-TextFile -Path (Join-Path $fakeHome '.claude/skills/unknown-local/SKILL.md') -Content 'unknown-sentinel'
    Write-TextFile -Path (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker') -Content 'system-sentinel'

    $retirementManifest = Join-Path $plansRoot 'retire-skills.json'
    $retirementPlanPath = Join-Path $plansRoot 'retirement-plan.json'
    Write-RetirementManifest -Path $retirementManifest -Claude @('retired-claude') -Codex @('retired-codex') -Reasonix @('retired-reasonix')

    $statePath = New-SeededAuthorityState -InitialPlan $initialPlan -ControlBase $controlBase

    Write-RetirementManifest -Path $retirementManifest -Codex @('.system')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'must never contain Codex \.system') 'retirement manifest rejects .system'

    Write-RetirementManifest -Path $retirementManifest -Claude @('../escape')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'safe bare identifier') 'retirement manifest rejects path-like names'

    Write-RetirementManifest -Path $retirementManifest -Codex @('brainstorming')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match "cannot authorize active Codex source skill 'brainstorming'") 'retirement manifest rejects an active source skill'

    $reasonixCanonicalOnly = Join-Path $v3Repo 'skills-source/reasonix-only/canonical-reasonix-only'
    $reasonixCanonicalOnlyLive = Join-Path $fakeHome 'AppData/Roaming/reasonix/skills/canonical-reasonix-only'
    Write-TextFile -Path (Join-Path $reasonixCanonicalOnly 'SKILL.md') -Content "canonical-reasonix-only`n"
    Write-TextFile -Path (Join-Path $reasonixCanonicalOnlyLive 'SKILL.md') -Content "canonical-reasonix-only`n"
    Write-RetirementManifest -Path $retirementManifest -Reasonix @('canonical-reasonix-only')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match "cannot authorize canonical Reasonix skill 'canonical-reasonix-only'") 'retirement manifest rejects a Reasonix-only canonical skill even with stale generated output'
    Remove-Item -LiteralPath $reasonixCanonicalOnly, $reasonixCanonicalOnlyLive -Recurse -Force

    $authorityCanonicalLive = Join-Path $fakeHome '.claude/skills/brainstorming'
    # The full fixture source legitimately contains every managed name; drop the
    # placeholder so the script-repository canonical authority check is the one
    # that fails closed (the fixture repo itself has no canonical tree).
    Remove-Item -LiteralPath (Join-Path $v3Repo 'claude/skills/brainstorming') -Recurse -Force
    Write-TextFile -Path (Join-Path $authorityCanonicalLive 'SKILL.md') -Content "staging-omitted-canonical`n"
    Write-RetirementManifest -Path $retirementManifest -Claude @('brainstorming')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match "cannot authorize canonical Claude skill 'brainstorming'") 'retirement checks the script repository canonical authority even when RepoRoot is staging or a fixture'
    Remove-Item -LiteralPath $authorityCanonicalLive -Recurse -Force

    $authorityInternalRetirementManifest = Join-Path $v3Repo ".git/ai-agent-dotfiles/sync-test-retirement-$([Guid]::NewGuid().ToString('N')).json"
    try {
        Write-RetirementManifest -Path $authorityInternalRetirementManifest -Claude @('retired-claude')
        $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $authorityInternalRetirementManifest)
        Assert ($result.Code -ne 0 -and $result.Out -match 'must be external to the repository') 'retirement manifest must remain outside the script repository canonical authority when RepoRoot is staging'
    }
    finally {
        Remove-Item -LiteralPath $authorityInternalRetirementManifest -Force -ErrorAction SilentlyContinue
    }

    Write-RetirementManifest -Path $retirementManifest -Claude @('retired-claude') -Codex @('retired-codex') -Reasonix @('retired-reasonix')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'retirement-authorized dry-run exits successfully'
    $retirementPlan = Read-LivePlanDocument -Path $retirementPlanPath
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/sync-plan.schema.json') -InstancePath $retirementPlanPath
    Assert $true 'retirement plan passes the pinned schema 3'
    Test-LiveSyncPlanSemantics -Document $retirementPlan
    Assert $true 'retirement plan passes full plan semantics'
    Assert ([string] $retirementPlan.PlanPayload.OperationKind -ceq 'retirement') 'plan OperationKind is retirement'
    Assert ([string] $retirementPlan.PlanPayload.Generator -ceq 'scripts/sync.ps1') 'plan Generator is scripts/sync.ps1'
    Assert (-not $retirementPlan.PlanPayload.Contains('TaskOverlayEvidence')) 'retirement plan carries zero hook evidence'
    Assert (-not $retirementPlan.PlanPayload.Contains('EnvironmentMaterializationRoot')) 'retirement plan binds no fresh materialization'
    $pruneActions = @($retirementPlan.PlanPayload.OrderedActions | Where-Object { [string] $_.Action -ceq 'prune' })
    Assert ($pruneActions.Count -eq 3) 'retirement plans exactly three prune actions'
    foreach ($action in $pruneActions) {
        Assert ([string] $action.Authority -ceq 'explicit-retirement') "prune $($action.Platform)/$($action.Name) carries explicit-retirement authority"
    }
    $expectedManifestHash = (Get-FileHash -LiteralPath $retirementManifest -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert ([string] $retirementPlan.PlanPayload.RetirementManifest.Hash -ceq $expectedManifestHash) 'plan binds the exact retirement manifest bytes'
    Assert ([string] $retirementPlan.PlanPayload.RetirementManifest.Path -ceq (Resolve-Path -LiteralPath $retirementManifest).Path) 'plan binds the resolved retirement manifest path'
    $safeNameRows = @($retirementPlan.PlanPayload.RetirementManifest.SafeNames)
    Assert ((@($safeNameRows[0].Names) -join ',') -ceq 'retired-claude' -and (@($safeNameRows[1].Names) -join ',') -ceq 'retired-codex' -and (@($safeNameRows[2].Names) -join ',') -ceq 'retired-reasonix') 'safe names are recorded per platform'
    $intent = $retirementPlan.PlanPayload.AuthorityStateIntent
    Assert ($intent.TaskOverlaySkills -is [System.Array] -and @($intent.TaskOverlaySkills).Count -eq 3 -and [string] $intent.TaskOverlaySkills[0].Platform -ceq 'Claude') 'intent TaskOverlaySkills uses the three-slot state array form'
    Assert ($intent.ManifestHashes -is [System.Array] -and @($intent.ManifestHashes).Count -eq 3) 'intent ManifestHashes uses the three-slot state array form'
    Assert ([string] $intent.EnvironmentLockHash -ceq [string] $initialPlan.PlanPayload.AuthorityStateIntent.EnvironmentLockHash) 'intent preserves the reviewed environment lock hash'
    Assert ([string] $intent.ControllerRepoFingerprint -ceq [string] $initialPlan.PlanPayload.AuthorityStateIntent.ControllerRepoFingerprint) 'intent preserves the controller repo fingerprint'
    Assert ([string] $intent.ApprovedToolchainHash -ceq [string] $initialPlan.PlanPayload.AuthorityStateIntent.ApprovedToolchainHash) 'intent preserves the approved toolchain hash'
    Assert ([string] $intent.LastOperationKind -ceq 'retirement') 'intent LastOperationKind is retirement'
    Assert ([string] $retirementPlan.PlanHash -ceq (Get-PlanHash -PlanPayload $retirementPlan.PlanPayload)) 'written PlanHash matches Get-PlanHash'
    Assert ([string] $retirementPlan.DocumentHash -ceq (Get-DocumentHash -Document $retirementPlan)) 'written DocumentHash matches Get-DocumentHash'
    $stateDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($statePath, [System.Text.UTF8Encoding]::new($false, $true)))
    $completedIntent = Complete-LivePlanAuthorityStateIntent -Document $retirementPlan
    $projectionNames = @($script:AuthorityStateIntentFieldNames | Where-Object { [string] $_ -cnotin @('PlanHash', 'DocumentHash', 'LastOperationKind') })
    $planProjection = [ordered]@{}
    foreach ($name in $projectionNames) { $planProjection[$name] = $completedIntent[$name] }
    $stateProjection = [ordered]@{}
    $stateProjected = Get-AuthorityStateIntentProjection -StateDocument $stateDocument
    foreach ($name in $projectionNames) { $stateProjection[$name] = $stateProjected[$name] }
    Assert ((Get-SemanticJsonHash -InputObject $planProjection) -ceq (Get-SemanticJsonHash -InputObject $stateProjection)) 'retirement intent projection matches the seeded authority state'

    Write-Host '[retirement selection conflict]'
    New-SeededAuthorityState -InitialPlan $initialPlan -ControlBase $controlBase -ClaudePostsetSkills @('retired-claude') | Out-Null
    $conflictPlanPath = Join-Path $plansRoot 'retirement-conflict-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $conflictPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'retirement-selection-conflict') 'retirement target inside the postset selection is rejected'
    $statePath = New-SeededAuthorityState -InitialPlan $initialPlan -ControlBase $controlBase

    Write-Host '[retirement apply drift gates]'
    $beforeBackupCount = @(Get-ChildItem -LiteralPath $fakeBackups -Force -ErrorAction SilentlyContinue).Count
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlanPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-retirement-manifest-required') 'apply rejects a retirement plan without the reviewed manifest before backup'
    $alternateManifest = Join-Path $plansRoot 'retire-skills-copy.json'
    Write-TextFile -Path $alternateManifest -Content (Get-Content -Raw -LiteralPath $retirementManifest)
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $alternateManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'apply rejects identical retirement bytes supplied from a different path'
    $alternateReasonixRoot = Join-Path $work 'alternate-reasonix-skills'
    Copy-Item -LiteralPath (Join-Path $fakeHome 'AppData/Roaming/reasonix/skills') -Destination $alternateReasonixRoot -Recurse -Force
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest, '-ReasonixLiveSkillsPath', $alternateReasonixRoot)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'apply rejects a reviewed plan against a different live root'
    Write-TextFile -Path $retirementManifest -Content '{"SchemaVersion":1,"Claude":["retired-claude"],"Codex":["retired-codex"],"Reasonix":["retired-reasonix"]}'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'apply rejects retirement manifest drift'
    $tamperedRetirement = Read-LivePlanDocument -Path $retirementPlanPath
    $tamperedRetirement.Metadata.GeneratedAtUtc = '2000-01-01T00:00:00.0000000Z'
    Write-TextFile -Path $retirementPlanPath -Content ((ConvertTo-Json -InputObject $tamperedRetirement -Depth 40) + "`n")
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'apply rejects reviewed-plan content tampering'
    Assert (@(Get-ChildItem -LiteralPath $fakeBackups -Force -ErrorAction SilentlyContinue).Count -eq $beforeBackupCount) 'every drift rejection happens before backup'
    Assert (Test-Path -LiteralPath $retiredTargets.Codex) 'drift rejections leave retirement targets untouched'

    Remove-Item -LiteralPath $retirementPlanPath -Force -ErrorAction SilentlyContinue
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'final retirement dry-run refreshes the bound plan'

    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    if ($result.Code -ne 0) { Write-Host '----- retirement apply child output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'retirement apply exits successfully'
    foreach ($target in $retiredTargets.Values) {
        Assert (-not (Test-Path -LiteralPath $target)) "explicit retirement prunes $target"
    }
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/unknown-local')) 'explicit retirement still preserves unrelated unknown skill'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker')) '.system sentinel survives explicit retirement'
    $liveTransactionsDirs = @(Get-ChildItem -LiteralPath (Join-Path $controlBase 'live-transactions') -Directory -Force | Sort-Object LastWriteTimeUtc)
    Assert ($liveTransactionsDirs.Count -ge 2) 'each apply publishes its own transaction journal namespace'
    foreach ($transactionDir in $liveTransactionsDirs) {
        Assert (Test-Path -LiteralPath (Join-Path $transactionDir.FullName 'result.json') -PathType Leaf) "transaction $($transactionDir.Name) published a fixed result"
    }
    $retirementTransaction = $liveTransactionsDirs[-1]
    $retirementJournalPhases = @(Get-ChildItem -LiteralPath $retirementTransaction.FullName -Filter '*.json' -File | ForEach-Object { $_.Name })
    Assert ($retirementJournalPhases -ccontains 'result.json') 'the retirement journal retains the fixed result file'
    $receiptDirs = @(Get-ChildItem -LiteralPath $fakeBackups -Directory -Force | Sort-Object LastWriteTimeUtc)
    Assert ($receiptDirs.Count -ge 2) 'each apply binds its own managed backup receipt'
    $retirementReceipt = $receiptDirs[-1]
    Assert (Test-Path -LiteralPath (Join-Path $retirementReceipt.FullName 'snapshot/claude/retired-claude/SKILL.md') -PathType Leaf) 'the managed backup receipt snapshots the exact retirement target'

    $replayPlanPath = Join-Path $plansRoot 'retirement-replay-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $replayPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'must identify an existing unknown live skill directory') 'successful retirement cannot silently reuse the same authorization after targets are gone'

    Write-Host '[Reasonix override retirement]'
    $reasonixOverrideRoot = Join-Path $work 'reasonix-override-live'
    Write-TextFile -Path (Join-Path $reasonixOverrideRoot 'demo/SKILL.md') -Content 'override-demo'
    Write-TextFile -Path (Join-Path $reasonixOverrideRoot 'retired-reasonix-override/SKILL.md') -Content "override-retired-sentinel`n"
    $overridePlanPath = Join-Path $plansRoot 'override-plan.json'
    Write-RetirementManifest -Path $retirementManifest -Reasonix @('retired-reasonix-override')
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-ReasonixLiveSkillsPath', $reasonixOverrideRoot, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $overridePlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'Reasonix override retirement dry-run exits successfully'
    $overridePlan = Read-LivePlanDocument -Path $overridePlanPath
    Assert ([string] $overridePlan.PlanPayload.Platforms[2].LiveRoot -ceq ([System.IO.Path]::GetFullPath($reasonixOverrideRoot))) 'plan binds the exact Reasonix override live root'
    # The installed claims authorize the environment's originally reviewed
    # roots; a retirement targeting an unclaimed root fails closed. A claimed
    # custom Reasonix root is covered by a dedicated sandbox in Step 5.
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-ReasonixLiveSkillsPath', $reasonixOverrideRoot, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $overridePlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-transaction-claims-binding-mismatch') 'retirement targeting a root outside the claimed bindings fails closed'
    Assert (Test-Path -LiteralPath (Join-Path $reasonixOverrideRoot 'retired-reasonix-override')) 'the rejected override retirement leaves its target untouched'


    Write-Host '[parity sandbox: Codex fallback + claimed custom Reasonix root]'
    # A dedicated second sandbox: the Codex live root resolves through the
    # .agents fallback (no .codex/skills) and the Reasonix root is overridden
    # at initial planning time, so the environment claims bind those exact
    # roots and both transactions run against them through the host.
    $work2 = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-sync-parity-$([Guid]::NewGuid().ToString('N'))"
    $plans2 = Join-Path $work2 'plans'
    $home2 = Join-Path $work2 'home'
    $controlBase2 = Join-Path $home2 'AppData\Local\ai-agent-dotfiles\control'
    $backups2 = Join-Path $home2 'AppData\Local\ai-agent-dotfiles\backups'
    $reasonixRoot2 = Join-Path $work2 'reasonix-live'
    foreach ($dir in @($work2, $plans2, $home2, (Join-Path $home2 '.agents\skills'))) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    function Invoke-Sync2 {
        param([string[]] $Arguments)
        return Invoke-SafetySandboxScript -SandboxRoot $work2 -ScriptPath $syncScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    }

    $repo2 = Join-Path $work2 'repo'
    foreach ($dir in @('harness-source/envs', 'manifests', 'tools/schema-validator', 'tools/gitleaks', 'schemas')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $repo2 $dir) | Out-Null
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/profiles') -Destination (Join-Path $repo2 'harness-source/profiles') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components') -Destination (Join-Path $repo2 'harness-source/components') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/envs/full.psd1') -Destination (Join-Path $repo2 'harness-source/envs/full.psd1') -Force
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        Copy-Item -LiteralPath (Join-Path $RepoRoot "manifests/managed-skills.$platform.txt") -Destination (Join-Path $repo2 "manifests/managed-skills.$platform.txt") -Force
    }
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/schema-validator/validator.lock.json') -Destination (Join-Path $repo2 'tools/schema-validator/validator.lock.json') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'tools/gitleaks/gitleaks.lock.json') -Destination (Join-Path $repo2 'tools/gitleaks/gitleaks.lock.json') -Force
    Copy-Item -LiteralPath (Join-Path $RepoRoot 'schemas') -Destination (Join-Path $repo2 'schemas') -Recurse -Force
    foreach ($platform in @('claude', 'codex', 'reasonix')) {
        $titlePlatform = [System.Globalization.CultureInfo]::InvariantCulture.TextInfo.ToTitleCase($platform)
        foreach ($name in (Import-PowerShellDataFile -LiteralPath (Join-Path $repo2 'harness-source/envs/full.psd1')).Skills[$titlePlatform]) {
            Write-FixtureSkillPlaceholder -Repo $repo2 -Platform $platform -Name ([string] $name)
        }
    }
    & git -C $repo2 init --quiet
    & git -C $repo2 add -A
    & git -C $repo2 -c 'user.name=parity fixture' -c 'user.email=parity-fixture@ai-agent-dotfiles.invalid' commit --quiet -m 'parity fixture'
    if ($LASTEXITCODE -ne 0) { throw 'parity fixture repo commit failed' }

    $parityInitialPlan = Join-Path $plans2 'parity-initial-plan.json'
    $result = Invoke-Sync2 -Arguments @('-RepoRoot', $repo2, '-ReasonixLiveSkillsPath', $reasonixRoot2, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $parityInitialPlan)
    if ($result.Code -ne 0) { Write-Host '----- parity initial dry-run output -----'; Write-Host $result.Out }
    # The existing .agents fallback root routes the Codex live target to
    # .agents, which makes the machine non-pristine: a fallback-root machine
    # requires the Phase 3 migrate/adopt flow, so pristine initial refuses.
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-selection-mismatch') 'a Codex fallback-root machine is not pristine for initial'
    Remove-Item -LiteralPath (Join-Path $home2 '.agents') -Recurse -Force
    $result = Invoke-Sync2 -Arguments @('-RepoRoot', $repo2, '-ReasonixLiveSkillsPath', $reasonixRoot2, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $parityInitialPlan)
    if ($result.Code -ne 0) { Write-Host '----- parity initial dry-run output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'parity initial dry-run exits 0'
    $parityInitialPlanDocument = Read-LivePlanDocument -Path $parityInitialPlan
    $parityRows = @($parityInitialPlanDocument.PlanPayload.TargetContextIntent.Rows)
    Assert ([string] $parityRows[2].RequestedPath -ceq ([System.IO.Path]::GetFullPath($reasonixRoot2))) 'parity plan claims the overridden Reasonix live root'

    # Bootstrap + canonical setup run in their own process: the sealed registry
    # route capture is process-global and the main sandbox already claimed it.
    $paritySetupScript = Join-Path $work2 'setup-authority.ps1'
    @'
#requires -Version 7.0
param([string] $AuthorityRepo, [string] $TargetRepo)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $AuthorityRepo 'scripts/json-artifact-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/root-claims-registry-common.ps1')
$home2 = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
$controlBase2 = Join-Path $home2 'AppData\Local\ai-agent-dotfiles\control'
$backups2 = Join-Path $home2 'AppData\Local\ai-agent-dotfiles\backups'
foreach ($folder in @((Join-Path $home2 'AppData\Roaming'), (Join-Path $home2 'AppData\Local'))) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
}
$identity = [pscustomobject][ordered]@{
    ResolverVersion = 'windows-token-sid-known-folder-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $home2
    RoamingAppDataRoot = (Join-Path $home2 'AppData\Roaming')
    LocalAppDataRoot = (Join-Path $home2 'AppData\Local')
}
$context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
$intent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)
$lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $intent
try { if ($null -eq $lock) { throw 'parity bootstrap returned no lock' } }
finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
$probe = Join-Path $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT 'canonical-probe'
$recoveryParent = Join-Path $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT 'canonical-recovery-parent'
foreach ($dir in @($probe, $recoveryParent)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$recoveryTemplate = Get-CanonicalCurrentUserOnlySecurityTemplate
$recoverySid = [Security.Principal.SecurityIdentifier]::new([string] $recoveryTemplate.OwnerSid)
$recoverySecurity = [Security.AccessControl.DirectorySecurity]::new()
$recoverySecurity.SetOwner($recoverySid)
$recoverySecurity.SetAccessRuleProtection($true, $false)
foreach ($rule in $recoveryTemplate.AccessRules) {
    $recoverySecurity.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($recoverySid, [Security.AccessControl.FileSystemRights]([long] $rule.FileSystemRights), [Security.AccessControl.InheritanceFlags]([long] $rule.InheritanceFlags), [Security.AccessControl.PropagationFlags]([long] $rule.PropagationFlags), [Security.AccessControl.AccessControlType]([long] $rule.AccessControlType)))
}
[System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($recoveryParent), $recoverySecurity)
$recovery = Join-Path $recoveryParent 'recovery'
New-Item -ItemType Directory -Force -Path $recovery | Out-Null
$recoverySecurity2 = [Security.AccessControl.DirectorySecurity]::new()
$recoverySecurity2.SetOwner($recoverySid)
$recoverySecurity2.SetAccessRuleProtection($true, $false)
foreach ($rule in $recoveryTemplate.AccessRules) {
    $recoverySecurity2.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($recoverySid, [Security.AccessControl.FileSystemRights]([long] $rule.FileSystemRights), [Security.AccessControl.InheritanceFlags]([long] $rule.InheritanceFlags), [Security.AccessControl.PropagationFlags]([long] $rule.PropagationFlags), [Security.AccessControl.AccessControlType]([long] $rule.AccessControlType)))
}
[System.IO.FileSystemAclExtensions]::SetAccessControl([System.IO.DirectoryInfo]::new($recovery), $recoverySecurity2)
try {
    $payload = New-CanonicalSetupPlanPayload -RepoRoot $TargetRepo -CanonicalRecoveryRoot $recovery -ControlBase $controlBase2 -BackupRoot $backups2 -ProbeRoot $probe -ToolchainRoot $AuthorityRepo
} catch {
    Write-Host ('SETUP-DIAG template: ' + (ConvertTo-Json -InputObject (Get-CanonicalCurrentUserOnlySecurityTemplate) -Compress))
    Write-Host ('SETUP-DIAG evidence: ' + (ConvertTo-Json -InputObject (Get-CanonicalDirectorySecurityEvidence -Path $recovery) -Compress))
    Write-Host ('SETUP-DIAG control exists: ' + (Test-Path -LiteralPath $controlBase2) + ' backups exists: ' + (Test-Path -LiteralPath $backups2))
    throw
}
$git = Get-CanonicalGitContext -RepoRoot $TargetRepo
$paths = Get-CanonicalTransactionContractPaths -GitContext $git
$state = New-CanonicalFinalSetupState -PlanPayload $payload -RepoRoot $TargetRepo
$setupLock = Enter-CanonicalRepoLock -LockPath ([string] $paths.LockPath) -AllowCreate
try {
    $bytes = [byte[]](ConvertTo-SemanticJsonBytes -InputObject $state)
    [IO.File]::WriteAllText([string] $paths.SetupStatePath, [Text.UTF8Encoding]::new($false).GetString($bytes), [Text.UTF8Encoding]::new($false))
}
finally { Exit-CanonicalRepoLock -LockHandle $setupLock }
Write-Host 'parity authority setup complete'
'@ | Set-Content -LiteralPath $paritySetupScript -Encoding UTF8
    $result = Invoke-SafetySandboxScript -SandboxRoot $work2 -ScriptPath $paritySetupScript -Arguments @('-AuthorityRepo', $RepoRoot, '-TargetRepo', $repo2) -AuthorityRepoRoot $RepoRoot
    if ($result.Code -ne 0) { Write-Host '----- parity setup output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'parity authority bootstrap and canonical setup succeed in their own process'

    $result = Invoke-Sync2 -Arguments @('-RepoRoot', $repo2, '-ReasonixLiveSkillsPath', $reasonixRoot2, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $parityInitialPlan)
    if ($result.Code -ne 0) { Write-Host '----- parity initial apply output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'parity initial apply completes through the receipt-backed host'
    Assert (Test-Path -LiteralPath (Join-Path $home2 '.codex\skills\brainstorming\SKILL.md')) 'parity initial installs codex brainstorming under the default root'
    Assert (Test-Path -LiteralPath (Join-Path $reasonixRoot2 'brainstorming\SKILL.md')) 'parity initial installs reasonix brainstorming under the claimed custom root'
    Assert (Test-Path -LiteralPath (Join-Path $controlBase2 'homes')) 'parity authority area exists under the derived control base'

    $parityRetired = Join-Path $reasonixRoot2 'retired-parity'
    Write-TextFile -Path (Join-Path $parityRetired 'SKILL.md') -Content "parity-retired`n"
    $parityRetireManifest = Join-Path $plans2 'parity-retire.json'
    Write-RetirementManifest -Path $parityRetireManifest -Reasonix @('retired-parity')
    $parityRetirementPlan = Join-Path $plans2 'parity-retirement-plan.json'
    $result = Invoke-Sync2 -Arguments @('-RepoRoot', $repo2, '-ReasonixLiveSkillsPath', $reasonixRoot2, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $parityRetirementPlan, '-RetireManifestPath', $parityRetireManifest)
    if ($result.Code -ne 0) { Write-Host '----- parity retirement dry-run output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'parity retirement dry-run exits 0'
    $result = Invoke-Sync2 -Arguments @('-RepoRoot', $repo2, '-ReasonixLiveSkillsPath', $reasonixRoot2, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $parityRetirementPlan, '-RetireManifestPath', $parityRetireManifest)
    if ($result.Code -ne 0) { Write-Host '----- parity retirement apply output -----'; Write-Host $result.Out }
    Assert ($result.Code -eq 0) 'parity retirement apply exits 0'
    Assert (-not (Test-Path -LiteralPath $parityRetired)) 'parity retirement prunes the claimed custom Reasonix root'
    Assert (Test-Path -LiteralPath (Join-Path $reasonixRoot2 'brainstorming\SKILL.md')) 'parity retirement keeps the managed reasonix skill'
    Remove-Item -LiteralPath $work2 -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host 'sync tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
