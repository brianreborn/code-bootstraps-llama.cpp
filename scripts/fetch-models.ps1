# Windows counterpart of scripts/fetch-models.sh (UNTESTED on Windows): download models into
# the shared store (GGUF_HOME, else $XDG_DATA_HOME\gguf or ~\.local\share\gguf) from the
# Hugging Face commit pinned in config\models-manifest.json and check their sha256 before
# moving them into place. MODELS_DIR replaces the models root. A checkout copy is used in
# place and is not moved. A mismatch is renamed to *.bad. Same picks and rules as the shell script:
#   powershell -ExecutionPolicy Bypass -File scripts\fetch-models.ps1 [-Pick default|fallback|step-up|language|language-small|locale-ja] [-Role coder] [-Ask]
# -Ask lists manifest rows that already have a sha256, except the default general and coder
# files, and reads one name from stdin (not the console host). Empty or unknown input downloads
# nothing and does not replace, move, or re-download that default pair.
# serve.ps1 serves ONE manifest file per role: another pick's file is parked in
# models-inactive\<role>\ (never deleted). -Ask does not park the default general and coder files.
# License notices print when a file is downloaded or restored.
# An unchanged file (same size and modification time as at its last check) is not re-hashed
# unless -FullVerify.
param(
    [string]$Pick = "default",
    [string]$Role = "",
    [switch]$FullVerify,
    [switch]$Ask
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path $PSScriptRoot "lib\common.ps1")
. (Join-Path $PSScriptRoot "lib\download.ps1")
if ($env:FULL_VERIFY -eq "1") { $FullVerify = $true }

function Get-Field($o, [string]$name) { if ($o.PSObject.Properties.Name -contains $name) { $o.$name } else { $null } }

$manifestPath = if ($env:MANIFEST) { $env:MANIFEST } else { "config\models-manifest.json" }
$manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
$fileOnly = ""
$keepDefaults = $false
$defGeneral = ""
$defCoder = ""
foreach ($cand in @($manifest.candidates)) {
    if ($cand.pick -eq "default" -and $cand.role -eq "general") { $defGeneral = [string]$cand.file }
    if ($cand.pick -eq "default" -and $cand.role -eq "coder") { $defCoder = [string]$cand.file }
}
if ($Ask) {
    # Same rule as fetch-models.sh --ask: known sha256, not the default general or coder file.
    $offered = @()
    foreach ($cand in @($manifest.candidates)) {
        $sha = [string](Get-Field $cand "sha256")
        if ([string]::IsNullOrWhiteSpace($sha)) { continue }
        $isDefaultPair = $cand.pick -eq "default" -and ($cand.role -eq "general" -or $cand.role -eq "coder")
        if ($isDefaultPair) { continue }
        $offered = @($offered) + @($cand)
    }
    if (@($offered).Count -eq 0) {
        Write-Host "fetch-models: no extra model with a sha256; no download"
        return
    }
    Write-Host "fetch-models: extra models with a known sha256, other than the default general and coder."
    Write-Host "fetch-models: an empty line downloads nothing."
    foreach ($cand in @($offered)) {
        Write-Host ("fetch-models: offer {0}/{1} {2}" -f $cand.pick, $cand.file, $cand.role)
    }
    Write-Host "fetch-models: which extra model?"
    $ans = [Console]::In.ReadLine()
    if ($null -eq $ans) { $ans = "" }
    $ans = $ans.Trim()
    if ($ans -eq "") {
        Write-Host "fetch-models: nothing chosen; no download"
        return
    }
    $hits = @()
    foreach ($cand in @($offered)) {
        $token = "{0}/{1}" -f $cand.pick, $cand.file
        $take = $false
        if ($ans -eq $token) { $take = $true }
        if (-not $take -and $ans -eq [string]$cand.file) {
            $n = 0
            foreach ($other in @($offered)) { if ([string]$other.file -eq $ans) { $n++ } }
            if ($n -eq 1) { $take = $true }
        }
        if (-not $take -and $ans -eq [string]$cand.pick) {
            $n = 0
            foreach ($other in @($offered)) { if ([string]$other.pick -eq $ans) { $n++ } }
            if ($n -eq 1) { $take = $true }
        }
        if ($take) { $hits = @($hits) + @($cand) }
    }
    if (@($hits).Count -ne 1) {
        Write-Host "fetch-models: '$ans' is not one listed extra; no download"
        return
    }
    $chosen = @($hits)[0]
    $Pick = [string]$chosen.pick
    $fileOnly = [string]$chosen.file
    $Role = ""
    $keepDefaults = $true
}
if ($fileOnly) {
    $entries = @($manifest.candidates | Where-Object { $_.pick -eq $Pick -and $_.file -eq $fileOnly })
} else {
    $entries = @($manifest.candidates | Where-Object { $_.pick -eq $Pick -and (-not $Role -or $_.role -eq $Role) })
}
if ($entries.Count -eq 0) { throw "fetch-models: no manifest entries for pick='$Pick'$(if ($Role) { " role='$Role'" })" }
$verified = Join-Path $Root ".cache\verified"
New-Item -ItemType Directory -Force -Path $verified | Out-Null

foreach ($e in $entries) {
    $notice = Get-Field $e "notice"   # printed when the file is downloaded or restored
    $dirRel = Get-Field $e "dir"; if (-not $dirRel) { $dirRel = "models/$($e.role)" }
    $dirRel = $dirRel -replace '\\', '/'
    $rel = "$dirRel/$($e.file)"
    $tail = ($dirRel -split '/', 2)[1]
    $inactiveRel = "models-inactive/$tail/$($e.file)"
    $sha = [string](Get-Field $e "sha256")
    if ([string]::IsNullOrWhiteSpace($sha)) { throw "fetch-models: $($e.file) has no sha256; not fetched" }
    if (-not (Get-Field $e "tested")) { Write-Warning "fetch-models: $($e.file) is untested with this repo" }
    $path = Resolve-GgufPath $rel
    $fresh = $false
    if (Test-Path -LiteralPath $path -PathType Leaf) { Write-Host "fetch-models: $path exists" }
    else {
        $inactive = Resolve-GgufPath $inactiveRel
        $dest = Get-GgufDest $rel
        if ((Test-Path -LiteralPath $inactive -PathType Leaf) -and (Test-GgufManaged $inactive)) {
            if ($notice) { Write-Warning "fetch-models: LICENSE NOTICE: $notice" }
            Write-Host "fetch-models: restoring $inactive"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Move-Item -LiteralPath $inactive -Destination $dest
            $path = $dest
        } elseif (Test-Path -LiteralPath $inactive -PathType Leaf) {
            if ($notice) { Write-Warning "fetch-models: LICENSE NOTICE: $notice" }
            Write-Host "fetch-models: using checkout copy $inactive (not moved)"
            $path = $inactive
        } else {
            if ($notice) { Write-Warning "fetch-models: LICENSE NOTICE: $notice" }
            $url = "https://huggingface.co/$($e.repo)/resolve/$($e.revision)/$($e.file)"
            Write-Host "fetch-models: $url -> $dest"
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            Get-VerifiedFile -Url $url -Dest $dest -Sha256 $sha -Tag "fetch-models"
            $fresh = $true
            $path = $dest
        }
    }
    $stamp = Join-Path $verified $sha
    if (-not $fresh) {
        if (-not $FullVerify -and (Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -TotalCount 1) -eq (Get-Fingerprint $path))) {
            Write-Host "fetch-models: $($e.file) unchanged since its last sha256 check (-FullVerify re-hashes)"
        } else {
            $got = Get-Sha256 $path
            if ($got -ne $sha) {
                Move-Item -Force -LiteralPath $path -Destination "$path.bad"
                throw "fetch-models: sha256 mismatch for existing $path (got $got); moved to $path.bad"
            }
        }
    }
    # Park siblings only in the store (or MODELS_DIR), never a checkout copy.
    if (Test-GgufManaged $path) {
        $parkDir = Split-Path -Parent $path
        $inactiveDir = Get-GgufDest "models-inactive/$tail"
        Get-ChildItem -LiteralPath $parkDir -Filter *.gguf -File -ErrorAction SilentlyContinue |
            Where-Object {
                # -Ask adds a file beside the defaults; do not park that pair.
                $park = $true
                if ($_.Name -eq $e.file) { $park = $false }
                if ($_.Name -match 'mmproj') { $park = $false }
                if ($keepDefaults -and ($_.Name -eq $defGeneral -or $_.Name -eq $defCoder)) { $park = $false }
                $park
            } | ForEach-Object {
            New-Item -ItemType Directory -Force -Path $inactiveDir | Out-Null
            Write-Host "fetch-models: parking $($_.FullName) -> $inactiveDir\"
            Move-Item -LiteralPath $_.FullName -Destination $inactiveDir
        }
    }
    Write-TextFile $stamp (Get-Fingerprint $path)
    Write-Host "fetch-models: OK $($e.role) = $($e.file)"
}
Write-Host "fetch-models: done. Restart scripts\serve.ps1 (or start.bat) to serve a newly installed model."
