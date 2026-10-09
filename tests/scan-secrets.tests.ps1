#requires -Version 7.0
# Behavior tests for scripts/scan-secrets.ps1 against fixture Git repositories in %TEMP%.
# Covers a planted token, ${VAR} and ALLCAPS placeholders, the '# scan-ok' marker, the
# excluded scan roots, Git-ignored and deleted files, and reparse-point refusal.
# Needs the pinned gitleaks (scripts/install-gitleaks.ps1). Secret-shaped strings are
# assembled at run time so this file itself stays clean for the repository scan.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'helpers/test-common.ps1')
$scan = Join-Path $RepoRoot 'scripts/scan-secrets.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) ('scan-secrets-tests-' + [guid]::NewGuid().ToString('N'))

$q = [char] 34
$githubToken = 'gh' + 'p_' + ('a1B2' * 9)
# Lowercase 'bearer' matches only the case-insensitive fallback scanner, not gitleaks.
$fallbackOnlyLine = 'authorization: ' + 'bear' + 'er ' + ('x' * 24)
$allCapsLine = 'pass' + 'word: ' + $q + 'CHANGE_ME_PLEASE' + $q

function Set-TestFile([string] $Path, [string] $Content) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Content, [Text.UTF8Encoding]::new($false))
}
function New-ScanRepo([string] $Name) {
    $repo = Join-Path $work $Name
    New-Item -ItemType Directory -Path $repo -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $RepoRoot '.gitleaks.toml') -Destination $repo
    Set-TestFile (Join-Path $repo 'README.md') "# fixture`n"
    & git -C $repo init --quiet
    if ($LASTEXITCODE -ne 0) { throw "Unable to initialize fixture repository: $repo" }
    return $repo
}
function Invoke-Scan([string] $Repo) {
    $jsonPath = Join-Path $work ('scan-' + [guid]::NewGuid().ToString('N') + '.json')
    $r = Invoke-TestProcess -ScriptPath $scan -Arguments @('-RepoRoot', $Repo, '-JsonPath', $jsonPath)
    $json = if (Test-Path -LiteralPath $jsonPath) { Get-Content -LiteralPath $jsonPath -Raw | ConvertFrom-Json } else { $null }
    return [pscustomobject]@{ Code = $r.Code; Out = $r.Out; Json = $json }
}

try {
    Write-Host '[clean repository passes]'
    $repo = New-ScanRepo 'clean'
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -eq 0 -and $r.Json.Result -eq 'PASS') 'a clean fixture passes'
    Assert-TestCondition ($r.Out -match 'filtered copy of 2 files') 'the scan input is README.md and .gitleaks.toml'

    Write-Host '[planted token fails]'
    $repo = New-ScanRepo 'planted'
    Set-TestFile (Join-Path $repo 'config/app.toml') "github = $q$githubToken$q`n"
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -ne 0) 'a planted GitHub token exits non-zero'
    Assert-TestCondition ($r.Json.Result -eq 'FAIL' -and $r.Json.GitleaksFailed -and $r.Json.BlockingFindingCount -ge 1) 'both gitleaks and the fallback report it'
    Assert-TestCondition ($r.Out -notmatch [regex]::Escape($githubToken)) 'the token is not echoed'

    Write-Host '[placeholders pass]'
    $repo = New-ScanRepo 'placeholders'
    Set-TestFile (Join-Path $repo 'config/app.toml') ('token = "${GITHUB_PAT}"' + "`n" + 'authorization = "Bearer ${GITHUB_PAT}"' + "`n" + 'bearer_token_env_var = "GITHUB_PAT"' + "`n")
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -eq 0 -and $r.Json.BlockingFindingCount -eq 0) '${VAR} and *_env_var placeholders pass'
    Set-TestFile (Join-Path $repo 'config/app.toml') "$allCapsLine`n"
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Json.BlockingFindingCount -eq 0) 'an ALLCAPS placeholder is not a fallback finding'
    Assert-TestCondition ($r.Code -ne 0 -and $r.Json.GitleaksFailed) 'gitleaks still judges a long ALLCAPS literal on its own rules'

    Write-Host '[# scan-ok marker]'
    $repo = New-ScanRepo 'scan-ok'
    Set-TestFile (Join-Path $repo 'notes.txt') "$fallbackOnlyLine`n"
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -ne 0 -and $r.Json.BlockingFindingCount -eq 1 -and -not $r.Json.GitleaksFailed) 'an unmarked fallback finding fails'
    Set-TestFile (Join-Path $repo 'notes.txt') "$fallbackOnlyLine # scan-ok`n"
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -eq 0 -and $r.Json.BlockingFindingCount -eq 0) "'# scan-ok' accepts the reviewed line"

    Write-Host '[excluded roots, ignored and deleted files are skipped]'
    $repo = New-ScanRepo 'excluded'
    $planted = "github = $q$githubToken$q`n"
    foreach ($relative in @(
        'claude/skills/a/SKILL.md', 'codex/skills/a/SKILL.md', 'reasonix/skills/a/SKILL.md', 'envs/work/x.txt',
        'reports/x.txt', 'tmp/x.txt', 'imports/x.txt',
        '.reasonix/desktop-topic-auto-title-meta.json', '.reasonix/desktop-topic-created-at.json',
        '.reasonix/desktop-topic-title-sources.json', '.reasonix/desktop-topic-titles.json', 'local/ignored.txt'
    )) { Set-TestFile (Join-Path $repo $relative) $planted }
    Set-TestFile (Join-Path $repo '.gitignore') "local/`n"
    Set-TestFile (Join-Path $repo 'backup/notes.txt') "$fallbackOnlyLine`n"
    Set-TestFile (Join-Path $repo 'tracked.txt') "tracked`n"
    & git -C $repo -c core.autocrlf=false add -- tracked.txt
    if ($LASTEXITCODE -ne 0) { throw 'git add failed' }
    Remove-Item -LiteralPath (Join-Path $repo 'tracked.txt')
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -eq 0 -and $r.Json.Result -eq 'PASS') 'excluded roots, protected .reasonix files and ignored files are not scanned'
    Assert-TestCondition ($r.Out -match 'filtered copy of 4 files') 'the input is README.md, .gitleaks.toml, .gitignore and backup/notes.txt'
    Set-TestFile (Join-Path $repo '.reasonix/other.json') $planted
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -ne 0) 'other .reasonix files are still scanned'

    Write-Host '[reparse points are refused]'
    $repo = New-ScanRepo 'junction'
    $outside = Join-Path $work 'outside'
    Set-TestFile (Join-Path $outside 'outside.txt') "outside`n"
    New-Item -ItemType Junction -Path (Join-Path $repo 'linked') -Target $outside | Out-Null
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -ne 0 -and $r.Out -match 'reparse point') 'a junction inside the repository is refused'
    Assert-TestCondition ($null -eq $r.Json) 'no scan result is written for a refused input'
    [IO.Directory]::Delete((Join-Path $repo 'linked'))
    New-Item -ItemType Directory -Path (Join-Path $repo 'tmp') -Force | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $repo 'tmp/linked') -Target $outside | Out-Null
    $r = Invoke-Scan $repo
    Assert-TestCondition ($r.Code -eq 0) 'a junction inside an excluded root is never visited'

    Write-Host 'scan-secrets tests: PASS'
}
finally {
    if (Test-Path -LiteralPath $work) {
        Get-ChildItem -LiteralPath $work -Recurse -Force -Attributes ReparsePoint | ForEach-Object { [IO.Directory]::Delete($_.FullName) }
        Remove-Item -LiteralPath $work -Recurse -Force
    }
}
