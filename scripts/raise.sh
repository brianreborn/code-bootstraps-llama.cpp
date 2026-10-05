#!/bin/sh
# Grant this account the right to mlock, once, and again later if it is lost.
# Re-run: scripts/raise.sh
# Optional setuid helper, off unless asked: scripts/raise.sh --chroot
# The helper is root only long enough to chroot, then it becomes this user.
# A login is required before memlock applies. This script does not stay root.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
want_chroot=0
for a in "$@"; do
  case "$a" in
    --chroot) want_chroot=1 ;;
    *) echo "raise.sh: unknown argument $a" >&2; exit 2 ;;
  esac
done
if [ "$(id -u)" != 0 ]; then
  echo "raise.sh: asking sudo once to write the memlock limit" >&2
  exec sudo sh "$ROOT/scripts/raise.sh" "$@"
fi
account=${RAISE_USER:-${SUDO_USER:-}}
if [ -z "$account" ] || [ "$account" = root ]; then
  echo "raise.sh: set RAISE_USER to the account that runs the server" >&2
  exit 1
fi
dest=/etc/security/limits.d/code-bootstraps-llama.conf
umask 022
mkdir -p /etc/security/limits.d
cat > "$dest" <<EOF
# Written by scripts/raise.sh. Sign in again before this applies.
$account - memlock unlimited
EOF
chmod 644 "$dest"
echo "raise.sh: wrote $dest for $account. Sign in again, then mlock can succeed." >&2
if [ "$want_chroot" != 1 ]; then
  echo "raise.sh: no setuid helper was installed. Pass --chroot to add the chroot helper." >&2
  exit 0
fi
cc=${CC:-cc}
command -v "$cc" >/dev/null 2>&1 || { echo "raise.sh: $cc is required to build the chroot helper" >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
"$cc" -O2 -o "$stage/chroot-drop" "$ROOT/scripts/chroot-drop.c"
install -d -m 755 /usr/local/libexec/code-bootstraps-llama
install -m 4755 -o root -g root "$stage/chroot-drop" /usr/local/libexec/code-bootstraps-llama/chroot-drop
echo "raise.sh: installed setuid /usr/local/libexec/code-bootstraps-llama/chroot-drop" >&2
echo "raise.sh: it drops to the invoking user before exec. Do not point sudoers at a copy under the repo." >&2
