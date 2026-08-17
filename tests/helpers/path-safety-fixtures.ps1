#requires -Version 7.0

function New-PathSafetyFixtureRoot {
    [CmdletBinding()]
    param([string] $Prefix = 'ai-agent-dotfiles-path-safety')

    $root = Join-Path ([System.IO.Path]::GetTempPath()) "$Prefix-$([Guid]::NewGuid().ToString('N'))"
    [System.IO.Directory]::CreateDirectory($root) | Out-Null
    return $root
}

function New-PathSafetyFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [string] $Content = 'fixture')

    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }
    [System.IO.File]::WriteAllText($Path, $Content, [System.Text.UTF8Encoding]::new($false))
    return $Path
}

function New-PathSafetyJunction {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Target)

    New-Item -ItemType Junction -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    return $Path
}

function New-PathSafetyHardLink {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $Target)

    New-Item -ItemType HardLink -Path $Path -Target $Target -ErrorAction Stop | Out-Null
    return $Path
}

function Add-PathSafetyNamedStream {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [string] $Name = 'safety-sentinel')

    Set-Content -LiteralPath $Path -Stream $Name -Value 'named stream sentinel' -NoNewline
}

function Assert-PathSafetyThrows {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [scriptblock] $Script,
        [Parameter(Mandatory)] [string] $Pattern,
        [Parameter(Mandatory)] [string] $Message
    )

    $failed = $false
    try { & $Script | Out-Null }
    catch { $failed = $_.Exception.Message -match $Pattern }
    Assert-TestCondition $failed $Message
}
