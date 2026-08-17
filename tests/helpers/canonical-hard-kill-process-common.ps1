#requires -Version 7.0

function Test-HardKillProcessIdentityGone {
    param([Parameter(Mandatory)][int]$ProcessId,[Parameter(Mandatory)][long]$StartTimeUtcTicks)
    $live=$null
    try{
        $live=[Diagnostics.Process]::GetProcessById($ProcessId)
        return $live.StartTime.ToUniversalTime().Ticks -ne $StartTimeUtcTicks
    }catch [ArgumentException]{return $true}
    finally{if($live){$live.Dispose()}}
}
