#!/bin/sh
# serve.sh / serve.ps1 wire the metrics gate: --turbo is consumed (never passed to llama-server),
# --metrics is refused, metrics on => LLAMA_ARG_ENDPOINT_METRICS + sampler, turbo => neither.
set -eu
ROOT=$(unset CDPATH; cd -- "$(dirname -- "$0")/.." && pwd)
die() { echo "FAIL: $*" >&2; exit 1; }
s=$ROOT/scripts/serve.sh; p=$ROOT/scripts/serve.ps1
grep -q 'case "$a" in --turbo) FAMILIA_TURBO=1; continue' "$s" || die "serve.sh does not consume --turbo"
grep -q -- '--metrics) die' "$s" || die "serve.sh does not refuse --metrics"
grep -q '\[ "$METRICS_ON" = 1 \] && export LLAMA_ARG_ENDPOINT_METRICS=1' "$s" || die "serve.sh metrics endpoint not gated"
grep -q 'if \[ "$METRICS_ON" = 1 \]; then' "$s" || die "serve.sh sampler not gated"
grep -q 'kill "$METRICS_PID"' "$s" || die "serve.sh does not stop the sampler"
grep -q 'if ($metricsOn) { $env:LLAMA_ARG_ENDPOINT_METRICS = "1" }' "$p" || die "serve.ps1 metrics endpoint not gated"
grep -q '\[switch\]$Turbo' "$p" || die "serve.ps1 has no -Turbo"
# the gate itself, end to end through the CLI serve.sh calls
py=$ROOT/scripts/lib/metrics.py
[ "$(FAMILIA_TURBO='' python3 "$py" status)" = on ] || die "default not on"
st=0; FAMILIA_TURBO=1 python3 "$py" status >/dev/null || st=$?; [ "$st" = 3 ] || die "FAMILIA_TURBO=1 not off"
st=0; python3 "$py" status --turbo >/dev/null || st=$?; [ "$st" = 3 ] || die "--turbo not off"
echo "test_metrics_turbo: ok"
