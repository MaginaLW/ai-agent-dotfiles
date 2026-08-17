#requires -Version 7.0

Set-StrictMode -Version Latest

function Get-CanonicalCommandResultContract {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ToolchainRoot)

    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $registryPath = Join-Path $root 'schemas/artifact-contracts.psd1'
    $registry = Import-PowerShellDataFile -LiteralPath $registryPath
    if ([long] $registry.SchemaVersion -ne 1 -or -not $registry.Contracts.ContainsKey('canonical-transaction-result')) {
        throw 'Canonical command-result contract is not registered.'
    }

    $contract = $registry.Contracts['canonical-transaction-result']
    if ([long] $contract.SchemaVersion -ne 1) { throw 'Canonical command-result registry version is unsupported.' }
    $bootstrapSchemaPath = [IO.Path]::GetFullPath((Join-Path $root 'schemas/canonical-transaction-result.schema.json'))
    $registrySchemaPath = [IO.Path]::GetFullPath((Join-Path $root ([string] $contract.SchemaPath)))
    if (-not $registrySchemaPath.Equals($bootstrapSchemaPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Canonical command-result registry schema differs from the fixed bootstrap schema.'
    }
    if ($contract.ContainsKey('SemanticValidator') -and -not [string]::IsNullOrWhiteSpace([string] $contract.SemanticValidator)) {
        throw 'Canonical command-result registry semantic validation is not supported by the public in-memory emitter.'
    }

    return [pscustomobject][ordered]@{
        SchemaVersion = [long] $contract.SchemaVersion
        BootstrapSchemaPath = $bootstrapSchemaPath
        RegistrySchemaPath = $registrySchemaPath
    }
}

function New-CanonicalPublicCommandResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [ValidateSet('PASS', 'WARN', 'FAIL')] [string] $Result,
        [Parameter(Mandatory)] [ValidateSet(
            'canonical-status',
            'canonical-setup',
            'canonical-normalize',
            'canonical-promote',
            'canonical-merge',
            'canonical-recover-status',
            'canonical-recover-abandon',
            'canonical-recover-rollback',
            'canonical-recover-finalize'
        )] [string] $CommandKind,
        [Parameter(Mandatory)] [string] $MessageToken,
        [string] $PlanHash
    )

    $document = [ordered]@{
        SchemaVersion = 1
        ArtifactKind = 'canonical-transaction-result'
        ResultScope = 'command'
        Result = $Result
        CommandKind = $CommandKind
        LifecycleKind = 'no-transaction'
        MessageToken = $MessageToken
    }
    if (-not [string]::IsNullOrWhiteSpace($PlanHash)) { $document.PlanHash = $PlanHash }
    return $document
}

function Get-CanonicalPublicCommandFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Exception] $Exception,
        [string] $FallbackMessageToken
    )

    $fallbackMessageId = if ($PSBoundParameters.ContainsKey('FallbackMessageToken')) { [string] $FallbackMessageToken } else { 'canonical-command-failed' }
    $message = [string] $Exception.Message
    $messageId = $fallbackMessageId
    if ($message -cmatch 'canonical-recovery-plan-stale') {
        $messageId = 'canonical-recovery-plan-stale'
    }
    elseif ($message -cmatch 'canonical-plan-stale') {
        $messageId = 'canonical-plan-stale'
    }
    elseif ($message -cmatch 'reviewed-plan-consumed') {
        $messageId = 'reviewed-plan-consumed'
    }
    elseif ($message -cmatch 'operation-lock-busy') {
        $messageId = 'operation-lock-busy'
    }
    elseif ($message -cmatch 'manual-recovery-required') {
        $messageId = 'manual-recovery-required'
    }
    elseif ($message -cmatch 'canonical-recovery-required') {
        $messageId = 'canonical-recovery-required'
    }
    elseif ($message -cmatch 'canonical-setup-required|canonical-lock-missing') {
        $messageId = 'canonical-setup-required'
    }
    elseif ($message -cmatch 'canonical-transaction-not-found') {
        $messageId = 'canonical-transaction-not-found'
    }
    elseif ($message -match '(?i)\bspecify exactly one of -dryrun or -apply\b') {
        $messageId = 'canonical-mode-invalid'
    }
    elseif ($message -match '(?i)\brequires -planpath; interactive parameter prompting is disabled\b') {
        $messageId = 'canonical-plan-required'
    }
    elseif ($message -match '(?i)\bapply requires an existing reviewed planpath\b') {
        $messageId = 'canonical-plan-not-found'
    }
    elseif ($message -match '(?i)\bplanpath parent must already exist\b') {
        $messageId = 'canonical-plan-parent-missing'
    }
    elseif ($message -match '(?i)\b(?:canonical(?: recovery)?|dryrun) planpath must be create-new\b') {
        $messageId = 'canonical-plan-exists'
    }
    elseif ($message -match '(?i)\breport root must be create-new\b') {
        $messageId = 'canonical-artifact-exists'
    }
    elseif ($message -match '(?i)\bcanonical preflight\b|\bpreflight artifact\b|\bpreflight result\b') {
        $messageId = 'canonical-preflight-failed'
    }

    $result = if ($messageId -in @('operation-lock-busy', 'canonical-setup-required', 'canonical-recovery-required')) { 'WARN' } else { 'FAIL' }
    return [pscustomobject][ordered]@{
        Result = $result
        MessageToken = $messageId
        ExitCode = 1
    }
}

function Write-CanonicalPublicCommandFailure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Exception] $Exception,
        [Parameter(Mandatory)] [string] $CommandKind,
        [Parameter(Mandatory)] [string] $ToolchainRoot,
        [Parameter(Mandatory)] [string] $ValidationPath,
        [string] $FallbackMessageToken,
        [string] $PlanHash
    )

    $fallbackMessageId = if ($PSBoundParameters.ContainsKey('FallbackMessageToken')) { [string] $FallbackMessageToken } else { 'canonical-command-failed' }
    $failure = Get-CanonicalPublicCommandFailure -Exception $Exception -FallbackMessageToken $fallbackMessageId
    $document = New-CanonicalPublicCommandResult -Result ([string] $failure.Result) -CommandKind $CommandKind -MessageToken ([string] $failure.MessageToken) -PlanHash $PlanHash
    Write-CanonicalPublicCommandResult -Document $document -ToolchainRoot $ToolchainRoot -ValidationPath $ValidationPath
    [Console]::Error.WriteLine([string] $failure.MessageToken)
    return $failure
}

function Write-CanonicalPublicCommandResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $ToolchainRoot,
        [Parameter(Mandatory)] [string] $ValidationPath
    )

    $contract = Get-CanonicalCommandResultContract -ToolchainRoot $ToolchainRoot
    if (-not $Document.Contains('SchemaVersion') -or [long] $Document.SchemaVersion -ne [long] $contract.SchemaVersion) {
        throw 'Canonical command-result document version differs from the registered contract.'
    }
    $bytes = ConvertTo-SemanticJsonBytes -InputObject $Document
    $null = Invoke-CanonicalContractSchemaValidation -Path $ValidationPath -SchemaPath $contract.BootstrapSchemaPath -ContentBytes $bytes
    $null = Invoke-CanonicalContractSchemaValidation -Path $ValidationPath -SchemaPath $contract.RegistrySchemaPath -ContentBytes $bytes
    [Console]::Out.WriteLine([Text.UTF8Encoding]::new($false).GetString($bytes))
}
