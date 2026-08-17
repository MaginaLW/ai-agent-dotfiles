#requires -Version 7.0

Set-StrictMode -Version Latest

. (Join-Path $PSScriptRoot 'canonical-preflight-common.ps1')

$script:CanonicalJournalSchemaRoot = Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..')).Path 'schemas'

function Get-CanonicalJournalTargetId {
    param([Parameter(Mandatory)][long]$Order,[Parameter(Mandatory)][string]$TargetKind,[Parameter(Mandatory)][string]$Role,[AllowNull()][string]$Platform,[Parameter(Mandatory)][string]$TargetPath)
    $locationKey=[IO.Path]::GetFullPath($TargetPath).ToLowerInvariant().Replace([char]92,[char]47)
    return Get-SemanticJsonHash -InputObject ([ordered]@{Domain='ai-agent-dotfiles/canonical-journal-target/v1';Order=$Order;TargetKind=$TargetKind;Role=$Role;Platform=if($Platform){$Platform}else{$null};LocationKey=$locationKey})
}

function Get-CanonicalTransactionContractPaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $GitContext)

    $gitCommonDir = [System.IO.Path]::GetFullPath([string] $GitContext.GitCommonDir)
    Assert-NoReparseExistingChain -Path $gitCommonDir
    $contractRoot = Join-Path $gitCommonDir 'ai-agent-dotfiles'
    Assert-NoReparseExistingChain -Path $contractRoot
    return [pscustomobject][ordered]@{
        ContractRoot = $contractRoot
        LockPath = Join-Path $contractRoot 'canonical.lock'
        SetupStatePath = Join-Path $contractRoot 'canonical-setup-state.json'
        TransactionsRoot = Join-Path $contractRoot 'canonical-transactions'
    }
}

function Assert-CanonicalUniqueRegularFile {
    param([Parameter(Mandatory)] [string] $Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $info = [AiAgentDotfiles.NoFollowFile]::Inspect($full)
    if ($info.IsDirectory -or $info.IsReparsePoint -or $info.LinkCount -ne 1) {
        throw "canonical contract file is not a unique regular file: $full"
    }
    if (@([AiAgentDotfiles.NoFollowFile]::GetNamedStreams($full)).Count -ne 0) {
        throw "canonical contract file has a named alternate data stream: $full"
    }
    return $info
}

function Invoke-CanonicalContractSchemaValidation {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][byte[]]$ContentBytes
    )
    $full=[System.IO.Path]::GetFullPath($Path)
    $parent=Split-Path -Parent $full
    $schemaValidation=Test-RepositoryJsonSchema -SchemaPath $SchemaPath -SchemaRoot (Split-Path -Parent $SchemaPath)
    $null=Resolve-PrivateArtifactPath -Path $full -Role EvidenceInputPath -RepoRoot $script:JsonArtifactRepoRoot -EvidenceRoots @($parent)
    return Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $schemaValidation -InstanceBytes $ContentBytes -InstancePath $full
}

function Open-CanonicalDirectoryContainmentChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [switch] $CreateMissing
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    if (-not $CreateMissing) { return Open-SafeDirectoryContainmentChain -Path $full }
    $existingPath = $null
    $handles = Open-SafeExistingDirectoryContainmentChain -Path $full -ExistingPath ([ref]$existingPath)
    try {
        $relative = [System.IO.Path]::GetRelativePath([System.IO.Path]::GetFullPath($existingPath), $full)
        if ($relative -ne '.') {
            foreach ($segment in @($relative -split '[\\/]' | Where-Object { $_ })) {
                if ($segment -in @('.', '..')) { throw "Unsafe canonical directory segment: $full" }
                $child = [AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($handles[$handles.Count - 1], $segment)
                $handles.Add($child)
            }
        }
        return ,$handles
    }
    catch {
        Close-SafeDirectoryContainmentChain -Handles $handles
        throw
    }
}

function Enter-CanonicalRepoLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $LockPath,
        [switch] $AllowCreate
    )

    $full = [System.IO.Path]::GetFullPath($LockPath)
    $parent = Split-Path -Parent $full
    $parentHandles = $null
    $heldLock = $null
    try {
        try {
            $parentHandles = Open-CanonicalDirectoryContainmentChain -Path $parent -CreateMissing:$AllowCreate
        }
        catch {
            if (-not $AllowCreate -and $_.Exception.Message -match 'missing') { throw 'canonical-lock-missing' }
            throw
        }
        $parentHandle = $parentHandles[$parentHandles.Count - 1]
        try {
            $heldLock = if ($AllowCreate) {
                [AiAgentDotfiles.NoFollowFile]::OpenOrCreateChildLockFile($parentHandle, [System.IO.Path]::GetFileName($full))
            }
            else {
                [AiAgentDotfiles.NoFollowFile]::OpenChildLockFile($parentHandle, [System.IO.Path]::GetFileName($full))
            }
        }
        catch [System.ComponentModel.Win32Exception] {
            if (-not $AllowCreate -and $_.Exception.NativeErrorCode -in @(2,3)) { throw 'canonical-lock-missing' }
            if ($_.Exception.NativeErrorCode -in @(32,33)) { throw 'operation-lock-busy' }
            throw
        }
        return [pscustomobject][ordered]@{
            Path = $full
            Stream = $heldLock.Stream
            Info = $heldLock.Info
            HeldLock = $heldLock
            ParentHandles = $parentHandles
        }
    }
    catch [System.IO.IOException] {
        if ($heldLock) { $heldLock.Dispose() }
        if ($parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
        throw 'operation-lock-busy'
    }
    catch {
        if ($heldLock) { $heldLock.Dispose() }
        if ($parentHandles) { Close-SafeDirectoryContainmentChain -Handles $parentHandles }
        throw
    }
}

function Exit-CanonicalRepoLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $LockHandle)
    if ($null -ne $LockHandle.HeldLock) { $LockHandle.HeldLock.Dispose() }
    elseif ($null -ne $LockHandle.Stream) { $LockHandle.Stream.Dispose() }
    if ($null -ne $LockHandle.ParentHandles) { Close-SafeDirectoryContainmentChain -Handles $LockHandle.ParentHandles }
}

function Read-CanonicalJsonContractFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $full = [System.IO.Path]::GetFullPath($Path)
    $parent = Split-Path -Parent $full
    $capture = Read-ExactJsonArtifactCapture -Path $full -Role EvidenceInputPath -RepoRoot $script:JsonArtifactRepoRoot -EvidenceRoots @($parent)
    $capture = Assert-ExactJsonArtifactCapture -Capture $capture
    $null = Invoke-CanonicalContractSchemaValidation -SchemaPath $SchemaPath -Path $capture.FullPath -ContentBytes $capture.Bytes
    return (Assert-ExactJsonArtifactCapture -Capture $capture).Document
}

function New-CanonicalPreparedJsonArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] $PendingParent,
        [Parameter(Mandatory)] [string] $PendingPath,
        [Parameter(Mandatory)] [string] $PendingName,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $temp = [System.IO.Path]::GetFullPath((Join-Path $PendingPath $PendingName))
    $bytes = ConvertTo-SemanticJsonBytes -InputObject $Document
    $tempHandle = $null
    try {
        try {
            $tempHandle = [AiAgentDotfiles.NoFollowFile]::CreateAndHashChildRegularFile($PendingParent, $PendingName, $bytes)
        }
        catch [System.ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -in @(80,183)) { throw "canonical pending artifact collision: $temp" }
            throw
        }
        $heldBytes = [AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($tempHandle, [long]$bytes.LongLength)
        $null = Invoke-CanonicalContractSchemaValidation -SchemaPath $SchemaPath -Path $temp -ContentBytes $heldBytes
        $documentFromHeldBytes = ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false,$true).GetString($heldBytes))
        return [pscustomobject][ordered]@{
            TempPath = $temp
            Hash = Get-SemanticJsonHash -InputObject $documentFromHeldBytes
            Sha256 = [string]$tempHandle.ReadResult.Sha256
            Identity = [string]$tempHandle.ReadResult.Identity
            Length = [long]$tempHandle.ReadResult.Length
            Document = $documentFromHeldBytes
            HeldHandle = $tempHandle
        }
    }
    catch {
        if ($tempHandle) { $tempHandle.Dispose() }
        throw
    }
}

function Publish-CanonicalPreparedJsonArtifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $PreparedArtifact,
        [Parameter(Mandatory)] $FinalParent,
        [Parameter(Mandatory)] [string] $FinalPath
    )

    $final = [System.IO.Path]::GetFullPath($FinalPath)
    $tempHandle = $PreparedArtifact.HeldHandle
    if ($null -eq $tempHandle) { throw 'canonical prepared artifact has no held regular file' }
    try {
        try {
            $publishedInfo = [AiAgentDotfiles.NoFollowFile]::RenameHeldRegularFileNoReplace($tempHandle, $FinalParent, [System.IO.Path]::GetFileName($final))
        }
        catch [System.ComponentModel.Win32Exception] {
            if ($_.Exception.NativeErrorCode -in @(80,183)) { throw "canonical journal artifact must be create-new: $final" }
            throw
        }
        if ([string]$publishedInfo.Identity -cne [string]$tempHandle.Info.Identity -or [long]$publishedInfo.Length -ne [long]$tempHandle.ReadResult.Length) {
            throw 'canonical published artifact identity differs from its held exact bytes'
        }
        return [pscustomobject][ordered]@{
            Path = $final
            Hash = [string]$PreparedArtifact.Hash
            Sha256 = [string]$PreparedArtifact.Sha256
            Identity = [string]$PreparedArtifact.Identity
            Length = [long]$PreparedArtifact.Length
            Document = $PreparedArtifact.Document
            HeldHandle = $tempHandle
        }
    }
    catch { throw }
}

function Publish-CanonicalHeldJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] $FinalParent,
        [Parameter(Mandatory)] [string] $FinalPath,
        [Parameter(Mandatory)] $PendingParent,
        [Parameter(Mandatory)] [string] $PendingPath,
        [Parameter(Mandatory)] [string] $PendingName,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $prepared = $null
    try {
        $prepared = New-CanonicalPreparedJsonArtifact -Document $Document -PendingParent $PendingParent -PendingPath $PendingPath -PendingName $PendingName -SchemaPath $SchemaPath
        return Publish-CanonicalPreparedJsonArtifact -PreparedArtifact $prepared -FinalParent $FinalParent -FinalPath $FinalPath
    }
    catch {
        if ($prepared -and $prepared.HeldHandle) { $prepared.HeldHandle.Dispose() }
        throw
    }
}

function ConvertTo-CanonicalPublishedJsonResult {
    param([Parameter(Mandatory)] $HeldPublication)
    return [pscustomobject][ordered]@{
        Path = [string]$HeldPublication.Path
        Hash = [string]$HeldPublication.Hash
        Sha256 = [string]$HeldPublication.Sha256
        Identity = [string]$HeldPublication.Identity
        Length = [long]$HeldPublication.Length
    }
}

function Write-CanonicalAtomicJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $FinalPath,
        [Parameter(Mandatory)] [string] $PendingDirectory,
        [Parameter(Mandatory)] [string] $PendingName,
        [Parameter(Mandatory)] [string] $SchemaPath
    )

    $final = [System.IO.Path]::GetFullPath($FinalPath)
    $pendingRoot = [System.IO.Path]::GetFullPath($PendingDirectory)
    $finalRoot = Split-Path -Parent $final
    $finalHandles = $null
    $pendingHandles = $null
    $publication = $null
    try {
        $finalHandles = Open-SafeDirectoryContainmentChain -Path $finalRoot
        $pendingHandles = Open-SafeDirectoryContainmentChain -Path $pendingRoot
        $finalParent = $finalHandles[$finalHandles.Count - 1]
        $pendingParent = $pendingHandles[$pendingHandles.Count - 1]
        $publication = Publish-CanonicalHeldJson -Document $Document -FinalParent $finalParent -FinalPath $final -PendingParent $pendingParent -PendingPath $pendingRoot -PendingName $PendingName -SchemaPath $SchemaPath
        return ConvertTo-CanonicalPublishedJsonResult -HeldPublication $publication
    }
    finally {
        if ($publication -and $publication.HeldHandle) { $publication.HeldHandle.Dispose() }
        if ($pendingHandles) { Close-SafeDirectoryContainmentChain -Handles $pendingHandles }
        if ($finalHandles) { Close-SafeDirectoryContainmentChain -Handles $finalHandles }
    }
}

function Compare-CanonicalJournalNames {
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Expected,
        [Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $Actual,
        [Parameter(Mandatory)] [string] $ErrorMessage
    )
    $expectedSorted=@($Expected|Sort-Object);$actualSorted=@($Actual|Sort-Object)
    if(@(Compare-Object $expectedSorted $actualSorted -CaseSensitive).Count -ne 0){throw $ErrorMessage}
}

function Close-CanonicalJournalSnapshot {
    param([AllowNull()]$Snapshot)
    if($null -eq $Snapshot){return}
    $artifactHandleValues=@($Snapshot.ArtifactHandles.Values)
    for($index=$artifactHandleValues.Count-1;$index -ge 0;$index--){
        if($artifactHandleValues[$index]){$artifactHandleValues[$index].Dispose()}
    }
    if($Snapshot.PendingHandle){$Snapshot.PendingHandle.Dispose()}
    if($Snapshot.NamespaceHandles){Close-SafeDirectoryContainmentChain -Handles $Snapshot.NamespaceHandles}
}

function Read-CanonicalHeldJsonContractFile {
    param(
        [Parameter(Mandatory)]$ParentHandle,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$DisplayPath,
        [Parameter(Mandatory)][string]$SchemaPath
    )
    $handle=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($ParentHandle,$Name)
    try{
        $bytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($handle,$script:JsonArtifactMaximumBytes)
        return [pscustomobject][ordered]@{Name=$Name;Path=$DisplayPath;SchemaPath=$SchemaPath;Bytes=$bytes;Document=$null;Handle=$handle;Sha256=[string]$handle.ReadResult.Sha256;Identity=[string]$handle.ReadResult.Identity;Length=[long]$handle.ReadResult.Length}
    }
    catch{$handle.Dispose();throw}
}

function Invoke-CanonicalJournalSchemaBatchValidation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SchemaPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Captures
    )

    if($Captures.Count -eq 0){return}
    $schemaFull=[System.IO.Path]::GetFullPath($SchemaPath)
    foreach($capture in $Captures){
        if($null -eq $capture){throw "Canonical journal schema batch capture is null: $schemaFull"}
        foreach($field in @('Path','SchemaPath','Bytes','Sha256','Identity','Length','Handle')){
            if($field -notin @($capture.PSObject.Properties.Name)){throw "Canonical journal schema batch capture is missing $field`: $schemaFull"}
        }
        $captureSchemaFull=[System.IO.Path]::GetFullPath([string]$capture.SchemaPath)
        if(-not [System.StringComparer]::OrdinalIgnoreCase.Equals($captureSchemaFull,$schemaFull)){throw "Canonical journal schema batch capture belongs to a different schema: $schemaFull"}
        $captureBytes=[byte[]]$capture.Bytes
        $captureSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($captureBytes)).ToLowerInvariant()
        if($captureSha -cne [string]$capture.Sha256 -or $captureBytes.LongLength -ne [long]$capture.Length){throw "Canonical journal schema batch capture has an inconsistent exact-byte tuple: $schemaFull"}
        $heldBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($capture.Handle,[long]$capture.Length)
        $heldSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($heldBytes)).ToLowerInvariant()
        if([string]$capture.Handle.Info.Identity -cne [string]$capture.Identity -or [string]$capture.Handle.ReadResult.Identity -cne [string]$capture.Identity -or [long]$capture.Handle.ReadResult.Length -ne [long]$capture.Length -or [string]$capture.Handle.ReadResult.Sha256 -cne [string]$capture.Sha256 -or $heldSha -cne [string]$capture.Sha256 -or -not [System.Linq.Enumerable]::SequenceEqual[byte]($heldBytes,$captureBytes)){throw "Canonical journal schema batch capture is detached from its held exact bytes: $([string]$capture.Path)"}
    }
    $schemaValidation=Test-RepositoryJsonSchema -SchemaPath $schemaFull -SchemaRoot (Split-Path -Parent $schemaFull)
    $schemaCapture=Assert-ExactJsonArtifactCapture -Capture $schemaValidation.ArtifactCapture
    $schemaCopy=$null;$instanceRootHandles=$null;$instanceDirectoryHandle=$null;$toolLease=$null
    $instanceHandles=[System.Collections.Generic.List[object]]::new()
    $instanceNames=[System.Collections.Generic.List[string]]::new()
    $instancePaths=[System.Collections.Generic.List[string]]::new()
    $instanceRoot=$null;$failure=$null;$cleanupFailure=$null
    try{
        $schemaCopy=New-HeldJsonSchemaCopy -SchemaCapture $schemaCapture
        $schemaCopyName=[System.IO.Path]::GetFileName([string]$schemaCopy.SchemaPath)
        $schemaRelativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($schemaCopy.DirectoryHandle,$schemaCopyName)
        $heldSchemaBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($schemaCopy.SchemaHandle,[long]$schemaCapture.Length)
        $heldSchemaSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($heldSchemaBytes)).ToLowerInvariant()
        if($heldSchemaSha -cne [string]$schemaCapture.Sha256 -or $heldSchemaSha -cne [string]$schemaCopy.Sha256 -or [string]$schemaCopy.SchemaHandle.Info.Identity -cne [string]$schemaCopy.SchemaHandle.ReadResult.Identity -or [string]$schemaCopy.SchemaHandle.Info.Identity -cne [string]$schemaRelativeInfo.Identity -or [long]$schemaCopy.SchemaHandle.ReadResult.Length -ne [long]$schemaCapture.Length){throw "Controlled journal schema copy differs from its held exact-byte capture: $schemaFull"}
        $tempParentPath=[System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        $tempVolumeRoot=[System.IO.Path]::GetPathRoot($tempParentPath)
        if($tempParentPath.Length -gt $tempVolumeRoot.Length){$tempParentPath=$tempParentPath.TrimEnd([char]92,[char]47)}
        $instanceRootHandles=Open-SafeDirectoryContainmentChain -Path $tempParentPath
        $instanceRootName='ai-agent-dotfiles-journal-batch-'+[Guid]::NewGuid().ToString('N')
        $instanceDirectoryHandle=[AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($instanceRootHandles[$instanceRootHandles.Count-1],$instanceRootName)
        $instanceRoot=Join-Path $tempParentPath $instanceRootName
        for($index=0;$index -lt $Captures.Count;$index++){
            $capture=$Captures[$index]
            $name=('{0:d6}-{1}.json' -f $index,[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData([byte[]]$capture.Bytes)).ToLowerInvariant().Substring(0,16))
            $held=[AiAgentDotfiles.NoFollowFile]::CreateAndSealChildRegularFile($instanceDirectoryHandle,$name,[byte[]]$capture.Bytes)
            $instanceHandles.Add($held)
            $instanceNames.Add($name)
            $relativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($instanceDirectoryHandle,$name)
            if([string]$held.Info.Identity -cne [string]$held.ReadResult.Identity -or [string]$held.Info.Identity -cne [string]$relativeInfo.Identity -or [string]$held.ReadResult.Sha256 -cne [string]$capture.Sha256 -or [long]$held.ReadResult.Length -ne [long]$capture.Length){throw 'Controlled journal instance copy differs from its held exact-byte capture.'}
            $instancePaths.Add((Join-Path $instanceRoot $name))
        }
        $toolLease=Open-PinnedToolLease -LockPath (Join-Path $script:JsonArtifactRepoRoot 'tools/schema-validator/validator.lock.json')
        $result=Invoke-PinnedJsonSchemaValidatorFiles -ToolLease $toolLease -SchemaPath $schemaCopy.SchemaPath -InstancePaths @($instancePaths)
        if([long]$result.ExitCode -ne 0){throw 'Pinned JSON Schema validator did not return PASS for the journal artifact group.'}
        $schemaRelativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($schemaCopy.DirectoryHandle,$schemaCopyName)
        $heldSchemaBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($schemaCopy.SchemaHandle,[long]$schemaCapture.Length)
        $heldSchemaSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($heldSchemaBytes)).ToLowerInvariant()
        if([string]$schemaRelativeInfo.Identity -cne [string]$schemaCopy.SchemaHandle.Info.Identity -or $heldSchemaSha -cne [string]$schemaCapture.Sha256 -or $heldSchemaBytes.LongLength -ne [long]$schemaCapture.Length){throw "Controlled journal schema copy changed during validation: $schemaFull"}
        for($index=0;$index -lt $instanceHandles.Count;$index++){
            $held=$instanceHandles[$index];$capture=$Captures[$index]
            $relativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($instanceDirectoryHandle,$instanceNames[$index])
            $heldBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,[long]$capture.Length)
            $heldSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($heldBytes)).ToLowerInvariant()
            if([string]$relativeInfo.Identity -cne [string]$held.Info.Identity -or $heldSha -cne [string]$capture.Sha256 -or $heldBytes.LongLength -ne [long]$capture.Length){throw 'Controlled journal instance copy changed during validation.'}
            $sourceBytes=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($capture.Handle,[long]$capture.Length)
            $sourceSha=[Convert]::ToHexString([System.Security.Cryptography.SHA256]::HashData($sourceBytes)).ToLowerInvariant()
            if([string]$capture.Handle.Info.Identity -cne [string]$capture.Identity -or [string]$capture.Handle.ReadResult.Identity -cne [string]$capture.Identity -or $sourceSha -cne [string]$capture.Sha256 -or -not [System.Linq.Enumerable]::SequenceEqual[byte]($sourceBytes,[byte[]]$capture.Bytes)){throw "Canonical journal source capture changed during validation: $([string]$capture.Path)"}
        }
    }
    catch{$failure=[System.InvalidOperationException]::new(("Canonical journal schema batch validation failed for schema '{0}': {1}" -f $schemaFull,$_.Exception.Message),$_.Exception)}
    finally{
        if($toolLease){try{Close-PinnedToolLease -ToolLease $toolLease}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}}

        $instanceInventoryExact=$false;$instanceInventoryEmpty=$false;$instanceDirectoryIdentity=$null
        $instanceDeleteRows=[System.Collections.Generic.List[object]]::new()
        if($instanceDirectoryHandle){
            try{
                $instanceDirectoryIdentity=[string]$instanceDirectoryHandle.Info.Identity
                if($null-eq$instanceRootHandles -or $instanceRootHandles.Count -eq 0){throw 'Controlled journal instance directory lost its held parent chain during cleanup.'}
                $parentRelativeInfo=[AiAgentDotfiles.NoFollowFile]::InspectChild($instanceRootHandles[$instanceRootHandles.Count-1],$instanceRootName)
                if([string]$parentRelativeInfo.Identity -cne $instanceDirectoryIdentity){throw 'Controlled journal instance directory identity changed before cleanup.'}
                Compare-CanonicalJournalNames -Expected @($instanceNames) -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($instanceDirectoryHandle)) -ErrorMessage 'Controlled journal instance cleanup inventory contains an unknown or missing entry.'
                if($instanceHandles.Count -ne $instanceNames.Count){throw 'Controlled journal instance cleanup handle inventory is inconsistent.'}
                for($index=0;$index -lt $instanceHandles.Count;$index++){
                    $instanceDeleteRows.Add([pscustomobject][ordered]@{Name=[string]$instanceNames[$index];Identity=[string]$instanceHandles[$index].Info.Identity})
                }
                $instanceInventoryExact=$true
            }
            catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}
        }
        for($index=$instanceHandles.Count-1;$index -ge 0;$index--){try{$instanceHandles[$index].Dispose()}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}}
        if($instanceInventoryExact){
            for($index=$instanceDeleteRows.Count-1;$index -ge 0;$index--){
                try{
                    $row=$instanceDeleteRows[$index]
                    $deleted=[AiAgentDotfiles.NoFollowFile]::DeleteChildRegularFileIfIdentity($instanceDirectoryHandle,[string]$row.Name,[string]$row.Identity)
                    if([string]$deleted.Identity -cne [string]$row.Identity){throw 'Controlled journal instance cleanup returned a different file identity.'}
                }
                catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}
            }
            try{
                Compare-CanonicalJournalNames -Expected @() -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($instanceDirectoryHandle)) -ErrorMessage 'Controlled journal instance cleanup directory is not empty after exact leaf deletion.'
                $instanceInventoryEmpty=$true
            }
            catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}
        }
        if($instanceDirectoryHandle){try{$instanceDirectoryHandle.Dispose()}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}}
        if($instanceInventoryExact -and $instanceInventoryEmpty){
            try{
                $deletedDirectory=[AiAgentDotfiles.NoFollowFile]::DeleteChildEmptyDirectoryIfIdentity($instanceRootHandles[$instanceRootHandles.Count-1],$instanceRootName,$instanceDirectoryIdentity)
                if([string]$deletedDirectory.Identity -cne $instanceDirectoryIdentity){throw 'Controlled journal instance cleanup returned a different directory identity.'}
            }
            catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}
        }
        if($instanceRootHandles){try{Close-SafeDirectoryContainmentChain -Handles $instanceRootHandles}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}}
        if($schemaCopy){try{Close-HeldJsonSchemaCopy -SchemaCopy $schemaCopy}catch{if($null-eq$cleanupFailure){$cleanupFailure=$_}}}
    }
    if($failure){
        if($cleanupFailure){try{$failure.Data['CanonicalJournalCleanupFailure']=$cleanupFailure.Exception.Message}catch{}}
        throw $failure
    }
    if($cleanupFailure){throw $cleanupFailure}
}

function Open-CanonicalJournalSnapshot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TransactionNamespace,
        [switch]$AllowUnfinished
    )
    $namespace=[IO.Path]::GetFullPath($TransactionNamespace)
    $namespaceHandles=$null;$pendingHandle=$null;$artifactHandles=[ordered]@{}
    try{
        $namespaceHandles=Open-SafeDirectoryContainmentChain -Path $namespace
        $namespaceHandle=$namespaceHandles[$namespaceHandles.Count-1]
        $initialNames=@([AiAgentDotfiles.NoFollowFile]::GetChildNames($namespaceHandle)|Sort-Object)
        $publishedNames=[System.Collections.Generic.List[string]]::new();$recordNames=[System.Collections.Generic.List[string]]::new();$resultNames=[System.Collections.Generic.List[string]]::new()
        $headerFound=$false;$pendingFound=$false
        foreach($name in $initialNames){
            $info=[AiAgentDotfiles.NoFollowFile]::InspectChild($namespaceHandle,$name)
            if($name -ceq '_pending' -and $info.IsDirectory -and -not $info.IsReparsePoint){$pendingFound=$true;continue}
            if($info.IsDirectory -or $info.IsReparsePoint){throw 'canonical transaction namespace contains a reparse or directory entry'}
            if($name -ceq 'header.json'){$headerFound=$true;$publishedNames.Add($name);continue}
            if($name -ceq 'result.json'){$resultNames.Add($name);$publishedNames.Add($name);continue}
            if($name -cmatch '^[0-9]{6}\.json$'){$recordNames.Add($name);$publishedNames.Add($name);continue}
            throw "canonical transaction namespace contains an unknown entry: $name"
        }
        if(-not $headerFound){throw 'canonical transaction namespace is missing header.json'}
        if(-not $pendingFound){throw 'canonical transaction namespace is missing _pending'}
        if($resultNames.Count -gt 1){throw 'canonical journal result cardinality exceeds one'}
        $pendingHandle=[AiAgentDotfiles.NoFollowFile]::HoldChildDirectory($namespaceHandle,'_pending')
        $pendingNames=@([AiAgentDotfiles.NoFollowFile]::GetChildNames($pendingHandle)|Sort-Object)
        $pendingEntries=[System.Collections.Generic.List[object]]::new()
        foreach($pendingName in $pendingNames){
            if($pendingName -cnotmatch '^(?:header-[0-9a-f]{32}|record-[0-9]{6}-[0-9a-f]{32}|result-[0-9a-f]{32}|setup-(?:claim|state)-[0-9a-f]{32})\.tmp$'){throw 'canonical pending namespace contains an unknown entry'}
            $pendingFile=[AiAgentDotfiles.NoFollowFile]::OpenAndHashChildRegularFile($pendingHandle,$pendingName)
            $artifactHandles["_pending/$pendingName"]=$pendingFile
            $pendingEntries.Add([ordered]@{Name=$pendingName;Path=[IO.Path]::GetFullPath((Join-Path (Join-Path $namespace '_pending') $pendingName));Length=[long]$pendingFile.ReadResult.Length;Sha256=[string]$pendingFile.ReadResult.Sha256;Identity=[string]$pendingFile.ReadResult.Identity})
        }
        $headerCapture=Read-CanonicalHeldJsonContractFile -ParentHandle $namespaceHandle -Name 'header.json' -DisplayPath (Join-Path $namespace 'header.json') -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-header.schema.json')
        $artifactHandles['header.json']=$headerCapture.Handle
        $recordCaptures=[System.Collections.Generic.List[object]]::new()
        foreach($recordName in @($recordNames|Sort-Object)){
            $capture=Read-CanonicalHeldJsonContractFile -ParentHandle $namespaceHandle -Name $recordName -DisplayPath (Join-Path $namespace $recordName) -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-record.schema.json')
            $artifactHandles[$recordName]=$capture.Handle;$recordCaptures.Add($capture)
        }
        $resultCaptures=[System.Collections.Generic.List[object]]::new()
        foreach($resultName in @($resultNames)){
            $capture=Read-CanonicalHeldJsonContractFile -ParentHandle $namespaceHandle -Name $resultName -DisplayPath (Join-Path $namespace $resultName) -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-transaction-result.schema.json')
            $artifactHandles[$resultName]=$capture.Handle;$resultCaptures.Add($capture)
        }
        Invoke-CanonicalJournalSchemaBatchValidation -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-header.schema.json') -Captures @($headerCapture)
        Invoke-CanonicalJournalSchemaBatchValidation -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-record.schema.json') -Captures @($recordCaptures)
        Invoke-CanonicalJournalSchemaBatchValidation -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-transaction-result.schema.json') -Captures @($resultCaptures)
        foreach($capture in @($headerCapture)+@($recordCaptures)+@($resultCaptures)){
            $capture.Document=ConvertFrom-SemanticJson -Json ([System.Text.UTF8Encoding]::new($false,$true).GetString([byte[]]$capture.Bytes))
        }
        Compare-CanonicalJournalNames -Expected $initialNames -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($namespaceHandle)) -ErrorMessage 'manual-recovery-required: canonical transaction inventory changed during held snapshot'
        Compare-CanonicalJournalNames -Expected $pendingNames -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($pendingHandle)) -ErrorMessage 'manual-recovery-required: canonical pending inventory changed during held snapshot'
        foreach($held in @($artifactHandles.Values)){$null=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,[long]$held.ReadResult.Length)}
        $header=$headerCapture.Document
        if([string]$header.TransactionNamespace -cne $namespace){throw 'canonical header namespace mismatch'}
        $chain=Test-CanonicalJournalChain -Header $header -Records @($recordCaptures|ForEach-Object Document) -Results @($resultCaptures|ForEach-Object Document)
        if(-not $AllowUnfinished -and -not $chain.IsTerminal){throw 'canonical-recovery-required'}
        $chain|Add-Member -NotePropertyName TransactionNamespace -NotePropertyValue $namespace
        $chain|Add-Member -NotePropertyName Header -NotePropertyValue $header
        $chain|Add-Member -NotePropertyName PendingEntries -NotePropertyValue @($pendingEntries)
        return [pscustomobject][ordered]@{State=$chain;Namespace=$namespace;NamespaceHandles=$namespaceHandles;NamespaceHandle=$namespaceHandle;PendingHandle=$pendingHandle;ArtifactHandles=$artifactHandles;InitialNames=$initialNames;PendingNames=$pendingNames}
    }
    catch{
        foreach($handle in @($artifactHandles.Values)){if($handle){$handle.Dispose()}}
        if($pendingHandle){$pendingHandle.Dispose()}
        if($namespaceHandles){Close-SafeDirectoryContainmentChain -Handles $namespaceHandles}
        throw
    }
}

function Assert-CanonicalJournalSnapshotInventory {
    param([Parameter(Mandatory)]$Snapshot,[string[]]$ExpectedAddedNames=@())
    $expectedNamespace=@($Snapshot.InitialNames)+@($ExpectedAddedNames)
    Compare-CanonicalJournalNames -Expected $expectedNamespace -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($Snapshot.NamespaceHandle)) -ErrorMessage 'manual-recovery-required: canonical published inventory changed during append session'
    Compare-CanonicalJournalNames -Expected $Snapshot.PendingNames -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($Snapshot.PendingHandle)) -ErrorMessage 'manual-recovery-required: canonical pending inventory changed during append session'
    foreach($held in @($Snapshot.ArtifactHandles.Values)){$null=[AiAgentDotfiles.NoFollowFile]::ReadHeldRegularFileBytes($held,[long]$held.ReadResult.Length)}
}

function Get-CanonicalJournalStateForAppend {
    param([Parameter(Mandatory)][string]$TransactionNamespace)
    $snapshot=$null
    try{
        $snapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $TransactionNamespace -AllowUnfinished
        Assert-CanonicalJournalSnapshotInventory -Snapshot $snapshot
        return $snapshot.State
    }
    finally{if($snapshot){Close-CanonicalJournalSnapshot -Snapshot $snapshot}}
}

function New-CanonicalJournalHeader {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document,
        [Parameter(Mandatory)] [string] $TransactionNamespace
    )

    $namespace=[System.IO.Path]::GetFullPath($TransactionNamespace);$parent=Split-Path -Parent $namespace
    $namespaceHandles=$null;$pendingHandle=$null;$publication=$null
    try{
        $namespaceHandles=Open-CanonicalDirectoryContainmentChain -Path $parent -CreateMissing
        try{$namespaceHandle=[AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($namespaceHandles[$namespaceHandles.Count-1],[IO.Path]::GetFileName($namespace))}
        catch [System.ComponentModel.Win32Exception]{if($_.Exception.NativeErrorCode -in @(80,183)){throw "canonical transaction namespace must be create-new: $namespace"};throw}
        $namespaceHandles.Add($namespaceHandle)
        $pendingHandle=[AiAgentDotfiles.NoFollowFile]::CreateChildDirectory($namespaceHandle,'_pending')
        $publication=Publish-CanonicalHeldJson -Document $Document -FinalParent $namespaceHandle -FinalPath (Join-Path $namespace 'header.json') -PendingParent $pendingHandle -PendingPath (Join-Path $namespace '_pending') -PendingName ("header-{0}.tmp" -f [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-header.schema.json')
        Compare-CanonicalJournalNames -Expected @('_pending','header.json') -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($namespaceHandle)) -ErrorMessage 'manual-recovery-required: new canonical journal inventory is unstable'
        Compare-CanonicalJournalNames -Expected @() -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($pendingHandle)) -ErrorMessage 'manual-recovery-required: new canonical pending inventory is unstable'
        return ConvertTo-CanonicalPublishedJsonResult -HeldPublication $publication
    }
    finally{
        if($publication -and $publication.HeldHandle){$publication.HeldHandle.Dispose()}
        if($pendingHandle){$pendingHandle.Dispose()}
        if($namespaceHandles){Close-SafeDirectoryContainmentChain -Handles $namespaceHandles}
    }
}

function Add-CanonicalJournalRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionNamespace,
        [Parameter(Mandatory)] [ValidateSet(
            'WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED','PREIMAGE_COPY_INTENT',
            'PREPARED','FILE_PREPARED','DIR_CREATE_INTENT','DIR_CREATED','MOVE_OLD_INTENT','OLD_MOVED',
            'MOVE_NEW_INTENT','NEW_INSTALLED','FILE_REPLACE_INTENT','FILE_REPLACED','SETUP_CLAIM_INTENT',
            'SETUP_CLAIM_PUBLISHED','SETUP_STATE_INTENT','SETUP_STATE_PUBLISHED','POSTCONDITIONS_OK',
            'RECOVERY_ACTION_INTENT','RECOVERY_ACTION_APPLIED','COMPLETE'
        )] [string] $Phase,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Data
    )

    $snapshot=$null;$publication=$null
    try{
        $snapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $TransactionNamespace -AllowUnfinished
        $state=$snapshot.State
        if ($state.ValidationStatus -cne 'VALID') { throw 'manual-recovery-required' }
        if ($state.IsTerminal) { throw 'canonical-transaction-already-terminal' }
        $sequence = [long] $state.Records.Count + 1
        $record = [ordered]@{
        SchemaVersion=1
        ArtifactKind='canonical-journal-record'
        TransactionId=[string]$state.Header.TransactionId
        Sequence=$sequence
        PreviousHash=[string]$state.DerivedJournalHeadHash
        Phase=$Phase
        Data=$Data
        }
        Assert-CanonicalJournalRecordSemantics -Record $record
        $candidateRecords=@($state.Records)+@($record)
        $candidateResults=if($state.Result){@($state.Result)}else{@()}
        $null=Test-CanonicalJournalChain -Header $state.Header -Records $candidateRecords -Results $candidateResults
        $name = '{0:d6}.json' -f $sequence
        $publication=Publish-CanonicalHeldJson -Document $record -FinalParent $snapshot.NamespaceHandle -FinalPath (Join-Path $state.TransactionNamespace $name) -PendingParent $snapshot.PendingHandle -PendingPath (Join-Path $state.TransactionNamespace '_pending') -PendingName ("record-{0:d6}-{1}.tmp" -f $sequence,[Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-record.schema.json')
        $snapshot.ArtifactHandles[$name]=$publication.HeldHandle
        Assert-CanonicalJournalSnapshotInventory -Snapshot $snapshot -ExpectedAddedNames @($name)
        return ConvertTo-CanonicalPublishedJsonResult -HeldPublication $publication
    }
    finally{if($snapshot){Close-CanonicalJournalSnapshot -Snapshot $snapshot}elseif($publication -and $publication.HeldHandle){$publication.HeldHandle.Dispose()}}
}

function Publish-CanonicalTransactionResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionNamespace,
        [Parameter(Mandatory)] [System.Collections.IDictionary] $Document
    )

    $snapshot=$null;$publication=$null
    try{
        $snapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $TransactionNamespace -AllowUnfinished
        $state=$snapshot.State
        if ($state.ValidationStatus -cne 'VALID' -or $state.IsTerminal) { throw 'manual-recovery-required' }
        if ($state.Result) { throw 'canonical-fixed-result-already-exists' }
        if ([string]$Document.ResultScope -cne 'transaction' -or [string]$Document.TransactionId -cne [string]$state.Header.TransactionId) {
        throw 'canonical-result-transaction-mismatch'
        }
        if ([string]$Document.OriginalDocumentHash -cne [string]$state.Header.OriginalDocumentHash) {
        throw 'canonical-result-original-document-mismatch'
        }
        if ([string]$Document.ResultBaseHeadHash -cne [string]$state.DerivedJournalHeadHash) {
        throw 'canonical-result-base-head-mismatch'
        }
        $null=Test-CanonicalJournalChain -Header $state.Header -Records @($state.Records) -Results @($Document)
        $publication=Publish-CanonicalHeldJson -Document $Document -FinalParent $snapshot.NamespaceHandle -FinalPath (Join-Path $state.TransactionNamespace 'result.json') -PendingParent $snapshot.PendingHandle -PendingPath (Join-Path $state.TransactionNamespace '_pending') -PendingName ("result-{0}.tmp" -f [Guid]::NewGuid().ToString('N')) -SchemaPath (Join-Path $script:CanonicalJournalSchemaRoot 'canonical-transaction-result.schema.json')
        $snapshot.ArtifactHandles['result.json']=$publication.HeldHandle
        Assert-CanonicalJournalSnapshotInventory -Snapshot $snapshot -ExpectedAddedNames @('result.json')
        return ConvertTo-CanonicalPublishedJsonResult -HeldPublication $publication
    }
    finally{if($snapshot){Close-CanonicalJournalSnapshot -Snapshot $snapshot}elseif($publication -and $publication.HeldHandle){$publication.HeldHandle.Dispose()}}
}

function Assert-CanonicalJournalRecordSemantics {
    param([Parameter(Mandatory)] $Record)

    $data = $Record.Data
    $targetPhases = @('PREIMAGE_COPY_INTENT','PREPARED','FILE_PREPARED','DIR_CREATE_INTENT','DIR_CREATED','MOVE_OLD_INTENT','OLD_MOVED','MOVE_NEW_INTENT','NEW_INSTALLED','FILE_REPLACE_INTENT','FILE_REPLACED')
    if ([string]$Record.Phase -in $targetPhases) {
        foreach($name in @('TargetId','TargetKind','TargetPath','PreimagePath','SwapOldPath','StagedPath','TargetState','PreimageState','SwapOldState','StagedState')){
            if(-not $data.Contains($name)){throw "canonical target record is missing $name"}
        }
    }
    $targetFields=@('TargetId','TargetKind','TargetPath','PreimagePath','SwapOldPath','StagedPath','TargetState','PreimageState','SwapOldState','StagedState')
    $allowed=switch([string]$Record.Phase){
        {$_ -in $targetPhases}{if($_ -ceq 'DIR_CREATED'){@($targetFields)+@('CreatedIdentity')}else{@($targetFields)};break}
        'WORKSPACE_CREATE_INTENT'{@('WorkspacePath','WorkspaceRole','WorkspaceState');break}
        'WORKSPACE_CREATED'{@('WorkspacePath','WorkspaceRole','WorkspaceState','CreatedIdentity');break}
        'SETUP_CLAIM_INTENT'{@('ClaimHash');break}
        'SETUP_CLAIM_PUBLISHED'{@('ClaimHash');break}
        'SETUP_STATE_INTENT'{@('StateHash');break}
        'SETUP_STATE_PUBLISHED'{@('StateHash');break}
        'POSTCONDITIONS_OK'{@('PostconditionsHash');break}
        'RECOVERY_ACTION_INTENT'{@('PlanKind','DocumentHash','PriorHeadHash','ExpectedOutcome','ExpectedTerminalProjectionHash');break}
        'RECOVERY_ACTION_APPLIED'{@('Action','DocumentHash');break}
        'COMPLETE'{if($data.Contains('ClosingPlanKind')){@('ResultHash','OriginalDocumentHash','Outcome','ClosingKind','ClosingDocumentHash','ClosingPlanKind')}else{@('ResultHash','OriginalDocumentHash','Outcome','ClosingKind','ClosingDocumentHash')};break}
        default{throw "unsupported canonical journal phase: $($Record.Phase)"}
    }
    $actualNames=@($data.Keys|ForEach-Object{[string]$_}|Sort-Object)
    $allowedNames=@($allowed|Sort-Object)
    if((Get-SemanticJsonHash -InputObject $actualNames) -cne (Get-SemanticJsonHash -InputObject $allowedNames)){throw "canonical journal phase $($Record.Phase) has invalid data fields"}
    switch ([string]$Record.Phase) {
        'WORKSPACE_CREATE_INTENT' { foreach($name in @('WorkspacePath','WorkspaceRole','WorkspaceState')){if(-not $data.Contains($name)){throw "WORKSPACE_CREATE_INTENT is missing $name"}} }
        'WORKSPACE_CREATED' { foreach($name in @('WorkspacePath','WorkspaceRole','WorkspaceState','CreatedIdentity')){if(-not $data.Contains($name)){throw "WORKSPACE_CREATED is missing $name"}} }
        'POSTCONDITIONS_OK' { if (-not $data.Contains('PostconditionsHash')) { throw 'POSTCONDITIONS_OK is missing PostconditionsHash' } }
        'RECOVERY_ACTION_INTENT' {
            foreach ($name in @('PlanKind','DocumentHash','PriorHeadHash','ExpectedOutcome','ExpectedTerminalProjectionHash')) { if (-not $data.Contains($name)) { throw "RECOVERY_ACTION_INTENT is missing $name" } }
            if ([string]$data.PriorHeadHash -cne [string]$Record.PreviousHash) { throw 'recovery intent prior head mismatch' }
        }
        'RECOVERY_ACTION_APPLIED' {
            foreach($name in @('Action','DocumentHash')){if(-not $data.Contains($name)){throw "RECOVERY_ACTION_APPLIED is missing $name"}}
        }
        'COMPLETE' {
            foreach ($name in @('ResultHash','OriginalDocumentHash','Outcome','ClosingKind','ClosingDocumentHash')) { if (-not $data.Contains($name)) { throw "COMPLETE is missing $name" } }
            if ([string]$data.ClosingKind -ceq 'original') {
                if ([string]$data.ClosingDocumentHash -cne [string]$data.OriginalDocumentHash -or $data.Contains('ClosingPlanKind')) { throw 'invalid original COMPLETE closure' }
            }
            else {
                if (-not $data.Contains('ClosingPlanKind')) { throw 'recovery COMPLETE is missing ClosingPlanKind' }
            }
        }
    }
}

function Get-CanonicalJournalResultProjection {
    param([Parameter(Mandatory)]$Result)
    $projection=[ordered]@{}
    foreach($name in @('SchemaVersion','ArtifactKind','ResultScope','Result','TransactionId','CanonicalOperationKind','OriginalDocumentHash','Outcome','PlanHash','PostconditionsHash','RestorationHash','FinalStateHash','ArtifactStates')){
        if(($Result -is [Collections.IDictionary] -and $Result.Contains($name)) -or ($Result -isnot [Collections.IDictionary] -and $Result.PSObject.Properties[$name])){$projection[$name]=$Result.$name}
    }
    return $projection
}

function Get-CanonicalJournalExpectedArtifactStates {
    param(
        [Parameter(Mandatory)]$Header,
        [object[]]$Records=@(),
        [Parameter(Mandatory)][ValidateSet('committed','abandoned','rolled-back','failed-restored')][string]$Outcome
    )
    $targetHash=Get-SemanticJsonHash -InputObject @($Header.Targets|ForEach-Object{[ordered]@{TargetId=[string]$_.TargetId;Current=$_.Current;Candidate=$_.Candidate}})
    if($Outcome -ceq 'abandoned'){
        $partialPhases=@('WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED','PREIMAGE_COPY_INTENT','PREPARED','FILE_PREPARED','DIR_CREATE_INTENT','SETUP_CLAIM_INTENT')
        $status=if(@($Records|Where-Object{[string]$_.Phase -in $partialPhases}).Count -eq 0){'MISSING'}else{'PARTIAL'}
        return @([ordered]@{Name='targets';Status=$status})
    }
    return @([ordered]@{Name='targets';Status='COMPLETE';Hash=$targetHash})
}

function Get-CanonicalJournalExpectedTransactionResultProjection {
    param(
        [Parameter(Mandatory)]$Header,
        [object[]]$Records=@(),
        [string]$SetupFinalStateHash,
        [Parameter(Mandatory)][ValidateSet('committed','abandoned','rolled-back','failed-restored')][string]$Outcome
    )
    $projection=[ordered]@{
        SchemaVersion=1;ArtifactKind='canonical-transaction-result';ResultScope='transaction'
        Result=if($Outcome -ceq 'failed-restored'){'FAIL'}else{'PASS'}
        TransactionId=[string]$Header.TransactionId;CanonicalOperationKind=[string]$Header.CanonicalOperationKind
        OriginalDocumentHash=[string]$Header.OriginalDocumentHash;Outcome=$Outcome
    }
    switch($Outcome){
        'committed'{
            $projection.PlanHash=[string]$Header.OriginalPlanHash
            $projection.PostconditionsHash=[string]$Header.ExpectedPostconditionsHash
            if([string]$Header.CanonicalOperationKind -ceq 'setup'){
                $published=@($Records|Where-Object{[string]$_.Phase -ceq 'SETUP_STATE_PUBLISHED'})
                if($published.Count -eq 1){$projection.FinalStateHash=[string]$published[0].Data.StateHash}
                elseif($SetupFinalStateHash){$projection.FinalStateHash=$SetupFinalStateHash}
                else{throw 'committed setup fixed result requires one published setup state'}
            }
            break
        }
        {$_ -in @('rolled-back','failed-restored')} {
            $restoration=[ordered]@{TransactionId=[string]$Header.TransactionId;Targets=@($Header.Targets|ForEach-Object{[ordered]@{TargetId=[string]$_.TargetId;Current=$_.Current}})}
            $projection.RestorationHash=Get-SemanticJsonHash -InputObject $restoration
            $projection.FinalStateHash=[string]$projection.RestorationHash
            break
        }
    }
    $projection.ArtifactStates=@(Get-CanonicalJournalExpectedArtifactStates -Header $Header -Records $Records -Outcome $Outcome)
    return $projection
}

function Test-CanonicalJournalObservedMissing {
    param([Parameter(Mandatory)]$Observed)
    return [string]$Observed.State -ceq 'MISSING'
}

function Get-CanonicalJournalEmptyDirectoryHash {
    return Get-SemanticJsonHash -InputObject @([ordered]@{Type='Directory';RelativePath=''})
}

function Assert-CanonicalJournalObservedMatchesContract {
    param(
        [Parameter(Mandatory)]$Observed,
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)][ValidateSet('File','Directory')][string]$ExpectedType,
        [Parameter(Mandatory)][string]$Label
    )
    if ([string]$Observed.State -cne [string]$Contract.State) { throw "$Label state differs from its reviewed contract" }
    if ([string]$Contract.State -ceq 'MISSING') { return }
    if ([string]$Observed.Type -cne $ExpectedType -or [string]$Observed.Hash -cne [string]$Contract.Hash) {
        throw "$Label differs from its reviewed contract"
    }
}

function Assert-CanonicalJournalObservedEqual {
    param(
        [Parameter(Mandatory)]$Actual,
        [Parameter(Mandatory)]$Expected,
        [Parameter(Mandatory)][string]$Label
    )
    if ((Get-SemanticJsonHash -InputObject $Actual) -cne (Get-SemanticJsonHash -InputObject $Expected)) {
        throw "$Label tuple differs from its preceding durable phase"
    }
}

function Assert-CanonicalJournalTargetTupleSemantics {
    param(
        [Parameter(Mandatory)]$Record,
        [Parameter(Mandatory)]$Target,
        $PriorRecord
    )
    $phase=[string]$Record.Phase
    $data=$Record.Data
    $kind=[string]$Target.TargetKind
    $expectedType=if($kind -ceq 'file'){'File'}else{'Directory'}
    $missing=@('PreimageState','SwapOldState','StagedState')

    switch($phase){
        'PREIMAGE_COPY_INTENT' {
            Assert-CanonicalJournalObservedMatchesContract -Observed $data.TargetState -Contract $Target.Current -ExpectedType $expectedType -Label 'PREIMAGE_COPY_INTENT target differs from header Current'
            Assert-CanonicalJournalObservedMatchesContract -Observed $data.StagedState -Contract $Target.Candidate -ExpectedType $expectedType -Label 'PREIMAGE_COPY_INTENT staged candidate differs from header Candidate'
            foreach($name in @('PreimageState','SwapOldState')){if(-not(Test-CanonicalJournalObservedMissing $data.$name)){throw "PREIMAGE_COPY_INTENT $name must be MISSING"}}
            break
        }
        {$_ -in @('PREPARED','FILE_PREPARED')} {
            foreach($name in @('TargetState','SwapOldState','StagedState')){Assert-CanonicalJournalObservedEqual -Actual $data.$name -Expected $PriorRecord.Data.$name -Label "$phase $name"}
            if([string]$Target.Current.State -ceq 'MISSING'){
                if(-not(Test-CanonicalJournalObservedMissing $data.PreimageState)){throw "$phase PreimageState must be MISSING for a MISSING current target"}
            }else{
                Assert-CanonicalJournalObservedMatchesContract -Observed $data.PreimageState -Contract $Target.Current -ExpectedType $expectedType -Label "$phase immutable preimage"
            }
            break
        }
        'DIR_CREATE_INTENT' {
            foreach($name in @('TargetState','PreimageState','SwapOldState','StagedState')){if(-not(Test-CanonicalJournalObservedMissing $data.$name)){throw "DIR_CREATE_INTENT $name must be MISSING"}}
            break
        }
        'DIR_CREATED' {
            if([string]$data.TargetState.State -cne 'PRESENT' -or [string]$data.TargetState.Type -cne 'Directory'){throw 'DIR_CREATED TargetState must be a PRESENT Directory'}
            if([string]$data.CreatedIdentity -cne [string]$data.TargetState.Identity){throw 'DIR_CREATED CreatedIdentity differs from TargetState identity'}
            Assert-CanonicalJournalObservedMatchesContract -Observed $data.TargetState -Contract $Target.Candidate -ExpectedType Directory -Label 'DIR_CREATED target'
            foreach($name in @('PreimageState','SwapOldState','StagedState')){if(-not(Test-CanonicalJournalObservedMissing $data.$name)){throw "DIR_CREATED $name must be MISSING"}}
            break
        }
        {$_ -in @('MOVE_OLD_INTENT','FILE_REPLACE_INTENT')} {
            foreach($name in @('TargetState','PreimageState','SwapOldState','StagedState')){Assert-CanonicalJournalObservedEqual -Actual $data.$name -Expected $PriorRecord.Data.$name -Label "$phase $name"}
            break
        }
        'OLD_MOVED' {
            if(-not(Test-CanonicalJournalObservedMissing $data.TargetState)){throw 'OLD_MOVED TargetState must be MISSING'}
            foreach($name in @('PreimageState','StagedState')){Assert-CanonicalJournalObservedEqual -Actual $data.$name -Expected $PriorRecord.Data.$name -Label "OLD_MOVED $name"}
            if([string]$Target.Current.State -ceq 'MISSING'){
                if(-not(Test-CanonicalJournalObservedMissing $data.SwapOldState)){throw 'OLD_MOVED SwapOldState must be MISSING for a MISSING current target'}
            }else{
                Assert-CanonicalJournalObservedEqual -Actual $data.SwapOldState -Expected $PriorRecord.Data.TargetState -Label 'OLD_MOVED swap-old'
            }
            break
        }
        'MOVE_NEW_INTENT' {
            foreach($name in @('TargetState','PreimageState','SwapOldState','StagedState')){Assert-CanonicalJournalObservedEqual -Actual $data.$name -Expected $PriorRecord.Data.$name -Label "MOVE_NEW_INTENT $name"}
            break
        }
        'NEW_INSTALLED' {
            Assert-CanonicalJournalObservedEqual -Actual $data.TargetState -Expected $PriorRecord.Data.StagedState -Label 'NEW_INSTALLED target'
            foreach($name in @('PreimageState','SwapOldState')){Assert-CanonicalJournalObservedEqual -Actual $data.$name -Expected $PriorRecord.Data.$name -Label "NEW_INSTALLED $name"}
            if(-not(Test-CanonicalJournalObservedMissing $data.StagedState)){throw 'NEW_INSTALLED StagedState must be MISSING'}
            break
        }
        'FILE_REPLACED' {
            Assert-CanonicalJournalObservedMatchesContract -Observed $data.TargetState -Contract $Target.Candidate -ExpectedType File -Label 'FILE_REPLACED target'
            Assert-CanonicalJournalObservedEqual -Actual $data.PreimageState -Expected $PriorRecord.Data.PreimageState -Label 'FILE_REPLACED PreimageState'
            if([string]$Target.Current.State -ceq 'MISSING'){
                if(-not(Test-CanonicalJournalObservedMissing $data.SwapOldState)){throw 'FILE_REPLACED SwapOldState must be MISSING for a MISSING current target'}
            }else{
                Assert-CanonicalJournalObservedMatchesContract -Observed $data.SwapOldState -Contract $Target.Current -ExpectedType File -Label 'FILE_REPLACED swap-old'
            }
            if(-not(Test-CanonicalJournalObservedMissing $data.StagedState)){throw 'FILE_REPLACED StagedState must be MISSING'}
            break
        }
    }
}

function Test-CanonicalJournalChain {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Header,
        [object[]] $Records = @(),
        [object[]] $Results = @()
    )

    $resultArray=@($Results | Where-Object { $null -ne $_ })
    if ($resultArray.Count -gt 1) { throw 'canonical journal result cardinality exceeds one' }
    if([string]$Header.CanonicalOperationKind -ceq 'setup'){
        $setup=$Header.SetupRecovery
        if([string]$setup.ExpectedClaimHash -cne (Get-SemanticJsonHash -InputObject $setup.ExpectedClaim) -or [string]$setup.ExpectedStateProjectionHash -cne (Get-SemanticJsonHash -InputObject $setup.ExpectedStateProjection)){
            throw 'canonical setup journal header expected object hash mismatch'
        }
        if([string]$setup.ExpectedClaim.ExpectedSetupStateProjectionHash -cne [string]$setup.ExpectedStateProjectionHash){throw 'canonical setup journal claim/state projection link mismatch'}
    }
    $targetIds=@($Header.Targets|ForEach-Object{[string]$_.TargetId})
    if(@($targetIds|Sort-Object -Unique).Count -ne $targetIds.Count){throw 'canonical journal header has duplicate TargetId'}
    $targetPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($target in @($Header.Targets)){if(-not $targetPaths.Add([IO.Path]::GetFullPath([string]$target.TargetPath))){throw 'canonical journal header has duplicate TargetPath'}}
    $orders=@($Header.Targets|ForEach-Object{[long]$_.Order}|Sort-Object)
    for($i=0;$i -lt $orders.Count;$i++){if($orders[$i] -ne $i){throw 'canonical journal header target order is not contiguous'}}
    foreach($target in @($Header.Targets)){
        $platform=if(($target -is [Collections.IDictionary] -and $target.Contains('Platform')) -or ($target -isnot [Collections.IDictionary] -and $target.PSObject.Properties['Platform'])){[string]$target.Platform}else{$null}
        $expectedTargetId=Get-CanonicalJournalTargetId -Order ([long]$target.Order) -TargetKind ([string]$target.TargetKind) -Role ([string]$target.Role) -Platform $platform -TargetPath ([string]$target.TargetPath)
        if([string]$target.TargetId -cne $expectedTargetId){throw 'canonical journal header TargetId differs from its canonical locator projection'}
    }
    $headerHash = Get-SemanticJsonHash -InputObject $Header
    $previous = $headerHash
    $hashes = [System.Collections.Generic.List[string]]::new()
    $hashes.Add($headerHash)
    $ordered = @($Records | Sort-Object { [long]$_.Sequence })
    $completeCount = 0
    $recoveryIntentByDocument=@{}
    $targetById=@{};foreach($target in @($Header.Targets)){$targetById[[string]$target.TargetId]=$target}
    $targetPhaseById=@{};$targetRecordById=@{};foreach($target in @($Header.Targets)){$targetPhaseById[[string]$target.TargetId]=$null;$targetRecordById[[string]$target.TargetId]=$null}
    $workspacePhase=@{'preimage'=$null;'swap-old'=$null}
    $recoveryStarted=$false
    $setupPhase=''
    for ($index=0; $index -lt $ordered.Count; $index++) {
        $record = $ordered[$index]
        $expected = $index + 1
        if ([long]$record.Sequence -ne $expected) { throw 'canonical journal published record gap or duplicate' }
        if ([string]$record.TransactionId -cne [string]$Header.TransactionId) { throw 'canonical journal record TransactionId mismatch' }
        if ([string]$record.PreviousHash -cne $previous) { throw 'canonical journal hash chain break' }
        Assert-CanonicalJournalRecordSemantics -Record $record
        $phase=[string]$record.Phase
        if($phase -in @('RECOVERY_ACTION_INTENT','RECOVERY_ACTION_APPLIED','COMPLETE')){$recoveryStarted=$true}
        elseif($recoveryStarted -and $phase -notin @('SETUP_CLAIM_PUBLISHED','SETUP_STATE_INTENT','SETUP_STATE_PUBLISHED')){throw 'canonical journal contains original-operation work after recovery began'}
        if($phase -in @('SETUP_CLAIM_INTENT','SETUP_CLAIM_PUBLISHED','SETUP_STATE_INTENT','SETUP_STATE_PUBLISHED')){
            if([string]$Header.CanonicalOperationKind -cne 'setup'){throw 'canonical setup publication phase appears in a non-setup transaction'}
            $allowedNext=switch($phase){
                'SETUP_CLAIM_INTENT'{@('');break}
                'SETUP_CLAIM_PUBLISHED'{@('SETUP_CLAIM_INTENT');break}
                'SETUP_STATE_INTENT'{@('','SETUP_CLAIM_PUBLISHED');break}
                'SETUP_STATE_PUBLISHED'{@('SETUP_STATE_INTENT');break}
            }
            if($setupPhase -notin $allowedNext){throw 'canonical setup claim/state phase order is invalid'}
            if($phase -in @('SETUP_CLAIM_INTENT','SETUP_CLAIM_PUBLISHED') -and [string]$record.Data.ClaimHash -cne [string]$Header.SetupRecovery.ExpectedClaimHash){throw 'canonical setup claim record hash differs from header'}
            if($phase -ceq 'SETUP_CLAIM_PUBLISHED'){
                $priorSetup=@($ordered|Where-Object{[long]$_.Sequence -lt [long]$record.Sequence -and [string]$_.Phase -ceq 'SETUP_CLAIM_INTENT'}|Select-Object -Last 1)
                if($priorSetup.Count -ne 1 -or [string]$record.Data.ClaimHash -cne [string]$priorSetup[0].Data.ClaimHash){throw 'canonical setup published claim differs from its intent'}
            }
            if($phase -ceq 'SETUP_STATE_PUBLISHED'){
                $priorSetup=@($ordered|Where-Object{[long]$_.Sequence -lt [long]$record.Sequence -and [string]$_.Phase -ceq 'SETUP_STATE_INTENT'}|Select-Object -Last 1)
                if($priorSetup.Count -ne 1 -or [string]$record.Data.StateHash -cne [string]$priorSetup[0].Data.StateHash){throw 'canonical setup published state differs from its intent'}
            }
            $setupPhase=$phase
        }
        if($phase -in @('WORKSPACE_CREATE_INTENT','WORKSPACE_CREATED')){
            $role=[string]$record.Data.WorkspaceRole;$prior=[string]$workspacePhase[$role]
            $expected=if($phase -ceq 'WORKSPACE_CREATE_INTENT'){''}else{'WORKSPACE_CREATE_INTENT'}
            if($prior -cne $expected){throw "canonical workspace phase order is invalid for $role"}
            $expectedPath=[IO.Path]::GetFullPath((Join-Path ([string]$Header.RecoveryTransactionRoot) $role))
            if([string]$record.Data.WorkspacePath -cne $expectedPath){throw "canonical workspace record path differs from header recovery root for $role"}
            if($phase -ceq 'WORKSPACE_CREATE_INTENT' -and -not(Test-CanonicalJournalObservedMissing $record.Data.WorkspaceState)){throw 'WORKSPACE_CREATE_INTENT WorkspaceState must be MISSING'}
            if($phase -ceq 'WORKSPACE_CREATED'){
                if([string]$record.Data.WorkspaceState.State -cne 'PRESENT' -or [string]$record.Data.WorkspaceState.Type -cne 'Directory'){throw 'WORKSPACE_CREATED WorkspaceState must be a PRESENT Directory'}
                if([string]$record.Data.CreatedIdentity -cne [string]$record.Data.WorkspaceState.Identity){throw 'WORKSPACE_CREATED CreatedIdentity differs from WorkspaceState identity'}
                if([string]$record.Data.WorkspaceState.Hash -cne (Get-CanonicalJournalEmptyDirectoryHash)){throw 'WORKSPACE_CREATED WorkspaceState must bind the canonical empty-directory content hash'}
            }
            $workspacePhase[$role]=$phase
        }
        if($phase -in @('PREIMAGE_COPY_INTENT','PREPARED','FILE_PREPARED','DIR_CREATE_INTENT','DIR_CREATED','MOVE_OLD_INTENT','OLD_MOVED','MOVE_NEW_INTENT','NEW_INSTALLED','FILE_REPLACE_INTENT','FILE_REPLACED')){
            $id=[string]$record.Data.TargetId
            if(-not $targetById.ContainsKey($id)){throw 'canonical target record references an unknown header TargetId'}
            $target=$targetById[$id]
            foreach($name in @('TargetId','TargetKind','TargetPath','PreimagePath','SwapOldPath','StagedPath')){
                $left=$record.Data.$name;$right=$target.$name
                if($null -eq $left -or $null -eq $right){if($null -ne $left -or $null -ne $right){throw "canonical target record $name differs from header target"}}
                elseif([string]$left -cne [string]$right){throw "canonical target record $name differs from header target"}
            }
            $kind=[string]$target.TargetKind
            $sequence=if($kind -ceq 'file'){@('PREIMAGE_COPY_INTENT','FILE_PREPARED','FILE_REPLACE_INTENT','FILE_REPLACED')}elseif($kind -ceq 'directory'){@('PREIMAGE_COPY_INTENT','PREPARED','MOVE_OLD_INTENT','OLD_MOVED','MOVE_NEW_INTENT','NEW_INSTALLED')}else{@('DIR_CREATE_INTENT','DIR_CREATED')}
            $prior=[string]$targetPhaseById[$id];$phaseIndex=if([string]::IsNullOrEmpty($prior)){-1}else{[Array]::IndexOf($sequence,$prior)}
            if($phaseIndex+1 -ge $sequence.Count -or [string]$sequence[$phaseIndex+1] -cne $phase){throw "canonical target phase order is invalid for $id"}
            if($phase -ceq 'PREIMAGE_COPY_INTENT' -and (@($workspacePhase.Values|Where-Object{[string]$_ -cne 'WORKSPACE_CREATED'}).Count -gt 0)){throw 'canonical preimage intent precedes durable workspace creation'}
            Assert-CanonicalJournalTargetTupleSemantics -Record $record -Target $target -PriorRecord $targetRecordById[$id]
            $targetPhaseById[$id]=$phase
            $targetRecordById[$id]=$record
        }
        if($phase -ceq 'POSTCONDITIONS_OK'){
            if([string]$record.Data.PostconditionsHash -cne [string]$Header.ExpectedPostconditionsHash){throw 'canonical POSTCONDITIONS_OK hash differs from header'}
            foreach($target in @($Header.Targets)){
                $required=if([string]$target.TargetKind -ceq 'file'){'FILE_REPLACED'}elseif([string]$target.TargetKind -ceq 'directory'){'NEW_INSTALLED'}else{'DIR_CREATED'}
                if([string]$targetPhaseById[[string]$target.TargetId] -cne $required){throw 'canonical POSTCONDITIONS_OK precedes completion of every target'}
            }
        }
        $previous = Get-SemanticJsonHash -InputObject $record
        $hashes.Add($previous)
        if ([string]$record.Phase -ceq 'COMPLETE') {
            $completeCount++
            if ($index -ne $ordered.Count-1) { throw 'canonical COMPLETE must be the final published record' }
        }
        elseif([string]$record.Phase -ceq 'RECOVERY_ACTION_INTENT'){
            $documentHash=[string]$record.Data.DocumentHash
            if($recoveryIntentByDocument.ContainsKey($documentHash)){throw 'canonical journal repeats a recovery intent DocumentHash'}
            $recoveryIntentByDocument[$documentHash]=[string]$record.Data.PlanKind
        }
        elseif([string]$record.Phase -ceq 'RECOVERY_ACTION_APPLIED'){
            $documentHash=[string]$record.Data.DocumentHash
            if(-not $recoveryIntentByDocument.ContainsKey($documentHash)){throw 'canonical recovery action has no prior intent'}
        }
    }
    if ($completeCount -gt 1) { throw 'canonical journal has duplicate COMPLETE records' }

    $result = if ($resultArray.Count -eq 1) { $resultArray[0] } else { $null }
    if ($result) {
        if ([string]$result.ResultScope -cne 'transaction' -or [string]$result.TransactionId -cne [string]$Header.TransactionId) { throw 'canonical fixed result scope mismatch' }
        if ([string]$result.CanonicalOperationKind -cne [string]$Header.CanonicalOperationKind) { throw 'canonical fixed result operation mismatch' }
        if ([string]$result.OriginalDocumentHash -cne [string]$Header.OriginalDocumentHash) { throw 'canonical fixed result original document mismatch' }
        $baseIndex = $hashes.IndexOf([string]$result.ResultBaseHeadHash)
        if ($baseIndex -lt 0) { throw 'canonical fixed result base head is not a chain ancestor' }
        $baseRecords=@($ordered|Where-Object{[long]$_.Sequence -le $baseIndex})
        $outcome=[string]$result.Outcome
        if($outcome -ceq 'committed'){
            if([string]$Header.CanonicalOperationKind -ceq 'setup'){
                if(@($baseRecords|Where-Object{[string]$_.Phase -ceq 'SETUP_STATE_PUBLISHED'}).Count -ne 1){throw 'committed setup fixed result precedes the published setup state'}
            }else{
                if(@($baseRecords|Where-Object{[string]$_.Phase -ceq 'POSTCONDITIONS_OK'}).Count -ne 1){throw 'committed fixed result precedes durable postconditions'}
            }
        }elseif($outcome -ceq 'abandoned' -and @($baseRecords|Where-Object{[string]$_.Phase -in @('DIR_CREATED','NEW_INSTALLED','FILE_REPLACED') -or ([string]$_.Phase -ceq 'OLD_MOVED' -and [string]$_.Data.SwapOldState.State -ceq 'PRESENT')}).Count -gt 0){
            throw 'abandoned fixed result follows a target primitive'
        }
        $actualProjection=Get-CanonicalJournalResultProjection -Result $result
        $expectedProjection=Get-CanonicalJournalExpectedTransactionResultProjection -Header $Header -Records $baseRecords -Outcome $outcome
        if((Get-SemanticJsonHash -InputObject $actualProjection) -cne (Get-SemanticJsonHash -InputObject $expectedProjection)){
            throw 'canonical fixed result semantic projection differs from its header and durable records'
        }
        $bindingIntent=@($ordered|Where-Object{[long]$_.Sequence -le $baseIndex -and [string]$_.Phase -ceq 'RECOVERY_ACTION_INTENT'}|Select-Object -Last 1)
        if($bindingIntent.Count -eq 1){
            $projectionHash=Get-SemanticJsonHash -InputObject (Get-CanonicalJournalResultProjection -Result $result)
            if([string]$bindingIntent[0].Data.ExpectedTerminalProjectionHash -cne $projectionHash -or [string]$bindingIntent[0].Data.ExpectedOutcome -cne [string]$result.Outcome){throw 'recovery intent projection differs from fixed result'}
            foreach($ancestorIntent in @($ordered|Where-Object{[long]$_.Sequence -le $baseIndex -and [string]$_.Phase -ceq 'RECOVERY_ACTION_INTENT'})){
                if([string]$ancestorIntent.Data.ExpectedTerminalProjectionHash -cne $projectionHash -or [string]$ancestorIntent.Data.ExpectedOutcome -cne [string]$result.Outcome){throw 'recovery intent ancestry projection differs from fixed result'}
            }
        }
        for ($index=$baseIndex; $index -lt $ordered.Count; $index++) {
            if ([string]$ordered[$index].Phase -notin @('RECOVERY_ACTION_INTENT','RECOVERY_ACTION_APPLIED','COMPLETE')) {
                throw 'canonical journal contains a non-closing record after the fixed result base head'
            }
        }
    }

    $terminal = if ($completeCount -eq 1) { $ordered[-1] } else { $null }
    if ($terminal) {
        if (-not $result) { throw 'canonical COMPLETE exists without fixed result' }
        $data = $terminal.Data
        $resultHash = Get-SemanticJsonHash -InputObject $result
        if ([string]$data.ResultHash -cne $resultHash -or [string]$data.OriginalDocumentHash -cne [string]$Header.OriginalDocumentHash -or [string]$data.Outcome -cne [string]$result.Outcome) {
            throw 'canonical COMPLETE/result mismatch'
        }
        if ([string]$data.ClosingKind -ceq 'recovery') {
            $matching = @($ordered | Where-Object {
                [string]$_.Phase -ceq 'RECOVERY_ACTION_INTENT' -and
                [string]$_.Data.DocumentHash -ceq [string]$data.ClosingDocumentHash -and
                [string]$_.Data.PlanKind -ceq [string]$data.ClosingPlanKind
            })
            if ($matching.Count -eq 0) { throw 'recovery COMPLETE has no matching recovery intent' }
            $projectionHash=Get-SemanticJsonHash -InputObject (Get-CanonicalJournalResultProjection -Result $result)
            if(@($matching|Where-Object{[string]$_.Data.ExpectedTerminalProjectionHash -ceq $projectionHash -and [string]$_.Data.ExpectedOutcome -ceq [string]$result.Outcome}).Count -ne $matching.Count){throw 'recovery COMPLETE intent projection differs from fixed result'}
        }
    }

    $consumed = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $null = $consumed.Add([string]$Header.OriginalDocumentHash)
    foreach ($record in $ordered) {
        if ([string]$record.Phase -ceq 'RECOVERY_ACTION_INTENT') { $null = $consumed.Add([string]$record.Data.DocumentHash) }
    }
    if ($terminal) { $null = $consumed.Add([string]$terminal.Data.ClosingDocumentHash) }
    return [pscustomobject][ordered]@{
        ValidationStatus='VALID'
        HeaderHash=$headerHash
        DerivedJournalHeadHash=$previous
        Records=$ordered
        Result=$result
        ResultHash=if($result){Get-SemanticJsonHash -InputObject $result}else{$null}
        IsTerminal=[bool]$terminal
        Outcome=if($terminal){[string]$terminal.Data.Outcome}else{$null}
        ConsumedDocumentHashes=@($consumed | Sort-Object)
    }
}

function Read-CanonicalJournalDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionNamespace,
        [switch] $AllowUnfinished
    )

    $snapshot=$null
    try{
        $snapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $TransactionNamespace -AllowUnfinished:$AllowUnfinished
        Assert-CanonicalJournalSnapshotInventory -Snapshot $snapshot
        return $snapshot.State
    }
    finally{if($snapshot){Close-CanonicalJournalSnapshot -Snapshot $snapshot}}
}

function Get-CanonicalAllTransactionStates {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TransactionsRoot)

    $root=[System.IO.Path]::GetFullPath($TransactionsRoot)
    $rootHandles=$null
    $worktreeLeases=[System.Collections.Generic.List[object]]::new()
    $states=[System.Collections.Generic.List[object]]::new()
    try{
        $existingPath=$null
        $rootHandles=Open-SafeExistingDirectoryContainmentChain -Path $root -ExistingPath ([ref]$existingPath)
        if(-not [string]::Equals([System.IO.Path]::GetFullPath([string]$existingPath).TrimEnd([char]92,[char]47),$root.TrimEnd([char]92,[char]47),[System.StringComparison]::OrdinalIgnoreCase)){
            return @()
        }
        $rootHandle=$rootHandles[$rootHandles.Count-1]
        $rootNames=@([AiAgentDotfiles.NoFollowFile]::GetChildNames($rootHandle)|Sort-Object)
        foreach($worktreeName in $rootNames){
            if($worktreeName -cnotmatch '^[0-9a-f]{64}$'){throw 'canonical transactions root contains an unknown worktree namespace'}
            $worktreeHandle=$null
            try{$worktreeHandle=[AiAgentDotfiles.NoFollowFile]::TryHoldPathChildDirectory($rootHandle,$worktreeName)}
            catch{throw 'canonical transactions root contains an unknown worktree namespace'}
            if($null -eq $worktreeHandle){throw 'manual-recovery-required: canonical transactions root inventory changed during held scan'}
            $worktreeLease=[pscustomobject][ordered]@{Name=$worktreeName;Handle=$worktreeHandle;InitialNames=@();TransactionLeases=[System.Collections.Generic.List[object]]::new()}
            $worktreeLeases.Add($worktreeLease);$worktreeHandle=$null
            $transactionNames=@([AiAgentDotfiles.NoFollowFile]::GetChildNames($worktreeLease.Handle)|Sort-Object)
            $worktreeLease.InitialNames=$transactionNames
            foreach($transactionName in $transactionNames){
                if($transactionName -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'){throw 'canonical worktree namespace contains an unknown transaction entry'}
                $transactionHandle=$null;$snapshot=$null
                try{
                    try{$transactionHandle=[AiAgentDotfiles.NoFollowFile]::TryHoldPathChildDirectory($worktreeLease.Handle,$transactionName)}
                    catch{throw 'canonical worktree namespace contains an unknown transaction entry'}
                    if($null -eq $transactionHandle){throw 'manual-recovery-required: canonical worktree inventory changed during held scan'}
                    $transactionPath=[System.IO.Path]::GetFullPath((Join-Path (Join-Path $root $worktreeName) $transactionName))
                    $snapshot=Open-CanonicalJournalSnapshot -TransactionNamespace $transactionPath -AllowUnfinished
                    if([string]$snapshot.NamespaceHandle.Info.Identity -cne [string]$transactionHandle.Info.Identity){throw 'manual-recovery-required: canonical transaction identity changed during held scan'}
                    if([string]$snapshot.State.Header.WorktreeId -cne $worktreeName -or [string]$snapshot.State.Header.TransactionId -cne $transactionName){throw 'canonical transaction locator/header mismatch'}
                    $worktreeLease.TransactionLeases.Add([pscustomobject][ordered]@{Name=$transactionName;Handle=$transactionHandle;Snapshot=$snapshot})
                    $states.Add($snapshot.State);$transactionHandle=$null;$snapshot=$null
                }
                finally{
                    if($snapshot){Close-CanonicalJournalSnapshot -Snapshot $snapshot}
                    if($transactionHandle){$transactionHandle.Dispose()}
                }
            }
        }
        foreach($worktreeLease in $worktreeLeases){
            foreach($transactionLease in $worktreeLease.TransactionLeases){Assert-CanonicalJournalSnapshotInventory -Snapshot $transactionLease.Snapshot}
            Compare-CanonicalJournalNames -Expected $worktreeLease.InitialNames -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($worktreeLease.Handle)) -ErrorMessage 'manual-recovery-required: canonical worktree inventory changed during held scan'
        }
        Compare-CanonicalJournalNames -Expected $rootNames -Actual @([AiAgentDotfiles.NoFollowFile]::GetChildNames($rootHandle)) -ErrorMessage 'manual-recovery-required: canonical transactions root inventory changed during held scan'
        return @($states)
    }
    finally{
        for($worktreeIndex=$worktreeLeases.Count-1;$worktreeIndex -ge 0;$worktreeIndex--){
            $worktreeLease=$worktreeLeases[$worktreeIndex]
            for($transactionIndex=$worktreeLease.TransactionLeases.Count-1;$transactionIndex -ge 0;$transactionIndex--){
                $transactionLease=$worktreeLease.TransactionLeases[$transactionIndex]
                Close-CanonicalJournalSnapshot -Snapshot $transactionLease.Snapshot
                $transactionLease.Handle.Dispose()
            }
            $worktreeLease.Handle.Dispose()
        }
        if($rootHandles){Close-SafeDirectoryContainmentChain -Handles $rootHandles}
    }
}

function Assert-CanonicalTransactionSetAllowsDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $TransactionsRoot,
        [Parameter(Mandatory)] [string] $DocumentHash,
        [string] $AllowedUnfinishedTransactionId
    )

    foreach($state in @(Get-CanonicalAllTransactionStates -TransactionsRoot $TransactionsRoot)){
        if(-not $state.IsTerminal -and ([string]$state.Header.TransactionId -cne $AllowedUnfinishedTransactionId)){
            throw 'canonical-recovery-required'
        }
        if($DocumentHash -in @($state.ConsumedDocumentHashes)){throw 'reviewed-plan-consumed'}
    }
}

function Test-CanonicalJournalManifestSemantics {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [System.Collections.IDictionary] $Document)
    $headerBytes=ConvertTo-SemanticJsonBytes -InputObject $Document.Header
    $headerSchemaPath=Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-header.schema.json'
    $headerSchemaValidation=Test-RepositoryJsonSchema -SchemaPath $headerSchemaPath -SchemaRoot $script:CanonicalJournalSchemaRoot
    $null=Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $headerSchemaValidation -InstanceBytes $headerBytes -InstancePath $headerSchemaPath
    foreach($record in @($Document.Records)){
        $recordBytes=ConvertTo-SemanticJsonBytes -InputObject $record
        $recordSchemaPath=Join-Path $script:CanonicalJournalSchemaRoot 'canonical-journal-record.schema.json'
        $recordSchemaValidation=Test-RepositoryJsonSchema -SchemaPath $recordSchemaPath -SchemaRoot $script:CanonicalJournalSchemaRoot
        $null=Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $recordSchemaValidation -InstanceBytes $recordBytes -InstancePath $recordSchemaPath
    }
    foreach($result in @($Document.Results)){
        $resultBytes=ConvertTo-SemanticJsonBytes -InputObject $result
        $resultSchemaPath=Join-Path $script:CanonicalJournalSchemaRoot 'canonical-transaction-result.schema.json'
        $resultSchemaValidation=Test-RepositoryJsonSchema -SchemaPath $resultSchemaPath -SchemaRoot $script:CanonicalJournalSchemaRoot
        $null=Invoke-FixedJsonSchemaValidationBytes -SchemaValidation $resultSchemaValidation -InstanceBytes $resultBytes -InstancePath $resultSchemaPath
    }
    $null=Test-CanonicalJournalChain -Header $Document.Header -Records @($Document.Records) -Results @($Document.Results)
}
