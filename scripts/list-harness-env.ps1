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

.PARAMETER JsonPath
    Optional machine-readable listing path. The JSON contains names, counts,
    validation status, and active environment only.

.OUTPUTS
    Human-readable listing. Exit code 0 when all definitions are valid, 1 when
    any definition is invalid.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $JsonPath
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
$rows = [System.Collections.Generic.List[object]]::new()
if ($definitionFiles.Count -eq 0) {
    Write-Output '  (none)'
}

foreach ($file in $definitionFiles) {
    $name = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $description = ''
    $profileName = ''
    $claudeCount = 0
    $codexCount = 0
    $reasonixCount = 0
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
        if ($definition.Skills.ContainsKey('Reasonix')) {
            $reasonixCount = @($definition.Skills.Reasonix).Count
        }
        $null = Resolve-HarnessEnvDefinition -RepoRoot $repo -Definition $definition
    }
    catch {
        $firstLine = ([string] $_.Exception.Message -split "`r?`n")[0]
        $status = "invalid: $firstLine"
        $anyInvalid = $true
    }

    $marker = if ($null -ne $activeName -and $name -ieq $activeName) { '*' } else { ' ' }
    $line = '{0} {1} profile={2} claude={3} codex={4} reasonix={5}  {6}' -f `
        $marker, $name.PadRight(12), $profileName.PadRight(10), $claudeCount, $codexCount, $reasonixCount, $status
    if (-not [string]::IsNullOrWhiteSpace($description)) {
        $line += "  $description"
    }
    Write-Output $line
    $rows.Add([pscustomobject] [ordered]@{
            Name = $name
            Description = $description
            Profile = $profileName
            ClaudeSkillCount = $claudeCount
            CodexSkillCount = $codexCount
            ReasonixSkillCount = $reasonixCount
            Status = if ($status -eq 'ok') { 'ok' } else { 'invalid' }
            StatusDetail = if ($status -eq 'ok') { $null } else { 'validation-failed' }
            Active = ($null -ne $activeName -and $name -ieq $activeName)
        })
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
    if ($JsonPath) {
        $parent = Split-Path -Parent $JsonPath
        if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
        $document = [ordered]@{ SchemaVersion = 1; GeneratedAtUtc = [DateTime]::UtcNow.ToString('o'); Environments = @($rows); ActiveName = $activeName; Result = 'FAIL' }
        [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
    }
    exit 1
}
if ($JsonPath) {
    $parent = Split-Path -Parent $JsonPath
    if ($parent) { New-Item -ItemType Directory -Force -Path $parent | Out-Null }
    $document = [ordered]@{ SchemaVersion = 1; GeneratedAtUtc = [DateTime]::UtcNow.ToString('o'); Environments = @($rows); ActiveName = $activeName; Result = 'PASS' }
    [System.IO.File]::WriteAllText($JsonPath, (ConvertTo-Json -InputObject $document -Depth 15) + "`n", [System.Text.UTF8Encoding]::new($false))
}
exit 0
