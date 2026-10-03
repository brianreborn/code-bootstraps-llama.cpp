# code-bootstraps-llama.cpp: Windows launcher (STUB, untested on Windows).
# Same behaviour as scripts/serve.sh: router mode on 127.0.0.1, API key file,
# built-in tools + MCP given to the router through LLAMA_ARG_* env vars.
#   powershell -ExecutionPolicy Bypass -File scripts\serve.ps1 [-ToolsRuntime auto|host|docker-container:<id>|ssh:<target>]
param(
    [string]$BindHost = "127.0.0.1",
    [int]$Port = 9931,
    [int]$ModelsMax = 2,
    [string]$ToolsRuntime = "auto",
    [string]$ToolsImage = "docker.io/library/python:3.12-slim",
    [string]$WorkDir = "",
    [string]$Tools = "read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info",
    [string]$McpConfig = "",
    [string]$Threads = "auto",        # generation threads: auto = physical cores
    [string]$ThreadsBatch = "auto",   # prompt/batch threads: auto = logical CPUs
    [string]$GpuLayers = "auto",      # -ngl auto + --fit on: GPU if a backend DLL finds one, else CPU
    [ValidateSet("on", "off")][string]$Repack = "on",
    [string]$LoadMode = "auto"
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
if (-not $WorkDir) { $WorkDir = Join-Path $Root "workspace" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

$bin = Get-ChildItem -Path $Root -Filter llama-server.exe -Recurse -ErrorAction SilentlyContinue |
       Where-Object { $_.FullName -match '\\build[^\\]*\\bin\\' } | Select-Object -First 1
if (-not $bin) { throw "llama-server.exe not found; run scripts\build-windows.ps1 first" }

# CPU topology (physical cores vs logical processors)
$cpus = Get-CimInstance Win32_Processor
if ($Threads -eq "auto")      { $Threads = ($cpus | Measure-Object -Property NumberOfCores -Sum).Sum }
if ($ThreadsBatch -eq "auto") { $ThreadsBatch = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum }

# API key file, generated once (.secrets\ is git-ignored)
$keyFile = Join-Path $Root ".secrets\api-keys"
if (-not (Test-Path $keyFile)) {
    New-Item -ItemType Directory -Force -Path (Split-Path $keyFile) | Out-Null
    $bytes = New-Object byte[] 24; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    @("# llama-server API key(s), one per line", (($bytes | ForEach-Object { $_.ToString("x2") }) -join "")) | Set-Content -Encoding ascii $keyFile
    Write-Host "serve.ps1: generated API key in $keyFile"
}

# MCP: the example server needs Python on PATH
if (-not $McpConfig) {
    if (Get-Command python3 -ErrorAction SilentlyContinue) { $McpConfig = "config\mcp-servers.json" }
    else { Write-Warning "python3 not on PATH: MCP example disabled (config\mcp-servers.empty.json)"; $McpConfig = "config\mcp-servers.empty.json" }
}

# Tools runtime: Docker Desktop if it answers, else the host (with a loud warning)
$container = $null; $runtime = ""
if ($ToolsRuntime -eq "auto") {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) { docker info *> $null; if ($LASTEXITCODE -ne 0) { $docker = $null } }
    if ($docker) {
        $container = (docker run -d --rm -v "${WorkDir}:/work" -w /work $ToolsImage sleep infinity).Trim()
        $runtime = "docker-container:$container"
    } else {
        Write-Warning "no working Docker: tools run on the HOST with this user's permissions (read/write/execute anything this account can). Use -Tools '' to disable."
    }
} elseif ($ToolsRuntime -ne "host") { $runtime = $ToolsRuntime }

# Router-only options go through the environment, see the note in scripts/serve.sh
Remove-Item Env:LLAMA_ARG_TOOLS, Env:LLAMA_ARG_TOOLS_RUNTIME, Env:LLAMA_ARG_MCP_SERVERS_CONFIG -ErrorAction SilentlyContinue
if ($Tools)   { $env:LLAMA_ARG_TOOLS = $Tools }
if ($runtime) { $env:LLAMA_ARG_TOOLS_RUNTIME = $runtime }
if ($McpConfig) { $env:LLAMA_ARG_MCP_SERVERS_CONFIG = $McpConfig }

$srvArgs = @("--host", $BindHost, "--port", $Port, "--api-key-file", $keyFile,
          "--models-dir", (Join-Path $Root "models"), "--models-preset", (Join-Path $Root "config\models-preset.ini"),
          "--models-max", $ModelsMax,
          "--threads", $Threads, "--threads-batch", $ThreadsBatch,
          "--n-gpu-layers", $GpuLayers, "--fit", "on", "--load-mode", $LoadMode)
if ($Repack -eq "off") { $srvArgs += "--no-repack" }
Write-Host "serve.ps1: $($bin.FullName) $($srvArgs -join ' ')"
try { & $bin.FullName @srvArgs } finally { if ($container) { docker rm -f $container *> $null } }
