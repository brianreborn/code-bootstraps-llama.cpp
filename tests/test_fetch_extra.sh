#!/bin/sh
# --ask lists hashed extras only, reads one name from stdin, and does not
# replace the default general and coder files. No llama-server, no real download.
#   sh tests/test_fetch_extra.sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d)
fails=0
cleanup() { rm -rf "$T"; }
trap cleanup EXIT
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
tab=$(printf '\t')
inode() { stat -c '%i' "$1" 2>/dev/null || stat -f '%i' "$1"; }

mkdir -p "$T/stubs"
cat > "$T/stubs/curl" <<'EOF'
#!/bin/sh
out=""
prev=""
url=""
for a in "$@"; do
  if [ "$prev" = "-o" ]; then out=$a; fi
  prev=$a
  case "$a" in
    http://*|https://*) url=$a ;;
  esac
done
[ -n "$out" ] || exit 2
if [ -n "${CURL_LOG:-}" ]; then printf '%s\n' "$url" >> "$CURL_LOG"; fi
printf 'downloaded\n' > "$out"
exit 0
EOF
cat > "$T/stubs/sha256sum" <<'EOF'
#!/bin/sh
printf '%s  %s\n' "$WANT_SHA" "$1"
EOF
chmod +x "$T/stubs/curl" "$T/stubs/sha256sum"

sb() {
  d=$1
  rm -rf "$d"
  mkdir -p "$d"
  cp -R "$ROOT/scripts" "$d/"
}

cat > "$T/fake.json" <<'EOF'
{
  "candidates": [
    {
      "role": "general",
      "pick": "default",
      "repo": "example/general",
      "revision": "abc",
      "file": "general-default.gguf",
      "sha256": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "tested": true
    },
    {
      "role": "coder",
      "pick": "default",
      "repo": "example/coder",
      "revision": "abc",
      "file": "coder-default.gguf",
      "sha256": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "tested": true
    },
    {
      "role": "coder",
      "pick": "extra",
      "repo": "example/extra",
      "revision": "abc",
      "file": "extra-coder.gguf",
      "sha256": "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
      "tested": false
    },
    {
      "role": "jev",
      "pick": "nosha",
      "repo": "example/nosha",
      "revision": "abc",
      "file": "no-sha.gguf",
      "sha256": "",
      "dir": "models-optional/jev",
      "tested": false
    }
  ]
}
EOF

EXTRA_SHA=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
sb "$T/sb"

ask() {
  log=$1
  store=$2
  want=${3:-$EXTRA_SHA}
  : > "$log"
  PATH="$T/stubs:$PATH" GGUF_HOME="$store" MANIFEST="$T/fake.json" CURL_LOG="$log" \
    WANT_SHA="$want" \
    sh "$T/sb/scripts/fetch-models.sh" --ask > "$T/out.txt" 2>&1
}

offers() { grep '^fetch-models.sh: offer ' "$T/out.txt" || true; }

# --- nothing chosen: no download, empty sha not offered, defaults not offered ---
if printf '\n' | ask "$T/empty.log" "$T/empty-store"; then
  off=$(offers)
  if [ ! -s "$T/empty.log" ] && [ ! -e "$T/empty-store" ] \
    && printf '%s\n' "$off" | grep -F 'extra/extra-coder.gguf' >/dev/null \
    && ! printf '%s\n' "$off" | grep -F 'general-default.gguf' >/dev/null \
    && ! printf '%s\n' "$off" | grep -F 'coder-default.gguf' >/dev/null \
    && ! printf '%s\n' "$off" | grep -F 'no-sha.gguf' >/dev/null \
    && ! grep -F 'no-sha.gguf' "$T/out.txt" >/dev/null; then
    ok "empty answer downloads nothing and hides the default pair and an empty sha"
  else
    bad "empty answer: $(tail -n 20 "$T/out.txt")"
  fi
else
  bad "empty answer failed: $(tail -n 12 "$T/out.txt")"
fi

if printf '   \n' | ask "$T/blank.log" "$T/blank-store"; then
  if [ ! -s "$T/blank.log" ] && [ ! -e "$T/blank-store" ]; then
    ok "whitespace answer downloads nothing"
  else
    bad "whitespace answer downloaded: $(cat "$T/blank.log" 2>/dev/null || true)"
  fi
else
  bad "whitespace answer failed: $(tail -n 8 "$T/out.txt")"
fi

if ask "$T/eof.log" "$T/eof-store" </dev/null; then
  if [ ! -s "$T/eof.log" ] && [ ! -e "$T/eof-store" ]; then
    ok "closed stdin downloads nothing"
  else
    bad "closed stdin downloaded"
  fi
else
  bad "closed stdin failed: $(tail -n 8 "$T/out.txt")"
fi

if printf 'nope\n' | ask "$T/nope.log" "$T/nope-store"; then
  if [ ! -s "$T/nope.log" ] && [ ! -e "$T/nope-store" ]; then
    ok "unknown name downloads nothing"
  else
    bad "unknown name downloaded: $(cat "$T/nope.log")"
  fi
else
  bad "unknown name failed: $(tail -n 8 "$T/out.txt")"
fi

if printf 'no-sha.gguf\n' | ask "$T/nosha.log" "$T/nosha-store"; then
  if [ ! -s "$T/nosha.log" ] && [ ! -e "$T/nosha-store" ] \
    && grep -F "not one listed extra" "$T/out.txt" >/dev/null; then
    ok "empty sha row is not offered and is not fetched"
  else
    bad "empty sha was fetched: $(tail -n 12 "$T/out.txt")"
  fi
else
  bad "empty sha choice failed: $(tail -n 8 "$T/out.txt")"
fi

# --- one listed extra: only that file, defaults stay put ---
store=$T/ok-store
mkdir -p "$store/models/general" "$store/models/coder" \
  "$T/sb/models/general" "$T/sb/models/coder"
printf 'keep-general\n' > "$store/models/general/general-default.gguf"
printf 'keep-coder\n' > "$store/models/coder/coder-default.gguf"
printf 'checkout-general\n' > "$T/sb/models/general/general-default.gguf"
printf 'checkout-coder\n' > "$T/sb/models/coder/coder-default.gguf"
ig=$(inode "$store/models/general/general-default.gguf")
ic=$(inode "$store/models/coder/coder-default.gguf")
cig=$(inode "$T/sb/models/general/general-default.gguf")
cic=$(inode "$T/sb/models/coder/coder-default.gguf")
printf 'downloaded\n' > "$T/expect-downloaded"
printf 'keep-general\n' > "$T/expect-general"
printf 'keep-coder\n' > "$T/expect-coder"
if printf 'extra-coder.gguf\n' | ask "$T/ok.log" "$store"; then
  if [ "$(cat "$T/ok.log")" = "https://huggingface.co/example/extra/resolve/abc/extra-coder.gguf" ] \
    && [ -f "$store/models/coder/extra-coder.gguf" ] \
    && cmp -s "$store/models/coder/extra-coder.gguf" "$T/expect-downloaded" \
    && [ "$(inode "$store/models/general/general-default.gguf")" = "$ig" ] \
    && [ "$(inode "$store/models/coder/coder-default.gguf")" = "$ic" ] \
    && cmp -s "$store/models/general/general-default.gguf" "$T/expect-general" \
    && cmp -s "$store/models/coder/coder-default.gguf" "$T/expect-coder" \
    && [ "$(inode "$T/sb/models/general/general-default.gguf")" = "$cig" ] \
    && [ "$(inode "$T/sb/models/coder/coder-default.gguf")" = "$cic" ] \
    && [ ! -e "$store/models-inactive/coder/coder-default.gguf" ] \
    && [ ! -e "$store/models-inactive/general/general-default.gguf" ] \
    && [ ! -e "$store/models-optional/jev/no-sha.gguf" ] \
    && [ ! -e "$store/models/coder/extra-coder.gguf.part" ] \
    && [ ! -e "$store/models/general/general-default.gguf.part" ]; then
    n=$(find "$store" -name '*.gguf' | wc -l | tr -d ' ')
    if [ "$n" = 3 ]; then
      ok "listed extra downloads only that file and leaves the default pair"
    else
      bad "store has $n gguf files, want 3"
    fi
  else
    bad "listed extra: log=$(cat "$T/ok.log" 2>/dev/null || true) $(tail -n 15 "$T/out.txt")"
  fi
else
  bad "listed extra failed: $(tail -n 15 "$T/out.txt")"
fi

# --- mismatch is not the live file, and still does not move the defaults ---
badstore=$T/bad-store
mkdir -p "$badstore/models/general" "$badstore/models/coder"
printf 'keep-general\n' > "$badstore/models/general/general-default.gguf"
printf 'keep-coder\n' > "$badstore/models/coder/coder-default.gguf"
bg=$(inode "$badstore/models/general/general-default.gguf")
bc=$(inode "$badstore/models/coder/coder-default.gguf")
if printf 'extra/extra-coder.gguf\n' | ask "$T/bad.log" "$badstore" \
    0000000000000000000000000000000000000000000000000000000000000000; then
  bad "ask accepted a sha256 mismatch"
else
  if [ ! -e "$badstore/models/coder/extra-coder.gguf" ] \
    && [ -f "$badstore/models/coder/extra-coder.gguf.bad" ] \
    && [ ! -e "$badstore/models/coder/extra-coder.gguf.part" ] \
    && [ "$(inode "$badstore/models/general/general-default.gguf")" = "$bg" ] \
    && [ "$(inode "$badstore/models/coder/coder-default.gguf")" = "$bc" ] \
    && [ ! -e "$badstore/models-inactive/coder/coder-default.gguf" ]; then
    ok "ask mismatch is not the live GGUF and does not move the defaults"
  else
    bad "ask mismatch left a live file or moved a default: $(tail -n 12 "$T/out.txt")"
  fi
fi

# --- real manifest: AgentHorse and JEV are offered because their sha is already known ---
real_rows=$T/real-rows
awk -v match_kv="" -v fields="pick role file sha256" -f "$ROOT/scripts/lib/manifest.awk" \
  "$ROOT/config/models-manifest.json" > "$real_rows"
if printf '\n' | PATH="$T/stubs:$PATH" GGUF_HOME="$T/real-store" \
    MANIFEST="$ROOT/config/models-manifest.json" CURL_LOG="$T/real.log" \
    sh "$T/sb/scripts/fetch-models.sh" --ask > "$T/real.out" 2>&1; then
  grep '^fetch-models.sh: offer ' "$T/real.out" > "$T/real-offers" || true
  miss=0
  while IFS= read -r line; do
    rest=${line#fetch-models.sh: offer }
    token=${rest%% *}
    pick=${token%%/*}
    file=${token#*/}
    found=0
    while IFS=$tab read -r p r f sha; do
      if [ "$p" = "$pick" ] && [ "$f" = "$file" ]; then
        found=1
        case "$sha" in
          ""|-) bad "real offer $token has no sha256"; miss=1 ;;
        esac
        if [ "$p" = default ] && [ "$r" = general ]; then bad "offered default general"; miss=1; fi
        if [ "$p" = default ] && [ "$r" = coder ]; then bad "offered default coder"; miss=1; fi
      fi
    done < "$real_rows"
    if [ "$found" != 1 ]; then bad "offer $token is not one manifest row"; miss=1; fi
  done < "$T/real-offers"
  if [ "$miss" = 0 ] && [ -s "$T/real-offers" ] \
    && grep -F 'offer agenthorse/AgentHorse-4B.Q4_K_M.gguf' "$T/real-offers" >/dev/null \
    && grep -F 'offer jev/Qwen3-0.6B-Q8_0.gguf' "$T/real-offers" >/dev/null \
    && ! grep -F 'LFM2.5-1.2B-Instruct-Q4_K_M.gguf' "$T/real-offers" >/dev/null \
    && ! grep -F 'Qwen3.5-2B-Q4_K_M.gguf' "$T/real-offers" >/dev/null \
    && [ ! -s "$T/real.log" ] && [ ! -e "$T/real-store" ]; then
    ok "real manifest offers only hashed rows other than the default general and coder"
  else
    bad "real manifest offers: $(tail -n 20 "$T/real.out")"
  fi
else
  bad "real manifest ask failed: $(tail -n 12 "$T/real.out")"
fi

# A file name shared by two rows is not one choice, so nothing is fetched.
: > "$T/ambig.log"
if printf '%s\n' 'Qwen3.5-0.8B-Q4_K_M.gguf' | PATH="$T/stubs:$PATH" GGUF_HOME="$T/ambig-store" \
    MANIFEST="$ROOT/config/models-manifest.json" CURL_LOG="$T/ambig.log" \
    sh "$T/sb/scripts/fetch-models.sh" --ask > "$T/ambig.out" 2>&1 \
  && [ ! -s "$T/ambig.log" ] && [ ! -e "$T/ambig-store" ]; then
  ok "ambiguous file name downloads nothing"
else
  bad "ambiguous file fetched: $(cat "$T/ambig.log" 2>/dev/null || true)"
fi

# The known AgentHorse row, and only that file, into the store. Defaults stay.
agent=$(awk -v match_kv="pick=agenthorse" -v fields="file sha256" \
  -f "$ROOT/scripts/lib/manifest.awk" "$ROOT/config/models-manifest.json")
agent_file=${agent%%"$tab"*}
agent_sha=${agent#*"$tab"}
gen=$(awk -v match_kv="pick=default role=general" -v fields="file" \
  -f "$ROOT/scripts/lib/manifest.awk" "$ROOT/config/models-manifest.json")
cod=$(awk -v match_kv="pick=default role=coder" -v fields="file" \
  -f "$ROOT/scripts/lib/manifest.awk" "$ROOT/config/models-manifest.json")
astore=$T/agent-store
mkdir -p "$astore/models/general" "$astore/models/coder"
printf 'keep-general\n' > "$astore/models/general/$gen"
printf 'keep-coder\n' > "$astore/models/coder/$cod"
aig=$(inode "$astore/models/general/$gen")
aic=$(inode "$astore/models/coder/$cod")
: > "$T/agent.log"
if printf 'agenthorse\n' | PATH="$T/stubs:$PATH" GGUF_HOME="$astore" \
    MANIFEST="$ROOT/config/models-manifest.json" CURL_LOG="$T/agent.log" WANT_SHA="$agent_sha" \
    sh "$T/sb/scripts/fetch-models.sh" --ask > "$T/agent.out" 2>&1 \
  && [ -f "$astore/models/coder/$agent_file" ] \
  && [ "$(wc -l < "$T/agent.log" | tr -d ' ')" = 1 ] \
  && grep -F "/$agent_file" "$T/agent.log" >/dev/null \
  && ! grep -F "/$gen" "$T/agent.log" >/dev/null \
  && ! grep -F "/$cod" "$T/agent.log" >/dev/null \
  && ! grep -F 'Qwen3-0.6B-Q8_0.gguf' "$T/agent.log" >/dev/null \
  && [ "$(inode "$astore/models/general/$gen")" = "$aig" ] \
  && [ "$(inode "$astore/models/coder/$cod")" = "$aic" ] \
  && [ ! -e "$astore/models-inactive/coder/$cod" ] \
  && [ ! -e "$astore/models/coder/$agent_file.part" ]; then
  ok "agenthorse ask downloads only that file and does not move the default pair"
else
  bad "agenthorse ask: $(tail -n 15 "$T/agent.out") log=$(cat "$T/agent.log" 2>/dev/null || true)"
fi

if [ "$fails" -eq 0 ]; then echo "all extra-model ask tests passed"
else echo "$fails failed"; exit 1; fi
