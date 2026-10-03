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

# Manifest of an unpacked directory ("f <size> <relative path>", sorted, / separators), the
# file part of tree_manifest() in scripts/lib/common.sh (the Windows archives have no
# symlinks; links are skipped); .verified-* stamps excluded.
function Get-TreeManifest([string]$Dir) {
    $base = (Resolve-Path -LiteralPath $Dir).Path.TrimEnd('\', '/')
    $rows = Get-ChildItem -LiteralPath $base -Recurse -File -Force | Where-Object { $_.Name -notlike ".verified-*" -and -not ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) } |
        ForEach-Object { "f $($_.Length) " + $_.FullName.Substring($base.Length + 1).Replace('\', '/') }
    @($rows | Sort-Object -CaseSensitive)
}

# Windows only (5.1 is always Windows; $IsWindows exists from PowerShell 6)
function Test-Windows { -not (Test-Path Variable:IsWindows) -or $IsWindows }
