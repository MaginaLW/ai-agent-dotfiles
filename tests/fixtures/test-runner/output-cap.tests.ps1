#requires -Version 7.0

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($env:AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT)) {
    throw 'AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT is required.'
}

$stateRoot = [System.IO.Path]::GetFullPath($env:AI_AGENT_DOTFILES_FIXTURE_STATE_ROOT)
[System.IO.Directory]::CreateDirectory($stateRoot) | Out-Null
[System.IO.File]::WriteAllText((Join-Path $stateRoot 'output-cap.pid'), [string] $PID)

$stream = [Console]::OpenStandardOutput()
$chunk = [byte[]]::new(1048576)
[Array]::Fill[byte]($chunk, [byte][char]'x')
for ($index = 0; $index -lt 70; $index++) {
    $stream.Write($chunk, 0, $chunk.Length)
}
$stream.Flush()
exit 0
