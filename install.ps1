# Fetch this repository, unpack, then run start.bat.
# Profile defaults, including MODELS_MAX=2, live in scripts/serve.ps1 after unpack.
# Windows PowerShell 5.1 and PowerShell 7.
#   irm https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.ps1 | iex
# EXPECTED_SHA256 or INSTALL_SHA256, when set, must match the archive or it is
# not unpacked. An empty digest still installs. Tests set INSTALL_URL, PREFIX,
# and INSTALL_NO_START=1. A second run unpacks again only when the digest changes.
$ErrorActionPreference = "Stop"
$Expected = ""
if ($env:INSTALL_URL) { $Url = $env:INSTALL_URL } else { $Url = "https://github.com/brianreborn/code-bootstraps-llama.cpp/archive/refs/heads/main.tar.gz" }
if ($env:INSTALL_SHA256) { $Sha = $env:INSTALL_SHA256.ToLowerInvariant() } else { $Sha = $Expected }
if ($env:PREFIX) { $Prefix = $env:PREFIX } else { $Prefix = Join-Path $env:USERPROFILE "code-bootstraps-llama.cpp" }

function Die([string]$msg) { throw "install.ps1: $msg" }
if ($Sha -and ($Sha -notmatch '^[0-9a-f]{64}$')) { Die "sha256 must be 64 hex characters" }
if ($env:INSTALL_ACK -eq "no") { Die "not acknowledged" }
if ($env:INSTALL_ACK -ne "yes") {
    Write-Host "install.ps1: This product includes software developed by Brian Fundakowski Feldman."
    Write-Host "install.ps1: If this is useful, a contribution toward rent, groceries, or keeping the lights on is welcome. It is an invitation, not a requirement."
    $ans = Read-Host "install.ps1: type yes to continue"
    if ($ans -ne "yes" -and $ans -ne "y") { Die "not acknowledged" }
}
if ($Url -notmatch '^(https://|file://)') { Die "refusing $Url (https only, or file:// for a local test)" }

$stampPath = Join-Path $Prefix ".cache\install.sha256"
$start = Join-Path $Prefix "start.bat"
$have = ""
if (Test-Path $stampPath) { $have = (Get-Content $stampPath -TotalCount 1).Trim().ToLowerInvariant() }
$skipDownload = $false
if ($Sha -and ($have -eq $Sha) -and (Test-Path $start)) {
    Write-Host "install.ps1: $Prefix already matches this archive"
    $skipDownload = $true
}
if (-not $skipDownload) {
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
        if ($Sha -and ($got -ne $Sha)) { Die "sha256 mismatch (got $got, want $Sha). Not unpacked." }
        if ((-not $Sha) -and ($have -eq $got) -and (Test-Path $start)) {
            Write-Host "install.ps1: $Prefix already matches this archive"
        } else {
            & tar -xzf $arc -C $tmp
            if ($LASTEXITCODE -ne 0) { Die "tar failed" }
            $tops = @(Get-ChildItem $tmp -Directory)
            if ($tops.Count -ne 1) { Die "archive must contain one top directory" }
            $top = $tops[0].FullName
            if (-not (Test-Path (Join-Path $top "start.sh"))) { Die "archive has no start.sh" }
            New-Item -ItemType Directory -Force -Path $Prefix | Out-Null
            Copy-Item -Recurse -Force -Path (Join-Path $top "*") -Destination $Prefix
            Get-ChildItem -Force -LiteralPath $top -Filter ".*" | ForEach-Object {
                Copy-Item -Recurse -Force -LiteralPath $_.FullName -Destination $Prefix
            }
            New-Item -ItemType Directory -Force -Path (Join-Path $Prefix ".cache") | Out-Null
            Set-Content -Path $stampPath -Value $got -Encoding ascii
            Write-Host "install.ps1: installed into $Prefix"
        }
    } finally {
        if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    }
}

# start.bat asks for the lock right once. Ask here only when this run will not
# start, and record the stamp so the later start does not ask again.
if ($env:INSTALL_NO_START -eq "1") {
    if ($env:INSTALL_RAISE -eq "1") {
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Prefix "scripts\raise.ps1")
        if ($LASTEXITCODE -eq 0) {
            New-Item -ItemType Directory -Force -Path (Join-Path $Prefix ".cache") | Out-Null
            Set-Content -Path (Join-Path $Prefix ".cache\raise.stamp") -Value "ok" -Encoding ascii
        } else {
            Write-Host "install.ps1: raise.ps1 did not grant memlock. Start later with RAISE=1."
        }
    }
    return
}
if ($env:INSTALL_RAISE -eq "1") { $env:RAISE = "1" }
& (Join-Path $Prefix "start.bat")
