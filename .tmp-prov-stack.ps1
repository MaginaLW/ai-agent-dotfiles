$ErrorActionPreference='Stop'
$testPath='C:\Repos\ai-agent-dotfiles\tests\canonical-hard-kill.tests.ps1'
$testSource=[IO.File]::ReadAllText($testPath)
$tokens=$null;$errors=$null
$testAst=[Management.Automation.Language.Parser]::ParseInput($testSource,[ref]$tokens,[ref]$errors)
$fn=@($testAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Test-HardKillPreimageProvenanceContract'},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$testAst.EndBlock)})
# 把 catch 改为 rethrow
$v=[string]$fn[0].Extent.Text
$old='}catch{$result.ErrorCodes=@([string]$_.Exception.Message)}'
if($v.IndexOf($old,[StringComparison]::Ordinal) -lt 0){throw 'catch anchor missing'}
$v=$v.Replace($old,'}catch{Write-Host ("POS: "+$_.InvocationInfo.PositionMessage);Write-Host ("LINE: "+$_.InvocationInfo.ScriptLineNumber); throw}')
Invoke-Expression $v
foreach($name in @('Get-HardKillTokenFingerprint','Get-HardKillAstTextCompact','Get-NearestHardKillFunction','Get-HardKillCommandArguments')){
    $m=@($testAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$testAst.EndBlock)})
    Invoke-Expression $m[0].Extent.Text
}
try{
    $hostSource=[IO.File]::ReadAllText('C:\Repos\ai-agent-dotfiles\tests\helpers\canonical-hard-kill-host.ps1')
    $r=Test-HardKillPreimageProvenanceContract -HostSource $hostSource
    "Valid=$($r.Valid)"
}catch{
    "THREW: $($_.Exception.Message)"
}
