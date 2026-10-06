#!/bin/sh
# Ask for launcher settings. Enter, or the default itself, omits that key.
# panel.py writes .cache/panel.env so the quoting stays : "${KEY:=value}".
# Answers come from stdin. Do not open a terminal; a pipe must be enough.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
command -v python3 >/dev/null 2>&1 || { echo "configure.sh: python3 was not found" >&2; exit 1; }
panel=$ROOT/scripts/panel.py
spec=$(python3 "$panel" --fields)
answers=$(mktemp)
trap 'rm -f "$answers"' EXIT
: > "$answers"

while IFS="$(printf '\t')" read -r key shown hint <&3; do
  [ -n "$key" ] || continue
  refused=0
  while true; do
    printf '%s [%s] (%s): ' "$key" "$shown" "$hint" >&2
    ans=
    eof=0
    if ! IFS= read -r ans; then eof=1; fi
    if [ "$eof" = 1 ] && [ -z "$ans" ]; then
      if [ "$refused" = 1 ]; then
        echo "configure.sh: refused $key" >&2
        exit 1
      fi
      break 2
    fi
    ans=$(printf '%s' "$ans" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$ans" ]; then
      if [ "$eof" = 1 ]; then break 2; fi
      break
    fi
    if python3 "$panel" --check "$key" "$ans"; then
      printf '%s\t%s\n' "$key" "$ans" >> "$answers"
      if [ "$eof" = 1 ]; then break 2; fi
      break
    fi
    echo "configure.sh: refused $key=$ans" >&2
    if [ "$eof" = 1 ]; then exit 1; fi
    refused=1
  done
done 3<<EOF
$spec
EOF

python3 "$panel" --write "$answers"
