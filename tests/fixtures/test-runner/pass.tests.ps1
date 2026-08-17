#requires -Version 7.0
Write-Host 'fixture pass'
Write-Output "fixture-inherited=$env:AI_AGENT_DOTFILES_RUNNER_INHERITED"
Write-Output "fixture-override=$env:AI_AGENT_DOTFILES_RUNNER_OVERRIDE"
Write-Output "fixture-working-directory=$((Get-Location).Path)"
exit 0
