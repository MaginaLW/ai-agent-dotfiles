#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'skills-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-transaction-common.ps1')

function New-CanonicalAdapterWorkspace {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $repo = Resolve-RepoRoot -RepoRoot $RepoRoot
    $relative = 'tmp/canonical-candidates/' + [Guid]::NewGuid().ToString('D').ToLowerInvariant()
    & git -C $repo check-ignore --quiet -- $relative
    if ($LASTEXITCODE -ne 0) { throw 'Canonical CandidateWorkspace must be covered by the repository tmp ignore rule.' }

    $workspace = Join-Path $repo $relative
    Assert-PathUnderRoot -Root $repo -Path $workspace
    Assert-NoReparseExistingChain -Path $workspace
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    $marker = Get-NoFollowRootEntryMarker -Path $workspace
    if ([string]$marker.EntryType -cne 'Directory') { throw 'Canonical CandidateWorkspace is not a direct regular directory.' }
    return [IO.Path]::GetFullPath($workspace)
}

function New-CanonicalBatchCandidateWorkspace {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $CandidateWorkspace,
        [AllowEmptyCollection()] [object[]] $Proposals = @()
    )

    $repo = Resolve-RepoRoot -RepoRoot $RepoRoot
    $workspace = (Resolve-Path -LiteralPath $CandidateWorkspace).Path
    Assert-PathUnderRoot -Root (Join-Path $repo 'tmp/canonical-candidates') -Path $workspace
    Assert-NoReparseExistingChain -Path $workspace
    if (@([IO.Directory]::EnumerateFileSystemEntries($workspace)).Count -ne 0) { throw 'Canonical CandidateWorkspace must be empty and create-new.' }

    $proposalRoot = Join-Path $workspace '.proposals'
    $results = [Collections.Generic.List[object]]::new()
    $targetKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    if ($Proposals.Count -gt 0) { [IO.Directory]::CreateDirectory($proposalRoot) | Out-Null }

    for ($index = 0; $index -lt $Proposals.Count; $index++) {
        $proposal = $Proposals[$index]
        $input = [string] $proposal.InputSkillPath
        $targetType = [string] $proposal.TargetType
        if ($targetType -notin @('shared','claude-only','codex-only','reasonix-only')) { throw "Unsupported canonical target type: $targetType" }
        $proposalWorkspace = Join-Path $proposalRoot $index.ToString('D4')
        [IO.Directory]::CreateDirectory($proposalWorkspace) | Out-Null
        $result = New-NormalizedSkillCandidate -RepoRoot $repo -InputSkillPath $input -CandidateWorkspace $proposalWorkspace -TargetType $targetType
        if ([string] $result.Status -cne 'candidate') {
            return [pscustomobject][ordered]@{
                Status = [string] $result.Status
                Reason = [string] $result.Reason
                FailedIndex = $index
                CandidateWorkspace = $workspace
                Results = @($results)
                RewriteList = @()
            }
        }
        $targetKey = "$targetType/$([string]$result.Name)"
        if (-not $targetKeys.Add($targetKey)) { throw "Duplicate canonical proposal target: $targetKey" }
        $results.Add($result)
    }

    $excludePrefixes = @($results | ForEach-Object { "$([string]$_.TargetType)/$([string]$_.Name)" })
    $sourceRoot = Join-Path $workspace 'skills-source'
    $null = Copy-SafeTree -SourceRoot (Join-Path $repo 'skills-source') -DestinationRoot $sourceRoot -ExcludePrefixes $excludePrefixes
    foreach ($result in $results) {
        $destination = Join-Path $sourceRoot (Join-Path ([string]$result.TargetType) ([string]$result.Name))
        $null = Copy-SafeTree -SourceRoot ([string]$result.CandidatePath) -DestinationRoot $destination
    }

    if (Test-Path -LiteralPath $proposalRoot -PathType Container) {
        $proposalSnapshot = Get-SafeTreeSnapshot -Root $proposalRoot
        if ($proposalSnapshot.TraversalIdentityEvidence.Count -lt 1) { throw 'Canonical proposal workspace identity evidence is missing.' }
        [IO.Directory]::Delete($proposalRoot, $true)
    }
    $null = Get-SafeTreeSnapshot -Root $sourceRoot

    $rewrites = @($results | ForEach-Object {
        foreach ($rewrite in @($_.Rewrites)) {
            '{0}|{1}|{2}' -f ([string]$rewrite.File),([string]$rewrite.Rule),([string]$rewrite.Replacement)
        }
    } | Sort-Object -Unique)
    return [pscustomobject][ordered]@{
        Status = 'candidate'
        Reason = ''
        CandidateWorkspace = $workspace
        CandidateSourceRoot = $sourceRoot
        Results = @($results)
        RewriteList = $rewrites
    }
}

function Assert-CanonicalSingleReplacementPlanBinding {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $PlanPath,
        [Parameter(Mandatory)] [ValidateSet('normalize','promote')] [string] $OperationKind,
        [Parameter(Mandatory)] [string] $InputSkillPath,
        [Parameter(Mandatory)] [ValidateSet('shared','claude-only','codex-only','reasonix-only')] [string] $TargetType
    )

    $repo = Resolve-RepoRoot -RepoRoot $RepoRoot
    $input = (Resolve-Path -LiteralPath $InputSkillPath).Path
    $document = Read-CanonicalTransactionPlan -PlanPath $PlanPath -RepoRoot $repo -ExpectedOperationKind $OperationKind
    if (-not ([IO.Path]::GetFullPath([string]$document.PlanPayload.Input.Path)).Equals([IO.Path]::GetFullPath($input), [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Canonical adapter input differs from the reviewed plan.'
    }
    $name = Get-SkillName -SkillPath $input
    $candidate = Join-Path ([string]$document.PlanPayload.CandidateSourceRoot) (Join-Path $TargetType $name)
    if (-not (Test-Path -LiteralPath (Join-Path $candidate 'SKILL.md') -PathType Leaf)) {
        throw 'Canonical adapter target type/name differs from the reviewed plan.'
    }
    return $document
}

function Invoke-CanonicalTransactionChild {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [ValidateSet('normalize','promote','merge')] [string] $OperationKind,
        [Parameter(Mandatory)] [ValidateSet('DryRun','Apply')] [string] $Mode,
        [Parameter(Mandatory)] [string] $PlanPath,
        [string] $CandidateWorkspace,
        [string] $InputPath,
        [string[]] $RewriteList = @(),
        [string] $CanonicalPreflightOutputRoot
    )

    $scriptPath = Join-Path $PSScriptRoot 'canonical-transaction.ps1'
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-NoProfile','-File',$scriptPath,'-RepoRoot',$RepoRoot,'-OperationKind',$OperationKind,"-$Mode",'-PlanPath',$PlanPath)) { $arguments.Add([string]$value) }
    if ($Mode -ceq 'DryRun') {
        foreach ($pair in @(
            @('-CandidateWorkspace',$CandidateWorkspace),
            @('-InputPath',$InputPath),
            @('-CanonicalPreflightOutputRoot',$CanonicalPreflightOutputRoot)
        )) {
            if ([string]::IsNullOrWhiteSpace([string]$pair[1])) { throw "Canonical DryRun is missing $($pair[0])." }
            $arguments.Add([string]$pair[0]); $arguments.Add([string]$pair[1])
        }
        foreach ($rewrite in @($RewriteList)) { $arguments.Add('-RewriteList'); $arguments.Add([string]$rewrite) }
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = (Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in $arguments) { $start.ArgumentList.Add($argument) }
    $process = [Diagnostics.Process]::new(); $process.StartInfo = $start
    try {
        if (-not $process.Start()) { throw 'Unable to start the canonical transaction child.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync(); $stderrTask = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        $stdout = $stdoutTask.GetAwaiter().GetResult().Trim()
        $stderr = $stderrTask.GetAwaiter().GetResult().Trim()
        if ([string]::IsNullOrWhiteSpace($stdout)) { throw "Canonical transaction child emitted no machine result (exit $($process.ExitCode)): $stderr" }
        try { $result = $stdout | ConvertFrom-Json -Depth 30 }
        catch { throw "Canonical transaction child emitted invalid JSON (exit $($process.ExitCode)): $stdout $stderr" }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($stdout)
        $null = Invoke-CanonicalContractSchemaValidation -Path $PlanPath -SchemaPath (Join-Path $script:CanonicalToolchainRoot 'schemas/canonical-transaction-result.schema.json') -ContentBytes $bytes
        $expectedCommand = "canonical-$OperationKind"
        if ([string]$result.ResultScope -cne 'command' -or [string]$result.CommandKind -cne $expectedCommand) {
            throw "Canonical transaction child result discriminator mismatch: expected $expectedCommand."
        }
        return [pscustomobject][ordered]@{ ExitCode=$process.ExitCode; Stdout=$stdout; Stderr=$stderr; Result=$result }
    }
    finally { $process.Dispose() }
}

function Write-CanonicalTransactionChildOutput {
    param([Parameter(Mandatory)] $Child)
    [Console]::Out.WriteLine([string]$Child.Stdout)
    if (-not [string]::IsNullOrWhiteSpace([string]$Child.Stderr)) { [Console]::Error.WriteLine([string]$Child.Stderr) }
}
