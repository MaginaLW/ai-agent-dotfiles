#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/json-artifact-common.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Assert-Throws {
    param([Parameter(Mandatory)] [scriptblock] $Action, [Parameter(Mandatory)] [string] $Pattern, [Parameter(Mandatory)] [string] $Message)
    $threw = $false
    try { & $Action }
    catch {
        $threw = $true
        if ($_.Exception.Message -notmatch $Pattern) { throw "FAIL: $Message (unexpected: $($_.Exception.Message))" }
    }
    if (-not $threw) { throw "FAIL: $Message (did not throw)" }
    Write-Host "  PASS  $Message"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-private-path-$([Guid]::NewGuid().ToString('N'))"
$external = Join-Path $work 'external'
New-Item -ItemType Directory -Path $external -Force | Out-Null
try {
    Write-Host '[external user artifacts]'
    $candidate = Join-Path $external 'plan.json'
    $resolved = Resolve-PrivateArtifactPath -Path $candidate -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf
    Assert ($resolved.FullPath -eq [System.IO.Path]::GetFullPath($candidate)) 'explicit external artifact path is accepted'
    Assert-Throws { Resolve-PrivateArtifactPath -Path (Join-Path $RepoRoot 'plan.json') -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf } 'worktree|disjoint' 'worktree descendant is rejected'
    $gitDir = (& git -C $RepoRoot rev-parse --absolute-git-dir).Trim()
    Assert-Throws { Resolve-PrivateArtifactPath -Path (Join-Path $gitDir 'index') -Role ExternalUserArtifact -RepoRoot $RepoRoot } 'Git|internal|disjoint' 'arbitrary Git internal path is rejected'

    Write-Host '[contracted internal paths]'
    $commonDir = (& git -C $RepoRoot rev-parse --path-format=absolute --git-common-dir).Trim()
    $contractRoot = Join-Path $commonDir 'ai-agent-dotfiles'
    $internal = Join-Path $contractRoot 'artifact.json'
    $internalResolved = Resolve-PrivateArtifactPath -Path $internal -Role InternalContractPath -RepoRoot $RepoRoot -InternalRoot $contractRoot -AllowMissingLeaf
    Assert ($internalResolved.FullPath -eq [System.IO.Path]::GetFullPath($internal)) 'exact GitCommonDir contract path is accepted for internal role'
    Assert-Throws { Resolve-PrivateArtifactPath -Path $internal -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf } 'Git|internal|disjoint' 'public external role cannot select an internal contract path'

    Write-Host '[evidence inputs]'
    $evidence = Join-Path $external 'receipt.json'
    [System.IO.File]::WriteAllText($evidence, '{}', [System.Text.UTF8Encoding]::new($false))
    $evidenceResult = Resolve-PrivateArtifactPath -Path $evidence -Role EvidenceInputPath -RepoRoot $RepoRoot -EvidenceRoots @($external)
    Assert ($evidenceResult.LinkCount -eq 1 -and $evidenceResult.NamedStreamCount -eq 0) 'regular single-link evidence is accepted before content open'
    Assert-Throws { Resolve-PrivateArtifactPath -Path (Join-Path $RepoRoot 'STATUS.md') -Role EvidenceInputPath -RepoRoot $RepoRoot -EvidenceRoots @($external) } 'allowlist|evidence' 'evidence outside its operation allowlist is rejected'

    $hardlink = Join-Path $external 'receipt-hardlink.json'
    New-Item -ItemType HardLink -Path $hardlink -Target $evidence | Out-Null
    Assert-Throws { Resolve-PrivateArtifactPath -Path $hardlink -Role EvidenceInputPath -RepoRoot $RepoRoot -EvidenceRoots @($external) } 'hard link' 'hardlinked evidence is rejected before content open'
    Remove-Item -LiteralPath $hardlink -Force

    Set-Content -LiteralPath $evidence -Stream 'phase0-boundary' -Value 'sentinel' -NoNewline
    Assert-Throws { Resolve-PrivateArtifactPath -Path $evidence -Role EvidenceInputPath -RepoRoot $RepoRoot -EvidenceRoots @($external) } 'alternate data stream' 'evidence with a named stream is rejected before content open'
    Remove-Item -LiteralPath $evidence -Stream 'phase0-boundary'

    $outside = Join-Path $work 'outside'
    New-Item -ItemType Directory -Path $outside | Out-Null
    $junction = Join-Path $external 'junction'
    New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
    Assert-Throws { Resolve-PrivateArtifactPath -Path (Join-Path $junction 'new.json') -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf } 'reparse' 'external output through a junction is rejected before creation'
    Remove-Item -LiteralPath $junction -Force

    Write-Host 'private path boundary tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
