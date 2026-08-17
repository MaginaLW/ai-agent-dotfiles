#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][string]$OpenedMarkerPath,
    [Parameter(Mandatory)][ValidateRange(1,[int]::MaxValue)][int]$ParentProcessId,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$ParentStartTimeUtcTicks,
    [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$DeadlineUtcTicks
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

if(-not('AiAgentDotfilesTests.HeldReadAttemptWatchdog' -as [type])){
    Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Threading;
namespace AiAgentDotfilesTests {
    public static class HeldReadAttemptWatchdog {
        public static void Start(int parentProcessId, long parentStartTimeUtcTicks, long deadlineUtcTicks) {
            Process parent = Process.GetProcessById(parentProcessId);
            if (parent.StartTime.ToUniversalTime().Ticks != parentStartTimeUtcTicks) {
                parent.Dispose();
                throw new InvalidOperationException("held-file read-attempt parent identity mismatch");
            }
            Thread watchdog = new Thread(() => {
                try {
                    while (true) {
                        long remainingTicks = deadlineUtcTicks - DateTime.UtcNow.Ticks;
                        if (remainingTicks <= 0) Environment.Exit(124);
                        int waitMilliseconds = (int)Math.Min(100L, Math.Max(1L, (remainingTicks + TimeSpan.TicksPerMillisecond - 1L) / TimeSpan.TicksPerMillisecond));
                        if (parent.WaitForExit(waitMilliseconds)) Environment.Exit(0);
                    }
                } finally { parent.Dispose(); }
            });
            watchdog.IsBackground = true;
            watchdog.Name = "held-file-read-attempt-watchdog";
            watchdog.Start();
        }
    }
}
'@
}

$stream=$null
try{
    if([DateTime]::UtcNow.Ticks -ge $DeadlineUtcTicks){throw 'held-file read-attempt deadline elapsed before startup'}
    [AiAgentDotfilesTests.HeldReadAttemptWatchdog]::Start($ParentProcessId,$ParentStartTimeUtcTicks,$DeadlineUtcTicks)
    $stream=[IO.File]::Open(
        [IO.Path]::GetFullPath($Path),
        [IO.FileMode]::Open,
        [IO.FileAccess]::Read,
        [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete
    )
    [IO.File]::WriteAllText(
        [IO.Path]::GetFullPath($OpenedMarkerPath),
        'opened',
        [Text.UTF8Encoding]::new($false)
    )
    while($true){Start-Sleep -Milliseconds 100}
}finally{
    if($stream){$stream.Dispose()}
}
