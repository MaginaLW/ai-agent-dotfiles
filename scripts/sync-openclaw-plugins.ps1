#requires -Version 7.0
<#
.SYNOPSIS
    Desired-state sync of OpenClaw managed plugins against live plugin installs.
    Reads openclaw/plugins/managed-plugins.json, compares with live state from
    `openclaw plugins list --json`, and converges via OpenClaw CLI commands.

.DESCRIPTION
    Dry-run (default) reports what would change without mutating anything.
    -Apply runs plugin lifecycle commands through the OpenClaw CLI:

      * openclaw plugins install <source>
      * openclaw plugins update <id-or-source>
      * openclaw plugins enable <id>
      * openclaw plugins disable <id>
      * openclaw plugins uninstall <id>  (only when allowUninstall: true)

    Hard rules:
      * Never use --dangerously-force-unsafe-install.
      * Never hand-edit installs.json.
      * Bundled plugins are never uninstalled; enable/disable only.
      * Unknown live plugins are reported but never touched.
      * Absolute-path plugin sources are rejected.

    Newer OpenClaw versions report absolute install paths from `plugins list`.
    For managed plugins, the read-only `plugins info` surface is used to
    canonicalize the installed package name before source comparison.

.PARAMETER RepoRoot
    Path to the ai-agent-dotfiles repository root.

.PARAMETER HomeRoot
    Home directory used to resolve OpenClaw install state.
    Defaults to $env:USERPROFILE.

.PARAMETER Apply
    Actually perform the sync. Without it the script is a pure dry-run.

.PARAMETER DryRun
    Force dry-run mode (same as omitting -Apply). Provided for call-site symmetry.

.PARAMETER OpenClawCommand
    Optional OpenClaw executable or script used for the read-only list probe.
    Intended for isolated tests and alternate installations.

.PARAMETER CliProbeTimeoutSeconds
    Maximum seconds to wait for each read-only OpenClaw CLI probe before falling back
    to sanitized local state. Defaults to 15 seconds.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $DryRun,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE,
    [string] $OpenClawCommand,
    [ValidateRange(1, 120)]
    [int] $CliProbeTimeoutSeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw 'This script requires PowerShell 7 or newer. Run it with pwsh.'
}

# If -DryRun is explicitly passed, override -Apply.
if ($DryRun) { $Apply = $false }

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$HomeRoot = if (Test-Path -LiteralPath $HomeRoot) {
    (Resolve-Path -LiteralPath $HomeRoot).Path
} else {
    [System.IO.Path]::GetFullPath($HomeRoot)
}
$ManagedPluginsPath = Join-Path $RepoRoot 'openclaw\plugins\managed-plugins.json'
$InstallsJsonPath = Join-Path $HomeRoot '.openclaw\plugins\installs.json'
$OpenClawConfigPath = Join-Path $HomeRoot '.openclaw\openclaw.json'
$DefaultHomeRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')

function Test-IsDefaultHomeRoot {
    $currentHomeRoot = [System.IO.Path]::GetFullPath($HomeRoot).TrimEnd('\', '/')
    return $currentHomeRoot -eq $DefaultHomeRoot
}

function New-OpenClawProbeStartInfo {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $commandName = if ([string]::IsNullOrWhiteSpace($OpenClawCommand)) { 'openclaw' } else { $OpenClawCommand }
    $commandInfo = Get-Command -Name $commandName -ErrorAction Stop | Select-Object -First 1
    $commandPath = [string] $commandInfo.Path
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        $commandPath = [string] $commandInfo.Source
    }
    if ([string]::IsNullOrWhiteSpace($commandPath)) {
        throw "Could not resolve OpenClaw command '$commandName'."
    }

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $extension = [System.IO.Path]::GetExtension($commandPath).ToLowerInvariant()

    if ($commandInfo.CommandType -eq 'ExternalScript' -or $extension -eq '.ps1') {
        $pwshPath = (Get-Command pwsh -ErrorAction Stop | Select-Object -First 1).Source
        $startInfo.FileName = $pwshPath
        foreach ($argument in (@('-NoProfile', '-File', $commandPath) + @($Arguments))) {
            [void] $startInfo.ArgumentList.Add($argument)
        }
    }
    elseif ($extension -in @('.cmd', '.bat')) {
        $startInfo.FileName = $env:ComSpec
        [void] $startInfo.ArgumentList.Add('/d')
        [void] $startInfo.ArgumentList.Add('/s')
        [void] $startInfo.ArgumentList.Add('/c')
        $commandArguments = @($Arguments | ForEach-Object { '"{0}"' -f ([string] $_) }) -join ' '
        [void] $startInfo.ArgumentList.Add(('"{0}" {1}' -f $commandPath, $commandArguments))
    }
    else {
        $startInfo.FileName = $commandPath
        foreach ($argument in $Arguments) {
            [void] $startInfo.ArgumentList.Add($argument)
        }
    }

    return $startInfo
}

function Invoke-OpenClawProbe {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments
    )

    $process = $null
    try {
        $process = [System.Diagnostics.Process]::new()
        $process.StartInfo = New-OpenClawProbeStartInfo -Arguments $Arguments
        if (-not $process.Start()) {
            throw 'OpenClaw CLI process could not be started.'
        }

        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        $completed = $process.WaitForExit($CliProbeTimeoutSeconds * 1000)
        if (-not $completed) {
            try {
                $process.Kill($true)
            }
            catch {
                try { $process.Kill() } catch { }
            }
            try { [void] $process.WaitForExit(2000) } catch { }
            return [pscustomobject]@{
                Succeeded = $false
                TimedOut = $true
                ExitCode = $null
                Output = ''
                Error = "OpenClaw CLI probe timed out after $CliProbeTimeoutSeconds seconds."
            }
        }

        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
        return [pscustomobject]@{
            Succeeded = ($process.ExitCode -eq 0)
            TimedOut = $false
            ExitCode = $process.ExitCode
            Output = $stdout
            Error = $stderr
        }
    }
    catch {
        return [pscustomobject]@{
            Succeeded = $false
            TimedOut = $false
            ExitCode = $null
            Output = ''
            Error = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $process) {
            $process.Dispose()
        }
    }
}

function Invoke-OpenClawListProbe {
    return Invoke-OpenClawProbe -Arguments @('plugins', 'list', '--json')
}

function Invoke-OpenClawInfoProbe {
    param(
        [Parameter(Mandatory)] [string] $PluginId
    )

    return Invoke-OpenClawProbe -Arguments @('plugins', 'info', $PluginId, '--json')
}

function Get-ObjectPropertyValue {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name,
        [object] $Default = $null
    )

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function Test-ObjectProperty {
    param(
        [Parameter(Mandatory)] [object] $Object,
        [Parameter(Mandatory)] [string] $Name
    )

    return ($null -ne $Object.PSObject.Properties[$Name])
}

function Get-CanonicalPluginInstall {
    param(
        [Parameter(Mandatory)] [string] $PluginId
    )

    try {
        $probe = Invoke-OpenClawInfoProbe -PluginId $PluginId
        if (-not $probe.Succeeded -or [string]::IsNullOrWhiteSpace($probe.Output)) {
            if ($probe.TimedOut) {
                Write-Verbose "OpenClaw info probe for '$PluginId' timed out after $CliProbeTimeoutSeconds seconds."
            }
            else {
                Write-Verbose "OpenClaw info probe for '$PluginId' failed or returned empty output."
            }
            return $null
        }

        $json = $probe.Output | ConvertFrom-Json
        $install = Get-ObjectPropertyValue -Object $json -Name 'install'
        if ($null -eq $install) {
            Write-Verbose "OpenClaw info for '$PluginId' has no install metadata."
            return $null
        }

        $resolvedName = Get-ObjectPropertyValue -Object $install -Name 'resolvedName'
        if ([string]::IsNullOrWhiteSpace([string] $resolvedName)) {
            Write-Verbose "OpenClaw info for '$PluginId' has no resolved package name."
            return $null
        }

        return [pscustomobject]@{
            Source  = [string] $resolvedName
            Version = Get-ObjectPropertyValue -Object $install -Name 'resolvedVersion'
        }
    }
    catch {
        Write-Verbose "OpenClaw info probe for '$PluginId' was unavailable: $($_.Exception.Message)"
        return $null
    }
}

function Resolve-CanonicalLivePluginSources {
    param(
        [AllowEmptyCollection()] [object[]] $Live,
        [AllowEmptyCollection()] [object[]] $Managed
    )

    $managedById = @{}
    foreach ($plugin in @($Managed)) {
        $id = Get-ObjectPropertyValue -Object $plugin -Name 'id'
        if (-not [string]::IsNullOrWhiteSpace([string] $id)) {
            $managedById[([string] $id).ToLowerInvariant()] = $plugin
        }
    }

    $resolved = @()
    foreach ($plugin in @($Live)) {
        $id = Get-ObjectPropertyValue -Object $plugin -Name 'id'
        $source = Get-ObjectPropertyValue -Object $plugin -Name 'source'
        if ([string]::IsNullOrWhiteSpace([string] $id) -or
            -not $managedById.ContainsKey(([string] $id).ToLowerInvariant()) -or
            [string]::IsNullOrWhiteSpace([string] $source) -or
            -not [System.IO.Path]::IsPathRooted([string] $source)) {
            $resolved += $plugin
            continue
        }

        $install = Get-CanonicalPluginInstall -PluginId ([string] $id)
        if ($null -ne $install) {
            $plugin.source = $install.Source
            if ($null -ne $install.Version -and -not [string]::IsNullOrWhiteSpace([string] $install.Version)) {
                $plugin.version = $install.Version
            }
            Write-Verbose "Canonicalized live source for '$id' to '$($install.Source)'."
        }
        $resolved += $plugin
    }

    return @($resolved)
}

# ---------------------------------------------------------------------------
# Schema validation
# ---------------------------------------------------------------------------

$ValidPluginFields = @('id', 'source', 'bundled', 'enabled', 'allowUninstall', 'marketplace')

function Test-RecognizedPluginFields {
    param([Parameter(Mandatory)] [object] $Plugin)
    $keys = $Plugin | Get-Member -MemberType NoteProperty | ForEach-Object Name
    $pluginId = Get-ObjectPropertyValue -Object $Plugin -Name 'id' -Default '<unknown>'
    foreach ($k in $keys) {
        if ($k -notin $ValidPluginFields) {
            Write-Error "Unrecognized field '$k' in managed plugin '$pluginId'. Allowed: $($ValidPluginFields -join ', ')"
            return $false
        }
    }
    return $true
}

function Assert-ValidManagedPlugins {
    param([Parameter(Mandatory)] [object] $Doc)

    if ($Doc.version -ne 1) { throw "Unsupported managed-plugins.json version: $($Doc.version)" }

    $ids = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $i = 0
    foreach ($p in $Doc.plugins) {
        $id = Get-ObjectPropertyValue -Object $p -Name 'id'
        if (-not $id) { Write-Error "Plugin at index $i is missing 'id'."; return $false }
        if ($false -eq (Test-RecognizedPluginFields -Plugin $p)) { return $false }
        if (-not (Test-ObjectProperty -Object $p -Name 'enabled')) {
            Write-Error "Plugin '$id' is missing required field 'enabled'."
            return $false
        }

        $bundled = [bool](Get-ObjectPropertyValue -Object $p -Name 'bundled' -Default $false)
        $source = Get-ObjectPropertyValue -Object $p -Name 'source'
        if ($bundled) {
            # Bundled plugins must not have a source (unless it is a documented alias).
            if ($source) {
                $allowedBundledSources = @(
                    '@openclaw/codex'  # codex is bundled in some deployments
                )
                if ($source -notin $allowedBundledSources) {
                    Write-Error "Bundled plugin '$id' must not declare a custom source ('$source'). Remove 'source' or set 'bundled: false'."
                    return $false
                }
            }
        } else {
            # Non-bundled plugins require 'source'.
            if (-not $source) {
                Write-Error "Managed plugin '$id' is not bundled and must declare 'source'."
                return $false
            }
            # Reject absolute local paths.
            if ([System.IO.Path]::IsPathRooted($source)) {
                Write-Error "Managed plugin '$id' has an absolute local path source ('$source'). Only npm/clawhub/git/npm-pack specs are allowed."
                return $false
            }
        }

        # Marketplace: if present, 'source' is required alongside it.
        $marketplace = Get-ObjectPropertyValue -Object $p -Name 'marketplace'
        if ($marketplace -and -not $source) {
            Write-Error "Plugin '$id' has 'marketplace' set but no 'source'."
            return $false
        }

        # allowUninstall defaults to false.
        if (-not (Test-ObjectProperty -Object $p -Name 'allowUninstall')) {
            $p | Add-Member -NotePropertyName 'allowUninstall' -NotePropertyValue $false -Force
        }

        # Duplicate id check.
        if (-not $ids.Add($id)) {
            Write-Error "Duplicate plugin id '$id' in managed-plugins.json."
            return $false
        }
        $i++
    }

    return $true
}

# ---------------------------------------------------------------------------
# Live plugin state
# ---------------------------------------------------------------------------

function Get-LivePlugins {
    <#
        Returns a list of live plugin records:
        [pscustomobject]@{ id, source, enabled, origin, version }
        Falls back to sanitized installs.json or openclaw.json enablement state
        when CLI is unavailable; fails closed if neither state surface exists.
    #>

    param(
        [AllowEmptyCollection()] [object[]] $ManagedPlugins = @()
    )

    $useCliProbe = (Test-IsDefaultHomeRoot) -or (-not [string]::IsNullOrWhiteSpace($OpenClawCommand))
    $probeAttempted = $false
    $probeFailed = $false
    Write-Verbose "OpenClaw list probe enabled=$useCliProbe custom-command=$(-not [string]::IsNullOrWhiteSpace($OpenClawCommand)) default-home=$(Test-IsDefaultHomeRoot)"
    if ($useCliProbe) {
        $probeAttempted = $true
        try {
            $probe = Invoke-OpenClawListProbe
            if ($probe.Succeeded -and -not [string]::IsNullOrWhiteSpace($probe.Output)) {
                $json = $probe.Output | ConvertFrom-Json
                $pluginsProperty = $json.PSObject.Properties['plugins']
                if ($null -ne $pluginsProperty) {
                    $plugins = @($pluginsProperty.Value)
                    $live = @()
                    foreach ($p in $plugins) {
                        $id = Get-ObjectPropertyValue -Object $p -Name 'id' -Default (Get-ObjectPropertyValue -Object $p -Name 'pluginId')
                        if (-not $id) { continue }
                        $live += [pscustomobject] @{
                            id      = $id
                            source  = Get-ObjectPropertyValue -Object $p -Name 'source'
                            enabled = [bool](Get-ObjectPropertyValue -Object $p -Name 'enabled' -Default $false)
                            origin  = Get-ObjectPropertyValue -Object $p -Name 'origin' -Default 'unknown'
                            version = Get-ObjectPropertyValue -Object $p -Name 'version'
                        }
                    }
                    Write-Verbose "Got $($live.Count) plugins from openclaw CLI."
                    return (Resolve-CanonicalLivePluginSources -Live $live -Managed $ManagedPlugins)
                }
            }
            if ($probe.TimedOut) {
                $probeFailed = $true
                Write-Warning "OpenClaw CLI probe timed out after $CliProbeTimeoutSeconds seconds. Falling back to sanitized local state."
            }
            elseif (-not [string]::IsNullOrWhiteSpace($probe.Error)) {
                $probeFailed = $true
                Write-Verbose "openclaw CLI probe failed: $($probe.Error). Falling back to sanitized local state."
            }
            else {
                $probeFailed = $true
                Write-Verbose "openclaw CLI returned empty, failed, or unexpected output. Falling back to sanitized local state."
            }
        }
        catch {
            $probeFailed = $true
            Write-Verbose "openclaw CLI probe unavailable: $($_.Exception.Message). Falling back to sanitized local state."
        }
    }

    if (Test-Path -LiteralPath $InstallsJsonPath -PathType Leaf) {
        try {
            return Get-LivePluginsFromInstallsJson
        }
        catch {
            $probeFailed = $true
            Write-Warning "Failed to use installs.json as live plugin state: $($_.Exception.Message)"
        }
    }

    $configLive = @(Get-LivePluginsFromConfig)
    if ($configLive.Count -gt 0) {
        Write-Warning 'Using plugin enablement from openclaw.json. Installation/source parity is not attestable.'
        return $configLive
    }

    if ($probeAttempted -and $probeFailed) {
        throw 'OpenClaw live plugin state is unavailable: the CLI probe failed and no sanitized fallback state exists; refusing to treat live state as empty.'
    }

    return @()
}

function Get-LivePluginsFromInstallsJson {
    if (-not (Test-Path -LiteralPath $InstallsJsonPath)) {
        Write-Verbose "No installs.json found at $InstallsJsonPath."
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $InstallsJsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        $live = @()
        $pluginsProperty = $raw.PSObject.Properties['plugins']
        if ($null -eq $pluginsProperty) {
            throw "installs.json is missing the top-level 'plugins' field."
        }
        $plugins = @($pluginsProperty.Value)
        if ($plugins.Count -gt 0) {
            foreach ($p in $plugins) {
                $id = Get-ObjectPropertyValue -Object $p -Name 'id' -Default (Get-ObjectPropertyValue -Object $p -Name 'pluginId')
                if (-not $id) { continue }
                $live += [pscustomobject] @{
                    id      = $id
                    source  = Get-ObjectPropertyValue -Object $p -Name 'source'
                    enabled = [bool](Get-ObjectPropertyValue -Object $p -Name 'enabled' -Default $false)
                    origin  = Get-ObjectPropertyValue -Object $p -Name 'origin' -Default 'unknown'
                    version = Get-ObjectPropertyValue -Object $p -Name 'version'
                }
            }
        }
        Write-Verbose "Got $($live.Count) plugins from installs.json."
        return $live
    }
    catch {
        throw "Failed to parse installs.json: $($_.Exception.Message)"
    }
}

function Get-LivePluginsFromConfig {
    if (-not (Test-Path -LiteralPath $OpenClawConfigPath -PathType Leaf)) {
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $OpenClawConfigPath -Raw -Encoding utf8 | ConvertFrom-Json
        $plugins = Get-ObjectPropertyValue -Object $raw -Name 'plugins' -Default $null
        $entries = if ($null -ne $plugins) {
            Get-ObjectPropertyValue -Object $plugins -Name 'entries' -Default $null
        } else {
            $null
        }
        if ($null -eq $entries) {
            return @()
        }

        $live = @()
        foreach ($property in @($entries.PSObject.Properties)) {
            $entry = $property.Value
            $live += [pscustomobject]@{
                id      = $property.Name
                source  = $null
                enabled = [bool](Get-ObjectPropertyValue -Object $entry -Name 'enabled' -Default $false)
                origin  = 'config'
                version = $null
            }
        }
        if ($live.Count -gt 0) {
            Write-Verbose "Got $($live.Count) plugin enablement entries from openclaw.json."
            return $live
        }
    }
    catch {
        Write-Verbose 'Failed to parse openclaw.json plugin entries. Falling back without exposing config values.'
    }

    return @()
}

# ---------------------------------------------------------------------------
# Plan computation
# ---------------------------------------------------------------------------

function Compute-PluginPlan {
    param(
        [Parameter(Mandatory)] [object[]] $Managed,
        [object[]] $Live
    )

    $Live = @($Live)

    $managedById = @{}
    foreach ($m in $Managed) {
        $id = Get-ObjectPropertyValue -Object $m -Name 'id'
        $managedById[$id.ToLowerInvariant()] = $m
    }

    $liveById = @{}
    foreach ($l in $Live) { $liveById[$l.id.ToLowerInvariant()] = $l }

    $toInstall = @()
    $toUpdate = @()
    $toEnable = @()
    $toDisable = @()
    $toUninstall = @()
    $unknownLive = @()
    $bundledPreserved = @()

    # Check managed plugins against live state.
    foreach ($kv in $managedById.GetEnumerator()) {
        $id = $kv.Key
        $m = $kv.Value
        $l = $liveById[$id]
        $managedEnabled = [bool](Get-ObjectPropertyValue -Object $m -Name 'enabled' -Default $false)
        $managedSource = Get-ObjectPropertyValue -Object $m -Name 'source'
        $managedBundled = [bool](Get-ObjectPropertyValue -Object $m -Name 'bundled' -Default $false)

        if (-not $l) {
            # Not installed -> install.
            $toInstall += $m
            continue
        }

        # Installed — check enablement.
        if ($managedEnabled -and -not $l.enabled) {
            $toEnable += $m
        } elseif (-not $managedEnabled -and $l.enabled) {
            $toDisable += $m
        }

        # Check source: if managed source differs and the plugin is not bundled,
        # flag for update.
        if ($managedSource -and $l.source -and ($managedSource -ne $l.source) -and -not $managedBundled) {
            $toUpdate += $m
        }

        # Bundled: track as preserved (never uninstall).
        if ($managedBundled) {
            $bundledPreserved += (Get-ObjectPropertyValue -Object $m -Name 'id')
        }
    }

    # Check for managed plugins that should be uninstalled.
    # Managed entries with allowUninstall:true that are removed from managed list.
    # (We actually don't auto-uninstall — uninstall only happens when a managed
    # entry has allowUninstall:true and we decide to remove it. For now, if it's
    # in the managed list, we keep it. If it's removed from the managed list and
    # was previously managed, the user should add an entry with enabled:false
    # and uninstall will happen on that.)

    # Unknown live: plugins in live that are not in managed list.
    foreach ($kv in $liveById.GetEnumerator()) {
        $id = $kv.Key
        if (-not $managedById.ContainsKey($id)) {
            $unknownLive += $kv.Value
        }
    }

    return [pscustomobject] @{
        ToInstall          = @($toInstall | Sort-Object id)
        ToUpdate           = @($toUpdate | Sort-Object id)
        ToEnable           = @($toEnable | Sort-Object id)
        ToDisable          = @($toDisable | Sort-Object id)
        ToUninstall        = @($toUninstall | Sort-Object id)
        UnknownLive        = @($unknownLive | Sort-Object id)
        BundledPreserved   = @($bundledPreserved | Sort-Object)
        ManagedCount       = $Managed.Count
        LiveCount          = $Live.Count
    }
}

# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------

function Write-PluginPlanReport {
    param([Parameter(Mandatory)] [object] $Plan)

    function Format-PluginList {
        param([object[]] $Items, [scriptblock] $Formatter)
        if ($Items.Count -eq 0) { return '<none>' }
        return ($Items | ForEach-Object $Formatter) -join ', '
    }

    Write-Host ''
    Write-Host '[openclaw-plugins]'
    Write-Host "  managed : $($Plan.ManagedCount) plugins from managed-plugins.json"
    Write-Host "  live    : $($Plan.LiveCount) plugins"

    Write-Host "  would install  ($($Plan.ToInstall.Count)) : $(Format-PluginList $Plan.ToInstall { "$($_.id) ($($_.source))" })"
    Write-Host "  would update   ($($Plan.ToUpdate.Count))  : $(Format-PluginList $Plan.ToUpdate { "$($_.id) ($($_.source))" })"
    Write-Host "  would enable   ($($Plan.ToEnable.Count))  : $(Format-PluginList $Plan.ToEnable { $_.id })"
    Write-Host "  would disable  ($($Plan.ToDisable.Count)) : $(Format-PluginList $Plan.ToDisable { $_.id })"
    Write-Host "  would uninstall ($($Plan.ToUninstall.Count)) : $(Format-PluginList $Plan.ToUninstall { $_.id })"
    Write-Host "  unknown plugins ($($Plan.UnknownLive.Count)) (ignored): $(Format-PluginList $Plan.UnknownLive { $_.id })"
    if ($Plan.BundledPreserved.Count -gt 0) {
        Write-Host "  bundled preserved: $($Plan.BundledPreserved -join ', ')"
    }
}

# ---------------------------------------------------------------------------
# Apply helpers
# ---------------------------------------------------------------------------

function Invoke-OpenClawPlugin {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [string] $Description
    )

    Write-Host "  [plugin] openclaw $($Arguments -join ' ')  :: $Description"
    $result = & openclaw plugins @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0) {
        $errorLines = $result | Where-Object { $_ -match 'error|fail|denied|block' } | Select-Object -First 5
        if ($errorLines) {
            Write-Host "  [plugin] ERROR: $($errorLines -join ' | ')"
        }
        Write-Host "  [plugin] ERROR: openclaw plugins $($Arguments -join ' ') failed with exit code $code."
        Write-Host "  [plugin] Full output:"
        $result | ForEach-Object { Write-Host "    $_" }
        throw "openclaw plugins $($Arguments -join ' ') failed (exit $code)"
    }
    Write-Host "  [plugin] OK"
}

function Apply-PluginInstall {
    param([Parameter(Mandatory)] [object] $Plugin)
    $source = Get-ObjectPropertyValue -Object $Plugin -Name 'source'
    $marketplace = Get-ObjectPropertyValue -Object $Plugin -Name 'marketplace'
    $id = Get-ObjectPropertyValue -Object $Plugin -Name 'id'
    $args = @('install', $source)
    if ($marketplace) { $args += @('--marketplace', $marketplace) }
    Invoke-OpenClawPlugin -Arguments $args -Description "install $id"
}

function Apply-PluginUpdate {
    param([Parameter(Mandatory)] [object] $Plugin)
    $source = Get-ObjectPropertyValue -Object $Plugin -Name 'source'
    $id = Get-ObjectPropertyValue -Object $Plugin -Name 'id'
    Invoke-OpenClawPlugin -Arguments @('update', $source) -Description "update $id"
}

function Apply-PluginEnable {
    param([Parameter(Mandatory)] [object] $Plugin)
    $id = Get-ObjectPropertyValue -Object $Plugin -Name 'id'
    Invoke-OpenClawPlugin -Arguments @('enable', $id) -Description "enable $id"
}

function Apply-PluginDisable {
    param([Parameter(Mandatory)] [object] $Plugin)
    $id = Get-ObjectPropertyValue -Object $Plugin -Name 'id'
    Invoke-OpenClawPlugin -Arguments @('disable', $id) -Description "disable $id"
}

function Apply-PluginUninstall {
    param([Parameter(Mandatory)] [object] $Plugin)

    $id = Get-ObjectPropertyValue -Object $Plugin -Name 'id'
    $allowUninstall = [bool](Get-ObjectPropertyValue -Object $Plugin -Name 'allowUninstall' -Default $false)
    if (-not $allowUninstall) {
        Write-Warning "Skipping uninstall of '$id': allowUninstall is not true."
        return
    }

    # Dry-run first to confirm.
    Write-Host "  [plugin] openclaw plugins uninstall $id --dry-run  :: pre-flight check"
    $dryResult = & openclaw plugins uninstall $id --dry-run 2>&1
    $dryCode = $LASTEXITCODE
    if ($dryCode -ne 0) {
        Write-Host "  [plugin] WARNING: uninstall dry-run failed (exit $dryCode). Output:"
        $dryResult | ForEach-Object { Write-Host "    $_" }
    } else {
        Write-Host "  [plugin] dry-run OK"
    }

    Invoke-OpenClawPlugin -Arguments @('uninstall', $id) -Description "uninstall $id"
}

function Apply-PluginPlan {
    param([Parameter(Mandatory)] [object] $Plan)

    foreach ($p in $Plan.ToInstall) {
        Apply-PluginInstall -Plugin $p
    }
    foreach ($p in $Plan.ToUpdate) {
        Apply-PluginUpdate -Plugin $p
    }
    foreach ($p in $Plan.ToEnable) {
        Apply-PluginEnable -Plugin $p
    }
    foreach ($p in $Plan.ToDisable) {
        Apply-PluginDisable -Plugin $p
    }
    foreach ($p in $Plan.ToUninstall) {
        Apply-PluginUninstall -Plugin $p
    }
}

# ---------------------------------------------------------------------------
# Post-apply verification
# ---------------------------------------------------------------------------

function Test-PluginParity {
    param(
        [Parameter(Mandatory)] [object[]] $Managed,
        [object[]] $Live
    )

    $Live = @($Live)

    $liveById = @{}
    foreach ($l in $Live) { $liveById[$l.id.ToLowerInvariant()] = $l }

    $allOk = $true
    foreach ($m in $Managed) {
        $id = Get-ObjectPropertyValue -Object $m -Name 'id'
        $enabled = [bool](Get-ObjectPropertyValue -Object $m -Name 'enabled' -Default $false)
        $l = $liveById[$id.ToLowerInvariant()]
        if (-not $l) {
            Write-Host "  [verify] MISSING: $id"
            $allOk = $false
            continue
        }
        if ($enabled -ne $l.enabled) {
            Write-Host "  [verify] ENABLEMENT MISMATCH: $id  managed=$enabled  live=$($l.enabled)"
            $allOk = $false
        }
    }
    return $allOk
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host '=== sync-openclaw-plugins.ps1 ==='
Write-Host "Mode         : $(if ($Apply) { 'APPLY' } else { 'DRY-RUN (no changes)' })"
Write-Host "Repo         : $RepoRoot"
Write-Host "Home         : $HomeRoot"
Write-Host "Managed file : $ManagedPluginsPath"

# --- Load managed plugins ---
if (-not (Test-Path -LiteralPath $ManagedPluginsPath)) {
    Write-Host ''
    Write-Host "No managed-plugins.json found. Nothing to sync."
    exit 0
}

try {
    $managedDoc = Get-Content -LiteralPath $ManagedPluginsPath -Raw -Encoding utf8 | ConvertFrom-Json
}
catch {
    Write-Error "Failed to parse $ManagedPluginsPath : $($_.Exception.Message)"
    exit 1
}

# --- Validate schema ---
if (-not (Assert-ValidManagedPlugins -Doc $managedDoc)) {
    Write-Error "managed-plugins.json validation failed."
    exit 1
}

$managedPlugins = @($managedDoc.plugins)
Write-Host "Managed plugin count: $($managedPlugins.Count)"

# --- Get live plugins ---
$liveResult = Get-LivePlugins -ManagedPlugins $managedPlugins
$livePlugins = @($liveResult)
Write-Host "Live plugin count   : $($livePlugins.Count)"

# --- Compute plan ---
if ($managedPlugins.Count -eq 0 -and $livePlugins.Count -eq 0) {
    Write-Host ''
    Write-Host '[openclaw-plugins] No managed or live plugins to compare.'
    Write-Host 'Plugin sync DRY-RUN: no changes needed.'
    exit 0
}

$plan = Compute-PluginPlan -Managed $managedPlugins -Live $livePlugins
Write-PluginPlanReport -Plan $plan

# --- Dry-run exit ---
if (-not $Apply) {
    $totalChanges = $plan.ToInstall.Count + $plan.ToUpdate.Count + $plan.ToEnable.Count +
                    $plan.ToDisable.Count + $plan.ToUninstall.Count
    Write-Host ''
    if ($totalChanges -eq 0) {
        Write-Host 'Plugin sync DRY-RUN: no changes needed.'
    } else {
        Write-Host "Plugin sync DRY-RUN: $totalChanges change(s) would be applied. Re-run with -Apply to execute."
    }
    exit 0
}

# ---------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------

if (-not (Test-IsDefaultHomeRoot)) {
    Write-Host ''
    Write-Host "ERROR: Refusing plugin apply for custom HomeRoot: $HomeRoot"
    Write-Host 'Plugin lifecycle commands target the real OpenClaw CLI profile. Use dry-run for fake homes.'
    exit 1
}

$totalChanges = $plan.ToInstall.Count + $plan.ToUpdate.Count + $plan.ToEnable.Count +
                $plan.ToDisable.Count + $plan.ToUninstall.Count

if ($totalChanges -eq 0) {
    Write-Host ''
    Write-Host 'Plugin sync APPLY: no changes needed.'
    exit 0
}

Write-Host ''
Write-Host '----- APPLYING PLUGIN CHANGES -----'
try {
    Apply-PluginPlan -Plan $plan
}
catch {
    Write-Host "ERROR during plugin apply: $($_.Exception.Message)"
    exit 1
}

# --- Post-apply verification ---
Write-Host ''
Write-Host '----- VERIFYING PLUGIN STATE -----'
$liveAfter = Get-LivePlugins
$parity = Test-PluginParity -Managed $managedPlugins -Live $liveAfter
if ($parity) {
    Write-Host "Plugin parity check: OK"
} else {
    Write-Host "Plugin parity check: MISMATCH (see above)"
    exit 1
}

Write-Host ''
Write-Host 'Plugin sync APPLY complete.'
Write-Host "  installed: $($plan.ToInstall.Count)"
Write-Host "  updated  : $($plan.ToUpdate.Count)"
Write-Host "  enabled  : $($plan.ToEnable.Count)"
Write-Host "  disabled : $($plan.ToDisable.Count)"
Write-Host "  uninstalled: $($plan.ToUninstall.Count)"
Write-Host "  unknown plugins preserved: $($plan.UnknownLive.Count)"
exit 0
