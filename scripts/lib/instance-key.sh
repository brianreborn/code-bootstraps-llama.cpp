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
    # ln fails when another starter won the race: both then read the winner's key
    if ln "$_tmp" "$_kf" 2>/dev/null; then
      echo "instance-key: created $_kf" >&2
    fi
    rm -f "$_tmp"
  fi
  chmod 600 "$_kf"
}

instance_key_first() { # <file>
  grep -v -e '^#' -e '^[[:space:]]*$' "$1" 2>/dev/null | tr -d ' \r' | head -n 1
}

# issue #38: never log a full key. key_mask <key> -> ****<last4>
key_mask() { _k=$1; [ ${#_k} -gt 4 ] && printf '****%s\n' "${_k#"${_k%????}"}" || printf '****\n'; }
# key_redact_sed <comma-list>: prints a sed script that masks every listed key.
# Keys are matched literally: only BRE specials ([ ] \ . * ^ $) and the / delimiter are
# escaped (escaping other punctuation would turn \+ \( \| \? into GNU operators), & / \ are
# escaped in the replacement, and longer keys go first so a key that contains another is
# fully hidden. If the script still fails to compile, fall back to hiding whole lines so
# the live log keeps running and never shows a key.
key_redact_sed() {
  _out=$(printf '%s\n' "$1" | tr ',' '\n' | awk 'length { print length "\t" $0 }' | sort -rn | cut -f2- |
    while IFS= read -r _k; do
      _p=$(printf '%s\n' "$_k" | sed 's/[][\\.*^$/]/\\&/g')
      _r=$(key_mask "$_k" | sed 's/[\\/&]/\\&/g')
      printf 's/%s/%s/g;' "$_p" "$_r"
    done)
  _out=${_out%;}
  # Compile-check with sed -f on a 0600 temp file so the keys never appear in argv.
  # If mktemp is unavailable, hide the whole line rather than fall back to sed -e.
  if [ -n "$_out" ]; then
    _tf=$(umask 077; mktemp 2>/dev/null) || _tf=
    if [ -n "$_tf" ]; then
      chmod 600 "$_tf"
      printf '%s\n' "$_out" > "$_tf"
      if ! printf 'x\n' | sed -f "$_tf" >/dev/null 2>&1; then
        _out='s/.*/[line hidden: key redaction failed]/'
      fi
      rm -f "$_tf"
    else
      _out='s/.*/[line hidden: key redaction failed]/'
    fi
  fi
  printf '%s\n' "$_out"
}
