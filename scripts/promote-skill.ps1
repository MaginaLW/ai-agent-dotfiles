#requires -Version 7.0
[CmdletBinding()]
param(
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [Parameter(Mandatory)] [string] $InputSkillPath,
    [Parameter(Mandatory)] [ValidateSet('shared', 'claude-only', 'codex-only', 'reasonix-only')] [string] $TargetType,
    [string] $PlanPath,
    [switch] $Apply,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

. (Join-Path $PSScriptRoot 'canonical-skill-adapter-common.ps1')
$ToolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'canonical-command-result.ps1')
$failureMessageId = 'canonical-command-failed'

try {
    $RepoRoot = Resolve-RepoRoot -RepoRoot $RepoRoot
    $InputSkillPath = (Resolve-Path -LiteralPath $InputSkillPath).Path
    if ([bool]$DryRun -eq [bool]$Apply) { throw 'Specify exactly one of -DryRun or -Apply.' }
    if ([string]::IsNullOrWhiteSpace($PlanPath)) { throw 'Promote requires -PlanPath; interactive parameter prompting is disabled.' }
    if ($Apply) { $failureMessageId = 'canonical-plan-not-found' }
    Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf:$DryRun | Out-Null
    if ($DryRun -and (Test-Path -LiteralPath $PlanPath)) { throw 'DryRun PlanPath must be create-new.' }
    if ($Apply -and -not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) { throw 'Apply requires an existing reviewed PlanPath.' }
    $failureMessageId = 'canonical-command-failed'

    if ($Apply) {
        $failureMessageId = 'canonical-plan-stale'
        $null = Assert-CanonicalSingleReplacementPlanBinding -RepoRoot $RepoRoot -PlanPath $PlanPath -OperationKind promote -InputSkillPath $InputSkillPath -TargetType $TargetType
        $failureMessageId = 'canonical-command-failed'
        $child = Invoke-CanonicalTransactionChild -RepoRoot $RepoRoot -OperationKind promote -Mode Apply -PlanPath $PlanPath
        Write-CanonicalTransactionChildOutput -Child $child
        exit $child.ExitCode
    }

    $name = Get-SkillName -SkillPath $InputSkillPath
    $existing = @()
    foreach ($type in @('shared', 'claude-only', 'codex-only', 'reasonix-only')) {
        $existingPath = Join-RepoPath -RepoRoot $RepoRoot -RelativePath "skills-source/$type/$name"
        if (Test-Path -LiteralPath (Join-Path $existingPath 'SKILL.md')) {
            $existing += $existingPath
        }
    }
    if ($existing.Count -gt 0) {
        $messageId = 'canonical-retained'
        $resultDocument = New-CanonicalPublicCommandResult -Result WARN -CommandKind canonical-promote -MessageToken $messageId
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        [Console]::Error.WriteLine($messageId)
        exit 3
    }

    $failureMessageId = 'canonical-candidate-failed'
    $workspace = New-CanonicalAdapterWorkspace -RepoRoot $RepoRoot
    $batch = New-CanonicalBatchCandidateWorkspace -RepoRoot $RepoRoot -CandidateWorkspace $workspace -Proposals @(
        [ordered]@{InputSkillPath=$InputSkillPath;TargetType=$TargetType}
    )
    if ([string]$batch.Status -cne 'candidate') {
        $token = [string] $batch.Reason
        $resultDocument = New-CanonicalPublicCommandResult -Result FAIL -CommandKind canonical-promote -MessageToken $token
        Write-CanonicalPublicCommandResult -Document $resultDocument -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath
        [Console]::Error.WriteLine($token)
        exit 2
    }
    $failureMessageId = 'canonical-command-failed'
    $preflightRoot = [IO.Path]::GetFullPath($PlanPath + '.preflight')
    $child = Invoke-CanonicalTransactionChild -RepoRoot $RepoRoot -OperationKind promote -Mode DryRun -PlanPath $PlanPath `
        -CandidateWorkspace $workspace -InputPath $InputSkillPath -RewriteList @($batch.RewriteList) -CanonicalPreflightOutputRoot $preflightRoot
    Write-CanonicalTransactionChildOutput -Child $child
    exit $child.ExitCode
}
catch {
    $failure = Write-CanonicalPublicCommandFailure -Exception $_.Exception -CommandKind canonical-promote -ToolchainRoot $ToolchainRoot -ValidationPath $PSCommandPath -FallbackMessageToken $failureMessageId
    exit ([int] $failure.ExitCode)
}
