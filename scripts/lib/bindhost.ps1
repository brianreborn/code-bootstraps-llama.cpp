# Same bind rules as scripts/lib/bindhost.sh. Windows PowerShell 5.1.
# A single external address is also bound on 127.0.0.1. Wildcards and loopback stay as given.

# Loopback rules, identical in bindhost.sh, bindhost.ps1 and scripts/lib/loopback.py:
# a comma-separated list, entries trimmed; an entry is loopback when it is localhost, ::1, [::1]
# or a dotted-quad 127.x.y.z. A value is loopback only when EVERY entry is; 0.0.0.0, ::, LAN
# addresses and empty entries are not.
function Test-LoopbackHost([string]$h) {
    if ($null -eq $h) { return $false }
    $e = $h.Trim().ToLowerInvariant()
    if ($e -eq "localhost" -or $e -eq "::1" -or $e -eq "[::1]") { return $true }
    if ($e -notmatch '^127\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$') { return $false }
    foreach ($i in 1..3) { if ([int]$Matches[$i] -gt 255) { return $false } }
    return $true
}

function Test-LoopbackList([string]$h) {
    if (-not $h) { return $false }
    foreach ($part in ($h -split ',')) {
        if (-not (Test-LoopbackHost $part)) { return $false }
    }
    return $true
}

function Get-BindHost([string]$h) {
    if (-not $h) { $h = "127.0.0.1" }
    if ($h -match '(^|,)(0\.0\.0\.0|::)(,|$)') { return $h }
    foreach ($part in ($h -split ',')) { if (Test-LoopbackHost $part) { return $h } }
    return "127.0.0.1,$h"
}

function Get-ProbeHost([string]$listen) {
    if ($listen -match '(^|,)(127\.0\.0\.1|localhost|0\.0\.0\.0|::)(,|$)') { return "127.0.0.1" }
    if ($listen -match '(^|,)::1(,|$)') { return "[::1]" }
    $first = ($listen -split ',')[0]
    if ($first -match ':') { return "[$first]" }
    return $first
}

function Get-PublicHosts([string]$h) {
    $listen = Get-BindHost $h
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($listen -split ',')) {
        $part = $part.Trim()
        if (-not $part) { continue }
        if ((Test-LoopbackHost $part) -or $part -eq "0.0.0.0" -or $part -eq "::") { continue }
        $out.Add($part)
    }
    # plain output (no ",@()" wrapper): callers use @(Get-PublicHosts ...), so none -> Count 0
    return $out.ToArray()
}

function Format-UrlHost([string]$h) {
    if ($h -match ':') { return "[$h]" }
    return $h
}
