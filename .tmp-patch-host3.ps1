$ErrorActionPreference='Stop'
$refDir=Join-Path $env:TEMP 'provenance-refs'
$hostPath='C:\Repos\ai-agent-dotfiles\tests\helpers\canonical-hard-kill-host.ps1'
$text=[IO.File]::ReadAllText($hostPath)

# 4) real/partial helper 函数定义：追加在 param 块/验证区之后、主流程之前。
#    插入点：probeRoute 之后的位置（Set-StrictMode 行之前不行--函数要在顶层。放在 loader 之后）。
$anchor='. (Join-Path $ToolchainRoot ''scripts/canonical-recovery-common.ps1'')'
if($text.IndexOf($anchor,[StringComparison]::Ordinal) -lt 0){throw 'loader anchor missing'}
$realFn=([IO.File]::ReadAllText((Join-Path $refDir 'realSource.txt'))).TrimEnd()
$partialFn=([IO.File]::ReadAllText((Join-Path $refDir 'partialSource.txt'))).TrimEnd()
$helpers=$realFn+"`n`n"+$partialFn
$text=$text.Replace($anchor,$anchor+"`n`n"+$helpers)
[IO.File]::WriteAllText($hostPath,$text)
'helper functions inserted'
