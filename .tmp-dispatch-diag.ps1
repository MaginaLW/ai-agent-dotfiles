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
$dispatcherSource=@'
if($Checkpoint -ceq 'before-preimage-copy' -or $Checkpoint -ceq 'after-preimage-copy'){
    Invoke-HardKillRealPreimageCheckpoint -TransactionNamespace $namespace -Target $script:target -InvocationContext $InvocationContext
}elseif($Checkpoint -ceq 'during-preimage-copy'){
    Invoke-HardKillRetainedPartialPreimageFixture -TransactionNamespace $namespace -Target $script:target -InvocationContext $InvocationContext
}
'@
$dispatcherSource=$dispatcherSource.TrimEnd()
$dispatchers=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and
    (Get-HardKillTokenFingerprint -Source ([string]$node.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $dispatcherSource)},$true)|
    Where-Object{$null -eq (Get-NearestHardKillFunction $_)})
"dispatchers: $($dispatchers.Count)"
$rootHelperCalls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and
    $node.GetCommandName() -cin @('Invoke-HardKillRealPreimageCheckpoint','Invoke-HardKillRetainedPartialPreimageFixture')},$true)|Where-Object{$null -eq (Get-NearestHardKillFunction $_)})
"rootHelperCalls: $($rootHelperCalls.Count)"
foreach($c in $rootHelperCalls){
    "  line $($c.Extent.StartLineNumber): $($c.Extent.Text.Substring(0,[Math]::Min(90,$c.Extent.Text.Length)))"
}
if($dispatchers.Count -eq 1){
    foreach($c in $rootHelperCalls){
        $cursor=$c.Parent;$inside=$false
        while($null -ne $cursor){if([object]::ReferenceEquals($cursor,$dispatchers[0])){$inside=$true;break};$cursor=$cursor.Parent}
        "  inside dispatcher: $inside"
    }
}
