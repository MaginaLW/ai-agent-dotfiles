#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolchainRoot,
    [Parameter(Mandatory)][string]$LockPath,
    [ValidateRange(1,300)][int]$WaitSeconds=3,
    [string]$AcquiredMarker
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
. (Join-Path $ToolchainRoot 'scripts/transaction-journal-common.ps1')

$deadline=[DateTime]::UtcNow.AddSeconds($WaitSeconds)
$lock=$null
do {
    try{$lock=Enter-CanonicalRepoLock -LockPath $LockPath}
    catch{
        if($_.Exception.Message -notmatch 'operation-lock-busy' -or [DateTime]::UtcNow -ge $deadline){throw}
        Start-Sleep -Milliseconds 50
    }
}while($null -eq $lock)
try{
    if($AcquiredMarker){
        $stream=[System.IO.File]::Open($AcquiredMarker,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)
        try{$bytes=[Text.Encoding]::ASCII.GetBytes('acquired');$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    }
}finally{Exit-CanonicalRepoLock -LockHandle $lock}
