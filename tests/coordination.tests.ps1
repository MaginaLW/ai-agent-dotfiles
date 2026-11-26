#requires -Version 7.0
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location -LiteralPath $repoRoot
$exitCode = 1
try {
    $testFiles = @(
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'tests') -Filter '*_test.py' -File |
            Where-Object { $_.Name -ne 'dashboard_server_test.py' } |
            Sort-Object -Property Name
    )
    if ($testFiles.Count -eq 0) {
        throw 'No coordination Python unit test files found under tests/*_test.py.'
    }
    $moduleNames = @($testFiles | ForEach-Object { "tests.$($_.BaseName)" })
    & python -B -m unittest -v @moduleNames
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
}
exit $exitCode
