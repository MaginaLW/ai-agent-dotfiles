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
$interstitial=if($probeRouteIndex -ge 0 -and $selectedOwnerIndex -gt $probeRouteIndex+1){@($rootStatements[($probeRouteIndex+1)..($selectedOwnerIndex-1)])}else{@()}
$productionLoaderSource=". (Microsoft.PowerShell.Management\Join-Path `$ToolchainRoot 'scripts/canonical-recovery-common.ps1')"
$reviewedSetupCommands=@('Set-StrictMode','Join-Path','Write-SemanticJson','Exit-CanonicalRepoLock','Get-CanonicalGitContext','Get-CanonicalTransactionContractPaths','New-CanonicalSetupPlanPayload','New-CanonicalFinalSetupState','Enter-CanonicalRepoLock','Set-CurrentUserOnlyAcl','Write-Utf8','Get-CanonicalJournalTargetId','Get-SafeTreeSnapshot','Get-CanonicalObservedPathState','Resolve-TargetContext','Get-CanonicalRepoIdentity','New-CanonicalJournalHeader','Split-Path','Test-Path','Out-Null')
$unreviewedSetup=@($interstitial|Where-Object{$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}|ForEach-Object{
    @($_.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|Where-Object{
        if($_.InvocationOperator -eq [Management.Automation.Language.TokenKind]::Dot -and (Get-HardKillTokenFingerprint -Source ([string]$_.Parent.Extent.Text)) -ceq (Get-HardKillTokenFingerprint -Source $productionLoaderSource)){return $false}
        $name=[string]$_.GetCommandName();$leaf=if($name.Contains('\')){$name.Substring($name.LastIndexOf('\')+1)}else{$name}
        $leaf -cnotin $reviewedSetupCommands
    })
}|Where-Object{$null -ne $_})
"unreviewedSetupCommands: $($unreviewedSetup.Count)"
foreach($u in $unreviewedSetup){ "  line $($u.Extent.StartLineNumber): $(([string]$u.Extent.Text).Substring(0,[Math]::Min(90,([string]$u.Extent.Text).Length)))" }
