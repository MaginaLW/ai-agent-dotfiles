#requires -Version 7.0

Set-StrictMode -Version Latest

# Public live command-result emitter: the status verb ends its stdout with one
# strict live-operation-result command document, self-validated against the
# registered contract (schema + bound semantic validator) before anything is
# printed. This mirrors scripts/canonical-command-result.ps1 for the live
# artifact kind; the document scope is command-only and never enters a
# transaction namespace or closes a reservation.

function Get-LiveCommandResultContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolchainRoot)

    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $registryPath = Join-Path $root 'schemas/artifact-contracts.psd1'
    $registry = Import-PowerShellDataFile -LiteralPath $registryPath
    if ([long] $registry.SchemaVersion -ne 1 -or -not $registry.Contracts.ContainsKey('live-operation-result')) {
        throw 'Live command-result contract is not registered.'
    }

    $contract = $registry.Contracts['live-operation-result']
    if ([long] $contract.SchemaVersion -ne 1) { throw 'Live command-result registry version is unsupported.' }
    $bootstrapSchemaPath = [IO.Path]::GetFullPath((Join-Path $root 'schemas/live-operation-result.schema.json'))
    $registrySchemaPath = [IO.Path]::GetFullPath((Join-Path $root ([string] $contract.SchemaPath)))
    if (-not $registrySchemaPath.Equals($bootstrapSchemaPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Live command-result registry schema differs from the fixed bootstrap schema.'
    }
    if ([string] $contract.SemanticValidator -cne 'Test-LiveOperationResultSemantics') {
        throw 'Live command-result registry must bind the in-memory semantic validator.'
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = [long] $contract.SchemaVersion
        BootstrapSchemaPath = $bootstrapSchemaPath
        RegistrySchemaPath = $registrySchemaPath
    }
}

function New-LivePublicCommandResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [string] $MessageToken
    )

    return [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'live-operation-result'
        ResultScope = 'command'
        Result = $Result
        CommandKind = 'live-recover-status'
        LifecycleKind = 'no-transaction'
        MessageToken = $MessageToken
    }
}

function Write-LivePublicCommandResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $ToolchainRoot,
        [Parameter(Mandatory)] [string] $ValidationPath
    )

    $contract = Get-LiveCommandResultContract -ToolchainRoot $ToolchainRoot
    if (-not $Document.Contains('SchemaVersion') -or [long] $Document.SchemaVersion -ne [long] $contract.SchemaVersion) {
        throw 'Live command-result document version differs from the registered contract.'
    }
    Test-LiveOperationResultSemantics -Document $Document
    $bytes = ConvertTo-SemanticJsonBytes -InputObject $Document
    $null = Invoke-CanonicalContractSchemaValidation -Path $ValidationPath -SchemaPath $contract.BootstrapSchemaPath -ContentBytes $bytes
    $null = Invoke-CanonicalContractSchemaValidation -Path $ValidationPath -SchemaPath $contract.RegistrySchemaPath -ContentBytes $bytes
    [Console]::Out.WriteLine([Text.UTF8Encoding]::new($false).GetString($bytes))
}
