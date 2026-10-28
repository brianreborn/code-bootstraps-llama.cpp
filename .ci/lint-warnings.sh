#!/bin/sh
# .ci/lint-warnings.sh: fail on NEW warnings (anything not in .ci/warnings-baseline.txt).
#   ShellCheck at -x -S warning on every tracked *.sh and *.mk file (.mk checked as POSIX sh)
#   Python: compile every tracked *.py with warnings as errors; where pytest.ini exists, also
#   pytest collection with DeprecationWarning / PendingDeprecationWarning / SyntaxWarning as errors.
# Usage: sh .ci/lint-warnings.sh            check (CI)
#        sh .ci/lint-warnings.sh --current  print today's shellcheck counts in baseline format
# Env: SHELLCHECK (default: shellcheck), PYTHON (default: python3).
# Identical copy in brianreborn/familia and brianreborn/code-bootstraps-llama.cpp.
set -eu
cd "$(dirname -- "$0")/.."
SC=${SHELLCHECK:-shellcheck}; PY=${PYTHON:-python3}
BASE=.ci/warnings-baseline.txt
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

"$SC" --version | sed -n 2p >&2
# count per "file code"; xargs exits 123 when shellcheck finds anything, so that status is not used
# here: the comparison against the baseline below is what fails the job.
{ git ls-files -z '*.sh' | xargs -0 -r "$SC" -x -S warning -f gcc || [ $? -eq 123 ]
  git ls-files -z '*.mk' | xargs -0 -r "$SC" -x -S warning -s sh -f gcc || [ $? -eq 123 ]
} > "$tmp/raw"
sed -n 's/^\([^:]*\):[0-9]*:[0-9]*: [a-z]*: .*\[\(SC[0-9]*\)\]$/\1 \2/p' "$tmp/raw" | sort | uniq -c \
  | awk '{print $1, $2, $3}' > "$tmp/now"
if [ "${1:-}" = --current ]; then cat "$tmp/now"; exit 0; fi

sed 's/#.*//' "$BASE" | awk 'NF==3 {print $1, $2, $3}' > "$tmp/base"
fail=0
while read -r n f c; do
  b=$(awk -v f="$f" -v c="$c" '$2==f && $3==c {print $1}' "$tmp/base")
  if [ "$n" -gt "${b:-0}" ]; then
    fail=1; echo "NEW: $f $c: $n now, ${b:-0} in baseline"
    grep "^$f:.*\[$c\]" "$tmp/raw" | sed 's/^/  /'
  fi
done < "$tmp/now"
while read -r n f c; do
  grep -q " $f $c\$" "$tmp/now" 2>/dev/null && continue
  echo "fixed (drop from baseline): $f $c"
done < "$tmp/base"
echo "shellcheck: $(wc -l < "$tmp/now") file/code pairs with warnings, $(wc -l < "$tmp/base") baselined"

# Python: no warning is baselined; any one fails the job.
git ls-files -z '*.py' | xargs -0 -r "$PY" -W error -c '
import sys
bad = 0
for f in sys.argv[1:]:
    with open(f, "rb") as fh: src = fh.read()
    try: compile(src, f, "exec")
    except (SyntaxError, Warning) as e: bad += 1; print("python:", f, type(e).__name__, e)
print("python: compiled", len(sys.argv) - 1, "files,", bad, "with warnings")
sys.exit(1 if bad else 0)' || fail=1
# pytest collection only where the repo is set up for pytest (pytest.ini); cbl's tests/*.py
# are standalone scripts that exit at import, so collecting them is not meaningful.
if [ -f pytest.ini ]; then
  "$PY" -m pytest -q -p no:cacheprovider --collect-only -W error::DeprecationWarning \
    -W error::PendingDeprecationWarning -W error::SyntaxWarning tests > "$tmp/collect" 2>&1 \
    || { cat "$tmp/collect"; fail=1; }
  tail -n 1 "$tmp/collect"
  if grep -q "warnings summary" "$tmp/collect"; then cat "$tmp/collect"; fail=1; fi
fi
[ "$fail" = 0 ] && echo "lint-warnings: OK (no new warnings)"
exit "$fail"
