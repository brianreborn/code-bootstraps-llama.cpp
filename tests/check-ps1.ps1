# Static checks for every .ps1 in the repository, run with PowerShell 7 (pwsh) on any OS:
#  - it parses;
#  - no PowerShell 6+ syntax that Windows PowerShell 5.1 rejects (?:, ??, ??=, ?., &&, ||);
#  - $IsWindows / $IsLinux / $IsMacOS / $IsCoreCLR only inside scripts/lib/common.ps1 (5.1 has
#    no such variables, and reading one under Set-StrictMode throws: start.bat failed that way);
#  - no Join-Path with more than one child path and no 6+-only parameters;
#  - ASCII only (5.1 reads a .ps1 without BOM in the ANSI code page).
#   pwsh -NoProfile -File tests/check-ps1.ps1        (tests/check-ps1.sh also runs the 5.1 emulation)
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$files = Get-ChildItem -Path $root -Recurse -Filter *.ps1 -File | Where-Object { $_.FullName -notmatch '[\\/](llama\.cpp|build[^\\/]*|bin)[\\/]' }
$bad = New-Object System.Collections.Generic.List[string]
$only6 = @{ "ConvertFrom-Json" = @("AsHashtable", "Depth"); "Get-Content" = @("AsByteStream"); "Set-Content" = @("AsByteStream");
            "Invoke-WebRequest" = @("SkipCertificateCheck", "SslProtocol", "Resume", "SkipHttpErrorCheck"); "ForEach-Object" = @("Parallel");
            "Join-Path" = @("AdditionalChildPath"); "Test-Json" = @(); "Get-Error" = @() }
foreach ($f in $files) {
    $rel = $f.FullName.Substring($root.Length + 1)
    $tokens = $null; $errs = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errs)
    foreach ($e in $errs) { $bad.Add("${rel}:$($e.Extent.StartLineNumber): parse error: $($e.Message)") }
    # 5.1 reads a .ps1 without a byte order mark in the ANSI code page: keep them ASCII
    $ln = 0; foreach ($l in [IO.File]::ReadAllLines($f.FullName)) { $ln++; if ($l -match '[^\x00-\x7F]') { $bad.Add("${rel}:${ln}: non-ASCII character (Windows PowerShell 5.1 would misread it)") } }
    $find = { param($pred) $ast.FindAll($pred, $true) }
    foreach ($n in (& $find { param($a) $a.GetType().Name -in @("TernaryExpressionAst", "PipelineChainAst") })) {
        $bad.Add("${rel}:$($n.Extent.StartLineNumber): PowerShell 7 only: $($n.GetType().Name -replace 'Ast$','') '$($n.Extent.Text.Substring(0, [Math]::Min(60, $n.Extent.Text.Length)))'")
    }
    foreach ($n in (& $find { param($a) ($a -is [System.Management.Automation.Language.BinaryExpressionAst] -and $a.Operator.ToString() -eq "QuestionQuestion") -or
                                    ($a -is [System.Management.Automation.Language.AssignmentStatementAst] -and $a.Operator.ToString() -eq "QuestionQuestionEquals") -or
                                    ($a -is [System.Management.Automation.Language.MemberExpressionAst] -and $a.NullConditional) })) {
        $bad.Add("${rel}:$($n.Extent.StartLineNumber): PowerShell 7 only operator: '$($n.Extent.Text)'")
    }
    if ($rel -notmatch '^scripts[\\/]lib[\\/]common\.ps1$') {
        foreach ($n in (& $find { param($a) $a -is [System.Management.Automation.Language.VariableExpressionAst] -and $a.VariablePath.UserPath -in @("IsWindows", "IsLinux", "IsMacOS", "IsCoreCLR") })) {
            $bad.Add("${rel}:$($n.Extent.StartLineNumber): `$$($n.VariablePath.UserPath) does not exist in Windows PowerShell 5.1: use Test-Windows / Get-OsName (scripts/lib/common.ps1)")
        }
    }
    foreach ($c in (& $find { param($a) $a -is [System.Management.Automation.Language.CommandAst] })) {
        $name = $c.GetCommandName()
        if (-not $name -or -not $only6.ContainsKey($name)) { continue }
        foreach ($p in ($c.CommandElements | Where-Object { $_ -is [System.Management.Automation.Language.CommandParameterAst] })) {
            if ($only6[$name] -contains $p.ParameterName) { $bad.Add("${rel}:$($c.Extent.StartLineNumber): $name -$($p.ParameterName) is PowerShell 6+ only") }
        }
        if ($name -eq "Join-Path") {
            $pos = @($c.CommandElements | Select-Object -Skip 1 | Where-Object { $_ -isnot [System.Management.Automation.Language.CommandParameterAst] })
            if ($pos.Count -gt 2) { $bad.Add("${rel}:$($c.Extent.StartLineNumber): Join-Path with $($pos.Count - 1) child paths needs PowerShell 6+") }
        }
    }
}
if ($bad.Count) { $bad | ForEach-Object { Write-Host "check-ps1: $_" }; exit 1 }
Write-Host "check-ps1: OK $($files.Count) files parse, no PowerShell 6+ syntax or variables"
