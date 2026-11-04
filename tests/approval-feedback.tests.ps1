#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
$recorder = Join-Path $RepoRoot 'skills-source/shared/approval-feedback/scripts/record-feedback.ps1'
$work = Join-Path $RepoRoot ('tmp/tests/approval-feedback/' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
$ledger = Join-Path $work 'private/approval-feedback.md'

function New-Entry([string] $Name, [int] $Score = 1, [string] $Permission = 'Approved') {
    $path = Join-Path $work "$Name.json"
    $data = [ordered]@{
        Task = 'task-one'; Request = $Name; Project = 'fixture'; Client = 'Codex'
        Scope = '同一任务内的固定范围'; Score = $Score; Permission = $Permission
        Source = "chat-one/call-$Name/question-0/answer"
    }
    Set-TestFile $path ($data | ConvertTo-Json)
    return $path
}
function Invoke-Record([string] $InputPath, [string] $Destination = $ledger) {
    $r = Invoke-TestProcess -ScriptPath $recorder -Arguments @('-EntryPath', $InputPath, '-LedgerPath', $Destination)
    return @{ Code = $r.Code; Result = ($r.Out | ConvertFrom-Json) }
}
function Get-Records([string] $Path = $ledger) {
    $text = [IO.File]::ReadAllText($Path)
    return @([regex]::Matches($text, '(?ms)^<!-- feedback-entry: [a-f0-9]{64} -->\r?\n```json\r?\n(.*?)\r?\n```\r?\n<!-- /feedback-entry: [a-f0-9]{64} -->') | ForEach-Object {
        $_.Groups[1].Value | ConvertFrom-Json
    })
}

Write-Host '[record and idempotent replay]'
$first = New-Entry 'A01'
$r = Invoke-Record $first
Assert-TestCondition ($r.Code -eq 0 -and $r.Result.Status -eq 'Recorded') 'first real feedback is recorded and acknowledged'
$savedHash = (Get-FileHash $ledger).Hash
$r = Invoke-Record $first
Assert-TestCondition ($r.Code -eq 0 -and $r.Result.Status -eq 'Duplicate' -and (Get-FileHash $ledger).Hash -eq $savedHash) 'replay is acknowledged without changing bytes'
$records = Get-Records
Assert-TestCondition ($records.Count -eq 1 -and $records[0].Score -eq 1 -and $records[0].Scope -ceq '同一任务内的固定范围') 'readback preserves the actual score and Unicode scope'

Write-Host '[same-task history and conflicting sources]'
$second = New-Entry 'A02' 3
$r = Invoke-Record $second
$records = Get-Records
Assert-TestCondition ($r.Code -eq 0 -and $records.Count -eq 2 -and $records[1].Score -eq 3 -and $records[0].Task -eq $records[1].Task) 'same-task later high score is preserved alongside the low score with one stable task identity'
$savedHash = (Get-FileHash $ledger).Hash
$entry = Get-Content -Raw $first | ConvertFrom-Json
$entry.Score = 0
Set-TestFile $first ($entry | ConvertTo-Json)
$r = Invoke-Record $first
Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Status -eq 'Pending' -and $r.Result.Reason -eq 'Conflict' -and (Get-FileHash $ledger).Hash -eq $savedHash) 'conflicting content for one answer cannot overwrite feedback'
$r = Invoke-Record (New-Entry 'A03' 0 'Denied')
$r2 = Invoke-Record (New-Entry 'A04' 1 'Unspecified')
$records = Get-Records
Assert-TestCondition ($r.Code -eq 0 -and $r2.Code -eq 0 -and $records[2].Permission -eq 'Denied' -and $records[3].Permission -eq 'Unspecified') 'denied and score-only feedback do not become approved records'

Write-Host '[legacy preservation and interrupted content]'
$legacy = Join-Path $work 'legacy.md'
$legacyBytes = [Text.UTF8Encoding]::new($true).GetPreamble() + [Text.Encoding]::UTF8.GetBytes("# 私有台账`r`n<!-- feedback-entry: old-task/A01 -->`r`n旧记录；1分`r`n")
[IO.File]::WriteAllBytes($legacy, $legacyBytes)
$r = Invoke-Record $second $legacy
$after = [IO.File]::ReadAllBytes($legacy)
Assert-TestCondition ($r.Code -eq 0 -and [Convert]::ToBase64String($after[0..($legacyBytes.Length - 1)]) -ceq [Convert]::ToBase64String($legacyBytes)) 'legacy UTF-8 BOM, CRLF and manual records remain byte-identical'
$broken = Join-Path $work 'incomplete.md'
Set-TestFile $broken "<!-- feedback-entry: $($r.Result.EntryId) -->`n"
$savedHash = (Get-FileHash $broken).Hash
$r = Invoke-Record $second $broken
Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Reason -eq 'Conflict' -and (Get-FileHash $broken).Hash -eq $savedHash) 'an incomplete existing source is not reported as saved'

Write-Host '[busy and unwritable destinations]'
$busy = [IO.File]::Open("$ledger.lock", 'Open', 'ReadWrite', 'None')
try {
    $savedHash = (Get-FileHash $ledger).Hash
    $pending = New-Entry 'A05'
    $r = Invoke-Record $pending
    Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Reason -eq 'Busy' -and $r.Result.Stage -eq 'AcquireLock' -and (Get-FileHash $ledger).Hash -eq $savedHash) 'a held OS lock identifies its stage without writing or retrying'
}
finally { $busy.Dispose() }
$r = Invoke-Record $pending
Assert-TestCondition ($r.Code -eq 0 -and $r.Result.Status -eq 'Recorded') 'a later normal replay records the formerly busy entry'
$occupied = Join-Path $work 'occupied.md'
New-Item -ItemType Directory $occupied | Out-Null
$r = Invoke-Record $pending $occupied
Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Status -eq 'Pending' -and $r.Result.Stage -eq 'ReadLedger' -and (Test-Path -LiteralPath $occupied -PathType Container)) 'an occupied ledger identifies the read stage and preserves the directory'
$blockedLockLedger = Join-Path $work 'blocked-lock.md'
New-Item -ItemType Directory "$blockedLockLedger.lock" | Out-Null
$r = Invoke-Record $pending $blockedLockLedger
Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Reason -eq 'StorageFailure' -and $r.Result.Stage -eq 'AcquireLock' -and -not (Test-Path $blockedLockLedger)) 'an unusable lock path identifies the acquire stage without guessing a permissions cause'

Write-Host '[capacity and blocked publication diagnostics]'
$oversized = Join-Path $work 'oversized.md'
Set-TestFile $oversized ('x' * 4194305)
$savedHash = (Get-FileHash $oversized).Hash
$r = Invoke-Record $pending $oversized
Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Stage -eq 'ReadLedger' -and (Get-FileHash $oversized).Hash -eq $savedHash) 'a ledger over the existing limit stops at read without changing bytes'
$publishBlocked = Join-Path $work 'publish-blocked.md'
Set-TestFile $publishBlocked 'private-publication-sentinel'
$savedHash = (Get-FileHash $publishBlocked).Hash
$reader = [IO.File]::Open($publishBlocked, 'Open', 'Read', 'Read')
try {
    $r = Invoke-Record $pending $publishBlocked
    $diagnostic = $r.Result | ConvertTo-Json -Compress
    Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Reason -eq 'StorageFailure' -and $r.Result.Stage -eq 'PublishLedger' -and (Get-FileHash $publishBlocked).Hash -eq $savedHash) 'a replacement blocked by an open reader identifies publication and preserves original bytes'
    Assert-TestCondition (-not $diagnostic.Contains($work) -and $diagnostic -notmatch 'private-publication-sentinel|publish-blocked') 'failure diagnostics reveal neither the private path nor ledger contents'
    Assert-TestCondition (@(Get-ChildItem $work -Filter '*.tmp' -File -Recurse -Force).Count -eq 0) 'failed publication removes only its temporary replacement'
}
finally { $reader.Dispose() }
$r = Invoke-Record $pending $publishBlocked
Assert-TestCondition ($r.Code -eq 0 -and $r.Result.Status -eq 'Recorded') 'the same entry records after the publication blocker is released'
$savedHash = (Get-FileHash $publishBlocked).Hash
$r = Invoke-Record $pending $publishBlocked
Assert-TestCondition ($r.Code -eq 0 -and $r.Result.Status -eq 'Duplicate' -and (Get-FileHash $publishBlocked).Hash -eq $savedHash) 'reconciliation replay remains idempotent after publication recovery'

Write-Host '[invalid input never touches the ledger]'
$savedHash = (Get-FileHash $ledger).Hash
foreach ($badScore in @('1', 1.5, -1, 4, $null)) {
    $entry = Get-Content -Raw $second | ConvertFrom-Json
    $entry.Score = $badScore
    $badPath = Join-Path $work 'invalid.json'
    Set-TestFile $badPath ($entry | ConvertTo-Json)
    $r = Invoke-Record $badPath
    Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Reason -eq 'InvalidInput' -and (Get-FileHash $ledger).Hash -eq $savedHash) 'non-integer, absent or out-of-range scores are rejected without mutation'
}
$entry = Get-Content -Raw $second | ConvertFrom-Json
$entry | Add-Member Unexpected 'private-sentinel-value'
$badPath = Join-Path $work 'extra.json'
Set-TestFile $badPath ($entry | ConvertTo-Json)
$r = Invoke-Record $badPath
Assert-TestCondition ($r.Code -eq 1 -and ($r.Result | ConvertTo-Json) -notmatch 'private-sentinel-value') 'unknown fields are rejected without echoing private input'
$r = Invoke-Record $pending 'relative.md'
Assert-TestCondition ($r.Code -eq 1 -and $r.Result.Reason -eq 'InvalidInput' -and -not (Test-Path (Join-Path $RepoRoot 'relative.md'))) 'relative storage is refused without falling back to cwd'

Write-Host '[linked paths are refused]'
$target = Join-Path $work 'link-target'
New-Item -ItemType Directory $target | Out-Null
$link = Join-Path $work 'linked'
New-Item -ItemType Junction -Path $link -Target $target | Out-Null
try {
    $r = Invoke-Record $pending (Join-Path $link 'ledger.md')
    Assert-TestCondition ($r.Code -eq 1 -and @(Get-ChildItem $target -Force).Count -eq 0) 'a linked ancestor cannot redirect writes'
}
finally { (Get-Item -LiteralPath $link -Force).Delete() }

Write-Host '[concurrent submissions and readback]'
$parallelLedger = Join-Path $work 'concurrent.md'
$children = @()
try {
    foreach ($name in @('C01', 'C02', 'C03', 'C04')) {
        $inputPath = New-Entry $name
        $info = [Diagnostics.ProcessStartInfo]::new(@(Get-Command pwsh -CommandType Application)[0].Source)
        foreach ($argument in @('-NoProfile', '-File', $recorder, '-EntryPath', $inputPath, '-LedgerPath', $parallelLedger)) {
            $info.ArgumentList.Add($argument)
        }
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $process = [Diagnostics.Process]::Start($info)
        $children += @{ Process = $process; Input = $inputPath; Output = $process.StandardOutput.ReadToEndAsync(); Error = $process.StandardError.ReadToEndAsync() }
    }
    foreach ($child in $children) {
        if (-not $child.Process.WaitForExit(10000)) { $child.Process.Kill($true); throw 'Recorder timed out.' }
        $result = $child.Output.GetAwaiter().GetResult() | ConvertFrom-Json
        Assert-TestCondition ($result.Status -in @('Recorded', 'Pending') -and -not $child.Error.GetAwaiter().GetResult()) 'concurrent writers return a valid terminal result'
        if ($result.Status -eq 'Pending') {
            Assert-TestCondition ($result.Reason -eq 'Busy') 'contention is explicitly pending'
        }
    }
    foreach ($child in $children) {
        $r = Invoke-Record $child.Input $parallelLedger
        Assert-TestCondition ($r.Code -eq 0 -and $r.Result.Status -in @('Recorded', 'Duplicate')) 'normal replay reconciles concurrent submissions'
    }
    $records = Get-Records $parallelLedger
    Assert-TestCondition ($records.Count -eq 4 -and @($records.Source | Sort-Object -Unique).Count -eq 4) 'concurrent submission plus replay loses no answer and creates no duplicate'
}
finally {
    foreach ($child in $children) {
        if (-not $child.Process.HasExited) { $child.Process.Kill($true); $child.Process.WaitForExit() }
        $child.Process.Dispose()
    }
}
Assert-TestCondition (@(Get-ChildItem $work -Filter '*.tmp' -File -Recurse -Force).Count -eq 0) 'normal terminal outcomes leave no temporary replacement files'
Write-Host 'approval-feedback tests: PASS'
