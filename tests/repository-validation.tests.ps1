#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Repository validation orchestrator suite (Phase 4 Task 3, docs/specs/2026-09-16-
# phase4-schema-ci-release-proposal.md section 5, Task 3). It drives the
# orchestrator logic ONLY through injected gate stubs (-GateCatalogPath and
# -SkipGates, both documented test-only parameters): it never runs the built-in
# gate catalog end-to-end and never invokes scripts/run-tests.ps1, so there is no
# recursion and no multi-hour suite execution here. CI invokes the real
# orchestrator exactly once.
#
# The manifest documents cannot carry a ManifestRole field (the registered
# artifact-validation-manifest schema forbids additional properties); the roles
# are pinned by binding position: the summary binds the child manifest with
# ManifestRole 'children' (schema const), and the final manifest is the create-new
# -FinalArtifactManifestPath document that lists child + children + summary and is
# never referenced forward by the summary and never lists itself (acyclic).

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')

$orchestratorPath = Join-Path $RepoRoot 'scripts/run-repository-validation.ps1'
$summarySchemaPath = Join-Path $RepoRoot 'schemas/repository-validation-summary.schema.json'
$manifestSchemaPath = Join-Path $RepoRoot 'schemas/artifact-validation-manifest.schema.json'

# The documented gate order (must match the orchestrator's
# $script:RepositoryValidationGateOrder literal, pinned by AST below).
$ExpectedGateOrder = @(
    'powershell-syntax'
    'pinned-tool-verify'
    'build-generated-skills'
    'secret-scan'
    'repository-doctor'
    'generated-manifests-parity'
    'env-build-list-status'
    'validate-json-artifacts'
    'unified-test-runner'
    'dangerous-tracked-files'
    'clean-tracked-state'
)

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-repository-validation-$([Guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory -Path $work -Force | Out-Null

function Set-ValidationTextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-ValidationStubGate {
    param(
        [Parameter(Mandatory)] [string] $Directory,
        [Parameter(Mandatory)] [string] $Name,
        [Parameter(Mandatory)] [string] $LogPath,
        [Parameter(Mandatory)] [int] $ExitCode
    )
    $stubPath = Join-Path $Directory ($Name + '.stub.ps1')
    $content = @"
`$ErrorActionPreference = 'Stop'
[System.IO.File]::AppendAllText('$($LogPath.Replace("'", "''"))', '$($Name.Replace("'", "''"))' + [char]10, [System.Text.UTF8Encoding]::new(`$false))
exit $ExitCode
"@
    Set-ValidationTextFile -Path $stubPath -Content $content
    return $stubPath
}

function New-ValidationGateCatalog {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string[]] $Order, [Parameter(Mandatory)] [string] $LogPath, [hashtable] $ExitCodes = @{})
    $stubRoot = Join-Path (Split-Path -Parent $Path) 'stubs'
    $lines = @('@{', '    SchemaVersion = 1', '    Gates = @(')
    foreach ($gateName in $Order) {
        $exitCode = if ($ExitCodes.ContainsKey($gateName)) { [int] $ExitCodes[$gateName] } else { 0 }
        $stubPath = New-ValidationStubGate -Directory $stubRoot -Name $gateName -LogPath $LogPath -ExitCode $exitCode
        $lines += ("        @{{ Name = '{0}'; ScriptPath = '{1}' }}" -f $gateName, $stubPath.Replace("'", "''"))
    }
    $lines += @('    )', '}')
    Set-ValidationTextFile -Path $Path -Content (($lines -join "`r`n") + "`r`n")
}

function Get-ValidationLogLines {
    param([Parameter(Mandatory)] [string] $LogPath)
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return @() }
    return @((Get-Content -Raw -LiteralPath $LogPath).TrimEnd("`r", "`n") -split "`r?`n" | Where-Object { $_ })
}

function Get-ValidationSemanticJson {
    param([Parameter(Mandatory)] [string] $Path)
    return ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($Path, [System.Text.UTF8Encoding]::new($false, $true)))
}

function Get-ValidationLowercaseSha256 {
    param([Parameter(Mandatory)] [string] $Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

try {
    # -------------------------------------------------------------------------
    # Part 1: the orchestrator's declared gate order is pinned by AST
    # -------------------------------------------------------------------------
    Write-Host '[declared gate order pinned by AST]'
    $parseTokens = $null
    $parseErrors = $null
    $orchestratorAst = [System.Management.Automation.Language.Parser]::ParseFile($orchestratorPath, [ref]$parseTokens, [ref]$parseErrors)
    Assert-TestCondition (@($parseErrors).Count -eq 0) 'the orchestrator parses without syntax errors'
    $orderAssignments = @($orchestratorAst.FindAll({ param($node) $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$script:RepositoryValidationGateOrder' }, $true))
    Assert-TestCondition ($orderAssignments.Count -eq 1) 'the orchestrator declares exactly one gate order literal'
    $declaredOrder = @($orderAssignments[0].Right.Expression.FindAll({ param($node) $node -is [System.Management.Automation.Language.StringConstantExpressionAst] }, $true) | ForEach-Object { $_.Value })
    Assert-TestCondition ((@(Compare-Object $declaredOrder $ExpectedGateOrder -SyncWindow 0).Count -eq 0)) 'the declared gate order equals the documented 11-gate sequence with no duplicates and no omissions'

    # -------------------------------------------------------------------------
    # Part 2: injected stub catalog - every gate exactly once, in order, PASS lines
    # -------------------------------------------------------------------------
    Write-Host '[all gates exactly once in the documented order]'
    $runAll = Join-Path $work 'run-all'
    $runAllLog = Join-Path $runAll 'gate-log.txt'
    $runAllCatalog = Join-Path $runAll 'catalog.psd1'
    New-ValidationGateCatalog -Path $runAllCatalog -Order $ExpectedGateOrder -LogPath $runAllLog
    $runAllOutputRoot = Join-Path $runAll 'output'
    $childManifestPath = Join-Path $runAll 'children-manifest.json'
    $finalManifestPath = Join-Path $runAll 'final-manifest.json'
    $summaryPath = Join-Path $runAll 'summary.json'
    $runAllArguments = @(
        '-OutputRoot', $runAllOutputRoot,
        '-ChildArtifactManifestPath', $childManifestPath,
        '-FinalArtifactManifestPath', $finalManifestPath,
        '-JsonSummaryPath', $summaryPath,
        '-RepoRoot', $RepoRoot,
        '-GateCatalogPath', $runAllCatalog
    )
    $runAllResult = Invoke-TestProcess -ScriptPath $orchestratorPath -Arguments $runAllArguments
    if ($runAllResult.Code -ne 0) { Write-Host $runAllResult.Out }
    Assert-TestCondition ($runAllResult.Code -eq 0) 'a full stub catalog run exits zero'
    Assert-TestCondition ((@(Compare-Object (Get-ValidationLogLines -LogPath $runAllLog) $ExpectedGateOrder -SyncWindow 0).Count -eq 0)) 'every gate ran exactly once each in the documented order'
    foreach ($gateName in $ExpectedGateOrder) {
        Assert-TestCondition ($runAllResult.Out -match ("GATE $gateName`: PASS \(\d+ ms\)")) "the run prints one parseable PASS line with duration for $gateName"
    }

    # -------------------------------------------------------------------------
    # Part 3: the emitted artifact chain validates against its registered kinds
    # -------------------------------------------------------------------------
    Write-Host '[artifact chain schemas, roles, and acyclicity]'
    foreach ($chainPath in @($childManifestPath, $finalManifestPath, $summaryPath)) {
        Assert-TestCondition (Test-Path -LiteralPath $chainPath -PathType Leaf) "the chain document exists: $(Split-Path -Leaf $chainPath)"
    }
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $summarySchemaPath -InstancePath $summaryPath
    Assert-TestCondition ($true) 'the summary document validates against the repository-validation-summary schema'
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $manifestSchemaPath -InstancePath $childManifestPath
    Assert-TestCondition ($true) 'the child manifest validates against the registered artifact-validation-manifest kind'
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $manifestSchemaPath -InstancePath $finalManifestPath
    Assert-TestCondition ($true) 'the final manifest validates against the registered artifact-validation-manifest kind'

    $summaryDocument = Get-ValidationSemanticJson -Path $summaryPath
    Assert-TestCondition ([string] $summaryDocument['ReportKind'] -ceq 'repository-validation') 'the summary carries ReportKind repository-validation'
    Assert-TestCondition ([string] $summaryDocument['Result'] -ceq 'PASS') 'the summary records PASS'
    Assert-TestCondition ([string] $summaryDocument['ChildArtifactManifest']['ManifestRole'] -ceq 'children') 'the summary binds its child manifest with ManifestRole children'
    Assert-TestCondition ([string] $summaryDocument['ChildArtifactManifest']['Sha256'] -ceq (Get-ValidationLowercaseSha256 -Path $childManifestPath)) 'the summary child-manifest hash binds the exact emitted bytes'
    $summaryGateNames = @($summaryDocument['Gates'] | ForEach-Object { [string] $_['Name'] })
    Assert-TestCondition ((@(Compare-Object $summaryGateNames $ExpectedGateOrder -SyncWindow 0).Count -eq 0)) 'the summary lists every gate exactly once in the documented order'

    $childDocument = Get-ValidationSemanticJson -Path $childManifestPath
    $childPaths = @($childDocument['Artifacts'] | ForEach-Object { [string] $_['Path'] })
    Assert-TestCondition ($childPaths.Count -eq $ExpectedGateOrder.Count) 'the child manifest carries exactly one evidence entry per gate (children only)'
    foreach ($entry in @($childDocument['Artifacts'])) {
        Assert-TestCondition ([string] $entry['ArtifactKind'] -ceq 'repository-validation-gate-evidence') 'each child entry is a gate-evidence artifact'
    }
    foreach ($selfReferencingPath in @($childManifestPath, $finalManifestPath, $summaryPath)) {
        Assert-TestCondition (-not ($childPaths -ccontains $selfReferencingPath)) 'the child manifest never lists a chain document'
    }

    $finalDocument = Get-ValidationSemanticJson -Path $finalManifestPath
    $finalPaths = @($finalDocument['Artifacts'] | ForEach-Object { [string] $_['Path'] })
    Assert-TestCondition ($finalPaths.Count -eq ($ExpectedGateOrder.Count + 2)) 'the final manifest lists the child manifest, the children, and the summary'
    Assert-TestCondition ($finalPaths[0] -ceq $childManifestPath) 'the final manifest lists the child manifest first'
    Assert-TestCondition ($finalPaths[-1] -ceq $summaryPath) 'the final manifest closes with the summary'
    Assert-TestCondition (-not ($finalPaths -ccontains $finalManifestPath)) 'the final manifest never lists itself (acyclic)'
    Assert-TestCondition ((@($finalPaths | Sort-Object -Unique).Count -eq $finalPaths.Count)) 'the final manifest entries are unique'

    # -------------------------------------------------------------------------
    # Part 4: a wrong explicit ArtifactKind fails closed (never inferred)
    # -------------------------------------------------------------------------
    Write-Host '[wrong explicit kind fails closed]'
    $wrongKindThrew = $false
    try { $null = Invoke-FixedJsonSchemaValidation -SchemaPath $summarySchemaPath -InstancePath $childManifestPath }
    catch { $wrongKindThrew = $true }
    Assert-TestCondition $wrongKindThrew 'validating the child manifest against the summary kind fails closed'
    $wrongKindThrew = $false
    try { $null = Invoke-FixedJsonSchemaValidation -SchemaPath $manifestSchemaPath -InstancePath $summaryPath }
    catch { $wrongKindThrew = $true }
    Assert-TestCondition $wrongKindThrew 'validating the summary against the manifest kind fails closed'

    # -------------------------------------------------------------------------
    # Part 5: one failing gate fails the run and stops before the artifact chain
    # -------------------------------------------------------------------------
    Write-Host '[one failing gate stops the run before the chain]'
    $runFailure = Join-Path $work 'run-failure'
    $runFailureLog = Join-Path $runFailure 'gate-log.txt'
    $runFailureCatalog = Join-Path $runFailure 'catalog.psd1'
    New-ValidationGateCatalog -Path $runFailureCatalog -Order $ExpectedGateOrder -LogPath $runFailureLog -ExitCodes @{ 'env-build-list-status' = 7 }
    $failureArguments = @(
        '-OutputRoot', (Join-Path $runFailure 'output'),
        '-ChildArtifactManifestPath', (Join-Path $runFailure 'children-manifest.json'),
        '-FinalArtifactManifestPath', (Join-Path $runFailure 'final-manifest.json'),
        '-JsonSummaryPath', (Join-Path $runFailure 'summary.json'),
        '-RepoRoot', $RepoRoot,
        '-GateCatalogPath', $runFailureCatalog
    )
    $failureResult = Invoke-TestProcess -ScriptPath $orchestratorPath -Arguments $failureArguments
    Assert-TestCondition ($failureResult.Code -ne 0) 'a failing gate fails the orchestrator non-zero'
    Assert-TestCondition ($failureResult.Out -match 'REPOSITORY VALIDATION: FAIL') 'the run prints the parseable FAIL verdict'
    $failureLogLines = @(Get-ValidationLogLines -LogPath $runFailureLog)
    $expectedPartialOrder = @($ExpectedGateOrder | Select-Object -First 7)
    Assert-TestCondition ((@(Compare-Object $failureLogLines $expectedPartialOrder -SyncWindow 0).Count -eq 0)) 'gates after the failing gate never run and the failed gate ran once'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $runFailure 'summary.json'))) 'the failing run emits no summary document'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $runFailure 'children-manifest.json'))) 'the failing run emits no child manifest'
    Assert-TestCondition (-not (Test-Path -LiteralPath (Join-Path $runFailure 'final-manifest.json'))) 'the failing run emits no final manifest'

    # -------------------------------------------------------------------------
    # Part 6: a second run at the same -JsonSummaryPath fails create-new preflight
    # -------------------------------------------------------------------------
    Write-Host '[create-new collision on rerun]'
    $rerunArguments = @(
        '-OutputRoot', (Join-Path $runAll 'output-rerun'),
        '-ChildArtifactManifestPath', $childManifestPath,
        '-FinalArtifactManifestPath', $finalManifestPath,
        '-JsonSummaryPath', $summaryPath,
        '-RepoRoot', $RepoRoot,
        '-GateCatalogPath', $runAllCatalog
    )
    $rerunResult = Invoke-TestProcess -ScriptPath $orchestratorPath -Arguments $rerunArguments
    Assert-TestCondition ($rerunResult.Code -ne 0) 'a second run at the same artifact paths fails'
    Assert-TestCondition ($rerunResult.Out -match 'create-new') 'the rerun failure is the create-new collision'
    Assert-TestCondition ((@(Get-ValidationLogLines -LogPath $runAllLog).Count -eq $ExpectedGateOrder.Count)) 'the failed rerun executes no gate (preflight rejects first)'

    # -------------------------------------------------------------------------
    # Part 7: -SkipGates is validated and only removes the named gates
    # -------------------------------------------------------------------------
    Write-Host '[SkipGates allowlist semantics]'
    $runSkip = Join-Path $work 'run-skip-unknown'
    $skipUnknownArguments = @(
        '-OutputRoot', (Join-Path $runSkip 'output'),
        '-ChildArtifactManifestPath', (Join-Path $runSkip 'children-manifest.json'),
        '-FinalArtifactManifestPath', (Join-Path $runSkip 'final-manifest.json'),
        '-JsonSummaryPath', (Join-Path $runSkip 'summary.json'),
        '-RepoRoot', $RepoRoot,
        '-GateCatalogPath', $runAllCatalog,
        '-SkipGates', 'not-a-documented-gate'
    )
    $skipUnknownResult = Invoke-TestProcess -ScriptPath $orchestratorPath -Arguments $skipUnknownArguments
    Assert-TestCondition ($skipUnknownResult.Code -ne 0) 'an unknown -SkipGates name fails closed'

    $runSubset = Join-Path $work 'run-subset'
    $runSubsetLog = Join-Path $runSubset 'gate-log.txt'
    $runSubsetCatalog = Join-Path $runSubset 'catalog.psd1'
    $subsetOrder = @('powershell-syntax', 'secret-scan', 'clean-tracked-state')
    New-ValidationGateCatalog -Path $runSubsetCatalog -Order $subsetOrder -LogPath $runSubsetLog
    $subsetArguments = @(
        '-OutputRoot', (Join-Path $runSubset 'output'),
        '-ChildArtifactManifestPath', (Join-Path $runSubset 'children-manifest.json'),
        '-FinalArtifactManifestPath', (Join-Path $runSubset 'final-manifest.json'),
        '-JsonSummaryPath', (Join-Path $runSubset 'summary.json'),
        '-RepoRoot', $RepoRoot,
        '-GateCatalogPath', $runSubsetCatalog,
        '-SkipGates', 'secret-scan'
    )
    $subsetResult = Invoke-TestProcess -ScriptPath $orchestratorPath -Arguments $subsetArguments
    if ($subsetResult.Code -ne 0) { Write-Host $subsetResult.Out }
    Assert-TestCondition ($subsetResult.Code -eq 0) 'skipping one injected gate still passes the run'
    Assert-TestCondition ((@(Compare-Object (Get-ValidationLogLines -LogPath $runSubsetLog) @('powershell-syntax', 'clean-tracked-state') -SyncWindow 0).Count -eq 0)) 'the skipped gate does not run and the remainder keep their order'
    $subsetSummary = Get-ValidationSemanticJson -Path (Join-Path $runSubset 'summary.json')
    $subsetGateNames = @($subsetSummary['Gates'] | ForEach-Object { [string] $_['Name'] })
    Assert-TestCondition ((@(Compare-Object $subsetGateNames @('powershell-syntax', 'clean-tracked-state') -SyncWindow 0).Count -eq 0)) 'the summary records only the executed gates as PASS'
    Assert-TestCondition ($subsetResult.Out -match 'GATE secret-scan: SKIP') 'skipped gates print a parseable SKIP line'

    Write-Host 'repository validation tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
