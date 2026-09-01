#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'canonical-preflight-common.ps1')
. (Join-Path $PSScriptRoot 'target-context-common.ps1')
. (Join-Path $PSScriptRoot 'transaction-journal-common.ps1')
. (Join-Path $PSScriptRoot 'canonical-mutation-common.ps1')

$script:CanonicalToolchainRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Get-CanonicalGitContext {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $requestedRepo=[System.IO.Path]::GetFullPath($RepoRoot)
    Assert-NoReparseExistingChain -Path $requestedRepo
    $repo = (Resolve-Path -LiteralPath $RepoRoot).Path
    Assert-NoReparseExistingChain -Path $repo
    $gitDir = ((& git -C $repo rev-parse --path-format=absolute --absolute-git-dir 2>$null) | Select-Object -First 1)
    $commonDir = ((& git -C $repo rev-parse --path-format=absolute --git-common-dir 2>$null) | Select-Object -First 1)
    $commit = ((& git -C $repo rev-parse HEAD 2>$null) | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($gitDir) -or [string]::IsNullOrWhiteSpace($commonDir) -or [string]::IsNullOrWhiteSpace($commit)) {
        throw 'Canonical transaction requires a Git repository with a selected commit.'
    }
    $gitDir = [System.IO.Path]::GetFullPath(([string]$gitDir).Trim())
    $commonDir = [System.IO.Path]::GetFullPath(([string]$commonDir).Trim())
    Assert-NoReparseExistingChain -Path $gitDir
    Assert-NoReparseExistingChain -Path $commonDir
    $commit = ([string]$commit).Trim().ToLowerInvariant()
    return [pscustomobject][ordered]@{
        RepoRoot = $repo
        GitDir = $gitDir
        GitCommonDir = $commonDir
        GitCommonDirHash = Get-LowerSemanticHash -Value $commonDir.ToLowerInvariant()
        WorktreeId = Get-LowerSemanticHash -Value $gitDir.ToLowerInvariant()
        RepositoryCommit = $commit
    }
}

function Get-LowerSemanticHash {
    param([Parameter(Mandatory)][object]$Value)
    return Get-SemanticJsonHash -InputObject $Value
}

function Read-CanonicalHeldRegularFileCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$MaximumBytes=[int]::MaxValue,
        [switch]$AllowMissing
    )

    if ($MaximumBytes -lt 0) { throw 'Canonical regular-file maximum byte length must be non-negative.' }
    $full=[System.IO.Path]::GetFullPath($Path)
    $parent=[System.IO.Path]::GetDirectoryName($full)
    $leaf=[System.IO.Path]::GetFileName($full)
    $handles=$null
    $fileHandle=$null
    try {
        $handlesReceiver2=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $parent -OwnershipReceiver $handlesReceiver2
        $handles=$handlesReceiver2.GetDeliveredExact()
        $parentHandle=$handles[$handles.Count-1]
        $initial=[AiAgentDotfiles.NoFollowFile]::TryInspectChild($parentHandle,$leaf)
        if ($null -eq $initial) {
            if ($AllowMissing) { return $null }
            throw "Canonical regular file is missing: $full"
        }
        if ($initial.IsDirectory -or $initial.IsReparsePoint) { throw "Canonical path is not a regular file: $full" }
        $fileHandle=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parentHandle,$leaf)
        if ([string]$fileHandle.ReadResult.Identity -cne [string]$initial.Identity -or [long]$fileHandle.ReadResult.Length -ne [long]$initial.Length) {
            throw "Canonical regular file changed while opening its held handle: $full"
        }
        $bytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($fileHandle,$MaximumBytes)
        return [pscustomobject][ordered]@{
            Path=$full
            Bytes=[byte[]]$bytes
            Identity=[string]$fileHandle.ReadResult.Identity
            Length=[long]$fileHandle.ReadResult.Length
            Sha256=[string]$fileHandle.ReadResult.Sha256
        }
    }
    finally {
        if ($null -ne $fileHandle) { $fileHandle.Dispose() }
        if ($null -ne $handles) { Close-SafeDirectoryContainmentChain -Handles $handles }
    }
}

function Get-CanonicalToolchainPolicyHash {
    param([string]$ToolchainRoot = $script:CanonicalToolchainRoot)
    $root = (Resolve-Path -LiteralPath $ToolchainRoot).Path
    $policyPath = Join-Path $root 'scripts/runner-policy.psd1'
    $policy = Import-PowerShellDataFile -LiteralPath $policyPath
    if ([long]$policy.SchemaVersion -ne 1) { throw 'Unsupported runner policy while binding canonical plan.' }
    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($relative in @($policy.ToolchainPaths | Sort-Object -Unique)) {
        $path = Join-Path $root ([string]$relative)
        $read=[AiAgentDotfiles.NoFollowFile]::HashRegularFile($path)
        $files.Add([ordered]@{ RelativePath=([string]$relative).Replace([char]92,[char]47); Length=[long]$read.Length; Sha256=[string]$read.Sha256 })
    }
    return Get-SemanticJsonHash -InputObject ([ordered]@{ SchemaVersion=1; DataPathspecs=@($policy.DataPathspecs | Sort-Object -Unique); ToolchainFiles=@($files) })
}

function Get-CanonicalPathState {
    param([Parameter(Mandatory)][string]$Path, [ValidateSet('auto','file','directory')][string]$Kind='auto')
    $full = [System.IO.Path]::GetFullPath($Path)
    $marker=Get-NoFollowRootEntryMarker -Path $full
    if ([string]$marker.EntryType -ceq 'MISSING') { return [ordered]@{ State='MISSING' } }
    if ([string]$marker.EntryType -ceq 'ReparsePoint') { throw "Canonical target is a reparse entry: $full" }
    if ($Kind -eq 'file' -and [string]$marker.EntryType -ceq 'Directory') { throw "Expected canonical file target but found directory: $full" }
    if ($Kind -eq 'directory' -and [string]$marker.EntryType -ceq 'File') { throw "Expected canonical directory target but found file: $full" }
    if ([string]$marker.EntryType -ceq 'Directory') {
        $directory=Get-CanonicalRetainedDirectoryObservation -Path $full
        return [ordered]@{ State='PRESENT'; Hash=[string]$directory.Hash }
    }
    $read=[AiAgentDotfiles.NoFollowFile]::HashRegularFile($full)
    return [ordered]@{ State='PRESENT'; Hash=[string]$read.Sha256 }
}

function Get-CanonicalInputEvidence {
    param([Parameter(Mandatory)][string]$Path)
    $full=[System.IO.Path]::GetFullPath($Path)
    $marker=Get-NoFollowRootEntryMarker -Path $full
    if ([string]$marker.EntryType -eq 'MISSING') { throw 'Canonical input is missing.' }
    if ([string]$marker.EntryType -eq 'ReparsePoint') { throw 'Canonical input must be a no-follow file or directory.' }
    if ([string]$marker.EntryType -eq 'Directory') {
        $directory=Get-CanonicalRetainedDirectoryObservation -Path $full
        return [ordered]@{ Path=$full; Kind='directory'; Hash=[string]$directory.Hash }
    }
    $read=[AiAgentDotfiles.NoFollowFile]::HashRegularFile($full)
    return [ordered]@{ Path=$full; Kind='file'; Hash=[string]$read.Sha256 }
}

function Read-CanonicalManifestNames {
    param([Parameter(Mandatory)][string]$Path)
    $capture=Read-CanonicalHeldRegularFileCapture -Path $Path -AllowMissing
    if ($null -eq $capture) { return @() }
    $text=[System.Text.UTF8Encoding]::new($false,$true).GetString($capture.Bytes)
    $reader=[System.IO.StringReader]::new($text)
    try {
        $names=[System.Collections.Generic.List[string]]::new()
        while (($line=$reader.ReadLine()) -ne $null) {
            $name=$line.Trim()
            if ($name) { $names.Add($name) }
        }
        return @($names | Sort-Object -Unique)
    }
    finally { $reader.Dispose() }
}

function Assert-CanonicalManifestsClean {
    param([Parameter(Mandatory)][string]$RepoRoot)
    foreach ($relative in @('manifests/managed-skills.claude.txt','manifests/managed-skills.codex.txt','manifests/managed-skills.reasonix.txt','manifests/managed-skills.txt')) {
        $tracked = @(& git -C $RepoRoot ls-files --error-unmatch -- $relative 2>$null)
        if ($LASTEXITCODE -ne 0 -or $tracked.Count -ne 1) { throw "Canonical manifest is not a tracked single file: $relative" }
        $status = @(& git -C $RepoRoot status --porcelain=v1 --untracked-files=all -- $relative)
        if ($LASTEXITCODE -ne 0 -or @($status | Where-Object { $_ }).Count -ne 0) { throw "canonical-manifest-dirty: $relative" }
    }
}

function Get-DirectCanonicalSkillNames {
    param([Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { return @() }
    return @(Get-ChildItem -LiteralPath $Root -Directory -Force | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } | ForEach-Object Name | Sort-Object -Unique)
}

function Get-CanonicalUnknownGeneratedInventory {
    param([Parameter(Mandatory)][string]$RepoRoot)
    $rows = [System.Collections.Generic.List[object]]::new()
    $platforms = @(
        @{ Name='Claude'; Root='claude/skills'; Manifest='manifests/managed-skills.claude.txt' },
        @{ Name='Codex'; Root='codex/skills'; Manifest='manifests/managed-skills.codex.txt' },
        @{ Name='Reasonix'; Root='reasonix/skills'; Manifest='manifests/managed-skills.reasonix.txt' }
    )
    foreach ($platform in $platforms) {
        $managed = @(Read-CanonicalManifestNames -Path (Join-Path $RepoRoot $platform.Manifest))
        $root = Join-Path $RepoRoot $platform.Root
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }
        foreach ($entry in @(Get-ChildItem -LiteralPath $root -Force | Sort-Object Name)) {
            if ($entry.Name -in $managed) { continue }
            $marker = Get-NoFollowRootEntryMarker -Path $entry.FullName
            $entryType = if ($marker.EntryType -eq 'MISSING') { 'File' } elseif ($marker.EntryType -in @('File','Directory','ReparsePoint')) { $marker.EntryType } else { 'File' }
            $rows.Add([ordered]@{ Platform=$platform.Name; Name=$entry.Name; EntryType=$entryType; Identity=$marker.Identity })
        }
    }
    return @($rows | Sort-Object Platform,Name)
}

function New-CanonicalTargetRow {
    param(
        [int]$Order,
        [ValidateSet('directory','file','parent-directory')][string]$TargetKind,
        [ValidateSet('canonical','generated','manifest','parent')][string]$Role,
        [string]$Platform,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$TargetPath,
        [AllowNull()][string]$CandidatePath,
        [Parameter(Mandatory)]$Current,
        [Parameter(Mandatory)]$Candidate
    )
    $context = Resolve-TargetContext -Path $TargetPath -Mode MetadataOnly
    $row = [ordered]@{
        Order=$Order
        TargetKind=$TargetKind
        Role=$Role
        RelativePath=([System.IO.Path]::GetRelativePath($RepoRoot,[System.IO.Path]::GetFullPath($TargetPath))).Replace([char]92,[char]47)
        TargetPath=[System.IO.Path]::GetFullPath($TargetPath)
        CandidatePath=if ($CandidatePath) { [System.IO.Path]::GetFullPath($CandidatePath) } else { $null }
        Current=$Current
        Candidate=$Candidate
        TargetContextHash=[string]$context.RequestedInitialRootContextHash
    }
    if ($Platform) { $row.Platform=$Platform }
    return $row
}

function Add-MissingCanonicalParentRows {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.Generic.List[object]]$Rows, [Parameter(Mandatory)][string]$RepoRoot, [Parameter(Mandatory)][string]$TargetPath)
    $parent = Split-Path -Parent ([System.IO.Path]::GetFullPath($TargetPath))
    $missing = [System.Collections.Generic.List[string]]::new()
    while ($parent -and (Test-PathInsideRoot -Path $parent -Root $RepoRoot) -and -not (Test-Path -LiteralPath $parent)) {
        $missing.Add($parent); $parent = Split-Path -Parent $parent
    }
    $emptyHash = Get-SemanticJsonHash -InputObject @([ordered]@{ Type='Directory'; RelativePath='.' })
    foreach ($path in @($missing | Sort-Object { $_.Length })) {
        if (@($Rows | Where-Object { $_.TargetPath -ieq $path }).Count -eq 0) {
            $Rows.Add((New-CanonicalTargetRow -Order 0 -TargetKind parent-directory -Role parent -RepoRoot $RepoRoot -TargetPath $path -CandidatePath $null -Current ([ordered]@{State='MISSING'}) -Candidate ([ordered]@{State='PRESENT';Hash=$emptyHash})))
        }
    }
}

function New-CanonicalSkillPlanPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('normalize','promote','merge')][string]$OperationKind,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CandidateWorkspace,
        [Parameter(Mandatory)][string]$InputPath,
        [string[]]$RewriteList=@(),
        [Parameter(Mandatory)][string]$CanonicalPreflightOutputRoot,
        [Parameter(Mandatory)][string]$BuildResultPath,
        [Parameter(Mandatory)][string]$ScanResultPath,
        [Parameter(Mandatory)][string]$ArtifactManifestPath,
        [Parameter(Mandatory)][string]$ArtifactValidationSummaryPath,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )
    $git = Get-CanonicalGitContext -RepoRoot $RepoRoot
    $candidate = (Resolve-Path -LiteralPath $CandidateWorkspace).Path
    $candidateSource = (Resolve-Path -LiteralPath (Join-Path $candidate 'skills-source')).Path
    Assert-CanonicalManifestsClean -RepoRoot $git.RepoRoot
    $preflight = Confirm-CanonicalPreflightArtifactValidation -ToolchainRoot $ToolchainRoot -RepoRoot $git.RepoRoot -CanonicalPreflightOutputRoot $CanonicalPreflightOutputRoot -BuildResultPath $BuildResultPath -ScanResultPath $ScanResultPath -ArtifactManifestPath $ArtifactManifestPath -ArtifactValidationSummaryPath $ArtifactValidationSummaryPath -ForbiddenRoots @($candidate)
    $unknown = @(Get-CanonicalUnknownGeneratedInventory -RepoRoot $git.RepoRoot)
    $probeContext = Resolve-TargetContext -Path (Join-Path $git.RepoRoot 'skills-source') -Mode MutationPreflight -ProbeRoot $candidate
    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($class in @('shared','claude-only','codex-only','reasonix-only')) {
        $currentRoot = Join-Path $git.RepoRoot (Join-Path 'skills-source' $class)
        $candidateRoot = Join-Path $candidateSource $class
        $names = @(Get-DirectCanonicalSkillNames -Root $currentRoot) + @(Get-DirectCanonicalSkillNames -Root $candidateRoot) | Sort-Object -Unique
        foreach ($name in $names) {
            $target = Join-Path $currentRoot $name; $source = Join-Path $candidateRoot $name
            $old = Get-CanonicalPathState -Path $target -Kind directory; $new = Get-CanonicalPathState -Path $source -Kind directory
            if ((Get-SemanticJsonHash -InputObject $old) -cne (Get-SemanticJsonHash -InputObject $new)) {
                Add-MissingCanonicalParentRows -Rows $rows -RepoRoot $git.RepoRoot -TargetPath $target
                $rows.Add((New-CanonicalTargetRow -Order 0 -TargetKind directory -Role canonical -RepoRoot $git.RepoRoot -TargetPath $target -CandidatePath $(if($new.State -eq 'PRESENT'){$source}else{$null}) -Current $old -Candidate $new))
            }
        }
    }

    $platforms = @(
        @{ Name='Claude'; Root='claude/skills'; Manifest='manifests/managed-skills.claude.txt'; Candidate='claude/skills' },
        @{ Name='Codex'; Root='codex/skills'; Manifest='manifests/managed-skills.codex.txt'; Candidate='codex/skills' },
        @{ Name='Reasonix'; Root='reasonix/skills'; Manifest='manifests/managed-skills.reasonix.txt'; Candidate='reasonix/skills' }
    )
    foreach ($platform in $platforms) {
        $currentNames = @(Read-CanonicalManifestNames -Path (Join-Path $git.RepoRoot $platform.Manifest))
        $candidateManifest = Join-Path $candidate (Join-Path 'manifests' ([System.IO.Path]::GetFileName($platform.Manifest)))
        $candidateNames = @(Read-CanonicalManifestNames -Path $candidateManifest)
        foreach ($name in @($currentNames + $candidateNames | Sort-Object -Unique)) {
            $target = Join-Path $git.RepoRoot (Join-Path $platform.Root $name)
            $source = Join-Path $candidate (Join-Path $platform.Candidate $name)
            if ($name -notin $currentNames -and (Test-Path -LiteralPath $target)) { throw "Candidate would overwrite unknown generated entry: $($platform.Name)/$name" }
            $old=Get-CanonicalPathState -Path $target -Kind directory; $new=Get-CanonicalPathState -Path $source -Kind directory
            if ((Get-SemanticJsonHash -InputObject $old) -cne (Get-SemanticJsonHash -InputObject $new)) {
                Add-MissingCanonicalParentRows -Rows $rows -RepoRoot $git.RepoRoot -TargetPath $target
                $rows.Add((New-CanonicalTargetRow -Order 0 -TargetKind directory -Role generated -Platform $platform.Name -RepoRoot $git.RepoRoot -TargetPath $target -CandidatePath $(if($new.State -eq 'PRESENT'){$source}else{$null}) -Current $old -Candidate $new))
            }
        }
    }

    foreach ($manifest in @(
        @{ Platform='Claude'; Name='managed-skills.claude.txt' },
        @{ Platform='Codex'; Name='managed-skills.codex.txt' },
        @{ Platform='Reasonix'; Name='managed-skills.reasonix.txt' },
        @{ Platform='Union'; Name='managed-skills.txt' }
    )) {
        $target=Join-Path $git.RepoRoot (Join-Path 'manifests' $manifest.Name); $source=Join-Path $candidate (Join-Path 'manifests' $manifest.Name)
        $rows.Add((New-CanonicalTargetRow -Order 0 -TargetKind file -Role manifest -Platform $manifest.Platform -RepoRoot $git.RepoRoot -TargetPath $target -CandidatePath $source -Current (Get-CanonicalPathState -Path $target -Kind file) -Candidate (Get-CanonicalPathState -Path $source -Kind file)))
    }
    $ordered = @($rows | Sort-Object @{Expression={switch($_.Role){'parent'{0}'canonical'{1}'generated'{2}'manifest'{3}}}},RelativePath)
    for ($i=0;$i -lt $ordered.Count;$i++) { $ordered[$i].Order=$i }
    $payload = [ordered]@{
        OperationKind=$OperationKind
        RepoRoot=$git.RepoRoot
        GitCommonDirHash=$git.GitCommonDirHash
        WorktreeId=$git.WorktreeId
        RepositoryCommit=$git.RepositoryCommit
        ToolchainPolicyHash=Get-CanonicalToolchainPolicyHash -ToolchainRoot $ToolchainRoot
        FilesystemCapabilityHash=[string]$probeContext.FilesystemCapabilityHash
        UnknownGeneratedInventory=$unknown
        ExpectedPostconditionsHash=Get-SemanticJsonHash -InputObject ([ordered]@{ Targets=@($ordered | ForEach-Object { [ordered]@{Path=$_.RelativePath;Candidate=$_.Candidate} }); Unknown=$unknown })
        CandidateWorkspace=$candidate
        CandidateSourceRoot=$candidateSource
        CanonicalPreflightOutputRoot=[System.IO.Path]::GetFullPath($CanonicalPreflightOutputRoot)
        BuildResultPath=$preflight.BuildResultPath
        BuildResultHash=$preflight.BuildResultHash
        ScanResultPath=$preflight.ScanResultPath
        ScanResultHash=$preflight.ScanResultHash
        ArtifactManifestPath=$preflight.ArtifactManifestPath
        ArtifactManifestHash=$preflight.ArtifactManifestHash
        ArtifactValidationSummaryPath=$preflight.ArtifactValidationSummaryPath
        ArtifactValidationSummaryHash=$preflight.ArtifactValidationSummaryHash
        Input=Get-CanonicalInputEvidence -Path $InputPath
        RewriteList=@($RewriteList | Sort-Object -Unique)
        Targets=$ordered
    }
    return $payload
}

function Get-CanonicalTokenSid {
    [CmdletBinding()]
    param()
    try { $sid=[System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
    catch { throw 'canonical-token-sid-unavailable' }
    if([string]::IsNullOrWhiteSpace($sid)){throw 'canonical-token-sid-unavailable'}
    return $sid
}

function Get-CanonicalTokenDefaultOwnerSid {
    [CmdletBinding()]
    param()
    try { $ownerSid=[System.Security.Principal.WindowsIdentity]::GetCurrent().Owner.Value }
    catch { throw 'canonical-token-owner-unavailable' }
    if([string]::IsNullOrWhiteSpace($ownerSid)){throw 'canonical-token-owner-unavailable'}
    return $ownerSid
}

function Test-CanonicalAllowedOwnerSid {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$OwnerSid,[Parameter(Mandatory)][string]$TokenSid)
    return ([string]$OwnerSid -ceq $TokenSid -or [string]$OwnerSid -ceq (Get-CanonicalTokenDefaultOwnerSid))
}

function Get-CanonicalRepoIdentity {
    param([Parameter(Mandatory)]$GitContext)
    $sid=Get-CanonicalTokenSid
    $commonMarker=Get-NoFollowRootEntryMarker -Path $GitContext.GitCommonDir
    return Get-CanonicalRepoIdentityFromHeldGitCommonDir -TokenSid $sid -GitCommonDirIdentity ([string]$commonMarker.Identity)
}

function Get-CanonicalRepoIdentityFromHeldGitCommonDir {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TokenSid,
        [Parameter(Mandatory)][string]$GitCommonDirIdentity
    )

    $identityParts=@($GitCommonDirIdentity -split ':',2)
    if($TokenSid -cnotmatch '^S-[0-9]+(?:-[0-9]+)+$' -or $identityParts.Count -ne 2 -or
        [string]::IsNullOrWhiteSpace($identityParts[0]) -or [string]::IsNullOrWhiteSpace($identityParts[1])) {
        throw 'Unable to derive canonical repository identity.'
    }
    return Get-SemanticJsonHash -InputObject ([ordered]@{
        Domain='ai-agent-dotfiles/canonical-repo/v1'
        TokenSid=$TokenSid
        VolumeIdentity=$identityParts[0]
        DirectoryIdentity=$identityParts[1]
    })
}

function Test-CanonicalHeldPathEqual {
    param([Parameter(Mandatory)][string]$Left,[Parameter(Mandatory)][string]$Right)
    return [IO.Path]::GetFullPath($Left).Equals([IO.Path]::GetFullPath($Right),[StringComparison]::OrdinalIgnoreCase)
}

function Get-CanonicalHeldOrdinalStrings {
    param([AllowEmptyCollection()][string[]]$Values=@())
    $result=[string[]]@($Values)
    [Array]::Sort($result,[StringComparer]::Ordinal)
    return $result
}

function Test-CanonicalHeldOrdinalStringArrayEqual {
    param([AllowEmptyCollection()][string[]]$Left=@(),[AllowEmptyCollection()][string[]]$Right=@())
    $leftItems=@($Left);$rightItems=@($Right)
    if($leftItems.Count -ne $rightItems.Count){return $false}
    for($index=0;$index -lt $leftItems.Count;$index++){if([string]$leftItems[$index] -cne [string]$rightItems[$index]){return $false}}
    return $true
}

function Get-CanonicalHeldDirectoryChainProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Handles,
        [Parameter(Mandatory)][string]$Label
    )

    $full=[IO.Path]::GetFullPath($Path)
    $volumeRoot=[IO.Path]::GetPathRoot($full)
    $relative=[IO.Path]::GetRelativePath($volumeRoot,$full)
    $segments=if($relative -ceq '.'){@()}else{@($relative -split '[\\/]')}
    $held=@($Handles)
    if($held.Count -ne ($segments.Count+1)){throw "$Label containment-chain cardinality mismatch"}
    $rows=[Collections.Generic.List[object]]::new()
    $current=$volumeRoot
    for($index=0;$index -lt $held.Count;$index++){
        $handle=$held[$index]
        if($handle -isnot [AiAgentDotfiles.SafeDirectoryHandle]){throw "$Label contains a non-directory handle"}
        if($index -gt 0){$current=[IO.Path]::GetFullPath((Join-Path $current ([string]$segments[$index-1])))}
        $securityBefore=[AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($handle)
        $streamsBefore=@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($handle))
        $securityAfter=[AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($handle)
        $streamsAfter=@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($handle))
        if(-not $handle.Info.IsDirectory -or $handle.Info.IsReparsePoint -or [long]$handle.Info.LinkCount -ne 1 -or
            [string]$securityBefore.Identity -cne [string]$handle.Info.Identity -or [string]$securityAfter.Identity -cne [string]$handle.Info.Identity -or
            [long]$securityBefore.LinkCount -ne 1 -or [long]$securityAfter.LinkCount -ne 1 -or [string]$securityBefore.Sddl -cne [string]$securityAfter.Sddl -or
            $streamsBefore.Count -ne 0 -or $streamsAfter.Count -ne 0){throw "$Label held directory evidence is unstable"}
        if($index -gt 0){
            $relativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($held[$index-1],[string]$segments[$index-1])
            if(-not $relativeInfo.IsDirectory -or $relativeInfo.IsReparsePoint -or [long]$relativeInfo.LinkCount -ne 1 -or
                [string]$relativeInfo.Identity -cne [string]$handle.Info.Identity){throw "$Label relative directory identity changed"}
        }
        $securityHash=Get-SemanticJsonHash -InputObject ([ordered]@{
            Domain='ai-agent-dotfiles/canonical-held-directory-security/v1'
            Identity=[string]$securityAfter.Identity;LinkCount=[long]$securityAfter.LinkCount;Sddl=[string]$securityAfter.Sddl
        })
        $rows.Add([ordered]@{
            Path=[IO.Path]::GetFullPath($current)
            LocationKey=[IO.Path]::GetFullPath($current).ToLowerInvariant().Replace([char]92,[char]47)
            Identity=[string]$securityAfter.Identity
            LinkCount=[long]$securityAfter.LinkCount
            SecurityHash=$securityHash
            NamedStreamCount=0L
        })
    }
    return [ordered]@{
        ResolverVersion='windows-no-follow-held-directory-chain-v1'
        Label=$Label
        Path=$full
        LocationKey=$full.ToLowerInvariant().Replace([char]92,[char]47)
        LeafIdentity=[string]$rows[$rows.Count-1].Identity
        Rows=@($rows)
    }
}

function Open-CanonicalHeldDirectoryChainCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$Label)

    $handles=$null
    try{
        $full=[IO.Path]::GetFullPath($Path)
        $handlesReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path $full -OwnershipReceiver $handlesReceiver
        $handles=$handlesReceiver.GetDeliveredExact()
        $projection=Get-CanonicalHeldDirectoryChainProjection -Path $full -Handles @($handles) -Label $Label
        $capture=[pscustomobject][ordered]@{
            Path=$full;Label=$Label;Handles=$handles;Projection=$projection
            ProjectionHash=Get-SemanticJsonHash -InputObject $projection;IsClosed=$false
        }
        $capture.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalHeldDirectoryChainCapture')
        return $capture
    }
    catch{
        if($null -ne $handles){Close-SafeDirectoryContainmentChain -Handles $handles}
        throw
    }
}

function Assert-CanonicalHeldDirectoryChainCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Capture)

    if('AiAgentDotfiles.CanonicalHeldDirectoryChainCapture' -cnotin @($Capture.PSObject.TypeNames) -or [bool]$Capture.IsClosed){throw 'canonical directory witness is missing, untyped, or closed'}
    $heldProjection=Get-CanonicalHeldDirectoryChainProjection -Path ([string]$Capture.Path) -Handles @($Capture.Handles) -Label ([string]$Capture.Label)
    $heldHash=Get-SemanticJsonHash -InputObject $heldProjection
    if($heldHash -cne [string]$Capture.ProjectionHash -or $heldHash -cne (Get-SemanticJsonHash -InputObject $Capture.Projection)){throw 'canonical held directory projection drift'}
    $fresh=$null
    try{
        $freshReceiver=[AiAgentDotfiles.SealedOwnershipTransferReceiver]::new()
        Open-SafeDirectoryContainmentChain -Path ([string]$Capture.Path) -OwnershipReceiver $freshReceiver
        $fresh=$freshReceiver.GetDeliveredExact()
        $freshProjection=Get-CanonicalHeldDirectoryChainProjection -Path ([string]$Capture.Path) -Handles @($fresh) -Label ([string]$Capture.Label)
        if((Get-SemanticJsonHash -InputObject $freshProjection) -cne $heldHash){throw 'canonical directory path no longer names the held chain'}
    }
    finally{if($null -ne $fresh){Close-SafeDirectoryContainmentChain -Handles $fresh}}
    return $true
}

function Close-CanonicalHeldDirectoryChainCapture {
    param([AllowNull()]$Capture)
    if($null -eq $Capture -or [bool]$Capture.IsClosed){return}
    Close-SafeDirectoryContainmentChain -Handles @($Capture.Handles)
    $Capture.IsClosed=$true
}

function Get-CanonicalHeldTransactionSetProjection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionsRoot,
        [Parameter(Mandatory)][string]$ExpectedRepoId,
        [Parameter(Mandatory)][string]$ExpectedGitCommonDirHash
    )

    try{$states=@(Get-CanonicalAllTransactionStates -TransactionsRoot $TransactionsRoot)}
    catch{throw 'canonical-recovery-required'}
    $rows=[Collections.Generic.List[object]]::new()
    $transactionIds=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($state in @($states | Sort-Object @{Expression={[string]$_.Header.WorktreeId}},@{Expression={[string]$_.Header.TransactionId}})){
        if(-not [bool]$state.IsTerminal -or @($state.PendingEntries).Count -ne 0){throw 'canonical-recovery-required'}
        if([string]$state.Header.RepoId -cne $ExpectedRepoId -or [string]$state.Header.GitCommonDirHash -cne $ExpectedGitCommonDirHash){throw 'canonical-recovery-required'}
        if(-not $transactionIds.Add([string]$state.Header.TransactionId)){throw 'canonical-recovery-required'}
        $rows.Add([ordered]@{
            WorktreeId=[string]$state.Header.WorktreeId
            TransactionId=[string]$state.Header.TransactionId
            TransactionNamespace=[IO.Path]::GetFullPath([string]$state.TransactionNamespace)
            HeaderHash=[string]$state.HeaderHash
            DerivedJournalHeadHash=[string]$state.DerivedJournalHeadHash
            ResultHash=[string]$state.ResultHash
            IsTerminal=[bool]$state.IsTerminal
            Outcome=[string]$state.Outcome
            ConsumedDocumentHashes=@(Get-CanonicalHeldOrdinalStrings -Values @($state.ConsumedDocumentHashes))
        })
    }
    return [ordered]@{
        ResolverVersion='canonical-phase1-held-transaction-set-projection-v1'
        TransactionsRoot=[IO.Path]::GetFullPath($TransactionsRoot)
        RepoId=$ExpectedRepoId
        GitCommonDirHash=$ExpectedGitCommonDirHash
        Transactions=@($rows)
    }
}

function ConvertFrom-CanonicalHeldSetupStateBytes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$GitCommonDirHash,
        [Parameter(Mandatory)][string]$TokenSid
    )

    $json=[Text.UTF8Encoding]::new($false,$true).GetString($Bytes)
    $state=ConvertFrom-SemanticJson -Json $json
    if($state -isnot [Collections.IDictionary]){throw 'canonical setup state root must be an object'}
    $null=Invoke-CanonicalContractSchemaValidation -Path $Path -SchemaPath $SchemaPath -ContentBytes $Bytes
    if($state.SchemaVersion -isnot [long] -or [long]$state.SchemaVersion -ne 1 -or [string]$state.ArtifactKind -cne 'canonical-setup-state'){throw 'canonical setup state v1 contract mismatch'}
    if([string]$state.RepoId -cne $RepoId -or [string]$state.ClaimId -cne $RepoId -or [string]$state.GitCommonDirHash -cne $GitCommonDirHash){throw 'canonical setup state repository binding mismatch'}
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate
    $templateHash=Get-SemanticJsonHash -InputObject $template
    if([string]$template.OwnerSid -cne $TokenSid -or [string]$state.OwnerSid -cne $TokenSid -or
        [string]$state.SecurityResolverVersion -cne [string]$template.ResolverVersion -or [string]$state.SecurityTemplateHash -cne $templateHash){throw 'canonical setup state security binding mismatch'}
    foreach($binding in @(
        [pscustomobject]@{Context=$state.CanonicalRecoveryRootIntent;Hash=[string]$state.CanonicalRecoveryRootIntentHash;Final=$state.CanonicalRecoveryRootFinalContext;FinalHash=[string]$state.CanonicalRecoveryRootFinalContextHash},
        [pscustomobject]@{Context=$state.ControlBaseIntent;Hash=[string]$state.ControlBaseIntentHash;Final=$state.ControlBaseFinalContext;FinalHash=[string]$state.ControlBaseFinalContextHash},
        [pscustomobject]@{Context=$state.BackupRootIntent;Hash=[string]$state.BackupRootIntentHash;Final=$state.BackupRootFinalContext;FinalHash=[string]$state.BackupRootFinalContextHash}
    )){
        if((Get-CanonicalStableRootContextHash -Context $binding.Context) -cne $binding.Hash -or
            (Get-CanonicalStableRootContextHash -Context $binding.Final) -cne $binding.FinalHash -or [string]$binding.Final.TargetStatus -cne 'EXISTS'){throw 'canonical setup state root-context graph mismatch'}
    }
    $bootstrapIntent=[ordered]@{
        OwnerSid=[string]$state.OwnerSid;SecurityResolverVersion=[string]$state.SecurityResolverVersion;SecurityTemplateHash=[string]$state.SecurityTemplateHash
        CanonicalRecoveryRootIntent=$state.CanonicalRecoveryRootIntent;CanonicalRecoveryRootIntentHash=[string]$state.CanonicalRecoveryRootIntentHash
        ControlBaseIntent=$state.ControlBaseIntent;ControlBaseIntentHash=[string]$state.ControlBaseIntentHash
        BackupRootIntent=$state.BackupRootIntent;BackupRootIntentHash=[string]$state.BackupRootIntentHash
    }
    if((Get-SemanticJsonHash -InputObject $bootstrapIntent) -cne [string]$state.SetupIntentHash -or
        (Get-SemanticJsonHash -InputObject (Get-CanonicalSetupStateProjection -State $state)) -cne [string]$state.SetupStateProjectionHash){throw 'canonical setup state semantic graph mismatch'}
    return $state
}

function Get-CanonicalHeldSetupStateCaptureProjection {
    param([Parameter(Mandatory)]$Capture)
    return [ordered]@{
        Path=[string]$Capture.Path;Identity=[string]$Capture.Identity;Length=[long]$Capture.Length
        BytesHash=[string]$Capture.BytesHash;SemanticHash=[string]$Capture.SemanticHash
        SecurityHash=[string]$Capture.SecurityHash;RootClaimHash=[string]$Capture.Document.RootClaimHash
        SetupStateProjectionHash=[string]$Capture.Document.SetupStateProjectionHash
    }
}

function Open-CanonicalHeldSetupStateCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$ContractCapture,
        [Parameter(Mandatory)][string]$SetupStatePath,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$GitCommonDirHash,
        [Parameter(Mandatory)][string]$TokenSid
    )

    $held=$null
    try{
        $null=Assert-CanonicalHeldDirectoryChainCapture -Capture $ContractCapture
        $full=[IO.Path]::GetFullPath($SetupStatePath)
        if(-not(Test-CanonicalHeldPathEqual -Left (Split-Path -Parent $full) -Right ([string]$ContractCapture.Path)) -or [IO.Path]::GetFileName($full) -cne 'canonical-setup-state.json'){throw 'canonical setup state path mismatch'}
        $parent=@($ContractCapture.Handles)[@($ContractCapture.Handles).Count-1]
        $initial=[AiAgentDotfiles.NoFollowFile]::TryInspectChild($parent,'canonical-setup-state.json')
        if($null -eq $initial){throw 'canonical-setup-required'}
        $held=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($parent,'canonical-setup-state.json')
        if([string]$initial.Identity -cne [string]$held.ReadResult.Identity -or [long]$initial.LinkCount -ne 1 -or [long]$initial.Length -ne [long]$held.ReadResult.Length){throw 'canonical setup state identity changed while opening'}
        $bytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,4194304L)
        $securityBefore=[AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($held)
        $bytesAgain=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,4194304L)
        $securityAfter=[AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($held)
        if([string]$securityBefore.Identity -cne [string]$held.ReadResult.Identity -or [string]$securityAfter.Identity -cne [string]$held.ReadResult.Identity -or
            [long]$securityBefore.LinkCount -ne 1 -or [long]$securityAfter.LinkCount -ne 1 -or [string]$securityBefore.Sddl -cne [string]$securityAfter.Sddl -or
            -not [Linq.Enumerable]::SequenceEqual([byte[]]$bytes,[byte[]]$bytesAgain)){throw 'canonical setup state held evidence is unstable'}
        $document=ConvertFrom-CanonicalHeldSetupStateBytes -Bytes $bytes -Path $full -SchemaPath $SchemaPath -RepoId $RepoId -GitCommonDirHash $GitCommonDirHash -TokenSid $TokenSid
        $capture=[pscustomobject][ordered]@{
            Path=$full;Handle=$held;Identity=[string]$held.ReadResult.Identity;Length=[long]$held.ReadResult.Length
            Bytes=[byte[]]$bytes;BytesHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes)).ToLowerInvariant()
            SemanticHash=Get-SemanticJsonHash -InputObject $document;SecuritySddl=[string]$securityAfter.Sddl
            SecurityHash=Get-SemanticJsonHash -InputObject ([ordered]@{Identity=[string]$securityAfter.Identity;LinkCount=[long]$securityAfter.LinkCount;Sddl=[string]$securityAfter.Sddl})
            Document=$document;SchemaPath=[IO.Path]::GetFullPath($SchemaPath);RepoId=$RepoId;GitCommonDirHash=$GitCommonDirHash;TokenSid=$TokenSid;ProjectionHash=$null;IsClosed=$false
        }
        $capture.ProjectionHash=Get-SemanticJsonHash -InputObject (Get-CanonicalHeldSetupStateCaptureProjection -Capture $capture)
        $capture.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalHeldSetupStateCapture')
        $held=$null
        return $capture
    }
    catch{
        if($null -ne $held){$held.Dispose()}
        if($_.Exception.Message -ceq 'canonical-setup-required'){throw}
        throw [InvalidOperationException]::new('canonical-recovery-required',$_.Exception)
    }
}

function Assert-CanonicalHeldSetupStateCapture {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Capture)

    if('AiAgentDotfiles.CanonicalHeldSetupStateCapture' -cnotin @($Capture.PSObject.TypeNames) -or [bool]$Capture.IsClosed -or
        $Capture.Handle -isnot [AiAgentDotfiles.SafeRegularFileHandle]){throw 'canonical setup-state capture is missing, untyped, or closed'}
    $bytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($Capture.Handle,4194304L)
    $security=[AiAgentDotfiles.NoFollowFile]::GetRegularFileSecuritySnapshot($Capture.Handle)
    $bytesHash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$bytes)).ToLowerInvariant()
    $storedBytes=[byte[]]$Capture.Bytes
    if([string]$Capture.Handle.ReadResult.Identity -cne [string]$Capture.Identity -or [long]$Capture.Handle.ReadResult.Length -ne [long]$Capture.Length -or
        $bytesHash -cne [string]$Capture.BytesHash -or [string]$security.Identity -cne [string]$Capture.Identity -or [long]$security.LinkCount -ne 1 -or
        $storedBytes.LongLength -ne [long]$Capture.Length -or [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($storedBytes)).ToLowerInvariant() -cne [string]$Capture.BytesHash -or
        [string]$security.Sddl -cne [string]$Capture.SecuritySddl -or
        (Get-SemanticJsonHash -InputObject ([ordered]@{Identity=[string]$security.Identity;LinkCount=[long]$security.LinkCount;Sddl=[string]$security.Sddl})) -cne [string]$Capture.SecurityHash){throw 'canonical setup-state held evidence drift'}
    $document=ConvertFrom-CanonicalHeldSetupStateBytes -Bytes $bytes -Path ([string]$Capture.Path) -SchemaPath ([string]$Capture.SchemaPath) -RepoId ([string]$Capture.RepoId) -GitCommonDirHash ([string]$Capture.GitCommonDirHash) -TokenSid ([string]$Capture.TokenSid)
    if((Get-SemanticJsonHash -InputObject $document) -cne [string]$Capture.SemanticHash -or
        (Get-SemanticJsonHash -InputObject $Capture.Document) -cne [string]$Capture.SemanticHash -or
        (Get-SemanticJsonHash -InputObject (Get-CanonicalHeldSetupStateCaptureProjection -Capture $Capture)) -cne [string]$Capture.ProjectionHash){throw 'canonical setup-state semantic projection drift'}
    return $true
}

function Close-CanonicalHeldSetupStateCapture {
    param([AllowNull()]$Capture)
    if($null -eq $Capture -or [bool]$Capture.IsClosed){return}
    $Capture.Handle.Dispose();$Capture.IsClosed=$true
}

function Get-CanonicalHeldNamespaceWitnessProjection {
    param([Parameter(Mandatory)]$Witness)
    return [ordered]@{
        ResolverVersion=[string]$Witness.ResolverVersion;TokenSid=[string]$Witness.TokenSid
        RepoRoot=[string]$Witness.RepoRoot;RepoRootPath=[string]$Witness.RepoRootPath;RepoRootChainHash=[string]$Witness.RepoRootCapture.ProjectionHash
        GitDir=[string]$Witness.GitDir;GitDirPath=[string]$Witness.GitDirPath;GitDirChainHash=[string]$Witness.GitDirCapture.ProjectionHash
        GitCommonDir=[string]$Witness.GitCommonDir;GitCommonDirPath=[string]$Witness.GitCommonDirPath;GitCommonDirChainHash=[string]$Witness.GitCommonDirCapture.ProjectionHash
        ContractRoot=[string]$Witness.ContractRoot;ContractRootPath=[string]$Witness.ContractRootPath;ContractRootChainHash=[string]$Witness.ContractRootCapture.ProjectionHash
        LockPath=[string]$Witness.LockPath;LockIdentity=[string]$Witness.CanonicalLockHandle.HeldLock.Info.Identity;LockSecurityHash=[string]$Witness.CanonicalLockHandle.SecurityHash
        RepoId=[string]$Witness.RepoId;GitCommonDirHash=[string]$Witness.GitCommonDirHash;WorktreeId=[string]$Witness.WorktreeId;RepositoryCommit=[string]$Witness.RepositoryCommit
        SetupStatePath=[string]$Witness.SetupStatePath;SetupStateProjectionHash=[string]$Witness.SetupStateCapture.ProjectionHash;SetupStateSemanticHash=[string]$Witness.SetupStateSemanticHash
        SetupStateStatus=[string]$Witness.SetupStateStatus;CanonicalTransactionCoverage=[string]$Witness.CanonicalTransactionCoverage
        UnfinishedCanonicalTransactionCount=[long]$Witness.UnfinishedCanonicalTransactionCount;CanonicalTransactionSetHash=[string]$Witness.CanonicalTransactionSetHash;ToolchainRoot=[string]$Witness.ToolchainRoot
        ContractRootInitialNames=@($Witness.ContractRootInitialNames)
    }
}

function Open-CanonicalHeldNamespaceWitness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$CanonicalLockHandle,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )

    $repoCapture=$null;$gitDirCapture=$null;$commonCapture=$null;$contractCapture=$null;$stateCapture=$null
    try{
        $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
        $paths=Get-CanonicalTransactionContractPaths -GitContext $git
        $null=Assert-CanonicalRepoLockHandle -LockHandle $CanonicalLockHandle -ExpectedLockPath ([string]$paths.LockPath)
        $repoCapture=Open-CanonicalHeldDirectoryChainCapture -Path ([string]$git.RepoRoot) -Label 'RepoRoot'
        $gitDirCapture=Open-CanonicalHeldDirectoryChainCapture -Path ([string]$git.GitDir) -Label 'GitDir'
        $commonCapture=Open-CanonicalHeldDirectoryChainCapture -Path ([string]$git.GitCommonDir) -Label 'GitCommonDir'
        $contractCapture=Open-CanonicalHeldDirectoryChainCapture -Path ([string]$paths.ContractRoot) -Label 'ContractRoot'
        $contractLeaf=@($contractCapture.Handles)[@($contractCapture.Handles).Count-1]
        $lockParent=@($CanonicalLockHandle.ParentHandles)[@($CanonicalLockHandle.ParentHandles).Count-1]
        if([string]$contractLeaf.Info.Identity -cne [string]$lockParent.Info.Identity){throw 'canonical lock is not held relative to the witnessed contract root'}

        $stableGit=Get-CanonicalGitContext -RepoRoot ([string]$git.RepoRoot)
        foreach($name in @('RepoRoot','GitDir','GitCommonDir','GitCommonDirHash','WorktreeId','RepositoryCommit')){
            if([string]$stableGit.$name -cne [string]$git.$name){throw 'canonical Git context changed during held capture'}
        }
        $tokenSid=Get-CanonicalTokenSid
        $heldCommonLeaf=@($commonCapture.Handles)[@($commonCapture.Handles).Count-1]
        $repoId=Get-CanonicalRepoIdentityFromHeldGitCommonDir -TokenSid $tokenSid -GitCommonDirIdentity ([string]$heldCommonLeaf.Info.Identity)
        $transactionProjection=Get-CanonicalHeldTransactionSetProjection -TransactionsRoot ([string]$paths.TransactionsRoot) -ExpectedRepoId $repoId -ExpectedGitCommonDirHash ([string]$git.GitCommonDirHash)
        $transactionHash=Get-SemanticJsonHash -InputObject $transactionProjection
        $schemaPath=Join-Path ([IO.Path]::GetFullPath($ToolchainRoot)) 'schemas/canonical-setup-state.schema.json'
        $stateCapture=Open-CanonicalHeldSetupStateCapture -ContractCapture $contractCapture -SetupStatePath ([string]$paths.SetupStatePath) -SchemaPath $schemaPath -RepoId $repoId -GitCommonDirHash ([string]$git.GitCommonDirHash) -TokenSid $tokenSid
        $contractNames=@(Get-CanonicalHeldOrdinalStrings -Values @([AiAgentDotfiles.NoFollowFile]::GetChildNames($contractLeaf)))
        $witness=[pscustomobject][ordered]@{
            ResolverVersion='windows-no-follow-canonical-namespace-witness-v1';CanonicalLockHandle=$CanonicalLockHandle;TokenSid=$tokenSid
            RepoRoot=[string]$git.RepoRoot;RepoRootPath=[string]$git.RepoRoot;RepoRootCapture=$repoCapture
            GitDir=[string]$git.GitDir;GitDirPath=[string]$git.GitDir;GitDirCapture=$gitDirCapture
            GitCommonDir=[string]$git.GitCommonDir;GitCommonDirPath=[string]$git.GitCommonDir;GitCommonDirCapture=$commonCapture
            ContractRoot=[string]$paths.ContractRoot;ContractRootPath=[string]$paths.ContractRoot;ContractRootCapture=$contractCapture
            LockPath=[string]$paths.LockPath;SetupStatePath=[string]$paths.SetupStatePath;TransactionsRoot=[string]$paths.TransactionsRoot
            RepoId=$repoId;GitCommonDirHash=[string]$git.GitCommonDirHash;WorktreeId=[string]$git.WorktreeId;RepositoryCommit=[string]$git.RepositoryCommit
            SetupStateStatus='VALID';SetupStateCapture=$stateCapture;SetupStateHandle=$stateCapture.Handle;SetupStateDocument=$stateCapture.Document;SetupStateBytes=[byte[]]$stateCapture.Bytes
            SetupStateIdentity=[string]$stateCapture.Identity;SetupStateLength=[long]$stateCapture.Length;SetupStateBytesHash=[string]$stateCapture.BytesHash;SetupStateSemanticHash=[string]$stateCapture.SemanticHash;SetupStateSecurityHash=[string]$stateCapture.SecurityHash
            CanonicalTransactionCoverage='WITNESSED';UnfinishedCanonicalTransactionCount=0L;CanonicalTransactionSetProjection=$transactionProjection;CanonicalTransactionSetHash=$transactionHash;ContractRootInitialNames=$contractNames
            ToolchainRoot=[IO.Path]::GetFullPath($ToolchainRoot);WitnessHash=$null;IsClosed=$false;Closed=$false
        }
        $witness.PSObject.TypeNames.Insert(0,'AiAgentDotfiles.CanonicalNamespaceWitness')
        $witness.WitnessHash=Get-SemanticJsonHash -InputObject (Get-CanonicalHeldNamespaceWitnessProjection -Witness $witness)
        $null=Assert-CanonicalHeldNamespaceWitness -Witness $witness -RepoRoot ([string]$git.RepoRoot) -CanonicalLockHandle $CanonicalLockHandle -ToolchainRoot $ToolchainRoot
        $stateCapture=$null;$contractCapture=$null;$commonCapture=$null;$gitDirCapture=$null;$repoCapture=$null
        return $witness
    }
    catch{
        if($null -ne $stateCapture){Close-CanonicalHeldSetupStateCapture -Capture $stateCapture}
        foreach($capture in @($contractCapture,$commonCapture,$gitDirCapture,$repoCapture)){if($null -ne $capture){Close-CanonicalHeldDirectoryChainCapture -Capture $capture}}
        if($_.Exception.Message -in @('canonical-witness-required','canonical-setup-required','canonical-recovery-required')){throw}
        throw 'canonical-witness-required'
    }
}

function Assert-CanonicalHeldNamespaceWitness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Witness,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)]$CanonicalLockHandle,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )

    try{
        if($null -eq $Witness -or 'AiAgentDotfiles.CanonicalNamespaceWitness' -cnotin @($Witness.PSObject.TypeNames) -or [bool]$Witness.IsClosed -or [bool]$Witness.Closed){throw 'invalid canonical witness type or lifetime'}
        if(-not [object]::ReferenceEquals($Witness.CanonicalLockHandle,$CanonicalLockHandle)){throw 'canonical witness lock reference mismatch'}
        if(-not(Test-CanonicalHeldPathEqual -Left ([string]$Witness.ToolchainRoot) -Right ([IO.Path]::GetFullPath($ToolchainRoot)))){throw 'canonical witness toolchain root mismatch'}
        foreach($aliasBinding in @(
            [pscustomobject]@{Alias=[string]$Witness.RepoRootPath;Canonical=[string]$Witness.RepoRoot},
            [pscustomobject]@{Alias=[string]$Witness.GitDirPath;Canonical=[string]$Witness.GitDir},
            [pscustomobject]@{Alias=[string]$Witness.GitCommonDirPath;Canonical=[string]$Witness.GitCommonDir},
            [pscustomobject]@{Alias=[string]$Witness.ContractRootPath;Canonical=[string]$Witness.ContractRoot}
        )){if(-not(Test-CanonicalHeldPathEqual -Left $aliasBinding.Alias -Right $aliasBinding.Canonical)){throw 'canonical witness path alias mismatch'}}
        $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
        $paths=Get-CanonicalTransactionContractPaths -GitContext $git
        $null=Assert-CanonicalRepoLockHandle -LockHandle $CanonicalLockHandle -ExpectedLockPath ([string]$paths.LockPath)
        foreach($binding in @(
            [pscustomobject]@{Actual=[string]$git.RepoRoot;Expected=[string]$Witness.RepoRoot},
            [pscustomobject]@{Actual=[string]$git.GitDir;Expected=[string]$Witness.GitDir},
            [pscustomobject]@{Actual=[string]$git.GitCommonDir;Expected=[string]$Witness.GitCommonDir},
            [pscustomobject]@{Actual=[string]$paths.ContractRoot;Expected=[string]$Witness.ContractRoot},
            [pscustomobject]@{Actual=[string]$paths.LockPath;Expected=[string]$Witness.LockPath},
            [pscustomobject]@{Actual=[string]$paths.SetupStatePath;Expected=[string]$Witness.SetupStatePath},
            [pscustomobject]@{Actual=[string]$paths.TransactionsRoot;Expected=[string]$Witness.TransactionsRoot}
        )){if(-not(Test-CanonicalHeldPathEqual -Left $binding.Actual -Right $binding.Expected)){throw 'canonical witness path mismatch'}}
        if([string]$git.GitCommonDirHash -cne [string]$Witness.GitCommonDirHash -or [string]$git.WorktreeId -cne [string]$Witness.WorktreeId -or
            [string]$git.RepositoryCommit -cne [string]$Witness.RepositoryCommit){throw 'canonical witness Git projection mismatch'}
        foreach($captureBinding in @(
            [pscustomobject]@{Capture=$Witness.RepoRootCapture;Path=[string]$Witness.RepoRoot;Label='RepoRoot'},
            [pscustomobject]@{Capture=$Witness.GitDirCapture;Path=[string]$Witness.GitDir;Label='GitDir'},
            [pscustomobject]@{Capture=$Witness.GitCommonDirCapture;Path=[string]$Witness.GitCommonDir;Label='GitCommonDir'},
            [pscustomobject]@{Capture=$Witness.ContractRootCapture;Path=[string]$Witness.ContractRoot;Label='ContractRoot'}
        )){
            if([string]$captureBinding.Capture.Label -cne [string]$captureBinding.Label -or -not(Test-CanonicalHeldPathEqual -Left ([string]$captureBinding.Capture.Path) -Right ([string]$captureBinding.Path))){throw 'canonical witness directory role mismatch'}
            $null=Assert-CanonicalHeldDirectoryChainCapture -Capture $captureBinding.Capture
        }
        $contractLeaf=@($Witness.ContractRootCapture.Handles)[@($Witness.ContractRootCapture.Handles).Count-1]
        $lockParent=@($CanonicalLockHandle.ParentHandles)[@($CanonicalLockHandle.ParentHandles).Count-1]
        if([string]$contractLeaf.Info.Identity -cne [string]$lockParent.Info.Identity){throw 'canonical witness lock/contract identity mismatch'}
        $tokenSid=Get-CanonicalTokenSid
        $commonLeaf=@($Witness.GitCommonDirCapture.Handles)[@($Witness.GitCommonDirCapture.Handles).Count-1]
        $repoId=Get-CanonicalRepoIdentityFromHeldGitCommonDir -TokenSid $tokenSid -GitCommonDirIdentity ([string]$commonLeaf.Info.Identity)
        if($tokenSid -cne [string]$Witness.TokenSid -or $repoId -cne [string]$Witness.RepoId){throw 'canonical witness repository identity mismatch'}
        $null=Assert-CanonicalHeldSetupStateCapture -Capture $Witness.SetupStateCapture
        if(-not [object]::ReferenceEquals($Witness.SetupStateHandle,$Witness.SetupStateCapture.Handle) -or
            -not(Test-CanonicalHeldPathEqual -Left ([string]$Witness.SetupStateCapture.Path) -Right ([string]$Witness.SetupStatePath)) -or
            [string]$Witness.SetupStateCapture.RepoId -cne [string]$Witness.RepoId -or [string]$Witness.SetupStateCapture.GitCommonDirHash -cne [string]$Witness.GitCommonDirHash -or
            [string]$Witness.SetupStateCapture.TokenSid -cne [string]$Witness.TokenSid -or
            -not(Test-CanonicalHeldPathEqual -Left ([string]$Witness.SetupStateCapture.SchemaPath) -Right (Join-Path ([string]$Witness.ToolchainRoot) 'schemas/canonical-setup-state.schema.json')) -or
            [string]$Witness.SetupStateBytesHash -cne [string]$Witness.SetupStateCapture.BytesHash -or
            [string]$Witness.SetupStateIdentity -cne [string]$Witness.SetupStateCapture.Identity -or [long]$Witness.SetupStateLength -ne [long]$Witness.SetupStateCapture.Length -or
            [string]$Witness.SetupStateSemanticHash -cne [string]$Witness.SetupStateCapture.SemanticHash -or [string]$Witness.SetupStateSecurityHash -cne [string]$Witness.SetupStateCapture.SecurityHash -or
            ([byte[]]$Witness.SetupStateBytes).LongLength -ne [long]$Witness.SetupStateLength -or
            [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([byte[]]$Witness.SetupStateBytes)).ToLowerInvariant() -cne [string]$Witness.SetupStateCapture.BytesHash -or
            (Get-SemanticJsonHash -InputObject $Witness.SetupStateDocument) -cne [string]$Witness.SetupStateCapture.SemanticHash -or
            [string]$Witness.SetupStateStatus -cne 'VALID' -or [string]$Witness.CanonicalTransactionCoverage -cne 'WITNESSED' -or [long]$Witness.UnfinishedCanonicalTransactionCount -ne 0){throw 'canonical witness setup-state alias mismatch'}
        $transactionProjection=Get-CanonicalHeldTransactionSetProjection -TransactionsRoot ([string]$Witness.TransactionsRoot) -ExpectedRepoId $repoId -ExpectedGitCommonDirHash ([string]$Witness.GitCommonDirHash)
        $transactionHash=Get-SemanticJsonHash -InputObject $transactionProjection
        if($transactionHash -cne [string]$Witness.CanonicalTransactionSetHash -or $transactionHash -cne (Get-SemanticJsonHash -InputObject $Witness.CanonicalTransactionSetProjection)){throw 'canonical-recovery-required'}
        $currentNames=@(Get-CanonicalHeldOrdinalStrings -Values @([AiAgentDotfiles.NoFollowFile]::GetChildNames($contractLeaf)))
        if(-not(Test-CanonicalHeldOrdinalStringArrayEqual -Left @($Witness.ContractRootInitialNames) -Right $currentNames)){throw 'canonical contract-root inventory drift'}
        if((Get-SemanticJsonHash -InputObject (Get-CanonicalHeldNamespaceWitnessProjection -Witness $Witness)) -cne [string]$Witness.WitnessHash){throw 'canonical witness projection hash mismatch'}
        return $true
    }
    catch{
        if($_.Exception.Message -ceq 'canonical-recovery-required'){throw}
        throw 'canonical-witness-required'
    }
}

function Close-CanonicalHeldNamespaceWitness {
    [CmdletBinding()]
    param([AllowNull()]$Witness)
    if($null -eq $Witness -or [bool]$Witness.IsClosed -or [bool]$Witness.Closed){return}
    Close-CanonicalHeldSetupStateCapture -Capture $Witness.SetupStateCapture
    foreach($capture in @($Witness.ContractRootCapture,$Witness.GitCommonDirCapture,$Witness.GitDirCapture,$Witness.RepoRootCapture)){Close-CanonicalHeldDirectoryChainCapture -Capture $capture}
    $Witness.IsClosed=$true;$Witness.Closed=$true
}

function Get-CanonicalCurrentUserOnlySecurityTemplate {
    [CmdletBinding()]
    param()
    $sid=Get-CanonicalTokenSid
    $inheritance=[long]([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit)
    return [ordered]@{
        ResolverVersion='windows-token-sid-current-user-only-v2'
        OwnerSid=$sid
        AreAccessRulesProtected=$true
        AccessRules=@([ordered]@{
            Sid=$sid
            AccessControlType=[long][System.Security.AccessControl.AccessControlType]::Allow
            FileSystemRights=[long][System.Security.AccessControl.FileSystemRights]::FullControl
            InheritanceFlags=$inheritance
            PropagationFlags=[long][System.Security.AccessControl.PropagationFlags]::None
            IsInherited=$false
        })
    }
}

function Get-CanonicalDirectorySecurityEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[string]$ExpectedIdentity)
    $full=[System.IO.Path]::GetFullPath($Path)
    $before=[AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($full)
    if($ExpectedIdentity -and [string]$before.Identity -cne $ExpectedIdentity){throw "canonical private root identity changed before owner/DACL capture: $full"}
    $raw=[System.Security.AccessControl.RawSecurityDescriptor]::new([string]$before.Sddl)
    if($null -eq $raw.Owner -or $null -eq $raw.DiscretionaryAcl){throw "canonical private root owner/DACL is unavailable: $full"}
    $ownerSid=[string]$raw.Owner.Value
    $rules=[System.Collections.Generic.List[object]]::new()
    foreach($ace in @($raw.DiscretionaryAcl)){
        if($ace -isnot [System.Security.AccessControl.CommonAce]){throw "canonical private root contains an unsupported ACL entry: $full"}
        $accessType=switch($ace.AceQualifier){
            ([System.Security.AccessControl.AceQualifier]::AccessAllowed){[long][System.Security.AccessControl.AccessControlType]::Allow;break}
            ([System.Security.AccessControl.AceQualifier]::AccessDenied){[long][System.Security.AccessControl.AccessControlType]::Deny;break}
            default{throw "canonical private root contains a non-access ACL entry: $full"}
        }
        $inheritance=[System.Security.AccessControl.InheritanceFlags]::None
        if(($ace.AceFlags -band [System.Security.AccessControl.AceFlags]::ContainerInherit) -ne 0){$inheritance=$inheritance -bor [System.Security.AccessControl.InheritanceFlags]::ContainerInherit}
        if(($ace.AceFlags -band [System.Security.AccessControl.AceFlags]::ObjectInherit) -ne 0){$inheritance=$inheritance -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit}
        $propagation=[System.Security.AccessControl.PropagationFlags]::None
        if(($ace.AceFlags -band [System.Security.AccessControl.AceFlags]::NoPropagateInherit) -ne 0){$propagation=$propagation -bor [System.Security.AccessControl.PropagationFlags]::NoPropagateInherit}
        if(($ace.AceFlags -band [System.Security.AccessControl.AceFlags]::InheritOnly) -ne 0){$propagation=$propagation -bor [System.Security.AccessControl.PropagationFlags]::InheritOnly}
        $rules.Add([ordered]@{
            Sid=[string]$ace.SecurityIdentifier.Value
            AccessControlType=$accessType
            FileSystemRights=[long]$ace.AccessMask
            InheritanceFlags=[long]$inheritance
            PropagationFlags=[long]$propagation
            IsInherited=(($ace.AceFlags -band [System.Security.AccessControl.AceFlags]::Inherited) -ne 0)
        })
    }
    $orderedRules=@($rules|Sort-Object @{Expression={[string]$_.Sid}},@{Expression={[long]$_.AccessControlType}},@{Expression={[long]$_.FileSystemRights}},@{Expression={[long]$_.InheritanceFlags}},@{Expression={[long]$_.PropagationFlags}},@{Expression={[bool]$_.IsInherited}})
    $after=[AiAgentDotfiles.NoFollowFile]::GetDirectorySecuritySnapshot($full)
    if([string]$before.Identity -cne [string]$after.Identity -or [string]$before.Sddl -cne [string]$after.Sddl){throw "canonical private root owner/DACL changed while reading: $full"}
    $protected=($raw.ControlFlags -band [System.Security.AccessControl.ControlFlags]::DiscretionaryAclProtected) -ne 0
    return [ordered]@{ResolverVersion='windows-token-sid-current-user-only-v2';OwnerSid=$ownerSid;AreAccessRulesProtected=$protected;AccessRules=$orderedRules}
}

function Assert-CanonicalCurrentUserOnlyDirectorySecurity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)]$Template,[string]$ExpectedIdentity)
    $actual=Get-CanonicalDirectorySecurityEvidence -Path $Path -ExpectedIdentity $ExpectedIdentity
    $broadSids=@('S-1-1-0','S-1-5-11','S-1-5-32-545')
    $writeMask=[long]([System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl)
    foreach($rule in @($actual.AccessRules)){
        if([string]$rule.Sid -in $broadSids -and [long]$rule.AccessControlType -eq [long][System.Security.AccessControl.AccessControlType]::Allow -and (([long]$rule.FileSystemRights -band $writeMask) -ne 0)){
            throw "canonical private root grants broad write access: $Path"
        }
    }
    $actualHash=Get-SemanticJsonHash -InputObject $actual
    $templateHash=Get-SemanticJsonHash -InputObject $Template
    $allowedHashes=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $null=$allowedHashes.Add($templateHash)
    $ownerVariant=[ordered]@{}
    foreach($key in @($Template.Keys)){ $ownerVariant[$key]=$Template[$key] }
    $ownerVariant.OwnerSid=Get-CanonicalTokenDefaultOwnerSid
    $null=$allowedHashes.Add((Get-SemanticJsonHash -InputObject $ownerVariant))
    if(-not $allowedHashes.Contains($actualHash)){throw "canonical private root owner/DACL does not match the current-user-only template: $Path"}
    return [pscustomobject][ordered]@{Evidence=$actual;EvidenceHash=$actualHash}
}

function Assert-CanonicalControlledPrivateAncestorSecurity {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Evidence,[Parameter(Mandatory)][string]$Path,[Parameter(Mandatory)][string]$TokenSid)
    if(-not (Test-CanonicalAllowedOwnerSid -OwnerSid ([string]$Evidence.OwnerSid) -TokenSid $TokenSid)){throw "canonical private root ancestor is not owned by the access-token owner: $Path"}
    $broadSids=@('S-1-1-0','S-1-5-11','S-1-5-32-545')
    $dangerousMask=[long]([System.Security.AccessControl.FileSystemRights]::Write -bor [System.Security.AccessControl.FileSystemRights]::Modify -bor [System.Security.AccessControl.FileSystemRights]::FullControl -bor [System.Security.AccessControl.FileSystemRights]::Delete -bor [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles)
    foreach($rule in @($Evidence.AccessRules)){
        if([string]$rule.Sid -in $broadSids -and [long]$rule.AccessControlType -eq [long][System.Security.AccessControl.AccessControlType]::Allow -and (([long]$rule.FileSystemRights -band $dangerousMask) -ne 0)){
            throw "canonical private root ancestor grants broad write/delete-child access: $Path"
        }
    }
}

function Get-CanonicalRootSecurityContext {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$TargetContext,[Parameter(Mandatory)]$SecurityTemplate)
    $parentEvidence=Get-CanonicalDirectorySecurityEvidence -Path ([string]$TargetContext.DeepestExistingParentPath) -ExpectedIdentity ([string]$TargetContext.DeepestExistingParentIdentity)
    $templateHash=Get-SemanticJsonHash -InputObject $SecurityTemplate
    $isExisting=[string]$TargetContext.TargetStatus -ceq 'EXISTS'
    $finalIdentity=$null;$finalOwnerSid=$null;$finalDaclHash=$null
    if($isExisting){
        if([string]$TargetContext.TargetType -cne 'Directory'){throw 'canonical private root exists but is not a directory'}
        $validated=Assert-CanonicalCurrentUserOnlyDirectorySecurity -Path ([string]$TargetContext.RequestedPath) -Template $SecurityTemplate -ExpectedIdentity ([string]$TargetContext.DeepestExistingParentIdentity)
        $finalIdentity=[string]$TargetContext.DeepestExistingParentIdentity
        $finalOwnerSid=[string]$validated.Evidence.OwnerSid
        $finalDaclHash=[string]$validated.EvidenceHash
    }
    else{
        Assert-CanonicalControlledPrivateAncestorSecurity -Evidence $parentEvidence -Path ([string]$TargetContext.DeepestExistingParentPath) -TokenSid ([string]$SecurityTemplate.OwnerSid)
    }
    return [ordered]@{
        ResolverVersion=[string]$SecurityTemplate.ResolverVersion
        TargetStatus=if($isExisting){'EXISTS'}else{'MISSING'}
        LocationKey=[string]$TargetContext.LocationKey
        RequestedPath=[string]$TargetContext.RequestedPath
        VolumeId=[string]$TargetContext.VolumeId
        DeepestExistingParentPath=[string]$TargetContext.DeepestExistingParentPath
        DeepestExistingParentIdentity=[string]$TargetContext.DeepestExistingParentIdentity
        DeepestExistingParentOwnerSid=[string]$parentEvidence.OwnerSid
        DeepestExistingParentDaclHash=Get-SemanticJsonHash -InputObject $parentEvidence
        MissingRemainder=@($TargetContext.MissingRemainder)
        ExpectedFinalOwnerSid=[string]$SecurityTemplate.OwnerSid
        ExpectedFinalDaclTemplateHash=$templateHash
        FinalDirectoryIdentity=$finalIdentity
        FinalOwnerSid=$finalOwnerSid
        FinalDaclHash=$finalDaclHash
    }
}

function Get-CanonicalDefaultLiveRoots {
    [CmdletBinding()]
    param()
    $profileRoot=[Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile)
    $roaming=[Environment]::GetFolderPath([Environment+SpecialFolder]::ApplicationData)
    if([string]::IsNullOrWhiteSpace($profileRoot) -or [string]::IsNullOrWhiteSpace($roaming)){throw 'canonical-known-folder-unavailable'}
    return @(
        [System.IO.Path]::GetFullPath((Join-Path $profileRoot '.claude/skills'))
        [System.IO.Path]::GetFullPath((Join-Path $profileRoot '.codex/skills'))
        [System.IO.Path]::GetFullPath((Join-Path $profileRoot '.agents/skills'))
        [System.IO.Path]::GetFullPath((Join-Path $roaming 'reasonix/skills'))
    )
}

function Get-CanonicalStableRootContextHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context)
    return Get-SemanticJsonHash -InputObject $Context
}

function Assert-CanonicalRecoveryVolumeMatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepositoryVolumeId,[Parameter(Mandatory)][string]$RecoveryVolumeId)
    if($RepositoryVolumeId -cne $RecoveryVolumeId){throw 'canonical-recovery-root-cross-volume'}
}

function Get-CanonicalSetupRootContexts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GitContext,
        [Parameter(Mandatory)][string]$CanonicalRecoveryRoot,
        [Parameter(Mandatory)][string]$ControlBase,
        [Parameter(Mandatory)][string]$BackupRoot
    )
    $liveRoots=@(Get-CanonicalDefaultLiveRoots)
    $fixedForbidden=@([string]$GitContext.RepoRoot,[string]$GitContext.GitCommonDir)+$liveRoots
    $recovery=Resolve-TargetContext -Path $CanonicalRecoveryRoot -Mode MetadataOnly -ForbiddenRoots ($fixedForbidden+@($ControlBase,$BackupRoot))
    $control=Resolve-TargetContext -Path $ControlBase -Mode MetadataOnly -ForbiddenRoots ($fixedForbidden+@($CanonicalRecoveryRoot,$BackupRoot))
    $backup=Resolve-TargetContext -Path $BackupRoot -Mode MetadataOnly -ForbiddenRoots ($fixedForbidden+@($CanonicalRecoveryRoot,$ControlBase))
    $repoContext=Resolve-TargetContext -Path ([string]$GitContext.RepoRoot) -Mode MetadataOnly
    Assert-CanonicalRecoveryVolumeMatch -RepositoryVolumeId ([string]$repoContext.VolumeId) -RecoveryVolumeId ([string]$recovery.VolumeId)
    return [pscustomobject][ordered]@{Recovery=$recovery;Control=$control;Backup=$backup;LiveRoots=$liveRoots}
}

function Get-CanonicalPrivateRootSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot)

    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $repoId=Get-CanonicalRepoIdentity -GitContext $git
    $localAppData=[Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if([string]::IsNullOrWhiteSpace($localAppData) -or -not(Test-Path -LiteralPath $localAppData -PathType Container)){throw 'canonical-known-folder-unavailable'}
    $privateBase=Join-Path $localAppData 'ai-agent-dotfiles'
    $repoParent=Split-Path -Parent $git.RepoRoot
    $recoveryBase=Join-Path $repoParent '.ai-agent-dotfiles-canonical-recovery'
    $recoveryRoot=Join-Path $recoveryBase $repoId
    $repoVolume=[AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($git.RepoRoot)
    $parentVolume=[AiAgentDotfiles.NoFollowFile]::GetVolumeInfo($repoParent)
    if($repoVolume.VolumeSerial -cne $parentVolume.VolumeSerial){throw 'canonical-recovery-root-cross-volume'}
    foreach($candidate in @($recoveryRoot,(Join-Path $privateBase 'control'),(Join-Path $privateBase 'backups'))){
        if(Test-TargetPathOverlap -Left $candidate -Right $git.RepoRoot){throw 'canonical-private-root-overlaps-working-tree'}
    }
    return [pscustomobject][ordered]@{
        RepoId=$repoId
        CanonicalRecoveryRoot=[System.IO.Path]::GetFullPath($recoveryRoot)
        ControlBase=[System.IO.Path]::GetFullPath((Join-Path $privateBase 'control'))
        BackupRoot=[System.IO.Path]::GetFullPath((Join-Path $privateBase 'backups'))
    }
}

function Get-CanonicalSetupStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RepoRoot,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)

    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $paths=Get-CanonicalTransactionContractPaths -GitContext $git
    $lockExists=Test-Path -LiteralPath $paths.LockPath -PathType Leaf
    $transactionsExist=Test-Path -LiteralPath $paths.TransactionsRoot -PathType Container
    if($transactionsExist -and -not $lockExists){return 'manual-recovery-required'}

    $lock=$null
    if($lockExists){
        try{$lock=Enter-CanonicalRepoLock -LockPath $paths.LockPath}
        catch{if($_.Exception.Message -match 'operation-lock-busy'){return 'canonical-recovery-required'};return 'manual-recovery-required'}
    }
    try{
        $lockExistsAfter=Test-Path -LiteralPath $paths.LockPath -PathType Leaf
        $transactionsExist=Test-Path -LiteralPath $paths.TransactionsRoot -PathType Container
        if(-not $lock -and $lockExistsAfter){return 'canonical-recovery-required'}
        if($transactionsExist -and -not $lock){return 'manual-recovery-required'}
        if($lock -and -not $lockExistsAfter){return 'manual-recovery-required'}
        if($transactionsExist){
            try{$states=@(Get-CanonicalAllTransactionStates -TransactionsRoot $paths.TransactionsRoot)}catch{return 'manual-recovery-required'}
            if(@($states|Where-Object{-not $_.IsTerminal}).Count -gt 0){return 'canonical-recovery-required'}
        }

        $stateParent=Split-Path -Parent $paths.SetupStatePath
        if(Test-Path -LiteralPath $stateParent -PathType Container){
            foreach($entry in @([System.IO.Directory]::EnumerateFileSystemEntries($stateParent))){
                $name=[System.IO.Path]::GetFileName($entry)
                if($name -like 'canonical-setup-state*' -and $name -cne 'canonical-setup-state.json'){return 'manual-recovery-required'}
            }
        }
        if(-not(Test-Path -LiteralPath $paths.SetupStatePath)){return 'canonical-setup-required'}
        try{
            $state=Read-CanonicalJsonContractFile -Path $paths.SetupStatePath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-setup-state.schema.json')
            if([string]$state.GitCommonDirHash -cne [string]$git.GitCommonDirHash){throw 'setup state belongs to another Git common directory'}
            $repoId=Get-CanonicalRepoIdentity -GitContext $git
            if([string]$state.RepoId -cne $repoId -or [string]$state.ClaimId -cne $repoId){throw 'setup state repository identity mismatch'}
            $securityTemplate=Get-CanonicalCurrentUserOnlySecurityTemplate
            $securityTemplateHash=Get-SemanticJsonHash -InputObject $securityTemplate
            if([string]$state.OwnerSid -cne [string]$securityTemplate.OwnerSid -or [string]$state.SecurityResolverVersion -cne [string]$securityTemplate.ResolverVersion -or [string]$state.SecurityTemplateHash -cne $securityTemplateHash){throw 'setup state security template mismatch'}
            $contexts=Get-CanonicalSetupRootContexts -GitContext $git -CanonicalRecoveryRoot ([string]$state.CanonicalRecoveryRoot) -ControlBase ([string]$state.ControlBase) -BackupRoot ([string]$state.BackupRoot)
            $rootBindings=@(
                [pscustomobject]@{TargetContext=$contexts.Recovery;Intent=$state.CanonicalRecoveryRootIntent;IntentHash=[string]$state.CanonicalRecoveryRootIntentHash;Final=$state.CanonicalRecoveryRootFinalContext;FinalHash=[string]$state.CanonicalRecoveryRootFinalContextHash}
                [pscustomobject]@{TargetContext=$contexts.Control;Intent=$state.ControlBaseIntent;IntentHash=[string]$state.ControlBaseIntentHash;Final=$state.ControlBaseFinalContext;FinalHash=[string]$state.ControlBaseFinalContextHash}
                [pscustomobject]@{TargetContext=$contexts.Backup;Intent=$state.BackupRootIntent;IntentHash=[string]$state.BackupRootIntentHash;Final=$state.BackupRootFinalContext;FinalHash=[string]$state.BackupRootFinalContextHash}
            )
            foreach($binding in $rootBindings){
                if((Get-CanonicalStableRootContextHash -Context $binding.Intent) -cne [string]$binding.IntentHash){throw 'setup state root intent hash mismatch'}
                if([string]$binding.Final.TargetStatus -cne 'EXISTS'){throw 'setup state lacks final private-root evidence'}
                $actualSecurityContext=Get-CanonicalRootSecurityContext -TargetContext $binding.TargetContext -SecurityTemplate $securityTemplate
                if([string]$actualSecurityContext.TargetStatus -cne 'EXISTS'){throw 'setup state references an incomplete private root'}
                $storedHash=Get-CanonicalStableRootContextHash -Context $binding.Final
                $actualHash=Get-CanonicalStableRootContextHash -Context $actualSecurityContext
                if($storedHash -cne [string]$binding.FinalHash -or $actualHash -cne [string]$binding.FinalHash){throw 'setup state root owner/DACL/identity context mismatch'}
            }
            $bootstrapIntent=[ordered]@{
                OwnerSid=[string]$state.OwnerSid;SecurityResolverVersion=[string]$state.SecurityResolverVersion;SecurityTemplateHash=[string]$state.SecurityTemplateHash
                CanonicalRecoveryRootIntent=$state.CanonicalRecoveryRootIntent;CanonicalRecoveryRootIntentHash=[string]$state.CanonicalRecoveryRootIntentHash
                ControlBaseIntent=$state.ControlBaseIntent;ControlBaseIntentHash=[string]$state.ControlBaseIntentHash
                BackupRootIntent=$state.BackupRootIntent;BackupRootIntentHash=[string]$state.BackupRootIntentHash
            }
            if((Get-SemanticJsonHash -InputObject $bootstrapIntent) -cne [string]$state.SetupIntentHash){throw 'setup state intent graph mismatch'}
            $projection=Get-CanonicalSetupStateProjection -State $state
            $projectionHash=Get-SemanticJsonHash -InputObject $projection
            if($projectionHash -cne [string]$state.SetupStateProjectionHash){throw 'setup state projection hash mismatch'}
            $claimPath=Join-Path ([string]$state.ControlBase) (Join-Path 'canonical-roots' ($repoId+'.json'))
            if(-not(Test-Path -LiteralPath $claimPath -PathType Leaf)){throw 'canonical root claim is missing'}
            $claim=Read-CanonicalJsonContractFile -Path $claimPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-root-claim.schema.json')
            $claimHash=Get-SemanticJsonHash -InputObject $claim
            if($claimHash -cne [string]$state.RootClaimHash){throw 'canonical root claim hash does not match final setup state'}
            if([string]$claim.RepoId -cne $repoId -or [string]$claim.ClaimId -cne $repoId -or [string]$claim.ExpectedSetupStateProjectionHash -cne $projectionHash -or [string]$claim.SetupIntentHash -cne [string]$state.SetupIntentHash){throw 'canonical root claim does not match setup state projection'}
            foreach($field in @('GitCommonDirHash','OwnerSid','SecurityResolverVersion','SecurityTemplateHash','CanonicalRecoveryRoot','CanonicalRecoveryRootIntentHash','FilesystemCapabilityHash','ControlBase','ControlBaseIntentHash','BackupRoot','BackupRootIntentHash','SetupIntentHash')){
                if([string]$claim[$field] -cne [string]$state[$field]){throw "canonical root claim/state mismatch for $field"}
            }
            foreach($field in @('CanonicalRecoveryRootIntent','ControlBaseIntent','BackupRootIntent')){
                if((Get-SemanticJsonHash -InputObject $claim[$field]) -cne (Get-SemanticJsonHash -InputObject $state[$field])){throw "canonical root claim/state context mismatch for $field"}
            }
            return 'canonical-ready'
        }catch{return 'manual-recovery-required'}
    }
    finally{if($lock){Exit-CanonicalRepoLock -LockHandle $lock}}
}

function New-CanonicalSetupPlanPayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$CanonicalRecoveryRoot,
        [Parameter(Mandatory)][string]$ControlBase,
        [Parameter(Mandatory)][string]$BackupRoot,
        [Parameter(Mandatory)][string]$ProbeRoot,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $contexts=Get-CanonicalSetupRootContexts -GitContext $git -CanonicalRecoveryRoot $CanonicalRecoveryRoot -ControlBase $ControlBase -BackupRoot $BackupRoot
    $recovery=Resolve-TargetContext -Path $CanonicalRecoveryRoot -Mode MutationPreflight -ProbeRoot $ProbeRoot -ForbiddenRoots (@($git.RepoRoot,$git.GitCommonDir,$ControlBase,$BackupRoot)+@($contexts.LiveRoots))
    $control=$contexts.Control
    $backup=$contexts.Backup
    $securityTemplate=Get-CanonicalCurrentUserOnlySecurityTemplate
    $securityTemplateHash=Get-SemanticJsonHash -InputObject $securityTemplate
    $recoverySecurityContext=Get-CanonicalRootSecurityContext -TargetContext $contexts.Recovery -SecurityTemplate $securityTemplate
    $controlSecurityContext=Get-CanonicalRootSecurityContext -TargetContext $control -SecurityTemplate $securityTemplate
    $backupSecurityContext=Get-CanonicalRootSecurityContext -TargetContext $backup -SecurityTemplate $securityTemplate
    $recoveryContextHash=Get-CanonicalStableRootContextHash -Context $recoverySecurityContext
    $controlContextHash=Get-CanonicalStableRootContextHash -Context $controlSecurityContext
    $backupContextHash=Get-CanonicalStableRootContextHash -Context $backupSecurityContext
    $repoId=Get-CanonicalRepoIdentity -GitContext $git
    $bootstrapIntent=[ordered]@{
        OwnerSid=[string]$securityTemplate.OwnerSid; SecurityResolverVersion=[string]$securityTemplate.ResolverVersion; SecurityTemplateHash=$securityTemplateHash
        CanonicalRecoveryRootIntent=$recoverySecurityContext; CanonicalRecoveryRootIntentHash=$recoveryContextHash
        ControlBaseIntent=$controlSecurityContext; ControlBaseIntentHash=$controlContextHash
        BackupRootIntent=$backupSecurityContext; BackupRootIntentHash=$backupContextHash
    }
    $setupIntentHash=Get-SemanticJsonHash -InputObject $bootstrapIntent
    $stateProjection=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-setup-state-projection';RepoId=$repoId;ClaimId=$repoId;GitCommonDirHash=$git.GitCommonDirHash
        OwnerSid=[string]$securityTemplate.OwnerSid;SecurityResolverVersion=[string]$securityTemplate.ResolverVersion;SecurityTemplateHash=$securityTemplateHash
        CanonicalRecoveryRoot=[System.IO.Path]::GetFullPath($CanonicalRecoveryRoot);CanonicalRecoveryRootIntent=$recoverySecurityContext;CanonicalRecoveryRootIntentHash=$recoveryContextHash
        FilesystemCapabilityHash=[string]$recovery.FilesystemCapabilityHash;ControlBase=[System.IO.Path]::GetFullPath($ControlBase);ControlBaseIntent=$controlSecurityContext;ControlBaseIntentHash=$controlContextHash
        BackupRoot=[System.IO.Path]::GetFullPath($BackupRoot);BackupRootIntent=$backupSecurityContext;BackupRootIntentHash=$backupContextHash;SetupIntentHash=$setupIntentHash
    }
    $stateProjectionHash=Get-SemanticJsonHash -InputObject $stateProjection
    $claim=[ordered]@{
        SchemaVersion=1; ArtifactKind='canonical-root-claim'; RepoId=$repoId; ClaimId=$repoId; GitCommonDirHash=$git.GitCommonDirHash
        OwnerSid=[string]$securityTemplate.OwnerSid; SecurityResolverVersion=[string]$securityTemplate.ResolverVersion; SecurityTemplateHash=$securityTemplateHash
        CanonicalRecoveryRoot=[System.IO.Path]::GetFullPath($CanonicalRecoveryRoot); CanonicalRecoveryRootIntent=$recoverySecurityContext; CanonicalRecoveryRootIntentHash=$recoveryContextHash
        FilesystemCapabilityHash=[string]$recovery.FilesystemCapabilityHash; ControlBase=[System.IO.Path]::GetFullPath($ControlBase)
        ControlBaseIntent=$controlSecurityContext; ControlBaseIntentHash=$controlContextHash; BackupRoot=[System.IO.Path]::GetFullPath($BackupRoot); BackupRootIntent=$backupSecurityContext
        BackupRootIntentHash=$backupContextHash; SetupIntentHash=$setupIntentHash; ExpectedSetupStateProjectionHash=$stateProjectionHash
    }
    return [ordered]@{
        OperationKind='setup'; RepoRoot=$git.RepoRoot; GitCommonDirHash=$git.GitCommonDirHash; WorktreeId=$git.WorktreeId; RepositoryCommit=$git.RepositoryCommit
        ToolchainPolicyHash=Get-CanonicalToolchainPolicyHash -ToolchainRoot $ToolchainRoot; FilesystemCapabilityHash=[string]$recovery.FilesystemCapabilityHash
        UnknownGeneratedInventory=@(); ExpectedPostconditionsHash=$stateProjectionHash
        PrivateRootBootstrapIntent=$bootstrapIntent;SetupIntentHash=$setupIntentHash
        ExpectedRootClaim=$claim;ExpectedRootClaimHash=Get-SemanticJsonHash -InputObject $claim
        ExpectedSetupStateProjection=$stateProjection;ExpectedSetupStateProjectionHash=$stateProjectionHash
    }
}

function Get-CanonicalSetupStateProjection {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)
    return [ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-setup-state-projection';RepoId=[string]$State.RepoId;ClaimId=[string]$State.ClaimId;GitCommonDirHash=[string]$State.GitCommonDirHash
        OwnerSid=[string]$State.OwnerSid;SecurityResolverVersion=[string]$State.SecurityResolverVersion;SecurityTemplateHash=[string]$State.SecurityTemplateHash
        CanonicalRecoveryRoot=[string]$State.CanonicalRecoveryRoot;CanonicalRecoveryRootIntent=$State.CanonicalRecoveryRootIntent;CanonicalRecoveryRootIntentHash=[string]$State.CanonicalRecoveryRootIntentHash
        FilesystemCapabilityHash=[string]$State.FilesystemCapabilityHash;ControlBase=[string]$State.ControlBase;ControlBaseIntent=$State.ControlBaseIntent;ControlBaseIntentHash=[string]$State.ControlBaseIntentHash
        BackupRoot=[string]$State.BackupRoot;BackupRootIntent=$State.BackupRootIntent;BackupRootIntentHash=[string]$State.BackupRootIntentHash;SetupIntentHash=[string]$State.SetupIntentHash
    }
}

function New-CanonicalFinalSetupState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$PlanPayload,[Parameter(Mandatory)][string]$RepoRoot)
    if([string]$PlanPayload.OperationKind -cne 'setup'){throw 'canonical final setup state requires a setup plan payload'}
    $projection=$PlanPayload.ExpectedSetupStateProjection
    if((Get-SemanticJsonHash -InputObject $projection) -cne [string]$PlanPayload.ExpectedSetupStateProjectionHash){throw 'canonical setup projection hash mismatch'}
    if((Get-SemanticJsonHash -InputObject $PlanPayload.PrivateRootBootstrapIntent) -cne [string]$PlanPayload.SetupIntentHash){throw 'canonical setup intent hash mismatch'}
    $rootClaimHash=Get-SemanticJsonHash -InputObject $PlanPayload.ExpectedRootClaim
    if($rootClaimHash -cne [string]$PlanPayload.ExpectedRootClaimHash){throw 'canonical root claim hash mismatch'}
    if([string]$projection.SetupIntentHash -cne [string]$PlanPayload.SetupIntentHash -or [string]$PlanPayload.ExpectedRootClaim.SetupIntentHash -cne [string]$PlanPayload.SetupIntentHash -or [string]$PlanPayload.ExpectedRootClaim.ExpectedSetupStateProjectionHash -cne [string]$PlanPayload.ExpectedSetupStateProjectionHash){throw 'canonical final setup state intent/claim/projection link mismatch'}
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    if([string]$projection.GitCommonDirHash -cne [string]$git.GitCommonDirHash -or [string]$projection.RepoId -cne (Get-CanonicalRepoIdentity -GitContext $git)){throw 'canonical final setup state repository mismatch'}
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate
    if([string]$projection.OwnerSid -cne [string]$template.OwnerSid -or [string]$projection.SecurityTemplateHash -cne (Get-SemanticJsonHash -InputObject $template)){throw 'canonical final setup state security template mismatch'}
    $contexts=Get-CanonicalSetupRootContexts -GitContext $git -CanonicalRecoveryRoot ([string]$projection.CanonicalRecoveryRoot) -ControlBase ([string]$projection.ControlBase) -BackupRoot ([string]$projection.BackupRoot)
    $finalRecovery=Get-CanonicalRootSecurityContext -TargetContext $contexts.Recovery -SecurityTemplate $template
    $finalControl=Get-CanonicalRootSecurityContext -TargetContext $contexts.Control -SecurityTemplate $template
    $finalBackup=Get-CanonicalRootSecurityContext -TargetContext $contexts.Backup -SecurityTemplate $template
    foreach($context in @($finalRecovery,$finalControl,$finalBackup)){if([string]$context.TargetStatus -cne 'EXISTS'){throw 'canonical final setup state requires existing private roots'}}
    return [ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-setup-state';RepoId=[string]$projection.RepoId;ClaimId=[string]$projection.ClaimId;GitCommonDirHash=[string]$projection.GitCommonDirHash
        OwnerSid=[string]$projection.OwnerSid;SecurityResolverVersion=[string]$projection.SecurityResolverVersion;SecurityTemplateHash=[string]$projection.SecurityTemplateHash
        CanonicalRecoveryRoot=[string]$projection.CanonicalRecoveryRoot;CanonicalRecoveryRootIntent=$projection.CanonicalRecoveryRootIntent;CanonicalRecoveryRootIntentHash=[string]$projection.CanonicalRecoveryRootIntentHash
        CanonicalRecoveryRootFinalContext=$finalRecovery;CanonicalRecoveryRootFinalContextHash=Get-SemanticJsonHash -InputObject $finalRecovery;FilesystemCapabilityHash=[string]$projection.FilesystemCapabilityHash
        ControlBase=[string]$projection.ControlBase;ControlBaseIntent=$projection.ControlBaseIntent;ControlBaseIntentHash=[string]$projection.ControlBaseIntentHash
        ControlBaseFinalContext=$finalControl;ControlBaseFinalContextHash=Get-SemanticJsonHash -InputObject $finalControl
        BackupRoot=[string]$projection.BackupRoot;BackupRootIntent=$projection.BackupRootIntent;BackupRootIntentHash=[string]$projection.BackupRootIntentHash
        BackupRootFinalContext=$finalBackup;BackupRootFinalContextHash=Get-SemanticJsonHash -InputObject $finalBackup
        SetupIntentHash=[string]$projection.SetupIntentHash;SetupStateProjectionHash=[string]$PlanPayload.ExpectedSetupStateProjectionHash;RootClaimHash=$rootClaimHash
    }
}

function Write-CanonicalTransactionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$PlanPayload,[Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$RepoRoot,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)
    $resolved=Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot -AllowMissingLeaf
    if ($resolved.Exists) { throw "Canonical PlanPath must be create-new: $($resolved.FullPath)" }
    $git=Get-CanonicalGitContext -RepoRoot $RepoRoot
    $document=[ordered]@{
        SchemaVersion=1; ArtifactKind='canonical-transaction-plan'
        Metadata=[ordered]@{ CreatedAtUtc=[DateTime]::UtcNow.ToString('o'); Generator='scripts/canonical-transaction.ps1'; RepositoryCommit=$git.RepositoryCommit }
        PlanPayload=$PlanPayload; PlanHash=Get-PlanHash -PlanPayload $PlanPayload
    }
    $document.DocumentHash=Get-DocumentHash -Document $document
    $null=Publish-ValidatedPreflightJson -Document $document -Path $resolved.FullPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-transaction-plan.schema.json')
    return $document
}

function Read-CanonicalTransactionPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$PlanPath,[Parameter(Mandatory)][string]$RepoRoot,[string]$ExpectedOperationKind,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)
    $resolved=Resolve-PrivateArtifactPath -Path $PlanPath -Role ExternalUserArtifact -RepoRoot $RepoRoot
    $document=Read-CanonicalJsonContractFile -Path $resolved.FullPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-transaction-plan.schema.json')
    if ([string]$document.PlanHash -cne (Get-PlanHash -PlanPayload $document.PlanPayload)) { throw 'canonical-plan-hash-mismatch' }
    if ([string]$document.DocumentHash -cne (Get-DocumentHash -Document $document)) { throw 'canonical-document-hash-mismatch' }
    if ($ExpectedOperationKind -and [string]$document.PlanPayload.OperationKind -cne $ExpectedOperationKind) { throw 'canonical-operation-kind-mismatch' }
    if ([string]$document.PlanPayload.RepoRoot -cne (Resolve-Path -LiteralPath $RepoRoot).Path) { throw 'canonical-plan-repository-mismatch' }
    if ([string]$document.PlanPayload.OperationKind -eq 'setup') {
        $claimKeys=@('ArtifactKind','BackupRoot','BackupRootIntent','BackupRootIntentHash','CanonicalRecoveryRoot','CanonicalRecoveryRootIntent','CanonicalRecoveryRootIntentHash','ClaimId','ControlBase','ControlBaseIntent','ControlBaseIntentHash','ExpectedSetupStateProjectionHash','FilesystemCapabilityHash','GitCommonDirHash','OwnerSid','RepoId','SchemaVersion','SecurityResolverVersion','SecurityTemplateHash','SetupIntentHash')|Sort-Object
        if (@(Compare-Object $claimKeys @($document.PlanPayload.ExpectedRootClaim.Keys|Sort-Object)).Count -ne 0) { throw 'canonical-root-claim-shape-mismatch' }
        $planBytes=ConvertTo-SemanticJsonBytes -InputObject $document.PlanPayload.ExpectedRootClaim
        $null=Invoke-CanonicalContractSchemaValidation -Path $resolved.FullPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-root-claim.schema.json') -ContentBytes $planBytes
        $projection=$document.PlanPayload.ExpectedSetupStateProjection
        if ([string]$document.PlanPayload.ExpectedRootClaim.RepoId -cne [string]$document.PlanPayload.ExpectedRootClaim.ClaimId -or [string]$projection.RepoId -cne [string]$projection.ClaimId) { throw 'canonical-setup-id-mismatch' }
        if ([string]$document.PlanPayload.ExpectedSetupStateProjectionHash -cne (Get-SemanticJsonHash -InputObject $projection)) { throw 'canonical-setup-state-projection-hash-mismatch' }
        if ([string]$document.PlanPayload.ExpectedRootClaimHash -cne (Get-SemanticJsonHash -InputObject $document.PlanPayload.ExpectedRootClaim)) { throw 'canonical-root-claim-hash-mismatch' }
        if ([string]$document.PlanPayload.ExpectedRootClaim.ExpectedSetupStateProjectionHash -cne [string]$document.PlanPayload.ExpectedSetupStateProjectionHash -or [string]$document.PlanPayload.ExpectedRootClaim.SetupIntentHash -cne [string]$document.PlanPayload.SetupIntentHash) { throw 'canonical-claim-state-projection-link-mismatch' }
        if ((Get-SemanticJsonHash -InputObject $document.PlanPayload.PrivateRootBootstrapIntent) -cne [string]$document.PlanPayload.SetupIntentHash) { throw 'canonical-bootstrap-intent-hash-mismatch' }
        foreach($name in @('OwnerSid','SecurityResolverVersion','SecurityTemplateHash','CanonicalRecoveryRoot','CanonicalRecoveryRootIntentHash','ControlBase','ControlBaseIntentHash','BackupRoot','BackupRootIntentHash','SetupIntentHash')){if([string]$document.PlanPayload.ExpectedRootClaim[$name] -cne [string]$projection[$name]){throw 'canonical-claim-state-projection-link-mismatch'}}
        foreach($name in @('CanonicalRecoveryRootIntent','ControlBaseIntent','BackupRootIntent')){
            $claimContextHash=Get-SemanticJsonHash -InputObject $document.PlanPayload.ExpectedRootClaim[$name]
            $projectionContextHash=Get-SemanticJsonHash -InputObject $projection[$name]
            if($claimContextHash -cne $projectionContextHash){throw 'canonical-claim-state-projection-context-link-mismatch'}
        }
        $contextLinks=@(
            [pscustomobject]@{ContextName='CanonicalRecoveryRootIntent';HashName='CanonicalRecoveryRootIntentHash'}
            [pscustomobject]@{ContextName='ControlBaseIntent';HashName='ControlBaseIntentHash'}
            [pscustomobject]@{ContextName='BackupRootIntent';HashName='BackupRootIntentHash'}
        )
        foreach($link in $contextLinks){
            $contextName=[string]$link.ContextName;$hashName=[string]$link.HashName
            if((Get-SemanticJsonHash -InputObject $projection[$contextName]) -cne [string]$projection[$hashName]){throw 'canonical-setup-root-intent-hash-mismatch'}
            if((Get-SemanticJsonHash -InputObject $document.PlanPayload.PrivateRootBootstrapIntent[$contextName]) -cne [string]$document.PlanPayload.PrivateRootBootstrapIntent[$hashName]){throw 'canonical-bootstrap-root-context-hash-mismatch'}
            if((Get-SemanticJsonHash -InputObject $document.PlanPayload.PrivateRootBootstrapIntent[$contextName]) -cne (Get-SemanticJsonHash -InputObject $projection[$contextName])){throw 'canonical-bootstrap-projection-context-link-mismatch'}
        }
        foreach($name in @('OwnerSid','SecurityResolverVersion','SecurityTemplateHash')){if([string]$document.PlanPayload.PrivateRootBootstrapIntent[$name] -cne [string]$projection[$name]){throw 'canonical-bootstrap-security-link-mismatch'}}
    }
    return $document
}

function Assert-CanonicalPlanCurrent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document,[Parameter(Mandatory)][string]$PlanPath,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)
    $saved=$Document.PlanPayload
    $current = if ([string]$saved.OperationKind -eq 'setup') {
        New-CanonicalSetupPlanPayload -RepoRoot ([string]$saved.RepoRoot) -CanonicalRecoveryRoot ([string]$saved.ExpectedSetupStateProjection.CanonicalRecoveryRoot) -ControlBase ([string]$saved.ExpectedSetupStateProjection.ControlBase) -BackupRoot ([string]$saved.ExpectedSetupStateProjection.BackupRoot) -ProbeRoot (Split-Path -Parent ([System.IO.Path]::GetFullPath($PlanPath))) -ToolchainRoot $ToolchainRoot
    }
    else {
        New-CanonicalSkillPlanPayload -OperationKind ([string]$saved.OperationKind) -RepoRoot ([string]$saved.RepoRoot) -CandidateWorkspace ([string]$saved.CandidateWorkspace) -InputPath ([string]$saved.Input.Path) -RewriteList @($saved.RewriteList) -CanonicalPreflightOutputRoot ([string]$saved.CanonicalPreflightOutputRoot) -BuildResultPath ([string]$saved.BuildResultPath) -ScanResultPath ([string]$saved.ScanResultPath) -ArtifactManifestPath ([string]$saved.ArtifactManifestPath) -ArtifactValidationSummaryPath ([string]$saved.ArtifactValidationSummaryPath) -ToolchainRoot $ToolchainRoot
    }
    $hash=Get-PlanHash -PlanPayload $current
    if ($hash -cne [string]$Document.PlanHash) { throw 'canonical-plan-stale' }
    return [pscustomobject][ordered]@{ Result='PASS'; PlanHash=$hash; DocumentHash=[string]$Document.DocumentHash; OperationKind=[string]$saved.OperationKind }
}

function Assert-CanonicalDocumentHashNotConsumed {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DocumentHash,[object[]]$TerminalEvidence=@())
    foreach ($terminal in @($TerminalEvidence)) {
        if ([string]$terminal.Outcome -notin @('committed','abandoned','rolled-back','failed-restored')) { continue }
        $keys=@([string]$terminal.OriginalDocumentHash)+@($terminal.AttemptDocumentHashes | ForEach-Object {[string]$_})+@([string]$terminal.ClosingDocumentHash)
        if ($DocumentHash -in $keys) { throw 'reviewed-plan-consumed' }
    }
}

function Read-CanonicalReadySetupStateUnderLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$GitContext,[Parameter(Mandatory)]$ContractPaths,[string]$ToolchainRoot=$script:CanonicalToolchainRoot)

    $state=Read-CanonicalJsonContractFile -Path $ContractPaths.SetupStatePath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-setup-state.schema.json')
    $repoId=Get-CanonicalRepoIdentity -GitContext $GitContext
    if([string]$state.GitCommonDirHash -cne [string]$GitContext.GitCommonDirHash -or [string]$state.RepoId -cne $repoId -or [string]$state.ClaimId -cne $repoId){throw 'canonical setup identity mismatch'}
    $template=Get-CanonicalCurrentUserOnlySecurityTemplate;$templateHash=Get-SemanticJsonHash -InputObject $template
    if([string]$state.OwnerSid -cne [string]$template.OwnerSid -or [string]$state.SecurityResolverVersion -cne [string]$template.ResolverVersion -or [string]$state.SecurityTemplateHash -cne $templateHash){throw 'canonical setup security template mismatch'}
    $contexts=Get-CanonicalSetupRootContexts -GitContext $GitContext -CanonicalRecoveryRoot ([string]$state.CanonicalRecoveryRoot) -ControlBase ([string]$state.ControlBase) -BackupRoot ([string]$state.BackupRoot)
    foreach($binding in @(
        [pscustomobject]@{Context=$contexts.Recovery;Intent=$state.CanonicalRecoveryRootIntent;IntentHash=[string]$state.CanonicalRecoveryRootIntentHash;Final=$state.CanonicalRecoveryRootFinalContext;FinalHash=[string]$state.CanonicalRecoveryRootFinalContextHash},
        [pscustomobject]@{Context=$contexts.Control;Intent=$state.ControlBaseIntent;IntentHash=[string]$state.ControlBaseIntentHash;Final=$state.ControlBaseFinalContext;FinalHash=[string]$state.ControlBaseFinalContextHash},
        [pscustomobject]@{Context=$contexts.Backup;Intent=$state.BackupRootIntent;IntentHash=[string]$state.BackupRootIntentHash;Final=$state.BackupRootFinalContext;FinalHash=[string]$state.BackupRootFinalContextHash}
    )){
        $actual=Get-CanonicalRootSecurityContext -TargetContext $binding.Context -SecurityTemplate $template
        if((Get-CanonicalStableRootContextHash -Context $binding.Intent) -cne $binding.IntentHash -or [string]$binding.Final.TargetStatus -cne 'EXISTS' -or (Get-CanonicalStableRootContextHash -Context $binding.Final) -cne $binding.FinalHash -or (Get-CanonicalStableRootContextHash -Context $actual) -cne $binding.FinalHash){throw 'canonical setup root identity/owner/DACL mismatch'}
    }
    $projection=Get-CanonicalSetupStateProjection -State $state;$projectionHash=Get-SemanticJsonHash -InputObject $projection
    if($projectionHash -cne [string]$state.SetupStateProjectionHash){throw 'canonical setup projection mismatch'}
    $claimPath=Join-Path ([string]$state.ControlBase) (Join-Path 'canonical-roots' ($repoId+'.json'))
    $claim=Read-CanonicalJsonContractFile -Path $claimPath -SchemaPath (Join-Path $ToolchainRoot 'schemas/canonical-root-claim.schema.json')
    if((Get-SemanticJsonHash -InputObject $claim) -cne [string]$state.RootClaimHash -or [string]$claim.ExpectedSetupStateProjectionHash -cne $projectionHash -or [string]$claim.SetupIntentHash -cne [string]$state.SetupIntentHash){throw 'canonical setup claim/state mismatch'}
    return $state
}

function New-CanonicalJournalTargetsFromPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PlanPayload,
        [Parameter(Mandatory)][string]$RecoveryTransactionRoot
    )

    $recovery=[IO.Path]::GetFullPath($RecoveryTransactionRoot)
    $targets=[Collections.Generic.List[object]]::new()
    foreach($planned in @($PlanPayload.Targets|Sort-Object{[long]$_.Order})){
        $order=[long]$planned.Order;$kind=[string]$planned.TargetKind;$role=[string]$planned.Role
        $platform=if(Test-CanonicalDataField -Data $planned -Name 'Platform'){[string]$planned.Platform}else{$null}
        $targetPath=[IO.Path]::GetFullPath([string]$planned.TargetPath)
        $targetId=Get-CanonicalJournalTargetId -Order $order -TargetKind $kind -Role $role -Platform $platform -TargetPath $targetPath
        $row=[ordered]@{
            TargetId=$targetId;Order=$order;TargetKind=$kind;Role=$role;TargetPath=$targetPath
            PreimagePath=Join-Path $recovery (Join-Path 'preimage' $targetId)
            SwapOldPath=Join-Path $recovery (Join-Path 'swap-old' $targetId)
            StagedPath=if($kind -ceq 'parent-directory'){$null}else{Join-Path $recovery (Join-Path 'staged' $targetId)}
            Current=$planned.Current;Candidate=$planned.Candidate;TargetContextHash=[string]$planned.TargetContextHash
        }
        if($platform){$row.Platform=$platform}
        $targets.Add($row)
    }
    return @($targets)
}

function Initialize-CanonicalReviewedStaging {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PlanPayload,
        [Parameter(Mandatory)][string]$RecoveryTransactionRoot,
        [Parameter(Mandatory)][object[]]$Targets
    )

    $recovery=[IO.Path]::GetFullPath($RecoveryTransactionRoot)
    if(Test-Path -LiteralPath $recovery){throw 'canonical recovery transaction root must be create-new'}
    $worktreeRoot=Split-Path -Parent $recovery
    if(-not(Test-Path -LiteralPath $worktreeRoot -PathType Container)){[IO.Directory]::CreateDirectory($worktreeRoot)|Out-Null}
    [AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite($recovery)
    $stagedRoot=Join-Path $recovery 'staged';[AiAgentDotfiles.CanonicalNativeMutation]::CreateDirectoryNoOverwrite($stagedRoot)
    foreach($target in $Targets){
            $context=Resolve-TargetContext -Path ([string]$target.TargetPath) -Mode MetadataOnly
            if([string]$context.RequestedInitialRootContextHash -cne [string]$target.TargetContextHash){throw 'canonical target context changed before staging'}
            $expectedKind=if([string]$target.TargetKind -ceq 'file'){'file'}else{'directory'}
            $actualCurrent=Get-CanonicalObservedPathState -Path ([string]$target.TargetPath) -ExpectedKind $expectedKind
            if(-not(Test-CanonicalObservedMatchesContractState -Actual $actualCurrent -Contract $target.Current)){throw 'canonical target changed before staging'}
            if([string]$target.TargetKind -ceq 'parent-directory'){continue}
            $planned=@($PlanPayload.Targets|Where-Object{[long]$_.Order -eq [long]$target.Order})[0]
            if([string]$target.Candidate.State -ceq 'MISSING'){
                if($planned.CandidatePath){throw 'canonical MISSING candidate unexpectedly has a source path'}
                continue
            }
            if(-not $planned.CandidatePath){throw 'canonical PRESENT candidate lacks a source path'}
            if([string]$target.TargetKind -ceq 'directory'){$null=Copy-SafeTree -SourceRoot ([string]$planned.CandidatePath) -DestinationRoot ([string]$target.StagedPath)}
            else{$null=Copy-CanonicalFileCreateNew -Source ([string]$planned.CandidatePath) -Destination ([string]$target.StagedPath)}
            $staged=Get-CanonicalObservedPathState -Path ([string]$target.StagedPath) -ExpectedKind $expectedKind
            if(-not(Test-CanonicalObservedMatchesContractState -Actual $staged -Contract $target.Candidate)){throw 'canonical staged bytes differ from the reviewed candidate'}
    }
    return [pscustomobject][ordered]@{RecoveryTransactionRoot=$recovery;Targets=@($Targets)}
}

function Test-CanonicalCommittedPostconditions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PlanPayload,
        [Parameter(Mandatory)][string]$TransactionId,
        [string]$ToolchainRoot=$script:CanonicalToolchainRoot
    )

    $repo=[IO.Path]::GetFullPath([string]$PlanPayload.RepoRoot)
    $workspace=Join-Path $repo (Join-Path 'tmp/canonical-postconditions' $TransactionId)
    if(Test-Path -LiteralPath $workspace){throw 'canonical postcondition workspace must be create-new'}
    [IO.Directory]::CreateDirectory((Split-Path -Parent $workspace))|Out-Null
    $source=Join-Path $workspace 'skills-source';$null=Copy-SafeTree -SourceRoot (Join-Path $repo 'skills-source') -DestinationRoot $source
    $outputRoot=Join-Path ([string]$PlanPayload.CanonicalPreflightOutputRoot) (Join-Path 'postconditions' $TransactionId)
    if(Test-Path -LiteralPath $outputRoot){throw 'canonical postcondition output root must be create-new'}
    [IO.Directory]::CreateDirectory($outputRoot)|Out-Null
    $buildResult=Join-Path $outputRoot 'build-result.json';$scanResult=Join-Path $outputRoot 'scan-result.json'
    $artifactManifest=Join-Path $outputRoot 'artifact-manifest.json';$artifactValidationSummary=Join-Path $outputRoot 'artifact-validation-summary.json'
    $buildArgs=@(
        '-RepoRoot',$ToolchainRoot,'-CanonicalPreflight','-CandidateWorkspace',$workspace,'-SourceRoot',$source,
        '-ClaudeOutputRoot',(Join-Path $workspace 'claude/skills'),'-CodexOutputRoot',(Join-Path $workspace 'codex/skills'),
        '-ReasonixOutputRoot',(Join-Path $workspace 'reasonix/skills'),'-ManifestOutputRoot',(Join-Path $workspace 'manifests'),
        '-CanonicalPreflightOutputRoot',$outputRoot,'-JsonPath',$buildResult
    )
    $null=Invoke-CanonicalPreflightChild -ToolchainRoot $ToolchainRoot -ScriptName 'build-skills.ps1' -Arguments $buildArgs -ResultPath $buildResult -SchemaPath (Join-Path $ToolchainRoot 'schemas/run-report.schema.json')
    $scanArgs=@('-RepoRoot',$ToolchainRoot,'-CanonicalPreflight','-SourceRoot',$workspace,'-CanonicalPreflightOutputRoot',$outputRoot,'-ScannerConfigPath',(Join-Path $ToolchainRoot '.gitleaks.toml'),'-JsonPath',$scanResult)
    $null=Invoke-CanonicalPreflightChild -ToolchainRoot $ToolchainRoot -ScriptName 'scan-secrets.ps1' -Arguments $scanArgs -ResultPath $scanResult -SchemaPath (Join-Path $ToolchainRoot 'schemas/secret-scan.schema.json')
    $artifactValidation=Publish-CanonicalPreflightArtifactValidation -ToolchainRoot $ToolchainRoot -RepoRoot $repo -CanonicalPreflightOutputRoot $outputRoot -BuildResultPath $buildResult -ScanResultPath $scanResult -ArtifactManifestPath $artifactManifest -ArtifactValidationSummaryPath $artifactValidationSummary -ForbiddenRoots @($workspace)
    $candidateSource=Get-SafeTreeSnapshot -Root ([string]$PlanPayload.CandidateSourceRoot);$rebuiltSource=Get-SafeTreeSnapshot -Root $source
    if(-not(Compare-SafeContentTree -LeftRows $candidateSource.ContentTreeRows -RightRows $rebuiltSource.ContentTreeRows)){throw 'canonical postcondition source differs from the reviewed candidate'}
    foreach($target in @($PlanPayload.Targets|Where-Object{[string]$_.TargetKind -ne 'parent-directory'})){
        $expectedKind=if([string]$target.TargetKind -ceq 'file'){'file'}else{'directory'}
        $real=Get-CanonicalObservedPathState -Path ([string]$target.TargetPath) -ExpectedKind $expectedKind
        if(-not(Test-CanonicalObservedMatchesContractState -Actual $real -Contract $target.Candidate)){throw 'canonical postcondition real target differs from the reviewed candidate'}
        $rebuiltPath=Join-Path $workspace ([string]$target.RelativePath)
        $rebuilt=Get-CanonicalObservedPathState -Path $rebuiltPath -ExpectedKind $expectedKind
        if(-not(Test-CanonicalObservedMatchesContractState -Actual $rebuilt -Contract $target.Candidate)){throw 'canonical postcondition rebuild differs from the reviewed candidate'}
    }
    $unknown=@(Get-CanonicalUnknownGeneratedInventory -RepoRoot $repo)
    if((Get-SemanticJsonHash -InputObject $unknown) -cne (Get-SemanticJsonHash -InputObject @($PlanPayload.UnknownGeneratedInventory))){throw 'canonical postcondition unknown inventory changed'}
    $postHash=Get-SemanticJsonHash -InputObject ([ordered]@{Targets=@($PlanPayload.Targets|ForEach-Object{[ordered]@{Path=$_.RelativePath;Candidate=$_.Candidate}});Unknown=$unknown})
    if($postHash -cne [string]$PlanPayload.ExpectedPostconditionsHash){throw 'canonical postcondition projection hash mismatch'}
    return [pscustomobject][ordered]@{
        Workspace=$workspace
        OutputRoot=$outputRoot
        BuildResultPath=$artifactValidation.BuildResultPath
        BuildResultHash=$artifactValidation.BuildResultHash
        ScanResultPath=$artifactValidation.ScanResultPath
        ScanResultHash=$artifactValidation.ScanResultHash
        ArtifactManifestPath=$artifactValidation.ArtifactManifestPath
        ArtifactManifestHash=$artifactValidation.ArtifactManifestHash
        ArtifactValidationSummaryPath=$artifactValidation.ArtifactValidationSummaryPath
        ArtifactValidationSummaryHash=$artifactValidation.ArtifactValidationSummaryHash
        PostconditionsHash=$postHash
    }
}

function Publish-CanonicalOriginalOutcome {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [Parameter(Mandatory)][ValidateSet('committed','abandoned','failed-restored')][string]$Outcome
    )

    $state=Get-CanonicalJournalStateForAppend -TransactionNamespace $TransactionNamespace
    $projection=Get-CanonicalJournalExpectedTransactionResultProjection -Header $state.Header -Records @($state.Records) -Outcome $Outcome
    $result=[ordered]@{};foreach($name in $projection.Keys){$result[$name]=$projection[$name]};$result.Insert(7,'ResultBaseHeadHash',[string]$state.DerivedJournalHeadHash)
    $published=Publish-CanonicalTransactionResult -TransactionNamespace $TransactionNamespace -Document $result
    $null=Add-CanonicalJournalRecord -TransactionNamespace $TransactionNamespace -Phase COMPLETE -Data ([ordered]@{
        ResultHash=[string]$published.Hash;OriginalDocumentHash=[string]$state.Header.OriginalDocumentHash;Outcome=$Outcome
        ClosingKind='original';ClosingDocumentHash=[string]$state.Header.OriginalDocumentHash
    })
    return Read-CanonicalJournalDirectory -TransactionNamespace $TransactionNamespace
}
