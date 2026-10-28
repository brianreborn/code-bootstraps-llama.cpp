# Windows counterpart of scripts/install-addon.sh: install a starter-pack add-on / MCP pick from
# its pinned installer, the safe way: download to a NAMED file, check its sha256, then run it.
# Never piped into Invoke-Expression.
#   powershell -ExecutionPolicy Bypass -File scripts\install-addon.ps1 [-Fetch] <pick>
# The pick needs "_installer_ps1": {"url": "https://...", "sha256": "<64 hex>"} in
# config\mcp-servers.starter.json (mcpServers or addons.*). No pin = refused (fail-closed).
# -Fetch downloads + verifies only. -Resolve prints "<url> <sha256>" and exits (tests).
# Env: ADDON_STARTER (starter file), ADDON_DIR (default .cache\installers).
param([Parameter(Position = 0)][string]$Pick = "", [switch]$Fetch, [switch]$Resolve)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\common.ps1")
. (Join-Path $PSScriptRoot "lib\download.ps1")
if ($Pick -notmatch '^[A-Za-z0-9._-]+$' -or $Pick -match '^\.+$') { throw "install-addon: usage: install-addon.ps1 [-Fetch] <pick>" }
$starterPath = if ($env:ADDON_STARTER) { $env:ADDON_STARTER } else { Join-Path $Root "config\mcp-servers.starter.json" }
$starter = Get-Content -Raw -LiteralPath $starterPath | ConvertFrom-Json
$groups = @($starter.mcpServers)
if ($starter.PSObject.Properties.Name -contains "addons") {
    foreach ($p in $starter.addons.PSObject.Properties) {
        if (-not $p.Name.StartsWith("_") -and $p.Value -is [psobject]) { $groups += $p.Value }
    }
}
$entry = $null
foreach ($g in $groups) { if ($g -and ($g.PSObject.Properties.Name -contains $Pick)) { $entry = $g.$Pick; break } }
if ($null -eq $entry) { throw "install-addon: unknown pick '$Pick'" }
if (-not ($entry.PSObject.Properties.Name -contains "_installer_ps1")) { throw "install-addon: pick '$Pick' has no pinned _installer_ps1 (see its _install note)" }
$url = [string]$entry._installer_ps1.url
$sha = ([string]$entry._installer_ps1.sha256).ToLowerInvariant()
if (-not $url.StartsWith("https://")) { throw "install-addon: pick '$Pick': installer url must be https" }
if ($sha -notmatch '^[0-9a-f]{64}$') { throw "install-addon: pick '$Pick': installer sha256 missing or malformed; refusing" }
if ($Resolve) { Write-Output "$url $sha"; exit 0 }
$dir = if ($env:ADDON_DIR) { $env:ADDON_DIR } else { Join-Path $Root ".cache\installers" }
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$file = Join-Path $dir "install-$Pick.ps1"
Get-VerifiedFile $url $file $sha "install-addon"
Write-Host "install-addon: $Pick installer saved to $file (sha256 ok)"
if ($Fetch) { Write-Host "install-addon: read it, then run: powershell -ExecutionPolicy Bypass -File `"$file`""; exit 0 }
& $file
