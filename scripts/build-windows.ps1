# Portable Release build of the pinned llama.cpp on Windows (x64, Visual Studio 2022 or Build Tools).
#   powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1   -> build-windows-x64\bin\Release\
# Run from a "Developer PowerShell for VS" (or any shell with cmake + MSVC on PATH).
param(
    [string]$BuildDir = "build-windows-x64",
    [int]$Jobs = [Environment]::ProcessorCount,
    [switch]$Native,
    # off (default) | auto | vulkan | cuda. auto: cuda if nvcc is on PATH, else vulkan if VULKAN_SDK is set.
    # The GPU backend is built as a loadable DLL (GGML_BACKEND_DL): one package, GPU or CPU at runtime. UNTESTED.
    [ValidateSet("off", "auto", "vulkan", "cuda")][string]$Gpu = "off"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root

$pin = @{}
Get-Content "config\llama-pin.env" | Where-Object { $_ -match '^\s*[A-Z_]+=' } | ForEach-Object {
    $k, $v = $_ -split '=', 2; $pin[$k.Trim()] = $v.Trim()
}
if (-not (Test-Path "llama.cpp\CMakeLists.txt")) { git submodule update --init --recursive }
$actual = (git -C llama.cpp rev-parse HEAD).Trim()
if ($actual -ne $pin.LLAMA_COMMIT) { Write-Warning "llama.cpp is at $actual, pin is $($pin.LLAMA_TAG) ($($pin.LLAMA_COMMIT))" }

# pin the prebuilt web UI to the same release instead of falling back to "latest"
$env:HF_UI_VERSION = $pin.LLAMA_TAG

$cmakeArgs = @("-S", "llama.cpp", "-B", $BuildDir, "-DLLAMA_BUILD_NUMBER=$($pin.LLAMA_BUILD_NUMBER)")
if ($Native) {
    $cmakeArgs += "-DGGML_NATIVE=ON"
} else {
    # one build for every x64 CPU: the best CPU backend DLL is picked at runtime
    $cmakeArgs += @("-DGGML_NATIVE=OFF", "-DGGML_BACKEND_DL=ON", "-DGGML_CPU_ALL_VARIANTS=ON")
}

if ($Gpu -eq "auto") {
    if (Get-Command nvcc -ErrorAction SilentlyContinue) { $Gpu = "cuda" }
    elseif ($env:VULKAN_SDK) { $Gpu = "vulkan" }
    else { $Gpu = "off"; Write-Warning "-Gpu auto found no CUDA (nvcc) or Vulkan SDK (VULKAN_SDK); CPU only" }
}
if ($Gpu -eq "vulkan") { $cmakeArgs += "-DGGML_VULKAN=ON" }
if ($Gpu -eq "cuda")   { $cmakeArgs += "-DGGML_CUDA=ON" }
Write-Host "build-windows.ps1: gpu=$Gpu native=$Native jobs=$Jobs dir=$BuildDir"

cmake @cmakeArgs
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed" }
# Visual Studio is a multi-config generator: the build type is chosen here, not at configure time
cmake --build $BuildDir --config Release -j $Jobs
if ($LASTEXITCODE -ne 0) { throw "cmake build failed" }
& "$BuildDir\bin\Release\llama-server.exe" --version
