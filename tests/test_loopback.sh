#!/bin/sh
# Loopback list rules of scripts/lib/bindhost.sh against the shared table tests/loopback-cases.txt
# (the same table tests/test_loopback.py and tests/test-ps1-helpers.ps1 check).
#   sh tests/test_loopback.sh
set -eu
ROOT_REPO=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT_REPO/scripts/lib/bindhost.sh"
fails=0 n=0
while IFS= read -r line; do
  case "$line" in "#"*) continue ;; esac
  v=${line%|*} want=${line##*|}
  if is_loopback_list "$v"; then got=1; else got=0; fi
  n=$((n + 1))
  if [ "$got" = "$want" ]; then echo "ok   is_loopback_list '$v' = $want"
  else echo "FAIL is_loopback_list '$v' got $got want $want"; fails=$((fails + 1)); fi
done < "$ROOT_REPO/tests/loopback-cases.txt"
[ "$n" -gt 20 ] || { echo "FAIL loopback-cases.txt has only $n cases"; fails=$((fails + 1)); }
# serve.sh warns exactly when the value is not loopback (default HOST=127.0.0.1,::1 must not warn)
for v in "127.0.0.1,::1" "localhost"; do is_loopback_list "$v" && echo "ok   no warning for $v" || { echo "FAIL warning for $v"; fails=$((fails + 1)); }; done
[ "$fails" -eq 0 ] || { echo "loopback: $fails failure(s)"; exit 1; }
echo "loopback: all checks passed"
