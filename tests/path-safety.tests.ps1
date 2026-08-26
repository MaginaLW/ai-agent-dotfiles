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

    Write-Host '[held target metadata lease]'
    $heldMissing = Join-Path $existing 'held-missing/child/target'
    $heldLease = Open-SealedHeldTargetContextLease -Path $heldMissing
    try {
        $heldProjection = Get-SealedHeldTargetContextLease -Lease $heldLease
        $heldLegacy = Resolve-TargetContext -Path $heldMissing -Mode MetadataOnly
        Assert-TestCondition ([string]$heldProjection.TargetStatus -ceq 'MISSING' -and [string]$heldProjection.FilesystemCapabilityStatus -ceq 'UNPROBED' -and $null -eq $heldProjection.FilesystemCapabilityHash) 'held missing target remains metadata-only and explicitly UNPROBED'
        Assert-TestCondition ([string]$heldProjection.RequestedInitialRootContextHash -ceq [string]$heldLegacy.RequestedInitialRootContextHash) 'held target preserves the legacy metadata intent hash'
        Assert-TestCondition ([string]$heldProjection.HeldMetadataHash -cmatch '^[0-9a-f]{64}$') 'held target adds a domain-separated metadata hash'
        [IO.Directory]::CreateDirectory((Join-Path $existing 'held-missing')) | Out-Null
        Assert-PathSafetyThrows -Script { Assert-SealedHeldTargetContextLease -Lease $heldLease | Out-Null } -Pattern '^target-context-plan-stale:' -Message 'held missing target detects appearance of its first absent namespace entry'
    }
    finally { Close-SealedHeldTargetContextLease -Lease $heldLease }
    Assert-PathSafetyThrows -Script { Get-SealedHeldTargetContextLease -Lease $heldLease | Out-Null } -Pattern '^target-context-plan-stale:' -Message 'closed held target lease fails closed'

    Write-Host '[mutation filesystem preflight]'
    $mutation = Resolve-TargetContext -Path $missing -Mode MutationPreflight -ProbeRoot $probeRoot
    Assert-TestCondition ($mutation.FilesystemCapabilityStatus -eq 'SUPPORTED') 'local fixed NTFS mutation preflight is supported'
    Assert-TestCondition (-not [string]::IsNullOrWhiteSpace($mutation.FilesystemCapabilityHash)) 'mutation preflight binds a filesystem capability hash'
    Assert-TestCondition (@([System.IO.Directory]::EnumerateFileSystemEntries($probeRoot)).Count -eq 0) 'capability probe cleans its dedicated slot'
    Assert-TestCondition ($mutation.RequestedInitialRootContextHash -ceq $first.RequestedInitialRootContextHash) 'mutation preflight independently preserves metadata-only intent hash'

    Write-Host '[unsupported locations and capabilities]'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path 'relative-target' -Mode MetadataOnly } -Pattern 'absolute|fully-qualified|relative' -Message 'relative target paths are rejected before cwd-bound normalization'
    $cwdBeforeRootProbe = Join-Path $work 'cwd-before-root-probe'
    [System.IO.Directory]::CreateDirectory($cwdBeforeRootProbe) | Out-Null
    Push-Location $cwdBeforeRootProbe
    try {
        Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path ([System.IO.Path]::GetPathRoot($work)) -Mode MetadataOnly } -Pattern 'root|volume' -Message 'volume root target is rejected without degrading to a cwd-relative drive path'
    }
    finally { Pop-Location }
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

    $danglingOutside = Join-Path $work 'dangling-outside'
    [System.IO.Directory]::CreateDirectory($danglingOutside) | Out-Null
    $danglingJunction = Join-Path $existing 'dangling-junction'
    New-PathSafetyJunction -Path $danglingJunction -Target $danglingOutside | Out-Null
    [System.IO.Directory]::Delete($danglingOutside)
    $danglingMarker = Get-NoFollowRootEntryMarker -Path $danglingJunction
    Assert-TestCondition ([string]$danglingMarker.EntryType -ceq 'ReparsePoint') 'fixture remains a dangling reparse entry'
    Assert-PathSafetyThrows -Script { Resolve-TargetContext -Path (Join-Path $danglingJunction 'child') -Mode MetadataOnly } -Pattern 'reparse' -Message 'dangling reparse ancestor is rejected rather than classified MISSING'

    Write-Host 'path safety tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
