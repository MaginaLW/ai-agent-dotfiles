#requires -Version 7.0
<#
.SYNOPSIS
    Builds a project's harness profile into <ProjectRoot>/.agent-harness/generated/ only.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $ProjectRoot = (Get-Location).Path,
    [switch] $Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Build
$repo = $plan.RepoRoot
$project = $plan.ProjectRoot
$generatedRoot = Join-Path $project '.agent-harness\generated'
if ($Clean -and (Test-Path -LiteralPath $generatedRoot)) { Remove-Item -LiteralPath $generatedRoot -Recurse -Force }
New-Item -ItemType Directory -Path $generatedRoot -Force | Out-Null

function Write-HarnessGeneratedText([string] $Name, [string] $Text) {
    Set-Content -LiteralPath (Join-Path $generatedRoot $Name) -Value $Text -Encoding UTF8
}
function Copy-HarnessGeneratedFile([string] $Source, [string] $Relative) {
    $destination = Join-Path $generatedRoot ($Relative -replace '/', '\')
    New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
    Copy-Item -LiteralPath $Source -Destination $destination -Force
}

foreach ($group in @($plan.Targets | Where-Object Mode -EQ 'ManagedBlock' | Group-Object Target)) {
    $name = if ($group.Name -ieq 'CLAUDE.md') { 'CLAUDE.generated.md' } else { 'AGENTS.generated.md' }
    $blocks = @(Get-HarnessManagedBlocks -Plan $plan -Targets @($group.Group))
    Write-HarnessGeneratedText $name ((@($blocks.Text) -join "`n`n") + "`n")
}
foreach ($group in @($plan.Targets | Where-Object Mode -EQ 'StructuredMerge' | Group-Object Target)) {
    $merged = Merge-HarnessSettings -Plan $plan -Base ([ordered] @{}) -Targets @($group.Group)
    Write-HarnessGeneratedText 'claude-settings.generated.json' ($merged | ConvertTo-Json -Depth 50)
}
foreach ($target in @($plan.Targets | Where-Object Mode -EQ 'DirectoryFiles')) {
    $component = Get-HarnessPlanComponent -Plan $plan -Target $target
    Copy-HarnessGeneratedFile (Get-HarnessComponentSource -Component $component -Output $target.Output) "files/$($target.Target)"
}
foreach ($target in @($plan.Targets | Where-Object Mode -EQ 'GeneratedOnly')) {
    $component = Get-HarnessPlanComponent -Plan $plan -Target $target
    Copy-HarnessGeneratedFile (Join-Path $component.Directory 'content.md') $target.Target.Substring('.agent-harness/generated/'.Length)
}

$profilePath = Get-HarnessRelativePath -Root $project -Path $plan.ProfilePath
$resolvedProfiles = @($plan.ResolvedProfiles | ForEach-Object { [ordered] @{ name = $_.Name; path = Get-HarnessRelativePath -Root $repo -Path $_.Path } })
$sources = @($plan.SourceFiles | ForEach-Object {
        [ordered] @{
            kind        = $_.Kind
            componentId = if ($_.PSObject.Properties.Name -contains 'ComponentId') { $_.ComponentId } else { $null }
            name        = if ($_.PSObject.Properties.Name -contains 'Name') { $_.Name } else { $null }
            path        = Get-HarnessRelativePath -Root $(if ($_.Kind -eq 'ProjectProfile') { $project } else { $repo }) -Path $_.Path
            hash        = $_.Hash
        }
    })

# Output keys are written sorted so plan.json is byte-stable across runs.
Write-HarnessGeneratedText 'plan.json' ([ordered] @{
        mode             = $plan.Mode
        profilePath      = $profilePath
        resolvedProfiles = $resolvedProfiles
        targetPlatforms  = @($plan.TargetPlatforms)
        componentIds     = @($plan.ComponentIds)
        components       = @($plan.Components | ForEach-Object {
                [ordered] @{ id = $_.Id; kind = $_.Kind; path = Get-HarnessRelativePath -Root $repo -Path $_.Directory; targetPlatforms = @($_.Data.TargetPlatforms) }
            })
        targets          = @($plan.Targets | ForEach-Object {
                $output = $_.Output
                $sortedOutput = [ordered] @{}
                foreach ($key in @($output.Keys | Sort-Object)) { $sortedOutput[$key] = $output[$key] }
                [ordered] @{
                    componentId = $_.ComponentId
                    mode        = $_.Mode
                    target      = $_.Target
                    action      = if (Test-Path -LiteralPath $_.FullPath) { 'inspect' } else { 'add' }
                    output      = $sortedOutput
                }
            })
        sources          = $sources
    } | ConvertTo-Json -Depth 50)

Write-HarnessGeneratedText 'manifest.json' ([ordered] @{
        profilePath      = $profilePath
        resolvedProfiles = $resolvedProfiles
        componentIds     = @($plan.ComponentIds)
        sources          = $sources
        generatedFiles   = @(Get-ChildItem -LiteralPath $generatedRoot -File -Recurse -Force | Sort-Object FullName | ForEach-Object {
                [ordered] @{ path = Get-HarnessRelativePath -Root $generatedRoot -Path $_.FullName; hash = Get-HarnessFileHash -Path $_.FullName }
            })
        targetPlatforms  = @($plan.TargetPlatforms)
        generatorVersion = '1'
        generatedAt      = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 50)

$generatedFiles = @(Get-ChildItem -LiteralPath $generatedRoot -File -Recurse -Force | Sort-Object FullName)
try {
    Invoke-HarnessSecretScan -RepoRoot $repo
    Assert-HarnessNoPrivatePaths -Paths (@($plan.SourceFiles | ForEach-Object Path) + @($generatedFiles | ForEach-Object FullName))
}
catch {
    Remove-Item -LiteralPath $generatedRoot -Recurse -Force -ErrorAction SilentlyContinue
    throw
}

Write-Output 'Harness profile build complete'
Write-Output "Project root: $project"
Write-Output "Generated root: $generatedRoot"
Write-Output "Components: $(@($plan.ComponentIds).Count)"
Write-Output "Generated files: $($generatedFiles.Count)"
