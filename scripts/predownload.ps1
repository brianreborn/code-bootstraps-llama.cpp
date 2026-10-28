# Windows counterpart of scripts/predownload.sh: toolchain installers (winget download), the pinned
# llama.cpp source tarball and web UI (sha256-checked), the submodule, and the default models.
#   powershell -ExecutionPolicy Bypass -File scripts\predownload.ps1 [-SkipPackages] [-SkipModels]
param([switch]$SkipPackages, [switch]$SkipModels)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
$pin = @{}
Get-Content "config\llama-pin.env" | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object { $k, $v = $_ -split '=', 2; $pin[$k.Trim()] = $v.Trim() }
$D = Join-Path $Root ".cache\predownload"; New-Item -ItemType Directory -Force -Path $D | Out-Null
if (-not $SkipPackages) { & (Join-Path $PSScriptRoot "prereqs.ps1") -Download }
function Get-Checked([string]$url, [string]$sha, [string]$dest) {
    if ((Test-Path $dest) -and ((Get-FileHash $dest -Algorithm SHA256).Hash -eq $sha.ToUpper())) { Write-Host "predownload: have $(Split-Path -Leaf $dest)"; return }
    Invoke-WebRequest -Uri $url -OutFile "$dest.part" -UseBasicParsing
    $got = (Get-FileHash "$dest.part" -Algorithm SHA256).Hash
    if ($got -ne $sha.ToUpper()) { Remove-Item "$dest.part"; throw "predownload: sha256 mismatch for $url (got $got, want $sha)" }
    Move-Item -Force "$dest.part" $dest; Write-Host "predownload: fetched $(Split-Path -Leaf $dest) (sha256 ok)"
}
Get-Checked $pin.LLAMA_SRC_URL $pin.LLAMA_SRC_SHA256 (Join-Path $D "llama.cpp-$($pin.LLAMA_TAG).tar.gz")
Get-Checked $pin.LLAMA_UI_URL $pin.LLAMA_UI_SHA256 (Join-Path $D "llama-$($pin.LLAMA_TAG)-ui.tar.gz")
if ((Test-Path ".git") -and (Get-Command git -ErrorAction SilentlyContinue)) { git submodule update --init llama.cpp }
if (-not (Test-Path "llama.cpp\CMakeLists.txt")) {
    New-Item -ItemType Directory -Force -Path "llama.cpp" | Out-Null
    tar -xzf (Join-Path $D "llama.cpp-$($pin.LLAMA_TAG).tar.gz") -C llama.cpp --strip-components=1
    if ($LASTEXITCODE -ne 0) { throw "predownload: unpacking the source tarball failed" }
    Set-Content -LiteralPath "llama.cpp\.cbl-source-tag" -Value "$($pin.LLAMA_TAG) $($pin.LLAMA_COMMIT)" -Encoding ascii
}
& (Join-Path $PSScriptRoot "apply-patches.ps1") -Check
if (-not $SkipModels) { & (Join-Path $PSScriptRoot "fetch-models.ps1") }
Write-Host "predownload: done: you can now build and start offline (start.bat)"
