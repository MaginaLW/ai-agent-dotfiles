#requires -Version 7.0
[CmdletBinding()]
param([string]$RepoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$script:assertionCount=0

function Assert-True {
    param([Parameter(Mandatory)][bool]$Condition,[Parameter(Mandatory)][string]$Message)
    if(-not $Condition){throw $Message}
    $script:assertionCount++
}

$helperPath=Join-Path $RepoRoot 'tests/helpers/canonical-hard-kill-job-process.ps1'
$helperText=[IO.File]::ReadAllText($helperPath)
$legacyStart=$helperText.IndexOf('internal void TerminateForLegacy',[StringComparison]::Ordinal)
$legacyEnd=if($legacyStart -ge 0){$helperText.IndexOf('public void Dispose()',$legacyStart,[StringComparison]::Ordinal)}else{-1}
$legacySource=if($legacyStart -ge 0 -and $legacyEnd -gt $legacyStart){$helperText.Substring($legacyStart,$legacyEnd-$legacyStart)}else{''}
Assert-True ($helperText.IndexOf('private const int ReviewedLegacyReapMilliseconds = 30000;',[StringComparison]::Ordinal) -ge 0) `
    'legacy reap does not declare its reviewed 30-second budget'
Assert-True ($legacySource.IndexOf('legacyReapDeadlineQpc = AddMillisecondsChecked(Stopwatch.GetTimestamp(), ReviewedLegacyReapMilliseconds, Stopwatch.Frequency);',[StringComparison]::Ordinal) -ge 0 -and
    $legacySource.IndexOf('legacyReapDeadlineQpc = AddMillisecondsChecked(Stopwatch.GetTimestamp(), timeoutMilliseconds, Stopwatch.Frequency);',[StringComparison]::Ordinal) -lt 0) `
    'legacy reap refreshes its absolute QPC deadline from the caller timeout'
Assert-True ($legacySource.IndexOf('legacyTerminationAttemptCount == 0',[StringComparison]::Ordinal) -ge 0 -and
    $legacySource.IndexOf('legacyTerminationAttemptCount = 1',[StringComparison]::Ordinal) -ge 0 -and
    ([regex]::Matches($legacySource,'TerminateJobObject\(').Count -eq 1)) `
    'legacy reap can issue TerminateJobObject more than once'
Assert-True ($legacySource.IndexOf('Marshal.GetLastWin32Error()',[StringComparison]::Ordinal) -ge 0 -and
    $legacySource.IndexOf('legacyTerminationNativeErrorCode',[StringComparison]::Ordinal) -ge 0 -and
    $legacySource.IndexOf('legacyTerminationFailureOperation',[StringComparison]::Ordinal) -ge 0) `
    'legacy reap does not retain the first TerminateJobObject native failure'

$controllerPath=Join-Path $RepoRoot 'tests/canonical-hard-kill.tests.ps1'
$tokens=$null;$parseErrors=$null
$controllerAst=[Management.Automation.Language.Parser]::ParseFile($controllerPath,[ref]$tokens,[ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) 'canonical hard-kill controller does not parse'
$waitFunctions=@($controllerAst.FindAll({param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'Wait-HardKillExternalSetupCheckpoint'
},$true))
Assert-True ($waitFunctions.Count -eq 1) 'setup checkpoint controller is not uniquely defined'
$waitSource=if($waitFunctions.Count -eq 1){[string]$waitFunctions[0].Extent.Text}else{''}
Assert-True ($waitSource.IndexOf('$primaryFailure=$null',[StringComparison]::Ordinal) -ge 0 -and
    $waitSource.IndexOf('[AggregateException]::new(',[StringComparison]::Ordinal) -ge 0 -and
    $waitSource.IndexOf('[Exception[]]@($primaryFailure,$cleanupFailure)',[StringComparison]::Ordinal) -ge 0) `
    'setup checkpoint cleanup can replace the primary failure'
Assert-True ($waitSource.IndexOf('if(-not $jobProcess.Reaped)',[StringComparison]::Ordinal) -ge 0) `
    'setup checkpoint cleanup retries an already completed Job reap'

. $helperPath

$identityMethod=[AiAgentDotfilesTests.HardKillJobProcess].GetMethod(
    'OriginalProcessIdentityGone',
    [Reflection.BindingFlags]'Static,NonPublic'
)
Assert-True ($null -ne $identityMethod) 'exact identity probe is unavailable'

$current=[Diagnostics.Process]::GetCurrentProcess()
try{
    $currentCreationFileTime=[long]$current.StartTime.ToUniversalTime().ToFileTimeUtc()
    Assert-True (-not[bool]$identityMethod.Invoke($null,@([int]$current.Id,$currentCreationFileTime))) `
        'a live exact PID/creation identity was incorrectly reported gone'
    Assert-True ([bool]$identityMethod.Invoke($null,@([int]$current.Id,($currentCreationFileTime-1L)))) `
        'a reused PID with a different creation FILETIME was not distinguished'
}finally{$current.Dispose()}

$probe=$null
try{
    $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    $probe=[Diagnostics.Process]::new()
    $probe.StartInfo.FileName=$pwsh
    $probe.StartInfo.UseShellExecute=$false
    $null=$probe.StartInfo.ArgumentList.Add('-NoProfile')
    $null=$probe.StartInfo.ArgumentList.Add('-Command')
    $null=$probe.StartInfo.ArgumentList.Add('[Threading.Thread]::Sleep(60000)')
    Assert-True $probe.Start() 'retained-handle identity probe did not start'
    $probeCreationFileTime=[long]$probe.StartTime.ToUniversalTime().ToFileTimeUtc()
    $null=$probe.Handle
    $probe.Kill($true)
    Assert-True $probe.WaitForExit(10000) 'retained-handle identity probe did not exit'
    Assert-True (-not[bool]$identityMethod.Invoke($null,@([int]$probe.Id,$probeCreationFileTime))) `
        'a signaled exact process retained by an external handle was incorrectly reported gone'
    $probeId=[int]$probe.Id
    $probe.Dispose();$probe=$null
    $deadline=[DateTime]::UtcNow.AddSeconds(10)
    do{
        $gone=[bool]$identityMethod.Invoke($null,@($probeId,$probeCreationFileTime))
        if(-not $gone){Start-Sleep -Milliseconds 10}
    }until($gone -or [DateTime]::UtcNow -ge $deadline)
    Assert-True $gone 'the exact process identity remained visible after its final test-owned handle closed'
}finally{
    if($probe){try{if(-not $probe.HasExited){$probe.Kill($true);$null=$probe.WaitForExit(10000)}}finally{$probe.Dispose()}}
}

$legacyJob=$null
try{
    $pwsh=(Get-Command pwsh -ErrorAction Stop).Source
    $legacyJob=Start-HardKillJobProcess -FilePath $pwsh -ArgumentList @(
        '-NoProfile','-Command','[Threading.Thread]::Sleep(60000)'
    )
    $callStart=[Diagnostics.Stopwatch]::GetTimestamp()
    Assert-True (Confirm-HardKillJobProcessReaped -JobProcess $legacyJob -TimeoutMilliseconds 1) `
        'legacy reap still treats the caller timeout as its reap budget'
    Assert-True $legacyJob.Reaped 'legacy reap did not produce its exact reap state'

    $flags=[Reflection.BindingFlags]'Instance,NonPublic'
    $deadlineField=[AiAgentDotfilesTests.HardKillJobProcess].GetField('legacyReapDeadlineQpc',$flags)
    $attemptField=[AiAgentDotfilesTests.HardKillJobProcess].GetField('legacyTerminationAttemptCount',$flags)
    Assert-True ($null -ne $deadlineField -and $null -ne $attemptField) 'legacy reap state is not reviewable'
    $firstDeadline=[long]$deadlineField.GetValue($legacyJob)
    $firstAttemptCount=[int]$attemptField.GetValue($legacyJob)
    $budgetMilliseconds=($firstDeadline-$callStart)*1000.0/[Diagnostics.Stopwatch]::Frequency
    Assert-True ($budgetMilliseconds -ge 29000 -and $budgetMilliseconds -le 31000) `
        'legacy reap did not bind the reviewed absolute QPC deadline on first entry'
    Assert-True ($firstAttemptCount -eq 1) 'legacy reap did not record exactly one termination attempt'
    Assert-True (Confirm-HardKillJobProcessReaped -JobProcess $legacyJob -TimeoutMilliseconds 1) `
        'a completed legacy reap did not remain idempotent'
    Assert-True ([long]$deadlineField.GetValue($legacyJob) -eq $firstDeadline -and [int]$attemptField.GetValue($legacyJob) -eq 1) `
        'later legacy cleanup refreshed the deadline or repeated TerminateJobObject'

    $argumentFailure=$null
    try{$null=Confirm-HardKillJobProcessReaped -JobProcess $legacyJob -TimeoutMilliseconds 0}catch{$argumentFailure=$_.Exception}
    Assert-True ($argumentFailure -is [ArgumentOutOfRangeException]) `
        'the reflection bridge did not unwrap the real argument exception type'

    $nativeCodeField=[AiAgentDotfilesTests.HardKillJobProcess].GetField('legacyTerminationNativeErrorCode',$flags)
    $nativeOperationField=[AiAgentDotfilesTests.HardKillJobProcess].GetField('legacyTerminationFailureOperation',$flags)
    Assert-True ($null -ne $nativeCodeField -and $null -ne $nativeOperationField) `
        'legacy native failure state is not retained'
    $expectedNativeCode=5
    $expectedNativeOperation='TerminateJobObject legacy containment failed'
    $nativeCodeField.SetValue($legacyJob,$expectedNativeCode)
    $nativeOperationField.SetValue($legacyJob,$expectedNativeOperation)
    $firstNativeFailure=$null;$secondNativeFailure=$null
    try{$null=Confirm-HardKillJobProcessReaped -JobProcess $legacyJob -TimeoutMilliseconds 1}catch{$firstNativeFailure=$_.Exception}
    try{$null=Confirm-HardKillJobProcessReaped -JobProcess $legacyJob -TimeoutMilliseconds 1}catch{$secondNativeFailure=$_.Exception}
    Assert-True ($firstNativeFailure -is [ComponentModel.Win32Exception] -and
        $secondNativeFailure -is [ComponentModel.Win32Exception]) `
        'the reflection bridge did not preserve the real native exception type'
    Assert-True ($firstNativeFailure.NativeErrorCode -eq $expectedNativeCode -and
        $secondNativeFailure.NativeErrorCode -eq $expectedNativeCode -and
        $firstNativeFailure.Message -ceq $expectedNativeOperation -and
        $secondNativeFailure.Message -ceq $expectedNativeOperation) `
        'legacy native error code or operation changed across cleanup retries'
    Assert-True ([int]$firstNativeFailure.Data['NativeErrorCode'] -eq $expectedNativeCode -and
        [string]$firstNativeFailure.Data['NativeOperation'] -ceq $expectedNativeOperation -and
        [int]$secondNativeFailure.Data['NativeErrorCode'] -eq $expectedNativeCode -and
        [string]$secondNativeFailure.Data['NativeOperation'] -ceq $expectedNativeOperation) `
        'the reflection bridge lost retained native exception Data'
}finally{
    if($legacyJob){
        if(-not $legacyJob.Reaped){try{$null=Confirm-HardKillJobProcessReaped -JobProcess $legacyJob -TimeoutMilliseconds 30000}catch{}}
        if($legacyJob.Reaped){Close-HardKillJobProcess -JobProcess $legacyJob}
    }
}

Write-Host ("Results: {0} passed, 0 failed" -f $script:assertionCount)
