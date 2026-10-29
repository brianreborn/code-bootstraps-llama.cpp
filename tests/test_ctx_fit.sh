#!/bin/sh
# Context fitting (n_ctx_train): runs serve.sh's ctx-fit block with a stub manifest and preset,
# and gguf_ctx.py on a synthetic GGUF header. No model, no server.
set -eu
here=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd); root=$(dirname "$here")
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
fail() { echo "test_ctx_fit: FAIL $*" >&2; exit 1; }
# 1) gguf_ctx.py reads <arch>.context_length from the header
python3 - "$tmp/t.gguf" <<'PY'
import struct, sys
def s(x): b = x.encode(); return struct.pack("<Q", len(b)) + b
kv = [s("general.architecture") + struct.pack("<I", 8) + s("lfm3"),
      s("tokenizer.ggml.tokens") + struct.pack("<IIQ", 9, 8, 2) + s("a") + s("b"),
      s("lfm3.context_length") + struct.pack("<II", 4, 8192)]
open(sys.argv[1], "wb").write(b"GGUF" + struct.pack("<IQQ", 3, 0, len(kv)) + b"".join(kv))
PY
got=$(python3 "$root/scripts/lib/gguf_ctx.py" "$tmp/t.gguf" | cut -f1,2)
[ "$got" = "$(printf '8192\tlfm3')" ] || fail "gguf_ctx.py printed '$got'"
# 2) the serve.sh block
cat > "$tmp/m.json" <<'J'
{
    "candidates": [
        {
            "role": "decision",
            "file": "small.gguf",
            "n_ctx_train": 8192
        },
        {
            "role": "general",
            "file": "big.gguf",
            "n_ctx_train": 262144
        }
    ]
}
J
printf '[*]\nctx-size = 131072\n[general]\ntemp = 0.4\n[decision]\nctx-size = 32768\nbatch-size = 16384\nubatch-size = 32768\n' > "$tmp/p.ini"
sed -n '/^# >>> ctx-fit/,/^# <<< ctx-fit/p' "$root/scripts/serve.sh" > "$tmp/fit.sh"
[ -s "$tmp/fit.sh" ] || fail "ctx-fit markers missing in serve.sh"
run() { # OVERLAY -> prints OVERLAY and CTX_FIT after the block
  ( ROOT=$root MANIFEST=$tmp/m.json MODELS_PRESET=$tmp/p.ini OVERLAY=$1
    M_GENERAL=/x/big.gguf M_CODER=/x/big.gguf M_DECISION=/x/small.gguf LANG_MODEL=""
    warn() { echo "WARN $*"; }
    ov_set() { ov_o=""; for ov_x in $OVERLAY; do [ "${ov_x%%=*}" = "$1" ] || ov_o="$ov_o$ov_x "; done; OVERLAY="${ov_o}$1=$2"; }
    . "$tmp/fit.sh"; echo "OVERLAY=$OVERLAY"; echo "FIT=$CTX_FIT" ) 2>&1
}
out=$(run "decision.load-on-startup=true")
echo "$out" | grep -q "context decision 8192 (model max; profile asked 32768)" || fail "no fit line: $out"
for k in ctx-size batch-size ubatch-size; do echo "$out" | grep -q "decision.$k=8192" || fail "decision.$k not 8192: $out"; done
echo "$out" | grep -q "general.ctx-size" && fail "general refitted: $out"
out=$(run "decision.ctx-size=4096 decision.parallel=1")
echo "$out" | grep -q "FIT=$" || fail "4096 refitted: $out"
echo "$out" | grep -q "decision.batch-size=4096" || fail "batch not fitted to 4096: $out"
printf '[decision]\nctx-size = 32768\nrope-scaling = yarn\n' > "$tmp/p.ini"
out=$(run ""); echo "$out" | grep -q "FIT=$" || fail "opt-in rope refitted: $out"
echo "test_ctx_fit: OK"
