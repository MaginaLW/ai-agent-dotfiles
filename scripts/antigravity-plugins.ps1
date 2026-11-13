#requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Build','Status','Deploy')] [string] $Action = 'Status',
    [string] $RepoRoot = (Split-Path -Parent $PSScriptRoot),
    [string] $JsonPath,
    [switch] $Apply
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'skills-common.ps1')
. (Join-Path $PSScriptRoot 'pinned-tool.ps1')
. (Join-Path $PSScriptRoot 'repo-common.ps1')

function Assert-AgPlainPath {
    param([string] $Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Plugin paths cannot contain reparse points.' }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
}

function Get-AgTextHash {
    param([string] $Text)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}

function Get-AgMapDigest {
    param([System.Collections.IDictionary] $Files)
    $rows = @($Files.Keys | Sort-Object -CaseSensitive | ForEach-Object { $_ + ':' + $Files[$_] })
    return Get-AgTextHash ($rows -join [char]10)
}

function Write-AgJsonFile {
    param([string] $Path, [object] $Value)
    Assert-AgPlainPath $Path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, (ConvertTo-Json -InputObject $Value -Depth 30) + [char]10, [Text.UTF8Encoding]::new($false))
}

function Read-AgJsonFile {
    param([string] $Path)
    Assert-AgPlainPath $Path
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
}

function Initialize-AgPluginContext {
    param([string] $Root)
    foreach ($variable in 'ANTIGRAVITY_GEMINI_DIR','ANTIGRAVITY_CONFIG_REL_DIR','ANTIGRAVITY_APP_DATA_DIR','JETSKI_APP_DATA_DIR') {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($variable))) { throw 'Native configuration overrides are unsupported until their target contract is verified.' }
    }
    $script:AgRepo = (Resolve-Path -LiteralPath $Root).Path
    Assert-AgPlainPath $script:AgRepo
    $script:AgWork = Join-Path $script:AgRepo 'tmp/antigravity'
    $script:AgPackage = Join-Path $script:AgWork 'plugins/ai-agent-dotfiles'
    $script:AgBuildReceipt = Join-Path $script:AgWork 'build.json'
    $script:AgInstallReceipt = Join-Path $script:AgWork 'installed.json'
    $script:AgConfigPath = Join-Path $script:AgRepo 'harness-source/antigravity/plugins.psd1'
    Assert-AgPlainPath $script:AgConfigPath
    $script:AgLoadedConfigHash = (Get-FileHash -LiteralPath $script:AgConfigPath -Algorithm SHA256).Hash
    $script:AgConfig = Import-PowerShellDataFile -LiteralPath $script:AgConfigPath
    if ((Get-FileHash -LiteralPath $script:AgConfigPath -Algorithm SHA256).Hash -cne $script:AgLoadedConfigHash) { throw 'Plugin configuration changed during loading.' }
    if (($script:AgConfig.Keys | Sort-Object) -join ',' -cne 'ExternalPlugins,ManagedPlugin,SchemaVersion' -or $script:AgConfig.SchemaVersion -ne 1) { throw 'Unsupported plugin configuration schema.' }
    $managed = $script:AgConfig.ManagedPlugin
    if ($managed -isnot [hashtable] -or ($managed.Keys | Sort-Object) -join ',' -cne 'Description,DisplayName,Name,Skills,Version' -or
        $managed.Name -cne 'ai-agent-dotfiles' -or $managed.Version -cnotmatch '^\d+\.\d+\.\d+$' -or
        [string]::IsNullOrWhiteSpace($managed.DisplayName) -or [string]::IsNullOrWhiteSpace($managed.Description)) { throw 'Invalid managed plugin identity or unsupported components.' }
    $names = @($managed.Skills)
    if ($names.Count -ne 2 -or @($names | Sort-Object -Unique).Count -ne 2 -or ($names | Sort-Object) -join ',' -cne 'boring-engineering,git-review') { throw 'Only the two reviewed shared skills are supported.' }
    foreach ($name in $names) {
        $source = Join-Path $script:AgRepo ('skills-source/shared/' + $name)
        Assert-AgPlainPath $source
        Assert-SkillTreeNoReparsePoint -Root $source
        if (-not (Test-Path -LiteralPath (Join-Path $source 'SKILL.md') -PathType Leaf)) { throw 'Selected skill is missing SKILL.md.' }
    }
    foreach ($external in @($script:AgConfig.ExternalPlugins)) {
        if ($external -isnot [hashtable] -or ($external.Keys | Sort-Object) -join ',' -cne 'Enabled,Name,Source,Version' -or
            $external.Name -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or $external.Name -eq $managed.Name -or
            $external.Source -cnotmatch '^https://[^\s]+$' -or [string]::IsNullOrWhiteSpace($external.Version) -or $external.Enabled -isnot [bool]) { throw 'Invalid read-only external plugin expectation.' }
    }
    if (@($script:AgConfig.ExternalPlugins | ForEach-Object Name | Sort-Object -Unique).Count -ne @($script:AgConfig.ExternalPlugins).Count) { throw 'Duplicate external plugin identity.' }
    Assert-AgPlainPath $script:AgWork
    $script:AgNative = @(Get-Command agy -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1)
    $script:AgNative = if ($script:AgNative.Count) { $script:AgNative[0].Source } else { $null }
}

function Get-AgManifestText {
    $managed = $script:AgConfig.ManagedPlugin
    $manifest = [ordered]@{
        '$schema' = 'https://antigravity.google/schemas/v1/plugin.json'
        name = $managed.Name
        displayName = $managed.DisplayName
        version = $managed.Version
        description = $managed.Description
    }
    return (ConvertTo-Json -InputObject $manifest) + [char]10
}

function Get-AgExpectedFiles {
    $files = [ordered]@{ 'plugin.json' = (Get-AgTextHash (Get-AgManifestText)) }
    foreach ($name in @($script:AgConfig.ManagedPlugin.Skills | Sort-Object)) {
        $root = Join-Path $script:AgRepo ('skills-source/shared/' + $name)
        Assert-AgPlainPath $root
        Assert-SkillTreeNoReparsePoint -Root $root
        foreach ($file in @(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName)) {
            if ($file.Name -like 'CREATION-LOG.md') { continue }
            $relative = [IO.Path]::GetRelativePath($root, $file.FullName).Replace('\','/')
            $files['skills/' + $name + '/' + $relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
    return ,$files
}

function Get-AgTreeFiles {
    param([string] $Root)
    Assert-AgPlainPath $Root
    Assert-SkillTreeNoReparsePoint -Root $Root
    $files = [ordered]@{}
    foreach ($file in @(Get-ChildItem -LiteralPath $Root -File -Recurse -Force | Sort-Object FullName)) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\','/')
        $files[$relative] = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
    return ,$files
}

function Invoke-AgNativeCommand {
    param([string[]] $Arguments)
    if (-not $script:AgNative) { throw 'agy is unavailable; native validation remains incomplete.' }
    $info = [Diagnostics.ProcessStartInfo]::new($script:AgNative)
    foreach ($argument in $Arguments) { $info.ArgumentList.Add($argument) }
    $info.WorkingDirectory = $script:AgRepo
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Native command timed out; mutating calls require readback before recovery.' }
        $process.WaitForExit()
        return @{ Code=$process.ExitCode; Out=$stdout.GetAwaiter().GetResult(); Error=$stderr.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

function Get-AgNativeValidation {
    param([string] $Root)
    $result = Invoke-AgNativeCommand @('plugin','validate',$Root,'--strict','--json')
    if ($result.Code -ne 0) { throw 'Native strict plugin validation failed.' }
    $data = ConvertFrom-Json -InputObject $result.Out -AsHashtable
    if ($data -isnot [hashtable]) { throw 'Unknown native validation schema.' }
    foreach ($key in 'dir','components','findings','agentPluginsSpec') { if (-not $data.ContainsKey($key)) { throw 'Unknown native validation schema.' } }
    if ($data.dir -isnot [string] -or $data.agentPluginsSpec -isnot [bool] -or $data.components -isnot [hashtable] -or $data.findings -isnot [array] -or
        @($data.Keys | Where-Object { $_ -notin @('dir','manifest','name','agentPluginsSpec','components','findings') }).Count) { throw 'Unknown native validation schema.' }
    # This package permits only skills. Check every other reported component is absent,
    # without adding handlers or dependencies for the native loader's other capabilities.
    if ($data.components.Count -ne 6 -or -not $data.components.ContainsKey('skills')) { throw 'Unknown native component schema.' }
    foreach ($entry in $data.components.GetEnumerator()) {
        $expected = if ($entry.Key -ceq 'skills') { 2 } else { 0 }
        if (($entry.Value -isnot [int] -and $entry.Value -isnot [long]) -or $entry.Value -ne $expected) { throw 'Native validation found unexpected components.' }
    }
    foreach ($finding in @($data.findings)) {
        if (-not $finding.ContainsKey('severity') -or $finding.severity -notin @('note')) { throw 'Native validation has warnings, errors or unknown findings.' }
    }
    return $data
}

function Invoke-AgPackageScan {
    param([string] $Root)
    $tool = Get-PinnedToolExecutable -LockPath (Join-Path $script:AgRepo 'tools/gitleaks/gitleaks.lock.json')
    $info = [Diagnostics.ProcessStartInfo]::new($tool.Executable)
    foreach ($argument in @('detect','--no-git','--source',$Root,'--redact','--config',(Join-Path $script:AgRepo '.gitleaks.toml'))) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $out = $process.StandardOutput.ReadToEndAsync()
        $err = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill($true); throw 'Package secret scan timed out.' }
        $process.WaitForExit()
        $null = $out.GetAwaiter().GetResult()
        $null = $err.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw 'Pinned package secret scan failed (redacted scanner output is not published).' }
    }
    finally { $process.Dispose() }
}

function Get-AgGateFingerprint {
    if ((Get-FileHash -LiteralPath $script:AgConfigPath -Algorithm SHA256).Hash -cne $script:AgLoadedConfigHash) { throw 'Plugin configuration changed; reload context and review again.' }
    $paths = @('.gitleaks.toml','tools/gitleaks/gitleaks.lock.json','harness-source/antigravity/plugins.psd1')
    $map = [ordered]@{}
    foreach ($path in $paths) {
        Assert-AgPlainPath (Join-Path $script:AgRepo $path)
        $map[$path] = (Get-FileHash -LiteralPath (Join-Path $script:AgRepo $path) -Algorithm SHA256).Hash
    }
    return Get-AgMapDigest $map
}

function Enter-AgPluginLock {
    [IO.Directory]::CreateDirectory($script:AgWork) | Out-Null
    Assert-AgPlainPath (Join-Path $script:AgWork 'writer.lock')
    return [IO.File]::Open((Join-Path $script:AgWork 'writer.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}

function New-AgPluginBuild {
    $lock = Enter-AgPluginLock
    $stage = Join-Path $script:AgWork ('build-' + [Guid]::NewGuid().ToString('N'))
    try {
        $expected = Get-AgExpectedFiles
        $digest = Get-AgMapDigest $expected
        $gate = Get-AgGateFingerprint
        $version = $null
        if ($script:AgNative) {
            $versionProbe = Invoke-AgNativeCommand @('--version')
            if ($versionProbe.Code -ne 0) { throw 'Cannot identify agy version for the build.' }
            $version = $versionProbe.Out.Trim()
        }
        if (Test-Path -LiteralPath $script:AgPackage) {
            if (-not (Test-Path -LiteralPath $script:AgBuildReceipt)) { throw 'Unowned candidate directory; preserve it for review.' }
            $old = Read-AgJsonFile $script:AgBuildReceipt
            if ($old.Name -cne 'ai-agent-dotfiles' -or (Get-AgMapDigest (Get-AgTreeFiles $script:AgPackage)) -cne $old.Digest) { throw 'Candidate was modified outside the builder; preserve it for review.' }
        }
        [IO.Directory]::CreateDirectory((Join-Path $stage 'skills')) | Out-Null
        foreach ($name in $script:AgConfig.ManagedPlugin.Skills) {
            $destination = Join-Path $stage ('skills/' + $name)
            Copy-SkillTree -SourceRoot (Join-Path $script:AgRepo ('skills-source/shared/' + $name)) -DestinationRoot $destination
            foreach ($file in @(Get-ChildItem -LiteralPath $destination -File -Recurse -Force | Where-Object Name -Like 'CREATION-LOG.md')) { Remove-Item -LiteralPath $file.FullName -Force }
        }
        [IO.File]::WriteAllText((Join-Path $stage 'plugin.json'), (Get-AgManifestText), [Text.UTF8Encoding]::new($false))
        if ((Get-AgMapDigest (Get-AgTreeFiles $stage)) -cne $digest) { throw 'Source changed while copying the candidate.' }
        $scratch = Join-Path $script:AgWork 'temp'
        [IO.Directory]::CreateDirectory($scratch) | Out-Null
        $previousTemp = $env:TEMP
        $previousTmp = $env:TMP
        try {
            $env:TEMP = $scratch
            $env:TMP = $scratch
            Invoke-SecretScanGate -RepoRoot $script:AgRepo | Out-Host
        }
        finally { $env:TEMP = $previousTemp; $env:TMP = $previousTmp }
        Invoke-AgPackageScan $stage
        $validation = if ($script:AgNative) { Get-AgNativeValidation $stage } else { $null }
        if ((Get-AgMapDigest (Get-AgExpectedFiles)) -cne $digest -or (Get-AgMapDigest (Get-AgTreeFiles $stage)) -cne $digest) { throw 'Source or candidate changed during build gates.' }
        if ((Get-AgGateFingerprint) -cne $gate) { throw 'Build gate inputs changed during scanning.' }
        Assert-AgPlainPath $script:AgPackage
        if (Test-Path -LiteralPath $script:AgPackage) {
            if ((Get-AgMapDigest (Get-AgTreeFiles $script:AgPackage)) -cne $old.Digest) { throw 'Previous candidate changed during build gates; preserve it.' }
        }
        if (Test-Path -LiteralPath $script:AgPackage) { Remove-Item -LiteralPath $script:AgPackage -Recurse -Force }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $script:AgPackage)) | Out-Null
        Move-Item -LiteralPath $stage -Destination $script:AgPackage
        $revision = (& git -C $script:AgRepo rev-parse HEAD | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { throw 'Cannot identify source revision.' }
        $receipt = [ordered]@{
            SchemaVersion=1; Name='ai-agent-dotfiles'; Version=$script:AgConfig.ManagedPlugin.Version
            Digest=$digest; Files=$expected; SourceRevision=$revision; GateFingerprint=$gate
            CanonicalScan='PASS'; PackageScan='PASS'; NativeValidation=$(if ($validation) { 'PASS' } else { 'UNKNOWN' }); NativeVersion=$version
        }
        Write-AgJsonFile $script:AgBuildReceipt $receipt
        return $receipt
    }
    finally { $lock.Dispose() }
}

function Get-AgRegistrationHash {
    param([string] $ConfigRoot)
    $path = Join-Path $ConfigRoot 'config.json'
    Assert-AgPlainPath $path
    if (-not (Test-Path -LiteralPath $path)) { return 'missing' }
    return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
}

function Get-AgInventoryToken {
    param([hashtable] $Inventory)
    $plugins = @($Inventory.Plugins | Sort-Object name,path | ForEach-Object {
        $entry = [ordered]@{}
        foreach ($key in @($_.Keys | Sort-Object)) { $entry[$key] = $_[$key] }
        $entry
    })
    return Get-AgTextHash (ConvertTo-Json -InputObject @{ Version=$Inventory.Version; ConfigRoot=$Inventory.ConfigRoot; Plugins=$plugins } -Depth 30 -Compress)
}

function Enter-AgDeploymentMutex {
    param([string] $ConfigRoot)
    $name = 'Local\ai-agent-dotfiles-antigravity-' + (Get-AgTextHash ([IO.Path]::GetFullPath($ConfigRoot).ToLowerInvariant()))
    $mutex = [Threading.Mutex]::new($false,$name)
    try { if (-not $mutex.WaitOne(0)) { throw 'Another managed plugin deployment owns this native target.' } }
    catch { $mutex.Dispose(); throw }
    return $mutex
}

function Read-AgTargetSnapshot {
    param([string] $Path)
    $snapshot = @{ Path=$Path; Present=$false; Files=$null; Identity=$null; Error=$null }
    try {
        Assert-AgPlainPath $Path
        if (Test-Path -LiteralPath $Path) {
            $snapshot.Present=$true
            $snapshot.Files=Get-AgTreeFiles $Path
            if (Test-Path -LiteralPath (Join-Path $Path 'plugin.json')) {
                $manifest=Read-AgJsonFile (Join-Path $Path 'plugin.json')
                $snapshot.Identity=@{ Name=$manifest['name']; Version=$manifest['version'] }
            }
        }
    }
    catch { $snapshot.Error=$_.Exception.Message }
    return $snapshot
}

function Get-AgInventory {
    $version = Invoke-AgNativeCommand @('--version')
    if ($version.Code -ne 0) { throw 'Cannot identify agy version.' }
    $listing = Invoke-AgNativeCommand @('plugin','list','--json')
    if ($listing.Code -ne 0) { throw 'Cannot read native plugin inventory.' }
    $plugins = ConvertFrom-Json -InputObject $listing.Out -AsHashtable -NoEnumerate
    if ($plugins -isnot [array]) { throw 'Unknown native plugin inventory schema.' }
    foreach ($plugin in $plugins) {
        if ($plugin -isnot [hashtable] -or -not $plugin.ContainsKey('name') -or -not $plugin.ContainsKey('path') -or
            -not $plugin.ContainsKey('enabled') -or $plugin.name -isnot [string] -or $plugin.path -isnot [string] -or
            $plugin.enabled -isnot [bool] -or [string]::IsNullOrWhiteSpace($plugin.name) -or -not [IO.Path]::IsPathFullyQualified($plugin.path)) { throw 'Unknown native plugin entry schema.' }
    }
    return @{ Version=$version.Out.Trim(); Plugins=@($plugins); ConfigRoot=(Join-Path ([Environment]::GetFolderPath('UserProfile')) '.gemini/config') }
}

function Get-AgFileChanges {
    param([System.Collections.IDictionary] $Before, [System.Collections.IDictionary] $After)
    return [ordered]@{
        Added=@($After.Keys | Where-Object { -not $Before.Contains($_) } | Sort-Object)
        Changed=@($After.Keys | Where-Object { $Before.Contains($_) -and $Before[$_] -cne $After[$_] } | Sort-Object)
        Removed=@($Before.Keys | Where-Object { -not $After.Contains($_) } | Sort-Object)
    }
}

function Get-AgInstalledFiles {
    param([string] $Root)
    # Native-generated metadata is handled explicitly after the installed contract is known.
    return Get-AgTreeFiles $Root
}

function Get-AgPluginPlan {
    $expected = Get-AgExpectedFiles
    $digest = Get-AgMapDigest $expected
    $inventory = Get-AgInventory
    $managed = $script:AgConfig.ManagedPlugin
    $plan = [ordered]@{
        SchemaVersion=1; Action='blocked'; Reason='candidate-missing'; NativeVersion=$inventory.Version
        InventoryToken=(Get-AgInventoryToken $inventory); RegistrationHash=(Get-AgRegistrationHash $inventory.ConfigRoot)
        ConfigRoot=$inventory.ConfigRoot; Name=$managed.Name; Version=$managed.Version; Skills=@($managed.Skills)
        Package=$script:AgPackage; Digest=$digest; GateFingerprint=(Get-AgGateFingerprint); SourceRevision=$null; Enabled=$null; InstalledPath=$null
        Changes=(Get-AgFileChanges ([ordered]@{}) $expected); CanonicalScan='UNKNOWN'; PackageScan='UNKNOWN'; NativeValidation='UNKNOWN'
        NativeAction=$null; WriteScope=@(); External=@(); ExternalExpectations=@()
        Limitations=@('Native App is not locked by this script.','Updates and rollback remain blocked until their native contracts are proven.','Installation may immediately enable the two skills.')
    }
    $matches = [Collections.Generic.List[object]]::new()
    foreach ($plugin in @($inventory.Plugins)) {
        $isTarget = $plugin.name -ieq $managed.Name
        if (Test-Path -LiteralPath (Join-Path $plugin.path 'plugin.json')) {
            $manifest = Read-AgJsonFile (Join-Path $plugin.path 'plugin.json')
            if ($manifest.ContainsKey('name') -and $manifest.name -ieq $managed.Name) { $isTarget = $true }
        }
        if ($isTarget) { $matches.Add($plugin) }
        else {
            $plan.External += @{ Name=$plugin.name; Enabled=$plugin.enabled; Version=$(if ($plugin.ContainsKey('version')) { $plugin.version } else { 'UNKNOWN' }); Source=$(if ($plugin.ContainsKey('source')) { $plugin.source } else { 'UNKNOWN' }) }
        }
    }
    foreach ($expectation in @($script:AgConfig.ExternalPlugins)) {
        $found = @($plan.External | Where-Object Name -CEQ $expectation.Name)
        $state = 'UNKNOWN'
        if ($found.Count -eq 1 -and $found[0].Version -ne 'UNKNOWN' -and $found[0].Source -ne 'UNKNOWN') {
            $state = if ($found[0].Version -ceq $expectation.Version -and $found[0].Source -ceq $expectation.Source -and $found[0].Enabled -eq $expectation.Enabled) { 'unchanged' } else { 'different' }
        }
        $plan.ExternalExpectations += @{ Name=$expectation.Name; State=$state; Expected=$expectation }
    }
    if ($matches.Count -gt 1) { $plan.Reason='ambiguous-native-identity'; return $plan }
    if ($matches.Count -eq 1) {
        $plan.InstalledPath=$matches[0].path
        $plan.Enabled=$matches[0].enabled
    }
    if (-not (Test-Path -LiteralPath $script:AgPackage) -or -not (Test-Path -LiteralPath $script:AgBuildReceipt)) { return $plan }
    $build = Read-AgJsonFile $script:AgBuildReceipt
    $plan.SourceRevision=$build.SourceRevision
    $actual = Get-AgTreeFiles $script:AgPackage
    if ($build.Name -cne $managed.Name -or $build.Version -cne $managed.Version -or $build.Digest -cne $digest -or
        (Get-AgMapDigest $actual) -cne $digest -or $build.GateFingerprint -cne (Get-AgGateFingerprint)) { $plan.Reason='source-candidate-or-gates-changed'; return $plan }
    $plan.CanonicalScan=$build.CanonicalScan
    $plan.PackageScan=$build.PackageScan
    $plan.NativeValidation=$build.NativeValidation
    if ($build.CanonicalScan -cne 'PASS' -or $build.PackageScan -cne 'PASS' -or $build.NativeValidation -cne 'PASS' -or $build.NativeVersion -cne $inventory.Version) { $plan.Reason='build-gates-incomplete-or-native-version-changed'; return $plan }
    if ($matches.Count -eq 0) {
        if (Test-Path -LiteralPath (Join-Path $script:AgWork 'pending-install.json')) { $plan.Reason='previous-install-needs-readback-review'; return $plan }
        $target = Join-Path $inventory.ConfigRoot 'plugins/ai-agent-dotfiles'
        Assert-AgPlainPath $target
        if (Test-Path -LiteralPath $target) { $plan.Reason='unregistered-target-directory'; return $plan }
        if (Test-Path -LiteralPath $script:AgInstallReceipt) { $plan.Reason='recorded-installation-missing'; return $plan }
        $plan.Action='install'; $plan.Reason='first-install'
        $plan.NativeAction=@('plugin','install',$script:AgPackage)
        $plan.WriteScope=@($target,(Join-Path $inventory.ConfigRoot 'config.json'),'Native CLI logs and registration state; other plugins must remain unchanged.')
        return $plan
    }
    $plan.Reason='same-name-unknown-owner'
    if (-not (Test-Path -LiteralPath $script:AgInstallReceipt)) { return $plan }
    $installed = Read-AgJsonFile $script:AgInstallReceipt
    if ($installed.Name -cne $managed.Name -or $installed.Path -cne $plan.InstalledPath -or $installed.SchemaVersion -ne 1) { return $plan }
    $live = Get-AgInstalledFiles $plan.InstalledPath
    $plan.Changes=Get-AgFileChanges $live $actual
    if ((Get-AgMapDigest $live) -cne $installed.Digest) { $plan.Reason='installed-content-drift'; return $plan }
    if ($installed.Version -ceq $managed.Version) {
        if ($installed.Digest -cne $digest) { $plan.Reason='same-version-different-content'; return $plan }
        $plan.Action='unchanged'; $plan.Reason='identity-version-and-content-match'; return $plan
    }
    if ([version]$managed.Version -le [version]$installed.Version) { $plan.Reason='downgrade-or-version-reuse'; return $plan }
    $plan.Reason='native-update-contract-unproven'
    return $plan
}

function Invoke-AgPluginDeploy {
    param([switch] $DoApply)
    $plan = Get-AgPluginPlan
    if (-not $DoApply -or $plan.Action -eq 'unchanged') { return $plan }
    if ($plan.Action -ne 'install') { throw ('Plugin deployment blocked: ' + $plan.Reason) }
    $mutex = Enter-AgDeploymentMutex $plan.ConfigRoot
    $lock = $null
    try {
        $lock = Enter-AgPluginLock
        $fresh = Get-AgPluginPlan
        if ((Get-AgTextHash ($plan | ConvertTo-Json -Depth 30 -Compress)) -cne (Get-AgTextHash ($fresh | ConvertTo-Json -Depth 30 -Compress))) { throw 'Source, package or live state changed after planning.' }
        $null = Get-AgNativeValidation $script:AgPackage
        $before = Get-AgInventory
        if ((Get-AgInventoryToken $before) -cne $plan.InventoryToken -or (Get-AgRegistrationHash $plan.ConfigRoot) -cne $plan.RegistrationHash) { throw 'Native state changed during pre-install validation.' }
        $attempt = Join-Path $script:AgWork ('attempt-' + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($attempt) | Out-Null
        Copy-SkillTree -SourceRoot $script:AgPackage -DestinationRoot (Join-Path $attempt 'package')
        Write-AgJsonFile (Join-Path $attempt 'pre-state.json') @{ Plan=$plan; Inventory=$before }
        # Recheck immediately before the sole mutating command, including every unrelated plugin.
        $finalPlan = Get-AgPluginPlan
        if ((Get-AgTextHash ($plan | ConvertTo-Json -Depth 30 -Compress)) -cne (Get-AgTextHash ($finalPlan | ConvertTo-Json -Depth 30 -Compress))) { throw 'Inputs changed immediately before native installation.' }
        Write-AgJsonFile (Join-Path $script:AgWork 'pending-install.json') @{ Attempt=$attempt; Digest=$plan.Digest }
        $native = $null
        $failure = $null
        try { $native = Invoke-AgNativeCommand @('plugin','install',$script:AgPackage) }
        catch { $failure = $_.Exception.Message }
        # Always read back, even after timeout, nonzero exit or an exception. No automatic retry.
        $after = $null
        try { $after = Get-AgInventory } catch { $failure = 'Native readback unavailable; installation state UNKNOWN.' }
        $approvedPath = Join-Path $plan.ConfigRoot 'plugins/ai-agent-dotfiles'
        $snapshots = @((Read-AgTargetSnapshot $approvedPath))
        if ($after) {
            foreach ($entry in @($after.Plugins | Where-Object name -IEQ 'ai-agent-dotfiles')) {
                if ([IO.Path]::GetFullPath($entry.path) -ine [IO.Path]::GetFullPath($approvedPath)) { $snapshots += Read-AgTargetSnapshot $entry.path }
            }
        }
        Write-AgJsonFile (Join-Path $attempt 'result.json') @{ Native=$native; Failure=$failure; Inventory=$after; Targets=$snapshots }
        if ($failure -or -not $native -or $native.Code -ne 0 -or -not $after) { throw 'Native install failed or is uncertain; inspect the retained attempt and do not blindly retry.' }
        $targets = @($after.Plugins | Where-Object name -IEQ 'ai-agent-dotfiles')
        if ($targets.Count -ne 1) { throw 'Installation readback has an unexpected target identity; stop.' }
        $target = $targets[0]
        if ([IO.Path]::GetFullPath($target.path) -ine [IO.Path]::GetFullPath($approvedPath)) { throw 'Native installation used a path outside the reviewed target; state needs review.' }
        $manifest = Read-AgJsonFile (Join-Path $target.path 'plugin.json')
        if ($manifest.name -cne $plan.Name -or $manifest.version -cne $plan.Version) { throw 'Installed manifest does not match the approved identity and version.' }
        $files = Get-AgInstalledFiles $target.path
        if ((Get-AgMapDigest $files) -cne $plan.Digest) { throw 'Installed content or native metadata needs review; no ownership receipt was written.' }
        $oldExternal = @($before.Plugins | Where-Object name -INE 'ai-agent-dotfiles')
        $newExternal = @($after.Plugins | Where-Object name -INE 'ai-agent-dotfiles')
        if ((ConvertTo-Json -InputObject $oldExternal -Depth 30 -Compress) -cne (ConvertTo-Json -InputObject $newExternal -Depth 30 -Compress)) { throw 'Unrelated plugin inventory changed during installation; stop.' }
        Write-AgJsonFile $script:AgInstallReceipt @{ SchemaVersion=1; Name=$plan.Name; Version=$plan.Version; Digest=$plan.Digest; Path=$target.path; Files=$files; Attempt=$attempt }
        Remove-Item -LiteralPath (Join-Path $script:AgWork 'pending-install.json')
        $readback = Get-AgPluginPlan
        if ($readback.Action -ne 'unchanged') { throw 'Post-install preview did not converge to unchanged.' }
        return $readback
    }
    finally { if ($lock) { $lock.Dispose() }; $mutex.ReleaseMutex(); $mutex.Dispose() }
}

# Dot-sourcing exposes the same functions for isolated contract fixtures without live commands.
if ($MyInvocation.InvocationName -eq '.') { return }
if ($Apply -and $Action -ne 'Deploy') { throw '-Apply is supported only for Deploy.' }
Initialize-AgPluginContext $RepoRoot
$report = switch ($Action) {
    Build { New-AgPluginBuild }
    Status { Get-AgPluginPlan }
    Deploy { Invoke-AgPluginDeploy -DoApply:$Apply }
}
if ($JsonPath) { Write-AgJsonFile ([IO.Path]::GetFullPath($JsonPath)) $report }
$report | ConvertTo-Json -Depth 30
