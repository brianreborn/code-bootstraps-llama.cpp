# Shared by scripts\fetch-llama.ps1 and scripts\fetch-models.ps1: HTTPS download + sha256 check.
# (Get-Sha256 is in common.ps1, dot-sourced first.)

# Download $Url to $Dest via $Dest.part; the file only gets its final name once its sha256 matches.
# A mismatch is kept as $Dest.bad. curl.exe (Windows 10 1803+) resumes and shows progress;
# Invoke-WebRequest is the fallback.
function Get-VerifiedFile([string]$Url, [string]$Dest, [string]$Sha256, [string]$Tag = "download") {
    if (-not $Url.StartsWith("https://")) { throw "${Tag}: refusing non-HTTPS URL $Url" }
    $part = "$Dest.part"
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($curl) {
        # progress bar in a console; in a log (output redirected) only errors
        $progress = if ([Console]::IsErrorRedirected -or [Console]::IsOutputRedirected) { "-sS" } else { "--progress-bar" }
        & $curl.Source -fL $progress --proto '=https' --proto-redir '=https' --retry 3 -C - -o $part $Url
        if ($LASTEXITCODE -ne 0) { throw "${Tag}: download failed (curl exit $LASTEXITCODE): $Url" }
    } else {
        $old = $ProgressPreference; $ProgressPreference = "SilentlyContinue"   # the progress bar makes IWR very slow
        # Windows PowerShell 5.1 may default to TLS 1.0/1.1, which GitHub and Hugging Face refuse
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        try { Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $part -MaximumRedirection 5 }
        finally { $ProgressPreference = $old }
    }
    $got = Get-Sha256 $part
    if ($got -ne $Sha256.ToLowerInvariant()) {
        Move-Item -Force -LiteralPath $part -Destination "$Dest.bad"
        throw "${Tag}: sha256 mismatch for $(Split-Path -Leaf $Dest) (got $got, want $Sha256); kept as $Dest.bad"
    }
    Move-Item -Force -LiteralPath $part -Destination $Dest
    Write-Host "${Tag}: OK sha256 $(Split-Path -Leaf $Dest)"
}
