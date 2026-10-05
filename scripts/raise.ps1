# Grant this account "Lock pages in memory", once, and again later if it is lost.
# Re-run from an elevated PowerShell: scripts\raise.ps1
# Windows has no chroot and no setuid helper. Sign out and back in before the right applies.
#Requires -Version 5.1
$ErrorActionPreference = "Stop"

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    Write-Host "raise.ps1: asking for administrator once"
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $PSCommandPath)
    Start-Process -FilePath "powershell.exe" -Verb RunAs -Wait -ArgumentList $args
    return
}

$account = if ($env:RAISE_USER) { $env:RAISE_USER } else { "$env:USERDOMAIN\$env:USERNAME" }
$sid = (New-Object System.Security.Principal.NTAccount($account)).Translate([System.Security.Principal.SecurityIdentifier]).Value
$tmp = Join-Path $env:TEMP ("cbl-raise-" + [guid]::NewGuid().ToString("n"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    $cfg = Join-Path $tmp "sec.cfg"
    $db = Join-Path $tmp "sec.sdb"
    $out = & secedit /export /cfg $cfg /areas USER_RIGHTS 2>&1
    if ($LASTEXITCODE -ne 0) { throw "secedit /export failed: $out" }
    $lines = Get-Content -LiteralPath $cfg
    $found = $false
    $priv = "SeLockMemoryPrivilege"
    $token = "*$sid"
    $new = foreach ($line in $lines) {
        if ($line -like "$priv*") {
            $found = $true
            if ($line -notlike "*$token*") {
                if ($line.Trim().EndsWith("=")) { "$line$token" } else { "$line,$token" }
            } else { $line }
        } else { $line }
    }
    if (-not $found) { throw "secedit export has no $priv line" }
    Set-Content -LiteralPath $cfg -Value $new -Encoding Unicode
    $out = & secedit /configure /db $db /cfg $cfg /areas USER_RIGHTS 2>&1
    if ($LASTEXITCODE -ne 0) { throw "secedit /configure failed: $out" }
    Write-Host "raise.ps1: $account may lock pages in memory. Sign out and back in."
    Write-Host "raise.ps1: no setuid helper exists on Windows."
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
