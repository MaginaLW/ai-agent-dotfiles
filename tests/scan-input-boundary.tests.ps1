#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $RepoRoot 'scripts/scan-input-common.ps1')

function Assert {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if (-not $Condition) { throw "FAIL: $Message" }
    Write-Host "  PASS  $Message"
}

function Invoke-BoundedPowerShell {
    param(
        [Parameter(Mandatory)] [string[]] $Arguments,
        [int] $TimeoutMilliseconds = 45000
    )

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = (Get-Command pwsh -ErrorAction Stop).Source
    $startInfo.WorkingDirectory = $RepoRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    foreach ($argument in $Arguments) { $startInfo.ArgumentList.Add($argument) }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    try {
        if (-not $process.Start()) { throw 'Unable to start bounded PowerShell fixture.' }
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMilliseconds)) {
            try { $process.Kill($true) } catch { }
            $null = $process.WaitForExit(5000)
            throw "Bounded PowerShell fixture exceeded $TimeoutMilliseconds ms."
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Stdout = $stdoutTask.GetAwaiter().GetResult()
            Stderr = $stderrTask.GetAwaiter().GetResult()
        }
    }
    finally { $process.Dispose() }
}

$regressionFailures = [System.Collections.Generic.List[string]]::new()
function Assert-Regression {
    param([Parameter(Mandatory)] [bool] $Condition, [Parameter(Mandatory)] [string] $Message)
    if ($Condition) {
        Write-Host "  PASS  $Message"
        return
    }
    $regressionFailures.Add($Message)
    Write-Host "  RED   $Message"
}

$work = Join-Path ([System.IO.Path]::GetTempPath()) "ai-agent-dotfiles-scan-input-$([Guid]::NewGuid().ToString('N'))"
$fixtureRepo = Join-Path $work 'repo'
$outputRoot = Join-Path $work 'scan-input'
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo '.reasonix') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $fixtureRepo 'src') -Force | Out-Null

try {
    & git -C $fixtureRepo init --quiet
    if ($LASTEXITCODE -ne 0) { throw 'fixture git init failed' }
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo 'src/ordinary.txt'), 'ordinary content')
    [System.IO.File]::WriteAllText((Join-Path $fixtureRepo '.reasonix/adjacent-visible.txt'), 'adjacent content')
    foreach ($leaf in Get-ProtectedReasonixRelativePaths) {
        $path = Join-Path $fixtureRepo $leaf
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $path) | Out-Null
        [System.IO.File]::WriteAllText($path, 'protected sentinel content')
    }
    & git -C $fixtureRepo add -- 'src/ordinary.txt' '.reasonix/adjacent-visible.txt'
    if ($LASTEXITCODE -ne 0) { throw 'fixture git add failed' }

    $result = New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $outputRoot
    Assert ((Test-Path -LiteralPath (Join-Path $outputRoot 'src/ordinary.txt') -PathType Leaf)) 'ordinary tracked file is materialized'
    Assert ((Test-Path -LiteralPath (Join-Path $outputRoot '.reasonix/adjacent-visible.txt') -PathType Leaf)) 'adjacent non-protected Reasonix file remains visible'
    foreach ($leaf in Get-ProtectedReasonixRelativePaths) {
        Assert (-not (Test-Path -LiteralPath (Join-Path $outputRoot $leaf))) "protected path is absent: $leaf"
        Assert ($leaf -notin @($result.Files.RelativePath)) "manifest excludes protected path: $leaf"
    }
    Assert ($result.Files.Count -eq 2) 'manifest contains the exact two allowed files'
    Assert (-not [string]::IsNullOrWhiteSpace($result.SourcePolicyHash)) 'manifest returns a source policy hash'

    Write-Host '[canonical exact exclusions before content reads]'
    $canonicalSource = Join-Path $work 'canonical-source'
    $canonicalOutput = Join-Path $work 'canonical-output'
    New-Item -ItemType Directory -Path (Join-Path $canonicalSource '.reasonix') -Force | Out-Null
    New-Item -ItemType Directory -Path $canonicalOutput -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $canonicalSource 'ordinary.txt'), 'ordinary fixture content')
    $lockedProtectedStreams = [System.Collections.Generic.List[System.IO.FileStream]]::new()
    try {
        foreach ($leaf in Get-ProtectedReasonixRelativePaths) {
            $path = Join-Path $canonicalSource $leaf
            New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
            [System.IO.File]::WriteAllText($path, 'locked fixture content')
            $lockedProtectedStreams.Add([System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None))
        }
        $canonicalResultPath = Join-Path $canonicalOutput 'scan-result.json'
        $canonicalRun = Invoke-BoundedPowerShell -Arguments @(
            '-NoProfile', '-File', (Join-Path $RepoRoot 'scripts/scan-secrets.ps1'),
            '-RepoRoot', $RepoRoot,
            '-CanonicalPreflight',
            '-SourceRoot', $canonicalSource,
            '-CanonicalPreflightOutputRoot', $canonicalOutput,
            '-ScannerConfigPath', (Join-Path $RepoRoot '.gitleaks.toml'),
            '-JsonPath', $canonicalResultPath
        )
        Assert-Regression ($canonicalRun.ExitCode -eq 0) 'canonical scan succeeds while every protected exact-path fixture denies reads'
        Assert-Regression (Test-Path -LiteralPath $canonicalResultPath -PathType Leaf) 'canonical no-read fixture publishes a result'
        if (Test-Path -LiteralPath $canonicalResultPath -PathType Leaf) {
            $canonicalDocument = Get-Content -LiteralPath $canonicalResultPath -Raw | ConvertFrom-Json -AsHashtable
            Assert-Regression ([string]$canonicalDocument.Result -ceq 'PASS') 'canonical no-read fixture remains a PASS scan'
            Assert-Regression (-not [bool]$canonicalDocument.GitleaksFailed) 'pinned gitleaks preserves exit-zero scan semantics'
        }
    }
    finally {
        foreach ($stream in $lockedProtectedStreams) { $stream.Dispose() }
    }

    Write-Host '[actual scan policy hash]'
    $defaultPrefixes = @('.git/', 'claude/skills/', 'codex/skills/', 'reasonix/skills/', 'envs/', 'reports/', 'tmp/', 'imports/')
    $exactExclusions = @(Get-ProtectedReasonixRelativePaths)
    $defaultPolicyHash = Get-ScanSourcePolicyHash -ExcludedPrefixes $defaultPrefixes -ExactExcludedRelativePaths $exactExclusions
    $canonicalPolicyHash = Get-ScanSourcePolicyHash -ExcludedPrefixes @() -ExactExcludedRelativePaths $exactExclusions -SkipGitIgnore
    Assert-Regression ($defaultPolicyHash -cne $canonicalPolicyHash) 'different effective scan policies have different hashes'
    Assert-Regression ([string]$result.SourcePolicyHash -ceq $defaultPolicyHash) 'default manifest binds the default effective policy hash'

    $normalizedPrefixVariant = @($defaultPrefixes | ForEach-Object { './' + (($_.TrimEnd('/')) -replace '/', '\').ToUpperInvariant() } | Sort-Object -Descending) + @('./TMP', 'tmp/')
    $normalizedExactVariant = @($exactExclusions | ForEach-Object { './' + (($_) -replace '/', '\').ToUpperInvariant() } | Sort-Object -Descending) + @($exactExclusions[0])
    $normalizedDefaultHash = Get-ScanSourcePolicyHash -ExcludedPrefixes $normalizedPrefixVariant -ExactExcludedRelativePaths $normalizedExactVariant
    Assert-Regression ($normalizedDefaultHash -ceq $defaultPolicyHash) 'policy hash normalizes order, slash form, case, and duplicate-insensitive path semantics'

    $canonicalPolicyDestination = Join-Path $work 'scan-input-canonical-policy'
    $canonicalPolicyResult = New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $canonicalPolicyDestination -ExcludedPrefixes @() -SkipGitIgnore
    Assert-Regression ([string]$canonicalPolicyResult.SourcePolicyHash -ceq $canonicalPolicyHash) 'canonical manifest binds its actual empty-prefix and skip-git-ignore policy'

    Write-Host '[pinned gitleaks process boundary]'
    $scannerText = [System.IO.File]::ReadAllText((Join-Path $RepoRoot 'scripts/scan-secrets.ps1'))
    Assert-Regression ($scannerText -notmatch '(?m)^\s*&\s*\$gitleaks(?:\s|$)') 'production scanner has no bare variable-based gitleaks launch'
    Assert-Regression ($scannerText -match '\bOpen-PinnedToolLease\b') 'production scanner opens a frozen pinned-tool lease'
    Assert-Regression ($scannerText -match '\bInvoke-PinnedToolProcess\b') 'production scanner invokes gitleaks through the bounded pinned-tool process runner'
    Assert-Regression ($scannerText -match '\bClose-PinnedToolLease\b') 'production scanner closes the pinned-tool lease after invocation'
    $leaseOpenIndex = $scannerText.IndexOf('Open-PinnedToolLease', [System.StringComparison]::Ordinal)
    $leaseInvokeIndex = $scannerText.IndexOf('Invoke-PinnedToolProcess', [System.StringComparison]::Ordinal)
    $leaseCloseIndex = $scannerText.IndexOf('Close-PinnedToolLease', [System.StringComparison]::Ordinal)
    Assert-Regression ($leaseOpenIndex -ge 0 -and $leaseInvokeIndex -gt $leaseOpenIndex -and $leaseCloseIndex -gt $leaseInvokeIndex) 'pinned-tool lease remains held until the bounded process call returns'
    foreach ($parameterName in @('TimeoutMilliseconds','ReapTimeoutMilliseconds','MaximumCombinedOutputBytes')) {
        Assert-Regression ($scannerText -match ("-" + $parameterName + '\b')) "pinned gitleaks invocation supplies bounded $parameterName"
    }

    Write-Host '[quoted-value false-positive regression]'
    $quotedValuePattern = '(?i)(api_key|token|secret|password|client_secret|refresh_token|access_token)\s*[:=]\s*["''][^$][^"'']{8,}["'']'
    $wireFieldName = 'Message' + 'Token'
    $messageValue = 'canonical-recovery-status-retry'
    $directWireAssignment = $wireFieldName + "='" + $messageValue + "'"
    $messageIdLiteralAssignment = '$recoveryMessageId' + "='" + $messageValue + "'"
    $variableWireAssignment = $wireFieldName + '=$recoveryMessageId'
    Assert-Regression ([regex]::IsMatch($directWireAssignment, $quotedValuePattern)) 'scanner rule demonstrates the direct quoted wire-field false positive'
    Assert-Regression (-not [regex]::IsMatch($messageIdLiteralAssignment, $quotedValuePattern)) 'semantic MessageId local does not trigger the quoted-secret rule'
    Assert-Regression (-not [regex]::IsMatch($variableWireAssignment, $quotedValuePattern)) 'wire field assigned from the MessageId local does not trigger the quoted-secret rule'

    Write-Host '[gitleaks exit-one semantics]'
    $findingSource = Join-Path $work 'finding-source'
    $findingOutput = Join-Path $work 'finding-output'
    New-Item -ItemType Directory -Path $findingSource,$findingOutput -Force | Out-Null
    $sensitiveFieldName = 'pass' + 'word'
    $syntheticValue = 'fixture-' + ('z' * 24)
    $syntheticAssignment = '$' + $sensitiveFieldName + " = '" + $syntheticValue + "'"
    [System.IO.File]::WriteAllText((Join-Path $findingSource 'synthetic.ps1'), $syntheticAssignment)
    $findingResultPath = Join-Path $findingOutput 'scan-result.json'
    $findingRun = Invoke-BoundedPowerShell -Arguments @(
        '-NoProfile', '-File', (Join-Path $RepoRoot 'scripts/scan-secrets.ps1'),
        '-RepoRoot', $RepoRoot,
        '-CanonicalPreflight',
        '-SourceRoot', $findingSource,
        '-CanonicalPreflightOutputRoot', $findingOutput,
        '-ScannerConfigPath', (Join-Path $RepoRoot '.gitleaks.toml'),
        '-JsonPath', $findingResultPath
    )
    Assert-Regression ($findingRun.ExitCode -eq 1) 'synthetic quoted finding preserves scanner exit-one semantics'
    Assert-Regression (Test-Path -LiteralPath $findingResultPath -PathType Leaf) 'finding scan publishes a validated FAIL result'
    if (Test-Path -LiteralPath $findingResultPath -PathType Leaf) {
        $findingDocument = Get-Content -LiteralPath $findingResultPath -Raw | ConvertFrom-Json -AsHashtable
        Assert-Regression ([string]$findingDocument.Result -ceq 'FAIL') 'finding scan result is FAIL'
        Assert-Regression ([bool]$findingDocument.GitleaksFailed) 'pinned gitleaks exit one is recorded as a finding result'
    }

    $secondDestination = Join-Path $work 'scan-input-existing'
    New-Item -ItemType Directory -Path $secondDestination | Out-Null
    $failed = $false
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $secondDestination | Out-Null }
    catch { $failed = $_.Exception.Message -match 'create-new' }
    Assert $failed 'existing destination is rejected'

    Write-Host '[alias, reparse, and ADS rejection]'
    $hardlinkPath = Join-Path $fixtureRepo 'src/protected-hardlink.txt'
    $protectedTarget = Join-Path $fixtureRepo (Get-ProtectedReasonixRelativePaths | Select-Object -First 1)
    New-Item -ItemType HardLink -Path $hardlinkPath -Target $protectedTarget | Out-Null
    $hardlinkRejected = $false
    $hardlinkDestination = Join-Path $work 'scan-input-hardlink'
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $hardlinkDestination | Out-Null }
    catch { $hardlinkRejected = $_.Exception.Message -match 'hard link|aliases a protected' }
    Assert $hardlinkRejected 'hardlink alias to protected content is rejected before copy'
    Assert (-not (Test-Path -LiteralPath $hardlinkDestination)) 'hardlink rejection creates no scan root'
    Remove-Item -LiteralPath $hardlinkPath -Force

    $outsideRoot = Join-Path $work 'outside'
    New-Item -ItemType Directory -Path $outsideRoot | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $outsideRoot 'outside.txt'), 'outside sentinel')
    $junctionPath = Join-Path $fixtureRepo 'outside-junction'
    New-Item -ItemType Junction -Path $junctionPath -Target $outsideRoot | Out-Null
    $junctionRejected = $false
    $junctionDestination = Join-Path $work 'scan-input-junction'
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $junctionDestination | Out-Null }
    catch { $junctionRejected = $_.Exception.Message -match 'reparse' }
    Assert $junctionRejected 'junction to outside content is rejected without traversal'
    Assert (-not (Test-Path -LiteralPath $junctionDestination)) 'junction rejection creates no scan root'
    Remove-Item -LiteralPath $junctionPath -Force

    $ordinaryPath = Join-Path $fixtureRepo 'src/ordinary.txt'
    Set-Content -LiteralPath $ordinaryPath -Stream 'phase0-sentinel' -Value 'named stream content' -NoNewline
    $adsRejected = $false
    $adsDestination = Join-Path $work 'scan-input-ads'
    try { New-FilteredScanInput -RepoRoot $fixtureRepo -DestinationRoot $adsDestination | Out-Null }
    catch { $adsRejected = $_.Exception.Message -match 'alternate data stream' }
    Assert $adsRejected 'named alternate data stream is rejected before copy'
    Assert (-not (Test-Path -LiteralPath $adsDestination)) 'ADS rejection creates no scan root'
    Remove-Item -LiteralPath $ordinaryPath -Stream 'phase0-sentinel'

    if ($regressionFailures.Count -gt 0) {
        throw "FAIL: scanner regression checks: $($regressionFailures -join '; ')"
    }
    Write-Host 'scan input boundary tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
