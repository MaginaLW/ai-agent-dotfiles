#requires -Version 7.0
<#
.SYNOPSIS
    Repository validation orchestrator: runs every current non-suite validation gate
    exactly once, then emits the machine-readable artifact chain (child artifact
    manifest -> repository-validation-summary -> final artifact manifest).

.DESCRIPTION
    Phase 4 Task 3 (docs/specs/2026-09-16-phase4-schema-ci-release-proposal.md section 5).
    Local and CI callers invoke this script once; it preserves every current
    .github/workflows/validate.yml non-suite gate (moved, never dropped) and the
    unified test runner exactly once. Gate order (each name is a stable token):

        1. powershell-syntax           YAML step 11: check-powershell-syntax.ps1, exit 0.
        2. pinned-tool-verify          YAML steps 3-4 verify halves: install-schema-
                                       validator.ps1 -VerifyOnly and install-gitleaks.ps1
                                       -VerifyOnly, both exit 0. The install halves stay in
                                       CI before this orchestrator.
        3. build-generated-skills      YAML step 8: build-skills.ps1, exit 0.
        4. secret-scan                 YAML step 7: scan-secrets.ps1 -JsonPath <external>,
                                       exit 0 plus JSON summary SchemaVersion 1 Result PASS.
        5. repository-doctor           YAML step 6: doctor.ps1 on an isolated HOME under
                                       the output root with -SkipSecretsScan (the secret
                                       scan is the named prior gate), exit 0.
        6. generated-manifests-parity  YAML step 9: build-skills.ps1 leaves the tree
                                       unchanged, verified via git diff --quiet --exit-code
                                       and git status --porcelain under '.' plus the four
                                       literal Reasonix negative pathspecs (metadata only,
                                       never opened), no unexpected untracked files, and
                                       no tracked generated output.
        7. env-build-list-status       YAML step 10 equivalent: the 10 registered and
                                       carved-out schema files exist and parse, the latest
                                       reports/build-report-*.json sidecar carries its
                                       required fields, then build-harness-env.ps1 -Name
                                       work plus list-harness-env.ps1 plus
                                       status-harness-env.ps1 with the original JSON
                                       field and Result=PASS assertions.
        8. validate-json-artifacts     YAML step 5: validate-json-artifacts.ps1 -All,
                                       exactly once.
        9. unified-test-runner         YAML step 12: run-tests.ps1 -All, exactly once
                                       (suite discovery stays inside the runner; this
                                       script never names suite paths).
        10. dangerous-tracked-files    YAML step 13: the forbidden tracked-file patterns
                                       (pem/key/p12/pfx, id_rsa/id_ed25519, .env, tokens,
                                       auth/.credentials.json, backup paths, .ssh).
        11. clean-tracked-state        Release-evidence clean gate: git status
                                       --porcelain empty under '.' plus the same four
                                       literal Reasonix negative pathspecs.

    On success it emits, all create-new and schema-validated with the pinned validator
    using explicitly passed registered ArtifactKinds (never inferred from filenames):

        -ChildArtifactManifestPath  ArtifactKind 'artifact-validation-manifest'
                                    (ManifestRole=children as bound by the summary):
                                    one evidence entry per executed gate plus each
                                    registered artifact a gate produced.
        -JsonSummaryPath            ArtifactKind 'repository-validation-summary',
                                    SchemaVersion 1, ReportKind
                                    'repository-validation', binding the child manifest.
                                    The registered schema allows only gate Name and
                                    Result; per-gate exit codes, durations, command
                                    lines, and the suite summary path reference live in
                                    the per-gate evidence documents bound by the child
                                    manifest and in the parseable GATE output lines.
        -FinalArtifactManifestPath  ArtifactKind 'artifact-validation-manifest' listing
                                    the child manifest, the children, and the summary,
                                    never itself (acyclic child -> summary -> final).

    Exit code is 0 only when every executed gate passed and the artifact chain was
    emitted and validated. Any gate failure stops the run before the artifact chain.

.PARAMETER OutputRoot
    Required external directory for gate evidence and gate-produced JSON artifacts.
    It must be create-new or an existing EMPTY directory and must be disjoint from
    the repository worktree and Git private directories.

.PARAMETER SkipGates
    TEST-ONLY allowlist of gate names to skip. Production callers (including CI)
    never pass it; the default runs all gates. Gate names must exist in the active
    catalog; skipped gates are omitted from the artifact chain. Accepts multiple
    arguments or one comma-separated list.

.PARAMETER GateCatalogPath
    TEST-ONLY path to a .psd1 catalog (@{ SchemaVersion = 1; Gates = @(
    @{ Name = 'gate-name'; ScriptPath = 'C:\path\stub.ps1' } ... }) that REPLACES the
    built-in gate catalog. Stub gates run via pwsh -NoProfile -File and pass on
    exit 0. tests/repository-validation.tests.ps1 uses this (and -SkipGates) to
    inject gate stubs; it never calls the real orchestrator end-to-end and never
    triggers the multi-hour unified runner gate. Production callers never pass it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputRoot,
    [Parameter(Mandatory)] [string] $ChildArtifactManifestPath,
    [Parameter(Mandatory)] [string] $FinalArtifactManifestPath,
    [Parameter(Mandatory)] [string] $JsonSummaryPath,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string[]] $SkipGates,
    [string] $GateCatalogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'json-artifact-common.ps1')

# The documented gate order. Get-RepositoryValidationBuiltinGates must define exactly
# these names; tests/repository-validation.tests.ps1 pins this literal via the
# PowerShell AST.
$script:RepositoryValidationGateOrder = @(
    'powershell-syntax'           # YAML step 11
    'pinned-tool-verify'          # YAML steps 3-4 (-VerifyOnly halves)
    'build-generated-skills'      # YAML step 8
    'secret-scan'                 # YAML step 7
    'repository-doctor'           # YAML step 6
    'generated-manifests-parity'  # YAML step 9
    'env-build-list-status'       # YAML step 10 equivalent
    'validate-json-artifacts'     # YAML step 5, exactly once
    'unified-test-runner'         # YAML step 12, exactly once
    'dangerous-tracked-files'     # YAML step 13
    'clean-tracked-state'         # release-evidence clean gate
)

$ReasonixNegativePathspecs = @(
    ':(exclude).reasonix/desktop-topic-auto-title-meta.json'
    ':(exclude).reasonix/desktop-topic-created-at.json'
    ':(exclude).reasonix/desktop-topic-title-sources.json'
    ':(exclude).reasonix/desktop-topic-titles.json'
)

$script:ValidationRepoRoot = $RepoRoot
$script:ValidationOutputRoot = $null
$script:ValidationGateArtifacts = [System.Collections.Generic.List[object]]::new()

function Get-RepositoryValidationGateOrder {
    return @($script:RepositoryValidationGateOrder)
}

function Add-RepositoryValidationGateArtifact {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ArtifactKind,
        [Parameter(Mandatory)] [int] $SchemaVersion
    )
    $script:ValidationGateArtifacts.Add([pscustomobject]@{
        Path = [System.IO.Path]::GetFullPath($Path)
        ArtifactKind = $ArtifactKind
        SchemaVersion = $SchemaVersion
    })
}

function New-RepositoryValidationOutcome {
    param([Parameter(Mandatory)] [int] $ExitCode, [string] $Detail = '')
    return [pscustomobject]@{ ExitCode = $ExitCode; Detail = $Detail }
}

function Invoke-RepositoryValidationGateCommand {
    # Runs one gate child process and maps its exit code to a gate outcome without
    # throwing, so the engine can record the real exit code in the gate evidence.
    # The child's stdout lines are native command output: they are captured and
    # re-emitted through Write-Host so the gate output stays visible while this
    # function's pipeline carries only the outcome object.
    param(
        [Parameter(Mandatory)] [string] $ScriptPath,
        [AllowEmptyCollection()] [string[]] $ScriptArguments = @()
    )
    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        return New-RepositoryValidationOutcome -ExitCode 1 -Detail "Required gate script is missing: $ScriptPath"
    }
    $gateOutput = @(& pwsh -NoProfile -File $ScriptPath @ScriptArguments 2>&1)
    foreach ($line in $gateOutput) { Write-Host $line }
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        return New-RepositoryValidationOutcome -ExitCode $exitCode -Detail "Gate script failed with exit code ${exitCode}: $ScriptPath"
    }
    return New-RepositoryValidationOutcome -ExitCode 0
}

function Test-RepositoryValidationRequiredJsonFields {
    param(
        [Parameter(Mandatory)] $Document,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $RequiredFields,
        [Parameter(Mandatory)] [string] $Label
    )
    foreach ($required in $RequiredFields) {
        if (-not (@($Document.PSObject.Properties.Name) -contains $required)) {
            throw "$Label is missing required field: $required"
        }
    }
}

function Test-RepositoryValidationExternalOutputRoot {
    param([Parameter(Mandatory)] [string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $null = Resolve-PrivateArtifactPath -Path $full -Role ExternalUserArtifact -RepoRoot $script:ValidationRepoRoot -AllowMissingLeaf
    if (Test-Path -LiteralPath $full -PathType Leaf) {
        throw "Output root must be a directory, not an existing file: $full"
    }
    if (Test-Path -LiteralPath $full -PathType Container) {
        $children = @([System.IO.Directory]::GetFileSystemEntries($full))
        if ($children.Count -ne 0) {
            throw "Output root exists and is not empty: $full"
        }
    }
    else {
        [System.IO.Directory]::CreateDirectory($full) | Out-Null
    }
    return $full
}

function Assert-RepositoryValidationCreateNewPath {
    param([Parameter(Mandatory)] [string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    if (Test-Path -LiteralPath $full) {
        throw "Artifact path must be create-new but already exists: $full"
    }
    $null = Resolve-PrivateArtifactPath -Path $full -Role ExternalUserArtifact -RepoRoot $script:ValidationRepoRoot -AllowMissingLeaf
    return $full
}

function Get-RepositoryValidationFileSha256 {
    param([Parameter(Mandatory)] [string] $Path)
    $bytes = [System.IO.File]::ReadAllBytes([System.IO.Path]::GetFullPath($Path))
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Write-RepositoryValidationCreateNewJson {
    # Create-new strict JSON writer; returns the SHA-256 of the exact bytes written.
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] $Document)

    $full = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject $Document -Depth 20) + "`n")
    $stream = [System.IO.File]::Open($full, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
    return [Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Write-RepositoryValidationGateEvidence {
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $GateName,
        [Parameter(Mandatory)] [bool] $Passed,
        [Parameter(Mandatory)] [int] $ExitCode,
        [Parameter(Mandatory)] [long] $DurationMilliseconds,
        [Parameter(Mandatory)] [string] $Command,
        [string] $Detail = ''
    )
    $document = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'repository-validation-gate-evidence'
        GateName = $GateName
        Result = $(if ($Passed) { 'PASS' } else { 'FAIL' })
        ExitCode = $ExitCode
        DurationMilliseconds = $DurationMilliseconds
        Command = $Command
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    }
    if (-not [string]::IsNullOrEmpty($Detail)) { $document['Detail'] = $Detail }
    return Write-RepositoryValidationCreateNewJson -Path $Path -Document $document
}

function Get-RepositoryValidationBuiltinGates {
    # Real gate implementations, keyed by the documented gate order names. Each gate
    # returns an outcome (ExitCode 0 = pass); assertion failures throw and the engine
    # records them as failures with the message in the gate evidence. Gate script
    # blocks resolve $script:ValidationRepoRoot / $script:ValidationOutputRoot at
    # invocation time (script blocks do not close over this function's locals).
    $gates = [ordered]@{}

    $gates['powershell-syntax'] = @{
        Command = 'pwsh -NoProfile -File scripts/check-powershell-syntax.ps1'
        Invoke = {
            Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/check-powershell-syntax.ps1')
        }
    }

    $gates['pinned-tool-verify'] = @{
        Command = 'pwsh -NoProfile -File scripts/install-schema-validator.ps1 -VerifyOnly; pwsh -NoProfile -File scripts/install-gitleaks.ps1 -VerifyOnly'
        Invoke = {
            $validatorOutcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/install-schema-validator.ps1') -ScriptArguments @('-VerifyOnly')
            if ($validatorOutcome.ExitCode -ne 0) { return $validatorOutcome }
            Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/install-gitleaks.ps1') -ScriptArguments @('-VerifyOnly')
        }
    }

    $gates['build-generated-skills'] = @{
        Command = 'pwsh -NoProfile -File scripts/build-skills.ps1'
        Invoke = {
            Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/build-skills.ps1')
        }
    }

    $gates['secret-scan'] = @{
        Command = 'pwsh -NoProfile -File scripts/scan-secrets.ps1 -JsonPath <OutputRoot>\secret-scan.json'
        Invoke = {
            $scanJson = Join-Path $script:ValidationOutputRoot 'secret-scan.json'
            $outcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/scan-secrets.ps1') -ScriptArguments @('-JsonPath', $scanJson)
            if ($outcome.ExitCode -ne 0) { return $outcome }
            if (-not (Test-Path -LiteralPath $scanJson -PathType Leaf)) {
                throw 'Secret scan did not produce its machine-readable JSON summary.'
            }
            $scanReport = Get-Content -Raw -LiteralPath $scanJson | ConvertFrom-Json
            if ([int]$scanReport.SchemaVersion -ne 1 -or $scanReport.Result -ne 'PASS') {
                throw 'Secret scan JSON summary is missing or reports a failure.'
            }
            Add-RepositoryValidationGateArtifact -Path $scanJson -ArtifactKind 'canonical-secret-scan-result' -SchemaVersion 1
            return New-RepositoryValidationOutcome -ExitCode 0 -Detail "Secret scan JSON summary: $scanJson"
        }
    }

    $gates['repository-doctor'] = @{
        Command = 'pwsh -NoProfile -File scripts/doctor.ps1 -HomeRoot <OutputRoot>\doctor-home -SkipSecretsScan'
        Invoke = {
            $doctorPath = Join-Path $script:ValidationRepoRoot 'scripts/doctor.ps1'
            if (-not (Test-Path -LiteralPath $doctorPath -PathType Leaf)) {
                throw 'scripts/doctor.ps1 is missing; repository doctor is a required validation entry point.'
            }
            $isolatedHome = Join-Path $script:ValidationOutputRoot 'doctor-home'
            [System.IO.Directory]::CreateDirectory($isolatedHome) | Out-Null
            $savedHome = [Environment]::GetEnvironmentVariable('HOME', 'Process')
            $savedUserProfile = [Environment]::GetEnvironmentVariable('USERPROFILE', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('HOME', $isolatedHome, 'Process')
                [Environment]::SetEnvironmentVariable('USERPROFILE', $isolatedHome, 'Process')
                Write-Host 'Doctor live-path probes are isolated to the validation output root.'
                $outcome = Invoke-RepositoryValidationGateCommand -ScriptPath $doctorPath -ScriptArguments @('-HomeRoot', $isolatedHome, '-SkipSecretsScan')
            }
            finally {
                [Environment]::SetEnvironmentVariable('HOME', $savedHome, 'Process')
                [Environment]::SetEnvironmentVariable('USERPROFILE', $savedUserProfile, 'Process')
            }
            return $outcome
        }
    }

    $gates['generated-manifests-parity'] = @{
        Command = 'git diff/git status --porcelain/git ls-files under . plus the four literal Reasonix negative pathspecs'
        Invoke = {
            $policyPaths = @('.', ':(exclude).reasonix/desktop-topic-auto-title-meta.json', ':(exclude).reasonix/desktop-topic-created-at.json', ':(exclude).reasonix/desktop-topic-title-sources.json', ':(exclude).reasonix/desktop-topic-titles.json')

            $null = & git -C $script:ValidationRepoRoot diff --quiet --exit-code -- $policyPaths
            if ($LASTEXITCODE -ne 0) {
                $null = & git -C $script:ValidationRepoRoot status --short -- $policyPaths
                throw 'Build changed tracked files. Rebuild locally and commit the intended source or manifest changes.'
            }

            $porcelain = @(git -C $script:ValidationRepoRoot status --porcelain -- $policyPaths)
            if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect the tracked/non-ignored state after build.' }
            if ($porcelain.Count -gt 0) {
                $porcelain | ForEach-Object { Write-Host "Unexpected state: $_" }
                throw 'Build left tracked or non-ignored state under the policy pathspec.'
            }

            $untrackedFiles = @(git -C $script:ValidationRepoRoot ls-files --others --exclude-standard -- $policyPaths)
            if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect untracked files after build.' }
            if ($untrackedFiles.Count -gt 0) {
                $untrackedFiles | ForEach-Object { Write-Host "Unexpected untracked file: $_" }
                throw 'Build left unexpected untracked files.'
            }

            $trackedGenerated = @(git -C $script:ValidationRepoRoot ls-files -- claude/skills codex/skills reasonix/skills generated)
            if ($LASTEXITCODE -ne 0) { throw 'Unable to inspect generated output tracking state.' }
            if ($trackedGenerated.Count -gt 0) {
                $trackedGenerated | ForEach-Object { Write-Host "Tracked generated output: $_" }
                throw 'Generated output must remain untracked.'
            }

            return New-RepositoryValidationOutcome -ExitCode 0
        }
    }

    $gates['env-build-list-status'] = @{
        Command = 'schema-file existence check; build-report sidecar check; pwsh -NoProfile -File scripts/build-harness-env.ps1 -Name work; list-harness-env.ps1; status-harness-env.ps1'
        Invoke = {
            # (a) Required schema files exist and parse (YAML step 10 inventory,
            #     including the two deliberately unregistered project-profile schemas).
            $schemaPaths = @(
                'schemas/sync-plan.schema.json',
                'schemas/run-report.schema.json',
                'schemas/doctor-report.schema.json',
                'schemas/secret-scan.schema.json',
                'schemas/harness-env-status.schema.json',
                'schemas/harness-env-lock.schema.json',
                'schemas/harness-env-list.schema.json',
                'schemas/harness-env-build.schema.json',
                'schemas/harness-component.schema.json',
                'schemas/harness-platform-output.schema.json'
            )
            foreach ($relative in $schemaPaths) {
                $schemaPath = Join-Path $script:ValidationRepoRoot $relative
                if (-not (Test-Path -LiteralPath $schemaPath -PathType Leaf)) {
                    throw "Required schema is missing: $schemaPath"
                }
                Get-Content -Raw -LiteralPath $schemaPath | ConvertFrom-Json | Out-Null
            }

            # (b) The build produced a machine-readable JSON sidecar (gate 3 ran earlier).
            $buildReports = @(Get-ChildItem -LiteralPath (Join-Path $script:ValidationRepoRoot 'reports') -Filter 'build-report-*.json' -File)
            if ($buildReports.Count -eq 0) {
                throw 'Build did not produce a machine-readable JSON sidecar.'
            }
            $latest = $buildReports | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
            $report = Get-Content -Raw -LiteralPath $latest.FullName | ConvertFrom-Json
            Test-RepositoryValidationRequiredJsonFields -Document $report -Label 'Build JSON report' `
                -RequiredFields @('SchemaVersion', 'ReportKind', 'GeneratedAtUtc', 'Summary', 'Details', 'Result', 'NextAction')
            if ([int]$report.SchemaVersion -ne 1 -or $report.ReportKind -ne 'build') {
                throw 'Build JSON report has an unsupported schema or report kind.'
            }

            # (c) Build the work environment and assert its build JSON and lock.
            $envBuildJson = Join-Path $script:ValidationOutputRoot 'env-build.json'
            $buildOutcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/build-harness-env.ps1') -ScriptArguments @('-Name', 'work', '-RepoRoot', $script:ValidationRepoRoot, '-JsonPath', $envBuildJson)
            if ($buildOutcome.ExitCode -ne 0) { return $buildOutcome }
            $envBuild = Get-Content -Raw -LiteralPath $envBuildJson | ConvertFrom-Json
            Test-RepositoryValidationRequiredJsonFields -Document $envBuild -Label 'Harness environment build JSON' `
                -RequiredFields @('SchemaVersion', 'GeneratedAtUtc', 'Name', 'Result', 'DefinitionHash', 'TaskOverlayHash', 'TaskOverlaySkills', 'LockHash', 'RepositoryCommit', 'SkillSourceEvidence', 'FileCount')
            if ([int]$envBuild.SchemaVersion -ne 3 -or $envBuild.Name -ne 'work' -or $envBuild.Result -ne 'PASS') {
                throw 'Harness environment build JSON is invalid.'
            }
            $envLockPath = Join-Path $script:ValidationRepoRoot 'envs/work/env.lock.json'
            if (-not (Test-Path -LiteralPath $envLockPath -PathType Leaf)) { throw 'Harness environment lock was not generated.' }
            $envLock = Get-Content -Raw -LiteralPath $envLockPath | ConvertFrom-Json
            Test-RepositoryValidationRequiredJsonFields -Document $envLock -Label 'Harness environment lock' `
                -RequiredFields @('SchemaVersion', 'Name', 'DefinitionHash', 'TaskOverlayHash', 'TaskOverlaySkills', 'RepositoryCommit', 'ManifestHashes', 'SkillSourceEvidence', 'SkillSourceHashes', 'StagedSkillTreeHashes', 'ProfileSourceHash', 'ProfileOutputHash', 'BuiltFiles')
            if ([int]$envLock.SchemaVersion -ne 3 -or $envLock.Name -ne 'work') {
                throw 'Harness environment lock has an unsupported schema or name.'
            }

            # (d) Environment list keeps its authority branch metadata-only.
            $envListJson = Join-Path $script:ValidationOutputRoot 'env-list.json'
            $listOutcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/list-harness-env.ps1') -ScriptArguments @('-RepoRoot', $script:ValidationRepoRoot, '-JsonPath', $envListJson)
            if ($listOutcome.ExitCode -ne 0) { return $listOutcome }
            $envList = Get-Content -Raw -LiteralPath $envListJson | ConvertFrom-Json
            if ([int]$envList.SchemaVersion -ne 2 -or $null -eq $envList.Environments) { throw 'Harness environment list JSON is invalid.' }
            if (([string]$envList.Authority.RootClaimsStatus -eq 'MISSING') -and ([string]$envList.Authority.IntendedRoot.FilesystemCapabilityStatus -ne 'UNPROBED')) {
                throw 'Harness environment list intended-root branch is not metadata-only.'
            }

            # (e) Environment status attests the freshly built work environment.
            $envStatusJson = Join-Path $script:ValidationOutputRoot 'env-status.json'
            $statusOutcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/status-harness-env.ps1') -ScriptArguments @('-RepoRoot', $script:ValidationRepoRoot, '-JsonPath', $envStatusJson)
            if ($statusOutcome.ExitCode -ne 0) { return $statusOutcome }
            $envStatus = Get-Content -Raw -LiteralPath $envStatusJson | ConvertFrom-Json
            if ([int]$envStatus.SchemaVersion -ne 2 -or -not (@($envStatus.PSObject.Properties.Name) -contains 'Environments')) {
                throw 'Harness environment JSON status summary is invalid.'
            }
            if ([string]::IsNullOrWhiteSpace([string]$envStatus.Authority.Route) -or -not (@($envStatus.PSObject.Properties.Name) -contains 'Environments')) {
                throw 'Harness environment status carries no authority route.'
            }
            if (([string]$envStatus.Authority.RootClaimsStatus -eq 'MISSING') -and ([string]$envStatus.Authority.IntendedRoot.FilesystemCapabilityStatus -ne 'UNPROBED')) {
                throw 'Harness environment status intended-root branch is not metadata-only.'
            }
            $workStatus = @($envStatus.Environments | Where-Object { $_.Name -eq 'work' })
            if ($workStatus.Count -ne 1 -or $workStatus[0].StagingStatus -ne 'built' -or $workStatus[0].LockStatus -ne 'valid') {
                throw 'Harness environment status did not attest the freshly built work environment.'
            }

            Add-RepositoryValidationGateArtifact -Path $envBuildJson -ArtifactKind 'harness-env-build' -SchemaVersion 3
            Add-RepositoryValidationGateArtifact -Path $envListJson -ArtifactKind 'harness-env-list' -SchemaVersion 2
            Add-RepositoryValidationGateArtifact -Path $envStatusJson -ArtifactKind 'harness-env-status' -SchemaVersion 2
            return New-RepositoryValidationOutcome -ExitCode 0 -Detail "Machine-readable evidence validated: $latest"
        }
    }

    $gates['validate-json-artifacts'] = @{
        Command = 'pwsh -NoProfile -File scripts/validate-json-artifacts.ps1 -All -JsonPath <OutputRoot>\artifact-validation.json'
        Invoke = {
            $artifactSummaryJson = Join-Path $script:ValidationOutputRoot 'artifact-validation.json'
            $outcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/validate-json-artifacts.ps1') -ScriptArguments @('-All', '-JsonSummaryPath', $artifactSummaryJson)
            if ($outcome.ExitCode -ne 0) {
                return New-RepositoryValidationOutcome -ExitCode $outcome.ExitCode -Detail "Registered artifact validation failed with exit code $($outcome.ExitCode)."
            }
            Add-RepositoryValidationGateArtifact -Path $artifactSummaryJson -ArtifactKind 'artifact-validation-summary' -SchemaVersion 1
            return New-RepositoryValidationOutcome -ExitCode 0 -Detail "Artifact validation summary: $artifactSummaryJson"
        }
    }

    $gates['unified-test-runner'] = @{
        Command = 'pwsh -NoProfile -File scripts/run-tests.ps1 -All -JsonSummaryPath <OutputRoot>\test-summary.json'
        Invoke = {
            $testSummaryJson = Join-Path $script:ValidationOutputRoot 'test-summary.json'
            $outcome = Invoke-RepositoryValidationGateCommand -ScriptPath (Join-Path $script:ValidationRepoRoot 'scripts/run-tests.ps1') -ScriptArguments @('-All', '-JsonSummaryPath', $testSummaryJson)
            if ($outcome.ExitCode -ne 0) {
                return New-RepositoryValidationOutcome -ExitCode $outcome.ExitCode -Detail "Unified test runner failed with exit code $($outcome.ExitCode)."
            }
            Add-RepositoryValidationGateArtifact -Path $testSummaryJson -ArtifactKind 'test-run-summary' -SchemaVersion 1
            return New-RepositoryValidationOutcome -ExitCode 0 -Detail "Test summary: $testSummaryJson"
        }
    }

    $gates['dangerous-tracked-files'] = @{
        Command = 'git ls-files forbidden-pattern check (pem/key/p12/pfx, id_rsa/id_ed25519, .env, tokens, auth/.credentials.json, backup paths, .ssh)'
        Invoke = {
            $trackedFiles = @(git -C $script:ValidationRepoRoot ls-files)
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to enumerate tracked files.'
            }
            $violations = foreach ($relativePath in $trackedFiles) {
                $normalizedPath = $relativePath -replace '\\', '/'
                $leafName = [System.IO.Path]::GetFileName($normalizedPath)
                $isForbidden = (
                    $leafName -match '(?i)\.(pem|key|p12|pfx)$' -or
                    $leafName -match '(?i)^id_(rsa|ed25519)$' -or
                    $leafName -match '(?i)^\.env(?:\..+)?$' -or
                    $leafName -match '(?i)^\.?tokens?(?:\.(txt|json|ya?ml))?$' -or
                    $leafName -match '(?i)\.tokens?$' -or
                    $leafName -match '(?i)^(auth|\.credentials)\.json$' -or
                    $normalizedPath -match '(?i)(^|/)(backup|backups)(/|$)' -or
                    $normalizedPath -match '(?i)(^|/)\.ssh(/|$)'
                )
                if ($isForbidden) { $relativePath }
            }
            $violations = @($violations)
            if ($violations.Count -gt 0) {
                $violations | Sort-Object -Unique | ForEach-Object { Write-Host "Forbidden tracked file: $_" }
                throw 'Dangerous files are tracked. Remove them from Git history and rotate exposed credentials if necessary.'
            }
            return New-RepositoryValidationOutcome -ExitCode 0
        }
    }

    $gates['clean-tracked-state'] = @{
        Command = 'git status --porcelain under . plus the four literal Reasonix negative pathspecs'
        Invoke = {
            $policyPaths = @('.', ':(exclude).reasonix/desktop-topic-auto-title-meta.json', ':(exclude).reasonix/desktop-topic-created-at.json', ':(exclude).reasonix/desktop-topic-title-sources.json', ':(exclude).reasonix/desktop-topic-titles.json')
            $porcelain = @(git -C $script:ValidationRepoRoot status --porcelain -- $policyPaths)
            if ($LASTEXITCODE -ne 0) {
                throw 'Unable to inspect the tracked/non-ignored repository state.'
            }
            if ($porcelain.Count -gt 0) {
                $porcelain | ForEach-Object { Write-Host "Dirty tracked/non-ignored state: $_" }
                throw 'Repository tracked/non-ignored state is not clean under the policy pathspec.'
            }
            return New-RepositoryValidationOutcome -ExitCode 0
        }
    }

    return $gates
}

function Resolve-RepositoryValidationActiveGates {
    # Returns [ordered] gate name -> @{ Command; Invoke } or @{ Command; StubPath }.
    if ($GateCatalogPath) {
        if (-not (Test-Path -LiteralPath $GateCatalogPath -PathType Leaf)) {
            throw "Gate catalog file is missing: $GateCatalogPath"
        }
        $catalogData = Import-PowerShellDataFile -LiteralPath $GateCatalogPath
        if ([long]$catalogData.SchemaVersion -ne 1 -or -not $catalogData.ContainsKey('Gates')) {
            throw 'Gate catalog must carry SchemaVersion 1 and a Gates list.'
        }
        $activeGates = [ordered]@{}
        foreach ($entry in @($catalogData.Gates)) {
            $gateName = [string] $entry.Name
            $stubPath = [string] $entry.ScriptPath
            if ([string]::IsNullOrWhiteSpace($gateName) -or [string]::IsNullOrWhiteSpace($stubPath)) {
                throw 'Gate catalog entries require Name and ScriptPath.'
            }
            if ($activeGates.Contains($gateName)) { throw "Duplicate gate name in gate catalog: $gateName" }
            $activeGates[$gateName] = @{
                Command = "pwsh -NoProfile -File $stubPath"
                StubPath = $stubPath
            }
        }
        return $activeGates
    }

    $builtin = Get-RepositoryValidationBuiltinGates
    $order = Get-RepositoryValidationGateOrder
    if (@($builtin.Keys).Count -ne $order.Count) {
        throw 'Built-in gate catalog does not match the documented gate order count.'
    }
    foreach ($gateName in $order) {
        if (-not $builtin.Contains($gateName)) {
            throw "Built-in gate catalog is missing documented gate: $gateName"
        }
    }
    foreach ($gateName in @($builtin.Keys)) {
        if ($order -cnotcontains $gateName) {
            throw "Built-in gate catalog carries an undocumented gate: $gateName"
        }
    }
    return $builtin
}

# ---------------------------------------------------------------------------
# Preflight: external output root, create-new artifact paths, active catalog.
# ---------------------------------------------------------------------------
$script:ValidationOutputRoot = Test-RepositoryValidationExternalOutputRoot -Path $OutputRoot
$childManifestFullPath = Assert-RepositoryValidationCreateNewPath -Path $ChildArtifactManifestPath
$finalManifestFullPath = Assert-RepositoryValidationCreateNewPath -Path $FinalArtifactManifestPath
$summaryFullPath = Assert-RepositoryValidationCreateNewPath -Path $JsonSummaryPath

$activeGates = Resolve-RepositoryValidationActiveGates
$skipSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
if ($SkipGates) {
    # Accept both PowerShell-style multiple tokens and the single comma-separated
    # token that a pwsh -File caller passes; gate names can never contain commas.
    $skipNames = @($SkipGates | ForEach-Object { [string] $_ } | ForEach-Object { $_.Split(',') } | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    foreach ($skipName in $skipNames) {
        if (-not $activeGates.Contains($skipName)) {
            throw "Unknown gate name in -SkipGates: $skipName"
        }
        $null = $skipSet.Add($skipName)
        Write-Host ("GATE {0}: SKIP (test-only -SkipGates)" -f $skipName)
    }
}
$selectedGateCount = @($activeGates.Keys | Where-Object { -not $skipSet.Contains($_) }).Count
if ($selectedGateCount -eq 0) {
    throw 'No gates were selected to run; -SkipGates must not remove every gate.'
}

foreach ($gateName in @($activeGates.Keys)) {
    if ($gateName -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') {
        throw "Gate name is not safe for evidence file naming: $gateName"
    }
}

# ---------------------------------------------------------------------------
# Gate execution: each gate exactly once, in catalog order, stop on first failure.
# ---------------------------------------------------------------------------
$executedGateRecords = [System.Collections.Generic.List[object]]::new()
foreach ($gateName in @($activeGates.Keys)) {
    if ($skipSet.Contains($gateName)) { continue }
    $gate = $activeGates[$gateName]
    $clock = [System.Diagnostics.Stopwatch]::StartNew()
    $gateExitCode = -1
    $gateDetail = ''
    try {
        if ($gate.ContainsKey('StubPath')) {
            & pwsh -NoProfile -File $gate['StubPath']
            $gateExitCode = $LASTEXITCODE
            if ($gateExitCode -ne 0) {
                $gateDetail = "Catalog gate failed with exit code ${gateExitCode}: $($gate['Command'])"
            }
        }
        else {
            $outcome = & $gate['Invoke']
            $gateExitCode = [int] $outcome.ExitCode
            $gateDetail = [string] $outcome.Detail
        }
    }
    catch {
        $gateExitCode = -1
        $gateDetail = $_.Exception.Message
    }
    $clock.Stop()
    $gatePassed = ($gateExitCode -eq 0)
    $gateDurationMs = [long] $clock.Elapsed.TotalMilliseconds

    $evidencePath = Join-Path (Join-Path $script:ValidationOutputRoot 'evidence') ($gateName + '.json')
    $null = Write-RepositoryValidationGateEvidence -Path $evidencePath -GateName $gateName `
        -Passed $gatePassed -ExitCode $gateExitCode -DurationMilliseconds $gateDurationMs `
        -Command ([string] $gate['Command']) -Detail $gateDetail

    Write-Host ("GATE {0}: {1} ({2} ms)" -f $gateName, $(if ($gatePassed) { 'PASS' } else { 'FAIL' }), $gateDurationMs)
    if (-not [string]::IsNullOrEmpty($gateDetail)) {
        Write-Host ("GATE-DETAIL {0}: {1}" -f $gateName, $gateDetail)
    }
    if (-not $gatePassed) {
        Write-Host 'REPOSITORY VALIDATION: FAIL'
        exit 1
    }
    $executedGateRecords.Add([pscustomobject]@{ Name = $gateName; EvidencePath = $evidencePath })
}

# ---------------------------------------------------------------------------
# Artifact chain: child manifest (children) -> summary -> final manifest, each
# schema-validated with the pinned validator using explicit registered kinds.
# ---------------------------------------------------------------------------
$chainEntries = [System.Collections.Generic.List[object]]::new()
foreach ($record in $executedGateRecords) {
    $chainEntries.Add([ordered]@{
        ArtifactKind = 'repository-validation-gate-evidence'
        SchemaVersion = 1
        Path = $record.EvidencePath
        Sha256 = Get-RepositoryValidationFileSha256 -Path $record.EvidencePath
    })
}
foreach ($gateArtifact in @($script:ValidationGateArtifacts)) {
    $chainEntries.Add([ordered]@{
        ArtifactKind = $gateArtifact.ArtifactKind
        SchemaVersion = $gateArtifact.SchemaVersion
        Path = $gateArtifact.Path
        Sha256 = Get-RepositoryValidationFileSha256 -Path $gateArtifact.Path
    })
}

$childDocument = [ordered]@{
    SchemaVersion = 1
    ArtifactKind = 'artifact-validation-manifest'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    Artifacts = @($chainEntries)
}
$childSha256 = Write-RepositoryValidationCreateNewJson -Path $childManifestFullPath -Document $childDocument
$null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/artifact-validation-manifest.schema.json') -InstancePath $childManifestFullPath

$summaryDocument = [ordered]@{
    SchemaVersion = 1
    ReportKind = 'repository-validation'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    ChildArtifactManifest = [ordered]@{
        ManifestRole = 'children'
        Path = $childManifestFullPath
        Sha256 = $childSha256
    }
    Gates = @($executedGateRecords | ForEach-Object { [ordered]@{ Name = $_.Name; Result = 'PASS' } })
    Result = 'PASS'
}
$summarySha256 = Write-RepositoryValidationCreateNewJson -Path $summaryFullPath -Document $summaryDocument
$null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/repository-validation-summary.schema.json') -InstancePath $summaryFullPath

$finalEntries = [System.Collections.Generic.List[object]]::new()
$finalEntries.Add([ordered]@{
    ArtifactKind = 'artifact-validation-manifest'
    SchemaVersion = 1
    Path = $childManifestFullPath
    Sha256 = $childSha256
})
foreach ($entry in $chainEntries) { $finalEntries.Add($entry) }
$finalEntries.Add([ordered]@{
    ArtifactKind = 'repository-validation-summary'
    SchemaVersion = 1
    Path = $summaryFullPath
    Sha256 = $summarySha256
})
$finalDocument = [ordered]@{
    SchemaVersion = 1
    ArtifactKind = 'artifact-validation-manifest'
    GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
    Artifacts = @($finalEntries)
}
$null = Write-RepositoryValidationCreateNewJson -Path $finalManifestFullPath -Document $finalDocument
$null = Invoke-FixedJsonSchemaValidation -SchemaPath (Join-Path $RepoRoot 'schemas/artifact-validation-manifest.schema.json') -InstancePath $finalManifestFullPath

Write-Host ("Child artifact manifest: {0}" -f $childManifestFullPath)
Write-Host ("Repository validation summary: {0}" -f $summaryFullPath)
Write-Host ("Final artifact manifest: {0}" -f $finalManifestFullPath)
Write-Host 'REPOSITORY VALIDATION: PASS'
exit 0
