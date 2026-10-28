# Windows build prerequisites (README "Build prerequisites"): Visual Studio 2022 / Build Tools with
# "Desktop development with C++" (MSVC), cmake, git. MinGW-w64 is not supported by build-windows.ps1.
#   scripts\prereqs.ps1 -Check       fail with an install hint when something is missing
#   scripts\prereqs.ps1 -Download    pre-download the installers with winget (no install)
param([switch]$Check, [switch]$Download)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$pkgs = @("Microsoft.VisualStudio.2022.BuildTools", "Kitware.CMake", "Git.Git", "Ninja-build.Ninja")
$hint = "winget install --id Microsoft.VisualStudio.2022.BuildTools --override `"--add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --passive`"; winget install Kitware.CMake Git.Git Ninja-build.Ninja"
if ($Download) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) { Write-Warning "winget not found; download by hand: $hint"; return }
    $dir = Join-Path (Split-Path -Parent $PSScriptRoot) ".cache\predownload\winget"
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    foreach ($p in $pkgs) { winget download --id $p --download-directory $dir --accept-package-agreements --accept-source-agreements | Out-Host }
    return
}
$missing = @()
foreach ($t in @("cmake", "git")) { if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { $missing += $t } }
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
$vc = if (Test-Path $vswhere) { & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath } else { $null }
if (-not $vc) { $missing += "MSVC (Visual Studio 2022 C++ build tools)" }
if ($missing.Count -gt 0) {
    $msg = "prereqs: missing: $($missing -join ', '). Install with: $hint (offline later? run scripts\predownload.ps1 first)"
    if ($Check) { throw $msg } else { Write-Warning $msg }
}
