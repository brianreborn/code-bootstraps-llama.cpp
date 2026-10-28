# shellcheck shell=sh
# One privilege prompt from start.sh. Not a second launcher.
# RAISE=0 skips. RAISE=1 asks again. A stamp is written only after success,
# because the new memlock limit does not apply to this login.
# Linux only. Termux and any other OS skip it. Never asks unless RAISE=1.

maybe_raise() {
  [ "${RAISE:-}" = 0 ] && return 0
  [ "${TERMUX:-0}" = 1 ] && return 0
  [ "$(uname -s)" = Linux ] || return 0
  mr_stamp=$ROOT/.cache/raise.stamp
  if [ "${RAISE:-}" != 1 ] && [ -f "$mr_stamp" ]; then
    return 0
  fi
  mr_lim=$(ulimit -l 2>/dev/null || printf '%s' limited)
  if [ "$mr_lim" = unlimited ] && [ "${RAISE:-}" != 1 ]; then
    mkdir -p "$ROOT/.cache" 2>/dev/null || true
    printf '%s\n' ok > "$mr_stamp" 2>/dev/null || true
    return 0
  fi
  # Root only on explicit opt-in (RAISE=1). sudo may run silently from its
  # credential cache, so a terminal is never treated as consent.
  if [ "${RAISE:-}" != 1 ]; then
    say "memlock is limited ($mr_lim); to raise it (needs root) re-run with RAISE=1"
    return 0
  fi
  say "WARNING: the next step runs sudo (root) to write /etc/security/limits.d"
  say "$(t "Asking once for permission to allow memory locking. Sign in again afterwards.")"
  if sh "$ROOT/scripts/raise.sh"; then
    mkdir -p "$ROOT/.cache" 2>/dev/null || true
    printf '%s\n' ok > "$mr_stamp" 2>/dev/null || true
  else
    say "$(t "Memory locking was not granted. The server still starts. Set RAISE=0 to stop asking.")"
  fi
  return 0
}
