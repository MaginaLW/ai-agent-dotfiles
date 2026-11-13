#requires -Version 7.0
[CmdletBinding()]
param([string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$suiteRepo = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
. (Join-Path $suiteRepo 'scripts/antigravity-plugins.ps1')
$script:AgRealInventory = ${function:Get-AgInventory}
$suiteWork = Join-Path $suiteRepo ('tmp/tests/antigravity-plugins/' + [Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($suiteWork) | Out-Null
$script:AgTestAssertions = 0

function Assert-PluginTest([bool] $Condition, [string] $Message) {
    Assert-TestCondition -Condition $Condition -Message $Message
    $script:AgTestAssertions++
}
function Assert-PluginThrows([scriptblock] $Operation, [string] $Pattern, [string] $Message) {
    $failure = $null
    try { $null = & $Operation } catch { $failure = $_.Exception.Message }
    Assert-PluginTest ($null -ne $failure -and $failure -match $Pattern) $Message
}

# Exercise the actual native inventory parser, substituting only the approved
# fixture root after parsing. Never change HOME, USERPROFILE or native config.
function Get-AgInventory {
    $inventory = & $script:AgRealInventory
    $inventory.ConfigRoot = $script:AgTestNativeRoot
    return $inventory
}
function Invoke-SecretScanGate {
    param([string] $RepoRoot)
    $script:AgTestCanonicalScans++
    if ($script:AgTestFailScan -eq 'canonical') { throw 'fixture canonical scan failed' }
}
function Invoke-AgPackageScan {
    param([string] $Root)
    $script:AgTestPackageScans++
    if ($script:AgTestFailScan -eq 'package') { throw 'fixture package scan failed' }
}
function Invoke-AgNativeCommand {
    param([string[]] $Arguments)
    $script:AgTestTrace.Add(($Arguments -join ' '))
    if ($Arguments.Count -eq 1 -and $Arguments[0] -ceq '--version') {
        return @{ Code=0; Out=$script:AgTestVersion; Error='' }
    }
    if (($Arguments -join ' ') -ceq 'plugin list --json') {
        if ($script:AgTestFailList) { return @{ Code=1; Out=''; Error='fixture list unavailable' } }
        $json = if ($null -ne $script:AgTestListJson) { $script:AgTestListJson } else { ConvertTo-Json -InputObject @($script:AgTestPlugins) -Depth 20 -Compress }
        return @{ Code=0; Out=$json; Error='' }
    }
    if ($Arguments.Count -eq 5 -and $Arguments[0] -ceq 'plugin' -and $Arguments[1] -ceq 'validate' -and
        $Arguments[3] -ceq '--strict' -and $Arguments[4] -ceq '--json') {
        Assert-AgPlainPath $Arguments[2]
        if ($script:AgTestValidationHook) { & $script:AgTestValidationHook }
        return @{ Code=0; Out=(ConvertTo-Json -InputObject $script:AgTestValidation -Depth 20 -Compress); Error='' }
    }
    if ($Arguments.Count -eq 3 -and $Arguments[0] -ceq 'plugin' -and $Arguments[1] -ceq 'install') {
        $script:AgTestInstallCalls++
        $target = Join-Path $script:AgTestNativeRoot 'plugins/ai-agent-dotfiles'
        if ($script:AgTestInstallMode -eq 'wrong-path') { $target = Join-Path $script:AgTestNativeRoot 'unexpected/ai-agent-dotfiles' }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        if ($script:AgTestInstallMode -in @('partial-nonzero','partial-throw')) {
            [IO.Directory]::CreateDirectory($target) | Out-Null
            Copy-Item -LiteralPath (Join-Path $Arguments[2] 'plugin.json') -Destination $target
            if ($script:AgTestInstallMode -eq 'partial-throw') { throw 'fixture install transport exception' }
            return @{ Code=1; Out=''; Error='fixture partial write' }
        }
        Copy-SkillTree -SourceRoot $Arguments[2] -DestinationRoot $target
        $script:AgTestPlugins += @{ name='ai-agent-dotfiles'; path=$target; enabled=$true; version=$script:AgConfig.ManagedPlugin.Version }
        Set-TestFile -Path (Join-Path $script:AgTestNativeRoot 'config.json') -Content '{"plugins":{"ai-agent-dotfiles":{"enabled":true}}}'
        if ($script:AgTestInstallMode -eq 'extra-metadata') { Set-TestFile -Path (Join-Path $target 'native-generated.json') -Content '{}' }
        if ($script:AgTestInstallMode -eq 'unrelated-change') { $script:AgTestPlugins[0].enabled = -not $script:AgTestPlugins[0].enabled }
        if ($script:AgTestInstallMode -eq 'readback-fails') { $script:AgTestFailList=$true }
        return @{ Code=0; Out='fixture installed'; Error='' }
    }
    throw 'Unexpected native command: the fixture permits only version/list/strict validate/single install.'
}
function New-PluginFixture([string] $Name) {
    $root = Join-Path $suiteWork $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    foreach ($path in @('.gitleaks.toml','tools/gitleaks/gitleaks.lock.json','harness-source/antigravity/plugins.psd1')) {
        $destination = Join-Path $root $path
        [IO.Directory]::CreateDirectory((Split-Path -Parent $destination)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $suiteRepo $path) -Destination $destination
    }
    [IO.Directory]::CreateDirectory((Join-Path $root 'skills-source/shared')) | Out-Null
    foreach ($name in @('boring-engineering','git-review')) {
        Copy-SkillTree -SourceRoot (Join-Path $suiteRepo ('skills-source/shared/' + $name)) -DestinationRoot (Join-Path $root ('skills-source/shared/' + $name))
    }
    Set-TestFile -Path (Join-Path $root 'skills-source/shared/git-review/CREATION-LOG.md') -Content 'source only'
    Set-TestFile -Path (Join-Path $root 'skills-source/shared/unselected/SKILL.md') -Content 'unselected'
    $script:AgTestNativeRoot = Join-Path $root 'native-config'
    [IO.Directory]::CreateDirectory($script:AgTestNativeRoot) | Out-Null
    Set-TestFile -Path (Join-Path $script:AgTestNativeRoot 'config.json') -Content '{"plugins":{}}'
    $script:AgTestVersion='1.5.8'
    $script:AgTestPlugins=@()
    $script:AgTestListJson=$null
    $script:AgTestFailList=$false
    $script:AgTestInstallMode='success'
    $script:AgTestInstallCalls=0
    $script:AgTestCanonicalScans=0
    $script:AgTestPackageScans=0
    $script:AgTestFailScan=''
    $script:AgTestTrace=[Collections.Generic.List[string]]::new()
    $script:AgTestValidationHook=$null
    $script:AgTestValidation=@{ dir='fixture'; components=@{agents=0;hooks=0;mcpServers=0;rules=0;sidecars=0;skills=2}; findings=@(); agentPluginsSpec=$false }
    Initialize-AgPluginContext $root
    $script:AgNative='fixture-only'
    return $root
}
function Add-ExternalFixture {
    $path = Join-Path $script:AgTestNativeRoot 'plugins/unrelated'
    Set-TestFile -Path (Join-Path $path 'plugin.json') -Content '{"name":"unrelated","version":"2.0.0"}'
    $script:AgTestPlugins += @{ name='unrelated'; path=$path; enabled=$false; version='2.0.0'; source='https://example.org/plugin' }
    return $path
}
function Get-OnlyAttemptResult {
    $attempts = @(Get-ChildItem -LiteralPath $script:AgWork -Directory -Filter 'attempt-*')
    Assert-PluginTest ($attempts.Count -eq 1) 'exactly one attempt is retained without retry'
    return Read-AgJsonFile (Join-Path $attempts[0].FullName 'result.json')
}

try {
    Write-Host 'Antigravity: reproducible package and read-only planning'
    $root = New-PluginFixture 'package'
    $missing = Get-AgPluginPlan
    Assert-PluginTest ($missing.Action -eq 'blocked' -and $missing.Reason -eq 'candidate-missing' -and -not (Test-Path $script:AgWork)) 'missing candidate status does not build or create management state'
    $first = New-AgPluginBuild
    $firstFiles = Get-AgTreeFiles $script:AgPackage
    $second = New-AgPluginBuild
    Assert-PluginTest ($first.Digest -ceq $second.Digest -and (Get-AgMapDigest $firstFiles) -ceq (Get-AgMapDigest (Get-AgTreeFiles $script:AgPackage))) 'identical inputs produce identical package files and digest'
    $skillDirs = @(Get-ChildItem (Join-Path $script:AgPackage 'skills') -Directory | Sort-Object Name | ForEach-Object Name)
    Assert-PluginTest (($skillDirs -join ',') -ceq 'boring-engineering,git-review') 'only the two reviewed canonical shared skills are packaged'
    Assert-PluginTest (-not (Test-Path (Join-Path $script:AgPackage 'skills/git-review/CREATION-LOG.md')) -and (Test-Path (Join-Path $script:AgPackage 'skills/boring-engineering/LICENSE'))) 'source-only creation log is excluded and license is preserved'
    $manifest = Read-AgJsonFile (Join-Path $script:AgPackage 'plugin.json')
    Assert-PluginTest (($manifest.Keys | Sort-Object) -join ',' -ceq '$schema,description,displayName,name,version') 'manifest contains only the reviewed metadata without extra components'
    Assert-PluginTest ($script:AgTestCanonicalScans -eq 2 -and $script:AgTestPackageScans -eq 2 -and $second.NativeValidation -eq 'PASS') 'both canonical inputs and final package pass gates on each build'
    Assert-PluginTest (-not (Test-Path (Join-Path $root 'claude')) -and -not (Test-Path (Join-Path $root 'codex')) -and -not (Test-Path (Join-Path $root 'manifests'))) 'plugin build does not create legacy outputs or change environment selections'
    $before = Get-AgMapDigest (Get-AgTreeFiles $root)
    $plan = Invoke-AgPluginDeploy
    Assert-PluginTest ($plan.Action -eq 'install' -and $plan.Changes.Added.Count -eq $firstFiles.Count -and $plan.Changes.Removed.Count -eq 0 -and $plan.NativeAction[1] -eq 'install') 'dry run describes first install and relative file additions'
    Assert-PluginTest ((Get-AgMapDigest (Get-AgTreeFiles $root)) -ceq $before -and $script:AgTestInstallCalls -eq 0) 'status and deployment preview make no fixture live or management-state changes'
    $script:AgTestVersion='1.5.9'
    Assert-PluginTest ((Get-AgPluginPlan).Reason -eq 'build-gates-incomplete-or-native-version-changed') 'native version changes invalidate the reviewed build'

    foreach ($gate in @('canonical','package')) {
        $null = New-PluginFixture ('scan-' + $gate)
        $script:AgTestFailScan=$gate
        Assert-PluginThrows { New-AgPluginBuild } 'scan failed' "$gate scan failure blocks publishing a candidate"
        Assert-PluginTest (-not (Test-Path $script:AgBuildReceipt) -and -not (Test-Path $script:AgPackage)) 'failed build writes no trusted build receipt or published package'
    }
    $null = New-PluginFixture 'native-unavailable'
    $script:AgNative=$null
    $build = New-AgPluginBuild
    Assert-PluginTest ($build.NativeValidation -eq 'UNKNOWN' -and (Get-AgPluginPlan).Action -eq 'blocked') 'build without agy remains unvalidated and cannot deploy'

    Write-Host 'Antigravity: reject unsafe selection, links and incompatible native data'
    foreach ($replacement in @("Skills = @('../git-review', 'boring-engineering')", "Skills = @('boring-engineering', 'boring-engineering')")) {
        $root = New-PluginFixture ('selection-' + [Guid]::NewGuid().ToString('N'))
        $config = Get-Content $script:AgConfigPath -Raw
        Set-TestFile -Path $script:AgConfigPath -Content ($config.Replace("Skills = @('boring-engineering', 'git-review')",$replacement))
        Assert-PluginThrows { Initialize-AgPluginContext $root } 'two reviewed shared skills' 'traversal and duplicate skill selections are rejected'
    }
    $root = New-PluginFixture 'components'
    Set-TestFile -Path $script:AgConfigPath -Content ((Get-Content $script:AgConfigPath -Raw).Replace("Version = '0.1.0'", "Version = '0.1.0'; Hooks = @()"))
    Assert-PluginThrows { Initialize-AgPluginContext $root } 'unsupported components' 'unreviewed component configuration is rejected'
    $root = New-PluginFixture 'reparse'
    $link = Join-Path $root 'skills-source/shared/git-review/linked'
    New-Item -ItemType Junction -Path $link -Target $script:AgTestNativeRoot | Out-Null
    try { Assert-PluginThrows { Initialize-AgPluginContext $root } 'reparse' 'source junctions are rejected before copying' }
    finally { Remove-Item -LiteralPath $link -Force }
    foreach ($badJson in @('{}','[{"name":"bad","path":"relative","enabled":true}]','[{"name":"bad","path":"C:/fixture","enabled":"true"}]')) {
        $null = New-PluginFixture ('inventory-' + [Guid]::NewGuid().ToString('N'))
        $script:AgTestListJson=$badJson
        Assert-PluginThrows { Get-AgPluginPlan } 'native.*schema' 'malformed native inventory fails closed'
    }
    foreach ($issue in @('warning','extra-component','missing-field','wrong-type')) {
        $null = New-PluginFixture ('validate-' + $issue)
        switch ($issue) {
            wrong-type { $script:AgTestValidation.agentPluginsSpec='unknown' }
            warning { $script:AgTestValidation.findings=@(@{severity='warning'}) }
            extra-component { $script:AgTestValidation.components.rules=1 }
            missing-field { $script:AgTestValidation.components.Remove('skills') }
        }
        Assert-PluginThrows { Get-AgNativeValidation $script:AgRepo } 'Native validation|native component|native validation schema' 'strict native validation rejects warnings, extra components and unknown schema'
    }

    Write-Host 'Antigravity: identity, ownership and lifecycle limits'
    $null = New-PluginFixture 'success'
    $externalPath = Add-ExternalFixture
    $externalHash = Get-AgMapDigest (Get-AgTreeFiles $externalPath)
    $null = New-AgPluginBuild
    $installed = Invoke-AgPluginDeploy -DoApply
    Assert-PluginTest ($installed.Action -eq 'unchanged' -and $installed.Enabled -and $script:AgTestInstallCalls -eq 1) 'first Apply verifies installed identity, version and content then converges to unchanged'
    Assert-PluginTest ((Get-AgMapDigest (Get-AgTreeFiles $externalPath)) -ceq $externalHash -and $installed.External.Count -eq 1 -and -not $installed.External[0].Enabled) 'unrelated disabled plugins remain unchanged and are reported as external'
    $script:AgTestPlugins[1].enabled=$false
    $disabled = Invoke-AgPluginDeploy -DoApply
    Assert-PluginTest ($disabled.Action -eq 'unchanged' -and -not $disabled.Enabled -and $script:AgTestInstallCalls -eq 1) 'unchanged disabled plugin is never reinstalled or enabled'
    Set-TestFile -Path (Join-Path $installed.InstalledPath 'skills/git-review/SKILL.md') -Content 'local drift'
    Assert-PluginTest ((Get-AgPluginPlan).Reason -eq 'installed-content-drift') 'local installed-content drift is blocked'

    $null = New-PluginFixture 'unknown-owner'
    $null = New-AgPluginBuild
    $unknownPath = Join-Path $script:AgTestNativeRoot 'plugins/alias'
    Copy-SkillTree -SourceRoot $script:AgPackage -DestinationRoot $unknownPath
    $script:AgTestPlugins=@(@{name='alias';path=$unknownPath;enabled=$true})
    Assert-PluginTest ((Get-AgPluginPlan).Reason -eq 'same-name-unknown-owner') 'manifest name detects same-name conflict despite a different directory and list name'
    $script:AgTestPlugins += @{name='ai-agent-dotfiles';path=$unknownPath;enabled=$true}
    Assert-PluginTest ((Get-AgPluginPlan).Reason -eq 'ambiguous-native-identity') 'multiple native identities are blocked without takeover'

    foreach ($version in @('same','0.2.0','0.0.9')) {
        $root = New-PluginFixture ('version-' + $version)
        $null = New-AgPluginBuild
        $null = Invoke-AgPluginDeploy -DoApply
        if ($version -eq 'same') {
            Add-Content -LiteralPath (Join-Path $root 'skills-source/shared/git-review/SKILL.md') -Value 'changed source content'
            $reason='same-version-different-content'
        }
        else {
            Set-TestFile -Path $script:AgConfigPath -Content ((Get-Content $script:AgConfigPath -Raw).Replace("Version = '0.1.0'", "Version = '$version'"))
            Initialize-AgPluginContext $root
            $script:AgNative='fixture-only'
            $reason=if ($version -eq '0.2.0') { 'native-update-contract-unproven' } else { 'downgrade-or-version-reuse' }
        }
        $null = New-AgPluginBuild
        Assert-PluginTest ((Get-AgPluginPlan).Reason -eq $reason -and $script:AgTestInstallCalls -eq 1) 'same-version replacement, unproven update and downgrade never mutate the installed plugin'
    }

    $root = New-PluginFixture 'external-expectations'
    $null = Add-ExternalFixture
    $expectation = "ExternalPlugins = @(@{ Name='unrelated'; Source='https://example.org/plugin'; Version='2.0.0'; Enabled=`$false })"
    Set-TestFile -Path $script:AgConfigPath -Content ((Get-Content $script:AgConfigPath -Raw).Replace('ExternalPlugins = @()',$expectation))
    Initialize-AgPluginContext $root
    $script:AgNative='fixture-only'
    Assert-PluginTest ((Get-AgPluginPlan).ExternalExpectations[0].State -eq 'unchanged') 'third-party exact source, version and enabled expectations are compared read-only'
    $script:AgTestPlugins[0].version='2.1.0'
    Assert-PluginTest ((Get-AgPluginPlan).ExternalExpectations[0].State -eq 'different') 'third-party drift is reported without changing the external plugin'
    $script:AgTestPlugins[0].Remove('source')
    Assert-PluginTest ((Get-AgPluginPlan).ExternalExpectations[0].State -eq 'UNKNOWN' -and $script:AgTestInstallCalls -eq 0) 'unavailable third-party provenance stays UNKNOWN without automatic repair'

    Write-Host 'Antigravity: failed writes always read back without automatic retry'
    foreach ($mode in @('partial-nonzero','partial-throw','readback-fails','wrong-path','extra-metadata','unrelated-change')) {
        $null = New-PluginFixture ('failure-' + $mode)
        if ($mode -eq 'unrelated-change') { $null = Add-ExternalFixture }
        $null = New-AgPluginBuild
        $script:AgTestInstallMode=$mode
        Assert-PluginThrows { Invoke-AgPluginDeploy -DoApply } 'failed|uncertain|outside|metadata|inventory changed' "native $mode stops the write chain"
        $result = Get-OnlyAttemptResult
        Assert-PluginTest ($script:AgTestInstallCalls -eq 1 -and -not (Test-Path $script:AgInstallReceipt) -and (Test-Path (Join-Path $script:AgWork 'pending-install.json'))) 'failed or unverified install retains pending state and never claims ownership'
        Assert-PluginTest (@($result.Targets).Count -ge 1 -and ($result.Targets[0].Present -or $mode -eq 'wrong-path')) 'failure receipt includes best-effort target filesystem readback'
        $installIndex = $script:AgTestTrace.FindIndex([Predicate[string]]{ param($line) $line.StartsWith('plugin install ') })
        Assert-PluginTest (@($script:AgTestTrace | Select-Object -Skip ($installIndex + 1) | Where-Object { $_ -eq 'plugin list --json' }).Count -eq 1) 'native inventory is read after each install result, including exceptions'
        $script:AgTestFailList=$false
        $again = Invoke-AgPluginDeploy
        Assert-PluginTest ($again.Action -eq 'blocked' -and $script:AgTestInstallCalls -eq 1) 'subsequent preview remains blocked and does not retry an uncertain install'
    }

    Write-Host 'Antigravity: changes during validation stop before native install'
    foreach ($change in @('source','package','gates','inventory','registration','target')) {
        $null = New-PluginFixture ('race-' + $change)
        if ($change -eq 'inventory') { $null = Add-ExternalFixture }
        $null = New-AgPluginBuild
        $script:AgTestValidationHook = switch ($change) {
            source { { Add-Content -LiteralPath (Join-Path $script:AgRepo 'skills-source/shared/git-review/SKILL.md') -Value 'raced source' } }
            package { { Add-Content -LiteralPath (Join-Path $script:AgPackage 'skills/git-review/SKILL.md') -Value 'raced package' } }
            gates { { Add-Content -LiteralPath (Join-Path $script:AgRepo '.gitleaks.toml') -Value '# changed scan input' } }
            inventory { { $script:AgTestPlugins[0].enabled = -not $script:AgTestPlugins[0].enabled } }
            registration { { Set-TestFile -Path (Join-Path $script:AgTestNativeRoot 'config.json') -Content '{"changed":true}' } }
            target { { [IO.Directory]::CreateDirectory((Join-Path $script:AgTestNativeRoot 'plugins/ai-agent-dotfiles')) | Out-Null } }
        }
        Assert-PluginThrows { Invoke-AgPluginDeploy -DoApply } 'changed|Inputs changed' "$change race invalidates the plan before mutation"
        Assert-PluginTest ($script:AgTestInstallCalls -eq 0 -and -not (Test-Path (Join-Path $script:AgWork 'pending-install.json'))) 'race detection never reaches native install or pending marker'
    }
    $null = New-PluginFixture 'writer-lock'
    $null = New-AgPluginBuild
    $writer = Enter-AgPluginLock
    try { Assert-PluginThrows { Invoke-AgPluginDeploy -DoApply } 'used by another process|being used' 'existing managed writer lock blocks a second Apply' }
    finally { $writer.Dispose() }
    Assert-PluginTest ($script:AgTestInstallCalls -eq 0) 'writer collision invokes no native mutation'

    Write-Host 'Antigravity: native target mutex spans independent writers'
    $null = New-PluginFixture 'native-target-lock'
    $null = New-AgPluginBuild
    $holderScript = Join-Path $suiteWork 'mutex-holder.ps1'
    Set-TestFile -Path $holderScript -Content (@(
        'param([string] $Name, [string] $ReadyPath, [string] $ReleasePath)',
        '$mutex = [Threading.Mutex]::new($false,$Name)',
        'try {',
        '    if (-not $mutex.WaitOne(0)) { throw "fixture mutex unavailable" }',
        '    [IO.File]::WriteAllText($ReadyPath,"ready")',
        '    $deadline = [DateTime]::UtcNow.AddSeconds(15)',
        '    while (-not (Test-Path -LiteralPath $ReleasePath)) { if ([DateTime]::UtcNow -gt $deadline) { throw "fixture release timed out" }; Start-Sleep -Milliseconds 20 }',
        '} finally { $mutex.ReleaseMutex(); $mutex.Dispose() }'
    ) -join "`n")
    $mutexName = 'Local\ai-agent-dotfiles-antigravity-' + (Get-AgTextHash ([IO.Path]::GetFullPath($script:AgTestNativeRoot).ToLowerInvariant()))
    $readyPath = Join-Path $suiteWork 'mutex-ready'
    $releasePath = Join-Path $suiteWork 'mutex-release'
    $info = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh -CommandType Application | Select-Object -First 1).Source)
    foreach ($argument in @('-NoProfile','-File',$holderScript,$mutexName,$readyPath,$releasePath)) { $info.ArgumentList.Add($argument) }
    $info.WorkingDirectory=$suiteWork
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.Environment['TEMP']=$suiteWork
    $info.Environment['TMP']=$suiteWork
    $holder = [Diagnostics.Process]::Start($info)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $readyPath) -and -not $holder.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 20 }
        Assert-PluginTest (Test-Path -LiteralPath $readyPath) 'independent fixture writer holds the native target mutex'
        Assert-PluginThrows { Invoke-AgPluginDeploy -DoApply } 'Another managed plugin deployment' 'same native target is locked even with independent writer state'
        Assert-PluginTest ($script:AgTestInstallCalls -eq 0) 'native target collision invokes no mutation'
    }
    finally {
        [IO.File]::WriteAllText($releasePath,'release')
        if (-not $holder.WaitForExit(5000)) { $holder.Kill($true); $holder.WaitForExit() }
        $holder.Dispose()
    }

    Write-Host ("Antigravity plugin tests: {0} assertions passed; native and scan operations used isolated stubs." -f $script:AgTestAssertions)
    $resolvedWork = [IO.Path]::GetFullPath($suiteWork)
    $expectedBase = [IO.Path]::GetFullPath((Join-Path $suiteRepo 'tmp/tests/antigravity-plugins'))
    if (-not (Test-SameOrDescendant -Path $resolvedWork -Root $expectedBase) -or $resolvedWork -eq $expectedBase) { throw 'Refuse cleanup outside exact owned test run.' }
    Remove-Item -LiteralPath $resolvedWork -Recurse -Force
}
catch {
    Write-Host "Fixture retained for diagnosis: $suiteWork"
    throw
}
