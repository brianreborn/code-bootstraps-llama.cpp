# Click-and-go launcher for Windows (start.bat runs this). UNTESTED on Windows.
# 1. llama.cpp: the official release pinned in config\llama-release.json (sha256-checked),
#    else a build with scripts\build-windows.ps1 when cmake is installed.
# 2. models: the default set from config\models-manifest.json (sha256-checked).
# 3. scripts\serve.ps1: router with tools and an API key.
# 4. opens the built-in web UI once the server answers (API key copied to the clipboard).
# Close the window (or Ctrl-C) to stop. Settings: -Port, -Variant cpu|vulkan|cuda-12|cuda-13,
# -NoBrowser, -Build, -CopyKey; other serve.ps1 parameters can follow (-RamProfile lowram,
# -ModelsMax, -Tools, ...).
param(
    [int]$Port = $(if ($env:PORT) { [int]$env:PORT } else { 9931 }),
    [string]$Variant = $(if ($env:VARIANT) { $env:VARIANT } else { "cpu" }),
    [switch]$NoBrowser,
    [switch]$Build,
    [switch]$CopyKey,                 # also copy the API key to the clipboard (opt-in: clipboard history)
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$ServeArgs = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
if ($env:NO_BROWSER -eq "1") { $NoBrowser = $true }

# a port that cannot be bound on 127.0.0.1, or that anything accepts connections on, is
# busy -> the next free one (serve.ps1 then prints the port it uses)
function Test-PortBusy([int]$p) {
    $l = New-Object System.Net.Sockets.TcpListener ([System.Net.IPAddress]::Loopback, $p)
    $l.ExclusiveAddressUse = $true
    try { $l.Start() } catch { return $true } finally { try { $l.Stop() } catch { } }
    $c = New-Object System.Net.Sockets.TcpClient   # e.g. a listener on 0.0.0.0 that Windows lets us shadow
    try { return ($c.ConnectAsync("127.0.0.1", $p).Wait(300) -and $c.Connected) } catch { return $false } finally { $c.Close() }
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
if ($CopyKey -or $env:COPY_KEY -eq "1") { $opener += "-CopyKey" }
Start-Process -FilePath $self -ArgumentList $opener -NoNewWindow | Out-Null

# --- 3. server (foreground) ----------------------------------------------------
# "-Name value" / "-Switch" pairs become named serve.ps1 parameters (an array splat would pass
# them positionally); anything else (llama-server "--flags") goes to serve.ps1's pass-through
$named = @{ Port = $Port; LlamaServer = $server }; $rest = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $ServeArgs.Count; $i++) {
    $t = $ServeArgs[$i]
    if ($t -match '^-([A-Za-z][A-Za-z0-9]*)$') {
        $name = $Matches[1]
        if ($i + 1 -lt $ServeArgs.Count -and $ServeArgs[$i + 1] -notmatch '^-') { $named[$name] = $ServeArgs[$i + 1]; $i++ }
        else { $named[$name] = $true }
    } else { $rest.Add($t) }
}
$restArgs = $rest.ToArray()
& (Join-Path $PSScriptRoot "serve.ps1") @named @restArgs
