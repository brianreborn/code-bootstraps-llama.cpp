# Windows counterpart of scripts/fetch-llama.sh (UNTESTED on Windows): download the official
# llama.cpp release pinned in config\llama-release.json, check its sha256, unpack it into
# bin\llama-<tag>-<platform>-<variant>\ and record llama-server.exe in .cache\llama-server.path.
#   powershell -ExecutionPolicy Bypass -File scripts\fetch-llama.ps1 [-Variant cpu|vulkan|cuda-12|cuda-13] [-Platform windows-x64]
# Exit 3: no listed binary for this machine, or it does not start (build with scripts\build-windows.ps1).
param(
    [string]$Variant = $(if ($env:VARIANT) { $env:VARIANT } else { "cpu" }),
    [string]$Platform = "",
    [switch]$PrintPlatform
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path $PSScriptRoot "lib\common.ps1")
. (Join-Path $PSScriptRoot "lib\download.ps1")

if (-not $Platform) {
    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    $os = Get-OsName   # (not $IsLinux / $IsMacOS: Windows PowerShell 5.1 does not have them)
    if (-not $arch) { $arch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() }
    $Platform = "$os-" + $(switch -regex ($arch) { '^(AMD64|X64)$' { "x64" } '^(ARM64|Arm64)$' { "arm64" } default { $arch.ToLower() } })
}
if ($PrintPlatform) { Write-Output $Platform; exit 0 }

$rel = Get-Content -Raw "config\llama-release.json" | ConvertFrom-Json
$asset = $rel.assets | Where-Object { $_.platform -eq $Platform -and $_.variant -eq $Variant } | Select-Object -First 1
if (-not $asset) {
    Write-Warning "fetch-llama: no $($rel.tag) release binary for platform '$Platform' variant '$Variant'."
    Write-Warning "fetch-llama: listed: $(($rel.assets | ForEach-Object { "$($_.platform)/$($_.variant)" }) -join ' ')"
    Write-Warning "fetch-llama: build from source instead (scripts\build-windows.ps1)."
    exit 3
}
$dl = Join-Path $Root ".cache\dl"
New-Item -ItemType Directory -Force -Path $dl | Out-Null
function Get-Asset([string]$File, [string]$Sha) {
    $dest = Join-Path $dl $File
    if ((Test-Path -LiteralPath $dest) -and ((Get-Sha256 $dest) -eq $Sha)) { Write-Host "fetch-llama: $File already downloaded and verified"; return }
    Write-Host "fetch-llama: $($rel.base_url)$File"
    Get-VerifiedFile -Url "$($rel.base_url)$File" -Dest $dest -Sha256 $Sha -Tag "fetch-llama"
}
function Expand-Stripped([string]$File, [string]$To) {   # unpack; a single top-level directory is stripped
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("llama-unpack-" + [guid]::NewGuid().ToString("N"))
    $src = Join-Path $dl $File
    # no "downloaded from the internet" mark on the archive -> none on the DLLs (SmartScreen, blocked DLL loads)
    if ((Test-Windows) -and (Get-Command Unblock-File -ErrorAction SilentlyContinue)) { Unblock-File -LiteralPath $src }
    if ($File.EndsWith(".zip")) { Expand-Archive -LiteralPath $src -DestinationPath $tmp -Force }
    else { New-Item -ItemType Directory -Path $tmp | Out-Null; tar -xzf $src -C $tmp; if ($LASTEXITCODE) { throw "tar failed on $File" } }
    $top = @(Get-ChildItem -Force -LiteralPath $tmp)
    $from = if ($top.Count -eq 1 -and $top[0].PSIsContainer) { $top[0].FullName } else { $tmp }
    Copy-Item -Recurse -Force -Path (Join-Path $from "*") -Destination $To
    Remove-Item -Recurse -Force -LiteralPath $tmp
}
$hasExtra = ($asset.PSObject.Properties.Name -contains "extra_file") -and $asset.extra_file
Get-Asset $asset.file $asset.sha256
if ($hasExtra) { Get-Asset $asset.extra_file $asset.extra_sha256 }   # CUDA runtime DLLs

$dest = Join-Path $Root "bin\llama-$($rel.tag)-$Platform-$Variant"
# the stamp lists every unpacked file and its size; a missing or changed file unpacks again
$stamp = Join-Path $dest ".verified-$($asset.sha256)"
$intact = (Test-Path -LiteralPath $stamp) -and
    ((@(Get-Content -LiteralPath $stamp) -join "`n") -eq ((Get-TreeManifest $dest) -join "`n"))
if (-not $intact) {
    if (Test-Path -LiteralPath $stamp) { Write-Host "fetch-llama: $dest changed since it was unpacked; unpacking again" }
    if (Test-Path -LiteralPath $dest) { Remove-Item -Recurse -Force -LiteralPath $dest }
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Expand-Stripped $asset.file $dest
    if ($hasExtra) { Expand-Stripped $asset.extra_file $dest }
    if (Test-Windows) { Get-ChildItem -LiteralPath $dest -Recurse -File | Unblock-File }
    Write-TextFile $stamp (Get-TreeManifest $dest)
}
$exe = Join-Path $dest "llama-server.exe"
if (-not (Test-Path -LiteralPath $exe)) { $exe = Join-Path $dest "llama-server" }
if (-not (Test-Path -LiteralPath $exe)) { throw "fetch-llama: llama-server missing after unpacking into $dest" }

# can it run here? (missing VC++ runtime, wrong architecture, ...)
if ($Platform -like "windows-*" -and -not (Test-Windows)) {
    Write-Warning "fetch-llama: $Platform binaries run on Windows only (this is $([System.Runtime.InteropServices.RuntimeInformation]::OSDescription)); use scripts/fetch-llama.sh here."
    Remove-Item -Recurse -Force -LiteralPath $dest
    exit 3
}
$ver = ""
$eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"   # --version prints to stderr; PS 5.1 would throw on it
try { $ver = (& $exe --version 2>&1 | Out-String); $ok = ($LASTEXITCODE -eq 0) } catch { $ok = $false; $ver = $_.ToString() }
finally { $ErrorActionPreference = $eap }
if (-not $ok) {
    Write-Warning "fetch-llama: the release llama-server does not run on this machine:"
    Write-Warning (($ver -split "`n" | Select-Object -First 5) -join "`n")
    Write-Warning "fetch-llama: build from source instead (scripts\build-windows.ps1)."
    Remove-Item -Recurse -Force -LiteralPath $dest
    exit 3
}
Write-Host "fetch-llama: $((($ver -split "`n") | Where-Object { $_ -match 'version' } | Select-Object -First 1)) -> $exe"
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache") | Out-Null
Write-TextFile (Join-Path $Root ".cache\llama-server.path") $exe
Write-Output $exe
