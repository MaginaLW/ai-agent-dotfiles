$ErrorActionPreference='Stop'
$testPath='C:\Repos\ai-agent-dotfiles\tests\canonical-hard-kill.tests.ps1'
$testSource=[IO.File]::ReadAllText($testPath)
$tokens=$null;$errors=$null
$testAst=[Management.Automation.Language.Parser]::ParseInput($testSource,[ref]$tokens,[ref]$errors)
foreach($name in @('Get-HardKillTokenFingerprint','Get-HardKillAstTextCompact','Get-NearestHardKillFunction','Get-HardKillCommandArguments')){
    $m=@($testAst.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$testAst.EndBlock)})
    Invoke-Expression $m[0].Extent.Text
}
$hostSource=[IO.File]::ReadAllText('C:\Repos\ai-agent-dotfiles\tests\helpers\canonical-hard-kill-host.ps1')
$ht=$null;$he=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($hostSource,[ref]$ht,[ref]$he)
# 复刻 shadow 检查
$productionLoaderSource=". (Microsoft.PowerShell.Management\Join-Path `$ToolchainRoot 'scripts/canonical-recovery-common.ps1')"
$normalEngineLoaderSource='. $normalEnginePath'
$shadowCommandNames=@('Set-Alias','New-Alias','Import-Alias','Remove-Alias','Import-Module','New-Module','Remove-Module','Set-Item','New-Item','Clear-Item','Remove-Item')
$shadowCommands=@($ast.FindAll({param($node)
    if($node -isnot [Management.Automation.Language.CommandAst]){return $false}
    $name=[string]$node.GetCommandName();$leaf=if($name.Contains('\')){$name.Substring($name.LastIndexOf('\')+1)}else{$name}
    $owner=Get-NearestHardKillFunction $node
    $reviewedRootLoader=$null -eq $owner -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and
        (Get-HardKillTokenFingerprint -Source ([string]$node.Parent.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $productionLoaderSource)
    $reviewedEngineLoader=$null -eq $owner -and $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and
        (Get-HardKillTokenFingerprint -Source ([string]$node.Parent.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $normalEngineLoaderSource)
    return $node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Ampersand -or
        ($node.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and -not $reviewedRootLoader -and -not $reviewedEngineLoader -and ($null -eq $owner -or $leaf -cin $shadowCommandNames))
},$true))
"shadow count: $($shadowCommands.Count)"
foreach($c in $shadowCommands){
    "  line $($c.Extent.StartLineNumber): $($c.Extent.Text.Substring(0,[Math]::Min(120,$c.Extent.Text.Length)))"
}
