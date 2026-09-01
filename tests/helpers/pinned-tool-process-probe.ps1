#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RepoRoot,
    [Parameter(Mandatory)] [string] $StateRoot,
    [Parameter(Mandatory)] [string] $OutcomePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')

$pwsh = @(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
$parentHandles = $null
$executableHandle = $null
$lease = $null
try {
    $parentHandlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
    Open-SafeDirectoryContainmentChain -Path (Split-Path -Parent $pwsh) -OwnershipReceiver $parentHandlesReceiver
    $parentHandles = $parentHandlesReceiver.GetDeliveredExact()
    $executableHandle = [AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile(
        $parentHandles[$parentHandles.Count - 1],
        [System.IO.Path]::GetFileName($pwsh)
    )
    $lease = [pscustomobject][ordered]@{
        Lock = [ordered]@{
            ToolKind = 'pipe-holder-fixture'
            VersionArguments = @(
                '-NoProfile',
                '-File',
                (Join-Path $RepoRoot 'tests/helpers/pinned-tool-pipe-holder-parent.ps1'),
                '-StateRoot',
                $StateRoot
            )
            ExpectedVersionPattern = '.*'
        }
        Paths = [pscustomobject]@{ Executable = $pwsh }
        LockCapture = $null
        LockParentHandles = $null
        ArchiveHandle = $null
        ArchiveParentHandles = $null
        ExecutableHandle = $executableHandle
        ExecutableParentHandles = $parentHandles
        ExecutableSha256 = [string] $executableHandle.ReadResult.Sha256
        ExecutableIdentity = [string] $executableHandle.ReadResult.Identity
        VersionOutput = $null
        Closed = $false
    }
    $executableHandle = $null
    $parentHandles = $null

    try {
        $result = Test-PinnedToolVersion -ToolLease $lease
        [System.IO.File]::WriteAllText($OutcomePath, "returned`n$result")
    }
    catch {
        [System.IO.File]::WriteAllText($OutcomePath, "threw`n$($_.Exception.Message)")
    }
}
finally {
    if ($lease) { Close-PinnedToolLease -ToolLease $lease }
    if ($executableHandle) { $executableHandle.Dispose() }
    if ($parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
}
