#requires -Version 7.0
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory, ParameterSetName = 'All')] [switch] $All,
    [Parameter(Mandatory, ParameterSetName = 'Manifest')] [string] $ArtifactManifestPath,
    [string] $JsonSummaryPath,
    [string] $ValidatorCacheRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')

function Read-SemanticJsonFile {
    param([Parameter(Mandatory)] [string] $Path)
    return ConvertFrom-SemanticJson -Json ([System.IO.File]::ReadAllText((Resolve-Path -LiteralPath $Path).Path, [System.Text.UTF8Encoding]::new($false, $true)))
}

function Resolve-RepositoryPath {
    param([Parameter(Mandatory)] [string] $Path)
    if ([System.IO.Path]::IsPathRooted($Path)) { return [System.IO.Path]::GetFullPath($Path) }
    return [System.IO.Path]::GetFullPath((Join-Path $RepoRoot $Path))
}

function Test-ScanInputManifestSemantics {
    param([Parameter(Mandatory)] [string] $Path)
    $document = Read-SemanticJsonFile -Path $Path
    $expected = @(Get-ProtectedReasonixRelativePaths | Sort-Object)
    $actual = @($document.ExcludedProtectedPaths | Sort-Object)
    if (@(Compare-Object $expected $actual -CaseSensitive).Count -ne 0) { throw 'scan-input-manifest must bind exactly the four protected Reasonix paths.' }
    $paths = @($document.Files | ForEach-Object { [string] $_.RelativePath })
    if (@($paths | Sort-Object -Unique).Count -ne $paths.Count) { throw 'scan-input-manifest file paths must be unique.' }
    if (@(Compare-Object $paths @($paths | Sort-Object) -SyncWindow 0).Count -ne 0) { throw 'scan-input-manifest file paths must be sorted.' }
}

function Test-TestRunSummarySemantics {
    param([Parameter(Mandatory)] [string] $Path)
    $document = Read-SemanticJsonFile -Path $Path
    $counts = $document.Counts
    if ([long] $counts.Started -ne ([long] $counts.Passed + [long] $counts.Failed + [long] $counts.TimedOut)) { throw 'test-run-summary Started count is inconsistent.' }
    if ([long] $counts.Completed -ne ([long] $counts.Passed + [long] $counts.Failed)) { throw 'test-run-summary Completed count is inconsistent.' }
    if ([string] $document.Result -eq 'PASS') {
        foreach ($name in @('Failed', 'TimedOut', 'Duplicate', 'Missing', 'TreeKillFailed')) {
            if ([long] $counts[$name] -ne 0) { throw "PASS test-run-summary has nonzero $name." }
        }
        if ([long] $counts.Discovered -ne [long] $counts.Started -or [long] $counts.Started -ne [long] $counts.Completed -or [long] $counts.Completed -ne [long] $counts.Passed) {
            throw 'PASS test-run-summary does not prove exact once completion.'
        }
    }
}

function Test-ArtifactManifestSemantics {
    param([Parameter(Mandatory)] [string] $Path)
    $document = Read-SemanticJsonFile -Path $Path
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($artifact in $document.Artifacts) {
        $artifactPath = Resolve-RepositoryPath -Path ([string] $artifact.Path)
        if (-not $seen.Add($artifactPath)) { throw "Artifact manifest contains duplicate path: $artifactPath" }
        $evidenceRoot = Split-Path -Parent $artifactPath
        $null = Resolve-PrivateArtifactPath -Path $artifactPath -Role EvidenceInputPath -RepoRoot $RepoRoot -EvidenceRoots @($evidenceRoot)
        $actualHash = (Get-FileHash -LiteralPath $artifactPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actualHash -cne [string] $artifact.Sha256) { throw "Artifact content hash mismatch: $artifactPath" }
    }
}

function Test-ArtifactValidationSummarySemantics {
    param([Parameter(Mandatory)] [string] $Path)
    $document = Read-SemanticJsonFile -Path $Path
    if ([long] $document.Counts.Failed -ne @($document.Failures).Count) { throw 'artifact-validation-summary failure count is inconsistent.' }
    if ([string] $document.Result -eq 'PASS' -and ([long] $document.Counts.Failed -ne 0 -or @($document.Failures).Count -ne 0)) { throw 'PASS artifact-validation-summary contains failures.' }
}

function Invoke-ContractSemanticValidator {
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Contract, [Parameter(Mandatory)] [string] $Path)
    if (-not $Contract.ContainsKey('SemanticValidator') -or [string]::IsNullOrWhiteSpace([string] $Contract.SemanticValidator)) { return }
    $command = Get-Command -Name ([string] $Contract.SemanticValidator) -CommandType Function -ErrorAction Stop
    & $command -Path $Path
}

function Invoke-ContractValidation {
    param(
        [Parameter(Mandatory)] [string] $ArtifactKind,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Contract,
        [Parameter(Mandatory)] [string] $Path
    )
    $schemaPath = Resolve-RepositoryPath -Path ([string] $Contract.SchemaPath)
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $Path -ValidatorCacheRoot $ValidatorCacheRoot
    $document = Read-SemanticJsonFile -Path $Path
    if (-not $document.Contains('SchemaVersion') -or [long] $document.SchemaVersion -ne [long] $Contract.SchemaVersion) { throw "$ArtifactKind has an unsupported SchemaVersion." }
    Invoke-ContractSemanticValidator -Contract $Contract -Path $Path
}

function Write-CreateNewJson {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [object] $Document)
    $full = [System.IO.Path]::GetFullPath($Path)
    $null = Resolve-PrivateArtifactPath -Path $full -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf
    $parent = Split-Path -Parent $full
    [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Document -Depth 20) + "`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
}

$registryPath = Join-Path $RepoRoot 'schemas/artifact-contracts.psd1'
$registry = Import-PowerShellDataFile -LiteralPath $registryPath
if ([long] $registry.SchemaVersion -ne 1 -or -not $registry.ContainsKey('Contracts')) { throw 'Unsupported artifact registry.' }
$registryHash = (Get-FileHash -LiteralPath $registryPath -Algorithm SHA256).Hash.ToLowerInvariant()
$counts = [ordered]@{ Contracts = $registry.Contracts.Count; PositivePassed = 0; NegativePassed = 0; ArtifactsValidated = 0; Failed = 0 }
$failures = [System.Collections.Generic.List[string]]::new()
$mode = if ($All) { 'All' } else { 'Manifest' }

try {
    if ($All) {
        foreach ($artifactKind in @($registry.Contracts.Keys | Sort-Object)) {
            $contract = $registry.Contracts[$artifactKind]
            $positive = Resolve-RepositoryPath -Path ([string] $contract.PositiveFixture)
            try {
                Invoke-ContractValidation -ArtifactKind $artifactKind -Contract $contract -Path $positive
                $counts.PositivePassed++
            }
            catch { $counts.Failed++; $failures.Add("$artifactKind positive fixture: $($_.Exception.Message)") }

            foreach ($negative in @($contract.NegativeFixtures)) {
                $negativePath = Resolve-RepositoryPath -Path ([string] $negative.Path)
                $failedAt = $null
                try {
                    $schemaPath = Resolve-RepositoryPath -Path ([string] $contract.SchemaPath)
                    $null = Invoke-FixedJsonSchemaValidation -SchemaPath $schemaPath -InstancePath $negativePath -ValidatorCacheRoot $ValidatorCacheRoot
                }
                catch { $failedAt = 'Schema' }
                if (-not $failedAt) {
                    try { Invoke-ContractSemanticValidator -Contract $contract -Path $negativePath }
                    catch { $failedAt = 'Semantic' }
                }
                if ($failedAt -ceq [string] $negative.FailureLayer) { $counts.NegativePassed++ }
                else { $counts.Failed++; $failures.Add("$artifactKind/$($negative.Name) failed at '$failedAt', expected '$($negative.FailureLayer)'.") }
            }
        }
    }
    else {
        $manifestSchema = Join-Path $RepoRoot 'schemas/artifact-validation-manifest.schema.json'
        $null = Invoke-FixedJsonSchemaValidation -SchemaPath $manifestSchema -InstancePath $ArtifactManifestPath -ValidatorCacheRoot $ValidatorCacheRoot
        Test-ArtifactManifestSemantics -Path $ArtifactManifestPath
        $manifest = Read-SemanticJsonFile -Path $ArtifactManifestPath
        foreach ($artifact in $manifest.Artifacts) {
            $kind = [string] $artifact.ArtifactKind
            if (-not $registry.Contracts.ContainsKey($kind)) { throw "Unknown ArtifactKind: $kind" }
            $contract = $registry.Contracts[$kind]
            if ([long] $artifact.SchemaVersion -ne [long] $contract.SchemaVersion) { throw "Unsupported SchemaVersion for $kind." }
            Invoke-ContractValidation -ArtifactKind $kind -Contract $contract -Path (Resolve-RepositoryPath -Path ([string] $artifact.Path))
            $counts.ArtifactsValidated++
        }
    }
}
catch {
    $counts.Failed++
    $failures.Add($_.Exception.Message)
}

$result = if ($counts.Failed -eq 0) { 'PASS' } else { 'FAIL' }
$summary = [ordered]@{
    SchemaVersion = 1
    ArtifactKind = 'artifact-validation-summary'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    Mode = $mode
    RegistryHash = $registryHash
    Counts = $counts
    Failures = @($failures)
    Result = $result
}
if ($JsonSummaryPath) {
    Write-CreateNewJson -Path $JsonSummaryPath -Document $summary
    $null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/artifact-validation-summary.schema.json') -InstancePath $JsonSummaryPath -ValidatorCacheRoot $ValidatorCacheRoot
    Test-ArtifactValidationSummarySemantics -Path $JsonSummaryPath
}
$summary | ConvertTo-Json -Depth 10
if ($result -ne 'PASS') { exit 1 }
