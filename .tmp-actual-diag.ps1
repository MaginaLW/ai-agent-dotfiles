$ErrorActionPreference='Stop'
$path='C:\Repos\ai-agent-dotfiles\tests\canonical-hard-kill.tests.ps1'
$source=[IO.File]::ReadAllText($path)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw $errors[0]}
$names=@('Get-HardKillCommandArguments','Get-HardKillAstTextCompact','Get-HardKillTokenFingerprint','Get-NearestHardKillFunction','Test-HardKillPreimageControllerTransportContract')
foreach($name in $names){
    $m=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq$name},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$ast.EndBlock)})
    if($m.Count -ne 1){throw "function:${name}:$($m.Count)"}
    Invoke-Expression $m[0].Extent.Text
}
$r=Test-HardKillPreimageControllerTransportContract -ControllerSource $source -Profile Actual
[pscustomobject]@{
    Valid=$r.Valid
    ErrorCodes=@($r.ErrorCodes)
    OwnerCount=$r.OwnerCount
    RouteCount=$r.RouteCount
    SelectedBranchCount=$r.SelectedBranchCount
    ForwardLoopCount=$r.ForwardLoopCount
    SectionGuardCount=$r.SectionGuardCount
    RuntimeGateCount=$r.RuntimeGateCount
    CaseSourceCount=$r.CaseSourceCount
}|ConvertTo-Json -Depth 3
