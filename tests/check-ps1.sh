#!/usr/bin/env bash
# PowerShell checks without Windows: tests/check-ps1.ps1 (parse + PowerShell 6+ constructs), then a
# Windows PowerShell 5.1 emulation under pwsh: a copy of scripts/ in which $IsWindows, $IsLinux,
# $IsMacOS and $IsCoreCLR are renamed to variables that do not exist (as in 5.1), run under the
# scripts' own Set-StrictMode -Version Latest. fetch-llama.ps1 -PrintPlatform must then take the
# Windows path (start.bat on 5.1 failed exactly there). tests/model_selection_matrix.py runs
# start.ps1 / serve.ps1 the same way (grid "ps51"). tests/test-ps1-helpers.ps1 then EXECUTES the
# helpers serve.ps1 relies on (readiness log check, file identity, fingerprint) on both copies;
# tests/test_serve_ready.sh runs serve.ps1 end to end with the real llama-server.
#   PWSH=/path/to/pwsh tests/check-ps1.sh
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; root="$(dirname "$here")"
PWSH="${PWSH:-$(command -v pwsh || true)}"
[[ -n "$PWSH" ]] || { echo "check-ps1: pwsh not found (set PWSH)" >&2; exit 1; }
"$PWSH" -NoProfile -File "$here/check-ps1.ps1"
h="$("$PWSH" -NoProfile -File "$here/test-ps1-helpers.ps1" -Scripts "$root/scripts" 2>&1)" || { echo "$h"; echo "check-ps1: test-ps1-helpers.ps1 failed" >&2; exit 1; }
echo "check-ps1: OK helpers run under strict mode (test-ps1-helpers.ps1)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
cp -r "$root/scripts" "$root/config" "$tmp/"
python3 "$here/ps51_emulation.py" "$tmp/scripts"
out="$(env -u PROCESSOR_ARCHITECTURE -u PROCESSOR_ARCHITEW6432 "$PWSH" -NoProfile -File "$tmp/scripts/fetch-llama.ps1" -PrintPlatform 2>&1)" || { echo "check-ps1: 5.1 emulation: fetch-llama.ps1 failed: $out" >&2; exit 1; }
[[ "$out" == windows-* ]] || { echo "check-ps1: 5.1 emulation: fetch-llama.ps1 -PrintPlatform printed '$out', want windows-*" >&2; exit 1; }
echo "check-ps1: OK 5.1 emulation (no \$IsWindows/\$IsLinux/\$IsMacOS, strict mode): fetch-llama.ps1 -PrintPlatform = $out"
h="$("$PWSH" -NoProfile -File "$here/test-ps1-helpers.ps1" -Scripts "$tmp/scripts" 2>&1)" || { echo "$h"; echo "check-ps1: 5.1 emulation: test-ps1-helpers.ps1 failed" >&2; exit 1; }
echo "check-ps1: OK 5.1 emulation: helpers run, FileId compiles and falls back off Windows"
