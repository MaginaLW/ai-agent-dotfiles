#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/scan-input-common.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-scan-input-$([Guid]::NewGuid().ToString('N'))"
$fixtureRepo = Join-Path $work 'repo'
$outputRoot = Join-Path $work 'scan-input'
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo '.reasonix') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'src') -Force | Out-Null

try {
    & git -C $fixtureRepo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'src/ordinary.txt'), 'ordinary content')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo '.reasonix/adjacent-visible.txt'), 'adjacent content')
    foreach ($leaf in Get-ProtectedReasonixRelativePaths) {
        $path = Join-Path $fixtureRepo $leaf
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllText($path, 'protected sentinel content')
    }
    & git -C $fixtureRepo add -- 'src/ordinary.txt' '.reasonix/adjacent-visible.txt'
    if ($LASTEXITCODE -ne 0) { throw 'fixture git add failed' }

    $result = New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $outputRoot
    Assert ((Test-Path -LiteralPath (Join-Path $outputRoot 'src/ordinary.txt') -PathType Leaf)) 'ordinary tracked file is materialized'
    Assert ((Test-Path -LiteralPath (Join-Path $outputRoot '.reasonix/adjacent-visible.txt') -PathType Leaf)) 'adjacent non-protected Reasonix file remains visible'
    foreach ($leaf in Get-ProtectedReasonixRelativePaths) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $outputRoot $leaf))) "protected path is absent: $leaf"
        Assert ($leaf -notin @($result.Files.RelativePath)) "manifest excludes protected path: $leaf"
    }
    Assert ($result.Files.Count -eq 2) 'manifest contains the exact two allowed files'
    Assert (-not [string]::IsNullOrWhiteSpace($result.SourcePolicyHash)) 'manifest returns a source policy hash'

    $secondDestination = Join-Path $work 'scan-input-existing'
    New-Item -ItemType Directory -Path $secondDestination | Out-Null
    $failed = $false
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $secondDestination | Out-Null }
    catch { $failed = $_.Exception.Message -match 'create-new' }
    Assert $failed 'existing destination is rejected'

    Write-Host '[alias, reparse, and ADS rejection]'
    $hardlinkPath = Join-Path $fixtureRepo 'src/protected-hardlink.txt'
    $protectedTarget = Join-Path $fixtureRepo (Get-ProtectedReasonixRelativePaths | Select-Object -First 1)
    New-Item -ItemType HardLink -Path $hardlinkPath -Target $protectedTarget | Out-Null
    $hardlinkRejected = $false
    $hardlinkDestination = Join-Path $work 'scan-input-hardlink'
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $hardlinkDestination | Out-Null }
    catch { $hardlinkRejected = $_.Exception.Message -match 'hard link|aliases a protected' }
    Assert $hardlinkRejected 'hardlink alias to protected content is rejected before copy'
    Assert (-not (Test-Path -LiteralPath $hardlinkDestination)) 'hardlink rejection creates no scan root'
    Remove-Item -LiteralPath $hardlinkPath -Force

    $outsideRoot = Join-Path $work 'outside'
    New-Item -ItemType Directory -Path $outsideRoot | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outsideRoot 'outside.txt'), 'outside sentinel')
    $junctionPath = Join-Path $fixtureRepo 'outside-junction'
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null
    $junctionRejected = $false
    $junctionDestination = Join-Path $work 'scan-input-junction'
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $junctionDestination | Out-Null }
    catch { $junctionRejected = $_.Exception.Message -match 'reparse' }
    Assert $junctionRejected 'junction to outside content is rejected without traversal'
    Assert (-not (Test-Path -LiteralPath $junctionDestination)) 'junction rejection creates no scan root'
    Remove-Item -LiteralPath $junctionPath -Force

    $ordinaryPath = Join-Path $fixtureRepo 'src/ordinary.txt'
    Set-Content -LiteralPath $ordinaryPath -Stream 'phase0-sentinel' -Value 'named stream content' -NoNewline
    $adsRejected = $false
    $adsDestination = Join-Path $work 'scan-input-ads'
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $adsDestination | Out-Null }
    catch { $adsRejected = $_.Exception.Message -match 'alternate data stream' }
    Assert $adsRejected 'named alternate data stream is rejected before copy'
    Assert (-not (Test-Path -LiteralPath $adsDestination)) 'ADS rejection creates no scan root'
    Remove-Item -LiteralPath $ordinaryPath -Stream 'phase0-sentinel'

    Write-Host 'scan input boundary tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
