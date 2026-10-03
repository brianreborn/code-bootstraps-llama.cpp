# Windows half of tests/model-selection-matrix.sh: runs scripts\start.ps1 / scripts\serve.ps1 in
# prepared sandboxes under pwsh on Linux, with the Windows-only calls stubbed:
#   Get-CimInstance (cores, RAM), Get-Culture (Windows display language), Get-FileHash (the
#   placeholder model files hold their manifest sha256 as text), curl.exe (records the URL).
# The sandboxes' scripts\fetch-llama.ps1 and scripts\lib\open-ui.ps1 are replaced by the driver.
#   pwsh -NoProfile -File tests/model-selection-matrix.ps1 -Jobs jobs.json
param([Parameter(Mandatory = $true)][string]$Jobs)
$ErrorActionPreference = "Stop"
$global:FakeMem = 16GB; $global:FakeCulture = "en-US"
function global:Get-CimInstance {
    param([Parameter(Position = 0)][string]$ClassName)
    if ($ClassName -eq "Win32_Processor") { [pscustomobject]@{ NumberOfCores = 8; NumberOfLogicalProcessors = 8 } }
    else { [pscustomobject]@{ TotalPhysicalMemory = [double]$global:FakeMem } }
}
function global:Get-Culture { [pscustomobject]@{ Name = $global:FakeCulture } }
function global:Get-FileHash {
    param([string]$Algorithm, [string]$LiteralPath, [string]$Path)
    $p = if ($LiteralPath) { $LiteralPath } else { $Path }
    [pscustomobject]@{ Hash = ([IO.File]::ReadAllText($p).Trim().Substring(0, 64)).ToUpperInvariant() }
}
$here = Get-Location
$list = Get-Content -Raw $Jobs | ConvertFrom-Json
# every job starts from this process's original environment (jobs set HOME, HF_HOME, PROFILE, ...)
$baseEnv = @{}; Get-ChildItem Env: | ForEach-Object { $baseEnv[$_.Name] = $_.Value }
foreach ($j in $list) {
    Get-ChildItem Env: | Where-Object { -not $baseEnv.ContainsKey($_.Name) } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    foreach ($k in $baseEnv.Keys) { Set-Item "Env:$k" $baseEnv[$k] }
    foreach ($p in $j.env.PSObject.Properties) { Set-Item "Env:$($p.Name)" $p.Value }
    $global:FakeMem = [double]$j.mem; $global:FakeCulture = [string]$j.culture
    $oldPath = $env:PATH; $env:PATH = "$($j.stubs)$([IO.Path]::PathSeparator)$oldPath"
    $status = "ok"
    try {
        $script = Join-Path $j.sandbox $j.script
        # argline is PowerShell syntax (as typed after start.bat / serve.ps1), so unknown -Name
        # tokens reach start.ps1's remaining arguments the way they do from the command line
        Invoke-Expression ("& `$script " + $j.argline + ' *> (Join-Path $env:CAPTURE_DIR "output.txt")')
    } catch {
        $status = "error: " + ($_.Exception.Message -replace '\s+', ' ')
    } finally {
        $env:PATH = $oldPath
        Set-Location $here
    }
    [IO.File]::WriteAllText((Join-Path $env:CAPTURE_DIR "status.txt"), $status)
}
