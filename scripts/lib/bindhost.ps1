# Same bind rules as scripts/lib/bindhost.sh. Windows PowerShell 5.1.
# A single external address is also bound on 127.0.0.1. Wildcards and loopback stay as given.

function Get-BindHost([string]$h) {
    if (-not $h) { $h = "127.0.0.1" }
    if ($h -match '(^|,)(127\.0\.0\.1|localhost|::1|0\.0\.0\.0|::)(,|$)') { return $h }
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
        if (-not $part) { continue }
        if ($part -in @("127.0.0.1", "localhost", "::1", "0.0.0.0", "::")) { continue }
        $out.Add($part)
    }
    return ,@($out.ToArray())
}

function Format-UrlHost([string]$h) {
    if ($h -match ':') { return "[$h]" }
    return $h
}
