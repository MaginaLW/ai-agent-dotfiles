#requires -Version 7.0

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

# Skill-tree helpers shared by build-skills.ps1 and promote-skill.ps1.

function Get-SkillDirectories {
    param(
        [Parameter(Mandatory)] [string] $RootPath,
        [string[]] $ExcludeNames = @('.system')
    )

    if (-not (Test-Path -LiteralPath $RootPath)) {
        return @()
    }
    return @(Get-ChildItem -LiteralPath $RootPath -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Name -notin $ExcludeNames -and
            (Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md'))
        } | Sort-Object Name)
}

function Test-SameOrDescendant {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92, [char]47)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]47)
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

# Refuses a skill tree that is, or contains, a symlink, junction or other reparse point.
# Get-ChildItem -Recurse lists reparse entries without following them.
function Assert-SkillTreeNoReparsePoint {
    param([Parameter(Mandatory)] [string] $Root)
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (-not $rootItem.PSIsContainer -or ($rootItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
        throw "Skill tree root is not a plain directory: $Root"
    }
    foreach ($item in @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            throw "Skill tree contains a reparse point: $($item.FullName)"
        }
    }
}

# Copies a skill tree (hidden files and empty directories included) to a create-new destination.
function Copy-SkillTree {
    param([Parameter(Mandatory)] [string] $SourceRoot, [Parameter(Mandatory)] [string] $DestinationRoot)
    $source = [System.IO.Path]::GetFullPath($SourceRoot)
    $destination = [System.IO.Path]::GetFullPath($DestinationRoot)
    if ((Test-SameOrDescendant -Path $source -Root $destination) -or (Test-SameOrDescendant -Path $destination -Root $source)) {
        throw 'Skill tree source and destination must be disjoint.'
    }
    if (Test-Path -LiteralPath $destination) { throw "Skill tree destination must be create-new: $destination" }
    Assert-SkillTreeNoReparsePoint -Root $source
    Copy-Item -LiteralPath $source -Destination $destination -Recurse -Force
}
