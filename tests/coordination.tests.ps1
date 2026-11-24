#requires -Version 7.0
$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath (Split-Path -Parent $PSScriptRoot)
try {
    & python -B -m unittest discover -s tests -p "*_test.py" -v
} finally {
    Pop-Location
}
exit $LASTEXITCODE
