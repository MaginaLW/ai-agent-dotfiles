#requires -Version 7.0

<#
.SYNOPSIS
    Test host for the managed backup receipt producer, restart classifier, and
    consumer verifier. Runs inside the internal sandbox (through
    live-transaction-host.ps1) when the caller needs the capability-gated
    failpoints; classification and verification run anywhere.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('produce', 'classify', 'verify')] [string] $Mode,
    [string] $ProducerArgsJson,
    [string] $FailpointsJson,
    [string] $ReceiptPath,
    [string] $IntentJson,
    [string] $BackupRoot,
    [string] $RepoRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path }
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
. (Join-Path $RepoRoot 'scripts/backup-receipt-common.ps1')

function ConvertTo-OrderedReceiptValue {
    param([AllowNull()] [object] $Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Collections.IDictionary]) {
        $result = [ordered]@{}
        foreach ($key in @($Value.Keys)) { $result[[string] $key] = ConvertTo-OrderedReceiptValue -Value $Value[$key] }
        return $result
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $result = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) { $result[$property.Name] = ConvertTo-OrderedReceiptValue -Value $property.Value }
        return $result
    }
    if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string]) -and -not ($Value -is [byte[]])) {
        return @([object[]] ($Value | ForEach-Object { ConvertTo-OrderedReceiptValue -Value $_ }))
    }
    return $Value
}

if (-not [string]::IsNullOrWhiteSpace($FailpointsJson)) {
    $env:AI_AGENT_DOTFILES_BACKUP_RECEIPT_FAILPOINTS = $FailpointsJson
}
else {
    Remove-Item Env:AI_AGENT_DOTFILES_BACKUP_RECEIPT_FAILPOINTS -ErrorAction SilentlyContinue
}

switch ($Mode) {
    'produce' {
        $request = ConvertTo-OrderedReceiptValue -Value (ConvertFrom-Json -InputObject $ProducerArgsJson)
        $splat = @{
            ReservationIntent = [System.Collections.IDictionary] $request['ReservationIntent']
            SourceOperationKind = [string] $request['SourceOperationKind']
            PlanHash = [string] $request['PlanHash']
            DocumentHash = [string] $request['DocumentHash']
            ExecutionContextHash = [string] $request['ExecutionContextHash']
            ControlBaseHash = [string] $request['ControlBaseHash']
            FilesystemCapabilityHash = [string] $request['FilesystemCapabilityHash']
            HomeAuthorityKey = [string] $request['HomeAuthorityKey']
            BackupRoot = [string] $request['BackupRoot']
            Platforms = @([object[]] (ConvertTo-OrderedReceiptValue -Value $request['Platforms']))
            ForbiddenRoots = @([string[]] $request['ForbiddenRoots'])
        }
        if (-not [string]::IsNullOrWhiteSpace([string] $request['AuthorityStatePath'])) { $splat.AuthorityStatePath = [string] $request['AuthorityStatePath'] }
        if (-not [string]::IsNullOrWhiteSpace([string] $request['RootClaimsPath'])) { $splat.RootClaimsPath = [string] $request['RootClaimsPath'] }
        $result = Invoke-SealedManagedBackupReceipt @splat
        ConvertTo-Json -InputObject $result -Depth 20
    }
    'classify' {
        Get-SealedBackupReceiptSlotState -ReceiptPath $ReceiptPath
    }
    'verify' {
        $intent = ConvertTo-OrderedReceiptValue -Value (ConvertFrom-Json -InputObject $IntentJson)
        $null = Assert-SealedBackupReceiptValid -ReceiptPath $ReceiptPath -ReservationIntent ([System.Collections.IDictionary] $intent) -BackupRoot $BackupRoot
        Write-Output 'verify-ok'
    }
}
