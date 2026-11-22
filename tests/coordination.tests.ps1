#requires -Version 7.0
$ErrorActionPreference = 'Stop'
$testFile = Get-Item -LiteralPath (Join-Path $PSScriptRoot 'coordination_protocol_test.py')
& python -B -m unittest discover -s $testFile.DirectoryName -p $testFile.Name
exit $LASTEXITCODE
