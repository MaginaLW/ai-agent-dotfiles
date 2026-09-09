#requires -Version 7.0
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SandboxRoot,
    [Parameter(Mandatory)] [string] $ScriptPath,
    [Parameter(Mandatory)] [string] $ArgumentsBase64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $scriptsRoot 'live-safety-interlock.ps1')
$sandbox = (Resolve-Path -LiteralPath $SandboxRoot).Path
$scriptFull = (Resolve-Path -LiteralPath $ScriptPath).Path
$scriptAllowed = (Test-LiveSafetyPathInsideRoot -Path $scriptFull -Root $scriptsRoot) -or (Test-LiveSafetyPathInsideRoot -Path $scriptFull -Root $sandbox)
if (-not $scriptAllowed) { throw "Internal host refuses script outside the authority or sandbox: $scriptFull" }

$json = [System.Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String($ArgumentsBase64))
$decodedArguments = ConvertFrom-Json -InputObject $json
$arguments = @($decodedArguments | ForEach-Object { [string] $_ })

$capability = New-LiveSafetySandboxCapability -SandboxRoot $sandbox
$previous = @{
    Root = $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT
    Path = $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH
    Token = $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN
    HomeRoot = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
    BackupRoot = $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT
    ControlBase = $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE
}
try {
    $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT = $capability.Root
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH = $capability.Path
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN = $capability.Token
    $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT = (Join-Path $capability.Root 'home')
    $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT = (Join-Path $capability.Root 'backups')
    $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE = (Join-Path $capability.Root 'control')
    & pwsh -NoProfile -File $scriptFull @arguments
    $operationExitCode = $LASTEXITCODE
}
finally {
    $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT = $previous.Root
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH = $previous.Path
    $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN = $previous.Token
    $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT = $previous.HomeRoot
    $env:AI_AGENT_DOTFILES_INTERNAL_BACKUP_ROOT = $previous.BackupRoot
    $env:AI_AGENT_DOTFILES_INTERNAL_CONTROL_BASE = $previous.ControlBase
    $capability.Stream.Dispose()
    Remove-Item -LiteralPath $capability.Path -Force -ErrorAction SilentlyContinue
}
exit $operationExitCode
