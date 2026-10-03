# Click-and-go launcher for Windows (start.bat runs this). UNTESTED on Windows.
# 1. llama.cpp: the official release pinned in config\llama-release.json (sha256-checked),
#    else a build with scripts\build-windows.ps1 when cmake is installed.
# 2. models: the default set from config\models-manifest.json (sha256-checked).
# 3. scripts\serve.ps1: router with tools and an API key.
# 4. opens the built-in web UI once the server answers (API key copied to the clipboard).
# Close the window (or Ctrl-C) to stop. Settings: -Port, -Variant cpu|vulkan|cuda-12|cuda-13,
# -NoBrowser, -Build; other serve.ps1 parameters can follow.
param(
    [int]$Port = $(if ($env:PORT) { [int]$env:PORT } else { 9931 }),
    [string]$Variant = $(if ($env:VARIANT) { $env:VARIANT } else { "cpu" }),
    [switch]$NoBrowser,
    [switch]$Build,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ServeArgs = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
if ($env:NO_BROWSER -eq "1") { $NoBrowser = $true }

# a port something already answers on (another llama-server, ...) -> the next free one
function Test-PortBusy([int]$p) {
    $c = New-Object System.Net.Sockets.TcpClient
    try { $c.ConnectAsync("127.0.0.1", $p).Wait(300) -and $c.Connected } catch { $false } finally { $c.Close() }
}
if (Test-PortBusy $Port) {
    $p = $Port; for ($i = 1; $i -le 20 -and (Test-PortBusy $p); $i++) { $p = $Port + $i }
    if (Test-PortBusy $p) { throw "ports $Port-$p are all in use; pass -Port" }
    Write-Host "start: port $Port is in use, using $p"; $Port = $p
}

# --- 1. llama-server ---------------------------------------------------------
$server = $null
if (-not $Build) {
    $global:LASTEXITCODE = 0
    try { $out = & (Join-Path $PSScriptRoot "fetch-llama.ps1") -Variant $Variant } catch { Write-Warning $_; $out = $null; $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -eq 0 -and $out) { $server = @($out)[-1] }
}
if (-not $server) {
    Write-Host "start: no usable release binary; building from source (needs git, cmake and Visual Studio C++)"
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw "cmake not found: install it with Visual Studio C++, or use a platform listed in config\llama-release.json" }
    & (Join-Path $PSScriptRoot "build-windows.ps1")
    $server = Join-Path $Root "build-windows-x64\bin\Release\llama-server.exe"
}

# --- 2. models ---------------------------------------------------------------
& (Join-Path $PSScriptRoot "fetch-models.ps1")

# --- 4. web UI: a helper in this console waits for the server, copies the key, opens the browser
$self = (Get-Process -Id $PID).Path   # powershell.exe or pwsh
$opener = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", (Join-Path $PSScriptRoot "lib\open-ui.ps1"), "-Port", $Port, "-ParentPid", $PID)
if ($NoBrowser) { $opener += "-NoBrowser" }
Start-Process -FilePath $self -ArgumentList $opener -NoNewWindow | Out-Null

# --- 3. server (foreground) ----------------------------------------------------
& (Join-Path $PSScriptRoot "serve.ps1") -Port $Port -LlamaServer $server @ServeArgs
