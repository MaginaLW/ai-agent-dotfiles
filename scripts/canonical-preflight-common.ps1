#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')

function Resolve-CanonicalPreflightArtifactPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $CanonicalPreflightOutputRoot,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string[]] $ForbiddenRoots = @(),
        [switch] $AllowMissingLeaf
    )

    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $outputRoot = [System.IO.Path]::GetFullPath($CanonicalPreflightOutputRoot)
    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not (Test-PathInsideRoot -Path $full -Root $outputRoot)) {
        throw "Canonical preflight artifact is outside CanonicalPreflightOutputRoot: $full"
    }

    $commonDir = (& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null).Trim()
    if ($LASTEXITCODE -ne 0) { throw 'Unable to resolve Git common directory for canonical preflight output.' }
    $contractRoot = Join-Path $commonDir 'ai-agent-dotfiles/canonical-preflight'
    if (Test-PathInsideRoot -Path $outputRoot -Root $contractRoot) {
        return Resolve-PrivateArtifactPath -Path $full -Role InternalContractPath -RepoRoot $repo -InternalRoot $contractRoot -ForbiddenRoots $ForbiddenRoots -AllowMissingLeaf:$AllowMissingLeaf
    }
    return Resolve-PrivateArtifactPath -Path $full -Role ExternalUserArtifact -RepoRoot $repo -ForbiddenRoots $ForbiddenRoots -AllowMissingLeaf:$AllowMissingLeaf
}

function Publish-ValidatedPreflightJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [string] $ValidatorCacheRoot
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) { throw "Preflight artifact must be create-new: $full" }
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $temp = Join-Path $parent ('.' + [System.IO.Path]::GetFileName($full) + '.' + [Guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Document -Depth 30) + "`n")
        $intendedHash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $stream = [System.IO.File]::Open($temp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $stream.Write($bytes, 0, $bytes.Length)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        $tempValidation = Invoke-FixedJsonSchemaValidation -SchemaPath $SchemaPath -InstancePath $temp -ValidatorCacheRoot $ValidatorCacheRoot
        $tempCapture = Assert-ExactJsonArtifactCapture -Capture $tempValidation.ArtifactCapture
        if ([string] $tempCapture.Sha256 -cne $intendedHash) { throw 'Preflight temp artifact differs from the intended exact bytes.' }
        [System.IO.File]::Move($temp, $full)
        $finalValidation = Invoke-FixedJsonSchemaValidation -SchemaPath $SchemaPath -InstancePath $full -ValidatorCacheRoot $ValidatorCacheRoot
        $finalCapture = Assert-ExactJsonArtifactCapture -Capture $finalValidation.ArtifactCapture
        if ([string] $finalCapture.Sha256 -cne $intendedHash -or [string] $finalCapture.Sha256 -cne [string] $tempCapture.Sha256) {
            throw 'Published preflight artifact differs from the validated intended exact bytes.'
        }
        return [pscustomobject][ordered]@{ Path=$finalCapture.FullPath; ContentHash=$finalCapture.Sha256; Identity=$finalCapture.Identity }
    }
    finally {
        if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
    }
}

function Read-CanonicalPreflightJsonArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [string] $ValidatorCacheRoot
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $validation = Invoke-FixedJsonSchemaValidation -SchemaPath $SchemaPath -InstancePath $full -ValidatorCacheRoot $ValidatorCacheRoot
    $capture = Assert-ExactJsonArtifactCapture -Capture $validation.ArtifactCapture
    return [pscustomobject][ordered]@{ Path=$capture.FullPath; ContentHash=$capture.Sha256; Identity=$capture.Identity; Document=$capture.Document }
}

function Confirm-CanonicalPreflightChildResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [int] $ChildExitCode,
        [Parameter(Mandatory)] [string] $ResultPath,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [string] $ValidatorCacheRoot
    )

    $artifact = Read-CanonicalPreflightJsonArtifact -Path $ResultPath -SchemaPath $SchemaPath -ValidatorCacheRoot $ValidatorCacheRoot
    $document = $artifact.Document
    if ($ChildExitCode -ne 0) {
        throw "Canonical preflight child failed with exit code $ChildExitCode."
    }
    if ($document -isnot [System.Collections.IDictionary] -or -not $document.Contains('Result') -or [string]$document.Result -cne 'PASS') {
        throw 'Canonical preflight child result is not PASS.'
    }

    return [pscustomobject][ordered]@{
        ResultPath = $artifact.Path
        ContentHash = $artifact.ContentHash
        Result = 'PASS'
        ExitCode = $ChildExitCode
    }
}

function Resolve-CanonicalPreflightArtifactSet {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $CanonicalPreflightOutputRoot,
        [Parameter(Mandatory)] [string] $BuildResultPath,
        [Parameter(Mandatory)] [string] $ScanResultPath,
        [Parameter(Mandatory)] [string] $ArtifactManifestPath,
        [Parameter(Mandatory)] [string] $ArtifactValidationSummaryPath,
        [string[]] $ForbiddenRoots = @(),
        [switch] $AllowMissingValidationArtifacts
    )

    $paths = [ordered]@{
        BuildResult = Resolve-CanonicalPreflightArtifactPath -Path $BuildResultPath -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -RepoRoot $RepoRoot -ForbiddenRoots $ForbiddenRoots
        ScanResult = Resolve-CanonicalPreflightArtifactPath -Path $ScanResultPath -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -RepoRoot $RepoRoot -ForbiddenRoots $ForbiddenRoots
        ArtifactManifest = Resolve-CanonicalPreflightArtifactPath -Path $ArtifactManifestPath -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -RepoRoot $RepoRoot -ForbiddenRoots $ForbiddenRoots -AllowMissingLeaf:$AllowMissingValidationArtifacts
        ArtifactValidationSummary = Resolve-CanonicalPreflightArtifactPath -Path $ArtifactValidationSummaryPath -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -RepoRoot $RepoRoot -ForbiddenRoots $ForbiddenRoots -AllowMissingLeaf:$AllowMissingValidationArtifacts
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $paths.GetEnumerator()) {
        if (-not $seen.Add([string]$entry.Value.FullPath)) {
            throw "Canonical preflight artifact paths must be distinct: $($entry.Value.FullPath)"
        }
    }
    return $paths
}

function Read-CanonicalPreflightDataFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ToolchainRoot
    )

    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $schemaRoot = Join-Path $root 'schemas'
    $evidence = Resolve-PrivateArtifactPath -Path $Path -Role EvidenceInputPath -RepoRoot $root -EvidenceRoots @($schemaRoot)
    $parentHandles = $null
    $fileHandle = $null
    try {
        $parentHandlesReceiver2=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $evidence.FullPath) -OwnershipReceiver $parentHandlesReceiver2
        $parentHandles = $parentHandlesReceiver2.GetDeliveredExact()
        if ($parentHandles.Count -eq 0) { throw 'Unable to hold the canonical preflight data-file parent chain.' }
        $fileHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parentHandles[$parentHandles.Count - 1], [System.IO.Path]::GetFileName($evidence.FullPath))
        if ([string] $fileHandle.ReadResult.Identity -cne [string] $evidence.Identity -or
            [long] $fileHandle.ReadResult.Length -ne [long] $evidence.Length) {
            throw "Canonical preflight data-file identity changed while opening: $($evidence.FullPath)"
        }
        $bytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($fileHandle, [long] [int]::MaxValue)
        $hash = [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        if ($hash -cne [string] $fileHandle.ReadResult.Sha256) { throw 'Canonical preflight data-file held bytes do not match its captured hash.' }
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
        $tokens = $null
        $parseErrors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, [ref] $tokens, [ref] $parseErrors)
        if (@($parseErrors).Count -ne 0 -or $ast.EndBlock.Statements.Count -ne 1) { throw 'Canonical preflight data file is not one strict literal hashtable.' }
        $statement = $ast.EndBlock.Statements[0]
        if ($statement -isnot [System.Management.Automation.Language.PipelineAst] -or
            $statement.PipelineElements.Count -ne 1 -or
            $statement.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst] -or
            $statement.PipelineElements[0].Expression -isnot [System.Management.Automation.Language.HashtableAst]) {
            throw 'Canonical preflight data file is not one strict literal hashtable.'
        }
        $document = $statement.PipelineElements[0].Expression.SafeGetValue()
        if ($document -isnot [System.Collections.IDictionary]) { throw 'Canonical preflight data file did not evaluate to a literal dictionary.' }
        return [pscustomobject][ordered]@{
            Path = [string] $evidence.FullPath
            ContentHash = $hash
            Identity = [string] $fileHandle.ReadResult.Identity
            Document = $document
        }
    }
    finally {
        if ($null -ne $fileHandle) { $fileHandle.Dispose() }
        if ($null -ne $parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
    }
}

function Confirm-CanonicalPreflightArtifactValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolchainRoot,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $CanonicalPreflightOutputRoot,
        [Parameter(Mandatory)] [string] $BuildResultPath,
        [Parameter(Mandatory)] [string] $ScanResultPath,
        [Parameter(Mandatory)] [string] $ArtifactManifestPath,
        [Parameter(Mandatory)] [string] $ArtifactValidationSummaryPath,
        [string[]] $ForbiddenRoots = @(),
        [int] $ValidatorExitCode = 0,
        [string] $ValidatorCacheRoot
    )

    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $paths = Resolve-CanonicalPreflightArtifactSet -RepoRoot $RepoRoot -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -BuildResultPath $BuildResultPath -ScanResultPath $ScanResultPath -ArtifactManifestPath $ArtifactManifestPath -ArtifactValidationSummaryPath $ArtifactValidationSummaryPath -ForbiddenRoots $ForbiddenRoots
    $build = Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath $paths.BuildResult.FullPath -SchemaPath (Join-Path $root 'schemas/run-report.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
    $scan = Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath $paths.ScanResult.FullPath -SchemaPath (Join-Path $root 'schemas/secret-scan.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot

    $manifest = Read-CanonicalPreflightJsonArtifact -Path $paths.ArtifactManifest.FullPath -SchemaPath (Join-Path $root 'schemas/artifact-validation-manifest.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
    $artifacts = @($manifest.Document.Artifacts)
    if ($artifacts.Count -ne 2) { throw 'Canonical preflight artifact manifest must contain exactly two child artifacts.' }
    $expected = @(
        [pscustomobject]@{ ArtifactKind='canonical-build-result'; Path=$build.ResultPath; Hash=$build.ContentHash },
        [pscustomobject]@{ ArtifactKind='canonical-secret-scan-result'; Path=$scan.ResultPath; Hash=$scan.ContentHash }
    )
    for ($index = 0; $index -lt $expected.Count; $index++) {
        $actual = $artifacts[$index]
        if ([string]$actual.ArtifactKind -cne [string]$expected[$index].ArtifactKind -or
            [long]$actual.SchemaVersion -ne 1 -or
            [string]$actual.Path -cne [string]$expected[$index].Path -or
            [string]$actual.Sha256 -cne [string]$expected[$index].Hash) {
            throw "Canonical preflight artifact manifest child $index does not exactly bind its validated result."
        }
    }

    $summary = Read-CanonicalPreflightJsonArtifact -Path $paths.ArtifactValidationSummary.FullPath -SchemaPath (Join-Path $root 'schemas/artifact-validation-summary.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
    if ($ValidatorExitCode -ne 0) { throw "Artifact validator failed with exit code $ValidatorExitCode." }
    $registryPath = Join-Path $root 'schemas/artifact-contracts.psd1'
    $registryCapture = Read-CanonicalPreflightDataFile -Path $registryPath -ToolchainRoot $root
    $registry = $registryCapture.Document
    $summaryDocument = $summary.Document
    if ([string]$summaryDocument.Mode -cne 'Manifest' -or
        [string]$summaryDocument.Result -cne 'PASS' -or
        [string]$summaryDocument.RegistryHash -cne [string]$registryCapture.ContentHash -or
        [long]$summaryDocument.Counts.Contracts -ne [long]$registry.Contracts.Count -or
        [long]$summaryDocument.Counts.PositivePassed -ne 0 -or
        [long]$summaryDocument.Counts.NegativePassed -ne 0 -or
        [long]$summaryDocument.Counts.ArtifactsValidated -ne 2 -or
        [long]$summaryDocument.Counts.Failed -ne 0 -or
        @($summaryDocument.Failures).Count -ne 0) {
        throw 'Canonical preflight artifact validation summary does not exactly prove two validated PASS artifacts.'
    }

    return [pscustomobject][ordered]@{
        BuildResultPath = $build.ResultPath
        BuildResultHash = $build.ContentHash
        ScanResultPath = $scan.ResultPath
        ScanResultHash = $scan.ContentHash
        ArtifactManifestPath = $manifest.Path
        ArtifactManifestHash = $manifest.ContentHash
        ArtifactValidationSummaryPath = $summary.Path
        ArtifactValidationSummaryHash = $summary.ContentHash
        ArtifactsValidated = 2
        Result = 'PASS'
    }
}

function Invoke-HeldCanonicalPreflightScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $ScriptEvidence,
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $full = [System.IO.Path]::GetFullPath([string] $ScriptEvidence.FullPath)
    $parent = Split-Path -Parent $full
    $leaf = [System.IO.Path]::GetFileName($full)
    $parentHandles = $null
    $scriptHandle = $null
    try {
        $parentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $parent -OwnershipReceiver $parentHandlesReceiver
        $parentHandles = $parentHandlesReceiver.GetDeliveredExact()
        if ($parentHandles.Count -eq 0) { throw "Unable to hold the canonical preflight script parent chain: $parent" }
        $scriptHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parentHandles[$parentHandles.Count - 1], $leaf)
        if ([string] $scriptHandle.ReadResult.Identity -cne [string] $ScriptEvidence.Identity -or
            [long] $scriptHandle.ReadResult.Length -ne [long] $ScriptEvidence.Length) {
            throw "Canonical preflight script identity changed before execution: $full"
        }

        $output = & pwsh -NoProfile -File $full @Arguments 2>&1 | Out-String
        $exitCode = $LASTEXITCODE
        $null = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($scriptHandle, [long] [int]::MaxValue)
        return [pscustomobject][ordered]@{
            ScriptPath = $full
            ScriptHash = [string] $scriptHandle.ReadResult.Sha256
            Output = $output
            ExitCode = [int] $exitCode
        }
    }
    finally {
        if ($null -ne $scriptHandle) { $scriptHandle.Dispose() }
        if ($null -ne $parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
    }
}

function Publish-CanonicalPreflightArtifactValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolchainRoot,
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $CanonicalPreflightOutputRoot,
        [Parameter(Mandatory)] [string] $BuildResultPath,
        [Parameter(Mandatory)] [string] $ScanResultPath,
        [Parameter(Mandatory)] [string] $ArtifactManifestPath,
        [Parameter(Mandatory)] [string] $ArtifactValidationSummaryPath,
        [string[]] $ForbiddenRoots = @(),
        [string] $ValidatorCacheRoot
    )

    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $paths = Resolve-CanonicalPreflightArtifactSet -RepoRoot $RepoRoot -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -BuildResultPath $BuildResultPath -ScanResultPath $ScanResultPath -ArtifactManifestPath $ArtifactManifestPath -ArtifactValidationSummaryPath $ArtifactValidationSummaryPath -ForbiddenRoots $ForbiddenRoots -AllowMissingValidationArtifacts
    if ($paths.ArtifactManifest.Exists -or $paths.ArtifactValidationSummary.Exists) {
        throw 'Canonical preflight artifact manifest and validation summary must both be create-new.'
    }
    $build = Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath $paths.BuildResult.FullPath -SchemaPath (Join-Path $root 'schemas/run-report.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
    $scan = Confirm-CanonicalPreflightChildResult -ChildExitCode 0 -ResultPath $paths.ScanResult.FullPath -SchemaPath (Join-Path $root 'schemas/secret-scan.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot
    $manifestDocument = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'artifact-validation-manifest'
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Artifacts = @(
            [ordered]@{ ArtifactKind='canonical-build-result'; SchemaVersion=1; Path=$build.ResultPath; Sha256=$build.ContentHash },
            [ordered]@{ ArtifactKind='canonical-secret-scan-result'; SchemaVersion=1; Path=$scan.ResultPath; Sha256=$scan.ContentHash }
        )
    }
    $null = Publish-ValidatedPreflightJson -Document $manifestDocument -Path $paths.ArtifactManifest.FullPath -SchemaPath (Join-Path $root 'schemas/artifact-validation-manifest.schema.json') -ValidatorCacheRoot $ValidatorCacheRoot

    $validatorPath = Join-Path $root 'scripts/validate-json-artifacts.ps1'
    $validatorEvidence = Resolve-PrivateArtifactPath -Path $validatorPath -Role EvidenceInputPath -RepoRoot $root -EvidenceRoots @((Join-Path $root 'scripts'))
    $validatorArguments = @('-ArtifactManifestPath',$paths.ArtifactManifest.FullPath,'-JsonSummaryPath',$paths.ArtifactValidationSummary.FullPath)
    if (-not [string]::IsNullOrWhiteSpace($ValidatorCacheRoot)) { $validatorArguments += @('-ValidatorCacheRoot',$ValidatorCacheRoot) }
    $validatorExecution = Invoke-HeldCanonicalPreflightScript -ScriptEvidence $validatorEvidence -Arguments $validatorArguments
    $output = $validatorExecution.Output
    $exitCode = $validatorExecution.ExitCode
    try {
        return Confirm-CanonicalPreflightArtifactValidation -ToolchainRoot $root -RepoRoot $RepoRoot -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -BuildResultPath $paths.BuildResult.FullPath -ScanResultPath $paths.ScanResult.FullPath -ArtifactManifestPath $paths.ArtifactManifest.FullPath -ArtifactValidationSummaryPath $paths.ArtifactValidationSummary.FullPath -ForbiddenRoots $ForbiddenRoots -ValidatorExitCode $exitCode -ValidatorCacheRoot $ValidatorCacheRoot
    }
    catch {
        throw "$($_.Exception.Message) Validator output: $($output.Trim())"
    }
}

function Invoke-CanonicalPreflightChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ToolchainRoot,
        [Parameter(Mandatory)] [ValidateSet('build-skills.ps1', 'scan-secrets.ps1')] [string] $ScriptName,
        [Parameter(Mandatory)] [string[]] $Arguments,
        [Parameter(Mandatory)] [string] $ResultPath,
        [Parameter(Mandatory)] [string] $SchemaPath,
        [string] $ValidatorCacheRoot
    )

    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $scriptPath = Join-Path $root (Join-Path 'scripts' $ScriptName)
    $scriptEvidence = Resolve-PrivateArtifactPath -Path $scriptPath -Role EvidenceInputPath -RepoRoot $root -EvidenceRoots @((Join-Path $root 'scripts'))
    if (Test-Path -LiteralPath $ResultPath) {
        throw "Canonical preflight result must be create-new: $ResultPath"
    }

    $childExecution = Invoke-HeldCanonicalPreflightScript -ScriptEvidence $scriptEvidence -Arguments $Arguments
    $output = $childExecution.Output
    $exitCode = $childExecution.ExitCode
    try {
        $validated = Confirm-CanonicalPreflightChildResult -ChildExitCode $exitCode -ResultPath $ResultPath -SchemaPath $SchemaPath -ValidatorCacheRoot $ValidatorCacheRoot
        $validated | Add-Member -NotePropertyName Output -NotePropertyValue $output
        return $validated
    }
    catch {
        $message = $_.Exception.Message
        throw "$message Child output: $($output.Trim())"
    }
}
