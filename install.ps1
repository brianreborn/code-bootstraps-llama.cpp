# Fetch this repository, check sha256, unpack, then run start.bat.
# Windows PowerShell 5.1 and PowerShell 7.
#   irm https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.ps1 | iex
# EXPECTED_SHA256 stays empty until a published archive is hashed. Until then this
# script refuses to download. Tests set INSTALL_URL, INSTALL_SHA256, PREFIX, and
# INSTALL_NO_START=1. A second run unpacks again only when the digest changes.
$ErrorActionPreference = "Stop"
$Expected = ""
if ($env:INSTALL_URL) { $Url = $env:INSTALL_URL } else { $Url = "https://github.com/brianreborn/code-bootstraps-llama.cpp/archive/refs/heads/main.tar.gz" }
if ($env:INSTALL_SHA256) { $Sha = $env:INSTALL_SHA256.ToLowerInvariant() } else { $Sha = $Expected }
if ($env:PREFIX) { $Prefix = $env:PREFIX } else { $Prefix = Join-Path $env:USERPROFILE "code-bootstraps-llama.cpp" }

function Die([string]$msg) { throw "install.ps1: $msg" }
if (-not $Sha) { Die "no sha256 is published for this installer yet. Set INSTALL_SHA256, or fill EXPECTED_SHA256 after a release archive is hashed." }
if ($Sha -notmatch '^[0-9a-f]{64}$') { Die "sha256 must be 64 hex characters" }
if ($Url -notmatch '^(https://|file://)') { Die "refusing $Url (https only, or file:// for a local test)" }

$stampPath = Join-Path $Prefix ".cache\install.sha256"
$start = Join-Path $Prefix "start.bat"
$have = ""
if (Test-Path $stampPath) { $have = (Get-Content $stampPath -TotalCount 1).Trim().ToLowerInvariant() }
if ($have -eq $Sha -and (Test-Path $start)) {
    Write-Host "install.ps1: $Prefix already matches this archive"
} else {
    $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("cbl-install-" + [System.Guid]::NewGuid().ToString("n"))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        $arc = Join-Path $tmp "src.tar.gz"
        if ($Url.StartsWith("file://")) {
            $local = $Url.Substring(7)
            if ($local.StartsWith("/") -and $local.Length -gt 3 -and $local.Substring(2, 1) -eq ":") { $local = $local.Substring(1) }
            Copy-Item $local $arc
        } else {
            Invoke-WebRequest -Uri $Url -OutFile $arc -UseBasicParsing
        }
        $got = (Get-FileHash -Algorithm SHA256 $arc).Hash.ToLowerInvariant()
        if ($got -ne $Sha) { Die "sha256 mismatch (got $got, want $Sha). Not unpacked." }
        & tar -xzf $arc -C $tmp
        if ($LASTEXITCODE -ne 0) { Die "tar failed" }
        $tops = @(Get-ChildItem $tmp -Directory)
        if ($tops.Count -ne 1) { Die "archive must contain one top directory" }
        $top = $tops[0].FullName
        if (-not (Test-Path (Join-Path $top "start.sh"))) { Die "archive has no start.sh" }
        New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
        & tar -C $top -cf - . | tar -C $Prefix -xf -
        if ($LASTEXITCODE -ne 0) { Die "unpack into $Prefix failed" }
        New-Item -ItemType Directory -Force -Path (Join-Path $Prefix ".cache") | Out-Null
        Set-Content -Path $stampPath -Value $Sha -Encoding ascii
        Write-Host "install.ps1: installed into $Prefix"
    } finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    }
}

if ($env:INSTALL_NO_START -eq "1") { return }
& (Join-Path $Prefix "start.bat")
