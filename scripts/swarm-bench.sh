#!/bin/sh
# /run bench entry point (familia issue #183). THIN STUB: speed smoke only on the smallest
# model; quality benchmarks (lm-eval, BFCL, MTEB) and full model coverage are swarm work.
# Prints a markdown result table on stdout. No sudo. Downloads go to $SWARM_BENCH_CACHE.
# Exit 78 = skipped (no llama-bench on this runner).
set -u
cache=${SWARM_BENCH_CACHE:-$HOME/.cache/familia-bench}
models=${SWARM_BENCH_MODELS:-"bartowski/SmolLM2-135M-Instruct-GGUF/SmolLM2-135M-Instruct-Q8_0.gguf"}
lb=${LLAMA_BENCH:-$(command -v llama-bench 2>/dev/null || true)}
if [ -z "$lb" ]; then
	for c in ./build-*/bin/llama-bench "$HOME"/code-bootstraps-llama.cpp/build-*/bin/llama-bench /workspace/cbl/build-*/bin/llama-bench; do
		[ -x "$c" ] && { lb=$c; break; }
	done
fi
[ -n "$lb" ] && [ -x "$lb" ] || { echo "llama-bench not found (set LLAMA_BENCH)"; exit 78; }
mkdir -p "$cache"
h=$(hostname | cut -d. -f1); u=$(id -un)
echo "| node | model | test | tok/s |"
echo "|---|---|---|---|"
rc=0
for m in $models; do
	repo=${m%/*}; file=${m##*/}; f=$cache/$file
	[ -s "$f" ] || curl -fsSL -o "$f" "https://huggingface.co/$repo/resolve/main/$file" || { echo "| $h-$u | $file | download | FAIL |"; rc=1; continue; }
	"$lb" -m "$f" -p 64 -n 16 -r 2 -o csv 2>/dev/null > "$cache/out.csv" || { echo "| $h-$u | $file | llama-bench | FAIL |"; rc=1; continue; }
	python3 - "$cache/out.csv" "$h-$u" "$file" <<'PY'
import csv,sys
for r in csv.DictReader(open(sys.argv[1])):
    t=("pp%s"%r["n_prompt"]) if r.get("n_prompt","0")!="0" else ("tg%s"%r["n_gen"])
    print("| %s | %s | %s | %.1f |"%(sys.argv[2],sys.argv[3],t,float(r["avg_ts"])))
PY
done
echo
echo "_stub: speed only; quality suites pending (#183)_"
exit $rc
