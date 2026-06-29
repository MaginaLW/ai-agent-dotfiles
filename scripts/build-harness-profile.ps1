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

function Get-RelativeHarnessPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    return ([System.IO.Path]::GetRelativePath($Root, $Path) -replace '\\', '/')
}

function Resolve-GeneratedHarnessDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $project = (Resolve-Path -LiteralPath $ProjectRoot).Path
    $generated = Normalize-HarnessCandidatePath -Candidate '.agent-harness/generated' -AllowedRoot $project -AllowMissingLeaf
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not $generated.StartsWith($project.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
        throw "Generated directory must resolve inside ProjectRoot: $generated"
    }
    return $generated
}

function Get-ComponentContentPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Component,
        [Parameter(Mandatory)] [string] $FileName
    )

    $path = Join-Path $Component.Directory $FileName
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        return $path
    }
    return $null
}

function ConvertTo-HarnessPlainObject {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered] @{}
        foreach ($key in $Value.Keys) {
            $result[[string] $key] = ConvertTo-HarnessPlainObject -Value $Value[$key]
        }
        return $result
    }
    if ($Value -is [pscustomobject]) {
        $result = [ordered] @{}
        foreach ($property in $Value.PSObject.Properties) {
            $result[$property.Name] = ConvertTo-HarnessPlainObject -Value $property.Value
        }
        return $result
    }
    if ($Value -is [array]) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) {
            $items.Add((ConvertTo-HarnessPlainObject -Value $item))
        }
        return ,$items.ToArray()
    }
    return $Value
}

function Merge-HarnessJsonObject {
    [CmdletBinding()]
    param(
        [AllowNull()] $Base,
        [AllowNull()] $Overlay
    )

    if ($null -eq $Base) { return $Overlay }
    if ($null -eq $Overlay) { return $Base }

    if ($Base -is [System.Collections.IDictionary] -and $Overlay -is [System.Collections.IDictionary]) {
        $merged = [ordered] @{}
        foreach ($key in $Base.Keys) {
            $merged[[string] $key] = $Base[$key]
        }
        foreach ($key in $Overlay.Keys) {
            if ($merged.Contains($key)) {
                $merged[[string] $key] = Merge-HarnessJsonObject -Base $merged[$key] -Overlay $Overlay[$key]
            }
            else {
                $merged[[string] $key] = $Overlay[$key]
            }
        }
        return $merged
    }

    if (($Base -is [array]) -or ($Overlay -is [array])) {
        $items = @(Select-HarnessStableUnique -Values (@($Base) + @($Overlay)))
        return ,$items
    }

    return $Overlay
}

function Write-HarnessJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $InputObject,
        [Parameter(Mandatory)] [string] $Path
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    $json = $InputObject | ConvertTo-Json -Depth 50
    Set-Content -LiteralPath $Path -Value $json -Encoding UTF8
}

function Write-HarnessTextFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [AllowNull()] [string] $Content
    )

    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Path $parent -Force | Out-Null
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -Encoding UTF8
}

function Assert-HarnessGeneratedOutputPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $GeneratedRoot
    )

    $root = (Resolve-Path -LiteralPath $GeneratedRoot).Path
    $resolved = if (Test-Path -LiteralPath $Path) {
        (Resolve-Path -LiteralPath $Path).Path
    }
    else {
        Normalize-HarnessCandidatePath -Candidate (Get-RelativeHarnessPath -Root $root -Path $Path) -AllowedRoot $root -AllowMissingLeaf
    }
    $comparison = [System.StringComparison]::OrdinalIgnoreCase
    if (-not ($resolved.Equals($root, $comparison) -or $resolved.StartsWith($root.TrimEnd('\', '/') + [System.IO.Path]::DirectorySeparatorChar, $comparison))) {
        throw "Build output path is outside generated directory: $Path"
    }
}

function Invoke-HarnessSecretScan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
    if (-not (Test-Path -LiteralPath $scan -PathType Leaf)) {
        throw "Missing secret scan script: $scan"
    }
    & $scan -RepoRoot $RepoRoot
    if ($LASTEXITCODE -ne 0) {
        throw "scripts/scan-secrets.ps1 failed with exit code $LASTEXITCODE."
    }
}

function Assert-NoHarnessMachinePrivatePaths {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Paths)

    $findings = @(Find-HarnessMachinePrivatePaths -Paths $Paths)
    if ($findings.Count -eq 0) { return }

    $details = $findings | ForEach-Object { "$($_.File):$($_.Line) $($_.Pattern)" }
    throw "Machine-private path scan failed: $($details -join '; ')"
}

$plan = New-HarnessProfilePlan -RepoRoot $RepoRoot -ProjectRoot $ProjectRoot -Mode Build
$repo = $plan.RepoRoot
$project = $plan.ProjectRoot
$generatedRoot = Resolve-GeneratedHarnessDirectory -ProjectRoot $project

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
        $contentPath = Get-ComponentContentPath -Component $component -FileName 'content.md'
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
        $settingsPath = Get-ComponentContentPath -Component $component -FileName 'settings.json'
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

foreach ($target in @($plan.Targets | Where-Object { $_.Mode -eq 'GeneratedOnly' })) {
    $component = $plan.Components | Where-Object { $_.Id -eq $target.ComponentId } | Select-Object -First 1
    $contentPath = Get-ComponentContentPath -Component $component -FileName 'content.md'
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
    profilePath = Get-RelativeHarnessPath -Root $project -Path $plan.ProfilePath
    resolvedProfiles = @($plan.ResolvedProfiles | ForEach-Object {
        [ordered] @{
            name = $_.Name
            path = Get-RelativeHarnessPath -Root $repo -Path $_.Path
        }
    })
    targetPlatforms = @($plan.TargetPlatforms)
    componentIds = @($plan.ComponentIds)
    components = @($plan.Components | ForEach-Object {
        [ordered] @{
            id = $_.Id
            kind = $_.Kind
            path = Get-RelativeHarnessPath -Root $repo -Path $_.Directory
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
            path = Get-RelativeHarnessPath -Root $root -Path $_.Path
            hash = $_.Hash
        }
    })
}

Write-HarnessJsonFile -InputObject $planSummary -Path (Join-Path $generatedRoot 'plan.json')

$generatedFilesForManifest = @(Get-ChildItem -LiteralPath $generatedRoot -File -Recurse -Force | Sort-Object FullName)
$manifest = [ordered] @{
    profilePath = Get-RelativeHarnessPath -Root $project -Path $plan.ProfilePath
    resolvedProfiles = @($plan.ResolvedProfiles | ForEach-Object {
        [ordered] @{
            name = $_.Name
            path = Get-RelativeHarnessPath -Root $repo -Path $_.Path
        }
    })
    componentIds = @($plan.ComponentIds)
    sources = @($plan.SourceFiles | ForEach-Object {
        $root = if ($_.Kind -eq 'ProjectProfile') { $project } else { $repo }
        [ordered] @{
            kind = $_.Kind
            componentId = if ($_.PSObject.Properties.Name -contains 'ComponentId') { $_.ComponentId } else { $null }
            name = if ($_.PSObject.Properties.Name -contains 'Name') { $_.Name } else { $null }
            path = Get-RelativeHarnessPath -Root $root -Path $_.Path
            hash = $_.Hash
        }
    })
    generatedFiles = @($generatedFilesForManifest | ForEach-Object {
        [ordered] @{
            path = Get-RelativeHarnessPath -Root $generatedRoot -Path $_.FullName
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
