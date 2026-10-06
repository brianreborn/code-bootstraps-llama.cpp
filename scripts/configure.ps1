# Ask for the launcher settings. Enter keeps the default and omits that key.
# scripts/panel.py writes .cache/panel.env, so the quoting stays : "${KEY:=value}".
# Read stdin, not Read-Host: Read-Host asks the console host and ignores a pipe.
# Do not exit: this file may be invoked with &.
$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$py = $null
$pyArgs = @()
$found = Get-Command python3 -ErrorAction SilentlyContinue
if ($found) { $py = $found.Source }
if (-not $py) {
    $found = Get-Command python -ErrorAction SilentlyContinue
    if ($found) { $py = $found.Source }
}
if (-not $py) {
    $found = Get-Command py -ErrorAction SilentlyContinue
    if ($found) {
        $py = $found.Source
        $pyArgs = @("-3")
    }
}
if (-not $py) { throw "configure.ps1: python3 was not found" }

$panel = Join-Path $PSScriptRoot "panel.py"
$spec = & $py @pyArgs $panel --fields
if ($LASTEXITCODE -ne 0) { throw "configure.ps1: could not list settings" }

$answers = New-Object System.Collections.Generic.List[string]
$stop = $false
foreach ($line in @($spec)) {
    if ($stop) { break }
    if (-not $line) { continue }
    $bits = $line.Split([char]9)
    if ($bits.Count -lt 3) { continue }
    $key = $bits[0]
    $shown = $bits[1]
    $hint = $bits[2]
    $refused = $false
    while ($true) {
        Write-Host -NoNewline ("{0} [{1}] ({2}): " -f $key, $shown, $hint)
        $ans = [Console]::In.ReadLine()
        if ($null -eq $ans) {
            if ($refused) { throw "configure.ps1: refused $key" }
            $stop = $true
            break
        }
        $ans = $ans.Trim()
        if ($ans -eq "") { break }
        & $py @pyArgs $panel --check $key $ans
        if ($LASTEXITCODE -ne 0) {
            Write-Host ("configure.ps1: refused {0}={1}" -f $key, $ans)
            $refused = $true
            continue
        }
        [void]$answers.Add($key + [char]9 + $ans)
        break
    }
}

$tmp = [System.IO.Path]::GetTempFileName()
$utf8 = New-Object System.Text.UTF8Encoding $false
try {
    if ($answers.Count -eq 0) {
        [System.IO.File]::WriteAllText($tmp, "", $utf8)
    } else {
        [System.IO.File]::WriteAllLines($tmp, $answers.ToArray(), $utf8)
    }
    & $py @pyArgs $panel --write $tmp
    if ($LASTEXITCODE -ne 0) { throw "configure.ps1: could not write .cache\panel.env" }
} finally {
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}
