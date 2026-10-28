#requires -Version 7.0
<#
.SYNOPSIS
    Read-only drift report between the repo copy and the live home copy of the
    config items managed by manifests/whitelist.psd1. Never writes anything.

.DESCRIPTION
    Each managed item (PushItems and PullItems) is reported as in-sync, differs,
    repo-only (a pull would deploy it) or home-only (a push would capture it).
    Items absent on both sides are omitted. ExcludedItems and CommonExcludedItems
    are skipped inside directories.
    The table also compares fields in differing Claude settings.json objects,
    without printing values. The JSON output remains the file-level report.

.PARAMETER RepoRoot
    Repository root. Defaults to the parent of this script's directory.

.PARAMETER HomeRoot
    Home directory. Defaults to $env:USERPROFILE. Claude is read from .claude
    and Codex from .codex.

.PARAMETER Platform
    One or more of Claude, Codex. Defaults to both.

.PARAMETER Json
    Emit the results as a JSON array instead of the table.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [ValidateSet('Claude', 'Codex')]
    [string[]] $Platform,
    [switch] $Json
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'config-common.ps1')

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
if (-not $Platform) { $Platform = @('Claude', 'Codex') }

function Get-ItemKind {
    param([Parameter(Mandatory)] [string] $Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 'absent' }
    if (Test-Path -LiteralPath $Path -PathType Container) { return 'dir' }
    return 'file'
}

function Get-DirFileMap {
    # Map of relative path ('/' separators) -> SHA256 for every non-excluded file under $Root.
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $map = @{}
    foreach ($file in (Get-ConfigFiles -Root $Root -Excluded $Excluded)) {
        $map[($file.Rel -replace '\\', '/')] = Get-FileHashHex -Path $file.FullName
    }
    return $map
}

function Compare-ConfigItem {
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $HomePath,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Excluded
    )
    $repoKind = Get-ItemKind -Path $RepoPath
    $homeKind = Get-ItemKind -Path $HomePath

    if ($repoKind -eq 'absent' -and $homeKind -eq 'absent') {
        return [pscustomobject] @{ Status = 'absent'; Detail = '' }
    }
    if ($homeKind -eq 'absent') {
        return [pscustomobject] @{ Status = 'repo-only'; Detail = 'would deploy on pull' }
    }
    if ($repoKind -eq 'absent') {
        return [pscustomobject] @{ Status = 'home-only'; Detail = 'untracked; would capture on push' }
    }
    if ($repoKind -ne $homeKind) {
        return [pscustomobject] @{ Status = 'differs'; Detail = "type mismatch ($repoKind vs $homeKind)" }
    }

    if ($repoKind -eq 'file') {
        if ((Get-FileHashHex -Path $RepoPath) -eq (Get-FileHashHex -Path $HomePath)) {
            return [pscustomobject] @{ Status = 'in-sync'; Detail = '' }
        }
        return [pscustomobject] @{ Status = 'differs'; Detail = 'content differs' }
    }

    $repoMap = Get-DirFileMap -Root $RepoPath -Excluded $Excluded
    $homeMap = Get-DirFileMap -Root $HomePath -Excluded $Excluded
    $onlyRepo = @($repoMap.Keys | Where-Object { -not $homeMap.ContainsKey($_) })
    $onlyHome = @($homeMap.Keys | Where-Object { -not $repoMap.ContainsKey($_) })
    $changed = @($repoMap.Keys | Where-Object { $homeMap.ContainsKey($_) -and $homeMap[$_] -ne $repoMap[$_] })
    if ($onlyRepo.Count -eq 0 -and $onlyHome.Count -eq 0 -and $changed.Count -eq 0) {
        return [pscustomobject] @{ Status = 'in-sync'; Detail = "$($repoMap.Count) files" }
    }
    $bits = @()
    if ($changed.Count) { $bits += "$($changed.Count) changed" }
    if ($onlyRepo.Count) { $bits += "$($onlyRepo.Count) repo-only" }
    if ($onlyHome.Count) { $bits += "$($onlyHome.Count) home-only" }
    return [pscustomobject] @{ Status = 'differs'; Detail = ($bits -join ', ') }
}

function Get-JsonObjectMap {
    param([System.Text.Json.JsonElement] $Element)
    $map = [System.Collections.Generic.Dictionary[string, System.Text.Json.JsonElement]]::new([StringComparer]::Ordinal)
    foreach ($property in $Element.EnumerateObject()) {
        if ($map.ContainsKey($property.Name)) { throw 'duplicate JSON object key' }
        $map.Add($property.Name, $property.Value)
    }
    return ,$map
}

function Assert-JsonUniqueObjectKeys {
    param([System.Text.Json.JsonElement] $Element)
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
        $map = Get-JsonObjectMap $Element
        foreach ($value in $map.Values) { Assert-JsonUniqueObjectKeys $value }
    }
    elseif ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Array) {
        foreach ($value in $Element.EnumerateArray()) { Assert-JsonUniqueObjectKeys $value }
    }
}

function Test-JsonEqual {
    param([System.Text.Json.JsonElement] $Left, [System.Text.Json.JsonElement] $Right)
    if ($Left.ValueKind -ne $Right.ValueKind) { return $false }
    switch ($Left.ValueKind.ToString()) {
        'Object' {
            $leftMap = Get-JsonObjectMap $Left
            $rightMap = Get-JsonObjectMap $Right
            if ($leftMap.Count -ne $rightMap.Count) { return $false }
            foreach ($key in $leftMap.Keys) {
                if (-not $rightMap.ContainsKey($key) -or -not (Test-JsonEqual $leftMap[$key] $rightMap[$key])) { return $false }
            }
            return $true
        }
        'Array' {
            if ($Left.GetArrayLength() -ne $Right.GetArrayLength()) { return $false }
            for ($i = 0; $i -lt $Left.GetArrayLength(); $i++) {
                if (-not (Test-JsonEqual $Left[$i] $Right[$i])) { return $false }
            }
            return $true
        }
        'String' { return $Left.GetString() -ceq $Right.GetString() }
        default { return $Left.GetRawText() -ceq $Right.GetRawText() }
    }
}

function Get-JsonFieldDifferences {
    param([System.Text.Json.JsonElement] $RepoJson, [System.Text.Json.JsonElement] $HomeJson, [string] $Path)
    $repoFields = Get-JsonObjectMap $RepoJson
    $homeFields = Get-JsonObjectMap $HomeJson
    $allKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($key in $repoFields.Keys) { [void] $allKeys.Add($key) }
    foreach ($key in $homeFields.Keys) { [void] $allKeys.Add($key) }
    $keys = [string[]] @($allKeys)
    [Array]::Sort($keys, [StringComparer]::Ordinal)
    foreach ($key in $keys) {
        # JSON Pointer escaping keeps keys containing '/' or '~' unambiguous.
        $field = $Path + '/' + $key.Replace('~', '~0').Replace('/', '~1')
        if (-not $repoFields.ContainsKey($key)) { [pscustomobject]@{ Kind = 'home-only'; Path = $field }; continue }
        if (-not $homeFields.ContainsKey($key)) { [pscustomobject]@{ Kind = 'repo-only'; Path = $field }; continue }
        $repoValue = $repoFields[$key]
        $homeValue = $homeFields[$key]
        if ($repoValue.ValueKind -ne $homeValue.ValueKind) { [pscustomobject]@{ Kind = 'type-changed'; Path = $field } }
        elseif ($repoValue.ValueKind -eq [System.Text.Json.JsonValueKind]::Object) {
            Get-JsonFieldDifferences $repoValue $homeValue $field
        }
        elseif (-not (Test-JsonEqual $repoValue $homeValue)) { [pscustomobject]@{ Kind = 'changed'; Path = $field } }
    }
}

function Show-ClaudeSettingsFieldDifferences {
    param([string] $RepoPath, [string] $HomePath)
    $repoDoc = $null
    $homeDoc = $null
    try {
        $repoDoc = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($RepoPath))
        $homeDoc = [System.Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($HomePath))
        if ($repoDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or $homeDoc.RootElement.ValueKind -ne [System.Text.Json.JsonValueKind]::Object) {
            Write-Host '  Field comparison unavailable: both JSON roots must be objects.' -ForegroundColor Yellow
            return
        }
        Assert-JsonUniqueObjectKeys $repoDoc.RootElement
        Assert-JsonUniqueObjectKeys $homeDoc.RootElement
        # Collect before printing so malformed or ambiguous nested objects never yield a partial report.
        $fields = @(Get-JsonFieldDifferences $repoDoc.RootElement $homeDoc.RootElement '')
        foreach ($field in $fields) {
            $path = ConvertTo-Json -InputObject $field.Path -Compress
            $suffix = if ($field.Kind -eq 'home-only') { ' (whole-file pull would remove this field)' } else { '' }
            Write-Host "  $($field.Kind) $path$suffix" -ForegroundColor Yellow
        }
        if ($fields.Count -eq 0) { Write-Host '  JSON fields match; file bytes differ.' -ForegroundColor DarkGray }
    }
    catch {
        # Parse errors can contain input snippets; do not print exception details.
        Write-Host '  Field comparison unavailable: invalid, unsupported, or ambiguous JSON.' -ForegroundColor Yellow
    }
    finally {
        if ($null -ne $repoDoc) { $repoDoc.Dispose() }
        if ($null -ne $homeDoc) { $homeDoc.Dispose() }
    }
}

$results = [System.Collections.Generic.List[object]]::new()
foreach ($target in (Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform $Platform -ItemKeys 'PushItems', 'PullItems')) {
    foreach ($item in $target.Items) {
        $cmp = Compare-ConfigItem `
            -RepoPath (Join-Path $target.RepoRoot $item) `
            -HomePath (Join-Path $target.HomeRoot $item) `
            -Excluded $target.Excluded
        if ($cmp.Status -eq 'absent') { continue }
        $results.Add([pscustomobject] @{
                Platform = $target.Name
                Item     = $item
                Status   = $cmp.Status
                Detail   = $cmp.Detail
            })
    }
}

if ($Json) {
    ConvertTo-Json -InputObject $results.ToArray() -Depth 5
    return
}

Write-Host "Config drift (repo <-> $HomeRoot) - read-only, no changes made." -ForegroundColor Cyan
Write-Host ''
if ($results.Count -eq 0) {
    Write-Host 'No managed config items present on either side.'
}
else {
    $colorFor = @{
        'in-sync'   = 'DarkGray'
        'differs'   = 'Yellow'
        'repo-only' = 'Green'
        'home-only' = 'Magenta'
    }
    foreach ($row in $results) {
        $label = '{0,-9} {1,-9} {2}' -f $row.Platform, $row.Status, $row.Item
        if ($row.Detail) { $label += "  ($($row.Detail))" }
        $color = if ($colorFor.ContainsKey($row.Status)) { $colorFor[$row.Status] } else { 'White' }
        Write-Host $label -ForegroundColor $color
        if ($row.Platform -eq 'Claude' -and $row.Item -eq 'settings.json' -and $row.Status -eq 'differs' -and $row.Detail -eq 'content differs') {
            $target = @(Get-ConfigTargets -RepoRoot $RepoRoot -HomeRoot $HomeRoot -Platform @('Claude') -ItemKeys 'PushItems', 'PullItems')[0]
            Show-ClaudeSettingsFieldDifferences -RepoPath (Join-Path $target.RepoRoot $row.Item) -HomePath (Join-Path $target.HomeRoot $row.Item)
        }
    }
}

Write-Host ''
$summary = $results | Group-Object Status | ForEach-Object { "$($_.Name)=$($_.Count)" }
Write-Host ("Summary: " + ($summary -join '  ')) -ForegroundColor Cyan
Write-Host 'Read-only inspection. Use config-pull or config-push (dry-run unless -Apply) to sync.' -ForegroundColor DarkGray
