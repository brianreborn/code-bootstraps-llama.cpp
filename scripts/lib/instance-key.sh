# shellcheck shell=sh
# One stable API key per llama-server instance (port). Sourced by serve.sh and start.sh.
# See docs/api-key-design.md. Invariants: the key lives at
#   ${XDG_CONFIG_HOME:-~/.config}/familia/instances/<port>/api-keys   (dir 700, file 600)
# it is created atomically only when missing, and it is never rotated on startup.

instance_key_dir() { # <port>
  printf '%s/familia/instances/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$1"
}

instance_key_file() { # <port>; API_KEY_FILE overrides
  if [ -n "${API_KEY_FILE:-}" ]; then printf '%s\n' "$API_KEY_FILE"; else printf '%s/api-keys\n' "$(instance_key_dir "$1")"; fi
}

# instance_key_ensure <file> [legacy-file]: create <file> if missing (adopting the legacy
# checkout key so existing browsers keep working), never overwrite. Prints nothing.
instance_key_ensure() {
  _kf=$1; _legacy=${2:-}
  _kd=$(dirname "$_kf")
  ( umask 077; mkdir -p "$_kd" ) && chmod 700 "$_kd"
  if [ ! -s "$_kf" ]; then
    _tmp="$_kd/.api-keys.$$.tmp"
    ( umask 077
      if [ -n "$_legacy" ] && [ -s "$_legacy" ] && grep -q -v -e '^#' -e '^[[:space:]]*$' "$_legacy"; then
        cat "$_legacy"
      else
        echo "# llama-server API key(s), one per line"; od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; echo
      fi > "$_tmp" )
    # ln fails when another starter won the race: both then read the winner's key.
    # Android (Termux) forbids hard links (SELinux denies link(2)), so ln always fails there:
    # then publish with a no-clobber (O_EXCL) create, which still never overwrites a key.
    if ln "$_tmp" "$_kf" 2>/dev/null ||
       { [ ! -e "$_kf" ] && ( umask 077; set -C; cat "$_tmp" > "$_kf" ) 2>/dev/null; }; then
      echo "instance-key: created $_kf" >&2
    fi
    rm -f "$_tmp"
  fi
  chmod 600 "$_kf"
}

instance_key_first() { # <file>
  grep -v -e '^#' -e '^[[:space:]]*$' "$1" 2>/dev/null | tr -d ' \r' | head -n 1
}
