#requires -Version 7.0
# Test-only OS adapters. Production files, resolver policy, locks and engines are
# copied unchanged except for the three explicitly listed default locators.
Set-StrictMode -Version Latest

function Assert-CanonicalIdentityFixturePath {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$Path)
    if (-not [IO.Path]::IsPathFullyQualified($Path)) { throw 'fixture-path-must-be-absolute' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetFullPath([string]$Fixture.Root).TrimEnd([char]92,[char]47)
    if (-not ($full.Equals($root,[StringComparison]::OrdinalIgnoreCase) -or
        $full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase))) {
        throw 'fixture-path-outside-owned-root'
    }
    $cursor = $full
    while ($cursor) {
        try {
            # GetAttributes also observes dangling links, unlike Exists.
            if (([IO.File]::GetAttributes($cursor) -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'fixture-reparse-path-refused'
            }
        }
        catch [IO.FileNotFoundException] { }
        catch [IO.DirectoryNotFoundException] { }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -ceq $cursor) { break }
        $cursor = $parent
    }
    return $full
}

function Assert-CanonicalIdentityFixtureOwned {
    param([Parameter(Mandatory)]$Fixture)
    $null = Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path ([string]$Fixture.Root)
    $marker = Join-Path $Fixture.Root '.canonical-fixture-owner'
    $null = Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $marker
    if (-not [IO.File]::Exists($marker) -or [IO.File]::ReadAllText($marker) -cne [string]$Fixture.OwnerToken) {
        throw 'fixture-ownership-marker-mismatch'
    }
}

function Remove-CanonicalIdentityFixture {
    param([Parameter(Mandatory)]$Fixture)
    Assert-CanonicalIdentityFixtureOwned -Fixture $Fixture
    $failures=[Collections.Generic.List[string]]::new()
    foreach ($child in @($Fixture.Children)) {
        try {
            Complete-CanonicalIdentityFixtureScript -Fixture $Fixture -Process $child.Process -Stop
            $child.Process.Dispose()
        }
        catch { $failures.Add([string]$_.Exception.Message) }
    }
    if ($failures.Count) { throw ('fixture-child-cleanup-failed: '+($failures -join '; ')) }
    $Fixture.Children.Clear()
    # Inspect entries without following reparse points before recursive cleanup.
    # A failed containment check preserves the entire fixture for diagnosis.
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push([string]$Fixture.Root)
    while ($pending.Count) {
        foreach ($entry in [IO.Directory]::EnumerateFileSystemEntries($pending.Pop())) {
            $null = Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $entry
            if (([IO.File]::GetAttributes($entry) -band [IO.FileAttributes]::Directory) -ne 0) { $pending.Push($entry) }
        }
    }
    Remove-Item -LiteralPath ([string]$Fixture.Root) -Recurse -Force -ErrorAction Stop
    Remove-Variable -Name CanonicalIdentityFixtureActive -Scope Script -ErrorAction SilentlyContinue
}

function New-CanonicalIdentityFixture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SourceRepoRoot,[Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+$')][string]$Name)
    if (-not $IsWindows) { throw 'canonical-identity-fixture-requires-windows' }
    # Production modules retain script-scoped locators and sealed runspace
    # captures. A suite uses exactly one copied toolchain per process.
    if ($null -ne (Get-Variable -Name CanonicalIdentityFixtureActive -Scope Script -ErrorAction SilentlyContinue)) {
        throw 'fixture-one-toolchain-per-process-required'
    }
    $source = (Resolve-Path -LiteralPath $SourceRepoRoot).Path
    $root = Join-Path ([IO.Path]::GetTempPath()) ('canonical-identity-'+$Name+'-'+[Guid]::NewGuid().ToString('N'))
    $fixture = [pscustomobject]@{
        Root=$root; ToolchainRoot=(Join-Path $root 'toolchain'); Home=(Join-Path $root 'home')
        OwnerToken=[Guid]::NewGuid().ToString('N'); Identity=$null; SourceRepoRoot=$source
        Children=[Collections.Generic.List[object]]::new()
    }
    $null = Assert-CanonicalIdentityFixturePath -Fixture $fixture -Path $root
    New-Item -ItemType Directory -Path $root -ErrorAction Stop | Out-Null
    [IO.File]::WriteAllText((Join-Path $root '.canonical-fixture-owner'),$fixture.OwnerToken,[Text.UTF8Encoding]::new($false))
    try {
        New-Item -ItemType Directory -Path $fixture.ToolchainRoot -ErrorAction Stop | Out-Null
        foreach ($relative in @('scripts','schemas','tools','tests/helpers','.gitleaks.toml','bootstrap.ps1')) {
            $from = Join-Path $source $relative
            $pending = [Collections.Generic.Stack[string]]::new(); $pending.Push($from)
            while ($pending.Count) {
                $entry = $pending.Pop()
                $attributes = [IO.File]::GetAttributes($entry)
                if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'fixture-source-reparse-refused' }
                if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
                    foreach ($child in [IO.Directory]::EnumerateFileSystemEntries($entry)) { $pending.Push($child) }
                }
            }
            $to = Join-Path $fixture.ToolchainRoot $relative
            [IO.Directory]::CreateDirectory((Split-Path -Parent $to)) | Out-Null
            Copy-Item -LiteralPath $from -Destination $to -Recurse -ErrorAction Stop
        }
        & git -C $fixture.ToolchainRoot init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'fixture-toolchain-git-init-failed' }
        foreach ($relative in @('AppData/Local','AppData/Roaming')) {
            [IO.Directory]::CreateDirectory((Join-Path $fixture.Home $relative)) | Out-Null
        }
        $fixture.Identity = [pscustomobject]@{
            ResolverVersion='sealed-home-authority-test-adapter-v1'
            TokenSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            ProfileRoot=$fixture.Home; RoamingAppDataRoot=(Join-Path $fixture.Home 'AppData/Roaming')
            LocalAppDataRoot=(Join-Path $fixture.Home 'AppData/Local')
        }
        # Read only installed, pinned cache bytes through the original adapter.
        # Do this before loading a copied module into the calling test's scope.
        . (Join-Path $source 'scripts/json-artifact-common.ps1')
        $cache = Join-Path $fixture.ToolchainRoot 'fixture-tool-cache'
        foreach ($relative in @('tools/schema-validator/validator.lock.json','tools/gitleaks/gitleaks.lock.json')) {
            $lock = Get-PinnedToolLock -Path (Join-Path $source $relative)
            $from = Get-PinnedToolPaths -Lock $lock
            $to = Get-PinnedToolPaths -Lock $lock -CacheRoot $cache
            foreach ($row in @(@($from.Archive,$to.Archive,$lock.AssetSha256),@($from.Executable,$to.Executable,$lock.ExecutableSha256))) {
                $bytes = [IO.File]::ReadAllBytes([string]$row[0])
                if ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne [string]$row[2]) {
                    throw 'fixture-pinned-tool-hash-mismatch'
                }
                $null = Assert-CanonicalIdentityFixturePath -Fixture $fixture -Path ([string]$row[1])
                [IO.Directory]::CreateDirectory((Split-Path -Parent ([string]$row[1]))) | Out-Null
                $stream=[IO.File]::Open([string]$row[1],[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
                try { $stream.Write($bytes); $stream.Flush($true) } finally { $stream.Dispose() }
            }
        }
        $identityAdapter = @'
function Get-WindowsHomeAuthorityIdentity {
    $fixtureRoot = '__FIXTURE_ROOT__'
    $fixtureHome = Join-Path $fixtureRoot 'home'
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'identity-called'), 'called')
    return [pscustomobject]@{
        ResolverVersion = 'sealed-home-authority-test-adapter-v1'
        TokenSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        ProfileRoot = $fixtureHome
        RoamingAppDataRoot = Join-Path $fixtureHome 'AppData/Roaming'
        LocalAppDataRoot = Join-Path $fixtureHome 'AppData/Local'
    }
}
'@
        $liveAdapter = @'
function Get-CanonicalDefaultLiveRoots {
    $fixtureHome = Join-Path '__FIXTURE_ROOT__' 'home'
    return @('.claude/skills','.codex/skills','.agents/skills','AppData/Roaming/reasonix/skills') | ForEach-Object { Join-Path $fixtureHome $_ }
}
'@
        $cacheAdapter = @'
function Get-PinnedToolCacheRoot {
    [CmdletBinding()] param([string]$CacheRoot)
    if ($CacheRoot) { return [IO.Path]::GetFullPath($CacheRoot) }
    return '__FIXTURE_CACHE__'
}
'@
        foreach ($adapter in @(
            @('home-authority-common.ps1','Get-WindowsHomeAuthorityIdentity',$identityAdapter),
            @('canonical-transaction-common.ps1','Get-CanonicalDefaultLiveRoots',$liveAdapter),
            @('json-artifact-common.ps1','Get-PinnedToolCacheRoot',$cacheAdapter))) {
            $path = Join-Path $fixture.ToolchainRoot ('scripts/'+$adapter[0]); $text=[IO.File]::ReadAllText($path)
            $tokens=$null; $errors=$null
            $ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$tokens,[ref]$errors)
            $name=[string]$adapter[1]
            $definitions=@($ast.FindAll({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name},$true))
            if ($errors.Count -ne 0 -or $definitions.Count -ne 1) { throw 'fixture-os-adapter-shape-mismatch' }
            $extent=$definitions[0].Extent
            $replacement=([string]$adapter[2]).Replace('__FIXTURE_ROOT__',$root.Replace("'","''")).Replace('__FIXTURE_CACHE__',$cache.Replace("'","''"))
            [IO.File]::WriteAllText($path,$text.Substring(0,$extent.StartOffset)+$replacement+$text.Substring($extent.EndOffset),[Text.UTF8Encoding]::new($false))
        }
        # Catch an incomplete copy before any owner-sensitive setup operation.
        . (Join-Path $fixture.ToolchainRoot 'scripts/canonical-transaction-common.ps1')
        $null = Get-CanonicalToolchainPolicyHash -ToolchainRoot $fixture.ToolchainRoot
        Assert-CanonicalIdentityFixtureOwned -Fixture $fixture
        $script:CanonicalIdentityFixtureActive=$fixture.Root
        return $fixture
    }
    catch {
        # Only this newly allocated, ownership-marked tree is eligible for cleanup.
        Remove-CanonicalIdentityFixture -Fixture $fixture
        throw
    }
}

function New-CanonicalIdentityFixtureProcessStartInfo {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ScriptPath,[string[]]$Arguments=@())
    Assert-CanonicalIdentityFixtureOwned -Fixture $Fixture
    $scriptFull = Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $ScriptPath
    if (-not $scriptFull.StartsWith(([string]$Fixture.ToolchainRoot+[IO.Path]::DirectorySeparatorChar),[StringComparison]::OrdinalIgnoreCase)) {
        throw 'fixture-child-must-use-copied-toolchain'
    }
    for ($index=0; $index -lt $Arguments.Count; $index++) {
        $argument=[string]$Arguments[$index]
        if ($argument -match '^-[A-Za-z]*(Path|Root|Workspace|Marker|Base)(?::(.*))?$') {
            $pathValue=if ($argument.Contains(':')) { [string]$Matches[2] } elseif ($index+1 -lt $Arguments.Count) { [string]$Arguments[$index+1] } else { '' }
            if (-not [IO.Path]::IsPathFullyQualified($pathValue)) { throw 'fixture-path-argument-must-be-absolute' }
            $null=Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $pathValue
        }
        if ([IO.Path]::IsPathFullyQualified($argument)) { $null=Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $argument }
    }
    $start=[Diagnostics.ProcessStartInfo]::new()
    $start.FileName=(Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true
    $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    $start.WorkingDirectory=[string]$Fixture.ToolchainRoot
    foreach ($key in @($start.Environment.Keys)) {
        if ($key -like 'AI_AGENT_DOTFILES_INTERNAL_*') { [void]$start.Environment.Remove($key) }
    }
    foreach ($argument in @('-NoProfile','-File',$scriptFull)+@($Arguments)) { [void]$start.ArgumentList.Add([string]$argument) }
    return $start
}

function Invoke-CanonicalIdentityFixtureScript {
    # The suite runner still owns its existing overall budget. Previously these
    # public wrappers waited indefinitely; avoid introducing a new 120s limit
    # on a full production transaction while retaining bounded child cleanup.
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ScriptPath,[string[]]$Arguments=@(),[ValidateRange(1,900000)][int]$TimeoutMilliseconds=900000)
    $process=[Diagnostics.Process]::new()
    $process.StartInfo=New-CanonicalIdentityFixtureProcessStartInfo -Fixture $Fixture -ScriptPath $ScriptPath -Arguments $Arguments
    try {
        if (-not $process.Start()) { throw 'fixture-child-start-failed' }
        $stdout=$process.StandardOutput.ReadToEndAsync(); $stderr=$process.StandardError.ReadToEndAsync()
        $Fixture.Children.Add([pscustomobject]@{Process=$process;StdoutStream=$null;StderrStream=$null;StdoutTask=$stdout;StderrTask=$stderr;Drained=$false})
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            Complete-CanonicalIdentityFixtureScript -Fixture $Fixture -Process $process -Stop
            throw 'fixture-child-timeout'
        }
        Complete-CanonicalIdentityFixtureScript -Fixture $Fixture -Process $process
        $outText=$stdout.GetAwaiter().GetResult(); $errText=$stderr.GetAwaiter().GetResult()
        return [pscustomobject]@{Code=$process.ExitCode;Stdout=$outText;Stderr=$errText;Out=($outText+$errText)}
    }
    finally {
        if (@($Fixture.Children | Where-Object { [object]::ReferenceEquals($_.Process,$process) }).Count) {
            Complete-CanonicalIdentityFixtureScript -Fixture $Fixture -Process $process -Stop
        }
        else { $process.Dispose() }
    }
}

function Start-CanonicalIdentityFixtureScript {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ScriptPath,[string[]]$Arguments=@(),
        [Parameter(Mandatory)][string]$StandardOutputPath,[Parameter(Mandatory)][string]$StandardErrorPath)
    $start=New-CanonicalIdentityFixtureProcessStartInfo -Fixture $Fixture -ScriptPath $ScriptPath -Arguments $Arguments
    $null=Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $StandardOutputPath
    $null=Assert-CanonicalIdentityFixturePath -Fixture $Fixture -Path $StandardErrorPath
    $process=[Diagnostics.Process]::new(); $process.StartInfo=$start
    $stdoutStream=$null; $stderrStream=$null
    try {
        $stdoutStream=[IO.File]::Open($StandardOutputPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $stderrStream=[IO.File]::Open($StandardErrorPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        if (-not $process.Start()) { throw 'fixture-child-start-failed' }
        $stdoutTask=$process.StandardOutput.BaseStream.CopyToAsync($stdoutStream)
        $stderrTask=$process.StandardError.BaseStream.CopyToAsync($stderrStream)
        $Fixture.Children.Add([pscustomobject]@{Process=$process;StdoutStream=$stdoutStream;StderrStream=$stderrStream;StdoutTask=$stdoutTask;StderrTask=$stderrTask;Drained=$false})
        return $process
    }
    catch {
        try { if ($process.Id -gt 0 -and -not $process.HasExited) { $process.Kill($true); $null=$process.WaitForExit(5000) } } catch { }
        if ($stdoutStream) { $stdoutStream.Dispose() }; if ($stderrStream) { $stderrStream.Dispose() }; $process.Dispose()
        throw
    }
}

function Complete-CanonicalIdentityFixtureScript {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][Diagnostics.Process]$Process,[switch]$Stop)
    $ownedChildren=@($Fixture.Children | Where-Object { [object]::ReferenceEquals($_.Process,$Process) })
    if ($ownedChildren.Count -ne 1) { throw 'fixture-child-ownership-required' }
    $child=$ownedChildren[0]
    if ($child.Drained) { return }
    if ($Stop -and -not $Process.HasExited) { $Process.Kill($true) }
    if (-not $Process.WaitForExit(5000)) { throw 'fixture-child-cleanup-timeout' }
    if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($child.StdoutTask,$child.StderrTask),5000)) { throw 'fixture-child-output-drain-timeout' }
    if ($null -ne $child.StdoutStream) { $child.StdoutStream.Flush($true); $child.StdoutStream.Dispose() }
    if ($null -ne $child.StderrStream) { $child.StderrStream.Flush($true); $child.StderrStream.Dispose() }
    $child.Drained=$true
}

function Invoke-CanonicalIdentityFixtureSandboxScript {
    param([Parameter(Mandatory)]$Fixture,[Parameter(Mandatory)][string]$ScriptPath,[string[]]$Arguments=@())
    # Validate the nested script and every absolute argument before encoding the
    # argument vector for the unchanged production internal host.
    $null=New-CanonicalIdentityFixtureProcessStartInfo -Fixture $Fixture -ScriptPath $ScriptPath -Arguments $Arguments
    $encoded=[Convert]::ToBase64String([Text.UTF8Encoding]::new($false).GetBytes((ConvertTo-Json -InputObject @($Arguments) -Compress)))
    return Invoke-CanonicalIdentityFixtureScript -Fixture $Fixture -ScriptPath (Join-Path $Fixture.ToolchainRoot 'scripts/internal/live-transaction-host.ps1') -Arguments @(
        '-SandboxRoot',[string]$Fixture.Root,'-ScriptPath',$ScriptPath,'-ArgumentsBase64',$encoded)
}
