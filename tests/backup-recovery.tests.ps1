#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-backup-recovery-$([Guid]::NewGuid().ToString('N'))"
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')
. (Join-Path $RepoRoot 'scripts/home-authority-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')
. (Join-Path $RepoRoot 'tests/helpers/safety-sandbox.ps1')

$script:pass = 0

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:pass++
    Write-Host "  PASS  $Message"
}

function Write-TextFile {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Content)
    $parent = Split-Path -Parent $Path
    New-Item -ItemType Directory -Force -Path $parent | Out-Null
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
}

try {
    Write-Host '[environment rollback surface]'
    $rollbackScript = Join-Path $RepoRoot 'scripts/rollback-harness-env.ps1'
    $cliScript = Join-Path $RepoRoot 'scripts/agent-dotfiles.ps1'
    $rollbackSource = [System.IO.File]::ReadAllText($rollbackScript)

    # The legacy selection surface is removed: only the receipt selects a
    # rollback, and the legacy switches must not reappear as parameters.
    $rollbackAst = [System.Management.Automation.Language.Parser]::ParseFile($rollbackScript, [ref] $null, [ref] $null)
    $rollbackParameters = @($rollbackAst.ParamBlock.Parameters | ForEach-Object { [string] $_.Name.VariablePath.UserPath })
    foreach ($name in @('ReceiptPath', 'DryRun', 'Apply', 'PlanPath', 'RepoRoot', 'JsonPath')) {
        Assert ($rollbackParameters -ccontains $name) "the rollback entry exposes the reviewed '$name' parameter"
    }
    foreach ($legacy in @('RunId', 'BackupPath', 'BackupRoot', 'HomeRoot')) {
        Assert (-not ($rollbackParameters -ccontains $legacy)) "the legacy '$legacy' selection is removed from the rollback entry"
    }
    Assert ($rollbackSource.Contains('rollback-source-kind-unsupported') -and $rollbackSource.Contains('live-rollback-dispatch-not-wired')) 'the rollback entry pins its reviewed failure tokens'

    # The wrapper keeps its mode gate before any forwarded work.
    function Invoke-CliArguments {
        param([Parameter(Mandatory)] [string] $ScriptPath, [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Arguments)
        $output = @(& pwsh -NoProfile -File $ScriptPath @Arguments 2>&1)
        return [pscustomobject]@{ Code = $LASTEXITCODE; Out = ($output -join "`n") }
    }
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('env')
    Assert ($r.Code -ne 0 -and $r.Out -match 'requires a sub-action') 'the env group requires a sub-action'
    $r = Invoke-CliArguments -ScriptPath $cliScript -Arguments @('env', 'rollback', '-ReceiptPath', (Join-Path $work 'absent'), '-PlanPath', (Join-Path $work 'plan.json'))
    Assert ($r.Code -ne 0 -and $r.Out -match 'requires an explicit -DryRun or -Apply') 'env rollback requires an explicit mode'

    New-Item -ItemType Directory -Force -Path $work | Out-Null
    function Invoke-RollbackDispatch {
        param([AllowEmptyCollection()] [string[]] $Arguments)
        return Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $rollbackScript -Arguments $Arguments -AuthorityRepoRoot $RepoRoot
    }

    # Sandbox gates: the authority gate precedes every receipt read.
    $absentReceipt = Join-Path $work 'absent-receipt'
    $absentPlan = Join-Path $work 'gated-plan.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $absentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-plan-authority-missing') 'the rollback route fails closed without a complete authority'
    Assert (-not (Test-Path -LiteralPath $absentPlan)) 'the authority gate writes no plan file'

    # Bootstrap the sandbox authority in its own process, mirroring the sync
    # and live-recovery parity fixtures.
    $setupScript = Join-Path $work 'setup-authority.ps1'
    Write-TextFile -Path $setupScript -Content @'
#requires -Version 7.0
param([string] $AuthorityRepo)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $AuthorityRepo 'scripts/json-artifact-common.ps1')
. (Join-Path $AuthorityRepo 'scripts/root-claims-registry-common.ps1')
$injectedHome = $env:AI_AGENT_DOTFILES_INTERNAL_HOME_ROOT
foreach ($folder in @((Join-Path $injectedHome 'AppData\Roaming'), (Join-Path $injectedHome 'AppData\Local'))) {
    if (-not (Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
}
$identity = [pscustomobject][ordered]@{
    ResolverVersion = 'windows-token-sid-known-folder-v1'
    TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    ProfileRoot = $injectedHome
    RoamingAppDataRoot = (Join-Path $injectedHome 'AppData\Roaming')
    LocalAppDataRoot = (Join-Path $injectedHome 'AppData\Local')
}
$context = Resolve-HomeAuthorityContextFromIdentity -Identity $identity
$intent = New-SealedHomeAuthorityBootstrapIntent -AuthorityContext $context -FilesystemCapabilityHash ('a' * 64)
$lock = Complete-SealedHomeAuthorityBootstrap -AuthorityContext $context -Intent $intent
try { if ($null -eq $lock) { throw 'bootstrap returned no lock' } }
finally { Exit-HomeAuthorityGlobalLiveLock -LockHandle $lock }
Write-Host 'rollback sandbox authority bootstrap complete'
'@
    $r = Invoke-SafetySandboxScript -SandboxRoot $work -ScriptPath $setupScript -Arguments @('-AuthorityRepo', $RepoRoot) -AuthorityRepoRoot $RepoRoot
    if ($r.Code -ne 0) { Write-Host '----- rollback sandbox setup output -----'; Write-Host $r.Out }
    Assert ($r.Code -eq 0) 'the rollback sandbox authority bootstrap succeeds'

    $controlBase = Join-Path (Join-Path $work 'home') 'AppData\Local\ai-agent-dotfiles\control'
    $backupRoot = Join-Path (Join-Path $work 'home') 'AppData\Local\ai-agent-dotfiles\backups'
    $authorityHome = Join-Path $work 'home'
    $authorityKey = Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain = 'ai-agent-dotfiles/home-authority/v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        HomeRootLocationKey = (ConvertTo-HomeAuthorityLocationKey -Path $authorityHome)
    })

    # Receipt preflight: missing, partial, and wrong source kind all fail
    # closed with their reviewed tokens, and a complete environment receipt
    # reaches the not-yet-wired transition stub.
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $absentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-missing') 'a missing receipt slot fails closed'

    $partialReceipt = Join-Path $work 'partial-receipt'
    New-Item -ItemType Directory -Force -Path (Join-Path $partialReceipt '_meta') | Out-Null
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $partialReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-receipt-not-complete.*PARTIAL') 'a partial receipt slot fails closed'

    function New-PreflightReceipt {
        param([Parameter(Mandatory)] [string] $SourceOperationKind, [Parameter(Mandatory)] [string] $Label)
        $root = Join-Path $work "preflight-$Label"
        $liveClaude = Join-Path $root 'live/claude/skills'
        foreach ($dir in @($liveClaude, (Join-Path $root 'live/codex/skills'), (Join-Path $root 'live/reasonix/skills'))) {
            New-Item -ItemType Directory -Force -Path $dir | Out-Null
        }
        Write-TextFile -Path (Join-Path $liveClaude 'kept/SKILL.md') -Content 'preflight-kept'
        $transactionId = [Guid]::NewGuid().ToString()
        $receiptId = [Guid]::NewGuid().ToString()
        $receiptPath = Join-Path $backupRoot $receiptId
        $platforms = @(
            [ordered]@{ Platform = 'Claude'; LiveRoot = $liveClaude; Targets = @([ordered]@{ Name = 'kept'; LivePath = (Join-Path $liveClaude 'kept'); PlannedTreeHash = (Get-SafeTreeSnapshot -Root (Join-Path $liveClaude 'kept')).TreeHash }) },
            [ordered]@{ Platform = 'Codex'; LiveRoot = (Join-Path $root 'live/codex/skills'); Targets = @() },
            [ordered]@{ Platform = 'Reasonix'; LiveRoot = (Join-Path $root 'live/reasonix/skills'); Targets = @() }
        )
        $receipt = Invoke-SealedManagedBackupReceipt -ReservationIntent ([ordered]@{
            TransactionId = $transactionId
            ReceiptId = $receiptId
            ReceiptPath = $receiptPath
        }) -SourceOperationKind $SourceOperationKind -PlanHash ('1' * 64) -DocumentHash ('2' * 64) -ExecutionContextHash ('3' * 64) -ControlBaseHash ('4' * 64) -FilesystemCapabilityHash ('5' * 64) -HomeAuthorityKey $authorityKey -BackupRoot $backupRoot -Platforms $platforms -ForbiddenRoots @()
        return [string] $receipt['ReceiptPath']
    }

    $retirementReceipt = New-PreflightReceipt -SourceOperationKind 'retirement' -Label 'retirement'
    Assert ((Get-SealedBackupReceiptSlotState -ReceiptPath $retirementReceipt) -ceq 'COMPLETE') 'the preflight fixture produces a complete receipt'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $retirementReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-kind-unsupported \(source=retirement\)') 'a retirement receipt cannot start an ordinary rollback'
    Assert (-not (Test-Path -LiteralPath $absentPlan)) 'a rejected source kind writes no plan'

    $initialReceipt = New-PreflightReceipt -SourceOperationKind 'initial' -Label 'initial'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $initialReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'rollback-source-kind-unsupported \(source=initial\)') 'an initial receipt cannot start an ordinary rollback'

    $environmentReceipt = New-PreflightReceipt -SourceOperationKind 'environment' -Label 'environment'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'live-rollback-dispatch-not-wired') 'a complete environment receipt reaches the reviewed transition stub'

    # -Apply stays behind the Phase 0 production interlock.
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-Apply', '-PlanPath', $absentPlan)
    Assert ($r.Code -ne 0 -and $r.Out -match 'safety-protocol-upgrade-required') 'the rollback Apply remains interlocked'

    # The plan path uses the shared private-artifact-path table: a plan path
    # inside the repository is rejected before any receipt work.
    $insideRepoPlan = Join-Path $RepoRoot 'rollback-plan-inside-repo.json'
    $r = Invoke-RollbackDispatch -Arguments @('-ReceiptPath', $environmentReceipt, '-DryRun', '-PlanPath', $insideRepoPlan)
    Assert ($r.Code -ne 0 -and $r.Out -notmatch 'live-rollback-dispatch-not-wired') 'a plan path inside the repository is rejected by the shared artifact-path table'
    Assert (-not (Test-Path -LiteralPath $insideRepoPlan)) 'the rejected plan path is never written'

    Write-Host 'backup recovery tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
