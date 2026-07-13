#requires -Version 7.0
<#
.SYNOPSIS
    Read-only status report for harness environments: definition validity,
    staging freshness, and which environment is active.

.DESCRIPTION
    For each env definition (harness-source/envs/*.psd1), or only the one named
    with -Name, reports:

        definition   valid | invalid: <reason>
        staging      missing  no envs/<name>/ directory
                     stale    env.lock.json missing/corrupt, or its
                              DefinitionHash no longer matches the definition
                     built    env.lock.json DefinitionHash matches

    The report ends with the activation state (state/current-env.json, read via
    Read-HarnessEnvState): 'No environment activated.' when there is no state
    file, otherwise 'Active environment: <Name>' with a '(definition missing)'
    suffix when no matching definition file exists.

    This script writes nothing anywhere. Exit code is always 0; invalid
    definitions are surfaced as warnings.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER Name
    Optional env name (bare identifier). Default: report all envs.

.PARAMETER HomeRoot
    Home directory used for live managed-set parity. Defaults to $env:USERPROFILE.

.PARAMETER ProjectRoot
    Optional project directory. When given, reads the project's
    .agent-harness/profile.psd1 and, if it declares RequiredEnv, reports
    whether the active environment matches. Detection and reminder only —
    this never activates anything.

.OUTPUTS
    Human-readable status lines plus warnings for invalid definitions. Exit 0.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $Name,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $ProjectRoot,
    [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

function Get-HarnessEnvLiveSkillRoot {
    param(
        [Parameter(Mandatory)] [string] $HomeRootValue,
        [Parameter(Mandatory)] [ValidateSet('Claude', 'Codex')] [string] $Platform
    )

    if ($Platform -eq 'Claude') { return Join-Path $HomeRootValue '.claude/skills' }
    $preferred = Join-Path $HomeRootValue '.codex/skills'
    $fallback = Join-Path $HomeRootValue '.agents/skills'
    if (Test-Path -LiteralPath $preferred -PathType Container) { return $preferred }
    if (Test-Path -LiteralPath $fallback -PathType Container) { return $fallback }
    return $preferred
}

function Get-HarnessEnvManifestNames {
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-HarnessEnvLiveParity {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $StagingPath,
        [Parameter(Mandatory)] [string] $HomeRoot
    )

    $mismatches = [System.Collections.Generic.List[string]]::new()
    if (-not (Test-Path -LiteralPath $StagingPath -PathType Container)) {
        return [pscustomobject]@{ Status = 'not-checked'; Mismatches = @('staging-missing') }
    }

    foreach ($platform in @('Claude', 'Codex')) {
        $key = $platform.ToLowerInvariant()
        $stagedRoot = Join-Path $StagingPath "$key/skills"
            $liveRoot = Get-HarnessEnvLiveSkillRoot -HomeRootValue $HomeRoot -Platform $platform
        $expectedNames = Get-HarnessEnvManifestNames -Path (Join-Path $StagingPath "manifest.$key.txt")
        $managedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in (Get-HarnessEnvManifestNames -Path (Join-Path $RepoRoot "manifests/managed-skills.$key.txt"))) {
            [void] $managedNames.Add($name)
        }
        $liveNames = if (Test-Path -LiteralPath $liveRoot -PathType Container) {
            @(Get-ChildItem -LiteralPath $liveRoot -Directory -Force | Where-Object { $_.Name -ne '.system' } | ForEach-Object Name)
        } else { @() }
        $liveManagedNames = @($liveNames | Where-Object { $managedNames.Contains($_) })
        $expectedSet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        foreach ($name in $expectedNames) { [void] $expectedSet.Add($name) }
        foreach ($name in $expectedSet) {
            if ($name -notin $liveManagedNames) { $mismatches.Add("$platform/$name missing") ; continue }
            $stagedHash = Get-HarnessTreeHash -Path (Join-Path $stagedRoot $name)
            $liveHash = Get-HarnessTreeHash -Path (Join-Path $liveRoot $name)
            if ($stagedHash -ne $liveHash) { $mismatches.Add("$platform/$name content-drift") }
        }
        foreach ($name in $liveManagedNames) {
            if (-not $expectedSet.Contains($name)) { $mismatches.Add("$platform/$name unexpected-managed") }
        }
    }

    $codexLive = Get-HarnessEnvLiveSkillRoot -HomeRootValue $HomeRoot -Platform Codex
    $systemDir = Join-Path $codexLive '.system'
    $systemStatus = if (-not (Test-Path -LiteralPath $systemDir -PathType Container)) {
        'not-present'
    }
    elseif (Test-Path -LiteralPath (Join-Path $systemDir '.codex-system-skills.marker') -PathType Leaf) {
        'present-marker'
    }
    else {
        'present-marker-missing'
    }

    [pscustomobject]@{
        Status = if ($mismatches.Count -eq 0) { 'pass' } else { 'mismatch' }
        Mismatches = @($mismatches)
        SystemStatus = $systemStatus
    }
}

function Protect-HarnessEnvStatusText {
    param([AllowNull()] [string] $Text)
    if ($null -eq $Text) { return $null }
    $result = $Text
    $result = $result.Replace([System.IO.Path]::GetFullPath($repo), '<repo>')
    $result = $result.Replace([System.IO.Path]::GetFullPath($HomeRoot), '<home>')
    return $result
}

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$definitionFiles = @(Get-HarnessEnvDefinitionFiles -RepoRoot $repo)

$envNames = [System.Collections.Generic.List[string]]::new()
$definitionByName = @{}
$statusRows = [System.Collections.Generic.List[object]]::new()
$activeSummary = [ordered] @{
    Name = $null
    Status = 'none'
    LockValidity = 'not-checked'
    DefinitionDrift = $false
    LiveParity = [ordered] @{ Status = 'not-checked'; Mismatches = @() }
    SystemStatus = 'not-checked'
    BackupReference = $null
    LockHash = $null
    LockReasons = @()
}
$lockByName = @{}
$projectLinkage = 'not-requested'
foreach ($file in $definitionFiles) {
    $envName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $envNames.Add($envName)
    $definitionByName[$envName] = $file.FullName
}

if (-not [string]::IsNullOrWhiteSpace($Name)) {
    # Validates the bare-identifier shape as a side effect.
    $null = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $Name
    $envNames.Clear()
    $envNames.Add($Name)
}

Write-Output 'Harness environment status'

if ($envNames.Count -eq 0) {
    Write-Output '  (no env definitions found)'
}

foreach ($envName in $envNames) {
    $definitionStatus = 'valid'
    $definitionPath = $null
    if ($definitionByName.ContainsKey($envName)) {
        $definitionPath = $definitionByName[$envName]
        try {
            $definition = Read-HarnessEnvDefinition -Path $definitionPath
            $null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $definition
        }
        catch {
            $firstLine = ([string] $_.Exception.Message -split "`r?`n")[0]
            $definitionStatus = "invalid: $firstLine"
        }
    }
    else {
        $definitionStatus = 'invalid: definition file not found'
    }

    $stagingPath = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $envName
    $stagingStatus = 'missing'
    $lockResult = $null
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        $stagingStatus = 'stale'
        if ($null -ne $definitionPath) {
            try {
                $lockResult = Test-HarnessEnvLock -RepoRoot $repo -DefinitionPath $definitionPath -StagingPath $stagingPath
                if ($lockResult.Valid) {
                    $stagingStatus = 'built'
                }
            }
            catch {
                $stagingStatus = 'stale'
            }
        }
    }

    $lockByName[$envName] = $lockResult

    [string[]] $lockReasons = @()
    if ($null -ne $lockResult) {
        $lockReasons = [string[]] @($lockResult.Reasons | ForEach-Object { Protect-HarnessEnvStatusText -Text $_ })
    }
    $statusRows.Add([pscustomobject] [ordered] @{
        Name = $envName
        DefinitionStatus = if ($definitionStatus -eq 'valid') { 'valid' } else { 'invalid' }
        StagingStatus = $stagingStatus
        LockStatus = if ($null -eq $lockResult) { 'not-checked' } elseif ($lockResult.Valid) { 'valid' } else { 'invalid' }
        LockReasons = $lockReasons
    })
    $lockLabel = if ($null -eq $lockResult) { 'not-checked' } elseif ($lockResult.Valid) { 'valid' } else { 'invalid' }
    Write-Output ('  {0} definition={1}  staging={2}  lock={3}' -f $envName.PadRight(12), $definitionStatus, $stagingStatus, $lockLabel)
    if ($definitionStatus -ne 'valid') {
        Write-Warning "Env '$envName' $definitionStatus"
    }
}

Write-Output ''
$state = $null
try {
    $state = Read-HarnessEnvState -RepoRoot $repo
}
catch {
    Write-Warning ([string] $_.Exception.Message)
}
if ($null -eq $state) {
    Write-Output 'No environment activated.'
}
else {
    $activeName = [string] $state.Name
    $definitionDrift = $false
    $activeLock = $null
    $activeParity = [pscustomobject]@{ Status = 'not-checked'; Mismatches = @(); SystemStatus = 'not-checked' }
    if (-not $definitionByName.ContainsKey($activeName)) {
        $definitionDrift = $true
    }
    else {
        $definitionDrift = $state.PSObject.Properties.Name -contains 'DefinitionHash' -and
            [string] $state.DefinitionHash -ne (Get-HarnessEnvDefinitionHash -Path $definitionByName[$activeName])
        $activeLock = $lockByName[$activeName]
        $activeStaging = Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $activeName
        $activeParity = Get-HarnessEnvLiveParity -RepoRoot $repo -StagingPath $activeStaging -HomeRoot $HomeRoot
    }
    $lockValid = $null -ne $activeLock -and $activeLock.Valid
    $activeStatus = if (-not $definitionDrift -and $lockValid -and $activeParity.Status -eq 'pass') { 'active' } else { 'drift' }
    $suffix = if (-not $definitionByName.ContainsKey($activeName)) {
        ' (definition missing)'
    } elseif ($definitionDrift) {
        ' (definition changed since activation - re-run env activate)'
    } elseif ($activeStatus -eq 'drift') {
        ' (attestation drift - inspect env status)'
    } else { '' }
    [string[]] $activeLockReasons = @()
    if ($null -ne $activeLock) {
        $activeLockReasons = [string[]] @($activeLock.Reasons | ForEach-Object { Protect-HarnessEnvStatusText -Text $_ })
    }
    $activeSummary = [ordered] @{
        Name = $activeName
        Status = $activeStatus
        LockValidity = if ($null -eq $activeLock) { 'not-checked' } elseif ($activeLock.Valid) { 'valid' } else { 'invalid' }
        DefinitionDrift = $definitionDrift
        LiveParity = [ordered] @{ Status = $activeParity.Status; Mismatches = @($activeParity.Mismatches) }
        SystemStatus = if ($activeParity.PSObject.Properties.Name -contains 'SystemStatus') { $activeParity.SystemStatus } else { 'not-checked' }
        BackupReference = if ($state.PSObject.Properties.Name -contains 'BackupReference') { [string] $state.BackupReference } else { $null }
        LockHash = if ($null -eq $activeLock) { $null } else { $activeLock.LockHash }
        LockReasons = $activeLockReasons
    }
    Write-Output "Active environment: $activeName$suffix"
    Write-Output "  lock validity: $($activeSummary.LockValidity); live parity: $($activeSummary.LiveParity.Status); .system: $($activeSummary.SystemStatus)"
    if ($activeSummary.BackupReference) { Write-Output "  backup reference: $($activeSummary.BackupReference)" }
}

# Project linkage: detection and reminder only, never an automatic activate.
if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
    Write-Output ''
    $projectProfilePath = Join-Path $ProjectRoot '.agent-harness/profile.psd1'
    if (-not (Test-Path -LiteralPath $projectProfilePath -PathType Leaf)) {
        $projectLinkage = 'no-profile'
        Write-Output 'Project declares no RequiredEnv (no .agent-harness/profile.psd1).'
    }
    else {
        $projectData = $null
        try {
            $projectData = (Get-HarnessProjectProfile -ProjectRoot $ProjectRoot).Data
        }
        catch {
            Write-Warning "Project profile could not be read: $($_.Exception.Message)"
        }
        if ($null -eq $projectData -or
            -not $projectData.ContainsKey('RequiredEnv') -or
            [string]::IsNullOrWhiteSpace([string] $projectData.RequiredEnv)) {
            if ($null -ne $projectData) {
                $projectLinkage = 'no-required-env'
                Write-Output 'Project declares no RequiredEnv.'
            }
        }
        else {
            $requiredEnv = [string] $projectData.RequiredEnv
            if (-not $definitionByName.ContainsKey($requiredEnv)) {
                $projectLinkage = 'missing-definition'
                Write-Warning "Project requires env '$requiredEnv', which has no definition in harness-source/envs/."
            }
            elseif ($null -eq $state) {
                $projectLinkage = 'inactive'
                Write-Output "Project requires env '$requiredEnv' - no environment activated. Run: agent-dotfiles.ps1 env activate $requiredEnv -DryRun"
            }
            elseif ($requiredEnv -ieq [string] $state.Name) {
                $projectLinkage = 'matches-active'
                Write-Output "Project requires env '$requiredEnv' - matches active."
            }
            else {
                $projectLinkage = 'mismatch'
                Write-Output "Project requires env '$requiredEnv' - does not match active '$([string] $state.Name)'. Run: agent-dotfiles.ps1 env activate $requiredEnv -DryRun"
            }
        }
    }
}

if ($JsonPath) {
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 1
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Environments = @($statusRows)
        Active = $activeSummary
        ProjectLinkage = $projectLinkage
    }
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
}

exit 0
