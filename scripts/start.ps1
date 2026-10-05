# Click-and-go launcher for Windows (start.bat runs this). Windows PowerShell 5.1 and PowerShell 7.
# 1. llama.cpp: the official release pinned in config\llama-release.json (sha256-checked),
#    else a build with scripts\build-windows.ps1 when cmake is installed.
# 2. models: the default set from config\models-manifest.json (sha256-checked).
# 3. scripts\serve.ps1: router with tools and an API key.
# 4. opens the built-in web UI once serve.ps1 reports it ready (-CopyKey: key to the clipboard).
# Close the window (or Ctrl-C) to stop. Settings: -Port, -Variant cpu|vulkan|cuda-12|cuda-13,
# -NoBrowser, -Build, -CopyKey; serve.ps1 parameters can follow (-RamProfile lowram,
# -ModelsMax, -Tools, ...), and anything else goes to llama-server (e.g. --ctx-size 8192).
# Environment variables (PORT, VARIANT, PROFILE, TOOLS, LOCALE, RAISE, ...) work as in start.sh.
# On Windows this also asks once for "Lock pages in memory" (scripts\raise.ps1). One command.
[CmdletBinding(PositionalBinding = $false)]
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
. (Join-Path $PSScriptRoot "lib\common.ps1")
$panelPrior = @{
    PORT = [Environment]::GetEnvironmentVariable("PORT")
    VARIANT = [Environment]::GetEnvironmentVariable("VARIANT")
}
Import-PanelEnv $Root
Use-PanelValue "Port" "PORT" ($PSBoundParameters.ContainsKey("Port")) ([string]$panelPrior["PORT"])
Use-PanelValue "Variant" "VARIANT" ($PSBoundParameters.ContainsKey("Variant")) ([string]$panelPrior["VARIANT"])
Publish-BoundParam "Port" "PORT" ($PSBoundParameters.ContainsKey("Port"))
Publish-BoundParam "Variant" "VARIANT" ($PSBoundParameters.ContainsKey("Variant"))
$serveScript = Join-Path $PSScriptRoot "serve.ps1"
$serveParams = (Get-Command $serveScript).Parameters
Assert-NoDoubleDashParam @($MyInvocation.MyCommand.Parameters.Keys) "start.ps1" $PSCommandPath
if ($env:NO_BROWSER -eq "1") { $NoBrowser = $true }

# One administrator prompt. The stamp is written here, as this user, only after
# success. The elevated child does not write it (it would be owned by Administrator).
$RaiseScript = Join-Path $PSScriptRoot "raise.ps1"
function Invoke-RaiseOnce {
    if ($env:RAISE -eq "0") { return }
    $win = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    if (-not $win) { return }
    $stamp = Join-Path $Root ".cache\raise.stamp"
    if ($env:RAISE -ne "1" -and (Test-Path -LiteralPath $stamp)) { return }
    $have = $false
    try {
        $priv = & whoami.exe /priv 2>$null
        if ($priv -match "SeLockMemoryPrivilege") { $have = $true }
    } catch {
        $have = $false
    }
    if ($have -and $env:RAISE -ne "1") {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stamp) | Out-Null
        Set-Content -LiteralPath $stamp -Value "ok" -Encoding ascii
        return
    }
    Write-Host "start: Asking once for permission to allow memory locking. Sign in again afterwards."
    $ok = $true
    try {
        & $RaiseScript
        if (-not $?) { $ok = $false }
    } catch {
        $ok = $false
    }
    if (-not $ok) {
        Write-Host "start: Memory locking was not granted. The server still starts. Set RAISE=0 to stop asking."
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $stamp) | Out-Null
    Set-Content -LiteralPath $stamp -Value "ok" -Encoding ascii
}
Invoke-RaiseOnce

# --- 1. llama-server ---------------------------------------------------------
$server = $null
if (-not $Build) {
    $global:LASTEXITCODE = 0; $err = ""
    try { $out = & (Join-Path $PSScriptRoot "fetch-llama.ps1") -Variant $Variant } catch { $err = $_.ToString(); $out = $null; $global:LASTEXITCODE = 1 }
    if ($LASTEXITCODE -eq 0 -and $out) { $server = @($out)[-1] }
    # 3 = no release binary for this machine, or it does not run here (missing VC++ runtime?);
    # anything else is a failed download, checksum or script error, which a source build would not fix
    elseif ($LASTEXITCODE -ne 3) {
        if (-not $err) { $err = "exit code $LASTEXITCODE" }
        $hint = if ($err -match 'curl exit (6|7|28|35|56)|could not be resolved|Unable to connect|No such host') { " Check the internet connection and run start.bat again." } else { "" }
        throw "setting up llama.cpp failed (scripts\fetch-llama.ps1): $err$hint"
    }
}
if (-not $server) {
    Write-Host "start: no usable release binary; building from source (needs git, cmake and Visual Studio C++)"
    if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) { throw "cmake not found: install it with Visual Studio C++, or use a platform listed in config\llama-release.json" }
    & (Join-Path $PSScriptRoot "build-windows.ps1")
    $server = Join-Path $Root "build-windows-x64\bin\Release\llama-server.exe"
}

# --- 2. models ---------------------------------------------------------------
try { & (Join-Path $PSScriptRoot "fetch-models.ps1") } catch {
    $e = $_.ToString()
    if ($e -match 'curl exit (6|7)\b|could not be resolved|Unable to connect|No such host') {
        throw "cannot reach huggingface.co (offline, or a firewall/proxy blocks it): connect to the internet and run start.bat again; a partial download resumes. ($e)"
    }
    throw
}

# a port that cannot be bound on 127.0.0.1, or that anything accepts connections on, is
# busy -> the next free one (serve.ps1 then prints the port it uses). Checked after the
# downloads, right before the server starts.
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

# --- 4. web UI: a helper in this console waits for serve.ps1's ready file, opens the browser
Remove-Item -Force -LiteralPath (Join-Path $Root ".cache\serve.ready") -ErrorAction SilentlyContinue
$self = (Get-Process -Id $PID).Path   # powershell.exe or pwsh
# one command-line string with the script path in quotes: Start-Process joins an array with
# spaces without quoting, which breaks on C:\Users\Jane Doe\...
$opener = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Port {1} -ParentPid {2}' -f (Join-Path $PSScriptRoot "lib\open-ui.ps1"), $Port, $PID
if ($NoBrowser) { $opener += " -NoBrowser" }
if ($CopyKey -or $env:COPY_KEY -eq "1") { $opener += " -CopyKey" }
Start-Process -FilePath $self -ArgumentList $opener -NoNewWindow | Out-Null

# --- 3. server (foreground) ----------------------------------------------------
# "-Name value" / "-Switch" for a serve.ps1 parameter become named parameters (an array splat
# would pass them positionally); everything else (llama-server "--flags" and their values)
# goes to serve.ps1's -Extra, where its refusal list applies.
$named = @{ Port = $Port; LlamaServer = $server }; $extra = New-Object System.Collections.Generic.List[string]
for ($i = 0; $i -lt $ServeArgs.Count; $i++) {
    $t = $ServeArgs[$i]
    $p = $null
    if ($t -match '^-([A-Za-z][A-Za-z0-9]*):?$') {
        $name = $Matches[1]
        $hits = @($serveParams.Keys | Where-Object { $_ -eq $name })
        if ($hits.Count -eq 0) { $hits = @($serveParams.Keys | Where-Object { $_ -like "$name*" }) }   # PowerShell prefix match
        # an ambiguous prefix (-m: -ModelsMax or -McpConfig?) goes to -Extra like any llama-server flag
        if ($hits.Count -eq 1 -and $hits[0] -ne "Extra") { $p = $serveParams[$hits[0]] }
    }
    if (-not $p) { $extra.Add($t); continue }
    if ($p.ParameterType -eq [switch]) { $named[$p.Name] = $true }
    elseif ($i + 1 -lt $ServeArgs.Count) { $named[$p.Name] = $ServeArgs[$i + 1]; $i++ }   # a value may start with "-" (-GpuLayers -1)
    else { throw "start.ps1: -$($p.Name) needs a value" }
}
if ($extra.Count -gt 0) { $named["Extra"] = $extra.ToArray() }
& $serveScript @named
