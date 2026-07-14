#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$pass = 0
$fail = 0
function Assert([bool] $Condition, [string] $Message) {
    if ($Condition) { $script:pass++; Write-Host "  PASS  $Message" -ForegroundColor Green }
    else { $script:fail++; Write-Host "  FAIL  $Message" -ForegroundColor Red }
}
function Set-FixtureFile([string] $Path, [AllowNull()][string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    Set-Content -LiteralPath $Path -Value ($Content ?? '') -Encoding UTF8 -NoNewline
}
function Invoke-Fixture([string] $Script, [string[]] $ScriptArguments = @()) {
    $out = & pwsh -NoProfile -File $Script @ScriptArguments 2>&1 | Out-String
    return @{ Code = $LASTEXITCODE; Out = $out }
}

$work = Join-Path $RepoRoot 'tmp/mcp-tests'
if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
New-Item -ItemType Directory -Path $work -Force | Out-Null
$fakeRepo = Join-Path $work 'repo'
$fakeHome = Join-Path $work 'home'
$state = Join-Path $work 'fake-cli-state.json'
$cli = Join-Path $work 'fake-claude.ps1'
$script = Join-Path $RepoRoot 'claude/mcp/apply-mcp.ps1'

Copy-Item -LiteralPath (Join-Path $RepoRoot 'harness-source/components/mcp-templates') -Destination (Join-Path $fakeRepo 'harness-source/components/mcp-templates') -Recurse -Force
Set-FixtureFile -Path $cli -Content @'
param([Parameter(ValueFromRemainingArguments = $true)][string[]] $CliArguments)
$statePath = $env:MCP_FAKE_STATE
$state = if (Test-Path -LiteralPath $statePath) { Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json } else { [pscustomobject]@{ Servers = @() } }
$name = 'github'
if ($CliArguments.Count -ge 2 -and $CliArguments[0] -eq 'mcp' -and $CliArguments[1] -eq 'get') {
    if ($state.Servers -contains $name) { Write-Output ('{"name":"' + $name + '"}'); exit 0 }
    Write-Error 'server not found'
    exit 1
}
if ($CliArguments.Count -ge 2 -and $CliArguments[0] -eq 'mcp' -and $CliArguments[1] -eq 'remove') {
    $state.Servers = @($state.Servers | Where-Object { $_ -ne $name })
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    exit 0
}
if ($CliArguments.Count -ge 2 -and $CliArguments[0] -eq 'mcp' -and $CliArguments[1] -eq 'add') {
    if ($env:MCP_FAKE_FAIL_ADD -eq '1') { Write-Error 'simulated add failure'; exit 7 }
    $state.Servers = @($state.Servers | Where-Object { $_ -ne $name }) + $name
    $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
    exit 0
}
Write-Error 'unsupported fake CLI operation'
exit 9
'@
Set-FixtureFile -Path $state -Content '{"Servers":[]}'
$oldToken = [Environment]::GetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN')
$oldFail = [Environment]::GetEnvironmentVariable('MCP_FAKE_FAIL_ADD')
[Environment]::SetEnvironmentVariable('MCP_FAKE_STATE', $state)
[Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', 'mcp-test-secret-value')
[Environment]::SetEnvironmentVariable('MCP_FAKE_FAIL_ADD', $null)

try {
    Write-Host '[MCP dry-run/apply/update/remove]'
    $plan = Join-Path $work 'add-plan.json'
    $summary = Join-Path $work 'add-summary.json'
    $dry = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', $plan, '-JsonPath', $summary)
    Assert ($dry.Code -eq 0 -and $dry.Out -match 'action=add') 'dry-run creates an add plan'
    $planText = Get-Content -Raw -LiteralPath $plan
    $planDoc = $planText | ConvertFrom-Json
    Assert ($planDoc.SchemaVersion -eq 1 -and $planDoc.PlanKind -eq 'mcp-operation' -and $planDoc.PlanHash -match '^[A-Fa-f0-9]{64}$') 'MCP plan has the machine-readable contract'
    $summaryDoc = Get-Content -Raw -LiteralPath $summary | ConvertFrom-Json
    Assert ($summaryDoc.SchemaVersion -eq 1 -and $summaryDoc.Result -eq 'DRY-RUN') 'MCP summary has the machine-readable contract'
    Assert ($planText -notmatch 'mcp-test-secret-value') 'plan does not contain environment values'
    Assert ($dry.Out -notmatch 'mcp-test-secret-value') 'dry-run output redacts environment values'

    $applied = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Apply', '-PlanPath', $plan)
    Assert ($applied.Code -eq 0) 'apply registers one server through the CLI'
    $stateObject = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
    Assert (@($stateObject.Servers) -contains 'github') 'fake CLI records the registered server'
    Assert ($applied.Out -notmatch 'mcp-test-secret-value') 'apply output redacts environment values'
    Assert (@(Get-ChildItem -LiteralPath (Join-Path $fakeHome '.ai-agent-dotfiles-mcp-backups') -Recurse -Filter operation.json).Count -gt 0) 'apply writes repo-external operation evidence'

    $updatePlan = Join-Path $work 'update-plan.json'
    $updateDry = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', $updatePlan)
    Assert ($updateDry.Code -eq 0 -and $updateDry.Out -match 'action=update') 'existing server receives an update plan'
    $updated = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Apply', '-PlanPath', $updatePlan)
    Assert ($updated.Code -eq 0) 'update uses CLI remove/add semantics'

    $driftPlan = Join-Path $work 'drift-plan.json'
    $driftDry = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', $driftPlan)
    $templatePath = Join-Path $fakeRepo 'harness-source/components/mcp-templates/github/template.psd1'
    $templateText = Get-Content -Raw -LiteralPath $templatePath
    Set-FixtureFile -Path $templatePath -Content ($templateText + "`n# drift")
    $driftApply = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Apply', '-PlanPath', $driftPlan)
    Assert ($driftApply.Code -ne 0 -and $driftApply.Out -match 'drift|hash') 'template drift blocks apply'
    Set-FixtureFile -Path $templatePath -Content $templateText

    $removePlan = Join-Path $work 'remove-plan.json'
    $removeDry = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Remove', '-DryRun', '-PlanPath', $removePlan)
    Assert ($removeDry.Code -eq 0 -and $removeDry.Out -match 'action=remove') 'remove creates an explicit removal plan'
    $removed = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Remove', '-Apply', '-PlanPath', $removePlan)
    Assert ($removed.Code -eq 0) 'remove uses the CLI'
    $stateObject = Get-Content -Raw -LiteralPath $state | ConvertFrom-Json
    Assert (@($stateObject.Servers).Count -eq 0) 'remove leaves the server absent'

    Write-Host '[MCP safety and partial failure]'
    [Environment]::SetEnvironmentVariable('MCP_FAKE_FAIL_ADD', '1')
    $partialPlan = Join-Path $work 'partial-plan.json'
    $partialDry = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', $partialPlan)
    $partial = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Apply', '-PlanPath', $partialPlan)
    Assert ($partial.Code -ne 0) 'CLI failure returns non-zero'
    $failureFiles = @(Get-ChildItem -LiteralPath (Join-Path $fakeHome '.ai-agent-dotfiles-mcp-backups') -Recurse -Filter failure.json -File)
    $hasFailureEvidence = $failureFiles.Count -gt 0
    Assert $hasFailureEvidence 'CLI failure leaves partial-operation evidence'
    if ($hasFailureEvidence) {
        $failureText = Get-Content -Raw -LiteralPath $failureFiles[-1].FullName
        Assert ($failureText -notmatch 'mcp-test-secret-value') 'failure evidence redacts environment values'
    }
    [Environment]::SetEnvironmentVariable('MCP_FAKE_FAIL_ADD', $null)

    $missingPlan = Join-Path $work 'missing-plan.json'
    [Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', $null)
    $missingDry = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', $missingPlan)
    Assert ($missingDry.Code -eq 0 -and $missingDry.Out -match 'Missing environment variables') 'missing environment variable is reported in dry-run'
    $missingApply = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-Apply', '-PlanPath', $missingPlan)
    Assert ($missingApply.Code -ne 0 -and $missingApply.Out -match 'missing') 'missing environment variable blocks apply'

    $badDir = Join-Path $fakeRepo 'harness-source/components/mcp-templates/bad'
    Set-FixtureFile -Path (Join-Path $badDir 'template.psd1') -Content @'
@{
    SchemaVersion = 1
    Id = 'bad'
    Command = 'npx'
    Args = @('../escape')
    RequiredEnv = @()
    Env = @{}
}
'@
    $bad = Invoke-Fixture $script @('-TemplateId', 'bad', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeHome, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', (Join-Path $work 'bad-plan.json'))
    Assert ($bad.Code -ne 0) 'unsafe template path is rejected'
    $insideRepo = Invoke-Fixture $script @('-TemplateId', 'github', '-RepoRoot', $fakeRepo, '-HomeRoot', $fakeRepo, '-ClaudeCommand', $cli, '-DryRun', '-PlanPath', (Join-Path $work 'inside-repo-plan.json'))
    Assert ($insideRepo.Code -ne 0) 'repo-local HomeRoot is rejected'
}
finally {
    [Environment]::SetEnvironmentVariable('GITHUB_PERSONAL_ACCESS_TOKEN', $oldToken)
    [Environment]::SetEnvironmentVariable('MCP_FAKE_FAIL_ADD', $oldFail)
    [Environment]::SetEnvironmentVariable('MCP_FAKE_STATE', $null)
}

if ($fail -gt 0) { Write-Host "Results: $pass passed, $fail failed" -ForegroundColor Red; throw 'MCP regression failed.' }
Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Results: $pass passed, $fail failed" -ForegroundColor Green
