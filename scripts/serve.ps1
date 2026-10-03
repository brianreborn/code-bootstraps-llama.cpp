# code-bootstraps-llama.cpp: Windows launcher (UNTESTED on Windows).
# Same behaviour as scripts/serve.sh: router mode on 127.0.0.1, API key through
# LLAMA_API_KEY (children inherit it), tools + MCP given to the router only through
# LLAMA_ARG_* env vars, profile overlay and the optional language slot.
#   powershell -ExecutionPolicy Bypass -File scripts\serve.ps1 [-ToolsRuntime auto|host|docker-container:<id>|ssh:<target>] [-- extra llama-server args]
param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 9931,
    [ValidateSet("auto", "default", "lowram")][string]$RamProfile = "auto",   # auto: lowram under 6 GB RAM
    [int]$ModelsMax = 0,                  # 0 = profile default (2, lowram 1)
    [string]$ToolsRuntime = "auto",
    # python:3.12-slim multi-arch index, pinned by digest (2026-10-03)
    [string]$ToolsImage = "docker.io/library/python:3.12-slim@sha256:dddfd7e07f9d15aeeca61529320492139d21cac7f0070c00609243e51e4e0016",
    [string]$WorkDir = "",
    [string]$Tools = "read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info",
    [string]$McpConfig = "",
    [string]$Threads = "auto",        # generation threads: auto = physical cores
    [string]$ThreadsBatch = "auto",   # prompt/batch threads: auto = logical CPUs
    [string]$GpuLayers = "auto",      # -ngl auto + --fit on: GPU if a backend DLL finds one, else CPU
    [ValidateSet("on", "off")][string]$Repack = "on",
    [string]$LoadMode = "auto",
    # languages (README "Languages"): Locale auto = Windows culture (Get-Culture); LanguageMode native (default),
    # swap (locale model as general), interpret (opt-in HY-MT, license not valid in EU/UK/South Korea), off
    [string]$Locale = $(if ($env:LOCALE) { $env:LOCALE } else { "auto" }),
    [ValidateSet("native", "swap", "interpret", "off")][string]$LanguageMode = $(if ($env:LANGUAGE_MODE) { $env:LANGUAGE_MODE } else { "native" }),
    [switch]$SwapCoder,               # swap mode: also replace the coder with the locale model
    [string]$LlamaServer = "",        # explicit path to llama-server.exe
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
if (-not $WorkDir) { $WorkDir = Join-Path $Root "workspace" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

# refuse pass-through args that would widen what the instances can do (see serve.sh)
foreach ($a in $Extra) {
    if ($a -match '^(--tools(-runtime)?(=.*)?|-ag|--(no-)?agent|--mcp-.*|--(no-)?(web)?ui-mcp-proxy.*|--api-key.*|--models-preset.*)$') {
        throw "argument '$a' is not allowed here; use -Tools / -ToolsRuntime / -McpConfig"
    }
}

# llama-server.exe: explicit path, else the Release output of scripts\build-windows.ps1
if (-not $LlamaServer) { $LlamaServer = Join-Path $Root "build-windows-x64\bin\Release\llama-server.exe" }
if (-not (Test-Path $LlamaServer -PathType Leaf)) { throw "llama-server.exe not found at $LlamaServer; run scripts\build-windows.ps1 or pass -LlamaServer" }

# CPU topology (physical cores vs logical processors) and RAM
$cpus = Get-CimInstance Win32_Processor
if ($Threads -eq "auto")      { $Threads = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum }
if ($ThreadsBatch -eq "auto") { $ThreadsBatch = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum }
$memMB = [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB)
if ($RamProfile -eq "auto") { $RamProfile = if ($memMB -lt 6144) { "lowram" } else { "default" } }
$overlay = @{}
if ($RamProfile -eq "lowram") {
    if ($ModelsMax -eq 0) { $ModelsMax = 1 }
    $overlay = @{ "coder.parallel" = "2"; "coder.ctx-size" = "16384"; "coder.kv-unified-per-slot" = "16384";
                  "general.parallel" = "1"; "general.ctx-size" = "8192"; "decision.parallel" = "1"; "decision.ctx-size" = "4096";
                  "language.parallel" = "1"; "language.ctx-size" = "4096" }
} elseif ($ModelsMax -eq 0) { $ModelsMax = 2 }

# language: locale -> primary language code; swap / interpret / off (same rules as serve.sh)
$presetPath = Join-Path $Root "config\models-preset.ini"
$presetLines = Get-Content $presetPath
if ($Locale -eq "auto") { $Locale = (Get-Culture).Name }          # e.g. ja-JP
$langCode = ($Locale -split '[-_.@]')[0].ToLower()
if (-not $langCode -or $langCode -in @("c", "posix")) { $langCode = "en" }
function Get-LocaleModel([string]$role) {
    $sec = ""
    foreach ($l in $presetLines) {
        if ($l -match '^\[(.*)\]') { $sec = $Matches[1]; continue }
        if ($sec -eq "locale.$langCode.$role" -and $l -match '^model\s*=\s*(.+)$') {
            $f = $Matches[1].Trim(); if (-not [System.IO.Path]::IsPathRooted($f)) { $f = Join-Path $Root $f }
            if (Test-Path $f -PathType Leaf) { return $f } else { return $null }
        }
    }
    return $null
}
$langModel = $null; $swapRoles = @(); $mode = $LanguageMode
if ($langCode -eq "en" -or $mode -eq "off") { $mode = "off" } else {
    $langFile = Get-ChildItem -Path (Join-Path $Root "models-optional\language") -Filter *.gguf -ErrorAction SilentlyContinue | Select-Object -First 1
    $swapOk = [bool](Get-LocaleModel "general")
    if ($mode -eq "swap") {
        if (-not $swapOk) { throw "LanguageMode swap: no installed model for [locale.$langCode.general]" }
        $swapRoles = @("general")
        if ($SwapCoder) { if (Get-LocaleModel "coder") { $swapRoles += "coder"; Write-Warning "-SwapCoder: the coder role now uses the locale model; it must emit tool calls (the ja model made 0 in 12 agent runs, see README Languages)" } else { Write-Warning "-SwapCoder: no installed [locale.$langCode.coder] model" } }
    }
    if ($mode -eq "interpret") {
        if (-not $langFile) { throw "LanguageMode interpret: no .gguf in models-optional\language" }
        $langModel = $langFile
    }
}
# keys of [locale.<lang>.<role>] for the swapped roles
$localeKeys = @{}; $localeOrder = @{}; $sec = ""
foreach ($l in $presetLines) {
    if ($l -match '^\[(.*)\]') { $sec = $Matches[1]; continue }
    $p = $sec -split '\.'
    if ($p.Count -eq 3 -and $p[0] -eq "locale" -and $p[1] -eq $langCode -and $swapRoles -contains $p[2] -and $l -match '^([A-Za-z0-9_-]+)\s*=\s*(.*)$') {
        $k = $Matches[1]; $v = $Matches[2].Trim()
        if ($k -eq "model" -and -not [System.IO.Path]::IsPathRooted($v)) { $v = Join-Path $Root $v }
        $localeKeys["$($p[2]).$k"] = $v
        if (-not $localeOrder.ContainsKey($p[2])) { $localeOrder[$p[2]] = New-Object System.Collections.Generic.List[string] }
        $localeOrder[$p[2]].Add($k)
    }
}

# effective preset (same rules as the awk filter in serve.sh)
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache") | Out-Null
$effective = Join-Path $Root ".cache\models-preset.effective.ini"
$out = New-Object System.Collections.Generic.List[string]; $sec = ""; $skip = $false; $seen = @{}
function Close-Section {
    if ($script:sec -eq "" -or $script:skip) { return }
    if ($localeOrder.ContainsKey($script:sec)) { foreach ($k in $localeOrder[$script:sec]) { if (-not $seen.ContainsKey("$($script:sec).$k")) { $out.Add("$k = $($localeKeys["$($script:sec).$k"])") } } }
    foreach ($k in $overlay.Keys) { if ($k.StartsWith("$($script:sec).") -and -not $seen.ContainsKey($k)) { $out.Add("$($k.Substring($script:sec.Length + 1)) = $($overlay[$k])") } }
    if ($script:sec -eq "language" -and $langModel) { $out.Add("model = $($langModel.FullName)") }
}
$script:sec = ""
foreach ($line in $presetLines) {
    if ($line -match '^\[(.*)\]') { Close-Section; $script:sec = $Matches[1]; $script:skip = ($script:sec -like "locale.*") -or ($script:sec -eq "language" -and -not $langModel); if (-not $script:skip) { $out.Add($line) }; continue }
    if ($script:skip) { continue }
    if ($line -match '^([A-Za-z0-9_-]+)\s*=') { $key = "$($script:sec).$($Matches[1])"
        if ($localeKeys.ContainsKey($key)) { $out.Add("$($Matches[1]) = $($localeKeys[$key])"); $seen[$key] = $true; continue }
        if ($overlay.ContainsKey($key)) { $out.Add("$($Matches[1]) = $($overlay[$key])"); $seen[$key] = $true; continue } }
    $out.Add($line)
}
Close-Section
Set-Content -Encoding utf8 -Path $effective -Value $out
# for scripts/agent.py: what the server was started with
@{ locale = $langCode; mode = $mode; swapped = ($swapRoles -join " ") } | ConvertTo-Json -Compress | Set-Content -Encoding utf8 (Join-Path $Root ".cache\language.json")

# API key file, generated once (.secrets\ is git-ignored), readable by this user only
$keyDir = Join-Path $Root ".secrets"; $keyFile = Join-Path $keyDir "api-keys"
New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
if (-not (Test-Path $keyFile)) {
    $bytes = New-Object byte[] 24; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    @("# llama-server API key(s), one per line", (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")) | Set-Content -Encoding ascii $keyFile
    Write-Host "serve.ps1: generated API key in $keyFile"
}
# remove inherited ACLs, grant only the current user
icacls $keyDir /inheritance:r /grant:r "$($env:USERNAME):(OI)(CI)F" | Out-Null
icacls $keyFile /inheritance:r /grant:r "$($env:USERNAME):F" | Out-Null
$keys = (Get-Content $keyFile | Where-Object { $_ -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() }) -join ","
if (-not $keys) { throw "no key in $keyFile" }

# MCP: the example server needs a working Python (the Store alias "python3" may exist but not run)
if (-not $McpConfig) {
    $py = $false
    try { & python3 -c "import sys" 2>$null; $py = ($LASTEXITCODE -eq 0) } catch { $py = $false }
    if ($py) { $McpConfig = "config\mcp-servers.json" }
    else { Write-Warning "python3 does not run: MCP example disabled (config\mcp-servers.empty.json)"; $McpConfig = "config\mcp-servers.empty.json" }
}

# Tools runtime: Docker Desktop if it answers, else the host (with a loud warning)
$container = $null; $runtime = ""
if ($ToolsRuntime -eq "auto") {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) { docker info *> $null; if ($LASTEXITCODE -ne 0) { $docker = $null } }
    if ($docker) {
        $container = (docker run -d --rm -v "${WorkDir}:/work" -w /work $ToolsImage sleep infinity).Trim()
        if ($LASTEXITCODE -ne 0) { throw "docker run failed" }
        $runtime = "docker-container:$container"
    } else {
        Write-Warning "no working Docker: tools run on the HOST with this user's permissions (read/write/execute anything this account can). Use -Tools '' to disable."
    }
} elseif ($ToolsRuntime -ne "host") { $runtime = $ToolsRuntime }

# Only the LLAMA_* variables set here reach llama-server (router and children read them)
Get-ChildItem Env: | Where-Object { $_.Name -like "LLAMA_ARG_*" -or $_.Name -eq "LLAMA_API_KEY" } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$env:LLAMA_API_KEY = $keys
if ($Tools)     { $env:LLAMA_ARG_TOOLS = $Tools }
if ($runtime)   { $env:LLAMA_ARG_TOOLS_RUNTIME = $runtime }
if ($McpConfig) { $env:LLAMA_ARG_MCP_SERVERS_CONFIG = $McpConfig }

$srvArgs = @("--host", $BindHost, "--port", $Port,
          "--models-dir", (Join-Path $Root "models"), "--models-preset", $effective,
          "--models-max", $ModelsMax,
          "--threads", $Threads, "--threads-batch", $ThreadsBatch,
          "--n-gpu-layers", $GpuLayers, "--fit", "on", "--load-mode", $LoadMode)
if ($Repack -eq "off") { $srvArgs += "--no-repack" }
$srvArgs += $Extra
Write-Host "serve.ps1: $LlamaServer $($srvArgs -join ' ')"
Write-Host "serve.ps1: profile=$RamProfile (RAM $memMB MB) language: locale=$langCode mode=$mode swapped=[$($swapRoles -join ' ')] language-slot=$(if ($langModel) { $langModel.FullName } else { '-' })"
try { & $LlamaServer @srvArgs } finally { if ($container) { docker rm -f $container *> $null } }
