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
    [string] $JsonPath,
    [string] $ReasonixLiveSkillsPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-authority-status-common.ps1')

function Protect-HarnessEnvStatusText {
    param([AllowNull()] [string] $Text)
    if ($null -eq $Text) { return $null }
    $result = $Text
    $result = $result.Replace([System.IO.Path]::GetFullPath($repo), '<repo>')
    $result = $result.Replace([System.IO.Path]::GetFullPath($HomeRoot), '<home>')
    return $result
}

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$taskOverlayPath = Get-HarnessTaskSkillOverlayPath -RepoRoot $repo
$definitionFiles = @(Get-HarnessEnvDefinitionFiles -RepoRoot $repo)
$authority = Get-HarnessEnvAuthorityAssessment -RepoRoot $repo -ReasonixLiveSkillsPath $ReasonixLiveSkillsPath
$authorityActive = [string] $authority.StateStatus -ceq 'VALID'

$envNames = [System.Collections.Generic.List[string]]::new()
$definitionByName = @{}
$statusRows = [System.Collections.Generic.List[object]]::new()
$activeSummary = [ordered] @{
    Name = $null
    Status = 'none'
    Source = 'none'
    LockValidity = 'not-checked'
    DefinitionDrift = $false
    TaskOverlayDrift = $false
    LiveParity = [ordered] @{ Status = 'not-checked'; Mismatches = @() }
    SystemStatus = 'not-checked'
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
            $taskOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $envName -Path $taskOverlayPath
            $effectiveDefinition = Merge-HarnessTaskSkillOverlay -Definition $definition -Overlay $taskOverlay
            $null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $effectiveDefinition
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
                $lockResult = Test-HarnessEnvLock -RepoRoot $repo -DefinitionPath $definitionPath -StagingPath $stagingPath -TaskOverlayPath $taskOverlayPath
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
    $reasonixCount = 0
    if ($null -ne $definitionPath) {
        try {
            $definitionForCount = Read-HarnessEnvDefinition -Path $definitionPath
            $taskOverlayForCount = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $envName -Path $taskOverlayPath
            $effectiveForCount = Merge-HarnessTaskSkillOverlay -Definition $definitionForCount -Overlay $taskOverlayForCount
            if ($effectiveForCount.Skills.ContainsKey('Reasonix')) {
                $reasonixCount = @($effectiveForCount.Skills.Reasonix).Count
            }
        }
        catch {
            $reasonixCount = 0
        }
    }
    $statusRows.Add([pscustomobject] [ordered] @{
        Name = $envName
        DefinitionStatus = if ($definitionStatus -eq 'valid') { 'valid' } else { 'invalid' }
        StagingStatus = $stagingStatus
        LockStatus = if ($null -eq $lockResult) { 'not-checked' } elseif ($lockResult.Valid) { 'valid' } else { 'invalid' }
        LockReasons = $lockReasons
        ReasonixSkillCount = $reasonixCount
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
if ($authorityActive) {
    # The shared authority state is the selector; it is the only source that
    # can describe a post-migration activation.
    $activeName = [string] $authority.StateSummary.EnvironmentName
    $definitionDrift = -not $definitionByName.ContainsKey($activeName)
    $taskOverlayDrift = $false
    $activeOverlay = $null
    $activeLockReasons = @($authority.LockParity.Reasons) + @($authority.LockParity.Mismatches)
    [string[]] $activeLockReasons = @($activeLockReasons | ForEach-Object { Protect-HarnessEnvStatusText -Text $_ })
    if (-not $definitionDrift) {
        $activeOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $activeName -Path $taskOverlayPath
        $taskOverlayDrift = [string] $authority.StateSummary.TaskOverlayHash -cne [string] $activeOverlay.Hash
        $activeLockPath = Get-HarnessEnvLockPath -StagingPath (Get-HarnessEnvStagingRoot -RepoRoot $repo -Name $activeName)
        if (Test-Path -LiteralPath $activeLockPath -PathType Leaf) {
            $activeLockFileHash = Get-HarnessFileHash -Path $activeLockPath
            if ([string] $authority.StateSummary.EnvironmentLockHash -ieq $activeLockFileHash) {
                $activeLockDocument = Read-HarnessEnvLock -Path $activeLockPath
                $definitionDrift = [string] $activeLockDocument['DefinitionHash'] -cne (Get-HarnessEnvDefinitionHash -Path $definitionByName[$activeName])
            }
        }
    }
    $activeStatus = if ($authority.ControllerMatch -and -not $definitionDrift -and -not $taskOverlayDrift -and [string] $authority.LockParity.Status -ceq 'pass') { 'active' } else { 'drift' }
    $suffix = if ($definitionDrift) {
        ' (definition changed since activation - re-run env activate)'
    } elseif ($taskOverlayDrift) {
        ' (task skill overlay changed since activation - re-run env task sync)'
    } elseif ($activeStatus -eq 'drift') {
        ' (attestation drift - inspect env status)'
    } else { '' }
    $activeSummary = [ordered] @{
        Name = $activeName
        Status = $activeStatus
        Source = 'authority'
        LockValidity = if ([string] $authority.LockParity.Status -ceq 'pass') { 'valid' } elseif ([string] $authority.LockParity.Status -ceq 'mismatch') { 'invalid' } else { 'not-checked' }
        DefinitionDrift = [bool] $definitionDrift
        TaskOverlayDrift = [bool] $taskOverlayDrift
        TaskOverlayHash = if ($null -eq $activeOverlay) { $null } else { $activeOverlay.Hash }
        LiveParity = [ordered] @{ Status = [string] $authority.LockParity.Status; Mismatches = @($authority.LockParity.Mismatches) }
        SystemStatus = [string] $authority.SystemStatus
        LockHash = if ([string] $authority.LockParity.Status -ceq 'not-checked') { $null } else { [string] $authority.StateSummary.EnvironmentLockHash }
        LockReasons = $activeLockReasons
    }
    Write-Output "Active environment: $activeName$suffix (shared authority)"
    Write-Output "  lock validity: $($activeSummary.LockValidity); live parity: $($activeSummary.LiveParity.Status); .system: $($activeSummary.SystemStatus); task overlay: $(if ($activeSummary.TaskOverlayHash) { $activeSummary.TaskOverlayHash } else { 'empty' })"
}
elseif ($null -eq $state) {
    Write-Output 'No environment activated.'
}
else {
    $activeName = [string] $state.Name
    $definitionDrift = $false
    $taskOverlayDrift = $false
    $activeOverlay = $null
    $activeLock = $null
    $activeParity = [pscustomobject]@{ Status = 'not-checked'; Mismatches = @(); SystemStatus = 'not-checked' }
    if (-not $definitionByName.ContainsKey($activeName)) {
        $definitionDrift = $true
    }
    else {
        $definitionDrift = $state.PSObject.Properties.Name -contains 'DefinitionHash' -and
            [string] $state.DefinitionHash -ne (Get-HarnessEnvDefinitionHash -Path $definitionByName[$activeName])
        $activeOverlay = Get-HarnessTaskSkillOverlayForEnvironment -RepoRoot $repo -BaseEnvName $activeName -Path $taskOverlayPath
        $taskOverlayDrift = $state.PSObject.Properties.Name -contains 'TaskOverlayHash' -and
            [string] $state.TaskOverlayHash -ne [string] $activeOverlay.Hash
        if ($state.PSObject.Properties.Name -notcontains 'TaskOverlayHash' -and $null -ne $activeOverlay.Hash) {
            $taskOverlayDrift = $true
        }
        $activeLock = $lockByName[$activeName]
        if ($null -ne $activeLock -and $null -ne $activeLock.Lock) {
            $activeParity = Get-HarnessEnvLockLiveParity -RepoRoot $repo -Lock ([System.Collections.IDictionary] $activeLock.Lock) -HomeRoot $HomeRoot
        }
        else {
            $activeParity = [pscustomobject]@{ Status = 'not-checked'; Mismatches = @('lock-not-valid'); SystemStatus = 'not-checked' }
        }
    }
    $lockValid = $null -ne $activeLock -and $activeLock.Valid
    $activeStatus = if (-not $definitionDrift -and -not $taskOverlayDrift -and $lockValid -and $activeParity.Status -eq 'pass') { 'active' } else { 'drift' }
    $suffix = if (-not $definitionByName.ContainsKey($activeName)) {
        ' (definition missing)'
    } elseif ($definitionDrift) {
        ' (definition changed since activation - re-run env activate)'
    } elseif ($taskOverlayDrift) {
        ' (task skill overlay changed since activation - re-run env task sync)'
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
        Source = 'legacy'
        LockValidity = if ($null -eq $activeLock) { 'not-checked' } elseif ($activeLock.Valid) { 'valid' } else { 'invalid' }
        DefinitionDrift = $definitionDrift
        TaskOverlayDrift = $taskOverlayDrift
        TaskOverlayHash = if ($null -eq $activeOverlay) { $null } else { $activeOverlay.Hash }
        LiveParity = [ordered] @{ Status = $activeParity.Status; Mismatches = @($activeParity.Mismatches) }
        SystemStatus = if ($activeParity.PSObject.Properties.Name -contains 'SystemStatus') { $activeParity.SystemStatus } else { 'not-checked' }
        LockHash = if ($null -eq $activeLock) { $null } else { $activeLock.LockHash }
        LockReasons = $activeLockReasons
    }
    Write-Output "Active environment: $activeName$suffix (local legacy state)"
    Write-Output "  lock validity: $($activeSummary.LockValidity); live parity: $($activeSummary.LiveParity.Status); .system: $($activeSummary.SystemStatus); task overlay: $(if ($activeSummary.TaskOverlayHash) { $activeSummary.TaskOverlayHash } else { 'empty' })"
}

# Project linkage: detection and reminder only, never an automatic activate.
$effectiveActiveName = if ($authorityActive) { [string] $authority.StateSummary.EnvironmentName }
elseif ($null -ne $state) { [string] $state.Name }
else { $null }
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
            elseif ($null -eq $effectiveActiveName) {
                $projectLinkage = 'inactive'
                Write-Output "Project requires env '$requiredEnv' - no environment activated. Run: agent-dotfiles.ps1 env activate $requiredEnv -DryRun"
            }
            elseif ($requiredEnv -ieq $effectiveActiveName) {
                $projectLinkage = 'matches-active'
                Write-Output "Project requires env '$requiredEnv' - matches active."
            }
            else {
                $projectLinkage = 'mismatch'
                Write-Output "Project requires env '$requiredEnv' - does not match active '$effectiveActiveName'. Run: agent-dotfiles.ps1 env activate $requiredEnv -DryRun"
            }
        }
    }
}

if ($JsonPath) {
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{
        SchemaVersion = 2
        GeneratedAtUtc = [DateTime]::UtcNow.ToString('o')
        Environments = @($statusRows)
        Active = $activeSummary
        ProjectLinkage = $projectLinkage
        Authority = $authority
    }
    Test-HarnessEnvAuthorityDocumentSemantics -Document $document
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
}

exit 0
