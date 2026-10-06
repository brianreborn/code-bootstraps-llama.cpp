# Move named GGUF files into the shared store. Does not scan the home directory.
#   powershell -File scripts\cache-model.ps1 FILE [LAYOUT] ...
# LAYOUT is models/<role>/name.gguf, models-optional/..., or models-inactive/...
# One path: the layout is taken from that path. A different existing destination
# is refused and both files stay. The same bytes succeed and are not rewritten.
param(
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$PathArgs
)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot "lib\common.ps1")

function Get-CacheLayout([string]$Path) {
    $n = $Path -replace '\\', '/'
    foreach ($prefix in @('models-optional/', 'models-inactive/', 'models/')) {
        $idx = $n.LastIndexOf($prefix)
        if ($idx -ge 0) { return $n.Substring($idx) }
    }
    return $null
}

function Test-SameBytes([string]$A, [string]$B) {
    $ia = Get-Item -LiteralPath $A
    $ib = Get-Item -LiteralPath $B
    if ($ia.Length -ne $ib.Length) { return $false }
    return ((Get-Sha256 $A) -eq (Get-Sha256 $B))
}

function Move-OneGguf([string]$Src, [string]$Layout) {
    if (-not (Test-Path -LiteralPath $Src -PathType Leaf)) { throw "cache-model: not a file: $Src" }
    $norm = $Layout -replace '\\', '/'
    if ($norm -notlike 'models/*' -and $norm -notlike 'models-optional/*' -and $norm -notlike 'models-inactive/*') {
        throw "cache-model: layout must start with models/, models-optional/, or models-inactive/: $Layout"
    }
    if ($norm -notlike '*.gguf') { throw "cache-model: not a .gguf layout: $Layout" }
    if ($norm -like '*..*') { throw "cache-model: refusing layout with ..: $Layout" }
    $dest = Join-Child (Get-GgufHome) $norm
    if (Test-Path -LiteralPath $dest) {
        if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Test-SameFile $Src $dest)) {
            Write-Host "cache-model: already in the store: $dest"
            return
        }
        if ((Test-Path -LiteralPath $dest -PathType Leaf) -and (Test-SameBytes $Src $dest)) {
            Write-Host "cache-model: destination already has the same bytes: $dest"
            return
        }
        throw "cache-model: refusing to overwrite a different file: $dest"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
    Move-Item -LiteralPath $Src -Destination $dest
    Write-Host "cache-model: moved to $dest"
}

if ($null -eq $PathArgs -or @($PathArgs).Count -eq 0) {
    throw "usage: cache-model.ps1 FILE [LAYOUT] ..."
}
$items = @($PathArgs)
$i = 0
$failed = $false
while ($i -lt $items.Count) {
    $src = $items[$i]
    $i++
    $layout = $null
    if ($i -lt $items.Count) {
        $nxt = ($items[$i] -replace '\\', '/')
        if ($nxt -like 'models/*' -or $nxt -like 'models-optional/*' -or $nxt -like 'models-inactive/*') {
            $layout = $nxt
            $i++
        }
    }
    if (-not $layout) { $layout = Get-CacheLayout $src }
    if (-not $layout) {
        Write-Host "cache-model: cannot tell the store layout from '$src'; pass models/... explicitly"
        $failed = $true
        continue
    }
    try { Move-OneGguf $src $layout } catch {
        Write-Host $_.Exception.Message
        $failed = $true
    }
}
if ($failed) { throw "cache-model: refused or failed" }
