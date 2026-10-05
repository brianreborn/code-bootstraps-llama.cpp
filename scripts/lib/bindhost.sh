# shellcheck shell=sh
# How HOST is passed to llama-server --host.
# 127.0.0.1, localhost, ::1, 0.0.0.0, and :: are left as given.
# Any other address is also bound on 127.0.0.1 so the local UI and agent keep working.
# A list that already contains a wildcard is left as given (binding both is undefined).

bind_hosts() {
  bh=${1:-127.0.0.1}
  [ -n "$bh" ] || bh=127.0.0.1
  case ",$bh," in
    *,127.0.0.1,*|*,localhost,*|*,::1,*|*,0.0.0.0,*|*,::,*) printf '%s\n' "$bh"; return 0 ;;
  esac
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
      case "$h" in
        ""|127.0.0.1|localhost|::1|0.0.0.0|::) ;;
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
