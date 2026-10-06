#!/bin/sh
# Console settings: Enter omits a key, a non-default is written, unknown is refused.
# The file is POSIX and does not override a variable that is already set.
#   sh tests/test_configure.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cfg=$ROOT/scripts/configure.sh
envf=$ROOT/.cache/panel.env
tmp=$(mktemp -d)
out=$tmp/out
err=$tmp/err
bak=$tmp/bak
had=0
if [ -f "$envf" ]; then had=1; cp "$envf" "$bak"; fi
cleanup() {
  if [ "$had" = 1 ]; then cp "$bak" "$envf"; else rm -f "$envf"; fi
  rm -rf "$tmp"
}
trap cleanup EXIT
fails=0
note() {
  if [ "$1" = ok ]; then echo "ok   $2"
  else echo "FAIL $2"; fails=$((fails + 1)); fi
}
run() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 sh "$cfg" >"$out" 2>"$err"
  else
    sh "$cfg" >"$out" 2>"$err"
  fi
}

mkdir -p "$ROOT/.cache"
rm -f "$envf"

# Enter on the first setting, then EOF: that key is omitted and nothing else is written.
if printf '\n' | run; then
  if [ -s "$envf" ]; then note bad "Enter wrote a key"; cat "$envf" >&2
  else note ok "Enter omits the key"; fi
else
  note bad "Enter failed"; cat "$err" >&2
fi

# Typing the launcher default is the same as Enter.
rm -f "$envf"
if printf 'auto\n' | run; then
  if [ -s "$envf" ]; then note bad "default PROFILE was written"; cat "$envf" >&2
  else note ok "typing the default omits the key"; fi
else
  note bad "default answer failed"; cat "$err" >&2
fi

# Unknown, then EOF: refused, and the file is not replaced.
stamp=$tmp/stamp
if [ -f "$envf" ]; then cp "$envf" "$stamp"; else : > "$stamp"; fi
if printf 'nope\n' | run; then
  note bad "unknown value was accepted"
else
  if grep -q 'refused' "$err"; then note ok "unknown value is refused"
  else note bad "unknown value failed without saying refused"; cat "$err" >&2; fi
fi
if cmp -s "$stamp" "$envf" || { [ ! -s "$stamp" ] && [ ! -s "$envf" ]; }; then
  note ok "refused run left the file unchanged"
else
  note bad "refused run changed the file"; cat "$envf" >&2
fi

# A corrected answer after a refusal is kept. Other keys stay omitted.
rm -f "$envf"
if printf 'nope\nlowram\n' | run; then
  if grep -q ': "${PROFILE:=lowram}"' "$envf" && ! grep -q nope "$envf"; then
    note ok "a corrected value is written"
  else
    note bad "corrected value missing"; cat "$envf" >&2
  fi
else
  note bad "re-prompt failed"; cat "$err" >&2
fi

input=$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1])
import panel
rows = []
for key in panel.FIELDS:
    if key == "PROFILE":
        rows.append("lowram")
    elif key == "PORT":
        rows.append("9944")
    elif key == "LANGUAGE_MODE":
        rows.append("auto")
    elif key == "REASONING":
        rows.append("on")
    elif key == "LOAD_MODE":
        rows.append("mlock")
    elif key == "THREADS":
        rows.append("auto")
    else:
        rows.append("")
sys.stdout.write("\n".join(rows) + "\n")
' "$ROOT/scripts")
if printf '%s' "$input" | run; then
  cat > "$tmp/want" <<'EOF'
: "${PROFILE:=lowram}"
: "${PORT:=9944}"
: "${REASONING:=on}"
: "${LOAD_MODE:=mlock}"
: "${LANGUAGE_MODE:=auto}"
EOF
  if cmp -s "$tmp/want" "$envf"; then note ok "non-default values are written"
  else note bad "non-default file mismatch"; echo "got:" >&2; cat "$envf" >&2; fi
else
  note bad "non-default run failed"; cat "$err" >&2
fi

if sh -c 'PORT=1111; . "$1"; test "$PORT" = 1111' sh "$envf"; then
  note ok "an already-set variable wins"
else
  note bad "panel.env overrode PORT"
fi
if sh -c 'unset PORT; . "$1"; test "$PORT" = 9944' sh "$envf"; then
  note ok "an unset variable takes the file value"
else
  note bad "panel.env did not set PORT"
fi
if sh -c 'PROFILE=default; . "$1"; test "$PROFILE" = default' sh "$envf"; then
  note ok "an already-set PROFILE wins"
else
  note bad "panel.env overrode PROFILE"
fi

# Enter again drops keys that were saved. The file is a delta, not a merge.
if printf '\n' | run; then
  if [ -s "$envf" ]; then note bad "Enter did not clear saved keys"; cat "$envf" >&2
  else note ok "Enter clears a saved key"; fi
else
  note bad "clearing Enter failed"; cat "$err" >&2
fi

[ "$fails" = 0 ] || exit 1
echo "test_configure.sh: ok"
