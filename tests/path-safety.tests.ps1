#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $PSScriptRoot 'helpers/path-safety-fixtures.ps1')
. (Join-Path $RepoRoot 'scripts/target-context-common.ps1')

$work = New-PathSafetyFixtureRoot
try {
    $existing = Join-Path $work 'existing'
    $probeRoot = Join-Path $work 'probe'
    [System.IO.Directory]::CreateDirectory($existing) | Out-Null
    [System.IO.Directory]::CreateDirectory($probeRoot) | Out-Null
    $missing = Join-Path $existing 'missing/child/target'

    Write-Host '[metadata-only target context]'
    $before = @([System.IO.Directory]::EnumerateFileSystemEntries($work, '*', [System.IO.SearchOption]::AllDirectories))
    $first = Resolve-TargetContext -Path $missing -Mode MetadataOnly
    $second = Resolve-TargetContext -Path $missing -Mode MetadataOnly
    $after = @([System.IO.Directory]::EnumerateFileSystemEntries($work, '*', [System.IO.SearchOption]::AllDirectories))
    Assert-TestCondition ($first.TargetStatus -eq 'MISSING') 'absent target is represented as MISSING'
    Assert-TestCondition ($first.FilesystemCapabilityStatus -eq 'UNPROBED') 'metadata-only context is explicitly UNPROBED'
    Assert-TestCondition ($first.RequestedInitialRootContextHash -ceq $second.RequestedInitialRootContextHash) 'metadata-only hash is stable across repeated resolution'
    Assert-TestCondition (@(Compare-Object $before $after).Count -eq 0) 'metadata-only resolution performs zero filesystem writes'
    Assert-TestCondition ($first.DeepestExistingParentPath -ceq [System.IO.Path]::GetFullPath($existing)) 'absent context binds the deepest existing parent'
    Assert-TestCondition ((@($first.MissingRemainder) -join '/') -ceq 'missing/child/target') 'absent context binds the normalized missing remainder'

    $caseVariant = Resolve-TargetContext -Path $missing.ToUpperInvariant() -Mode MetadataOnly
    Assert-TestCondition ($caseVariant.LocationKey -ceq $first.LocationKey) 'location key is case-insensitive and separator-stable'

    Write-Host '[mutation filesystem preflight]'
    $mutation = Resolve-TargetContext -Path $missing -Mode MutationPreflight -ProbeRoot $probeRoot
    Assert-TestCondition ($mutation.FilesystemCapabilityStatus -eq 'SUPPORTED') 'local fixed NTFS mutation preflight is supported'
    Assert-TestCondition (-not [string]::IsNullOrWhiteSpace($mutation.FilesystemCapabilityHash)) 'mutation preflight binds a filesystem capability hash'
    Assert-TestCondition (@([System.IO.Directory]::EnumerateFileSystemEntries($probeRoot)).Count -eq 0) 'capability probe cleans its dedicated slot'
    Assert-TestCondition ($mutation.RequestedInitialRootContextHash -ceq $first.RequestedInitialRootContextHash) 'mutation preflight independently preserves metadata-only intent hash'

    Write-Host '[unsupported locations and capabilities]'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path ([System.IO.Path]::GetPathRoot($work)) -Mode MetadataOnly } -Pattern 'root|volume' -Message 'volume root target is rejected'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path $existing -Mode MetadataOnly -HomeRoot $existing } -Pattern 'HomeRoot' -Message 'HomeRoot itself is rejected'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $existing '.system/child') -Mode MetadataOnly } -Pattern '\.system' -Message '.system target is rejected'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $existing 'child') -Mode MetadataOnly -ForbiddenRoots @($existing) } -Pattern 'overlap' -Message 'source/target ancestor overlap is rejected'
    foreach ($case in @(
        @{ DriveType='Network'; FileSystemType='NTFS' },
        @{ DriveType='Removable'; FileSystemType='NTFS' },
        @{ DriveType='Fixed'; FileSystemType='ReFS' },
        @{ DriveType='Fixed'; FileSystemType='FAT32' },
        @{ DriveType='Unknown'; FileSystemType='UNKNOWN' }
    )) {
        Assert-PathSafetyThrows -Script { Assert-SupportedTargetFilesystem -DriveType $case.DriveType -FileSystemType $case.FileSystemType } -Pattern 'unsupported' -Message "unsupported filesystem is rejected: $($case.DriveType)/$($case.FileSystemType)"
    }

    $outside = Join-Path $work 'outside'
    [System.IO.Directory]::CreateDirectory($outside) | Out-Null
    $junction = Join-Path $existing 'junction'
    New-PathSafetyJunction -Path $junction -Target $outside | Out-Null
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $junction 'child') -Mode MetadataOnly } -Pattern 'reparse' -Message 'reparse ancestor is rejected without resolution'

    Write-Host 'path safety tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
