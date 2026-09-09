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
$fakeBackups = Join-Path $work 'backups'
$controlBase = Join-Path $work 'control'
$plansRoot = Join-Path $work 'plans'
. (Join-Path $PSScriptRoot 'helpers/safety-sandbox.ps1')
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/live-plan-common.ps1')

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
    New-Item -ItemType Directory -Force -Path $work, $fakeHome, $fakeBackups, $plansRoot | Out-Null

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
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $initialApplyPlan)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-initial-apply-not-wired') 'pristine initial apply fails closed after the reviewed plan is validated'
    Assert (@(Get-ChildItem -LiteralPath $fakeBackups -Force -ErrorAction SilentlyContinue).Count -eq 0) 'unwired initial apply creates no backup'

    $tamperedPlanPath = Join-Path $plansRoot 'initial-apply-plan.json'
    $tampered = Read-LivePlanDocument -Path $tamperedPlanPath
    $tampered.Metadata.GeneratedAtUtc = '2000-01-01T00:00:00.0000000Z'
    Write-TextFile -Path $tamperedPlanPath -Content ((ConvertTo-Json -InputObject $tampered -Depth 40) + "`n")
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $tamperedPlanPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-hash-mismatch') 'apply rejects a tampered reviewed plan'

    Write-Host '[authority present gate]'
    $initialPlanHomeKey = [string] $initialPlan.PlanPayload.AuthorityStateIntent.HomeAuthorityKey
    New-Item -ItemType Directory -Force -Path (Join-Path (Join-Path $controlBase 'homes') $initialPlanHomeKey) | Out-Null
    $authorityPlanPath = Join-Path $plansRoot 'authority-plan.json'
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $authorityPlanPath)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-authority-present') 'initial dry-run refuses an occupied control base'
    Assert (-not (Test-Path -LiteralPath $authorityPlanPath)) 'authority-present rejection creates zero plan bytes'

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

    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-SkipBuild', '-SkipSecretScan', '-DryRun', '-PlanPath', $retirementPlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -ne 0 -and $result.Out -match 'live-plan-authority-missing') 'retirement dry-run requires the seeded schema 3 authority state'

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
    Assert ($result.Code -eq 0) 'retirement apply exits successfully'
    foreach ($target in $retiredTargets.Values) {
        Assert (-not (Test-Path -LiteralPath $target)) "explicit retirement prunes $target"
    }
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.claude/skills/unknown-local')) 'explicit retirement still preserves unrelated unknown skill'
    Assert (Test-Path -LiteralPath (Join-Path $fakeHome '.codex/skills/.system/.codex-system-skills.marker')) '.system sentinel survives explicit retirement'
    $retirementJournal = @(Get-ChildItem -LiteralPath $fakeBackups -Filter 'sync-journal.json' -File -Recurse | Sort-Object LastWriteTimeUtc)[-1]
    $retirementJournalState = Get-Content -Raw -LiteralPath $retirementJournal.FullName | ConvertFrom-Json
    Assert (@($retirementJournalState.Completed | Where-Object { $_.Action -eq 'prune' -and $_.Authority -eq 'explicit-retirement' }).Count -eq 3) 'sync journal records explicit retirement authority for each prune'
    $retirementBackup = (Split-Path -Parent $retirementJournal.FullName)
    Assert (Test-Path -LiteralPath (Join-Path $retirementBackup 'claude-skills/retired-claude/SKILL.md')) 'mandatory backup contains the exact retirement target'

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
    $result = Invoke-Sync -Arguments @('-RepoRoot', $v3Repo, '-ReasonixLiveSkillsPath', $reasonixOverrideRoot, '-SkipBuild', '-SkipSecretScan', '-Apply', '-PlanPath', $overridePlanPath, '-RetireManifestPath', $retirementManifest)
    Assert ($result.Code -eq 0) 'Reasonix override retirement apply exits successfully'
    Assert (-not (Test-Path -LiteralPath (Join-Path $reasonixOverrideRoot 'retired-reasonix-override'))) 'Reasonix override retirement target is pruned'
    $overrideBackup = @(Get-ChildItem -LiteralPath $fakeBackups -Directory -Recurse -Force | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'reasonix-skills/retired-reasonix-override/SKILL.md') } | Select-Object -First 1)
    Assert ($null -ne $overrideBackup) 'mandatory backup contains the exact Reasonix override retirement target'

    Write-Host '[prune-time target verification]'
    $tokens = $null
    $parseErrors = $null
    $syncAst = [System.Management.Automation.Language.Parser]::ParseFile($syncScript, [ref] $tokens, [ref] $parseErrors)
    Assert ($parseErrors.Count -eq 0) 'sync script parses before function-level prune tests'
    foreach ($functionName in @('Assert-SafeLiveSkillTarget', 'Get-StringSha256', 'Get-SkillTreeHash', 'Remove-OneSkillDir')) {
        $functionAst = $syncAst.Find({
            param($node)
            $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $functionName
        }, $true)
        Assert ($null -ne $functionAst) "sync script contains $functionName"
        $definition = [scriptblock]::Create($functionAst.Extent.Text)
        . $definition
    }
    $CodexSystemDirName = '.system'
    $removeUnitRoot = Join-Path $work 'remove-unit-live'
    New-Item -ItemType Directory -Force -Path $removeUnitRoot | Out-Null
    $reviewedHash = ('0' * 64) -join ''

    $missingRejected = $false
    try {
        Remove-OneSkillDir -LiveRoot $removeUnitRoot -Name 'missing-retired' -ExpectedHash $reviewedHash
    }
    catch {
        $missingRejected = $_.Exception.Message -match 'missing or non-directory'
    }
    Assert $missingRejected 'reviewed prune fails closed when the target disappeared after planning'

    Write-TextFile -Path (Join-Path $removeUnitRoot 'non-directory-retired') -Content "file-sentinel`n"
    $fileRejected = $false
    try {
        Remove-OneSkillDir -LiveRoot $removeUnitRoot -Name 'non-directory-retired' -ExpectedHash $reviewedHash
    }
    catch {
        $fileRejected = $_.Exception.Message -match 'missing or non-directory'
    }
    Assert $fileRejected 'reviewed prune fails closed when the target became a file after planning'

    $changedTarget = Join-Path $removeUnitRoot 'changed-retired'
    Write-TextFile -Path (Join-Path $changedTarget 'SKILL.md') -Content "changed-after-review`n"
    $changedRejected = $false
    try {
        Remove-OneSkillDir -LiveRoot $removeUnitRoot -Name 'changed-retired' -ExpectedHash $reviewedHash
    }
    catch {
        $changedRejected = $_.Exception.Message -match 'Refusing to prune changed skill'
    }
    Assert $changedRejected 'reviewed prune recomputes the moved target tree hash before deletion'
    Assert (Test-Path -LiteralPath (Join-Path $changedTarget 'SKILL.md')) 'hash-mismatch prune restores the original target directory'
    Assert (@(Get-ChildItem -LiteralPath $removeUnitRoot -Directory -Filter '.ai-agent-dotfiles-prune-*').Count -eq 0) 'hash-mismatch prune leaves no rollback directory behind'

    Write-Host 'sync tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
