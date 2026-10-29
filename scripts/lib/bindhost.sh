# shellcheck shell=sh
# How HOST is passed to llama-server --host.
# 127.0.0.1, localhost, ::1, 0.0.0.0, and :: are left as given.
# Any other address is also bound on 127.0.0.1 so the local UI and agent keep working.
# A list that already contains a wildcard is left as given (binding both is undefined).

# Loopback rules, identical in bindhost.sh, bindhost.ps1 and scripts/lib/loopback.py:
# HOST may be a comma-separated list; spaces around entries are trimmed. One entry is loopback
# when it is localhost, ::1, [::1], or a dotted-quad 127.x.y.z (127.0.0.0/8). A value is
# loopback only when EVERY entry is; 0.0.0.0, ::, LAN addresses and empty entries are not.
is_loopback_host() {
  lh=$1
  while :; do case "$lh" in " "*|"	"*) lh=${lh#?} ;; *) break ;; esac; done
  while :; do case "$lh" in *" "|*"	") lh=${lh%?} ;; *) break ;; esac; done
  lh=$(printf '%s' "$lh" | tr 'A-Z' 'a-z')
  case "$lh" in
    localhost|::1|"[::1]") return 0 ;;
    127.*.*.*) ;;
    *) return 1 ;;
  esac
  (
    IFS=.
    set -f
    # shellcheck disable=SC2086
    set -- $lh
    [ $# -eq 4 ] || exit 1
    for o in "$@"; do
      case "$o" in ""|*[!0-9]*|????*) exit 1 ;; esac
      [ "$o" -le 255 ] || exit 1
    done
  )
}

is_loopback_list() {
  case "$1" in "") return 1 ;; esac
  (
    IFS=,
    set -f
    # a trailing comma is an empty entry too
    case "$1" in *,) exit 1 ;; esac
    for h in $1; do is_loopback_host "$h" || exit 1; done
  )
}

# true when at least one entry is loopback (or a wildcard, for bind_hosts)
has_loopback_entry() {
  (
    IFS=,
    set -f
    for h in $1; do is_loopback_host "$h" && exit 0; done
    exit 1
  )
}

bind_hosts() {
  bh=${1:-127.0.0.1}
  [ -n "$bh" ] || bh=127.0.0.1
  case ",$bh," in
    *,0.0.0.0,*|*,::,*) printf '%s\n' "$bh"; return 0 ;;
  esac
  if has_loopback_entry "$bh"; then printf '%s\n' "$bh"; return 0; fi
  printf '%s\n' "127.0.0.1,$bh"
}

# Host the local probe, recover helper, and "listening on" line use.
probe_host_of() {
  ph=$(bind_hosts "$1")
  case ",$ph," in
    *,127.0.0.1,*|*,localhost,*|*,0.0.0.0,*|*,::,*) printf '%s\n' 127.0.0.1; return 0 ;;
  esac
  case "$ph" in
    ::1|*,::1|::1,*) printf '%s\n' ::1; return 0 ;;
  esac
  printf '%s\n' "${ph%%,*}"
}

# Addresses other machines can open. Wildcards and loopback are omitted.
public_hosts() {
  ph=$(bind_hosts "$1")
  (
    IFS=,
    set -f
    for h in $ph; do
      is_loopback_host "$h" && continue
      while :; do case "$h" in " "*) h=${h#?} ;; *" ") h=${h%?} ;; *) break ;; esac; done
      case "$h" in
        ""|0.0.0.0|::) ;;
        *) printf '%s\n' "$h" ;;
      esac
    done
  )
}

# Bracket an IPv6 address for an http:// URL.
url_host() {
  case "$1" in
    *:*) printf '[%s]' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}
