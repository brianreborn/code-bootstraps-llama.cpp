# Runs the helpers of scripts\lib\common.ps1 that serve.ps1 depends on, under Set-StrictMode
# -Version Latest, instead of only parsing them (review of e363234: a New-Object argument list
# with -bor and an unset $script: variable both parsed fine and failed at run time on 5.1).
#   pwsh -NoProfile -File tests/test-ps1-helpers.ps1 [-Scripts <dir with lib\common.ps1>]
# tests/check-ps1.sh runs it on scripts/ and on the Windows PowerShell 5.1 emulation copy (there
# Test-Windows is true, so the CodeBootstraps.FileId path is taken: it compiles, its kernel32 calls
# fail off Windows and the callers must fall back).
param([string]$Scripts = (Join-Path (Split-Path -Parent $PSScriptRoot) "scripts"))
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
. (Join-Path $Scripts "lib/common.ps1")
$fails = 0
$onRealWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT   # (not renamed by the 5.1 emulation)
function Check([string]$Name, [bool]$Ok, [string]$Detail = "") {
    if ($Ok) { Write-Output "ok   $Name" } else { Write-Output "FAIL $Name $Detail"; $script:fails++ }
}
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("ps1-helpers-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    # --- Test-ServerSaidListening (serve.ps1's readiness check) ---
    $log = Join-Path $tmp "server.log"
    Check "listening: no log file -> false" (-not (Test-ServerSaidListening -LogFile $log -Port 9931))
    [IO.File]::WriteAllText($log, "0.00.081.694 I srv  llama_server: starting`n")
    Check "listening: no listening line -> false" (-not (Test-ServerSaidListening -LogFile $log -Port 9931))
    [IO.File]::AppendAllText($log, "0.00.081.694 I srv  llama_server: listening on http://127.0.0.1:9931`n")
    Check "listening: line for the port -> true" (Test-ServerSaidListening -LogFile $log -Port 9931)
    Check "listening: other port (993) -> false" (-not (Test-ServerSaidListening -LogFile $log -Port 993))
    Check "listening: other port (99311) -> false" (-not (Test-ServerSaidListening -LogFile $log -Port 99311))
    # held open for writing, as llama-server holds its --log-file
    $w = [IO.FileStream]::new($log, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
    try { Check "listening: log open for writing by another handle -> true" (Test-ServerSaidListening -LogFile $log -Port 9931) }
    finally { $w.Dispose() }
    # exactly as serve.ps1 runs it: the function's text, defined in a new runspace under strict mode
    $ps = [powershell]::Create()
    [void]$ps.AddScript({
        param($def, $log)
        Set-StrictMode -Version Latest
        Set-Item -Path function:Test-ServerSaidListening -Value ([scriptblock]::Create($def))
        Test-ServerSaidListening -LogFile $log -Port 9931
    }).AddArgument(${function:Test-ServerSaidListening}.ToString()).AddArgument($log)
    $r = @($ps.Invoke()); $errs = @($ps.Streams.Error); $ps.Dispose()
    Check "listening: in a runspace from the function text -> true" ($r.Count -eq 1 -and $r[0] -eq $true -and $errs.Count -eq 0) "result '$r' errors '$errs'"

    # --- CodeBootstraps.FileId, Get-Fingerprint, Test-SameFile ---
    $f = Join-Path $tmp "model.gguf"; [IO.File]::WriteAllText($f, "x")
    $initErr = ""; try { Initialize-FileId } catch { $initErr = $_.Exception.Message }
    Check "Initialize-FileId under strict mode" ($initErr -eq "" -and ("CodeBootstraps.FileId" -as [type])) $initErr
    Check "Initialize-FileId again (type loaded)" ($(try { Initialize-FileId; $true } catch { $false }))
    if (Test-Windows) {
        $id = ""; try { $id = [CodeBootstraps.FileId]::Identity($f) } catch { }
        if ($onRealWindows) { Check "FileId.Identity" ($id -match '^[0-9a-f]{8}-[0-9a-f]{16}$') "got '$id'" }
        $fp = Get-Fingerprint $f
        if ($onRealWindows) { Check "Get-Fingerprint (Windows: w ...)" ($fp -match '^w \d+ \d+ \d+ \d+ [0-9a-f]{8}-[0-9a-f]{16}$') "got '$fp'" }
        else { Check "Get-Fingerprint (Windows path off Windows: t fallback)" ($fp -match '^t 1 \d+ \d+$') "got '$fp'" }
    } else {
        $fp = Get-Fingerprint $f
        $want = (& stat -c '%s %Y %Z %i' -L $f).Trim()
        Check "Get-Fingerprint = stat '%s %Y %Z %i'" ($fp -eq $want) "got '$fp' want '$want'"
    }
    $fp1 = Get-Fingerprint $f
    Start-Sleep -Milliseconds 1100
    [IO.File]::WriteAllText($f, "y")   # same size, rewritten
    (Get-Item -LiteralPath $f).LastWriteTimeUtc = (Get-Item -LiteralPath $f).LastWriteTimeUtc.AddSeconds(-5)
    Check "Get-Fingerprint changes after a same-size rewrite" ((Get-Fingerprint $f) -ne $fp1)
    Check "Test-SameFile: same file" (Test-SameFile $f (Join-Path $tmp "./model.gguf"))
    $g = Join-Path $tmp "other.gguf"; [IO.File]::WriteAllText($g, "x")
    Check "Test-SameFile: other file" (-not (Test-SameFile $f $g))
} finally {
    Remove-Item -Recurse -Force -LiteralPath $tmp -ErrorAction SilentlyContinue
}
if ($fails) { Write-Output "test-ps1-helpers: $fails failed"; exit 1 }
Write-Output "test-ps1-helpers: OK"
