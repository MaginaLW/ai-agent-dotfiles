#requires -Version 7.0
# Shared helpers for promote-skill.ps1, normalize-skill.ps1 and auto-merge-skills.ps1.
#
# Flow: build a normalized candidate under tmp/skill-candidates/<guid>, print what
# would be written (-DryRun), and on -Apply copy it into skills-source/<type>/<name>
# and run build-skills.ps1 and scan-secrets.ps1. There is no plan file: Git is the
# recovery path for skills-source/.

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'skills-common.ps1')

# Refuses a reparse point on Path or on any existing directory between Path and Root.
function Assert-SkillCandidateNoReparseChain {
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [string] $Path
    )

    Assert-PathUnderRoot -Root $Root -Path $Path
    $rootFull = [IO.Path]::GetFullPath($Root).TrimEnd([char]92, [char]47)
    $current = [IO.Path]::GetFullPath($Path).TrimEnd([char]92, [char]47)
    while (-not [string]::IsNullOrEmpty($current)) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to use a path through a reparse point: $current"
            }
        }
        if ($current.Equals($rootFull, [StringComparison]::OrdinalIgnoreCase)) { break }
        $current = [IO.Path]::GetDirectoryName($current)
    }
}

function New-SkillCandidateWorkspace {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $relative = 'tmp/skill-candidates/' + [Guid]::NewGuid().ToString('N')
    & git -C $RepoRoot check-ignore --quiet -- $relative
    if ($LASTEXITCODE -ne 0) { throw 'tmp/skill-candidates must be covered by the repository tmp/ ignore rule.' }
    $workspace = [IO.Path]::GetFullPath((Join-Path $RepoRoot $relative))
    Assert-SkillCandidateNoReparseChain -Root $RepoRoot -Path $workspace
    if (Test-Path -LiteralPath $workspace) { throw "Candidate workspace must be create-new: $workspace" }
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    return $workspace
}

# Builds one normalized candidate per proposal (InputSkillPath, TargetType). Stops at
# the first rejection and returns its reason; nothing under skills-source/ is touched.
function New-SkillCandidateSet {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Workspace,
        [AllowEmptyCollection()] [object[]] $Proposals = @()
    )

    $results = [Collections.Generic.List[object]]::new()
    $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    for ($index = 0; $index -lt $Proposals.Count; $index++) {
        $proposal = $Proposals[$index]
        $proposalWorkspace = Join-Path $Workspace ('proposal-' + $index.ToString('D4'))
        [IO.Directory]::CreateDirectory($proposalWorkspace) | Out-Null
        $result = New-NormalizedSkillCandidate -RepoRoot $RepoRoot -InputSkillPath ([string]$proposal.InputSkillPath) `
            -CandidateWorkspace $proposalWorkspace -TargetType ([string]$proposal.TargetType)
        if ([string]$result.Status -cne 'candidate') {
            return [pscustomobject][ordered]@{
                Status = [string]$result.Status
                Reason = [string]$result.Reason
                FailedIndex = $index
                Results = @($results)
            }
        }
        $key = "$([string]$result.TargetType)/$([string]$result.Name)"
        if (-not $targets.Add($key)) { throw "Duplicate candidate target: skills-source/$key" }
        Assert-SkillTreeNoReparsePoint -Root ([string]$result.CandidatePath)
        $results.Add($result)
    }
    return [pscustomobject][ordered]@{
        Status = 'candidate'
        Reason = ''
        FailedIndex = -1
        Results = @($results)
    }
}

# Prints, per candidate, the target, whether it is created or replaced, its files and
# the path rewrites applied by normalization.
function Write-SkillCandidatePlan {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [AllowEmptyCollection()] [object[]] $Results = @()
    )

    foreach ($result in $Results) {
        $targetRelative = "skills-source/$([string]$result.TargetType)/$([string]$result.Name)"
        $action = if (Test-Path -LiteralPath (Join-Path $RepoRoot $targetRelative)) { 'replace' } else { 'create' }
        Write-Host "$action $targetRelative"
        Write-Host "  candidate: $(Get-RelativeDisplayPath -Root $RepoRoot -Path ([string]$result.CandidatePath))"
        foreach ($file in @(Get-ChildItem -LiteralPath ([string]$result.CandidatePath) -File -Recurse -Force | Sort-Object FullName)) {
            Write-Host "  file: $(Get-RelativeDisplayPath -Root ([string]$result.CandidatePath) -Path $file.FullName)"
        }
        foreach ($rewrite in @($result.Rewrites)) {
            $file = ([string]$rewrite.File) -replace '^canonical/[^/]+/[^/]+/', ''
            Write-Host "  rewrite: $file ($([string]$rewrite.Rule) -> $([string]$rewrite.Replacement))"
        }
    }
}

# Copies one candidate into skills-source/<type>/<name>. The target must be new unless
# -AllowReplace is given; then the existing directory is first moved to BackupRoot.
function Install-SkillCandidate {
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [object] $Result,
        [switch] $AllowReplace,
        [string] $BackupRoot
    )

    $relative = "skills-source/$([string]$Result.TargetType)/$([string]$Result.Name)"
    $target = [IO.Path]::GetFullPath((Join-Path $RepoRoot $relative))
    Assert-SkillCandidateNoReparseChain -Root $RepoRoot -Path $target
    if (Test-Path -LiteralPath $target) {
        if (-not $AllowReplace) { throw "Refusing to overwrite existing skill: $relative" }
        if ([string]::IsNullOrWhiteSpace($BackupRoot)) { throw 'Replacing a skill requires a backup root.' }
        Assert-SkillTreeNoReparsePoint -Root $target
        $backup = [IO.Path]::GetFullPath((Join-Path $BackupRoot (Join-Path ([string]$Result.TargetType) ([string]$Result.Name))))
        Assert-SkillCandidateNoReparseChain -Root $RepoRoot -Path $backup
        if (Test-Path -LiteralPath $backup) { throw "Backup path must be create-new: $backup" }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $backup)) | Out-Null
        Move-Item -LiteralPath $target -Destination $backup
        Write-Host "backup: $relative -> $(Get-RelativeDisplayPath -Root $RepoRoot -Path $backup)"
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    Copy-SkillTree -SourceRoot ([string]$Result.CandidatePath) -DestinationRoot $target
    Write-Host "wrote: $relative"
    return $relative
}

# Runs build-skills.ps1 and scan-secrets.ps1 against RepoRoot and reports PASS/FAIL for each.
function Invoke-SkillCandidateChecks {
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction Stop)[0].Source
    $outcome = [ordered]@{}
    foreach ($entry in @(@('Build', 'build-skills.ps1'), @('Scan', 'scan-secrets.ps1'))) {
        & $pwsh -NoProfile -File (Join-Path $PSScriptRoot $entry[1]) -RepoRoot $RepoRoot | Out-Host
        $outcome[$entry[0]] = if ($LASTEXITCODE -eq 0) { 'PASS' } else { 'FAIL' }
        Write-Host "$($entry[1]): $($outcome[$entry[0]])"
    }
    return [pscustomobject]$outcome
}
