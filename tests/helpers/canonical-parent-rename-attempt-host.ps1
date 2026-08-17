#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('JournalPhase','PathMissing','PathPresent','FileContent','ChildPresent','LeaseHeld')][string]$TriggerKind,
    [Parameter(Mandatory)][string]$WatchRoot,
    [Parameter(Mandatory)][string]$Ancestor,
    [Parameter(Mandatory)][string]$Moved,
    [Parameter(Mandatory)][string]$ReadyPath,
    [Parameter(Mandatory)][string]$ResultPath,
    [string]$TransactionNamespace,
    [string]$Phase,
    [string]$StopPhase,
    [string]$TargetId,
    [string]$WorkspaceRole,
    [string]$TriggerPath,
    [string]$ExpectedContent,
    [string]$ProbePath,
    [int]$TimeoutSeconds=120
)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'

function Get-JournalPhaseMatch {
    param([Parameter(Mandatory)][string]$ExpectedPhase)
    if([string]::IsNullOrWhiteSpace($TransactionNamespace) -or -not(Test-Path -LiteralPath $TransactionNamespace -PathType Container)){return $false}
    foreach($file in @(Get-ChildItem -LiteralPath $TransactionNamespace -Filter '*.json' -File -ErrorAction SilentlyContinue)){
        try{$record=[IO.File]::ReadAllText($file.FullName)|ConvertFrom-Json -AsHashtable}catch{continue}
        if(-not $record.Contains('Phase') -or [string]$record.Phase -cne $ExpectedPhase){continue}
        if($TargetId -and (-not $record.Contains('Data') -or [string]$record.Data.TargetId -cne $TargetId)){continue}
        if($WorkspaceRole -and (-not $record.Contains('Data') -or [string]$record.Data.WorkspaceRole -cne $WorkspaceRole)){continue}
        return $true
    }
    return $false
}

function Test-Trigger {
    switch($TriggerKind){
        'JournalPhase'{return Get-JournalPhaseMatch -ExpectedPhase $Phase}
        'PathMissing'{return -not(Test-Path -LiteralPath $TriggerPath)}
        'PathPresent'{return Test-Path -LiteralPath $TriggerPath}
        'ChildPresent'{return Test-Path -LiteralPath $TriggerPath}
        'FileContent'{
            try{return [IO.File]::ReadAllText([IO.Path]::GetFullPath($TriggerPath)) -ceq $ExpectedContent}catch{return $false}
        }
        'LeaseHeld'{
            $probe=[IO.Path]::GetFullPath($ProbePath)
            try{
                [IO.Directory]::Move([IO.Path]::GetFullPath($Ancestor),$probe)
                [IO.Directory]::Move($probe,[IO.Path]::GetFullPath($Ancestor))
                return $false
            }
            catch{return $true}
        }
    }
}

$watcher=[IO.FileSystemWatcher]::new([IO.Path]::GetFullPath($WatchRoot))
$watcher.IncludeSubdirectories=$true
$watcher.NotifyFilter=[IO.NotifyFilters]::FileName -bor [IO.NotifyFilters]::DirectoryName -bor [IO.NotifyFilters]::LastWrite -bor [IO.NotifyFilters]::Size
$watcher.Filter='*'
$watcher.EnableRaisingEvents=$true
$result=[ordered]@{Attempted=$false;Blocked=$false;Moved=$false;Missed=$false;Error=$null}
try{
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ReadyPath),'ready',[Text.UTF8Encoding]::new($false))
    $deadline=[DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while([DateTime]::UtcNow -lt $deadline){
        if($StopPhase -and (Get-JournalPhaseMatch -ExpectedPhase $StopPhase)){$result.Missed=$true;break}
        if(Test-Trigger){
            $result.Attempted=$true
            try{
                [IO.Directory]::Move([IO.Path]::GetFullPath($Ancestor),[IO.Path]::GetFullPath($Moved))
                $result.Moved=$true
                [IO.Directory]::CreateDirectory([IO.Path]::GetFullPath($Ancestor))|Out-Null
            }
            catch{$result.Blocked=$true;$result.Error=$_.Exception.GetBaseException().Message}
            break
        }
        $null=$watcher.WaitForChanged([IO.WatcherChangeTypes]::All,1000)
    }
    if(-not $result.Attempted -and -not $result.Missed){$result.Missed=$true}
}
finally{
    $watcher.Dispose()
    [IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath),($result|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
}
