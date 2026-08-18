$ErrorActionPreference='Stop'
$testPath='C:\Repos\ai-agent-dotfiles\tests\canonical-hard-kill.tests.ps1'
$testSource=[IO.File]::ReadAllText($testPath)
$tokens=$null;$errors=$null
$testAst=[Management.Automation.Language.Parser]::ParseInput($testSource,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'test parse error'}
foreach($name in @('Get-HardKillTokenFingerprint','Get-HardKillAstTextCompact','Get-NearestHardKillFunction','Get-HardKillCommandArguments')){
    $m=@($testAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$testAst.EndBlock)})
    if($m.Count -ne 1){throw "checker ${name}: $($m.Count)"}
    Invoke-Expression $m[0].Extent.Text
}
$fn=@($testAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Test-HardKillPreimageProvenanceContract'},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$testAst.EndBlock)})
if($fn.Count -ne 1){throw 'contract fn count'}
Invoke-Expression $fn[0].Extent.Text
$hostSource=[IO.File]::ReadAllText('C:\Repos\ai-agent-dotfiles\tests\helpers\canonical-hard-kill-host.ps1')
$r=Test-HardKillPreimageProvenanceContract -HostSource $hostSource
[pscustomobject]@{
    Valid=$r.Valid
    ErrorCodes=@($r.ErrorCodes)
    RealHelper=$r.RealHelperCount
    PartialHelper=$r.PartialHelperCount
}|ConvertTo-Json -Depth 3
