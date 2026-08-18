$ErrorActionPreference='Stop'
$refDir=Join-Path $env:TEMP 'provenance-refs'
$hostPath='C:\Repos\ai-agent-dotfiles\tests\helpers\canonical-hard-kill-host.ps1'
$text=[IO.File]::ReadAllText($hostPath)
$prod='$null=Initialize-CanonicalTransactionPreimages -TransactionNamespace $namespace'
if($text.IndexOf($prod,[StringComparison]::Ordinal) -lt 0){throw 'production call anchor missing'}
$selectedLine='$sealedPreimageSelected=$Checkpoint -ceq ' + "‘before-preimage-copy’" + ' -or $Checkpoint -ceq ' + "‘after-preimage-copy’" + ' -or $Checkpoint -ceq ' + "‘during-preimage-copy’"
# 用正规引号重建（上面故意不用弯引号——直接写死单引号版本）
$selectedLine='$sealedPreimageSelected=$Checkpoint -ceq ' + [char]39 + 'before-preimage-copy' + [char]39 + ' -or $Checkpoint -ceq ' + [char]39 + 'after-preimage-copy' + [char]39 + ' -or $Checkpoint -ceq ' + [char]39 + 'during-preimage-copy' + [char]39
"selected line: $selectedLine"
$bindings=@(
'$normalSetupPaths=@($FixtureRoot,$TransactionId)',
('foreach' + [char]36 + 'normalSetupPath in ' + [char]36 + 'normalSetupPaths){if([string]::IsNullOrWhiteSpace([string]' + [char]36 + 'normalSetupPath)){throw ' + [char]39 + 'normal preimage setup input is missing' + [char]39 + '}}'),
'$namespace=Join-Path $paths.TransactionsRoot (Join-Path $git.WorktreeId $TransactionId)',
'$targetId=Get-CanonicalJournalTargetId -Order 0 -TargetKind $targetKind -Role $role -Platform $platform -TargetPath $targetPath',
([IO.File]::ReadAllText((Join-Path $refDir 'normalTargetSource.txt'))).TrimEnd(),
$selectedLine,
'$sealedStageArguments=@($MutationEnginePath,$ExpectedEngineSha256,$SealedInvocationFixturePath,$SealedInvocationFixtureSha256)',
'$sealedStageArgumentCount=[int](-not[string]::IsNullOrWhiteSpace([string]$MutationEnginePath))+[int](-not[string]::IsNullOrWhiteSpace([string]$ExpectedEngineSha256))+[int](-not[string]::IsNullOrWhiteSpace([string]$SealedInvocationFixturePath))+[int](-not[string]::IsNullOrWhiteSpace([string]$SealedInvocationFixtureSha256))',
('if((' + [char]36 + 'sealedPreimageSelected -and ' + [char]36 + 'sealedStageArgumentCount -ne 4) -or (-not ' + [char]36 + 'sealedPreimageSelected -and ' + [char]36 + 'sealedStageArgumentCount -ne 0)){throw ' + [char]39 + 'sealed preimage stage arguments must be all present or all absent' + [char]39 + '}')
)
$selectedOwner=([IO.File]::ReadAllText((Join-Path $refDir 'selectedOwnerSource.txt'))).TrimEnd()
$block=($bindings -join "`n")+"`n"+$selectedOwner+"`n"+$prod
$text=$text.Replace($prod,$block)
[IO.File]::WriteAllText($hostPath,$text)
'bindings + selectedOwner + production inserted'
