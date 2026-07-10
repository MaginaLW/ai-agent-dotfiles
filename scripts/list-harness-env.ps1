#requires -Version 7.0
<#
.SYNOPSIS
    Read-only listing of harness environment definitions (harness-source/envs/*.psd1).

.DESCRIPTION
    Enumerates every env definition, validates each one (schema, profile chain,
    managed-skill membership), and prints one line per env with its name,
    Description, Profile, per-platform skill counts, and validation result.
    Validation failures are caught per env so one bad definition does not abort
    the listing.

    The active environment (state/current-env.json, read via Read-HarnessEnvState)
    is marked with a leading '*'. When no state file exists the listing ends with
    'No environment activated.'

    This script never writes anything: no staging, no state, no home files.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.OUTPUTS
    Human-readable listing. Exit code 0 when all definitions are valid, 1 when
    any definition is invalid.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-env-common.ps1')

$repo = Resolve-HarnessRepoRoot -RepoRoot $RepoRoot
$definitionFiles = @(Get-HarnessEnvDefinitionFiles -RepoRoot $repo)
$state = Read-HarnessEnvState -RepoRoot $repo
$activeName = if ($null -ne $state) { [string] $state.Name } else { $null }

Write-Output 'Harness environments (harness-source/envs):'

$anyInvalid = $false
if ($definitionFiles.Count -eq 0) {
    Write-Output '  (none)'
}

foreach ($file in $definitionFiles) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $description = ''
    $profileName = ''
    $claudeCount = 0
    $codexCount = 0
    $status = 'ok'

    try {
        $definition = Read-HarnessEnvDefinition -Path $file.FullName
        if ($definition.ContainsKey('Description')) {
            $description = [string] $definition.Description
        }
        $profileName = [string] $definition.Profile
        if ($definition.Skills.ContainsKey('Claude')) {
            $claudeCount = @($definition.Skills.Claude).Count
        }
        if ($definition.Skills.ContainsKey('Codex')) {
            $codexCount = @($definition.Skills.Codex).Count
        }
        $null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $definition
    }
    catch {
        $firstLine = ([string] $_.Exception.Message -split "`r?`n")[0]
        $status = "invalid: $firstLine"
        $anyInvalid = $true
    }

    $marker = if ($null -ne $activeName -and $name -ieq $activeName) { '*' } else { ' ' }
    $line = '{0} {1} profile={2} claude={3} codex={4}  {5}' -f `
        $marker, $name.PadRight(12), $profileName.PadRight(10), $claudeCount, $codexCount, $status
    if (-not [string]::IsNullOrWhiteSpace($description)) {
        $line += "  $description"
    }
    Write-Output $line
}

if ($null -eq $state) {
    Write-Output ''
    Write-Output 'No environment activated.'
}
else {
    Write-Output ''
    Write-Output "Active environment: $activeName"
}

if ($anyInvalid) {
    exit 1
}
exit 0
