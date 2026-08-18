$ErrorActionPreference='Stop'
$refDir=Join-Path $env:TEMP 'provenance-refs'
$hostPath='C:\Repos\ai-agent-dotfiles\tests\helpers\canonical-hard-kill-host.ps1'
$text=[IO.File]::ReadAllText($hostPath)

# 1) param 块扩展：在 TerminalOutcome 后加 probe 与 sealed 参数
$oldParam="    [ValidateSet('committed','failed-restored')][string]`$TerminalOutcome='committed'
)"
$newParam="    [ValidateSet('committed','failed-restored')][string]`$TerminalOutcome='committed',
    [string]`$ContractProbeRequestPath,
    [string]`$ContractProbeRequestSha256,
    [string]`$MutationEnginePath,
    [string]`$ExpectedEngineSha256,
    [string]`$ExpectedProbeHostSha256,
    [string]`$ContractProbeResultPath,
    [string]`$ContractProbeScratchRoot,
    [string]`$SealedInvocationFixturePath,
    [string]`$SealedInvocationFixtureSha256
)"
if($text.IndexOf($oldParam,[StringComparison]::Ordinal) -lt 0){throw 'param anchor missing'}
$text=$text.Replace($oldParam,$newParam)

# 2) probeRoute：插在 param 块结束后（Set-StrictMode 前）
$probeRoute=[IO.File]::ReadAllText((Join-Path $refDir 'probeRouteSource.txt')).TrimEnd()
$anchor='. (Join-Path $ToolchainRoot ''scripts/canonical-recovery-common.ps1'')'
if($text.IndexOf($anchor,[StringComparison]::Ordinal) -lt 0){throw 'loader anchor missing'}
$text=$text.Replace($anchor,$probeRoute+"`n`n"+$anchor)

[IO.File]::WriteAllText($hostPath,$text)
'param + probeRoute inserted'
