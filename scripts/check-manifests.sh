#!/usr/bin/env bash
# Developer check: the Python-free manifest reader (scripts/lib/manifest.awk) must see
# exactly what a real JSON parser sees. Needs python3 (developers only, not users).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
AWK="${AWK:-awk}"; rc=0
check() {   # $1 file, $2 array key, $3 fields
  local want got
  want="$(python3 - "$1" "$2" "$3" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
for c in d[sys.argv[2]]:
    if "file" not in c: continue
    vals = []
    for f in sys.argv[3].split():
        v = c.get(f, "-")
        v = {True: "yes", False: "no"}.get(v, v) if isinstance(v, bool) else v
        if not isinstance(v, str): v = json.dumps(v)
        if '"' in v or "\t" in v: sys.exit(f"{sys.argv[1]}: {f} of {c['file']} contains a quote or tab")
        vals.append(v if v != "" else "-")
    print("\t".join(vals))
PY
)"
  got="$($AWK -v match_kv="" -v fields="$3" -f scripts/lib/manifest.awk "$1")"
  if [[ "$want" == "$got" ]]; then echo "check-manifests: OK $1 ($(wc -l <<< "$got") entries, $AWK)"
  else echo "check-manifests: MISMATCH in $1"; diff <(echo "$want") <(echo "$got") || true; rc=1; fi
}
check config/models-manifest.json candidates "pick role repo revision file sha256 tested dir notice bytes"
[[ -f config/llama-release.json ]] && check config/llama-release.json assets "platform variant file sha256 bytes"
exit $rc
