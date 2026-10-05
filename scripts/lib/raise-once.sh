# shellcheck shell=sh
# One privilege prompt from start.sh. Not a second launcher.
# RAISE=0 skips. RAISE=1 asks again. A stamp is written only after success,
# because the new memlock limit does not apply to this login.
# Linux only. Termux and any other OS skip it. No terminal and RAISE is not 1:
# do not ask (tests, cron, a piped install whose stderr is not a terminal).

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
  mr_tty=0
  if [ -t 0 ] || [ -t 2 ]; then mr_tty=1; fi
  if [ "$mr_tty" != 1 ] && [ "${RAISE:-}" != 1 ]; then
    return 0
  fi
  say "$(t "Asking once for permission to allow memory locking. Sign in again afterwards.")"
  if sh "$ROOT/scripts/raise.sh"; then
    mkdir -p "$ROOT/.cache" 2>/dev/null || true
    printf '%s\n' ok > "$mr_stamp" 2>/dev/null || true
  else
    say "$(t "Memory locking was not granted. The server still starts. Set RAISE=0 to stop asking.")"
  fi
  return 0
}
