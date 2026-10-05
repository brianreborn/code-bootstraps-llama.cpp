# code-bootstraps-llama.cpp: Windows launcher (Windows PowerShell 5.1 and PowerShell 7).
# Same behaviour as scripts/serve.sh: router mode on 127.0.0.1, API key through
# LLAMA_API_KEY (children inherit it), tools + MCP given to the router only through
# LLAMA_ARG_* env vars, every role pinned to one sha256-checked file, profile overlay and
# the optional language slot.
#   powershell -ExecutionPolicy Bypass -File scripts\serve.ps1 [-RamProfile lowram] [-Tools lean] [-ToolsRuntime auto|host|docker-container:<id>|ssh:<target>] [llama-server flags, e.g. --ctx-size 8192]
# Parameters default to the environment variables serve.sh reads (PORT, HOST, PROFILE,
# MODELS_MAX, TOOLS, TOOLS_RUNTIME, THREADS, THREADS_BATCH, GPU_LAYERS, REPACK, LOAD_MODE,
# WORKDIR, MCP_CONFIG, LOCALE, LANGUAGE_MODE, SWAP_CODER, LLAMA_SERVER, MODELS_PRESET,
# MANIFEST, MODELS_DIR, LANGUAGE_DIR); a parameter given on the command line wins.
# Extra llama-server flags apply to EVERY role; flags that pick a model, tools, MCP or the key
# are refused (see serve.sh).
[CmdletBinding(PositionalBinding = $false)]
param(
    [string]$BindHost = $(if ($env:HOST) { $env:HOST } else { "127.0.0.1" }),
    [int]$Port = $(if ($env:PORT) { [int]$env:PORT } else { 9931 }),
    [string]$RamProfile = $(if ($env:PROFILE) { $env:PROFILE } else { "auto" }),   # auto | lowram | moderate | default (README "Light tuning")
    [int]$ModelsMax = $(if ($env:MODELS_MAX) { [int]$env:MODELS_MAX } else { 0 }),   # general/coder kept loaded: 0 = profile default (lowram 1, moderate/default 2); decision stays loaded on top (not lowram)
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
    [switch]$SwapCoder = ($env:SWAP_CODER -eq "1"),   # swap mode: also replace the coder with the locale model
    [string]$LlamaServer = $(if ($env:LLAMA_SERVER) { $env:LLAMA_SERVER } else { "" }),   # explicit path to llama-server.exe
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Extra = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path $PSScriptRoot "lib\common.ps1")
. (Join-Path $PSScriptRoot "lib\bindhost.ps1")
Assert-NoDoubleDashParam @($MyInvocation.MyCommand.Parameters.Keys) "serve.ps1" $PSCommandPath
function Get-RepoPath([string]$p) { if ([System.IO.Path]::IsPathRooted($p)) { $p } else { Join-Path $Root $p } }

# parameters that may come from the environment are checked here (ValidateSet skips defaults)
if ($RamProfile -notin @("auto", "lowram", "moderate", "default")) { throw "unknown PROFILE / -RamProfile '$RamProfile' (auto|lowram|moderate|default)" }
if ($Repack -notin @("on", "off")) { throw "unknown REPACK / -Repack '$Repack' (on|off)" }
$mode = $LanguageMode.ToLowerInvariant()
if ($mode -eq "auto") { $mode = "native" }
if ($mode -notin @("native", "swap", "interpret", "off")) { throw "unknown LANGUAGE_MODE / -LanguageMode '$LanguageMode' (native|swap|interpret|off)" }

# refuse pass-through args that would widen what the instances can do or pick another model
# (same list as serve.sh; case-insensitive, _ = -). Other llama-server flags apply to EVERY role.
foreach ($a in $Extra) {
    $n = (($a -split '=', 2)[0] -replace '_', '-').ToLowerInvariant()
    if ($n -match '^(--tools|--tools-runtime|-ag|--agent|--no-agent|--mcp-.*|--(no-)?(web)?ui-mcp-proxy|--api-key|--api-key-file)$') {
        throw "argument '$a' is not allowed here; use -Tools / -ToolsRuntime / -McpConfig (the API key is in .secrets\api-keys)"
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
    elseif ($weak) { $RamProfile = "lowram"; $profileWhy = "auto: slow CPU, $weak"; Write-Warning "slow CPU ($weak): using the lowram profile (lean tools, smaller contexts); the first answer can still take minutes" }
    elseif ($availMB -gt 0 -and $availMB -lt 2048) { $RamProfile = "lowram"; $profileWhy = "auto: only $availMB MB RAM free" }
    elseif ($availMB -gt 0 -and $availMB -lt 6500) { $RamProfile = "moderate"; $profileWhy = "auto: $availMB MB RAM free" }
    else { $RamProfile = "default"; $profileWhy = "auto: $memMB MB RAM, $availMB MB free" }
} else {
    $profileWhy = "PROFILE=$RamProfile"
    if ($weak -and $RamProfile -ne "lowram") {
        Write-Warning "slow CPU ($weak): -RamProfile $RamProfile is heavy here; -RamProfile lowram (or -Tools lean) answers much sooner"
    }
}
# same keys in the same order as OVERLAY in serve.sh, so both write the same preset. The decision
# model is loaded at startup and kept (one --models-max slot more than ModelsMax), except lowram.
$small = [ordered]@{ "coder.parallel" = "2"; "coder.ctx-size" = "16384"; "coder.kv-unified-per-slot" = "16384";
              "general.parallel" = "1"; "general.ctx-size" = "8192"; "decision.parallel" = "1"; "decision.ctx-size" = "4096";
              "language.parallel" = "1"; "language.ctx-size" = "4096" }
$overlay = [ordered]@{}
$resident = 1
if ($RamProfile -eq "lowram") {
    if ($ModelsMax -eq 0) { $ModelsMax = 1 }
    $overlay = $small; $resident = 0
} elseif ($RamProfile -eq "moderate") {
    if ($ModelsMax -eq 0) { $ModelsMax = 2 }
    $overlay = $small; $overlay["coder.ctx-size"] = "24576"; $overlay["decision.load-on-startup"] = "true"
} else {
    if ($ModelsMax -eq 0) { $ModelsMax = 2 }
    $overlay["decision.load-on-startup"] = "true"
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
$coderCtx = Get-Knob "CODER_CTX" 2048 262144 $env:CTX
$generalCtx = Get-Knob "GENERAL_CTX" 2048 262144 $env:CTX
$parallelKnob = Get-Knob "PARALLEL" 1 16
if ($coderCtx) { Set-Overlay "coder.ctx-size" $coderCtx; Set-Overlay "coder.kv-unified-per-slot" $coderCtx; $tuned += " CODER_CTX=$coderCtx" }
if ($generalCtx) { Set-Overlay "general.ctx-size" $generalCtx; Set-Overlay "general.kv-unified-per-slot" $generalCtx; $tuned += " GENERAL_CTX=$generalCtx" }
if ($parallelKnob) { Set-Overlay "coder.parallel" $parallelKnob; $tuned += " PARALLEL=$parallelKnob" }

# --- models: every role pinned to ONE file (same rules as serve.sh) ---------------------
$presetPath = Get-RepoPath $(if ($env:MODELS_PRESET) { $env:MODELS_PRESET } else { "config\models-preset.ini" })
$manifestPath = Get-RepoPath $(if ($env:MANIFEST) { $env:MANIFEST } else { "config\models-manifest.json" })
$modelsDir = Get-RepoPath $(if ($env:MODELS_DIR) { $env:MODELS_DIR } else { "models" })
$languageDir = Get-RepoPath $(if ($env:LANGUAGE_DIR) { $env:LANGUAGE_DIR } else { "models-optional\language" })
if (-not (Test-Path -LiteralPath $presetPath -PathType Leaf)) { throw "preset $presetPath not found" }
$presetLines = @(Get-Content -LiteralPath $presetPath)
$manifest = @((Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json).candidates)
function Get-Field($o, [string]$name) { if ($o.PSObject.Properties.Name -contains $name) { $o.$name } else { $null } }
function Get-ManifestSha([string]$file) { foreach ($c in $manifest) { if ($c.file -eq $file) { return $c.sha256 } }; return $null }
function Assert-Model([string]$path, [string]$sha) {
    $stamp = Join-Path $Root ".cache\verified\$sha"
    if ($env:FULL_VERIFY -ne "1" -and (Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -TotalCount 1) -eq (Get-Fingerprint $path))) { return }
    Write-Host "serve.ps1: checking the sha256 of $path"
    $got = Get-Sha256 $path
    if ($got -ne $sha) { throw "sha256 mismatch for $path (got $got, want $sha from $manifestPath): run scripts\fetch-models.ps1" }
    New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache\verified") | Out-Null
    Write-TextFile $stamp (Get-Fingerprint $path)
}
function Test-Model([string]$path, [string]$what) {   # manifest file: sha256-checked; other files: warning
    $sha = Get-ManifestSha (Split-Path -Leaf $path)
    if ($sha) { Assert-Model $path $sha } else { Write-Warning "${what}: $path is not in $manifestPath, so its sha256 is not checked" }
}
function Get-SectionValue([string]$section, [string]$key) {
    $sec = ""
    foreach ($l in $presetLines) {
        if ($l -match '^\[(.*)\]') { $sec = $Matches[1]; continue }
        if ($sec -eq $section -and $l -match "^$key\s*=\s*(.*)$") { $v = $Matches[1].Trim(); if ($v) { return (Get-RepoPath $v) } else { return "" } }
    }
    return ""
}
function Get-RoleModel([string]$role) {
    $f = Get-SectionValue $role "model"
    if ($f) {
        if (-not (Test-Path -LiteralPath $f -PathType Leaf)) { throw "[$role] model = $f in ${presetPath}: file not found" }
        Test-Model $f "[$role] model"; return $f
    }
    foreach ($c in $manifest) {
        if ($c.role -ne $role -or (Get-Field $c "dir")) { continue }
        $p = Join-Path (Join-Path $modelsDir $role) $c.file
        if (Test-Path -LiteralPath $p -PathType Leaf) { Assert-Model $p $c.sha256; return $p }
    }
    throw "no model for the $role role in $(Join-Path $modelsDir $role) (none of the manifest files for it is there): run scripts\fetch-models.ps1"
}
$roleModel = [ordered]@{}
foreach ($r in @("general", "coder", "decision")) {
    $roleModel[$r] = Get-RoleModel $r
    Get-ChildItem -LiteralPath (Join-Path $modelsDir $r) -Filter *.gguf -File -ErrorAction SilentlyContinue |
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
            $p = Join-Path $languageDir $c.file
            if (Test-Path -LiteralPath $p -PathType Leaf) { Assert-Model $p $c.sha256; $langModel = $p; break }
        }
        if (-not $langModel) { throw "LANGUAGE_MODE=interpret: no interpreter model from $manifestPath in $languageDir (scripts\fetch-models.ps1 -Pick language)" }
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
        if ($k -eq "model") { $v = Get-RepoPath $v }
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

# API key file, generated once (.secrets\ is git-ignored), readable by this user only. The
# directory and the empty file get their ACL BEFORE the key is written into it.
$keyDir = Join-Path $Root ".secrets"; $keyFile = Join-Path $keyDir "api-keys"
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
    New-Item -ItemType File -Force -Path $keyFile | Out-Null
    Set-Private $keyFile $false
    $bytes = New-Object byte[] 24; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    Write-TextFile $keyFile @("# llama-server API key(s), one per line", (($bytes | ForEach-Object { $_.ToString("x2") }) -join ""))
    Write-Host "serve.ps1: generated API key in $keyFile"
}
Set-Private $keyFile $false
$keys = (Get-Content $keyFile | Where-Object { $_.Trim() -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() }) -join ","
if (-not $keys) { throw "no key in $keyFile" }

# Tools: every definition is in every prompt (Qwen3.5 template: full 1732 tokens, lean 843)
if ($Tools -eq "auto") { $Tools = if ($RamProfile -eq "lowram") { "lean" } else { "full" } }
if ($Tools -eq "full") { $Tools = "read_file,file_glob_search,grep_search,exec_shell_command,write_file,edit_file,get_info" }
if ($Tools -eq "lean") {
    $Tools = "read_file,write_file,edit_file,exec_shell_command"
    if (-not $McpConfig) { $McpConfig = "config\mcp-servers.empty.json"; Write-Host "serve.ps1: -Tools lean: example MCP server off (pass -McpConfig to use one)" }
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
    else { Write-Host "serve.ps1: note: no working Python 3 (python3, python, py -3): the example MCP server is off; the built-in tools still work"; $McpConfig = "config\mcp-servers.empty.json" }
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
if ($Tools)     { $env:LLAMA_ARG_TOOLS = $Tools }
if ($runtime)   { $env:LLAMA_ARG_TOOLS_RUNTIME = $runtime }
if ($McpConfig) {
    # @ROOT@ in the MCP config = this repository (the server itself runs in WorkDir)
    $McpConfig = Get-RepoPath $McpConfig
    $mcpEff = Join-Path $Root ".cache\mcp-servers.effective.json"
    $json = (Get-Content -Raw $McpConfig).Replace("@ROOT@", ($Root -replace '\\', '/')).TrimEnd()
    if ($pyCmd -and $pyCmd[0] -ne "python3") {   # the example config says "python3"
        $json = $json.Replace('"command": "python3"', '"command": "' + $pyCmd[0] + '"')
        if ($pyCmd.Count -gt 1) { $json = $json.Replace('"args": ["scripts/', '"args": ["' + $pyCmd[1] + '", "scripts/') }
    }
    Write-TextFile $mcpEff $json
    $env:LLAMA_ARG_MCP_SERVERS_CONFIG = $mcpEff
}

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
$srvArgs += $Extra
Write-Host "serve.ps1: $LlamaServer $($srvArgs -join ' ')"
$profileTxt = "  Profile: $RamProfile ($profileWhy): $ModelsMax general/coder model(s) loaded$(if ($resident) { ' + decision kept loaded' })$(if ($tuned) { "; set:$tuned" })`n" +
              "  Change:  set PROFILE=lowram|moderate|default (or start.bat -RamProfile moderate), or MODELS_MAX CTX CODER_CTX GENERAL_CTX PARALLEL THREADS TOOLS (README `"Light tuning`")`n"
New-Item -ItemType Directory -Force -Path (Join-Path $Root ".cache") | Out-Null
[IO.File]::WriteAllText((Join-Path (Join-Path $Root ".cache") "profile.txt"), $profileTxt, (New-Object Text.UTF8Encoding $false))
Write-Host "serve.ps1: profile=$RamProfile ($profileWhy; RAM $memMB MB, $availMB MB free) models-max=$routerMax (ModelsMax $ModelsMax + $resident resident)$(if ($tuned) { " tuned:$tuned" }) models: general=$($roleModel['general']) coder=$($roleModel['coder']) decision=$($roleModel['decision'])"
Write-Host "serve.ps1: language: locale=$langCode mode=$mode swapped=[$($swapRoles -join ' ')] language-slot=$(if ($langModel) { $langModel } else { '-' })"

# Ready = OUR llama-server listens on the port and answers /health: it wrote "listening on
# http://...:<port>" to .cache\server.log (it logs that only after its bind succeeded), and on
# Windows the listening socket's process is a child of this PowerShell running the same file
# as $LlamaServer (compared by file identity, so subst drives and junctions match). Then
# .cache\serve.ready gets "<port> <pid>"; scripts\lib\open-ui.ps1 waits for that file. Checked
# in a background runspace of this process, which ends with the server.
$readyFile = Join-Path $Root ".cache\serve.ready"
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
    for ($i = 0; $i -lt 2400 -and -not $sync.Stop; $i++) {
        Start-Sleep -Milliseconds 500
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
    $sync.Stop = $true
    try { $watch.Stop(); $watch.Dispose() } catch { }
    Remove-Item -Force -LiteralPath $readyFile -ErrorAction SilentlyContinue
    Remove-Item -Recurse -Force -LiteralPath $llamaCache -ErrorAction SilentlyContinue
    Pop-Location
    if ($container) { docker rm -f $container *> $null }
}
