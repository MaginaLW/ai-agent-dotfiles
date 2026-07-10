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

.OUTPUTS
    Human-readable status lines plus warnings for invalid definitions. Exit 0.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $Name
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$definitionFiles = @(Get-HarnessEnvDefinitionFiles -RepoRoot $repo)

$envNames = [System.Collections.Generic.List[string]]::new()
$definitionByName = @{}
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
    $suffix = if ($definitionByName.ContainsKey($activeName)) { '' } else { ' (definition missing)' }
    Write-Output "Active environment: $activeName$suffix"
}

exit 0
