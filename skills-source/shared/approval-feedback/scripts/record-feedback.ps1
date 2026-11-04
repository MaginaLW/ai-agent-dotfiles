#requires -Version 7.0
<#
.SYNOPSIS
    Records one source-attributed score in an explicitly authorized private ledger.
.DESCRIPTION
    EntryPath is a UTF-8 JSON object containing Task, Request, Project, Client, Scope,
    Score (integer 0..3), Permission (Approved/Denied/Unspecified), and Source.
    Source identifies the original submitted answer, including the question index.
    This helper does not grant permission, classify independent tasks, or count thresholds.
    Exit 0 means Recorded or Duplicate with readback; exit 1 means Pending with a fixed
    failure Stage, never private paths or exception text. A busy lock
    is not retried. All writers must use this helper; the adjacent .lock file is retained.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $EntryPath,
    [Parameter(Mandatory)] [string] $LedgerPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$lock = $null
$temporary = $null
$entryId = $null
$reason = 'InvalidInput'
$stage = 'ValidateInput'
$result = $null
$utf8 = [Text.UTF8Encoding]::new($false, $true)

function Assert-PlainPath([string] $Path) {
    $current = $Path
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Linked path is not supported.' }
        }
        $current = Split-Path -Parent $current
    }
}

try {
    foreach ($path in @($EntryPath, $LedgerPath)) {
        $stage = if ($path -eq $EntryPath) { 'ValidateInput' } else { 'ValidateStoragePath' }
        if (-not [IO.Path]::IsPathFullyQualified($path)) { throw 'Explicit absolute paths are required.' }
        Assert-PlainPath $path
    }
    $stage = 'ValidateInput'
    $EntryPath = [IO.Path]::GetFullPath($EntryPath)
    $LedgerPath = [IO.Path]::GetFullPath($LedgerPath)
    if ($EntryPath -eq $LedgerPath -or $EntryPath -eq "$LedgerPath.lock") { throw 'Input and storage must differ.' }
    if ((Get-Item -LiteralPath $EntryPath).Length -gt 65536) { throw 'Input is too large.' }
    $inputEntry = $utf8.GetString([IO.File]::ReadAllBytes($EntryPath)).TrimStart([char]0xfeff) | ConvertFrom-Json -AsHashtable
    $fields = @('Task', 'Request', 'Project', 'Client', 'Scope', 'Score', 'Permission', 'Source')
    if ($inputEntry -isnot [System.Collections.IDictionary] -or $inputEntry.Count -ne $fields.Count) {
        throw 'Expected exactly the documented fields.'
    }
    $entry = [ordered]@{}
    foreach ($field in $fields) {
        if (-not $inputEntry.ContainsKey($field)) { throw 'Missing field.' }
        $value = $inputEntry[$field]
        if ($field -eq 'Score') {
            if (($value -isnot [long] -and $value -isnot [int]) -or $value -lt 0 -or $value -gt 3) {
                throw 'Score must be an integer from 0 through 3.'
            }
        }
        elseif ($value -isnot [string] -or [string]::IsNullOrWhiteSpace($value) -or
            $value.Length -gt 2048 -or $value -match '[\x00-\x1f\x7f]') { throw 'Expected a short single-line string.' }
        $entry[$field] = $value
    }
    if ($entry.Permission -cnotin @('Approved', 'Denied', 'Unspecified')) { throw 'Unknown permission label.' }
    # The same answer keeps its identity across short-ID changes and retransmission.
    $identity = ConvertTo-Json -InputObject @($entry.Client, $entry.Task, $entry.Source) -Compress
    $hasher = [Security.Cryptography.SHA256]::Create()
    try { $entryId = [BitConverter]::ToString($hasher.ComputeHash($utf8.GetBytes($identity))).Replace('-', '').ToLowerInvariant() }
    finally { $hasher.Dispose() }
    $json = ConvertTo-Json -InputObject $entry -Depth 3 -EscapeHandling EscapeHtml
    $marker = "<!-- feedback-entry: $entryId -->"
    $block = $marker + "`n" + '```json' + "`n" + $json + "`n" + '```' + "`n<!-- /feedback-entry: $entryId -->"

    $reason = 'StorageFailure'
    $stage = 'PrepareStorage'
    $parent = Split-Path -Parent $LedgerPath
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $stage = 'AcquireLock'
    Assert-PlainPath "$LedgerPath.lock"
    try { $lock = [IO.File]::Open("$LedgerPath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch {
        $failure = $_.Exception.GetBaseException()
        if ($failure -is [IO.IOException] -and ($failure.HResult -band 0xffff) -in @(32, 33)) { $reason = 'Busy' }
        throw
    }
    $stage = 'ReadLedger'
    Assert-PlainPath $LedgerPath
    $original = if (Test-Path -LiteralPath $LedgerPath) {
        if ((Get-Item -LiteralPath $LedgerPath).Length -gt 4194304) { throw 'Ledger is too large.' }
        $utf8.GetString([IO.File]::ReadAllBytes($LedgerPath))
    }
    else { "# Approval feedback (private records; no permission granted)`n" }

    if ($original.Contains($marker)) {
        $reason = 'Conflict'
        # Do not silently replace a score or treat an incomplete write as successful.
        $pattern = '(?m)^' + [regex]::Escape($block) + '(?=\r?$|\n)'
        if ([regex]::Matches($original, [regex]::Escape($marker)).Count -ne 1 -or $original -cnotmatch $pattern) {
            throw 'Existing source has different or incomplete content.'
        }
        $result = @{ Status = 'Duplicate'; EntryId = $entryId }
    }
    else {
        $stage = 'WriteTemporary'
        $updated = $original + "`n`n" + $block + "`n"
        $temporary = Join-Path $parent ('.' + [IO.Path]::GetFileName($LedgerPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
        $bytes = $utf8.GetBytes($updated)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) }
        finally { $stream.Dispose() }
        $stage = 'PublishLedger'
        # Match deploy-skills: PowerShell converts $null to an empty backup path.
        if (Test-Path -LiteralPath $LedgerPath) { [IO.File]::Replace($temporary, $LedgerPath, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $LedgerPath) }
        $temporary = $null
        $stage = 'ReadBack'
        if ($utf8.GetString([IO.File]::ReadAllBytes($LedgerPath)) -cne $updated) { throw 'Readback differs.' }
        $result = @{ Status = 'Recorded'; EntryId = $entryId }
    }
}
catch {
    # Never print entry contents, source paths or exception messages from private storage.
    $result = @{ Status = 'Pending'; EntryId = $entryId; Reason = $reason; Stage = $stage }
}
finally {
    try { if ($temporary -and [IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
    catch { $result = @{ Status = 'Pending'; EntryId = $entryId; Reason = 'CleanupFailure'; Stage = 'Cleanup' } }
    finally { if ($lock) { $lock.Dispose() } }
}
$result | ConvertTo-Json -Compress
if ($result.Status -eq 'Pending') { exit 1 }
