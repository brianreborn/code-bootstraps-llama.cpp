#!/bin/sh
# The launcher asks for memlock once, as part of start.sh, and does not ask again
# after that succeeds.   sh tests/test_raise_gate.sh
set -eu
ROOT_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fails=0
say() { printf '%s\n' "$*"; }
t() { printf '%s\n' "$1"; }
. "$ROOT_REPO/scripts/lib/raise-once.sh"

note() {
  if [ "$1" = ok ]; then echo "ok   $2"
  else echo "FAIL $2"; fails=$((fails + 1)); fi
}

setup() {
  ROOT=$tmp/tree
  rm -rf "$ROOT"
  mkdir -p "$ROOT/scripts" "$ROOT/.cache"
  CALLLOG=$tmp/called
  : > "$CALLLOG"
  RC=0
  export CALLLOG RC
  cat > "$ROOT/scripts/raise.sh" <<'EOF'
#!/bin/sh
printf '%s\n' called >> "$CALLLOG"
exit "$RC"
EOF
  TERMUX=0
  unset RAISE || true
}

calls() { wc -l < "$CALLLOG" | tr -d ' '; }

ask='Asking once for permission to allow memory locking. Sign in again afterwards.'
deny='Memory locking was not granted. The server still starts. Set RAISE=0 to stop asking.'
for f in "$ROOT_REPO/scripts/lib/raise-once.sh" "$ROOT_REPO/scripts/start.ps1" "$ROOT_REPO/config/messages/ja"; do
  hit=0
  grep -F "$ask" "$f" >/dev/null && grep -F "$deny" "$f" >/dev/null && hit=1
  note "$( [ "$hit" = 1 ] && echo ok || echo no )" "sentences in ${f#$ROOT_REPO/}"
done
tabs=$(awk -F '\t' -v a="$ask" -v d="$deny" '($1==a || $1==d) && NF>=2 { n++ } END { print n+0 }' "$ROOT_REPO/config/messages/ja")
note "$( [ "$tabs" = 2 ] && echo ok || echo no )" "ja catalog has both sentences as one tab each ($tabs)"

# A non-interactive start does not ask, and does not record a stamp.
setup
RC=0
maybe_raise </dev/null >/dev/null 2>&1
note "$( [ "$(calls)" = 0 ] && [ ! -f "$ROOT/.cache/raise.stamp" ] && echo ok || echo no )" "no tty: no prompt, no stamp"

# RAISE=0 never asks, even when forced would.
setup
RAISE=0 RC=0
maybe_raise </dev/null >/dev/null 2>&1
note "$( [ "$(calls)" = 0 ] && echo ok || echo no )" "RAISE=0 skips"

# Termux cannot write the Linux limit file.
setup
TERMUX=1 RAISE=1 RC=0
maybe_raise </dev/null >/dev/null 2>&1
note "$( [ "$(calls)" = 0 ] && echo ok || echo no )" "Termux skips even with RAISE=1"

# Another OS skips.
setup
saved=$PATH
mkdir -p "$tmp/bin"
printf '%s\n' '#!/bin/sh' 'echo Darwin' > "$tmp/bin/uname"
chmod +x "$tmp/bin/uname"
PATH=$tmp/bin:$PATH
RAISE=1 RC=0
maybe_raise </dev/null >/dev/null 2>&1
PATH=$saved
note "$( [ "$(calls)" = 0 ] && echo ok || echo no )" "macOS skips"

# Success writes the stamp and a later start does not ask again.
setup
RAISE=1 RC=0
maybe_raise </dev/null >/dev/null 2>&1
stamped=$(tr -d '[:space:]' < "$ROOT/.cache/raise.stamp" 2>/dev/null || true)
unset RAISE || true
maybe_raise </dev/null >/dev/null 2>&1
note "$( [ "$(calls)" = 1 ] && [ "$stamped" = ok ] && echo ok || echo no )" "success stamps ok and the next start is quiet"

# A declined or failed prompt does not stamp, so the next forced run tries again,
# and set -e does not abort the launcher.
setup
RAISE=1 RC=1
maybe_raise </dev/null >/dev/null 2>&1 || note no "failure aborted the shell"
note "$( [ ! -f "$ROOT/.cache/raise.stamp" ] && [ "$(calls)" = 1 ] && echo ok || echo no )" "failure does not stamp"
RAISE=1 RC=0
maybe_raise </dev/null >/dev/null 2>&1
note "$( [ "$(calls)" = 2 ] && [ -f "$ROOT/.cache/raise.stamp" ] && echo ok || echo no )" "RAISE=1 tries again after a failure"

# install.sh asks only when it will not start. The start path only exports RAISE.
awk '
  /INSTALL_NO_START/ { gate=1 }
  gate && /exit 0/ { gate=0; after=1; next }
  after && /raise\.sh/ { bad=1 }
  END { exit bad ? 1 : 0 }
' "$ROOT_REPO/install.sh" && note ok "install.sh does not call raise.sh on the start path" || note no "install.sh calls raise.sh after the no-start exit"

grep -n exec "$ROOT_REPO/start.sh" | grep -q raise && note no "start.sh execs raise" || note ok "start.sh does not exec raise"

# A terminal (stderr is a tty, stdin is not, as in curl|sh) does ask.
setup
python3 - "$ROOT_REPO/scripts/lib/raise-once.sh" "$ROOT" "$CALLLOG" <<'PY'
import os, pty, subprocess, sys
lib, root, calllog = sys.argv[1:]
master, slave = pty.openpty()
script = r'''
set -eu
. "$1"
ROOT=$2
CALLLOG=$3
RC=0
export CALLLOG RC
TERMUX=0
unset RAISE || true
say() { printf '%s\n' "$*" >&2; }
t() { printf '%s\n' "$1"; }
maybe_raise </dev/null
'''
r = subprocess.run(["dash", "-c", script, "dash", lib, root, calllog],
                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=slave)
os.close(slave)
os.close(master)
sys.exit(r.returncode)
PY
note "$( [ "$(calls)" = 1 ] && [ -f "$ROOT/.cache/raise.stamp" ] && echo ok || echo no )" "a terminal asks once and stamps"

[ "$fails" = 0 ] && echo "test_raise_gate: ok" || { echo "test_raise_gate: $fails failed" >&2; exit 1; }
