# One stable API key per llama-server instance (port): the PowerShell twin of
# scripts/lib/instance-key.sh (docs/api-key-design.md). Dot-sourced by serve.ps1 and open-ui.ps1.
# The key lives at %APPDATA%\familia\instances\<port>\api-keys (XDG_CONFIG_HOME or ~/.config off
# Windows; $env:API_KEY_FILE overrides), readable by this user only, created atomically ONLY when
# missing (adopting a legacy .secrets\api-keys), never rotated. Nothing here prints a key.

function Test-InstanceKeyWindows { [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT }

function Get-InstanceKeyFile([int]$Port) {
    if ($env:API_KEY_FILE) { return $env:API_KEY_FILE }
    $base = if (Test-InstanceKeyWindows) { $env:APPDATA } elseif ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $HOME ".config" }
    return (Join-Path (Join-Path (Join-Path (Join-Path $base "familia") "instances") "$Port") "api-keys")
}

function Set-InstanceKeyPrivate([string]$Path, [bool]$Dir) {
    if (Test-InstanceKeyWindows) {
        $grant = if ($Dir) { "$($env:USERNAME):(OI)(CI)F" } else { "$($env:USERNAME):F" }
        icacls $Path /inheritance:r /grant:r $grant | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "icacls could not restrict $Path (exit $LASTEXITCODE); the API key would be readable by others" }
    } else { chmod $(if ($Dir) { "700" } else { "600" }) $Path }
}

function Get-InstanceKeyLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    return @(Get-Content -LiteralPath $Path | Where-Object { $_.Trim() -and -not $_.StartsWith("#") } | ForEach-Object { $_.Trim() })
}

# Initialize-InstanceKey <file> [legacy-file]: create <file> if missing or empty, never overwrite.
function Initialize-InstanceKey([string]$KeyFile, [string]$LegacyFile = "") {
    $keyDir = Split-Path -Parent $KeyFile
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    Set-InstanceKeyPrivate $keyDir $true
    if (-not (Test-Path -LiteralPath $KeyFile) -or (Get-Item -LiteralPath $KeyFile).Length -eq 0) {
        # private temp file in the same dir, then an atomic no-overwrite Move: if another starter won
        # the bootstrap race the Move throws and everyone reads the winner's key
        $tmp = Join-Path $keyDir (".api-keys.{0}.{1}.tmp" -f $PID, [guid]::NewGuid().ToString("N"))
        New-Item -ItemType File -Force -Path $tmp | Out-Null
        Set-InstanceKeyPrivate $tmp $false
        $legacy = if ($LegacyFile) { @(Get-InstanceKeyLines $LegacyFile) } else { @() }
        $lines = if ($legacy.Count -gt 0) {
            @("# llama-server API key(s), one per line (adopted from $LegacyFile)") + $legacy
        } else {
            $bytes = New-Object byte[] 24; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
            @("# llama-server API key(s), one per line", (($bytes | ForEach-Object { $_.ToString("x2") }) -join ""))
        }
        [System.IO.File]::WriteAllText($tmp, ((@($lines) -join "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
        try { [System.IO.File]::Move($tmp, $KeyFile); Write-Host "instance-key: created $KeyFile" }
        catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
    Set-InstanceKeyPrivate $KeyFile $false
}
