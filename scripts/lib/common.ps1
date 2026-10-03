# Shared by the scripts\*.ps1 (dot-sourced). Windows PowerShell 5.1 and PowerShell 7.

# Text files for llama-server and the shell scripts must be UTF-8 WITHOUT a byte order mark:
# Set-Content -Encoding utf8 on 5.1 writes one, and llama-server b11374 then fails with
# "failed to parse server config file". .NET resolves relative paths against the process
# directory, not the PowerShell location, so the path is made absolute first.
function Write-TextFile([string]$Path, $Lines) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $text = (@($Lines) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
}

# "<size> <mtime in seconds>", the same format as fingerprint() in scripts/lib/common.sh
function Get-Fingerprint([string]$Path) {
    $i = Get-Item -LiteralPath $Path
    $unix0 = New-Object DateTime 1970, 1, 1, 0, 0, 0, ([DateTimeKind]::Utc)
    $epoch = [int64][Math]::Floor(($i.LastWriteTimeUtc - $unix0).TotalSeconds)
    "$($i.Length) $epoch"
}

function Get-Sha256([string]$Path) { (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToLowerInvariant() }

# Manifest of an unpacked directory ("f <size> <sha256> <relative path>", sorted, / separators),
# the file part of tree_manifest() in scripts/lib/common.sh (the Windows archives have no
# symlinks; links are skipped); .verified-* stamps excluded.
function Get-TreeManifest([string]$Dir) {
    $base = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\', '/')
    $rows = Get-ChildItem -LiteralPath $base -Recurse -File -Force | Where-Object { $_.Name -notlike ".verified-*" -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { "f $($_.Length) $(Get-Sha256 $_.FullName) " + $_.FullName.Substring($base.Length + 1).Replace('\', '/') }
    @($rows | Sort-Object -CaseSensitive)
}

# Windows PowerShell 5.1 has no $IsWindows / $IsLinux / $IsMacOS (PowerShell 6+), and reading an
# unset variable under Set-StrictMode throws: every OS test goes through these two functions.
# (tests/check-ps1.sh fails on any other use of those variables.)
function Test-Windows { -not (Test-Path Variable:IsWindows) -or $IsWindows }
function Get-OsName {
    if (Test-Windows) { return "windows" }
    if ((Test-Path Variable:IsMacOS) -and $IsMacOS) { return "macos" }
    return "linux"
}

# PowerShell binds "--name" on a "-File" command line to the script's own -Name parameter
# (prefix match: --tools -> -Tools, --threads -> -Threads), so a llama-server flag with the
# same name would silently change a launcher setting. Refuse it; the user writes -Name.
# Only when this script is the one powershell -File started (start.ps1 passes its leftovers to
# serve.ps1 as -Extra strings, which PowerShell does not bind).
function Assert-NoDoubleDashParam([string[]]$Names, [string]$Tag, [string]$ScriptPath) {
    $argv = @([Environment]::GetCommandLineArgs())
    $i = 0; while ($i -lt $argv.Count -and $argv[$i] -notmatch '^-(f|file)$') { $i++ }
    if ($i + 1 -ge $argv.Count -or (Split-Path -Leaf $argv[$i + 1]) -ne (Split-Path -Leaf $ScriptPath)) { return }
    for ($j = $i + 2; $j -lt $argv.Count; $j++) {
        if ($argv[$j] -match '^--([A-Za-z][A-Za-z0-9]*)$') {
            $n = $Matches[1]
            $hit = @($Names | Where-Object { $_ -like "$n*" })
            if ($hit.Count -gt 0) {
                throw "${Tag}: '$($argv[$j])' would be read as this script's -$($hit[0]) parameter, not passed to llama-server. Write -$($hit[0]) <value> for that setting."
            }
        }
    }
}
