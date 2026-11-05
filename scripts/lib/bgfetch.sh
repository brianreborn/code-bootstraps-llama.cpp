# shellcheck shell=sh
# Background model download (start.sh MODELS_BG=1) lifetime, issue #35.
# A non-interactive sh starts background jobs with SIGINT ignored, so Ctrl-C at the
# terminal never reached fetch-models.sh or its curl. These helpers stop the whole
# download tree (subshell, fetch-models.sh, curl) explicitly. curl downloads into
# <file>.part with -C -, so an interrupted download resumes on the next start.

# bgfetch_tree PID: PID and all its descendants (collected before any kill, so
# children are not lost when they are reparented).
bgfetch_tree() {
  bt_all=$(ps -eo pid=,ppid= 2>/dev/null || ps -o pid=,ppid= 2>/dev/null || true)
  printf '%s\n' "$bt_all" | awk -v root="$1" '
    { kids[$2] = kids[$2] " " $1 }
    END {
      n = 1; q[1] = root; print root
      for (i = 1; i <= n; i++) {
        m = split(kids[q[i]], c, " ")
        for (j = 1; j <= m; j++) { if (c[j] == "") continue; q[++n] = c[j]; print c[j] }
      }
    }'
}

# bgfetch_stop [PID]: stop the background download (default: FAMILIA_BG_FETCH_PID,
# else .cache/fetch-models.pid). TERM first, KILL whatever is left after ~2 s.
bgfetch_stop() {
  bs_pid=${1:-${FAMILIA_BG_FETCH_PID:-}}
  bs_pidfile=${ROOT:-.}/.cache/fetch-models.pid
  if [ -z "$bs_pid" ] && [ -f "$bs_pidfile" ]; then bs_pid=$(cat "$bs_pidfile" 2>/dev/null || true); fi
  case "$bs_pid" in ""|*[!0-9]*) return 0 ;; esac
  kill -0 "$bs_pid" 2>/dev/null || { rm -f "$bs_pidfile"; return 0; }
  bs_list=$(bgfetch_tree "$bs_pid")
  # shellcheck disable=SC2086 # word splitting of the pid list is intended
  kill -TERM $bs_list 2>/dev/null || true
  bs_i=0
  while [ "$bs_i" -lt 10 ]; do
    bs_left=""
    for bs_p in $bs_list; do kill -0 "$bs_p" 2>/dev/null && bs_left="$bs_left $bs_p"; done
    [ -n "$bs_left" ] || break
    sleep 0.2; bs_i=$((bs_i + 1))
  done
  # shellcheck disable=SC2086
  [ -z "${bs_left:-}" ] || kill -KILL $bs_left 2>/dev/null || true
  rm -f "$bs_pidfile"
  if [ -n "${ROOT:-}" ] && [ -f "$ROOT/.cache/fetch-models.log" ]; then
    echo "fetch-models: stopped (interrupted; partial downloads resume on the next start)" >> "$ROOT/.cache/fetch-models.log"
  fi
}
