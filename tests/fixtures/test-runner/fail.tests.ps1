#requires -Version 7.0
Write-Output 'fixture failure stdout'
[Console]::Error.WriteLine('fixture failure stderr')
exit 7
