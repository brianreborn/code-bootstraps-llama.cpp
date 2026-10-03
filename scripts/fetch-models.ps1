# Windows counterpart of scripts/fetch-models.sh (UNTESTED on Windows): download models into
# models\<role>\ from the Hugging Face commit pinned in config\models-manifest.json and check
# their sha256 before moving them into place. Same picks and rules as the shell script:
#   powershell -ExecutionPolicy Bypass -File scripts\fetch-models.ps1 [-Pick default|fallback|step-up|language|language-small|locale-ja] [-Role coder]
# One .gguf per role directory: another pick's file is parked in models-inactive\<role>\ (never deleted).
# An unchanged file (same size and modification time as at its last check) is not re-hashed
# unless -FullVerify.
param(
    [string]$Pick = "default",
    [string]$Role = "",
    [switch]$FullVerify
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
Set-Location $Root
. (Join-Path $PSScriptRoot "lib\download.ps1")
if ($env:FULL_VERIFY -eq "1") { $FullVerify = $true }

function Get-Field($o, [string]$name) { if ($o.PSObject.Properties.Name -contains $name) { $o.$name } else { $null } }
function Get-Fingerprint([string]$Path) { $i = Get-Item -LiteralPath $Path; "$($i.Length) $($i.LastWriteTimeUtc.Ticks)" }

$manifest = Get-Content -Raw "config\models-manifest.json" | ConvertFrom-Json
$entries = @($manifest.candidates | Where-Object { $_.pick -eq $Pick -and (-not $Role -or $_.role -eq $Role) })
if ($entries.Count -eq 0) { throw "fetch-models: no manifest entries for pick='$Pick'$(if ($Role) { " role='$Role'" })" }
$verified = Join-Path $Root ".cache\verified"
New-Item -ItemType Directory -Force -Path $verified | Out-Null

foreach ($e in $entries) {
    $notice = Get-Field $e "notice"
    if ($notice) { Write-Warning "fetch-models: LICENSE NOTICE: $notice" }
    $dirRel = Get-Field $e "dir"; if (-not $dirRel) { $dirRel = "models/$($e.role)" }
    $dir = Join-Path $Root ($dirRel -replace '/', '\')
    $inactive = Join-Path $Root ("models-inactive\" + (($dirRel -split '/', 2)[1] -replace '/', '\'))
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    if (-not (Get-Field $e "tested")) { Write-Warning "fetch-models: $($e.file) is untested with this repo" }
    $path = Join-Path $dir $e.file
    $fresh = $false
    if (Test-Path -LiteralPath $path) { Write-Host "fetch-models: $path exists" }
    elseif (Test-Path -LiteralPath (Join-Path $inactive $e.file)) {
        Write-Host "fetch-models: restoring $(Join-Path $inactive $e.file)"
        Move-Item -LiteralPath (Join-Path $inactive $e.file) -Destination $dir
    } else {
        $url = "https://huggingface.co/$($e.repo)/resolve/$($e.revision)/$($e.file)"
        Write-Host "fetch-models: $url -> $path"
        Get-VerifiedFile -Url $url -Dest $path -Sha256 $e.sha256 -Tag "fetch-models"
        $fresh = $true
    }
    $stamp = Join-Path $verified $e.sha256
    if (-not $fresh) {
        if (-not $FullVerify -and (Test-Path -LiteralPath $stamp) -and ((Get-Content -LiteralPath $stamp -TotalCount 1) -eq (Get-Fingerprint $path))) {
            Write-Host "fetch-models: $($e.file) unchanged since its last sha256 check (-FullVerify re-hashes)"
        } else {
            $got = Get-Sha256 $path
            if ($got -ne $e.sha256) {
                Move-Item -Force -LiteralPath $path -Destination "$path.bad"
                throw "fetch-models: sha256 mismatch for existing $path (got $got); moved to $path.bad"
            }
        }
    }
    # only now (file verified) park any other model of this role, so the router sees exactly one .gguf
    Get-ChildItem -LiteralPath $dir -Filter *.gguf | Where-Object { $_.Name -ne $e.file -and $_.Name -notmatch 'mmproj' } | ForEach-Object {
        New-Item -ItemType Directory -Force -Path $inactive | Out-Null
        Write-Host "fetch-models: parking $($_.FullName) -> $inactive\"
        Move-Item -LiteralPath $_.FullName -Destination $inactive
    }
    Set-Content -LiteralPath $stamp -Value (Get-Fingerprint $path) -Encoding ASCII
    Write-Host "fetch-models: OK $($e.role) = $($e.file)"
}
Write-Host "fetch-models: done. A running server picks up swaps via GET /models?reload=1 (or restart scripts\serve.ps1)."
