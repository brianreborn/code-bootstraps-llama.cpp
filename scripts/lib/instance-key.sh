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
  if ! { ( umask 077; mkdir -p "$_kd" ) && chmod 700 "$_kd"; } 2>/dev/null; then
    echo "instance-key: ERROR: cannot create key dir $_kd" >&2; return 1
  fi
  if [ ! -s "$_kf" ]; then
    _tmp="$_kd/.api-keys.$$.tmp"
    ( umask 077
      if [ -n "$_legacy" ] && [ -s "$_legacy" ] && grep -q -v -e '^#' -e '^[[:space:]]*$' "$_legacy"; then
        cat "$_legacy"
      else
        echo "# llama-server API key(s), one per line"; od -An -tx1 -N24 /dev/urandom | tr -d ' \n'; echo
      fi > "$_tmp" )
    # ln fails when another starter won the race: both then read the winner's key.
    # Android forbids hard links under /data, so ln also fails there for everyone:
    # fall back to a mkdir lock (atomic everywhere) + rename, re-checking under the lock.
    if ln "$_tmp" "$_kf" 2>/dev/null; then
      echo "instance-key: created $_kf" >&2
    elif [ ! -s "$_kf" ]; then
      _lock="$_kf.lock"; _n=0; _own=
      while :; do
        if mkdir "$_lock" 2>/dev/null; then _own=1; break; fi
        [ -s "$_kf" ] && break
        _n=$((_n + 1)); [ "$_n" -ge 100 ] && break   # ~10s, then give up waiting
        sleep 0.1 2>/dev/null || sleep 1
      done
      if [ -n "$_own" ]; then
        [ -s "$_kf" ] || { mv -f "$_tmp" "$_kf" && echo "instance-key: created $_kf (no-link fallback)" >&2; }
        rmdir "$_lock" 2>/dev/null
      fi
    fi
    rm -f "$_tmp"
  fi
  if [ ! -s "$_kf" ] || [ -z "$(instance_key_first "$_kf")" ]; then
    echo "instance-key: ERROR: no key could be written to $_kf" >&2
    return 1
  fi
  chmod 600 "$_kf"
}

instance_key_first() { # <file>
  grep -v -e '^#' -e '^[[:space:]]*$' "$1" 2>/dev/null | tr -d ' \r' | head -n 1
}
