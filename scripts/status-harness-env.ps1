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
    [string] $ProjectRoot,
    [string] $JsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$definitionFiles = @(Get-HarnessEnvDefinitionFiles -RepoRoot $repo)

$envNames = [System.Collections.Generic.List[string]]::new()
$definitionByName = @{}
$statusRows = [System.Collections.Generic.List[object]]::new()
$activeSummary = [ordered] @{ Name = $null; Status = 'none' }
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
    if (Test-Path -LiteralPath $stagingPath -PathType Container) {
        $stagingStatus = 'stale'
        $lockPath = Join-Path $stagingPath 'env.lock.json'
        if ((Test-Path -LiteralPath $lockPath -PathType Leaf) -and $null -ne $definitionPath) {
            try {
                $lock = Get-Content -Raw -LiteralPath $lockPath | ConvertFrom-Json
                if ($null -ne $lock -and
                    $lock.PSObject.Properties.Name -contains 'DefinitionHash' -and
                    [string] $lock.DefinitionHash -eq (Get-HarnessEnvDefinitionHash -Path $definitionPath)) {
                    $stagingStatus = 'built'
                }
            }
            catch {
                $stagingStatus = 'stale'
            }
        }
    }

    $statusRows.Add([pscustomobject] [ordered] @{
        Name = $envName
        DefinitionStatus = if ($definitionStatus -eq 'valid') { 'valid' } else { 'invalid' }
        StagingStatus = $stagingStatus
    })
    Write-Output ('  {0} definition={1}  staging={2}' -f $envName.PadRight(12), $definitionStatus, $stagingStatus)
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
    $suffix = if (-not $definitionByName.ContainsKey($activeName)) {
        ' (definition missing)'
    }
    elseif ($state.PSObject.Properties.Name -contains 'DefinitionHash' -and
        [string] $state.DefinitionHash -ne (Get-HarnessEnvDefinitionHash -Path $definitionByName[$activeName])) {
        ' (definition changed since activation - re-run env activate)'
    }
    else {
        ''
    }
    $activeSummary = [ordered] @{ Name = $activeName; Status = if ($suffix) { 'drift' } else { 'active' } }
    Write-Output "Active environment: $activeName$suffix"
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
