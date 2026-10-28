# code-bootstraps-llama.cpp: Windows launcher (Windows PowerShell 5.1 and PowerShell 7).
# Same behaviour as scripts/serve.sh: router mode on 127.0.0.1, API key through
# LLAMA_API_KEY (children inherit it), tools + MCP given to the router only through
# LLAMA_ARG_* env vars, every role pinned to one sha256-checked file, profile overlay and
# the optional language slot.
#   powershell -ExecutionPolicy Bypass -File scripts\serve.ps1 [-RamProfile lowram] [-Tools lean] [-ToolsRuntime auto|host|docker-container:<id>|ssh:<target>] [llama-server flags, e.g. --ctx-size 8192]
# Parameters default to the environment variables serve.sh reads (PORT, HOST, PROFILE,
# MODELS_MAX, TOOLS, TOOLS_RUNTIME, THREADS, THREADS_BATCH, GPU_LAYERS, REPACK, LOAD_MODE,
# WORKDIR, MCP_CONFIG, LOCALE, LANGUAGE_MODE, SWAP_CODER, REASONING, LLAMA_SERVER, MODELS_PRESET,
# MANIFEST, MODELS_DIR, LANGUAGE_DIR); a parameter given on the command line wins.
# Extra llama-server flags apply to EVERY role; flags that pick a model, tools, MCP or the key
# are refused (see serve.sh).
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$BindHost = $(if ($env:HOST) { $env:HOST } else { "127.0.0.1" }),
    [int]$Port = $(if ($env:PORT) { [int]$env:PORT } else { 9931 }),
    [string]$RamProfile = $(if ($env:PROFILE) { $env:PROFILE } else { "auto" }),   # auto | lowram | moderate | default (README "Light tuning")
    [int]$ModelsMax = $(if ($env:MODELS_MAX) { [int]$env:MODELS_MAX } else { 0 }),   # general/coder kept loaded: 0 = profile default 2; decision stays loaded on top (not lowram)
    [string]$ToolsRuntime = $(if ($env:TOOLS_RUNTIME) { $env:TOOLS_RUNTIME } else { "auto" }),
    # python:3.12-slim multi-arch index, pinned by digest (2026-10-03)
    [string]$ToolsImage = $(if ($env:TOOLS_IMAGE) { $env:TOOLS_IMAGE } else { "docker.io/library/python:3.12-slim@sha256:dddfd7e07f9d15aeeca61529320492139d21cac7f0070c00609243e51e4e0016" }),
    [string]$WorkDir = $(if ($env:WORKDIR) { $env:WORKDIR } else { "" }),
    [string]$Tools = $(if ($null -ne $env:TOOLS) { $env:TOOLS } else { "auto" }),   # auto (full; lean on lowram) | full | lean | comma list | "" (none)
    [string]$McpConfig = $(if ($env:MCP_CONFIG) { $env:MCP_CONFIG } else { "" }),
    [string]$Threads = $(if ($env:THREADS) { $env:THREADS } else { "auto" }),               # generation threads: auto = physical cores
    [string]$ThreadsBatch = $(if ($env:THREADS_BATCH) { $env:THREADS_BATCH } else { "auto" }), # prompt/batch threads: auto = logical CPUs
    [string]$GpuLayers = $(if ($env:GPU_LAYERS) { $env:GPU_LAYERS } else { "auto" }),        # -ngl auto + --fit on: GPU if a backend DLL finds one, else CPU
    [string]$Repack = $(if ($env:REPACK) { $env:REPACK } else { "on" }),
    [string]$LoadMode = $(if ($env:LOAD_MODE) { $env:LOAD_MODE } else { "" }),
    # languages (README "Languages"): Locale auto = Windows culture (Get-Culture); LanguageMode native (default; auto = native),
    # swap (locale model as general), interpret (opt-in HY-MT, license not valid in EU/UK/South Korea), off
    [string]$Locale = $(if ($env:LOCALE) { $env:LOCALE } else { "auto" }),
    [string]$LanguageMode = $(if ($env:LANGUAGE_MODE) { $env:LANGUAGE_MODE } else { "native" }),
    [switch]$SwapCoder = ($env:SWAP_CODER -eq "1"),
    [switch]$Turbo = ($env:FAMILIA_TURBO -and $env:FAMILIA_TURBO -ne "0"),   # metrics turbo button: no telemetry at all (config\metrics.json)   # swap mode: also replace the coder with the locale model
    [string]$ModelSet = $(if ($env:MODEL_SET) { $env:MODEL_SET } else { "unimpeded" }),   # official | unimpeded (config\model-sets.json)
    [string]$LlamaServer = $(if ($env:LLAMA_SERVER) { $env:LLAMA_SERVER } else { "" }),   # explicit path to llama-server.exe
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path $PSScriptRoot "lib\common.ps1")
$panelPrior = @{
    PORT = [Environment]::GetEnvironmentVariable("PORT")
    HOST = [Environment]::GetEnvironmentVariable("HOST")
    PROFILE = [Environment]::GetEnvironmentVariable("PROFILE")
    MODELS_MAX = [Environment]::GetEnvironmentVariable("MODELS_MAX")
    TOOLS = [Environment]::GetEnvironmentVariable("TOOLS")
    TOOLS_RUNTIME = [Environment]::GetEnvironmentVariable("TOOLS_RUNTIME")
    LOCALE = [Environment]::GetEnvironmentVariable("LOCALE")
    LANGUAGE_MODE = [Environment]::GetEnvironmentVariable("LANGUAGE_MODE")
    GPU_LAYERS = [Environment]::GetEnvironmentVariable("GPU_LAYERS")
    THREADS = [Environment]::GetEnvironmentVariable("THREADS")
    THREADS_BATCH = [Environment]::GetEnvironmentVariable("THREADS_BATCH")
    REPACK = [Environment]::GetEnvironmentVariable("REPACK")
    LOAD_MODE = [Environment]::GetEnvironmentVariable("LOAD_MODE")
    SWAP_CODER = [Environment]::GetEnvironmentVariable("SWAP_CODER")
    WORKDIR = [Environment]::GetEnvironmentVariable("WORKDIR")
}
Import-PanelEnv $Root
Use-PanelValue "Port" "PORT" ($PSBoundParameters.ContainsKey("Port")) ([string]$panelPrior["PORT"])
Use-PanelValue "BindHost" "HOST" ($PSBoundParameters.ContainsKey("BindHost")) ([string]$panelPrior["HOST"])
Use-PanelValue "RamProfile" "PROFILE" ($PSBoundParameters.ContainsKey("RamProfile")) ([string]$panelPrior["PROFILE"])
Use-PanelValue "ModelsMax" "MODELS_MAX" ($PSBoundParameters.ContainsKey("ModelsMax")) ([string]$panelPrior["MODELS_MAX"])
Use-PanelValue "Tools" "TOOLS" ($PSBoundParameters.ContainsKey("Tools")) ([string]$panelPrior["TOOLS"])
Use-PanelValue "ToolsRuntime" "TOOLS_RUNTIME" ($PSBoundParameters.ContainsKey("ToolsRuntime")) ([string]$panelPrior["TOOLS_RUNTIME"])
Use-PanelValue "Locale" "LOCALE" ($PSBoundParameters.ContainsKey("Locale")) ([string]$panelPrior["LOCALE"])
Use-PanelValue "LanguageMode" "LANGUAGE_MODE" ($PSBoundParameters.ContainsKey("LanguageMode")) ([string]$panelPrior["LANGUAGE_MODE"])
Use-PanelValue "GpuLayers" "GPU_LAYERS" ($PSBoundParameters.ContainsKey("GpuLayers")) ([string]$panelPrior["GPU_LAYERS"])
Use-PanelValue "Threads" "THREADS" ($PSBoundParameters.ContainsKey("Threads")) ([string]$panelPrior["THREADS"])
Use-PanelValue "ThreadsBatch" "THREADS_BATCH" ($PSBoundParameters.ContainsKey("ThreadsBatch")) ([string]$panelPrior["THREADS_BATCH"])
Use-PanelValue "Repack" "REPACK" ($PSBoundParameters.ContainsKey("Repack")) ([string]$panelPrior["REPACK"])
Use-PanelValue "LoadMode" "LOAD_MODE" ($PSBoundParameters.ContainsKey("LoadMode")) ([string]$panelPrior["LOAD_MODE"])
Use-PanelValue "SwapCoder" "SWAP_CODER" ($PSBoundParameters.ContainsKey("SwapCoder")) ([string]$panelPrior["SWAP_CODER"])
Use-PanelValue "WorkDir" "WORKDIR" ($PSBoundParameters.ContainsKey("WorkDir")) ([string]$panelPrior["WORKDIR"])
Publish-BoundParam "Port" "PORT" ($PSBoundParameters.ContainsKey("Port"))
Publish-BoundParam "BindHost" "HOST" ($PSBoundParameters.ContainsKey("BindHost"))
Publish-BoundParam "RamProfile" "PROFILE" ($PSBoundParameters.ContainsKey("RamProfile"))
Publish-BoundParam "ModelsMax" "MODELS_MAX" ($PSBoundParameters.ContainsKey("ModelsMax"))
Publish-BoundParam "Tools" "TOOLS" ($PSBoundParameters.ContainsKey("Tools"))
Publish-BoundParam "ToolsRuntime" "TOOLS_RUNTIME" ($PSBoundParameters.ContainsKey("ToolsRuntime"))
Publish-BoundParam "Locale" "LOCALE" ($PSBoundParameters.ContainsKey("Locale"))
Publish-BoundParam "LanguageMode" "LANGUAGE_MODE" ($PSBoundParameters.ContainsKey("LanguageMode"))
Publish-BoundParam "GpuLayers" "GPU_LAYERS" ($PSBoundParameters.ContainsKey("GpuLayers"))
Publish-BoundParam "Threads" "THREADS" ($PSBoundParameters.ContainsKey("Threads"))
Publish-BoundParam "ThreadsBatch" "THREADS_BATCH" ($PSBoundParameters.ContainsKey("ThreadsBatch"))
Publish-BoundParam "Repack" "REPACK" ($PSBoundParameters.ContainsKey("Repack"))
Publish-BoundParam "LoadMode" "LOAD_MODE" ($PSBoundParameters.ContainsKey("LoadMode"))
Publish-BoundParam "WorkDir" "WORKDIR" ($PSBoundParameters.ContainsKey("WorkDir"))
. (Join-Path $PSScriptRoot "lib\bindhost.ps1")
Assert-NoDoubleDashParam @($MyInvocation.MyCommand.Parameters.Keys) "serve.ps1" $PSCommandPath
function Get-RepoPath([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $Root $p } }

# parameters that may come from the environment are checked here (ValidateSet skips defaults)
if ($RamProfile -notin @("auto", "lowram", "moderate", "default")) { throw "unknown PROFILE / -RamProfile '$RamProfile' (auto|lowram|moderate|default)" }
Assert-ModelSet $ModelSet
$env:MODEL_SET = $ModelSet
if ($Repack -notin @("on", "off")) { throw "unknown REPACK / -Repack '$Repack' (on|off)" }
$mode = $LanguageMode.ToLowerInvariant()
if ($mode -eq "auto") { $mode = "native" }
if ($mode -notin @("native", "swap", "interpret", "off")) { throw "unknown LANGUAGE_MODE / -LanguageMode '$LanguageMode' (native|swap|interpret|off)" }

# refuse pass-through args that would widen what the instances can do or pick another model
# (same list as serve.sh; case-insensitive, _ = -). Other llama-server flags apply to EVERY role.
foreach ($a in $Extra) {
    $n = (($a -split '=', 2)[0] -replace '_', '-').ToLowerInvariant()
    if ($n -match '^(--tools|--tools-runtime|-ag|--agent|--no-agent|--mcp-.*|--(no-)?(web)?ui-mcp-proxy|--api-key|--api-key-file)$') {
        throw "argument '$a' is not allowed here; use -Tools / -ToolsRuntime / -McpConfig (the API key is in %APPDATA%\familia\instances\<port>\api-keys)"
    }
    if ($n -match '^(-m|--model|-mu|--model-url|-dr|--docker-repo|-hf|-hfr|--hf-repo|-hff|--hf-file|-hfd|-hfrd|--hf-repo-draft|-hfv|-hfrv|--hf-repo-v|-hffv|--hf-file-v|-mv|--model-vocoder|-md|--model-draft|--spec-draft-model|--spec-draft-hf|--models-dir|--models-preset|--lora|--lora-scaled|--control-vector|--control-vector-scaled|-mm|--mmproj|-mmu|--mmproj-url|-a|--alias|--path|--media-path|--embd-.*-default|--fim-.*-default|--fim-.*-spec|--gpt-oss-.*-default|--vision-.*-default)$') {
        throw "argument '$a' is not allowed here: the models come from config\models-manifest.json and the preset (a [<role>] section may set 'model = <file>'; see README Models)"
    }
    if ($n -match '^(--host|--port|--reuse-port)$') { throw "argument '$a' is not allowed here; use -BindHost / -Port (serve.ps1 checks that its own server got that port)" }
    if ($n -eq '--rpc') { throw "argument '$a' is not allowed here: it would hand the models' work to other machines" }
    if ($n -match '^(--log-file|--log-disable|-lv|--verbosity|--log-verbosity)$') {
        throw "argument '$a' is not allowed here: serve.ps1 reads the server's log (.cache\server.log) to see that its own server listens; -v gives more output"
    }
}
if ($Extra.Count -gt 0) { Write-Host "serve.ps1: extra llama-server arguments apply to EVERY role (general, coder, decision): $($Extra -join ' ')" }

if (-not $WorkDir) { $WorkDir = Join-Path $Root "workspace" }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null
$WorkDir = (Resolve-Path $WorkDir).Path

# llama-server.exe: explicit path, else the Release output of scripts\build-windows.ps1
if (-not $LlamaServer) {
    # own build first, then the release binary scripts\fetch-llama.ps1 verified last
    $LlamaServer = Join-Path $Root "build-windows-x64\bin\Release\llama-server.exe"
    $relPath = Join-Path $Root ".cache\llama-server.path"
    if (-not (Test-Path $LlamaServer) -and (Test-Path $relPath)) { $LlamaServer = (Get-Content $relPath -TotalCount 1).Trim() }
}
if (-not (Test-Path $LlamaServer -PathType Leaf)) { throw "llama-server.exe not found at $LlamaServer; run scripts\build-windows.ps1 or pass -LlamaServer" }
$LlamaServer = (Resolve-Path -LiteralPath (Get-RepoPath $LlamaServer)).Path

# CPU topology (physical cores vs logical processors) and RAM
$cpus = Get-CimInstance Win32_Processor
$cores = [int](($cpus | Measure-Object -Property NumberOfCores -Sum).Sum)
if ($Threads -eq "auto")      { $Threads = $cores }
if ($ThreadsBatch -eq "auto") { $ThreadsBatch = ($cpus | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum }
$memMB = if ($env:MEM_TOTAL_MB) { [int]$env:MEM_TOTAL_MB } else { [int]((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB) }
# free RAM now (MEM_AVAIL_MB overrides, as in serve.sh); unknown: assume the OS and apps keep 2 GB
$availMB = 0
if ($env:MEM_AVAIL_MB) { $availMB = [int]$env:MEM_AVAIL_MB }
else { try { $availMB = [int]((Get-CimInstance Win32_OperatingSystem).FreePhysicalMemory / 1KB) } catch { $availMB = 0 } }
if ($availMB -le 0 -and $memMB -gt 0) { $availMB = $memMB - 2048 }
# A weak CPU (2 cores or fewer, or no AVX2) reads prompts at 1-3 tokens/s: auto picks lowram.
$weak = ""
if ($cores -gt 0 -and $cores -le 2) { $weak = "$cores CPU cores" }
elseif ((Test-Windows) -and $env:PROCESSOR_ARCHITECTURE -eq "AMD64") {
    try {
        if (-not ("CodeBootstraps.Cpu" -as [type])) {
            Add-Type -Namespace CodeBootstraps -Name Cpu -MemberDefinition '[DllImport("kernel32.dll")] public static extern bool IsProcessorFeaturePresent(uint feature);'
        }
        if (-not [CodeBootstraps.Cpu]::IsProcessorFeaturePresent(40)) { $weak = "no AVX2" }   # 40 = PF_AVX2_INSTRUCTIONS_AVAILABLE
    } catch { }
}
# auto, most conservative first (same rules as serve.sh): lowram under 6.9 GB RAM, on a slow CPU or
# under 2 GB free; moderate when less is free than default needs (6.5 GB); else default
if ($RamProfile -eq "auto") {
    if ($memMB -gt 0 -and $memMB -lt 6900) { $RamProfile = "lowram"; $profileWhy = "auto: $memMB MB RAM" }
    elseif ($availMB -gt 0 -and $availMB -lt 2048) { $RamProfile = "lowram"; $profileWhy = "auto: only $availMB MB RAM free" }
    elseif ($availMB -gt 0 -and $availMB -lt 6500) { $RamProfile = "moderate"; $profileWhy = "auto: $availMB MB RAM free" }
    else { $RamProfile = "default"; $profileWhy = "auto: $memMB MB RAM, $availMB MB free" }
    if ($weak) { Write-Warning "slow CPU ($weak): responses may be slow; profile is $RamProfile (memory-only)" }
} else {
    $profileWhy = "PROFILE=$RamProfile"
    if ($weak -and $RamProfile -ne "lowram") {
        Write-Warning "slow CPU ($weak): -RamProfile $RamProfile is heavy here; responses may be slow"
    }
}
# same keys in the same order as OVERLAY in serve.sh, so both write the same preset. The decision
# model is loaded at startup and kept (one --models-max slot more than ModelsMax), except lowram.
# SIZING (same as serve.sh; per host in .cache\panel.env or the environment): monolithic = long
# context (131072 pools, up to 8 loaded); distributed = small slots (16k pools, 2-4 parallel, 2 loaded).
$sizing = if ($env:SIZING) { $env:SIZING } else { "monolithic" }
if ($sizing -notin @("monolithic", "distributed")) { throw "unknown SIZING=$sizing (monolithic|distributed)" }
$overlay = [ordered]@{}
$resident = 1
$ctxMinCoder = 32768; $ctxMinGeneral = 16384
function Add-Pairs($pairs) { foreach ($p in ($pairs -split ' ')) { if ($p) { $kv = $p -split '=', 2; if ($overlay.Contains($kv[0])) { $overlay.Remove($kv[0]) }; $overlay[$kv[0]] = $kv[1] } } }
if ($sizing -eq "distributed") {
    $ctxMinCoder = 2048; $ctxMinGeneral = 2048
    Add-Pairs "*.kv-unified=true *.parallel=2 *.ctx-size=16384 *.kv-unified-per-slot=8192 *.stop-timeout=10 general.ctx-size=16384 coder.parallel=4 coder.ctx-size=32768 coder.kv-unified-per-slot=16384 decision.ctx-size=8192 decision.kv-unified-per-slot=4096 decision.batch-size=4096 decision.ubatch-size=4096 embed.ctx-size=8192 embed.batch-size=8192 embed.ubatch-size=8192"
    $small = "coder.parallel=2 coder.ctx-size=16384 coder.kv-unified-per-slot=16384 general.parallel=1 general.ctx-size=8192 decision.parallel=1 decision.ctx-size=4096 language.parallel=1 language.ctx-size=4096"
    if ($ModelsMax -eq 0) { $ModelsMax = 2 }
    if ($RamProfile -eq "lowram") { Add-Pairs $small; $resident = 0 }
    elseif ($RamProfile -eq "moderate") { Add-Pairs "$small coder.ctx-size=24576 decision.load-on-startup=true" }
    else { Add-Pairs "decision.load-on-startup=true" }
} else {
    if ($RamProfile -eq "lowram") {
        if ($ModelsMax -eq 0) { $ModelsMax = 2 }
        $resident = 0
        Add-Pairs "coder.ctx-size=65536 general.ctx-size=131072 decision.parallel=1 decision.ctx-size=4096 language.parallel=1 language.ctx-size=4096"
    } elseif ($RamProfile -eq "moderate") {
        if ($ModelsMax -eq 0) { $ModelsMax = 4 }
        Add-Pairs "coder.parallel=1 coder.ctx-size=131072 general.parallel=1 general.ctx-size=131072 decision.parallel=1 decision.ctx-size=4096 language.parallel=1 language.ctx-size=4096"
    } else {
        if ($ModelsMax -eq 0) { $ModelsMax = 8 }
        Add-Pairs "decision.load-on-startup=true"
    }
}
if ($ModelsMax -lt 1 -or $ModelsMax -gt 8) { throw "MODELS_MAX / -ModelsMax $ModelsMax`: want a whole number from 1 to 8" }
$routerMax = $ModelsMax + $resident
function Set-Overlay([string]$k, [string]$v) { if ($overlay.Contains($k)) { $overlay.Remove($k) }; $overlay[$k] = $v }
function Get-Knob([string]$name, [int]$lo, [int]$hi, [string]$fallback = "") {
    $v = [Environment]::GetEnvironmentVariable($name); if (-not $v) { $v = $fallback }
    if (-not $v) { return "" }
    $n = 0
    if (-not [int]::TryParse($v, [ref]$n) -or $n -lt $lo -or $n -gt $hi) { throw "$name=$v`: want a whole number from $lo to $hi" }
    return "$n"
}
$tuned = ""
$coderCtx = Get-Knob "CODER_CTX" $ctxMinCoder 262144 $env:CTX
$generalCtx = Get-Knob "GENERAL_CTX" $ctxMinGeneral 262144 $env:CTX
$parallelKnob = Get-Knob "PARALLEL" 1 16
if ($coderCtx) { Set-Overlay "coder.ctx-size" $coderCtx; Set-Overlay "coder.kv-unified-per-slot" $coderCtx; $tuned += " CODER_CTX=$coderCtx" }
if ($generalCtx) { Set-Overlay "general.ctx-size" $generalCtx; Set-Overlay "general.kv-unified-per-slot" $generalCtx; $tuned += " GENERAL_CTX=$generalCtx" }
if ($parallelKnob) { Set-Overlay "coder.parallel" $parallelKnob; $tuned += " PARALLEL=$parallelKnob" }
# Prompt cache (issue #16, same rules as serve.sh): lowram 768, moderate 1024, default 2048 MiB,
# never more than a quarter of the free RAM. CACHE_RAM (MiB, 0 = off) or a --cache-ram argument wins.
$uaCacheRam = $false
foreach ($a in $Extra) { $n = (($a -split '=', 2)[0] -replace '_', '-').ToLowerInvariant(); if ($n -eq '--cache-ram' -or $n -eq '-cram') { $uaCacheRam = $true } }
if (-not $uaCacheRam) {
    $cacheRamKnob = Get-Knob "CACHE_RAM" 0 1048576
    if ($env:CACHE_RAM -eq "0") { $cacheRamKnob = "0" }
    if ($cacheRamKnob) { $cacheRam = [int]$cacheRamKnob; $tuned += " CACHE_RAM=$cacheRamKnob" }
    else {
        $cacheRam = switch ($RamProfile) { "lowram" { 768 } "moderate" { 1024 } default { 2048 } }
        if ($availMB -gt 0 -and [int][math]::Floor($availMB / 4) -lt $cacheRam) { $cacheRam = [int][math]::Floor($availMB / 4) }
        if ($cacheRam -lt 512) { Write-Warning "prompt cache limited to $cacheRam MiB by free RAM; a long coder prompt (about 500 MiB) will not be cached" }
    }
    Set-Overlay "*.cache-ram" "$cacheRam"
}
$reasoning = [Environment]::GetEnvironmentVariable("REASONING")
if (-not $reasoning) { $reasoning = "" }
# Reasoning toggle per role: REASONING_GENERAL / REASONING_CODER, else REASONING, else the preset.
foreach ($rsRole in @("general", "coder")) {
    $rsV = [Environment]::GetEnvironmentVariable("REASONING_" + $rsRole.ToUpper())
    if (-not $rsV) { $rsV = $reasoning }
    if ($rsV -eq "") { continue }
    if (@("on", "off", "auto") -notcontains $rsV) { throw "unknown REASONING=$rsV for $rsRole (on|off|auto)" }
    Set-Overlay "$rsRole.reasoning" $rsV
}

# --- models: every role pinned to ONE file (same rules as serve.sh) ---------------------
$presetPath = Get-RepoPath $(if ($env:MODELS_PRESET) { $env:MODELS_PRESET } else { "config\models-preset.ini" })
$manifestPath = Get-RepoPath $(if ($env:MANIFEST) { $env:MANIFEST } else { "config\models-manifest.json" })
# MODELS_DIR replaces the models root. Unset: shared store, then the checkout copy.
# LANGUAGE_DIR, when set, is the only interpreter directory.
$languageDir = ""
if (-not [string]::IsNullOrEmpty($env:LANGUAGE_DIR)) { $languageDir = Get-RepoPath $env:LANGUAGE_DIR }
if (-not (Test-Path -LiteralPath $presetPath -PathType Leaf)) { throw "preset $presetPath not found" }
$presetLines = @(Get-Content -LiteralPath $presetPath)
$manifest = @((Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).candidates)
function Get-Field($o, [string]$name) { if ($o.PSObject.Properties.Name -contains $name) { $o.$name } else { $null } }
function Get-ManifestSha([string]$file) { foreach ($c in $manifest) { if ($c.file -eq $file) { return $c.sha256 } }; return $null }
function Assert-Model([string]$path, [string]$sha) {
    $stamp = Join-Path $Root ".cache\verified\$sha"
    if ($env:FULL_VERIFY -ne "1" -and (Test-Stamp $stamp $path)) { return }
    Write-Host "serve.ps1: checking the sha256 of $path"
    $got = Get-Sha256 $path
    if ($got -ne $sha) { throw "sha256 mismatch for $path (got $got, want $sha from $manifestPath): run scripts\fetch-models.ps1" }
    New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache\verified") | Out-Null
    Add-Stamp $stamp $path
}
function Test-Model([string]$path, [string]$what) {   # manifest file: sha256-checked; other files: warning
    $sha = Get-ManifestSha (Split-Path -Leaf $path)
    if ($sha) { Assert-Model $path $sha } else { Write-Warning "${what}: $path is not in $manifestPath, so its sha256 is not checked" }
}
function Get-SectionValue([string]$section, [string]$key) {
    $sec = ""
    foreach ($l in $presetLines) {
        if ($l -match '^\[(.*)\]') { $sec = $Matches[1]; continue }
        if ($sec -eq $section -and $l -match "^$key\s*=\s*(.*)$") {
            $v = $Matches[1].Trim()
            if (-not $v) { return "" }
            if ($key -eq "model") { return (Resolve-GgufPath $v) }
            return (Get-RepoPath $v)
        }
    }
    return ""
}
function Get-RoleModel([string]$role) {
    $f = Get-SectionValue $role "model"
    if ($f) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "[$role] model = $f in ${presetPath}: file not found" }
        Test-Model $f "[$role] model"; return $f
    }
    # MODEL_SET pick first (sha256-checked); official never falls back to the uncensored default.
    $sp = Get-ModelSetPick $Root $ModelSet $role
    if ($sp) {
        foreach ($c in $manifest) {
            if ($c.pick -ne $sp[0] -or $c.role -ne $sp[1]) { continue }
            $d = Get-Field $c "dir"; if (-not $d) { $d = "models/" + $sp[1] }
            $p = Resolve-GgufPath ($d + "/" + $c.file)
            if (Test-Path -LiteralPath $p -PathType Leaf) { Assert-Model $p $c.sha256; return $p }
            if ($ModelSet -eq "official") { throw "MODEL_SET=official: the $role role's model $($c.file) is not installed: run scripts\fetch-models.ps1 -ModelSet official" }
            break
        }
    }
    foreach ($c in $manifest) {
        if ($c.role -ne $role -or (Get-Field $c "dir")) { continue }
        $p = Resolve-GgufPath ("models/" + $role + "/" + $c.file)
        if (Test-Path -LiteralPath $p -PathType Leaf) { Assert-Model $p $c.sha256; return $p }
    }
    # dir "models/<other role>": one download serves two roles (chat + coder on one file).
    # Checked after the role's own folder, so an installed fallback/step-up is not shadowed.
    foreach ($c in $manifest) {
        $d = Get-Field $c "dir"
        if ($c.role -ne $role -or -not $d -or -not $d.StartsWith("models/")) { continue }
        $p = Resolve-GgufPath ($d + "/" + $c.file)
        if (Test-Path -LiteralPath $p -PathType Leaf) { Assert-Model $p $c.sha256; return $p }
    }
    if (-not [string]::IsNullOrEmpty($env:MODELS_DIR)) {
        $where = Join-Child $env:MODELS_DIR $role
    } else {
        $where = (Join-Child (Get-GgufHome) ("models/" + $role)) + " or " + (Join-Child $Root ("models/" + $role))
    }
    throw "no model for the $role role in $where (none of the manifest files for it is there): run scripts\fetch-models.ps1"
}
$roleModel = [ordered]@{}
foreach ($r in @("general", "coder", "decision")) {
    $roleModel[$r] = Get-RoleModel $r
    $roleDir = Split-Path -Parent $roleModel[$r]
    Get-ChildItem -LiteralPath $roleDir -Filter *.gguf -File -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $roleModel[$r] } |
        ForEach-Object { Write-Host "serve.ps1: note: $($_.FullName) is ignored (the $r role serves $(Split-Path -Leaf $roleModel[$r]))" }
}

# --- language: locale -> primary language code; swap / interpret / off (same rules as serve.sh)
if ($Locale -eq "auto") { $Locale = (Get-Culture).Name }          # e.g. ja-JP
$langCode = (($Locale -split '[-_.@]')[0].ToLowerInvariant()) -replace '[^a-z0-9]', ''
if (-not $langCode -or $langCode -in @("c", "posix")) { $langCode = "en" }
function Get-LocaleModel([string]$role) {
    $f = Get-SectionValue "locale.$langCode.$role" "model"
    if ($f -and (Test-Path -LiteralPath $f -PathType Leaf)) { return $f }
    return $null
}
$langModel = ""; $swapRoles = @()
if ($langCode -eq "en" -or $mode -eq "off") { $mode = "off" } else {
    if ($mode -eq "swap") {
        $lm = Get-LocaleModel "general"
        if (-not $lm) { throw "LANGUAGE_MODE=swap: no installed model for [locale.$langCode.general] (scripts\fetch-models.ps1 -Pick locale-$langCode)" }
        $swapRoles = @("general"); Test-Model $lm "[locale.$langCode.general] model"
        if ($SwapCoder) {
            $lc = Get-LocaleModel "coder"
            if ($lc) { $swapRoles += "coder"; Test-Model $lc "[locale.$langCode.coder] model"; Write-Warning "-SwapCoder: the coder role now uses the locale model; it must emit tool calls (the ja model made 0 in 12 agent runs, see README Languages)" }
            else { Write-Warning "-SwapCoder: no installed [locale.$langCode.coder] model; coder unchanged" }
        }
    }
    if ($mode -eq "interpret") {   # the manifest's interpreter entries, in manifest order
        foreach ($c in $manifest) {
            if ($c.role -ne "language") { continue }
            if ($languageDir) { $p = Join-Path $languageDir $c.file }
            else { $p = Resolve-GgufPath ("models-optional/language/" + $c.file) }
            if (Test-Path -LiteralPath $p -PathType Leaf) { Assert-Model $p $c.sha256; $langModel = $p; break }
        }
        if (-not $langModel) {
            if ($languageDir) { $whereLang = $languageDir }
            else { $whereLang = (Join-Child (Get-GgufHome) "models-optional/language") + " or " + (Join-Child $Root "models-optional/language") }
            throw "LANGUAGE_MODE=interpret: no interpreter model from $manifestPath in $whereLang (scripts\fetch-models.ps1 -Pick language)"
        }
    }
}
if ($langModel) { $roleModel["language"] = $langModel }
# keys of [locale.<lang>.<role>] for the swapped roles
$localeKeys = @{}; $localeOrder = @{}; $sec = ""
foreach ($l in $presetLines) {
    if ($l -match '^\[(.*)\]') { $sec = $Matches[1]; continue }
    $p = $sec -split '\.'
    if ($p.Count -eq 3 -and $p[0] -eq "locale" -and $p[1] -eq $langCode -and $swapRoles -contains $p[2] -and $l -match '^([A-Za-z0-9_-]+)\s*=\s*(.*)$') {
        $k = $Matches[1]; $v = $Matches[2].Trim()
        if ($k -eq "reasoning" -and $overlay.Contains("$($p[2]).reasoning")) { continue }
        if ($k -eq "model") { $v = Resolve-GgufPath $v }
        $localeKeys["$($p[2]).$k"] = $v
        if (-not $localeOrder.ContainsKey($p[2])) { $localeOrder[$p[2]] = New-Object System.Collections.Generic.List[string] }
        $localeOrder[$p[2]].Add($k)
    }
}

# effective preset (same rules and output as the awk filter in serve.sh)
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache") | Out-Null
$effective = Join-Path $Root ".cache\models-preset.effective.ini"
$out = New-Object System.Collections.Generic.List[string]; $script:sec = ""; $script:skip = $false; $seen = @{}; $had = @{}
function Close-Section {
    $s = $script:sec
    if ($s -eq "" -or $script:skip) { return }
    if ($localeOrder.ContainsKey($s)) { foreach ($k in $localeOrder[$s]) { if (-not $seen.ContainsKey("$s.$k")) { $out.Add("$k = $($localeKeys["$s.$k"])") } } }
    foreach ($k in $overlay.Keys) { if ($k.StartsWith("$s.") -and -not $seen.ContainsKey($k)) { $out.Add("$($k.Substring($s.Length + 1)) = $($overlay[$k])") } }
    if ($roleModel.Contains($s) -and -not $seen.ContainsKey("$s.model") -and -not $localeKeys.ContainsKey("$s.model")) { $out.Add("model = $($roleModel[$s])") }
}
foreach ($line in $presetLines) {
    if ($line -match '^\[.*\]') {
        Close-Section; $script:sec = $line.Substring(1, $line.IndexOf(']') - 1); $had[$script:sec] = $true
        $script:skip = ($script:sec -like "locale.*") -or ($script:sec -eq "language" -and -not $langModel)
        if (-not $script:skip) { $out.Add($line) }; continue
    }
    if ($script:skip) { continue }
    if ($line -match '^([A-Za-z0-9_-]+)\s*=') { $k = $Matches[1]; $key = "$($script:sec).$k"   # (later -match calls overwrite $Matches)
        if ($localeKeys.ContainsKey($key)) { $out.Add("$k = $($localeKeys[$key])"); $seen[$key] = $true; continue }
        if ($overlay.Contains($key)) { $out.Add("$k = $($overlay[$key])"); $seen[$key] = $true; continue }
        if ($k -eq "model" -and $roleModel.Contains($script:sec)) { $out.Add("model = $($roleModel[$script:sec])"); $seen[$key] = $true; continue }
        # path-valued keys: relative to the repository (the server runs in WorkDir)
        if ($k -match '^(model|mmproj)$|-(file|config|dir|path)$') { $v = ($line -replace '^[^=]*=\s*', '')
            if ($v -and -not [System.IO.Path]::IsPathRooted($v)) { $out.Add("$k = $(Join-Path $Root $v)"); continue } } }
    $out.Add($line)
}
Close-Section
foreach ($r in @("general", "coder", "decision", "language")) {
    if ($roleModel.Contains($r) -and -not $had.ContainsKey($r)) { $out.Add(""); $out.Add("[$r]"); $out.Add("model = $($roleModel[$r])") }
}
Write-TextFile $effective $out
# for scripts/agent.py: what the server was started with (same format as serve.sh)
Write-TextFile (Join-Path $Root ".cache\language.json") ('{{"locale": "{0}", "mode": "{1}", "swapped": "{2}"}}' -f $langCode, $mode, ($swapRoles -join " "))

# One stable API key per instance (docs/api-key-design.md): %APPDATA%\familia\instances\<port>\api-keys
# (XDG_CONFIG_HOME or ~/.config off Windows), readable by this user only, created atomically ONLY when
# missing (adopting a legacy .secrets\api-keys), never rotated on startup. $env:API_KEY_FILE overrides.
$cfgBase = if (Test-Windows) { $env:APPDATA } elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
$keyFile = if ($env:API_KEY_FILE) { $env:API_KEY_FILE } else { Join-Path (Join-Path (Join-Path (Join-Path $cfgBase "familia") "instances") "$Port") "api-keys" }
$keyDir = Split-Path -Parent $keyFile
$legacyKeyFile = Join-Path (Join-Path $Root ".secrets") "api-keys"
New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
function Set-Private([string]$path, [bool]$dir) {
    if (Test-Windows) {
        $grant = if ($dir) { "$($env:USERNAME):(OI)(CI)F" } else { "$($env:USERNAME):F" }
        icacls $path /inheritance:r /grant:r $grant | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not restrict $path (exit $LASTEXITCODE); the API key would be readable by others" }
    } else { chmod $(if ($dir) { "700" } else { "600" }) $path }
}
Set-Private $keyDir $true
if (-not (Test-Path -LiteralPath $keyFile) -or (Get-Item -LiteralPath $keyFile).Length -eq 0) {
    # private temp file in the same dir, then an atomic no-overwrite Move: if another starter won
    # the bootstrap race the Move throws and everyone reads the winner's key
    $tmp = Join-Path $keyDir (".api-keys.{0}.tmp" -f $PID)
    New-Item -ItemType File -Force -Path $tmp | Out-Null
    Set-Private $tmp $false
    $legacy = if (Test-Path -LiteralPath $legacyKeyFile) { @(Get-Content -LiteralPath $legacyKeyFile | Where-Object { $_.Trim() -and -not $_.StartsWith("#") }) } else { @() }
    if ($legacy.Count -gt 0) {
        Write-TextFile $tmp (@("# llama-server API key(s), one per line (adopted from $legacyKeyFile)") + $legacy)
    } else {
        $bytes = New-Object byte[] 24; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        Write-TextFile $tmp @("# llama-server API key(s), one per line", (($bytes | ForEach-Object { $_.ToString("x2") }) -join ""))
    }
    try { [System.IO.File]::Move($tmp, $keyFile); Write-Host "serve.ps1: created instance API key in $keyFile" }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}
Set-Private $keyFile $false
$keys = (Get-Content $keyFile | Where-Object { $_.Trim() -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() }) -join ","
if (-not $keys) { throw "no key in $keyFile" }

# Tools: every definition is in every prompt (Qwen3.5 template: full 1732 tokens, lean 843)
if ($Tools -eq "auto") { $Tools = "full" }
if ($Tools -eq "full") { $Tools = "read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info" }
if ($Tools -eq "lean") {
    $Tools = "read_file,write_file,edit_file,exec_shell_command"
}

# MCP: the example server needs a Python that really runs. "python3" on Windows is often the
# Microsoft Store placeholder, so python3, python and the py launcher are each tried.
$pyCmd = $null
if (-not $McpConfig -or $McpConfig -eq "config\mcp-servers.json") {
    $eap = $ErrorActionPreference; $ErrorActionPreference = "Continue"
    foreach ($cand in @(@("python3"), @("python"), @("py", "-3"))) {
        if (-not (Get-Command $cand[0] -ErrorAction SilentlyContinue)) { continue }
        $pre = @($cand | Select-Object -Skip 1)
        try { $v = & $cand[0] @pre -c "import sys; print(sys.version_info[0])" 2>$null; if ($LASTEXITCODE -eq 0 -and "$v".Trim() -eq "3") { $pyCmd = $cand; break } } catch { }
    }
    $ErrorActionPreference = $eap
    if ($pyCmd) { $McpConfig = "config\mcp-servers.json" }
    else { Write-Warning "serve.ps1: no working Python 3 (python3, python, py -3): the bundled example MCP server will not run, but MCP stays active for any other configured servers"; $McpConfig = "config\mcp-servers.json" }
}

# Tools runtime: Docker Desktop if it answers, else the host
$container = $null; $runtime = ""
if ($ToolsRuntime -eq "auto") {
    $docker = Get-Command docker -ErrorAction SilentlyContinue
    if ($docker) { docker info *> $null; if ($LASTEXITCODE -ne 0) { $docker = $null } }
    if ($docker) {
        $container = (docker run -d --rm -v "${WorkDir}:/work" -w /work $ToolsImage sleep infinity).Trim()
        if ($LASTEXITCODE -ne 0) { throw "docker run failed" }
        $runtime = "docker-container:$container"
    } else {
        Write-Host "serve.ps1: note: Docker is not running, so the agent's tools run directly on this computer as your user."
        Write-Host "serve.ps1:   They start in $WorkDir but can reach any file your account can; review what the agent does."
        Write-Host "serve.ps1:   -Tools lean offers fewer tools, -Tools '' none; Docker Desktop keeps them in a container."
    }
} elseif ($ToolsRuntime -ne "host") { $runtime = $ToolsRuntime }

# Only the LLAMA_* variables set here reach llama-server (router and children read them)
# (also the router/child internals, tracing and model download endpoints)
$clear = @("LLAMA_API_KEY", "LLAMA_APP_CMD", "LLAMA_SERVER_ROUTER_PORT", "LLAMA_SERVER_CHILD_MODE",
           "LLAMA_SERVER_SLOTS_DEBUG", "LLAMA_SERVER_SLOTS_N_DIFF", "LLAMA_MEDIA_MARKER", "LLAMA_TRACE", "LLAMA_CACHE", "HF_ENDPOINT", "MODEL_ENDPOINT")
Get-ChildItem Env: | Where-Object { $_.Name -like "LLAMA_ARG_*" -or $clear -contains $_.Name } | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$env:LLAMA_API_KEY = $keys
# patches/0002: tag every log line with [pid] (children: [pid model:port]); LLAMA_LOG_PID=0 turns it off
if (-not $env:LLAMA_LOG_PID) { $env:LLAMA_LOG_PID = "1" }
# The router also lists every GGUF in the Hugging Face cache (%USERPROFILE%\.cache\huggingface\hub,
# HF_HUB_CACHE, HF_HOME) and serves it on request; LLAMA_CACHE wins over those. So every start
# gets a NEW empty directory (removed on exit; leftovers of a closed window go at the next
# start): whatever a cache directory held before is never listed.
$cacheBase = Join-Path $Root ".cache"
New-Item -ItemType Directory -Force -Path $cacheBase | Out-Null
foreach ($d in @(Get-ChildItem -Force -LiteralPath $cacheBase -Directory -Filter "llama-cache*")) {
    $owner = 0
    if ($d.Name -match '^llama-cache\.(\d+)\.') { $owner = [int]$Matches[1] }
    if ($owner -and (Get-Process -Id $owner -ErrorAction SilentlyContinue)) { continue }   # another running serve.ps1
    # a junction or symlink: remove the link only (Remove-Item -Recurse on 5.1 would empty its target)
    if ($d.Attributes -band [IO.FileAttributes]::ReparsePoint) { [IO.Directory]::Delete($d.FullName) }
    else { Remove-Item -Recurse -Force -LiteralPath $d.FullName }
}
$llamaCache = Join-Path $cacheBase ("llama-cache.$PID." + [guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $llamaCache | Out-Null   # fails if it exists
$env:LLAMA_CACHE = $llamaCache
# ...and the router can download any Hugging Face model into it at run time (POST /models with
# the API key, e.g. from the web UI's model picker). Offline mode makes that download fail.
$env:LLAMA_ARG_OFFLINE = "1"
$env:MODEL_ENDPOINT = "https://offline.invalid/"   # the router checks a download request online even when offline (.invalid never resolves)
# Router children listen on loopback without the API key and must get NO tools and no MCP
# (same rule as serve.sh): only a llama-server with patches/0003 ("router-child-no-tools")
# keeps them on the router; an unpatched one would pass them to every child.
if ($Tools -or $McpConfig -or $runtime) {
    $binDir = Split-Path -Parent $LlamaServer
    $patched = $false
    foreach ($f in @(Get-ChildItem -LiteralPath $binDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(llama-server(\.exe)?|.*server.*\.dll|libllama-server.*)$' })) {
        if ([System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($f.FullName)).Contains('router-child-no-tools')) { $patched = $true; break }
    }
    if (-not $patched) {
        Write-Warning "serve.ps1: $LlamaServer lacks patches/0003 (router-child-no-tools): its child instances would inherit the tools and MCP servers, so Tools and MCP are off; build with scripts\build-windows.ps1 to use them"
        $Tools = ""; $McpConfig = ""; $runtime = ""
    }
}
if ($Tools)     { $env:LLAMA_ARG_TOOLS = $Tools }
if ($runtime)   { $env:LLAMA_ARG_TOOLS_RUNTIME = $runtime }
if ($McpConfig) {
    # @ROOT@ in the MCP config = this repository (the server itself runs in WorkDir)
    $McpConfig = Get-RepoPath $McpConfig
    $mcpEff = Join-Path $Root ".cache\mcp-servers.effective.json"
    $rootFwd = $Root -replace '\\', '/'
    $json = $null
    if ($pyCmd) {
        # Base config + enabled starter picks, gated by config\security-gating.json (fail-closed):
        # scripts\lib\mcp_load.py + mcp_gate.py, the same code serve.sh runs. MCP_PICKS=a,b enables picks.
        $starter = if ($null -ne $env:MCP_STARTER) { $env:MCP_STARTER } else { Join-Path $Root "config\mcp-servers.starter.json" }
        if ($starter) { $starter = Get-RepoPath $starter }
        $pre = @($pyCmd | Select-Object -Skip 1)
        $picks = if ($env:MCP_PICKS) { $env:MCP_PICKS } else { "" }
        & $pyCmd[0] @pre (Join-Path $Root "scripts\lib\mcp_load.py") --root $rootFwd --base $McpConfig --starter "$starter" --picks "$picks" --out $mcpEff
        if ($LASTEXITCODE -ne 0) { throw "serve.ps1: the MCP config could not be built (scripts\lib\mcp_load.py)" }
        $json = (Get-Content -Raw $mcpEff).TrimEnd()
    } else {
        if ($env:MCP_PICKS) { Write-Warning "serve.ps1: no working Python 3: MCP_PICKS ($env:MCP_PICKS) ignored" }
        $json = (Get-Content -Raw $McpConfig).Replace("@ROOT@", $rootFwd).TrimEnd()
    }
    if ($pyCmd -and $pyCmd[0] -ne "python3") {   # the example config says "python3"
        $json = $json.Replace('"command": "python3"', '"command": "' + $pyCmd[0] + '"')
        if ($pyCmd.Count -gt 1) { $json = $json.Replace('"args": ["scripts/', '"args": ["' + $pyCmd[1] + '", "scripts/') }
    }
    Write-TextFile $mcpEff $json
    $env:LLAMA_ARG_MCP_SERVERS_CONFIG = $mcpEff
}

# Metrics / telemetry gate (config\metrics.json, default ON; scripts\lib\metrics.py, same as
# serve.sh). -Turbo / FAMILIA_TURBO=1 / turbo_button.turbo:true turn ALL collection off.
$metricsOn = $false
$metricsPy = $pyCmd
if (-not $metricsPy -and (Get-Command python -ErrorAction SilentlyContinue)) { $metricsPy = @("python") }
if ($metricsPy) {
    $mPre = @($metricsPy | Select-Object -Skip 1)
    $mArgs = @((Join-Path $Root "scripts\lib\metrics.py"), "status")
    if ($Turbo) { $mArgs += "--turbo" }
    $metricsState = (& $metricsPy[0] @mPre @mArgs) -join ""
    $metricsOn = ($LASTEXITCODE -eq 0)
} else { $metricsState = "off (no Python)" }
Write-Host "serve.ps1: metrics $metricsState"
if ($metricsOn) { $env:LLAMA_ARG_ENDPOINT_METRICS = "1" }

$requestedHost = $BindHost
if (-not $requestedHost) { $requestedHost = "127.0.0.1" }
if ($requestedHost -notin @("127.0.0.1", "localhost", "::1")) {
    Write-Warning "the chosen host is not loopback; keep the API key secret"
}
$listenHost = Get-BindHost $requestedHost
$probeHost = Get-ProbeHost $listenHost
$srvArgs = @("--host", $listenHost, "--port", $Port,
          "--models-preset", $effective,
          "--models-max", $routerMax,
          "--threads", $Threads, "--threads-batch", $ThreadsBatch,
          "--n-gpu-layers", $GpuLayers, "--fit", "on")
if ($LoadMode) { $srvArgs += @("--load-mode", $LoadMode) }
if ($Repack -eq "off") { $srvArgs += "--no-repack" }
# the log is also how serve.ps1 knows its OWN server bound the port (see "Ready" below); the
# router does not pass --log-file on to the model instances
$logFile = Join-Path $Root ".cache\server.log"
$srvArgs += @("--log-file", $logFile)
Write-Host "serve.ps1: logs: $logFile"
$srvArgs += $Extra
Write-Host "serve.ps1: $LlamaServer $($srvArgs -join ' ')"
$profileTxt = "  Profile: $RamProfile ($profileWhy): $ModelsMax general/coder model(s) loaded$(if ($resident) { ' + decision kept loaded' })$(if ($tuned) { "; set:$tuned" })`n" +
              "  Change:  set PROFILE=lowram|moderate|default (or start.bat -RamProfile moderate), or MODELS_MAX CTX CODER_CTX GENERAL_CTX PARALLEL THREADS TOOLS (README `"Light tuning`")`n"
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache") | Out-Null
[IO.File]::WriteAllText((Join-Path (Join-Path $Root ".cache") "profile.txt"), $profileTxt, (New-Object Text.UTF8Encoding $false))
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache") | Out-Null
Write-TextFile (Join-Path $Root ".cache\sizing") $sizing   # shown by the cockpit
Write-Host "serve.ps1: model set: $ModelSet (MODEL_SET / -ModelSet official|unimpeded; config\model-sets.json)"
Write-Host "serve.ps1: sizing=$sizing profile=$RamProfile ($profileWhy; RAM $memMB MB, $availMB MB free) models-max=$routerMax (ModelsMax $ModelsMax + $resident resident)$(if ($tuned) { " tuned:$tuned" }) models: general=$($roleModel['general']) coder=$($roleModel['coder']) decision=$($roleModel['decision'])"
Write-Host "serve.ps1: language: locale=$langCode mode=$mode swapped=[$($swapRoles -join ' ')] language-slot=$(if ($langModel) { $langModel } else { '-' })"

# Ready = OUR llama-server listens on the port and answers /health: it wrote "listening on
# http://...:<port>" to .cache\server.log (it logs that only after its bind succeeded), and on
# Windows the listening socket's process is a child of this PowerShell running the same file
# as $LlamaServer (compared by file identity, so subst drives and junctions match). Then
# .cache\serve.ready gets "<port> <pid>"; scripts\lib\open-ui.ps1 waits for that file. Checked
# in a background runspace of this process, which ends with the server.
$readyFile = Join-Path $Root ".cache\serve.ready"
# Readiness ceiling (same as serve.sh): 1800 s, 3600 s for lowram or <= 2 logical CPUs;
# READY_TIMEOUT=SECONDS overrides, 0 = wait as long as the server lives.
$readyTimeout = if ($env:READY_TIMEOUT) { $env:READY_TIMEOUT } else { "auto" }
if ($readyTimeout -eq "auto") {
    $readyTimeout = if ($RamProfile -eq "lowram" -or [Environment]::ProcessorCount -le 2) { 3600 } else { 1800 }
} elseif ($readyTimeout -notmatch '^\d+$') { throw "READY_TIMEOUT must be seconds (0 = no limit)" }
$env:FAMILIA_READY_TIMEOUT_EFFECTIVE = "$readyTimeout"
Remove-Item -Force -LiteralPath $readyFile -ErrorAction SilentlyContinue
Remove-Item -Force -LiteralPath $logFile -ErrorAction SilentlyContinue   # an old "listening on" line must not count
$exeId = ""
if (Test-Windows) { try { Initialize-FileId; $exeId = [CodeBootstraps.FileId]::Identity($LlamaServer) } catch { } }
# Closing the console window ends this process without running the "finally" below. A console
# control handler (close, logoff, shutdown events) deletes the ready file and the per-start
# LLAMA_CACHE directory first; Ctrl-C still goes through "finally". C# 5 syntax: Windows PowerShell 5.1 compiles it with the .NET 4 csc.
$readyTypeDef = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
namespace CodeBootstraps {
    public static class ReadyFileCleanup {
        public delegate bool Handler(uint ctrlType);
        [DllImport("kernel32.dll")] static extern bool SetConsoleCtrlHandler(Handler handler, bool add);
        static Handler keep;   // a static reference: the GC must not collect the delegate
        static string path, cacheDir;
        public static bool OnCtrl(uint ctrlType) {
            if (ctrlType >= 2) {   // 2 close, 5 logoff, 6 shutdown
                try { File.Delete(path); } catch { }
                // recursive delete removes a junction/symlink inside without following it
                try { if (cacheDir != null) Directory.Delete(cacheDir, true); } catch { }
            }
            return false;   // let the default handling (and llama-server's own) continue
        }
        public static void Register(string file, string cache) {
            path = file; cacheDir = cache;
            if (keep != null) return;
            keep = new Handler(OnCtrl);
            SetConsoleCtrlHandler(keep, true);
        }
    }
}
'@
if (Test-Windows) {
    try {
        if (-not ("CodeBootstraps.ReadyFileCleanup" -as [type])) { Add-Type -TypeDefinition $readyTypeDef }
        [CodeBootstraps.ReadyFileCleanup]::Register($readyFile, $llamaCache)
    } catch { Write-Host "serve.ps1: note: no console-close cleanup for $readyFile ($($_.Exception.Message)); start.bat removes a stale one" }
}
$sync = [hashtable]::Synchronized(@{ Stop = $false })
$watch = [powershell]::Create()
[void]$watch.AddScript({
    param($sync, $port, $probeHost, $exe, $parentPid, $readyFile, $onWindows, $logFile, $exeId, $saidListeningDef)
    Set-StrictMode -Version Latest
    # the same Test-ServerSaidListening as in scripts\lib\common.ps1 (tests/test-ps1-helpers.ps1 runs it)
    Set-Item -Path function:Test-ServerSaidListening -Value ([scriptblock]::Create($saidListeningDef))
    function Test-OurExe($path) {
        if (-not $path) { return $false }
        if ($exeId) { try { return [CodeBootstraps.FileId]::Identity($path) -eq $exeId } catch { } }
        return ([IO.Path]::GetFullPath($path) -ieq [IO.Path]::GetFullPath($exe))
    }
    # ceiling from READY_TIMEOUT (seconds, 0 = none), resolved by serve.ps1 before the start
    $limit = [int]$env:FAMILIA_READY_TIMEOUT_EFFECTIVE
    $every = if ($env:READY_EVERY) { [int]$env:READY_EVERY } else { 30 }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $next = $every
    while (-not $sync.Stop) {
        Start-Sleep -Milliseconds 500
        $el = [int]$sw.Elapsed.TotalSeconds
        if ($limit -gt 0 -and $el -ge $limit) {
            [Console]::Out.WriteLine("serve.ps1: not ready after ${el}s (READY_TIMEOUT=$limit): llama-server has not answered /health on port $port. See $logFile; set READY_TIMEOUT=0 (no limit) or a larger value and restart")
            return
        }
        if ($el -ge $next) {
            $lim = if ($limit -gt 0) { "limit ${limit}s" } else { "no limit" }
            [Console]::Out.WriteLine("serve.ps1: still starting (${el}s, $lim)")
            $next += $every
        }
        if (-not (Test-ServerSaidListening -LogFile $logFile -Port $port)) { continue }
        $owner = 0
        if ($onWindows) {
            try {
                foreach ($c in @(Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction Stop)) {
                    $p = Get-CimInstance Win32_Process -Filter "ProcessId = $($c.OwningProcess)"
                    if ($p -and $p.ParentProcessId -eq $parentPid -and (Test-OurExe $p.ExecutablePath)) { $owner = $c.OwningProcess }
                }
            } catch { }
            if (-not $owner) { continue }
        }
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://${probeHost}:$port/health" | Out-Null } catch { continue }
        [IO.File]::WriteAllText($readyFile, "$port $owner`n")
        [Console]::Out.WriteLine("serve.ps1: listening on http://${probeHost}:$port$(if ($owner) { " (pid $owner)" })")
        return
    }
})
[void]$watch.AddArgument($sync).AddArgument($Port).AddArgument($probeHost).AddArgument($LlamaServer).AddArgument($PID).AddArgument($readyFile).AddArgument([bool](Test-Windows)).AddArgument($logFile).AddArgument($exeId).AddArgument(${function:Test-ServerSaidListening}.ToString())
# the server runs in WorkDir: with the host runtime that is the web UI's default tool directory
$recover = $null
$pyRecover = $pyCmd
if (-not $pyRecover -and (Get-Command python -ErrorAction SilentlyContinue)) { $pyRecover = @("python") }
if ($pyRecover) {
    $env:RECOVER_URL = "http://${probeHost}:$Port"
    $env:API_KEY_FILE = $keyFile
    $recArgs = @()
    if ($pyRecover.Count -gt 1) { $recArgs += $pyRecover[1..($pyRecover.Count - 1)] }
    $recArgs += (Join-Path $Root "scripts\recover.py")
    $recLog = Join-Path $Root ".cache\recover.log"
    $recover = Start-Process -FilePath $pyRecover[0] -ArgumentList $recArgs -PassThru -WindowStyle Hidden -RedirectStandardError $recLog -WorkingDirectory $Root
}
$metricsProc = $null
if ($metricsOn) {
    $msArgs = @()
    if ($metricsPy.Count -gt 1) { $msArgs += $metricsPy[1..($metricsPy.Count - 1)] }
    $msArgs += @("`"$(Join-Path $Root "scripts\lib\metrics.py")`"", "sample", "--url", "http://${probeHost}:$Port", "--key-file", "`"$keyFile`"")
    $metricsProc = Start-Process -FilePath $metricsPy[0] -ArgumentList $msArgs -PassThru -WindowStyle Hidden -WorkingDirectory $Root
}
$publicHosts = @(Get-PublicHosts $requestedHost)
foreach ($h in $publicHosts) {
    Write-Host "serve.ps1: also on http://$(Format-UrlHost $h):$Port"
}
if ($publicHosts.Count -gt 0) {
    Write-Host "serve.ps1: Other machines can use these addresses. The API key is sent as plain HTTP."
} elseif ($listenHost -match '(^|,)(0\.0\.0\.0|::)(,|$)') {
    Write-Host "serve.ps1: Other machines can connect to this machine on this port. The API key is sent as plain HTTP."
}
Push-Location $WorkDir
try {
    [void]$watch.BeginInvoke()
    & $LlamaServer @srvArgs
} finally {
    if ($recover -and -not $recover.HasExited) { Stop-Process -Id $recover.Id -Force -ErrorAction SilentlyContinue }
    if ($metricsProc -and -not $metricsProc.HasExited) { Stop-Process -Id $metricsProc.Id -Force -ErrorAction SilentlyContinue }
    $sync.Stop = $true
    try { $watch.Stop(); $watch.Dispose() } catch { }
    Remove-Item -Force -LiteralPath $readyFile -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $llamaCache -ErrorAction SilentlyContinue
    Pop-Location
    if ($container) { docker rm -f $container *> $null }
}
