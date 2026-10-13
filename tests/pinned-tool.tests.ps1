#requires -Version 7.0
# Failure-path tests for scripts/pinned-tool.ps1: lock-file validation and installed-cache
# verification, all offline. The download path needs the network and is exercised by
# bootstrap and CI instead. Fixture "executables" are .cmd scripts so the version probe runs.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $RepoRoot 'scripts/pinned-tool.ps1')
$work = Join-Path ([IO.Path]::GetTempPath()) ('pinned-tool-tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null

function New-LockObject {
    # A valid lock as an ordered hashtable; a $null override removes the key.
    param([hashtable] $Overrides = @{})
    $lock = [ordered]@{
        SchemaVersion          = 1
        ToolKind               = 'probe-tool'
        Version                = '1.2.3'
        AssetName              = 'probe-tool.zip'
        AssetUrl               = 'https://github.com/example/probe-tool/releases/download/v1.2.3/probe-tool.zip'
        AssetSha256            = ('a' * 64)
        ExecutableName         = 'probe-tool.cmd'
        ExecutableSha256       = ('b' * 64)
        VersionArguments       = @('--version')
        ExpectedVersionPattern = '^probe-tool 1\.2\.3$'
    }
    foreach ($key in $Overrides.Keys) {
        if ($null -eq $Overrides[$key]) { $lock.Remove($key) } else { $lock[$key] = $Overrides[$key] }
    }
    return $lock
}

function Write-LockFile {
    param([Parameter(Mandatory)] [object] $Lock, [Parameter(Mandatory)] [string] $Name)
    $path = Join-Path $work "$Name.json"
    [IO.File]::WriteAllText($path, ($Lock | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    return $path
}

function New-InstalledCache {
    # Builds the cache tree for the lock and returns the lock with real hashes filled in.
    param(
        [Parameter(Mandatory)] [string] $CacheRoot,
        [string] $ExecutableContent = "@echo off`r`necho probe-tool 1.2.3`r`n"
    )
    $lock = New-LockObject
    $archive = Join-Path $CacheRoot 'probe-tool/1.2.3/probe-tool.zip'
    New-Item -ItemType Directory -Path (Split-Path -Parent $archive) -Force | Out-Null
    [IO.File]::WriteAllBytes($archive, [byte[]](1..32))
    $executable = Join-Path $CacheRoot 'probe-tool/1.2.3/bin/probe-tool.cmd'
    New-Item -ItemType Directory -Path (Split-Path -Parent $executable) -Force | Out-Null
    [IO.File]::WriteAllText($executable, $ExecutableContent, [Text.UTF8Encoding]::new($false))
    $lock.AssetSha256 = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    $lock.ExecutableSha256 = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash.ToLowerInvariant()
    return $lock
}

function Assert-ThrowsWith {
    param([Parameter(Mandatory)] [scriptblock] $Body, [Parameter(Mandatory)] [string] $Pattern, [Parameter(Mandatory)] [string] $Message)
    $failed = $false
    $text = ''
    try { & $Body | Out-Null } catch { $failed = $true; $text = $_.Exception.Message }
    Assert-TestCondition ($failed -and ($text -match $Pattern)) "$Message (message: $text)"
}

try {
    Write-Host '[lock-file validation]'
    Assert-ThrowsWith { Read-PinnedToolLockFile -LockPath (Write-LockFile -Lock (New-LockObject -Overrides @{ ExecutableSha256 = $null }) -Name 'missing-field') } 'missing ExecutableSha256' 'a lock without ExecutableSha256 is rejected'
    Assert-ThrowsWith { Read-PinnedToolLockFile -LockPath (Write-LockFile -Lock (New-LockObject -Overrides @{ SchemaVersion = 99 }) -Name 'bad-schema') } 'Unsupported pinned tool lock version: 99' 'an unsupported lock schema is rejected'
    Assert-ThrowsWith { Read-PinnedToolLockFile -LockPath (Write-LockFile -Lock (New-LockObject -Overrides @{ AssetSha256 = 'not-hex' }) -Name 'bad-hash') } 'must be lowercase hexadecimal' 'a non-hexadecimal hash is rejected'
    Assert-ThrowsWith { Read-PinnedToolLockFile -LockPath (Write-LockFile -Lock (New-LockObject -Overrides @{ AssetUrl = 'https://example.com/download/probe-tool.zip' }) -Name 'bad-url') } 'official GitHub release asset URL' 'a non-GitHub-release asset URL is rejected'
    Assert-ThrowsWith { Read-PinnedToolLockFile -LockPath (Write-LockFile -Lock (New-LockObject -Overrides @{ AssetName = 'other.zip' }) -Name 'bad-name') } 'asset name does not match its URL' 'an asset name that differs from the URL is rejected'

    Write-Host '[installed-cache verification]'
    $cacheEmpty = Join-Path $work 'cache-empty'
    Assert-ThrowsWith { Get-PinnedToolExecutable -LockPath (Write-LockFile -Lock (New-LockObject) -Name 'not-installed') -CacheRoot $cacheEmpty } 'is not installed' 'an empty cache fails verification instead of passing silently'

    $cacheTampered = Join-Path $work 'cache-tampered'
    $tamperedLock = New-InstalledCache -CacheRoot $cacheTampered
    [IO.File]::WriteAllBytes((Join-Path $cacheTampered 'probe-tool/1.2.3/probe-tool.zip'), [byte[]](9..40))
    Assert-ThrowsWith { Get-PinnedToolExecutable -LockPath (Write-LockFile -Lock $tamperedLock -Name 'tampered-archive') -CacheRoot $cacheTampered } 'archive hash mismatch' 'a modified archive fails the hash gate'

    $cacheExe = Join-Path $work 'cache-tampered-exe'
    $exeLock = New-InstalledCache -CacheRoot $cacheExe
    [IO.File]::WriteAllText((Join-Path $cacheExe 'probe-tool/1.2.3/bin/probe-tool.cmd'), "@echo off`r`necho replaced`r`n", [Text.UTF8Encoding]::new($false))
    Assert-ThrowsWith { Get-PinnedToolExecutable -LockPath (Write-LockFile -Lock $exeLock -Name 'tampered-exe') -CacheRoot $cacheExe } 'executable hash mismatch' 'a modified executable fails the hash gate'

    Write-Host '[version probe]'
    $cacheGood = Join-Path $work 'cache-good'
    $goodLock = New-InstalledCache -CacheRoot $cacheGood
    $verified = Install-PinnedTool -LockPath (Write-LockFile -Lock $goodLock -Name 'good') -CacheRoot $cacheGood -VerifyOnly
    Assert-TestCondition ($verified.VersionOutput -match 'probe-tool 1\.2\.3') 'VerifyOnly returns the probed version on a matching install'
    Assert-TestCondition ($verified.Executable -like '*probe-tool*1.2.3*bin*probe-tool.cmd') 'the executable path follows the cache layout'

    $mismatchLock = New-InstalledCache -CacheRoot $cacheGood
    $mismatchLock.ExpectedVersionPattern = '^nothing-matches$'
    Assert-ThrowsWith { Get-PinnedToolExecutable -LockPath (Write-LockFile -Lock $mismatchLock -Name 'version-mismatch') -CacheRoot $cacheGood } 'version output did not match the lock' 'a version pattern mismatch fails verification'

    $cacheFailing = Join-Path $work 'cache-failing-probe'
    $failingLock = New-InstalledCache -CacheRoot $cacheFailing -ExecutableContent "@echo off`r`nexit /b 1`r`n"
    Assert-ThrowsWith { Get-PinnedToolExecutable -LockPath (Write-LockFile -Lock $failingLock -Name 'probe-fails') -CacheRoot $cacheFailing } 'version probe failed with exit code 1' 'a failing version probe fails verification'

    Write-Host 'pinned-tool tests: PASS'
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
