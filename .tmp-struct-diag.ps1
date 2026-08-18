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
# 顶层语句与结构定位
$rootStatements=@($ast.EndBlock.Statements)
$probeRouteSource=@'
if($ContractProbe){
    Invoke-SealedMutationContractProbe -ContractProbeRequestPath $ContractProbeRequestPath -ContractProbeRequestSha256 $ContractProbeRequestSha256 -MutationEnginePath $MutationEnginePath -ExpectedEngineSha256 $ExpectedEngineSha256 -ExpectedProbeHostSha256 $ExpectedProbeHostSha256 -ContractProbeResultPath $ContractProbeResultPath -ContractProbeScratchRoot $ContractProbeScratchRoot
    return
}
'@
$probeRouteSource=$probeRouteSource.TrimEnd()
$selectedOwnerSource=([IO.File]::ReadAllText((Join-Path $env:TEMP 'provenance-refs\selectedOwnerSource.txt'))).TrimEnd()
$probeRoutes=@($rootStatements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and
    (Get-HardKillTokenFingerprint -Source ([string]$_.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $probeRouteSource)})
$selectedOwners=@($rootStatements|Where-Object{$_ -is [Management.Automation.Language.IfStatementAst] -and
    (Get-HardKillTokenFingerprint -Source ([string]$_.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $selectedOwnerSource)})
"probeRoutes: $($probeRoutes.Count) selectedOwners: $($selectedOwners.Count)"
if($probeRoutes.Count -eq 1 -and $selectedOwners.Count -eq 1){
    $selectedOwnerIndex=[Array]::IndexOf($rootStatements,$selectedOwners[0])
    $probeRouteIndex=[Array]::IndexOf($rootStatements,$probeRoutes[0])
    "probeRouteIndex: $probeRouteIndex selectedOwnerIndex: $selectedOwnerIndex"
    $interstitial=if($probeRouteIndex -ge 0 -and $selectedOwnerIndex -gt $probeRouteIndex+1){@($rootStatements[($probeRouteIndex+1)..($selectedOwnerIndex-1)])}else{@()}
    "interstitial statements: $($interstitial.Count)"
    $interstitial|ForEach-Object{ "  [{0}] {1}" -f $_.GetType().Name.Replace('StatementAst',''), ([string]$_.Extent.Text).Substring(0,[Math]::Min(70,([string]$_.Extent.Text).Length)).Replace("`n",' ') }
}
