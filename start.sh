#!/bin/sh
# Click-and-go launcher (Linux, Android/Termux; macOS: start.command).
# Settings: PORT, VARIANT=auto|cpu|vulkan|cuda-12|cuda-13, NO_BROWSER=1, BUILD=1 (build the pinned source with patches/; default: reuse an existing local build, else the sha256-checked b11969 release binary for this OS/arch, else build from source),
# COPY_KEY=1, WAKE_LOCK=0, RAISE=0|1, REASONING=on|auto (default off), plus everything scripts/serve.sh reads.
# DETACH_MODE=foreground|nohup|tmux|screen|screen-attached (default foreground).
# On Linux this also asks once for memlock (scripts/raise.sh). One command.
# Usage hints:
#   PORT=9932 sh start.sh --args --etc                  # set env, pass args
#   VARIANT=vulkan 2 coder --ctx 65536                  # menu item ref: "2" = second model slot
#   HERMES_PY=/usr/local/bin/python3.12 sh start.sh     # FreeBSD: override Python path
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
if [ -f "$ROOT/.cache/panel.env" ]; then . "$ROOT/.cache/panel.env"; fi
. "$ROOT/scripts/lib/i18n.sh"
. "$ROOT/scripts/lib/raise-once.sh"
. "$ROOT/scripts/lib/bindhost.sh"
LANG_CODE=$(lang_code_of "${LOCALE:-auto}")
export PORT="${PORT:-9931}"
MK_TAG=start; . "$ROOT/lib/msg.mk"   # say
. "$ROOT/lib/os.mk"                    # mk_is_termux
TERMUX=0
if mk_is_termux; then TERMUX=1; fi

missing=""
for tool in curl tar awk; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v cksum >/dev/null 2>&1 || missing="$missing sha256sum"
if [ -n "$missing" ]; then
  say "$(t "Some required programs are missing.")$missing"
  pkgs=$(printf '%s' "$missing" | sed 's/sha256sum/coreutils/; s/ awk/ gawk/')
  if [ "$TERMUX" = 1 ]; then cmd="pkg install -y$pkgs"
  elif command -v pacman >/dev/null 2>&1; then cmd="sudo pacman -Sy --needed --noconfirm$pkgs"
  elif command -v apt-get >/dev/null 2>&1; then cmd="sudo apt-get update && sudo apt-get install -y$pkgs"
  elif command -v dnf >/dev/null 2>&1; then cmd="sudo dnf install -y$pkgs"
  elif command -v pkg >/dev/null 2>&1; then cmd="sudo pkg install -y$pkgs"
  else cmd=""; fi
  [ -z "$cmd" ] || say "install them with: $cmd"
  if [ -n "$cmd" ] && [ "${AUTO_DEPS:-0}" = 1 ] && [ -r /dev/tty ]; then
    printf 'start: run it now? [y/N] ' >&2
    read -r ans < /dev/tty || ans=n
    case "$ans" in y|Y|yes) sh -c "$cmd" || exit 1 ;; *) exit 1 ;; esac
  else
    [ -z "$cmd" ] || say "or re-run with AUTO_DEPS=1 to install them after one confirmation"
    exit 1
  fi
fi

maybe_raise

VARIANT=${VARIANT:-auto}
if [ -n "${LLAMA_SERVER:-}" ]; then
  say "$(t "using the binary you named")"
elif [ "${BUILD:-0}" != 1 ] && existing=$(ls -td "$ROOT"/build-*/bin/llama-server 2>/dev/null | head -n 1) && [ -x "$existing" ]; then
  # prebuilt-first never forces a rebuild: an earlier (patched) source build is reused as-is
  LLAMA_SERVER=$existing
  say "using the existing build $LLAMA_SERVER (BUILD=1 rebuilds)"
elif [ "${BUILD:-0}" != 1 ] && LLAMA_SERVER=$(scripts/fetch-llama.sh --variant "$VARIANT"); then
  say "using the sha256-checked release binary $LLAMA_SERVER (upstream, without patches/: tools/MCP stay off; BUILD=1 builds the patched source)"
else
  rc=$?
  if [ "${BUILD:-0}" != 1 ] && [ "$rc" != 3 ]; then
    say "$(t "downloading llama.cpp failed; check the network and run start.sh again")"
    exit 1
  fi
  [ "${BUILD:-0}" = 1 ] || say "$(t "no release binary for this machine; building from source")"
  case "$(uname -s)" in
    Darwin) script=scripts/build-macos.sh ;;
    FreeBSD) script=scripts/build-linux.sh; BUILD_DIR=${BUILD_DIR:-build-freebsd} ;;
    *)
      if [ "$TERMUX" = 1 ]; then script=scripts/build-termux.sh
      else script=scripts/build-linux.sh; fi
      ;;
  esac
  command -v cmake >/dev/null 2>&1 || { say "$(t "cmake was not found")"; exit 1; }
  if [ ! -f llama.cpp/CMakeLists.txt ] && [ ! -e .git ]; then
    # archive install (install.sh / install-code-bootstraps-llama.cpp.sh): no submodule, so fetch the pinned, sha256-checked source tarball
    if ! SKIP_PACKAGES=1 SKIP_MODELS=1 scripts/predownload.sh; then
      say "$(t "llama.cpp sources are missing from this download")"
      exit 1
    fi
  fi
  if [ ! -f llama.cpp/CMakeLists.txt ]; then
    if ! git submodule update --init --recursive llama.cpp; then
      say "$(t "could not fetch the pinned llama.cpp sources; check git access and run git submodule update --init --recursive")"
      exit 1
    fi
  fi
  # build-linux.sh picks ONE backend itself (scripts/lib/backend.sh; FAMILIA_BACKEND overrides)
  if [ "$(uname -s)" = FreeBSD ]; then
    BUILD_DIR="$BUILD_DIR" FAMILIA_BACKEND=cpu "$script"
  else
    "$script"
  fi
  if [ "$(uname -s)" = FreeBSD ]; then
    case "$BUILD_DIR" in
      /*) built_dir=$BUILD_DIR ;;
      *) built_dir=$ROOT/$BUILD_DIR ;;
    esac
    LLAMA_SERVER=$built_dir/bin/llama-server
  else
    LLAMA_SERVER=$(ls -td "$ROOT"/build-"$(uname -s | tr A-Z a-z)"-*/bin/llama-server 2>/dev/null | head -n 1 || true)
    [ -n "$LLAMA_SERVER" ] || LLAMA_SERVER=$(ls -td "$ROOT"/build-*/bin/llama-server 2>/dev/null | head -n 1 || true)
  fi
  [ -x "${LLAMA_SERVER:-}" ] || { say "$(t "build finished but llama-server was not found")"; exit 1; }
fi
export LLAMA_SERVER
# tests: stop once the llama-server choice is made
if [ "${START_RESOLVE_ONLY:-0}" = 1 ]; then printf '%s\n' "$LLAMA_SERVER"; exit 0; fi

rc=0
# MODELS_BG=1 (default): download the general model first (chat starts with it), then the other
# roles in the background (.cache/fetch-models.log, streamed live by serve.sh and the cockpit);
# serve.sh hot-adds each role when its file lands. MODELS_BG=0 = download everything first.
if [ "${MODELS_BG:-1}" = 1 ]; then
  scripts/fetch-models.sh --role general || rc=$?
  if [ "$rc" = 0 ]; then
    mkdir -p .cache
    if ! scripts/fetch-models.sh --dry-run 2>/dev/null | grep -q "would download"; then
      : # everything is already here
    else
      export MODELS_PENDING_OK=1
      ( scripts/fetch-models.sh > .cache/fetch-models.log 2>&1; echo "fetch-models: done (exit $?)" >> .cache/fetch-models.log ) </dev/null &
      echo $! > .cache/fetch-models.pid
      say "downloading the other models in the background (logs: $ROOT/.cache/fetch-models.log); chat starts now"
    fi
  fi
else
  scripts/fetch-models.sh || rc=$?
fi
if [ "$rc" = 6 ] || [ "$rc" = 7 ]; then
  say "$(t "cannot reach the model host; connect and run start.sh again")"
  exit 1
elif [ "$rc" != 0 ]; then
  exit "$rc"
fi

port_busy() {
  pb=0
  curl -s --max-time 1 "telnet://127.0.0.1:$1" </dev/null >/dev/null 2>&1 || pb=$?
  if [ "$pb" = 1 ]; then
    pb=0
    curl -sS -o /dev/null --connect-timeout 1 --max-time 1 "http://127.0.0.1:$1/" >/dev/null 2>&1 || pb=$?
  fi
  [ "$pb" != 7 ]
}
if port_busy "$PORT"; then
  p=$PORT
  i=1
  while [ "$i" -le 20 ]; do
    p=$((PORT + i))
    port_busy "$p" || break
    i=$((i + 1))
  done
  if port_busy "$p"; then say "$(t "that port is in use; choose another with PORT")"; exit 1; fi
  say "$(t "that port is in use, so another free port was chosen")"
  export PORT="$p"
fi

open_ui() {
  parent=$1
  port=""
  pid=""
  ready=0
  # No fixed limit here: serve.sh owns the readiness ceiling (READY_TIMEOUT) and prints the
  # progress; this waits for its ready file as long as the launcher lives (OPEN_UI_TIMEOUT
  # seconds caps it, 0 = no cap), then says so instead of returning silently.
  t0=$(date +%s)
  while :; do
    kill -0 "$parent" 2>/dev/null || return 0
    if [ -s .cache/serve.ready ]; then
      read -r port pid < .cache/serve.ready || true
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ready=1; break; fi
    fi
    if [ "${OPEN_UI_TIMEOUT:-0}" -gt 0 ] && [ $(( $(date +%s) - t0 )) -ge "$OPEN_UI_TIMEOUT" ]; then break; fi
    sleep 1
  done
  if [ "$ready" != 1 ]; then
    echo "start.sh: the server was not ready after $(( $(date +%s) - t0 ))s (OPEN_UI_TIMEOUT=$OPEN_UI_TIMEOUT); the web UI was not opened. It may still be loading: watch the serve.sh lines above" >&2
    return 0
  fi
  url="http://127.0.0.1:$port/?model=chat"
  . "$ROOT/scripts/lib/instance-key.sh"
  key=$(instance_key_first "$(instance_key_file "$port")" || true)
  if [ "${COPY_KEY:-0}" = 1 ]; then
    if command -v pbcopy >/dev/null 2>&1; then printf %s "$key" | pbcopy || true
    elif command -v termux-clipboard-set >/dev/null 2>&1; then printf %s "$key" | termux-clipboard-set || true
    elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then printf %s "$key" | wl-copy || true
    elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then printf %s "$key" | xclip -selection clipboard || true
    fi
  fi
  {
    echo
    printf '  Web UI:  %s\n' "$url"
    pubs=$(public_hosts "${HOST:-127.0.0.1}")
    if [ -n "$pubs" ]; then
      printf '%s\n' "$pubs" | while IFS= read -r h; do
        [ -n "$h" ] || continue
        printf '  Web UI:  http://%s:%s/?model=chat\n' "$(url_host "$h")" "$port"
      done
      echo "  $(t "Other machines can use these addresses. The API key is sent as plain HTTP.")"
    else
      case ",$(bind_hosts "${HOST:-127.0.0.1}")," in
        *,0.0.0.0,*|*,::,*)
          echo "  $(t "Other machines can connect to this machine on this port. The API key is sent as plain HTTP.")"
          ;;
      esac
    fi
    echo "  API key: $key"
    echo "  $(t "The page will ask for the API key the first time. Paste the key printed above.")"
    echo "  $(t "Stop with Ctrl-C or by closing this terminal.")"
    echo
  } >&2
  [ "${NO_BROWSER:-0}" = 1 ] && return 0
  if [ "$(uname -s)" = Darwin ]; then open "$url" || true
  elif command -v termux-open-url >/dev/null 2>&1; then termux-open-url "$url" || true
  elif [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && command -v xdg-open >/dev/null 2>&1; then xdg-open "$url" >/dev/null 2>&1 &
  else say "$url"; fi
}
# Cockpit (live logs, startup recovery): started here so nobody has to run it by hand. It reads
# the instance key itself; the browser never asks for it. COCKPIT=0 skips it; COCKPIT_PORT moves it.
start_cockpit() {
  [ "${COCKPIT:-1}" = 1 ] && command -v python3 >/dev/null 2>&1 || return 0
  cp_port=${COCKPIT_PORT:-9933}
  i=0
  while [ "$i" -le 20 ]; do
    if curl -s --max-time 1 "http://127.0.0.1:$cp_port/session" 2>/dev/null | grep -q '"auth"'; then
      say "cockpit (live logs): http://127.0.0.1:$cp_port/ (already running)"; return 0
    fi
    port_busy "$cp_port" || break
    cp_port=$((cp_port + 1)); i=$((i + 1))
  done
  mkdir -p .cache
  COCKPIT_PORT=$cp_port nohup python3 scripts/cockpit.py >> .cache/cockpit.log 2>&1 </dev/null &
  say "cockpit (live logs, startup recovery): http://127.0.0.1:$cp_port/ (logs: $ROOT/.cache/cockpit.log)"
}
rm -f .cache/serve.ready
start_cockpit
open_ui "$$" &
if [ "$TERMUX" = 1 ] && command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 && export TERMUX_WAKE_LOCKED=1 || true
fi
case "${DETACH_MODE:-foreground}" in
  tmux)
    if command -v tmux >/dev/null 2>&1; then
      say "launching detached inside tmux session familia-server"
      exec tmux new-session -d -s familia-server "sh scripts/serve.sh $*"
    else
      say "tmux requested but not found; falling back to nohup"
      mkdir -p .cache
      say "logs: $ROOT/.cache/server.log"
      nohup sh scripts/serve.sh "$@" >> .cache/server.log 2>&1 &
      disown $! 2>/dev/null || true
    fi
    ;;
  screen)
    if command -v screen >/dev/null 2>&1; then
      say "launching detached inside screen session familia-server (10000 lines of scrollback)"
      exec screen -h 10000 -dmS familia-server sh scripts/serve.sh "$@"
    else
      say "screen requested but not found; falling back to nohup"
      mkdir -p .cache
      say "logs: $ROOT/.cache/server.log"
      nohup sh scripts/serve.sh "$@" >> .cache/server.log 2>&1 &
      disown $! 2>/dev/null || true
    fi
    ;;
  screen-attached)
    if command -v screen >/dev/null 2>&1; then
      say "launching attached inside screen session familia-server (10000 lines of scrollback; detach with Ctrl-A then D; reattach with screen -r familia-server)"
      exec screen -h 10000 -S familia-server sh scripts/serve.sh "$@"
    else
      say "screen-attached requested but screen is not installed"
      exit 1
    fi
    ;;
  nohup)
    say "launching detached with nohup (logs: $ROOT/.cache/server.log)"
    mkdir -p .cache
    nohup sh scripts/serve.sh "$@" >> .cache/server.log 2>&1 &
    disown $! 2>/dev/null || true
    ;;
  foreground|"")
    exec scripts/serve.sh "$@"
    ;;
  *)
    say "unknown DETACH_MODE=$DETACH_MODE (foreground|nohup|tmux|screen|screen-attached)"
    exit 1
    ;;
esac
