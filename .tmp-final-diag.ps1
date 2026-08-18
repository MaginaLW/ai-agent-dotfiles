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
$rootStatements=@($ast.EndBlock.Statements)
$selectedOwnerSource=([IO.File]::ReadAllText((Join-Path $env:TEMP 'provenance-refs\selectedOwnerSource.txt'))).TrimEnd()
$selectedOwners=@($rootStatements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and (Get-HardKillTokenFingerprint -Source ([string]$_.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $selectedOwnerSource)})
$probeRouteSource=(Get-Content (Join-Path $env:TEMP 'provenance-refs\probeRouteSource.txt') -Raw).TrimEnd()
$probeRoutes=@($rootStatements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and (Get-HardKillTokenFingerprint -Source ([string]$_.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $probeRouteSource)})
$selectedOwnerIndex=[Array]::IndexOf($rootStatements,$selectedOwners[0])
$probeRouteIndex=[Array]::IndexOf($rootStatements,$probeRoutes[0])
"probeRouteIndex=$probeRouteIndex selectedOwnerIndex=$selectedOwnerIndex selectedOwners=$($selectedOwners.Count)"
$rootProductionCalls=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Initialize-CanonicalTransactionPreimages'},$true)|Where-Object{$null -eq (Get-NearestHardKillFunction $_)})
"rootProductionCalls: $($rootProductionCalls.Count)"
$productionOwner=$rootProductionCalls[0]
while($null -ne $productionOwner.Parent -and -not[object]::ReferenceEquals($productionOwner.Parent,$ast.EndBlock)){$productionOwner=$productionOwner.Parent}
$productionIndex=[Array]::IndexOf($rootStatements,$productionOwner)
"productionIndex=$productionIndex need=$($selectedOwnerIndex+1)"
$rootProductionText='$null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $namespace'
"productionOwner fingerprint match: $((Get-HardKillTokenFingerprint -Source ([string]$productionOwner.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $rootProductionText))"
$interstitial=if($probeRouteIndex -ge 0 -and $selectedOwnerIndex -gt $probeRouteIndex+1){@($rootStatements[($probeRouteIndex+1)..($selectedOwnerIndex-1)])}else{@()}
$reviewedDirectCommands=@('Set-StrictMode','Write-SemanticJson','Exit-CanonicalRepoLock')
$unreviewedDirect=@($interstitial|Where-Object{$_ -is [Management.Automation.Language.PipelineAst]}|ForEach-Object{
    $p=$_
    if($p.PipelineElements.Count -eq 1 -and $p.PipelineElements[0] -is [Management.Automation.Language.CommandAst]){
        $c=$p.PipelineElements[0]
        if($c.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot){return $null}
        if($c.GetCommandName() -cin $reviewedDirectCommands){return $null}
        return $p
    }
    return $p
}|Where-Object{$null -ne $_})
"unreviewedDirectCommands: $($unreviewedDirect.Count)"
foreach($u in $unreviewedDirect){ "  line $($u.Extent.StartLineNumber): $(([string]$u.Extent.Text).Substring(0,[Math]::Min(80,([string]$u.Extent.Text).Length)))" }
