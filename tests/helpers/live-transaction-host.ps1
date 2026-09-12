#requires -Version 7.0

<#
.SYNOPSIS
    Test host for the receipt-backed and state-only live transaction engines.
    Runs inside the internal sandbox (through scripts/internal/live-transaction-host.ps1)
    when the caller needs the capability-gated failpoints.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('produce', 'state-only', 'reserve')] [string] $Mode,
    [string] $ProducerArgsJson,
    [string] $FailpointsJson,
    [string] $RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/live-transaction-common.ps1')
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')

function ConvertTo-OrderedLiveTxValue {
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys)) { $result[[string] $key] = ConvertTo-OrderedLiveTxValue -Value $Value[$key] }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-OrderedLiveTxValue -Value $property.Value }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]) -and -not ($Value -is [byte[]])) {
        $items = [System.Collections.Generic.List[object]]::new()
        foreach ($item in $Value) { $items.Add((ConvertTo-OrderedLiveTxValue -Value $item)) }
        return , $items.ToArray()
    }
    return $Value
}

$failpointsName = 'AI_AGENT_DOTFILES_LIVE_TX_FAILPOINTS'
if (-not [string]::IsNullOrWhiteSpace($FailpointsJson)) {
    [System.Environment]::SetEnvironmentVariable($failpointsName, $FailpointsJson)
}
else {
    [System.Environment]::SetEnvironmentVariable($failpointsName, $null)
}

switch ($Mode) {
    'produce' {
        $request = ConvertTo-OrderedLiveTxValue -Value (ConvertFrom-Json -InputObject $ProducerArgsJson)
        $splat = @{
            TransactionDirectory = [string] $request['TransactionDirectory']
            Header = [System.Collections.IDictionary] $request['Header']
            Receipt = [System.Collections.IDictionary] $request['Receipt']
            Targets = @([object[]] (ConvertTo-OrderedLiveTxValue -Value $request['Targets']))
            SourceRootsByPlatform = [System.Collections.IDictionary] $request['SourceRootsByPlatform']
            AuthorityStateIntent = [System.Collections.IDictionary] $request['AuthorityStateIntent']
            TargetContextIntent = [System.Collections.IDictionary] $request['TargetContextIntent']
            FinalCapabilityHashesByPlatform = [System.Collections.IDictionary] $request['FinalCapabilityHashesByPlatform']
            ControlBase = [string] $request['ControlBase']
            StateRecoveryDirectory = [string] $request['StateRecoveryDirectory']
        }
        $result = Invoke-SealedLiveTransactionMutation @splat
        ConvertTo-Json -InputObject $result -Depth 20
    }
    'state-only' {
        $request = ConvertTo-OrderedLiveTxValue -Value (ConvertFrom-Json -InputObject $ProducerArgsJson)
        $splat = @{
            TransactionDirectory = [string] $request['TransactionDirectory']
            Header = [System.Collections.IDictionary] $request['Header']
            AuthorityStateIntent = [System.Collections.IDictionary] $request['AuthorityStateIntent']
            TargetContextIntent = [System.Collections.IDictionary] $request['TargetContextIntent']
            FinalCapabilityHashesByPlatform = [System.Collections.IDictionary] $request['FinalCapabilityHashesByPlatform']
            ControlBase = [string] $request['ControlBase']
            StateRecoveryDirectory = [string] $request['StateRecoveryDirectory']
        }
        $result = Invoke-SealedLiveTransactionStateOnly @splat
        ConvertTo-Json -InputObject $result -Depth 20
    }
    'reserve' {
        # Mirrors the production host's reservation step: the journal namespace
        # and its header are published (the RESERVED checkpoint fires here) and
        # nothing else happens.
        $request = ConvertTo-OrderedLiveTxValue -Value (ConvertFrom-Json -InputObject $ProducerArgsJson)
        $publication = New-SealedLiveJournalHeader -Document ([System.Collections.IDictionary] $request['Header']) -TransactionDirectory ([string] $request['TransactionDirectory'])
        ConvertTo-Json -InputObject ([ordered]@{ Path = [string] $publication.Path; Hash = [string] $publication.Hash }) -Depth 6
    }
}
