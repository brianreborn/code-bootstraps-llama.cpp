#!/bin/sh
# Click-and-go launcher (Linux, Android/Termux; macOS: start.command).
# Settings: PORT, VARIANT=auto|cpu|vulkan|cuda-12|cuda-13, NO_BROWSER=1, BUILD=1,
# COPY_KEY=1, WAKE_LOCK=0, RAISE=0|1, REASONING=on|auto (default off), plus everything scripts/serve.sh reads.
# On Linux this also asks once for memlock (scripts/raise.sh). One command.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$ROOT"
if [ -f "$ROOT/.cache/panel.env" ]; then . "$ROOT/.cache/panel.env"; fi
. "$ROOT/scripts/lib/i18n.sh"
. "$ROOT/scripts/lib/raise-once.sh"
. "$ROOT/scripts/lib/bindhost.sh"
LANG_CODE=$(lang_code_of "${LOCALE:-auto}")
export PORT="${PORT:-9931}"
say() { printf '%s\n' "start: $*" >&2; }
TERMUX=0
case "${PREFIX:-}" in *com.termux*) TERMUX=1 ;; esac

missing=""
for tool in curl tar awk; do
  command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"
done
command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 || command -v cksum >/dev/null 2>&1 || missing="$missing sha256sum"
if [ -n "$missing" ]; then
  say "$(t "Some required programs are missing.")$missing"
  if [ "$TERMUX" = 1 ]; then say "$(t "Install the missing programs with pkg install.")$missing"; fi
  exit 1
fi

maybe_raise

VARIANT=${VARIANT:-auto}
if [ -n "${LLAMA_SERVER:-}" ]; then
  say "$(t "using the binary you named")"
elif [ "${BUILD:-0}" != 1 ] && LLAMA_SERVER=$(scripts/fetch-llama.sh --variant "$VARIANT"); then
  :
else
  rc=$?
  if [ "${BUILD:-0}" != 1 ] && [ "$rc" != 3 ]; then
    say "$(t "downloading llama.cpp failed; check the network and run start.sh again")"
    exit 1
  fi
  say "$(t "no release binary for this machine; building from source")"
  case "$(uname -s)" in
    Darwin) script=scripts/build-macos.sh ;;
    *)
      if [ "$TERMUX" = 1 ]; then script=scripts/build-termux.sh
      else script=scripts/build-linux.sh; fi
      ;;
  esac
  command -v cmake >/dev/null 2>&1 || { say "$(t "cmake was not found")"; exit 1; }
  if [ ! -f llama.cpp/CMakeLists.txt ] && [ ! -e .git ]; then
    say "$(t "llama.cpp sources are missing from this download")"
    exit 1
  fi
  [ -f llama.cpp/CMakeLists.txt ] || git submodule update --init llama.cpp
  gpu_build=off
  case "$(cat .cache/llama-variant 2>/dev/null || true)" in
    vulkan) gpu_build=vulkan ;;
    cuda-*) gpu_build=cuda ;;
  esac
  if [ "$script" = scripts/build-linux.sh ] && [ "$gpu_build" != off ]; then
    say "$(t "Linux will use a GPU build so the GPU is not left idle.")"
    GPU=$gpu_build "$script"
  else
    "$script"
  fi
  LLAMA_SERVER=$(ls -d "$ROOT"/build-*/bin/llama-server 2>/dev/null | head -n 1 || true)
  [ -x "${LLAMA_SERVER:-}" ] || { say "$(t "build finished but llama-server was not found")"; exit 1; }
fi
export LLAMA_SERVER

rc=0
scripts/fetch-models.sh || rc=$?
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
  i=1
  while [ "$i" -le 600 ]; do
    kill -0 "$parent" 2>/dev/null || return 0
    if [ -s .cache/serve.ready ]; then
      read -r port pid < .cache/serve.ready || true
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then ready=1; break; fi
    fi
    sleep 1
    i=$((i + 1))
  done
  [ "$ready" = 1 ] || return 0
  url="http://127.0.0.1:$port/?model=coder"
  key=$(grep -v -e '^#' -e '^[[:space:]]*$' .secrets/api-keys 2>/dev/null | head -n 1 || true)
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
        printf '  Web UI:  http://%s:%s/?model=coder\n' "$(url_host "$h")" "$port"
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
rm -f .cache/serve.ready
open_ui "$$" &
if [ "$TERMUX" = 1 ] && [ "${WAKE_LOCK:-1}" != 0 ] && command -v termux-wake-lock >/dev/null 2>&1; then
  termux-wake-lock >/dev/null 2>&1 && export TERMUX_WAKE_LOCKED=1 || true
fi
exec scripts/serve.sh "$@"
