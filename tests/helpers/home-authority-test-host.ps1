#requires -Version 7.0

# Tests-only sealed identity adapter. Production scripts never dot-source this
# file and expose no HomeRoot/BackupRoot/lock-wait selector.

Set-StrictMode -Version Latest

function Resolve-SealedHomeAuthorityTestContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$ProfileRoot,
        [Parameter(Mandatory)][string]$RoamingAppDataRoot,
        [Parameter(Mandatory)][string]$LocalAppDataRoot,
        [string]$ReasonixLiveSkillsPath,
        [string[]]$ForbiddenRoots = @()
    )

    $identity = [pscustomobject][ordered]@{
        ResolverVersion = 'sealed-home-authority-test-adapter-v1'
        TokenSid = $TokenSid
        ProfileRoot = $ProfileRoot
        RoamingAppDataRoot = $RoamingAppDataRoot
        LocalAppDataRoot = $LocalAppDataRoot
    }
    $arguments = @{
        Identity = $identity
        ForbiddenRoots = @($ForbiddenRoots)
    }
    if (-not [string]::IsNullOrWhiteSpace($ReasonixLiveSkillsPath)) {
        $arguments.ReasonixLiveSkillsPath = $ReasonixLiveSkillsPath
    }
    return Resolve-HomeAuthorityContextFromIdentity @arguments
}
