#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/canonical-preflight-common.ps1')

$script:pass = 0
$script:fail = 0
function Assert {
    param([bool]$Condition, [string]$Message)
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Assert-Throws {
    param([scriptblock]$Action, [string]$Message)
    try { & $Action; Assert $false $Message }
    catch { Assert $true $Message }
}
function Set-File {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Content)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { [System.IO.Directory]::CreateDirectory($parent) | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}
function Get-RepositoryMutationFingerprint {
    $rows = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in @('skills-source','claude/skills','codex/skills','reasonix/skills','manifests','reports')) {
        $path = Join-Path $RepoRoot $relative
        if (-not (Test-Path -LiteralPath $path)) {
            $rows.Add([ordered]@{ Path=$relative; State='MISSING'; Hash=$null })
        }
        elseif (Test-Path -LiteralPath $path -PathType Container) {
            $rows.Add([ordered]@{ Path=$relative; State='DIRECTORY'; Hash=(Get-SafeTreeSnapshot -Root $path).TreeHash })
        }
        else {
            $rows.Add([ordered]@{ Path=$relative; State='FILE'; Hash=(Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() })
        }
    }
    return Get-SemanticJsonHash -InputObject @($rows)
}
function Invoke-RawChild {
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][string[]]$Arguments)
    $output = & pwsh -NoProfile -File $ScriptPath @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ Code=$LASTEXITCODE; Output=$output }
}

$work = Join-Path $RepoRoot ('tmp/canonical-preflight-tests-' + [Guid]::NewGuid().ToString('N'))
$external = Join-Path ([System.IO.Path]::GetTempPath()) ('ai-agent-dotfiles-canonical-preflight-' + [Guid]::NewGuid().ToString('N'))
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
if (Test-Path -LiteralPath $external) { Remove-Item -LiteralPath $external -Recurse -Force }
[System.IO.Directory]::CreateDirectory($work) | Out-Null

try {
    Write-Host "`n[isolated canonical build and scan]" -ForegroundColor Cyan
    $before = Get-RepositoryMutationFingerprint
    $candidate = Join-Path $work 'success'
    [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
    $source = Join-Path $candidate 'skills-source'
    $null = Copy-SafeTree -SourceRoot (Join-Path $RepoRoot 'skills-source') -DestinationRoot $source
    $claude = Join-Path $candidate 'claude/skills'
    $codex = Join-Path $candidate 'codex/skills'
    $reasonix = Join-Path $candidate 'reasonix/skills'
    $manifests = Join-Path $candidate 'manifests'
    $buildResult = Join-Path $external 'build-result.json'
    $buildArgs = @(
        '-RepoRoot',$RepoRoot,'-CanonicalPreflight','-CandidateWorkspace',$candidate,'-SourceRoot',$source,
        '-ClaudeOutputRoot',$claude,'-CodexOutputRoot',$codex,'-ReasonixOutputRoot',$reasonix,
        '-ManifestOutputRoot',$manifests,'-CanonicalPreflightOutputRoot',$external,'-JsonPath',$buildResult
    )
    $build = Invoke-CanonicalPreflightChild -ToolchainRoot $RepoRoot -ScriptName 'build-skills.ps1' -Arguments $buildArgs -ResultPath $buildResult -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json')
    Assert ($build.Result -eq 'PASS' -and $build.ContentHash -cmatch '^[0-9a-f]{64}$') 'build: exit, schema, content hash, and PASS result are all accepted'
    Assert ((Test-Path -LiteralPath $claude) -and (Test-Path -LiteralPath $codex) -and (Test-Path -LiteralPath $reasonix) -and (Test-Path -LiteralPath $manifests)) 'build: all generated and manifest roots stay beneath CandidateWorkspace'
    Assert (-not (Test-Path -LiteralPath (Join-Path $candidate 'reports'))) 'build: no reviewed report is written beneath CandidateWorkspace'

    $scanResult = Join-Path $external 'scan-result.json'
    $scanArgs = @(
        '-RepoRoot',$RepoRoot,'-CanonicalPreflight','-SourceRoot',$candidate,
        '-CanonicalPreflightOutputRoot',$external,'-ScannerConfigPath',(Join-Path $RepoRoot '.gitleaks.toml'),'-JsonPath',$scanResult
    )
    $scan = Invoke-CanonicalPreflightChild -ToolchainRoot $RepoRoot -ScriptName 'scan-secrets.ps1' -Arguments $scanArgs -ResultPath $scanResult -SchemaPath (Join-Path $RepoRoot 'schemas/secret-scan.schema.json')
    Assert ($scan.Result -eq 'PASS' -and $scan.ContentHash -cmatch '^[0-9a-f]{64}$') 'scan: exit, schema, content hash, and PASS result are all accepted'

    $artifactManifest = Join-Path $external 'artifact-manifest.json'
    $artifactValidationSummary = Join-Path $external 'artifact-validation-summary.json'
    $artifactValidation = Publish-CanonicalPreflightArtifactValidation `
        -ToolchainRoot $RepoRoot `
        -RepoRoot $RepoRoot `
        -CanonicalPreflightOutputRoot $external `
        -BuildResultPath $build.ResultPath `
        -ScanResultPath $scan.ResultPath `
        -ArtifactManifestPath $artifactManifest `
        -ArtifactValidationSummaryPath $artifactValidationSummary `
        -ForbiddenRoots @($candidate)
    $manifestDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($artifactManifest, [System.Text.UTF8Encoding]::new($false, $true)))
    $summaryDocument = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($artifactValidationSummary, [System.Text.UTF8Encoding]::new($false, $true)))
    Assert (@($manifestDocument.Artifacts).Count -eq 2) 'artifact validation: manifest binds exactly the build and scan child artifacts'
    Assert (
        [string]$manifestDocument.Artifacts[0].ArtifactKind -ceq 'canonical-build-result' -and
        [string]$manifestDocument.Artifacts[0].Path -ceq [System.IO.Path]::GetFullPath($build.ResultPath) -and
        [string]$manifestDocument.Artifacts[0].Sha256 -ceq $build.ContentHash -and
        [string]$manifestDocument.Artifacts[1].ArtifactKind -ceq 'canonical-secret-scan-result' -and
        [string]$manifestDocument.Artifacts[1].Path -ceq [System.IO.Path]::GetFullPath($scan.ResultPath) -and
        [string]$manifestDocument.Artifacts[1].Sha256 -ceq $scan.ContentHash
    ) 'artifact validation: ordered child paths and hashes are exact'
    Assert (
        [string]$summaryDocument.Mode -ceq 'Manifest' -and
        [string]$summaryDocument.Result -ceq 'PASS' -and
        [long]$summaryDocument.Counts.ArtifactsValidated -eq 2 -and
        [long]$summaryDocument.Counts.Failed -eq 0
    ) 'artifact validation: validator summary proves PASS with two validated artifacts'
    $registryReaderText = ${function:Read-CanonicalPreflightDataFile}.Ast.Extent.Text
    $artifactGateText = ${function:Confirm-CanonicalPreflightArtifactValidation}.Ast.Extent.Text
    Assert (
        $registryReaderText -match 'Open-SafeDirectoryContainmentChain' -and
        $registryReaderText -match 'OpenAndHashChildRegularFile' -and
        $registryReaderText -match 'ReadHeldRegularFileBytes' -and
        $registryReaderText -match 'ParseInput' -and
        $registryReaderText -match 'SafeGetValue' -and
        $artifactGateText -match 'Read-CanonicalPreflightDataFile' -and
        $artifactGateText -notmatch 'Import-PowerShellDataFile|Get-FileHash'
    ) 'artifact validation parses and hashes the registry from one held exact-byte capture'
    Assert (
        [string]$artifactValidation.ArtifactManifestHash -cmatch '^[0-9a-f]{64}$' -and
        [string]$artifactValidation.ArtifactValidationSummaryHash -cmatch '^[0-9a-f]{64}$' -and
        (Test-PathInsideRoot -Path $artifactValidation.ArtifactManifestPath -Root $external) -and
        (Test-PathInsideRoot -Path $artifactValidation.ArtifactValidationSummaryPath -Root $external) -and
        -not (Test-PathInsideRoot -Path $artifactValidation.ArtifactManifestPath -Root $candidate) -and
        -not (Test-PathInsideRoot -Path $artifactValidation.ArtifactValidationSummaryPath -Root $candidate)
    ) 'artifact validation: manifest and summary are hash-bound external artifacts, never candidate artifacts'
    Assert-Throws {
        Publish-CanonicalPreflightArtifactValidation `
            -ToolchainRoot $RepoRoot `
            -RepoRoot $RepoRoot `
            -CanonicalPreflightOutputRoot $external `
            -BuildResultPath $build.ResultPath `
            -ScanResultPath $scan.ResultPath `
            -ArtifactManifestPath $artifactManifest `
            -ArtifactValidationSummaryPath $artifactValidationSummary `
            -ForbiddenRoots @($candidate)
    } 'artifact validation: manifest and summary reject replay instead of overwriting'
    Assert ((Get-RepositoryMutationFingerprint) -ceq $before) 'success: canonical/generated/manifests/reports remain byte-identical'

    Write-Host "`n[failing children remain isolated]" -ForegroundColor Cyan
    $failCandidate = Join-Path $work 'build-failure'
    [System.IO.Directory]::CreateDirectory($failCandidate) | Out-Null
    $failSource = Join-Path $failCandidate 'skills-source'
    $null = Copy-SafeTree -SourceRoot (Join-Path $RepoRoot 'skills-source') -DestinationRoot $failSource
    $sharedSkill = @(Get-ChildItem -LiteralPath (Join-Path $failSource 'shared') -Directory | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | Select-Object -First 1)[0]
    $null = Copy-SafeTree -SourceRoot $sharedSkill.FullName -DestinationRoot (Join-Path $failSource (Join-Path 'claude-only' $sharedSkill.Name))
    $failBuildResult = Join-Path $external 'build-failure-result.json'
    $rawBuild = Invoke-RawChild -ScriptPath (Join-Path $RepoRoot 'scripts/build-skills.ps1') -Arguments @(
        '-RepoRoot',$RepoRoot,'-CanonicalPreflight','-CandidateWorkspace',$failCandidate,'-SourceRoot',$failSource,
        '-ClaudeOutputRoot',(Join-Path $failCandidate 'claude/skills'),'-CodexOutputRoot',(Join-Path $failCandidate 'codex/skills'),
        '-ReasonixOutputRoot',(Join-Path $failCandidate 'reasonix/skills'),'-ManifestOutputRoot',(Join-Path $failCandidate 'manifests'),
        '-CanonicalPreflightOutputRoot',$external,'-JsonPath',$failBuildResult
    )
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json') -InstancePath $failBuildResult
    $failBuildDoc = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($failBuildResult))
    Assert ($rawBuild.Code -ne 0 -and [string]$failBuildDoc.Result -ceq 'FAIL') 'build failure: nonzero child publishes a schema-valid FAIL result'

    $scanFailCandidate = Join-Path $work 'scan-failure'
    Set-File -Path (Join-Path $scanFailCandidate 'skills-source/shared/unsafe/SKILL.md') -Content ("---`nname: unsafe`ndescription: test`n---`n`nsecret = `"sk-ant-$('Q' * 24)`"`n")
    $failScanResult = Join-Path $external 'scan-failure-result.json'
    $rawScan = Invoke-RawChild -ScriptPath (Join-Path $RepoRoot 'scripts/scan-secrets.ps1') -Arguments @(
        '-RepoRoot',$RepoRoot,'-CanonicalPreflight','-SourceRoot',$scanFailCandidate,'-CanonicalPreflightOutputRoot',$external,
        '-ScannerConfigPath',(Join-Path $RepoRoot '.gitleaks.toml'),'-JsonPath',$failScanResult
    )
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/secret-scan.schema.json') -InstancePath $failScanResult
    $failScanDoc = ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText($failScanResult))
    Assert ($rawScan.Code -ne 0 -and [string]$failScanDoc.Result -ceq 'FAIL') 'scan failure: nonzero child publishes a schema-valid FAIL result'
    Assert ((Get-RepositoryMutationFingerprint) -ceq $before) 'failure: canonical/generated/manifests/reports remain byte-identical'

    Write-Host "`n[result gate negatives]" -ForegroundColor Cyan
    Assert-Throws { Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath (Join-Path $external 'missing.json') -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json') } 'gate: zero exit with missing result fails closed'
    $invalid = Join-Path $external 'invalid.json'; Set-File -Path $invalid -Content "{}`n"
    Assert-Throws { Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath $invalid -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json') } 'gate: zero exit with invalid JSON contract fails closed'
    $falsePass = Join-Path $external 'false-pass.json'; Copy-Item -LiteralPath $failScanResult -Destination $falsePass
    Assert-Throws { Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath $falsePass -SchemaPath (Join-Path $RepoRoot 'schemas/secret-scan.schema.json') } 'gate: zero exit with Result=FAIL fails closed'
    $nonzeroPass = Join-Path $external 'nonzero-pass.json'; Copy-Item -LiteralPath $buildResult -Destination $nonzeroPass
    Assert-Throws { Confirm-CanonicalPreflightChildResult -ChildExitCode 9 -ResultPath $nonzeroPass -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json') } 'gate: nonzero exit with Result=PASS fails closed'

    Write-Host "`n[preflight child execution lease]" -ForegroundColor Cyan
    $leaseToolchain = Join-Path $work 'execution-lease-toolchain'
    $leaseScripts = Join-Path $leaseToolchain 'scripts'
    [System.IO.Directory]::CreateDirectory($leaseScripts) | Out-Null
    & git -C $leaseToolchain init -q
    if ($LASTEXITCODE -ne 0) { throw 'Unable to initialize the isolated preflight execution-lease fixture.' }
    $leaseScript = Join-Path $leaseScripts 'build-skills.ps1'
    Set-File -Path $leaseScript -Content @'
param(
    [Parameter(Mandatory)][string]$JsonPath,
    [Parameter(Mandatory)][string]$MarkerPath,
    [Parameter(Mandatory)][string]$FixturePath
)
$replacement = $PSScriptRoot + '-replaced'
try {
    [System.IO.Directory]::Move($PSScriptRoot, $replacement)
    [System.IO.File]::WriteAllText($MarkerPath, 'REPLACED', [System.Text.UTF8Encoding]::new($false))
}
catch [System.IO.IOException] {
    [System.IO.File]::WriteAllText($MarkerPath, 'BLOCKED', [System.Text.UTF8Encoding]::new($false))
}
[System.IO.File]::Copy($FixturePath, $JsonPath, $false)
Write-Output 'ORIGINAL_SCRIPT_EXECUTED'
'@
    $leaseMarker = Join-Path $external 'execution-lease-marker.txt'
    $leaseResult = Join-Path $external 'execution-lease-result.json'
    $leaseRun = Invoke-CanonicalPreflightChild `
        -ToolchainRoot $leaseToolchain `
        -ScriptName 'build-skills.ps1' `
        -Arguments @('-JsonPath',$leaseResult,'-MarkerPath',$leaseMarker,'-FixturePath',(Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-build-result.valid.json')) `
        -ResultPath $leaseResult `
        -SchemaPath (Join-Path $RepoRoot 'schemas/run-report.schema.json')
    Assert (
        [System.IO.File]::ReadAllText($leaseMarker, [System.Text.UTF8Encoding]::new($false, $true)) -ceq 'BLOCKED' -and
        (Test-Path -LiteralPath $leaseScripts -PathType Container) -and
        -not (Test-Path -LiteralPath ($leaseScripts + '-replaced')) -and
        [string]$leaseRun.Output -cmatch 'ORIGINAL_SCRIPT_EXECUTED'
    ) 'preflight child holds its script and full parent chain so ordinary parent replacement is blocked while original bytes execute'
    $heldExecutionText = ${function:Invoke-HeldCanonicalPreflightScript}.Ast.Extent.Text
    $childCallerText = ${function:Invoke-CanonicalPreflightChild}.Ast.Extent.Text
    $publishCallerText = ${function:Publish-CanonicalPreflightArtifactValidation}.Ast.Extent.Text
    Assert (
        $heldExecutionText -match 'Open-SafeDirectoryContainmentChain' -and
        $heldExecutionText -match 'OpenAndHashChildRegularFile' -and
        $childCallerText -match 'Invoke-HeldCanonicalPreflightScript' -and
        $publishCallerText -match 'Invoke-HeldCanonicalPreflightScript' -and
        $childCallerText -notmatch '&\s*pwsh' -and
        $publishCallerText -notmatch '&\s*pwsh'
    ) 'build, scan, and artifact-validator children share the same held-script execution lease'

    $leaseSchemas = Join-Path $leaseToolchain 'schemas'
    [System.IO.Directory]::CreateDirectory($leaseSchemas) | Out-Null
    foreach ($schemaName in @('run-report.schema.json','secret-scan.schema.json','artifact-validation-manifest.schema.json','artifact-validation-summary.schema.json','artifact-contracts.psd1')) {
        [System.IO.File]::Copy((Join-Path $RepoRoot (Join-Path 'schemas' $schemaName)), (Join-Path $leaseSchemas $schemaName), $false)
    }
    $leaseValidator = Join-Path $leaseScripts 'validate-json-artifacts.ps1'
    Set-File -Path $leaseValidator -Content @'
param(
    [Parameter(Mandatory)][string]$ArtifactManifestPath,
    [Parameter(Mandatory)][string]$JsonSummaryPath
)
$replacement = $PSScriptRoot + '-validator-replaced'
$marker = [Environment]::GetEnvironmentVariable('AI_AGENT_DOTFILES_PREFLIGHT_VALIDATOR_LEASE_MARKER')
try {
    [System.IO.Directory]::Move($PSScriptRoot, $replacement)
    [System.IO.File]::WriteAllText($marker, 'REPLACED', [System.Text.UTF8Encoding]::new($false))
}
catch [System.IO.IOException] {
    [System.IO.File]::WriteAllText($marker, 'BLOCKED_ORIGINAL_VALIDATOR_EXECUTED', [System.Text.UTF8Encoding]::new($false))
}
$root = Split-Path -Parent $PSScriptRoot
$registryPath = Join-Path $root 'schemas/artifact-contracts.psd1'
$registry = Import-PowerShellDataFile -LiteralPath $registryPath
$summary = [ordered]@{
    SchemaVersion = 1
    ArtifactKind = 'artifact-validation-summary'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    Mode = 'Manifest'
    RegistryHash = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    Counts = [ordered]@{ Contracts=[long]$registry.Contracts.Count; PositivePassed=0; NegativePassed=0; ArtifactsValidated=2; Failed=0 }
    Failures = @()
    Result = 'PASS'
}
[System.IO.File]::WriteAllText($JsonSummaryPath, (ConvertTo-Json $summary -Depth 10) + "`n", [System.Text.UTF8Encoding]::new($false))
Write-Output 'ORIGINAL_VALIDATOR_EXECUTED'
'@
    $leaseValidatorMarker = Join-Path $external 'validator-execution-lease-marker.txt'
    $leasePublishOutput = Join-Path $external 'validator-execution-lease'
    [System.IO.Directory]::CreateDirectory($leasePublishOutput) | Out-Null
    $leaseBuildResult = Join-Path $leasePublishOutput 'build-result.json'
    $leaseScanResult = Join-Path $leasePublishOutput 'scan-result.json'
    [System.IO.File]::Copy((Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-build-result.valid.json'), $leaseBuildResult, $false)
    [System.IO.File]::Copy((Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-secret-scan-result.valid.json'), $leaseScanResult, $false)
    $previousLeaseMarker = [Environment]::GetEnvironmentVariable('AI_AGENT_DOTFILES_PREFLIGHT_VALIDATOR_LEASE_MARKER')
    try {
        [Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_PREFLIGHT_VALIDATOR_LEASE_MARKER', $leaseValidatorMarker)
        $leaseValidation = Publish-CanonicalPreflightArtifactValidation `
            -ToolchainRoot $leaseToolchain `
            -RepoRoot $RepoRoot `
            -CanonicalPreflightOutputRoot $leasePublishOutput `
            -BuildResultPath $leaseBuildResult `
            -ScanResultPath $leaseScanResult `
            -ArtifactManifestPath (Join-Path $leasePublishOutput 'artifact-manifest.json') `
            -ArtifactValidationSummaryPath (Join-Path $leasePublishOutput 'artifact-validation-summary.json')
    }
    finally { [Environment]::SetEnvironmentVariable('AI_AGENT_DOTFILES_PREFLIGHT_VALIDATOR_LEASE_MARKER', $previousLeaseMarker) }
    Assert (
        [string]$leaseValidation.Result -ceq 'PASS' -and
        [System.IO.File]::ReadAllText($leaseValidatorMarker, [System.Text.UTF8Encoding]::new($false, $true)) -ceq 'BLOCKED_ORIGINAL_VALIDATOR_EXECUTED' -and
        (Test-Path -LiteralPath $leaseScripts -PathType Container) -and
        -not (Test-Path -LiteralPath ($leaseScripts + '-validator-replaced'))
    ) 'artifact validator holds its script and full parent chain so ordinary parent replacement is blocked while original bytes execute'
    $leaseScriptsAfterReturn = $leaseScripts + '-after-return'
    [System.IO.Directory]::Move($leaseScripts, $leaseScriptsAfterReturn)
    [System.IO.Directory]::Move($leaseScriptsAfterReturn, $leaseScripts)
    Assert ((Test-Path -LiteralPath $leaseScripts -PathType Container) -and -not (Test-Path -LiteralPath $leaseScriptsAfterReturn)) 'preflight child execution lease is released after the process exits'

    Write-Host "`n[exact-byte preflight artifacts]" -ForegroundColor Cyan
    $raceSourcePath = Join-Path $RepoRoot 'tests/fixtures/artifacts/canonical-build-result.valid.json'
    $raceSchemaPath = Join-Path $RepoRoot 'schemas/run-report.schema.json'
    $raceAText = [System.IO.File]::ReadAllText($raceSourcePath, [System.Text.UTF8Encoding]::new($false, $true))
    $raceBText = $raceAText.Replace('"Result":"PASS"', '"Result":"FAIL"')
    $raceABytes = [System.Text.UTF8Encoding]::new($false).GetBytes($raceAText)
    $raceBBytes = [System.Text.UTF8Encoding]::new($false).GetBytes($raceBText)
    Assert ($raceABytes.Length -eq $raceBBytes.Length -and -not [Convert]::ToHexString($raceABytes).Equals([Convert]::ToHexString($raceBBytes), [System.StringComparison]::Ordinal)) 'exact-byte preflight race vectors differ while preserving length'

    $readRacePath = Join-Path $external 'read-snapshot-race.json'
    [System.IO.File]::WriteAllBytes($readRacePath, $raceABytes)
    $expectedRaceAHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($raceABytes)).ToLowerInvariant()
    $realFixedValidator = ${function:Invoke-FixedJsonSchemaValidation}
    $script:PreflightReadHashCalls = 0
    function Get-FileHash {
        param([string] $LiteralPath, [string] $Path, [string] $Algorithm = 'SHA256')
        $targetPath = if ($LiteralPath) { $LiteralPath } else { $Path }
        if ($targetPath -and [System.IO.Path]::GetFullPath($targetPath) -ceq [System.IO.Path]::GetFullPath($readRacePath)) {
            $script:PreflightReadHashCalls++
            if ($script:PreflightReadHashCalls -eq 2) { [System.IO.File]::WriteAllBytes($readRacePath, $raceABytes) }
        }
        return Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $targetPath -Algorithm $Algorithm
    }
    function Invoke-FixedJsonSchemaValidation {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$SchemaPath,[Parameter(Mandatory)][string]$InstancePath,[string]$ValidatorCacheRoot)
        $arguments = @{ SchemaPath=$SchemaPath; InstancePath=$InstancePath }
        if ($PSBoundParameters.ContainsKey('ValidatorCacheRoot')) { $arguments.ValidatorCacheRoot=$ValidatorCacheRoot }
        $result = & $realFixedValidator @arguments
        if ([System.IO.Path]::GetFullPath($InstancePath) -ceq [System.IO.Path]::GetFullPath($readRacePath)) { [System.IO.File]::WriteAllBytes($readRacePath, $raceBBytes) }
        return $result
    }
    try {
        $readRace = Read-CanonicalPreflightJsonArtifact -Path $readRacePath -SchemaPath $raceSchemaPath
        Assert ([string]$readRace.Document.Result -ceq 'PASS' -and [string]$readRace.ContentHash -ceq $expectedRaceAHash) 'preflight read returns document and hash from the schema-validated exact-byte capture'
    }
    finally {
        Set-Item -LiteralPath Function:Invoke-FixedJsonSchemaValidation -Value $realFixedValidator
        Remove-Item -LiteralPath Function:Get-FileHash -ErrorAction SilentlyContinue
        Remove-Variable -Name PreflightReadHashCalls -Scope Script -ErrorAction SilentlyContinue
    }

    $publishRacePath = Join-Path $external 'publish-snapshot-race.json'
    $publishDocument = ConvertFrom-SemanticJson -Json $raceAText
    $realFixedValidator = ${function:Invoke-FixedJsonSchemaValidation}
    function Invoke-FixedJsonSchemaValidation {
        [CmdletBinding()]
        param([Parameter(Mandatory)][string]$SchemaPath,[Parameter(Mandatory)][string]$InstancePath,[string]$ValidatorCacheRoot)
        $arguments = @{ SchemaPath=$SchemaPath; InstancePath=$InstancePath }
        if ($PSBoundParameters.ContainsKey('ValidatorCacheRoot')) { $arguments.ValidatorCacheRoot=$ValidatorCacheRoot }
        $result = & $realFixedValidator @arguments
        if ([System.IO.Path]::GetExtension($InstancePath) -ceq '.tmp') { [System.IO.File]::WriteAllBytes($InstancePath, $raceBBytes) }
        return $result
    }
    try {
        Assert-Throws {
            Publish-ValidatedPreflightJson -Document $publishDocument -Path $publishRacePath -SchemaPath $raceSchemaPath | Out-Null
        } 'preflight publish rejects a same-length temp edit before binding the final artifact'
    }
    finally {
        Set-Item -LiteralPath Function:Invoke-FixedJsonSchemaValidation -Value $realFixedValidator
        if (Test-Path -LiteralPath $publishRacePath) { Remove-Item -LiteralPath $publishRacePath -Force }
    }

    $top = @(Get-ChildItem -LiteralPath $candidate -Force | ForEach-Object Name | Sort-Object)
    Assert (@(Compare-Object $top @('claude','codex','manifests','reasonix','skills-source')).Count -eq 0) 'layout: CandidateWorkspace contains only source/generated/manifests roots'
    Assert (@(Get-ChildItem -LiteralPath $external -File -Force).Count -ge 6) 'layout: machine-readable results are published only beneath the external preflight output root'
}
catch {
    $script:fail++
    Write-Host "  FAIL  unhandled test error: $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Write-Host ''
    Write-Host ("Results: {0} passed, {1} failed" -f $script:pass, $script:fail) -ForegroundColor Cyan
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
    if (Test-Path -LiteralPath $external) { Remove-Item -LiteralPath $external -Recurse -Force }
}

if ($script:fail -ne 0) { exit 1 }
