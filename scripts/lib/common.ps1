# Shared by the scripts\*.ps1 (dot-sourced). Windows PowerShell 5.1 and PowerShell 7.
# The scripts run under Set-StrictMode -Version Latest: every script-scope variable read here is
# set here first (reading an unset one throws). tests/test-ps1-helpers.ps1 runs these functions.

# scripts/panel.py writes .cache/panel.env as POSIX defaults: : "${KEY:=value}"
# A variable that is already set wins. Call this before reading those settings.
function Import-PanelEnv([string]$Root) {
    $path = Join-Path $Root ".cache\panel.env"
    if (-not (Test-Path -LiteralPath $path)) { return }
    foreach ($line in @(Get-Content -LiteralPath $path)) {
        if ($null -eq $line) { continue }
        if ($line -match '^: "\$\{([A-Z][A-Z0-9_]*):=(.*)\}"$') {
            $key = $Matches[1]
            if ([string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($key))) {
                Set-Item -Path ("Env:" + $key) -Value $Matches[2]
            }
        }
    }
}

# Param() defaults are bound before the script body, so a panel value loaded above
# has to be copied into a parameter the user did not pass and did not set in the environment.
# $Prior is that environment value from before Import-PanelEnv. Call from the script body.
function Use-PanelValue([string]$Variable, [string]$EnvName, [bool]$Bound, [string]$Prior) {
    if ($Bound) { return }
    if (-not [string]::IsNullOrEmpty($Prior)) { return }
    $now = [Environment]::GetEnvironmentVariable($EnvName)
    if ([string]::IsNullOrEmpty($now)) { return }
    if ($Variable -eq "Port") { Set-Variable -Name $Variable -Scope 1 -Value ([int]$now); return }
    Set-Variable -Name $Variable -Scope 1 -Value $now
}

# A parameter typed on the command line wins over the panel, including for child processes.
function Publish-BoundParam([string]$Variable, [string]$EnvName, [bool]$Bound) {
    if (-not $Bound) { return }
    $value = Get-Variable -Name $Variable -Scope 1 -ValueOnly
    Set-Item -Path ("Env:" + $EnvName) -Value ([string]$value)
}
$script:FileIdFailed = $false   # Add-Type of CodeBootstraps.FileId failed once: do not retry

# Text files for llama-server and the shell scripts must be UTF-8 WITHOUT a byte order mark:
# Set-Content -Encoding utf8 on 5.1 writes one, and llama-server b11374 then fails with
# "failed to parse server config file". .NET resolves relative paths against the process
# directory, not the PowerShell location, so the path is made absolute first.
function Write-TextFile([string]$Path, $Lines) {
    $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $text = (@($Lines) -join "`n") + "`n"
    [System.IO.File]::WriteAllText($full, $text, (New-Object System.Text.UTF8Encoding $false))
}

# Identity and change times of a file, from the open handle (Windows): volume serial + file
# index (the NTFS "inode"; the same for a path through subst, a junction or a symlink), and
# FILE_BASIC_INFO's creation, last-write and change times. C# 5: Windows PowerShell 5.1
# compiles it with the .NET 4 csc.
$script:FileIdTypeDef = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace CodeBootstraps {
    public static class FileId {
        // BY_HANDLE_FILE_INFORMATION: FILETIMEs are 4-byte aligned (Pack = 4, 52 bytes)
        [StructLayout(LayoutKind.Sequential, Pack = 4)]
        struct ByHandleInfo {
            public uint Attributes; public long Creation; public long Access; public long Write;
            public uint VolumeSerial; public uint SizeHigh; public uint SizeLow; public uint Links;
            public uint IndexHigh; public uint IndexLow;
        }
        // FILE_BASIC_INFO (40 bytes)
        [StructLayout(LayoutKind.Sequential)]
        struct BasicInfo { public long Creation; public long Access; public long Write; public long Change; public uint Attributes; }
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandle(SafeFileHandle h, out ByHandleInfo info);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle h, int infoClass, out BasicInfo info, uint size);
        static FileStream Open(string path) {
            return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        }
        // "<volume serial>-<file index>"
        public static string Identity(string path) {
            using (FileStream fs = Open(path)) {
                ByHandleInfo i;
                if (!GetFileInformationByHandle(fs.SafeFileHandle, out i)) throw new IOException("GetFileInformationByHandle failed");
                return i.VolumeSerial.ToString("x8") + "-" + ((((ulong)i.IndexHigh) << 32) | i.IndexLow).ToString("x16");
            }
        }
        // "<size> <write> <creation> <change> <identity>" (times in FILETIME ticks)
        public static string Fingerprint(string path) {
            using (FileStream fs = Open(path)) {
                ByHandleInfo i; BasicInfo b;
                if (!GetFileInformationByHandle(fs.SafeFileHandle, out i)) throw new IOException("GetFileInformationByHandle failed");
                if (!GetFileInformationByHandleEx(fs.SafeFileHandle, 0, out b, (uint)Marshal.SizeOf(typeof(BasicInfo)))) throw new IOException("GetFileInformationByHandleEx failed");
                ulong size = (((ulong)i.SizeHigh) << 32) | i.SizeLow;
                string id = i.VolumeSerial.ToString("x8") + "-" + ((((ulong)i.IndexHigh) << 32) | i.IndexLow).ToString("x16");
                return "w " + size + " " + b.Write + " " + b.Creation + " " + b.Change + " " + id;
            }
        }
        public static string StructSizes() {
            return Marshal.SizeOf(typeof(ByHandleInfo)) + " " + Marshal.SizeOf(typeof(BasicInfo));
        }
    }
}
'@
function Initialize-FileId {
    if ($script:FileIdFailed) { throw "CodeBootstraps.FileId unavailable" }
    if (-not ("CodeBootstraps.FileId" -as [type])) {
        try { Add-Type -TypeDefinition $script:FileIdTypeDef } catch { $script:FileIdFailed = $true; throw }
    }
}

# Fingerprint of a verified model (.cache\verified\<sha256>); while it is unchanged the file is
# not re-hashed ($env:FULL_VERIFY=1 re-hashes). Windows: size, last-write, creation and
# change times and the file identity; elsewhere (PowerShell 7) the same as fingerprint() in
# scripts/lib/common.sh: "<size> <mtime> <ctime> <inode>".
function Get-Fingerprint([string]$Path) {
    $full = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (Test-Windows) {
        try { Initialize-FileId; return [CodeBootstraps.FileId]::Fingerprint($full) } catch { }
        $i = Get-Item -LiteralPath $full   # no P/Invoke (constrained language?): weaker, times only
        return "t $($i.Length) $($i.LastWriteTimeUtc.Ticks) $($i.CreationTimeUtc.Ticks)"
    }
    $out = & stat -c '%s %Y %Z %i' -L $full 2>$null
    if (-not $out) { $out = & stat -L -f '%z %m %c %i' $full }
    return "$out".Trim()
}

# Same file? (volume + file index on Windows, so subst drives, junctions and symlinks match;
# else the full paths, case-insensitively)
function Test-SameFile([string]$A, [string]$B) {
    if (-not $A -or -not $B) { return $false }
    if (Test-Windows) {
        try { Initialize-FileId; return ([CodeBootstraps.FileId]::Identity($A) -eq [CodeBootstraps.FileId]::Identity($B)) } catch { }
    }
    return ([IO.Path]::GetFullPath($A) -ieq [IO.Path]::GetFullPath($B))
}

# Did llama-server write its own "listening on http://<host>:<Port>" line to its --log-file?
# It logs that only after the bind succeeded. The log is open for writing by llama-server, so it
# is opened with ReadWrite+Delete sharing. param() block (not "function f(...)"): serve.ps1 hands
# this function's text to its readiness runspace, and only a param block is part of that text.
function Test-ServerSaidListening {
    param([string]$LogFile, [int]$Port)
    $share = [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete   # NOT inside a New-Object argument list
    $text = ""
    try {
        $fs = [IO.FileStream]::new($LogFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, $share)
        try { $text = [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
    } catch { return $false }
    return [regex]::IsMatch($text, "listening on http://\S*:$Port(?![0-9])")
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
