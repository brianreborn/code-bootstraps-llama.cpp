#!/bin/sh
# sudo must never run without an explicit opt-in (RAISE=1 / AUTO_DEPS=1).
# A PATH shim makes any sudo call fail loudly and records it.
set -eu
ROOT_REPO=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/tree/scripts" "$tmp/tree/.cache"
cat > "$tmp/bin/sudo" <<SH
#!/bin/sh
echo "sudo \$*" >> "$tmp/sudo.log"; exit 99
SH
chmod +x "$tmp/bin/sudo"
cp "$ROOT_REPO/scripts/raise.sh" "$tmp/tree/scripts/raise.sh"
PATH="$tmp/bin:$PATH"; export PATH
say() { :; }; t() { printf '%s\n' "$1"; }
. "$ROOT_REPO/scripts/lib/raise-once.sh"
ROOT=$tmp/tree; TERMUX=0; unset RAISE AUTO_DEPS || true
# stdin and stderr pretend to be absent and present; neither is consent
maybe_raise </dev/null 2>/dev/null
maybe_raise 2>/dev/null </dev/null
if [ -s "$tmp/sudo.log" ]; then echo "FAIL sudo was invoked without RAISE=1:"; cat "$tmp/sudo.log"; exit 1; fi
echo "ok   no sudo without RAISE=1"
