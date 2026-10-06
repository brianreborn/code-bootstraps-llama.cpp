#!/bin/sh
# REASONING overlay: empty and off leave the preset; on and auto set general and coder only.
# Uses a stub llama-server that exits at once, so no model is loaded.
#   sh tests/test_reasoning.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib/common.sh"
T=$(mktemp -d)
fails=0
cleanup() {
  if [ -f "$T/pids" ]; then
    while IFS= read -r p; do
      [ -n "$p" ] || continue
      kill -TERM -"$p" 2>/dev/null || true
    done < "$T/pids"
  fi
  rm -rf "$T"
}
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
: > "$T/pids"
printf '%s\n' '#!/bin/sh' 'exit 0' > "$T/llama-server"
chmod +x "$T/llama-server"
tab=$(printf '\t')

sandbox() {
  d=$1
  mkdir -p "$d/.cache/verified"
  cp -R "$ROOT/scripts" "$ROOT/config" "$d/"
  awk -v match_kv="pick=default" -v fields="role file sha256" -f "$ROOT/scripts/lib/manifest.awk" \
    "$ROOT/config/models-manifest.json" > "$d/.cache/default-rows"
  while IFS=$tab read -r role f sha; do
    mkdir -p "$d/models/$role"
    echo "placeholder $f" > "$d/models/$role/$f"
    fingerprint "$d/models/$role/$f" > "$d/.cache/verified/$sha"
  done < "$d/.cache/default-rows"
}
place() {
  sha=$1
  path=$2
  d=$3
  mkdir -p "$(dirname "$path")" "$d/.cache/verified"
  echo "placeholder $sha" > "$path"
  fingerprint "$path" > "$d/.cache/verified/$sha"
}

nkey() {
  awk -v sec="$2" -v key="$3" '
    /^\[/ { s = substr($0, 2, index($0, "]") - 2); next }
    s == sec && $0 ~ "^" key "[ \t]*=" { n++ }
    END { print n + 0 }
  ' "$1"
}
val() {
  awk -v sec="$2" -v key="$3" '
    /^\[/ { s = substr($0, 2, index($0, "]") - 2); next }
    s == sec && $0 ~ "^" key "[ \t]*=" {
      sub(/^[^=]*=[ \t]*/, ""); sub(/[ \t\r]+$/, ""); print; exit
    }
  ' "$1"
}

src=$ROOT/config/models-preset.ini
if [ "$(nkey "$src" coder reasoning)" = 1 ] && [ "$(val "$src" coder reasoning)" = off ] \
  && [ "$(nkey "$src" language reasoning)" = 1 ] && [ "$(val "$src" language reasoning)" = off ] \
  && [ "$(nkey "$src" locale.ja.general reasoning)" = 1 ] && [ "$(val "$src" locale.ja.general reasoning)" = off ] \
  && [ "$(nkey "$src" locale.ja.coder reasoning)" = 1 ] && [ "$(val "$src" locale.ja.coder reasoning)" = off ] \
  && [ "$(nkey "$src" general reasoning)" = 0 ] && [ "$(nkey "$src" decision reasoning)" = 0 ]; then
  ok "committed preset keeps reasoning off (coder, language, locale only)"
else
  bad "committed preset reasoning keys changed"
fi

cat > "$T/launch.py" <<'PY'
import os, signal, subprocess, sys, time
d, port, binpath, out = sys.argv[1:5]
env = os.environ.copy()
env.pop("REASONING", None)
env.update({
    "PORT": port,
    "PROFILE": "lowram",
    "TOOLS_RUNTIME": "host",
    "TOOLS": "",
    "MCP_CONFIG": "",
    "LOCALE": "en",
    "LANGUAGE_MODE": "off",
    "LLAMA_SERVER": binpath,
    # Sandbox is the store, so a real ~/.local/share/gguf is not read.
    "GGUF_HOME": d,
})
for item in sys.argv[5:]:
    k, v = item.split("=", 1)
    env[k] = v
log = open(out, "w")
p = subprocess.Popen(["sh", "scripts/serve.sh"], cwd=d, env=env, stdout=log, stderr=subprocess.STDOUT,
                     start_new_session=True)
with open(os.environ["PIDFILE"], "a") as f:
    f.write(str(p.pid) + "\n")
ini = os.path.join(d, ".cache", "models-preset.effective.ini")
deadline = time.time() + 40
while time.time() < deadline:
    if p.poll() is not None:
        break
    if os.path.isfile(ini) and os.path.getsize(ini) > 0:
        # preset is written before the server is exec'd; let the stub exit too
        time.sleep(0.2)
        if p.poll() is not None:
            break
    time.sleep(0.05)
if p.poll() is None:
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        p.wait(timeout=5)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL)
        p.wait(timeout=5)
else:
    try:
        os.killpg(p.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
sys.exit(0)
PY

launch() {
  name=$1
  shift
  d=$T/$name
  rm -rf "$d"
  sandbox "$d"
  if [ "${1:-}" = --language ]; then
    shift
    place 4383ac0c3c8e476de98ff979c2a3f069f8c4fb385e7860cf2d28da896cc477c7 \
      "$d/models-optional/language/HY-MT1.5-1.8B-Q4_K_M.gguf" "$d"
  fi
  if [ "${1:-}" = --locale ]; then
    shift
    place fc3404fe7aa1f9dce8ff88d348308606c73eb6dfbf7c920148fe7a722bf105dc \
      "$d/models-optional/locale/ja/Qwen3.5-0.8B-Japanese-SFT-v2-Q4_K_M.gguf" "$d"
  fi
  port=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()')
  PIDFILE=$T/pids python3 "$T/launch.py" "$d" "$port" "$T/llama-server" "$d/out.txt" "$@"
  printf '%s\n' "$d"
}

expect_off() {
  ini=$1/.cache/models-preset.effective.ini
  name=$2
  if [ ! -f "$ini" ]; then bad "$name: no effective preset: $(tail -n 5 "$1/out.txt")"; return; fi
  if [ "$(nkey "$ini" general reasoning)" = 0 ] && [ "$(nkey "$ini" coder reasoning)" = 1 ] \
    && [ "$(val "$ini" coder reasoning)" = off ] && [ "$(nkey "$ini" decision reasoning)" = 0 ] \
    && [ "$(nkey "$ini" language reasoning)" = 0 ] \
    && ! grep -E 'reasoning[ \t]*=[ \t]*(on|auto)' "$ini" >/dev/null; then
    ok "$name: no reasoning overlay"
  else
    bad "$name: preset changed: $(grep reasoning "$ini" || true)"
  fi
}

expect_mode() {
  ini=$1/.cache/models-preset.effective.ini
  name=$2
  mode=$3
  lang_off=$4
  if [ ! -f "$ini" ]; then bad "$name: no effective preset: $(tail -n 8 "$1/out.txt")"; return; fi
  lang_n=$(nkey "$ini" language reasoning)
  lang_v=$(val "$ini" language reasoning)
  if [ "$lang_off" = yes ]; then
    lang_ok=0
    [ "$lang_n" = 1 ] && [ "$lang_v" = off ] && lang_ok=1
  else
    lang_ok=0
    [ "$lang_n" = 0 ] && lang_ok=1
  fi
  if [ "$lang_ok" = 1 ] && [ "$(nkey "$ini" general reasoning)" = 1 ] && [ "$(val "$ini" general reasoning)" = "$mode" ] \
    && [ "$(nkey "$ini" coder reasoning)" = 1 ] && [ "$(val "$ini" coder reasoning)" = "$mode" ] \
    && [ "$(nkey "$ini" decision reasoning)" = 0 ] \
    && [ "$(nkey "$ini" locale.ja.general reasoning)" = 0 ] && [ "$(nkey "$ini" locale.ja.coder reasoning)" = 0 ]; then
    ok "$name: general and coder reasoning=$mode, decision and language stay off"
  else
    bad "$name: got general=$(val "$ini" general reasoning) coder=$(val "$ini" coder reasoning) decision=$(nkey "$ini" decision reasoning) language=$lang_n:$lang_v"
    grep -n reasoning "$ini" || true
  fi
}

d=$(launch unset)
expect_off "$d" "REASONING unset"
d=$(launch off REASONING=off)
expect_off "$d" "REASONING=off"
d=$(launch on REASONING=on)
expect_mode "$d" "REASONING=on" on no
d=$(launch auto REASONING=auto)
expect_mode "$d" "REASONING=auto" auto no
d=$(launch interpret --language REASONING=on LANGUAGE_MODE=interpret LOCALE=ja)
expect_mode "$d" "interpret + REASONING=on" on yes
d=$(launch swap --locale REASONING=on LANGUAGE_MODE=swap LOCALE=ja SWAP_CODER=1)
expect_mode "$d" "swap + REASONING=on" on no
d=$(launch bad REASONING=yes)
if [ -f "$d/.cache/models-preset.effective.ini" ]; then
  bad "REASONING=yes wrote a preset"
elif grep -q "unknown REASONING" "$d/out.txt"; then
  ok "REASONING=yes is refused"
else
  bad "REASONING=yes: $(tail -n 5 "$d/out.txt")"
fi

if [ "$fails" -eq 0 ]; then echo "all reasoning overlay tests passed"
else echo "$fails failed"; exit 1; fi
