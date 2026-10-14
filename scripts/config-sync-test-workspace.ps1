#requires -Version 7.0
# Dot-source only. The suite and its runner share this exact workspace ownership contract.
Set-StrictMode -Version Latest

function Get-ConfigSyncTestBase {
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    $base = [IO.Path]::GetFullPath((Join-Path $repo 'tmp/tests/config-sync'))
    $path = $base
    while ($path) {
        if (Test-Path -LiteralPath $path) {
            $item = Get-Item -LiteralPath $path -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw 'Config-sync test workspace ancestors must be ordinary directories.'
            }
        }
        $parent = Split-Path -Parent $path
        if ($parent -eq $path) { break }
        $path = $parent
    }
    return $base
}

function Assert-ConfigSyncTestWork {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $WorkRoot,
        [Parameter(Mandatory)] [ValidatePattern('^[a-f0-9]{32}$')] [string] $RunId
    )
    $expected = Join-Path (Get-ConfigSyncTestBase -RepoRoot $RepoRoot) $RunId
    $actual = [IO.Path]::GetFullPath($WorkRoot)
    if (-not [string]::Equals($actual, $expected, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Config-sync workspace is outside its exact owned run path.'
    }
    $root = Get-Item -LiteralPath $actual -Force
    $markerPath = Join-Path $actual 'owner.json'
    $marker = Get-Item -LiteralPath $markerPath -Force
    if (-not $root.PSIsContainer -or $marker.PSIsContainer -or
        ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        ($marker.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Config-sync workspace ownership cannot use a reparse point.'
    }
    $owner = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json
    if ($owner.project -ne 'ai-agent-dotfiles' -or $owner.suite -ne 'config-sync.tests.ps1' -or $owner.run_id -ne $RunId) {
        throw 'Config-sync workspace ownership marker does not match this run.'
    }
    return $actual
}

function New-ConfigSyncTestWork {
    param([Parameter(Mandatory)] [string] $RepoRoot)
    $base = Get-ConfigSyncTestBase -RepoRoot $RepoRoot
    $runId = [Guid]::NewGuid().ToString('N')
    $root = Join-Path $base $runId
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    [ordered]@{
        project='ai-agent-dotfiles';suite='config-sync.tests.ps1';run_id=$runId;owner_pid=$PID;
        created_utc=[DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'owner.json') -Encoding utf8
    return [pscustomobject]@{ Root=$root;RunId=$runId }
}

function Complete-ConfigSyncTestWork {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $WorkRoot,
        [Parameter(Mandatory)] [string] $RunId,
        [Parameter(Mandatory)] [ValidateSet('Passed','Failed','TimedOut','Unknown')] [string] $Outcome,
        [string[]] $FailureMessages = @(),
        [string] $ExceptionType = '',
        [string] $FailureScript = '',
        [int] $FailureLine = 0,
        [Nullable[int]] $ExitCode = $null,
        [ValidateSet('','TimedOut','OutputNotDrained','ChildExitFailed','RunnerFailure','ProcessNotTerminal','WorkspaceNotFinalized')] [string] $ProblemKind = '',
        [ValidateSet('Suite','Runner')] [string] $ReceiptRole = 'Suite',
        [bool] $ParentTerminal = $false,
        [bool] $OutputDrained = $false,
        [switch] $RemovePayload
    )
    $root = Assert-ConfigSyncTestWork -RepoRoot $RepoRoot -WorkRoot $WorkRoot -RunId $RunId
    if ($RemovePayload -and $Outcome -in @('TimedOut','Unknown')) {
        throw 'Timeout or uncertain termination must retain the exact owned workspace.'
    }
    if ($RemovePayload) {
        $pending = [Collections.Generic.Stack[string]]::new()
        $pending.Push($root)
        while ($pending.Count) {
            foreach ($item in (Get-ChildItem -LiteralPath $pending.Pop() -Force)) {
                if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw 'Config-sync fixture contains a reparse point; preserve it for inspection.'
                }
                if ($item.PSIsContainer) { $pending.Push($item.FullName) }
            }
        }
    }
    $receipts = Join-Path (Get-ConfigSyncTestBase -RepoRoot $RepoRoot) 'receipts'
    if (Test-Path -LiteralPath $receipts) {
        $item = Get-Item -LiteralPath $receipts -Force
        if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Config-sync receipt directory must be an ordinary directory.'
        }
    }
    $suffix = if ($ReceiptRole -eq 'Runner') { '-runner' } else { '' }
    $receiptPath = Join-Path $receipts "$RunId$suffix.json"
    if (Test-Path -LiteralPath $receiptPath) {
        $item = Get-Item -LiteralPath $receiptPath -Force
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Config-sync receipt file must be an ordinary file.'
        }
    }
    New-Item -ItemType Directory -Path $receipts -Force | Out-Null
    # Record only structured fields and constant problem kinds, never child output.
    # A failure receipt records the pre-cleanup observation, not a deletion result.
    $problemSummary = if ($ProblemKind) { "$ProblemKind; exit_code=$ExitCode; parent_terminal=$ParentTerminal; output_drained=$OutputDrained" } else { '' }
    $json = [ordered]@{
        project='ai-agent-dotfiles';suite='config-sync.tests.ps1';run_id=$RunId;outcome=$Outcome;role=$ReceiptRole;
        observed_utc=[DateTime]::UtcNow.ToString('o');parent_terminal=$ParentTerminal;output_drained=$OutputDrained;
        payload_present_at_receipt=$true;cleanup_requested=[bool]$RemovePayload;
        cleanup_required=$(if ($RemovePayload) { $null } else { $true });
        failed_assertions=@($FailureMessages);exception_type=$ExceptionType;failure_script=$FailureScript;failure_line=$FailureLine;
        exit_code=$ExitCode;problem_kind=$ProblemKind;problem_summary=$problemSummary.Substring(0,[Math]::Min(160,$problemSummary.Length))
    } | ConvertTo-Json
    # CreateNew preserves an existing receipt, and Flush(true) completes the diagnostic
    # write before any payload removal. Any IO failure leaves the original root.
    $stream = [IO.FileStream]::new($receiptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
    try {
        $bytes=[Text.Encoding]::UTF8.GetBytes($json)
        $stream.Write($bytes,0,$bytes.Length)
        $stream.Flush($true)
    }
    finally { $stream.Dispose() }
    if ($RemovePayload) { Remove-Item -LiteralPath $root -Recurse -Force }
    if ($Outcome -eq 'Passed' -and $RemovePayload) { Remove-Item -LiteralPath $receiptPath -Force }
}
