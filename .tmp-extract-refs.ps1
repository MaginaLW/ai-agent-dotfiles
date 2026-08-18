$ErrorActionPreference='Stop'
$path='C:\Repos\ai-agent-dotfiles\tests\canonical-hard-kill.tests.ps1'
$source=[IO.File]::ReadAllText($path)
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
if($errors.Count){throw 'parse error'}
$fn=@($ast.FindAll({param($n)$n-is[Management.Automation.Language.FunctionDefinitionAst]-and$n.Name-ceq'Test-HardKillPreimageProvenanceContract'},$true)|Where-Object{[object]::ReferenceEquals($_.Parent,$ast.EndBlock)})
if($fn.Count -ne 1){throw "contract fn: $($fn.Count)"}
$body=$fn[0].Body.Extent.Text
$bodyStart=$fn[0].Body.Extent.StartOffset
$lines=$source.Split("`n")
$fnStartLine=$fn[0].Extent.StartLineNumber
# 逐行扫描 here-string 赋值：$var=@' ... '@
$out=[IO.Path]::Combine($env:TEMP,'provenance-refs')
[IO.Directory]::CreateDirectory($out)|Out-Null
$inHere=$false;$curVar=$null;$buf=[System.Collections.Generic.List[string]]::new()
foreach($line in $lines){
    if(-not $inHere){
        if($line -match '^\s*\$([A-Za-z0-9_]+)=@''\s*$'){
            $inHere=$true;$curVar=$Matches[1];$buf.Clear();continue
        }
    }else{
        if($line.Trim() -eq "'@"){
            [IO.File]::WriteAllText((Join-Path $out ($curVar+'.txt')),($buf -join "`n")+[char]10)
            "$curVar : $($buf.Count) lines"
            $inHere=$false;$curVar=$null;continue
        }
        $buf.Add($line.TrimEnd())
    }
}
"refs written to $out"
