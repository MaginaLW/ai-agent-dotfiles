#requires -Version 7.0

Set-StrictMode -Version Latest

function Get-LiveSafetyPolicy {
    [CmdletBinding()]
    param()
    $path = Join-Path $PSScriptRoot 'live-safety-policy.psd1'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'safety-protocol-upgrade-required: live safety policy is missing.' }
    $policy = Import-PowerShellDataFile -LiteralPath $path
    if (
        [int] $policy.ProtocolVersion -ne 3 -or
        [string] $policy.ReleaseState -notin @('interlocked', 'released') -or
        [string]::IsNullOrWhiteSpace([string] $policy.InterlockDiagnostic)
    ) {
        throw 'safety-protocol-upgrade-required: live safety policy is invalid.'
    }
    return $policy
}

function Test-LiveSafetyPathInsideRoot {
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Root)
    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd([char]92, [char]47)
    $fullRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]47)
    return $fullPath.Equals($fullRoot, [System.StringComparison]::OrdinalIgnoreCase) -or
        $fullPath.StartsWith($fullRoot + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)
}

function Get-LiveSafetyOsTempRoot {
    $temp = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([char]92, [char]47)
    if (-not (Test-Path -LiteralPath $temp -PathType Container)) { throw 'OS temporary root is unavailable.' }
    return $temp
}

function New-LiveSafetySandboxCapability {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $SandboxRoot)

    $root = (Resolve-Path -LiteralPath $SandboxRoot).Path
    $temp = Get-LiveSafetyOsTempRoot
    if ($root.Equals($temp, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-LiveSafetyPathInsideRoot -Path $root -Root $temp)) {
        throw 'Internal live-safety sandbox must be a dedicated descendant of the OS temporary root.'
    }
    $path = Join-Path $root ".live-safety-capability-$([Guid]::NewGuid().ToString('N'))"
    $token = [Guid]::NewGuid().ToString('N')
    $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($token)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose()
        $stream = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        return [pscustomobject]@{ Root = $root; Path = $path; Token = $token; Stream = $stream }
    }
    catch { $stream.Dispose(); throw }
}

function Test-LiveSafetySandboxCapability {
    [CmdletBinding()]
    param([AllowEmptyCollection()] [string[]] $Paths = @())

    $rootText = $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT
    $pathText = $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_PATH
    $tokenText = $env:AI_AGENT_DOTFILES_INTERNAL_CAPABILITY_TOKEN
    if ([string]::IsNullOrWhiteSpace($rootText) -or [string]::IsNullOrWhiteSpace($pathText) -or [string]::IsNullOrWhiteSpace($tokenText)) {
        if ($env:AI_AGENT_DOTFILES_INTERNAL_HOST_DEBUG -eq '1') { Write-Host 'Sandbox capability debug: environment locator is incomplete.' }
        return $false
    }
    try {
        $root = (Resolve-Path -LiteralPath $rootText).Path
        $temp = Get-LiveSafetyOsTempRoot
        if ($root.Equals($temp, [System.StringComparison]::OrdinalIgnoreCase) -or -not (Test-LiveSafetyPathInsideRoot -Path $root -Root $temp)) { throw 'sandbox root is not a dedicated OS-temp descendant' }
        $capabilityPath = [System.IO.Path]::GetFullPath($pathText)
        if (-not (Test-LiveSafetyPathInsideRoot -Path $capabilityPath -Root $root) -or -not (Test-Path -LiteralPath $capabilityPath -PathType Leaf)) { throw 'capability locator is missing or outside the sandbox' }
        if ([System.IO.File]::ReadAllText($capabilityPath, [System.Text.Encoding]::ASCII) -cne $tokenText) { throw 'capability token does not match' }
        $exclusiveOpened = $false
        try {
            $probe = [System.IO.File]::Open($capabilityPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
            $exclusiveOpened = $true
            $probe.Dispose()
        }
        catch [System.IO.IOException] { }
        catch [System.UnauthorizedAccessException] { }
        if ($exclusiveOpened) { throw 'capability file is not held by the internal host' }
        foreach ($candidate in @($Paths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })) {
            if (-not (Test-LiveSafetyPathInsideRoot -Path ([System.IO.Path]::GetFullPath($candidate)) -Root $root)) { throw "mutation path is outside the sandbox: $candidate" }
        }
        return $true
    }
    catch {
        if ($env:AI_AGENT_DOTFILES_INTERNAL_HOST_DEBUG -eq '1') { Write-Host "Sandbox capability debug: $($_.Exception.Message)" }
        return $false
    }
}

function Assert-LiveSafetyMutationAllowed {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Operation,
        [AllowEmptyCollection()] [string[]] $Paths = @()
    )

    $policy = Get-LiveSafetyPolicy
    if ([string] $policy.ReleaseState -eq 'released') { return }
    if (Test-LiveSafetySandboxCapability -Paths $Paths) { return }
    throw "$($policy.InterlockDiagnostic): ProtocolVersion=$($policy.ProtocolVersion) ReleaseState=$($policy.ReleaseState); production mutation '$Operation' is unavailable until the reviewed live-safety protocol is released."
}

function Get-LiveSafetyTemporaryRoot {
    [CmdletBinding()]
    param()

    if (-not [string]::IsNullOrWhiteSpace($env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT)) {
        $candidate = Join-Path $env:AI_AGENT_DOTFILES_INTERNAL_SANDBOX_ROOT 'internal-temp'
        if (Test-LiveSafetySandboxCapability -Paths @($candidate)) {
            [System.IO.Directory]::CreateDirectory($candidate) | Out-Null
            return $candidate
        }
    }
    return [System.IO.Path]::GetTempPath()
}
