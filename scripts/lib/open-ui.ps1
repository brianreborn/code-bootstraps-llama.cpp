# Started by scripts\start.ps1 in the same console: waits until the router answers with the
# API key, prints the URL and the key (copied to the clipboard), then opens the browser.
param([int]$Port = 9931, [switch]$NoBrowser, [int]$ParentPid = 0)
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$keyFile = Join-Path $Root ".secrets\api-keys"
$url = "http://127.0.0.1:$Port/?model=coder"
$key = $null; $ready = $false
for ($i = 0; $i -lt 600; $i++) {   # up to 10 min (first model load on a slow disk)
    if ($ParentPid -and -not (Get-Process -Id $ParentPid -ErrorAction SilentlyContinue)) { exit 0 }   # launcher gone
    if (Test-Path -LiteralPath $keyFile) {
        $key = Get-Content -LiteralPath $keyFile | Where-Object { $_.Trim() -and -not $_.StartsWith("#") } | Select-Object -First 1
    }
    if ($key) {
        try { Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Uri "http://127.0.0.1:$Port/models" -Headers @{ Authorization = "Bearer $($key.Trim())" } | Out-Null; $ready = $true; break }
        catch { }
    }
    Start-Sleep -Seconds 1
}
if (-not $ready) { exit 0 }
$key = $key.Trim()
$copied = $false
try { Set-Clipboard -Value $key -ErrorAction Stop; $copied = $true } catch { }
Write-Host ""
Write-Host "  Web UI:  $url"
Write-Host "  API key: $key$(if ($copied) { '   (copied to the clipboard)' })"
Write-Host "  The first time, the page asks for the API key: paste it there."
Write-Host "  Files the agent creates go to: $(Join-Path $Root 'workspace')"
Write-Host "  Close this window (or Ctrl-C) to stop the server."
Write-Host ""
if (-not $NoBrowser) { Start-Process $url }
