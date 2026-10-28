# Apply patches\*.patch in order to the llama.cpp source tree (default: .\llama.cpp). Same rules as
# scripts/apply-patches.sh: idempotent, fails if a patch does not apply. -Check: verify only.
param([string]$Src = "", [switch]$Check)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
if (-not $Src) { $Src = Join-Path $Root "llama.cpp" }
if (-not (Test-Path (Join-Path $Src "CMakeLists.txt"))) { throw "apply-patches.ps1: no llama.cpp source in $Src" }
if (-not (Get-Command git -ErrorAction SilentlyContinue)) { throw "apply-patches.ps1: git is required (git apply)" }
Push-Location $Src
try {
    foreach ($p in Get-ChildItem (Join-Path $Root "patches") -Filter *.patch | Sort-Object Name) {
        git apply --check -R $p.FullName 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Host "apply-patches.ps1: $($p.Name) already applied"; continue }
        git apply --check $p.FullName
        if ($LASTEXITCODE -ne 0) { throw "apply-patches.ps1: $($p.Name) does not apply to $Src (pin and patches out of sync)" }
        if ($Check) { Write-Host "apply-patches.ps1: $($p.Name) applies cleanly"; continue }
        git apply $p.FullName
        if ($LASTEXITCODE -ne 0) { throw "apply-patches.ps1: git apply $($p.Name) failed" }
        Write-Host "apply-patches.ps1: applied $($p.Name)"
    }
} finally { Pop-Location }
