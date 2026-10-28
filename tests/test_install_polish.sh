#!/bin/sh
# Install commands download to a named file then run it (no pipe one-liners);
# INSTALL_BRANCH selects the archive; start paths print their log files.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
bad() { echo "FAIL $*"; fail=$((fail + 1)); }
if git ls-files 2>/dev/null | grep -v '^tests/' | grep -E '\.(md|sh|ps1|bat|txt)$' |
   xargs grep -nE '(curl|wget|irm|iwr|Invoke-RestMethod|Invoke-WebRequest)\b[^|]*\|[[:space:]]*(sh|bash|iex|Invoke-Expression)\b' 2>/dev/null; then
  bad "pipe install one-liner(s) above"
fi
grep -q "curl -fsSLo install-cbl.sh https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.sh && \\\\$" README.md && grep -q "^  sh ./install-cbl.sh" README.md || bad "README lacks download-then-run sh form"
grep -q 'OutFile install-cbl.ps1' README.md || bad "README lacks download-then-run ps1 form"
grep -q 'refs/heads/${INSTALL_BRANCH:-main}.tar.gz' install.sh || bad "install.sh ignores INSTALL_BRANCH"
grep -q 'INSTALL_BRANCH' install.ps1 || bad "install.ps1 ignores INSTALL_BRANCH"
grep -q 'serve.sh: logs: router' scripts/serve.sh || bad "serve.sh does not print the router log"
grep -q 'serve.sh: logs: $ln $lp' scripts/serve.sh || bad "serve.sh does not print the log manifest"
[ "$(grep -c 'logs: $ROOT/.cache/server.log' start.sh)" -ge 3 ] || bad "start.sh detach paths do not print the server log"
grep -q '(BUILD_DIR + \\$ORIGIN rpath)' scripts/build-linux.sh || bad "build-linux.sh \$ORIGIN not escaped"
# the manifest loop prints name + path per line
d=$(mktemp -d); printf 'router\t/a/server.log\nembed\t/a/embed.log\n' > "$d/m"
out=$(while IFS="$(printf '\t')" read -r ln lp; do echo "serve.sh: logs: $ln $lp"; done < "$d/m"); rm -rf "$d"
[ "$out" = "serve.sh: logs: router /a/server.log
serve.sh: logs: embed /a/embed.log" ] || bad "manifest print: $out"
[ "$fail" = 0 ] && echo "PASS test_install_polish" || { echo "FAILED $fail"; exit 1; }
