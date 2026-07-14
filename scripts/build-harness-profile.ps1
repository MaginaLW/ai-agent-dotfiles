#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Join-Path $PSScriptRoot '..'),
    [string] $ProjectRoot = (Get-Location).Path,
    [switch] $Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'harness-profile-common.ps1')

$GeneratorVersion = '1'

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Build
$repo = $plan.RepoRoot
$project = $plan.ProjectRoot
$generatedRoot = Resolve-HarnessGeneratedDirectory -ProjectRoot $project

if ($Clean -and (Test-Path -LiteralPath $generatedRoot)) {
    $resolvedGenerated = (Resolve-Path -LiteralPath $generatedRoot).Path
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not $resolvedGenerated.StartsWith($project.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "Refusing to clean generated directory outside ProjectRoot: $resolvedGenerated"
    }
    Remove-Item -LiteralPath $resolvedGenerated -Recurse -Force
    $plan = New-HarnessProfilePlan -RepoRoot $repo -ProjectRoot $project -Mode Build
}

New-Item -ItemType Directory -Path $generatedRoot -Force | Out-Null

$managedBlockGroups = @($plan.Targets | Where-Object { $_.Mode -eq 'ManagedBlock' } | Group-Object Target)
foreach ($group in $managedBlockGroups) {
    $outputName = if ($group.Name -ieq 'AGENTS.md') {
        'AGENTS.generated.md'
    }
    elseif ($group.Name -ieq 'CLAUDE.md') {
        'CLAUDE.generated.md'
    }
    else {
        ((Split-Path -Leaf $group.Name) -replace '\.md$', '') + '.generated.md'
    }
    $outputPath = Join-Path $generatedRoot $outputName
    Assert-HarnessGeneratedOutputPath -Path $outputPath -GeneratedRoot $generatedRoot

    $blocks = [System.Collections.Generic.List[string]]::new()
    foreach ($target in @($group.Group)) {
        $component = $plan.Components | Where-Object { $_.Id -eq $target.ComponentId } | Select-Object -First 1
        $contentPath = Get-HarnessComponentContentPath -Component $component -FileName 'content.md'
        $content = if ($contentPath) { (Get-Content -Raw -LiteralPath $contentPath).TrimEnd() } else { '' }
        $blockId = if ($target.Output.BlockId) { [string] $target.Output.BlockId } else { [string] $target.ComponentId }
        $blocks.Add("<!-- BEGIN AGENT-HARNESS: $blockId -->`n$content`n<!-- END AGENT-HARNESS: $blockId -->")
    }
    Write-HarnessTextFile -Path $outputPath -Content (($blocks.ToArray() -join "`n`n") + "`n")
}

$structuredGroups = @($plan.Targets | Where-Object { $_.Mode -eq 'StructuredMerge' } | Group-Object Target)
foreach ($group in $structuredGroups) {
    $merged = [ordered] @{}
    foreach ($target in @($group.Group)) {
        $component = $plan.Components | Where-Object { $_.Id -eq $target.ComponentId } | Select-Object -First 1
        $settingsPath = Get-HarnessComponentContentPath -Component $component -FileName 'settings.json'
        if (-not $settingsPath) {
            throw "StructuredMerge component '$($component.Id)' is missing settings.json."
        }
        $settings = Get-Content -Raw -LiteralPath $settingsPath | ConvertFrom-Json
        $merged = Merge-HarnessJsonObject -Base $merged -Overlay (ConvertTo-HarnessPlainObject -Value $settings)
    }

    $outputName = if ($group.Name -ieq '.claude/settings.json') {
        'claude-settings.generated.json'
    }
    else {
        ((Split-Path -Leaf $group.Name) -replace '\.json$', '') + '.generated.json'
    }
    $outputPath = Join-Path $generatedRoot $outputName
    Assert-HarnessGeneratedOutputPath -Path $outputPath -GeneratedRoot $generatedRoot
    Write-HarnessJsonFile -InputObject $merged -Path $outputPath
}

foreach ($target in @($plan.Targets | Where-Object { $_.Mode -eq 'DirectoryFiles' })) {
    $component = $plan.Components | Where-Object { $_.Id -eq $target.ComponentId } | Select-Object -First 1
    $sourceName = if ($target.Output.ContainsKey('Source') -and $target.Output.Source) { [string] $target.Output.Source } else { 'content.md' }
    $contentPath = Get-HarnessComponentContentPath -Component $component -FileName $sourceName
    if (-not $contentPath) {
        throw "DirectoryFiles component '$($component.Id)' is missing $sourceName."
    }
    $relativeTarget = ($target.Target -replace '\\', '/')
    $outputPath = Join-Path $generatedRoot (Join-Path 'files' ($relativeTarget -replace '/', [System.IO.Path]::DirectorySeparatorChar))
    Assert-HarnessGeneratedOutputPath -Path $outputPath -GeneratedRoot $generatedRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
    Copy-Item -LiteralPath $contentPath -Destination $outputPath -Force
}

foreach ($target in @($plan.Targets | Where-Object { $_.Mode -eq 'GeneratedOnly' })) {
    $component = $plan.Components | Where-Object { $_.Id -eq $target.ComponentId } | Select-Object -First 1
    $contentPath = Get-HarnessComponentContentPath -Component $component -FileName 'content.md'
    if (-not $contentPath) {
        throw "GeneratedOnly component '$($component.Id)' is missing content.md."
    }

    $targetRelative = $target.Target -replace '\\', '/'
    if (-not $targetRelative.StartsWith('.agent-harness/generated/', [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "GeneratedOnly target must be under .agent-harness/generated/: $($target.Target)"
    }
    $generatedRelative = $targetRelative.Substring('.agent-harness/generated/'.Length)
    $outputPath = Join-Path $generatedRoot ($generatedRelative -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    Assert-HarnessGeneratedOutputPath -Path $outputPath -GeneratedRoot $generatedRoot
    New-Item -ItemType Directory -Path (Split-Path -Parent $outputPath) -Force | Out-Null
    Copy-Item -LiteralPath $contentPath -Destination $outputPath -Force
}

$plan = New-HarnessProfilePlan -RepoRoot $repo -ProjectRoot $project -Mode Build
$generatedFilesBeforeMetadata = @(Get-ChildItem -LiteralPath $generatedRoot -File -Recurse -Force | Sort-Object FullName)
$planSummary = [ordered] @{
    mode = $plan.Mode
    profilePath = Get-HarnessRelativePath -Root $project -Path $plan.ProfilePath
    resolvedProfiles = @($plan.ResolvedProfiles | ForEach-Object {
        [ordered] @{
            name = $_.Name
            path = Get-HarnessRelativePath -Root $repo -Path $_.Path
        }
    })
    targetPlatforms = @($plan.TargetPlatforms)
    componentIds = @($plan.ComponentIds)
    components = @($plan.Components | ForEach-Object {
        [ordered] @{
            id = $_.Id
            kind = $_.Kind
            path = Get-HarnessRelativePath -Root $repo -Path $_.Directory
            targetPlatforms = @($_.Data.TargetPlatforms)
        }
    })
    targets = @($plan.Targets | ForEach-Object {
        [ordered] @{
            componentId = $_.ComponentId
            mode = $_.Mode
            target = $_.Target
            action = $_.Action
            output = $_.Output
        }
    })
    sources = @($plan.SourceFiles | ForEach-Object {
        $root = if ($_.Kind -eq 'ProjectProfile') { $project } else { $repo }
        [ordered] @{
            kind = $_.Kind
            componentId = if ($_.PSObject.Properties.Name -contains 'ComponentId') { $_.ComponentId } else { $null }
            name = if ($_.PSObject.Properties.Name -contains 'Name') { $_.Name } else { $null }
            path = Get-HarnessRelativePath -Root $root -Path $_.Path
            hash = $_.Hash
        }
    })
}

Write-HarnessJsonFile -InputObject $planSummary -Path (Join-Path $generatedRoot 'plan.json')

$generatedFilesForManifest = @(Get-ChildItem -LiteralPath $generatedRoot -File -Recurse -Force | Sort-Object FullName)
$manifest = [ordered] @{
    profilePath = Get-HarnessRelativePath -Root $project -Path $plan.ProfilePath
    resolvedProfiles = @($plan.ResolvedProfiles | ForEach-Object {
        [ordered] @{
            name = $_.Name
            path = Get-HarnessRelativePath -Root $repo -Path $_.Path
        }
    })
    componentIds = @($plan.ComponentIds)
    sources = @($plan.SourceFiles | ForEach-Object {
        $root = if ($_.Kind -eq 'ProjectProfile') { $project } else { $repo }
        [ordered] @{
            kind = $_.Kind
            componentId = if ($_.PSObject.Properties.Name -contains 'ComponentId') { $_.ComponentId } else { $null }
            name = if ($_.PSObject.Properties.Name -contains 'Name') { $_.Name } else { $null }
            path = Get-HarnessRelativePath -Root $root -Path $_.Path
            hash = $_.Hash
        }
    })
    generatedFiles = @($generatedFilesForManifest | ForEach-Object {
        [ordered] @{
            path = Get-HarnessRelativePath -Root $generatedRoot -Path $_.FullName
            hash = Get-HarnessFileHash -Path $_.FullName
        }
    })
    targetPlatforms = @($plan.TargetPlatforms)
    generatorVersion = $GeneratorVersion
    generatedAt = (Get-Date).ToUniversalTime().ToString('o')
}

Write-HarnessJsonFile -InputObject $manifest -Path (Join-Path $generatedRoot 'manifest.json')

$generatedFiles = @(Get-ChildItem -LiteralPath $generatedRoot -File -Recurse -Force | Sort-Object FullName)
try {
    Invoke-HarnessSecretScan -RepoRoot $repo
    Assert-NoHarnessMachinePrivatePaths -Paths (@($plan.SourceFiles | ForEach-Object { $_.Path }) + @($generatedFiles | ForEach-Object { $_.FullName }))
}
catch {
    if (Test-Path -LiteralPath $generatedRoot) {
        Remove-Item -LiteralPath $generatedRoot -Recurse -Force
    }
    throw
}

Write-Output 'Harness profile build complete'
Write-Output "Project root: $project"
Write-Output "Generated root: $generatedRoot"
Write-Output "Components: $(@($plan.ComponentIds).Count)"
Write-Output "Generated files: $(@($generatedFiles).Count)"
