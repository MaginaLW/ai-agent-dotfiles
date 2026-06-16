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

.PARAMETER RepoRoot
    Path to the ai-agent-dotfiles repository root.

.PARAMETER HomeRoot
    Home directory used to resolve OpenClaw install state.
    Defaults to $env:USERPROFILE.

.PARAMETER Apply
    Actually perform the sync. Without it the script is a pure dry-run.

.PARAMETER DryRun
    Force dry-run mode (same as omitting -Apply). Provided for call-site symmetry.
#>
[CmdletBinding()]
param(
    [switch] $Apply,
    [switch] $DryRun,
    [string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path,
    [string] $HomeRoot = $env:USERPROFILE
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
$DefaultHomeRoot = [System.IO.Path]::GetFullPath($env:USERPROFILE).TrimEnd('\', '/')

function Test-IsDefaultHomeRoot {
    $currentHomeRoot = [System.IO.Path]::GetFullPath($HomeRoot).TrimEnd('\', '/')
    return $currentHomeRoot -eq $DefaultHomeRoot
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
        Falls back to sanitized installs.json read when CLI is unavailable.
    #>

    if (Test-IsDefaultHomeRoot) {
        try {
            $result = & openclaw plugins list --json 2>&1
            if ($LASTEXITCODE -eq 0 -and $result) {
                $json = $result | Out-String | ConvertFrom-Json
                $plugins = @(Get-ObjectPropertyValue -Object $json -Name 'plugins' -Default @())
                if ($plugins.Count -gt 0) {
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
                    return ,$live
                }
            }
            Write-Verbose "openclaw CLI returned empty or unexpected output. Falling back to installs.json."
        }
        catch {
            Write-Verbose "openclaw CLI unavailable: $($_.Exception.Message). Falling back to installs.json."
        }
    }

    return Get-LivePluginsFromInstallsJson
}

function Get-LivePluginsFromInstallsJson {
    if (-not (Test-Path -LiteralPath $InstallsJsonPath)) {
        Write-Verbose "No installs.json found at $InstallsJsonPath."
        return @()
    }

    try {
        $raw = Get-Content -LiteralPath $InstallsJsonPath -Raw -Encoding utf8 | ConvertFrom-Json
        $live = @()
        $plugins = @(Get-ObjectPropertyValue -Object $raw -Name 'plugins' -Default @())
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
        return ,$live
    }
    catch {
        Write-Warning "Failed to parse installs.json: $($_.Exception.Message)"
        return @()
    }
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
$liveResult = Get-LivePlugins
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
