#!/bin/sh
# MODEL_SET=official|unimpeded (config/model-sets.json): both sets name a pinned manifest
# file for every role the manifest has, unknown values are refused by every launcher, and
# --set does not loosen the model / host flag refusals.
#   sh tests/test_model_sets.sh
set -eu
ROOT=$(CDPATH="" cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
fails=0
note() { if [ "$1" = ok ]; then echo "ok   $2"; else echo "FAIL $2"; fails=$((fails + 1)); fi; }
tab=$(printf '\t')

# 1. every manifest role resolves in both sets to one manifest row with revision + sha256
for set in official unimpeded; do
  for role in $(awk -v match_kv="" -v fields="role" -f scripts/lib/manifest.awk config/models-manifest.json | grep -vx -- - | sort -u); do
    sp=$(MODEL_SET=$set ROOT=$ROOT sh -c '. scripts/lib/modelset.sh; model_set_pick "$1"' x "$role")
    if [ -z "$sp" ]; then note bad "$set/$role: no entry in config/model-sets.json"; continue; fi
    n=$(awk -v match_kv="pick=${sp%%"$tab"*} role=${sp#*"$tab"}" -v fields="revision sha256" -f scripts/lib/manifest.awk config/models-manifest.json |
      awk -F '\t' '$1 ~ /^[0-9a-f]{40}$/ && $2 ~ /^[0-9a-f]{64}$/' | wc -l | tr -d ' ')
    if [ "$n" -ge 1 ]; then note ok "$set/$role -> $(printf '%s' "$sp" | tr '\t' '/') pinned"
    else note bad "$set/$role -> $sp: no pinned manifest row"; fi
  done
done
# 2. the unimpeded set is today's default (behaviour unchanged): pick=default for general/coder
for role in general coder; do
  sp=$(MODEL_SET=unimpeded ROOT=$ROOT sh -c '. scripts/lib/modelset.sh; model_set_pick "$1"' x "$role")
  [ "${sp%%"$tab"*}" = default ] && note ok "unimpeded $role = manifest default" || note bad "unimpeded $role is $sp"
done
# official never serves the uncensored file
if MODEL_SET=official sh scripts/fetch-models.sh --dry-run 2>&1 | grep -q 'dry-run: .*Uncensored'; then
  note bad "official dry-run lists an uncensored file"
else note ok "official dry-run has no uncensored file"; fi
MODEL_SET=official sh scripts/fetch-models.sh --dry-run 2>&1 | grep -q 'dry-run: general LiquidAI/LFM3-1.7B-GGUF' &&
  note ok "official general = LiquidAI/LFM3-1.7B-GGUF" || note bad "official general"
sh scripts/fetch-models.sh --dry-run 2>&1 | grep -q 'dry-run: general AtomicChat/LFM3-1.7B-Uncensored-GGUF' &&
  note ok "no MODEL_SET = unimpeded default" || note bad "default set"
sh scripts/fetch-models.sh --set official --dry-run 2>&1 | grep -q 'dry-run: embed ggml-org/embeddinggemma-2-GGUF' &&
  note ok "fetch-models.sh --set official" || note bad "fetch-models.sh --set official"

# 3. unknown values refused
refused() {   # NAME CMD...: must exit non-zero and name the set
  name=$1; shift
  if out=$("$@" 2>&1); then note bad "$name accepted"; return; fi
  case "$out" in *"MODEL_SET"*"official|unimpeded"*) note ok "$name refused" ;; *) note bad "$name: $out" ;; esac
}
refused "fetch-models.sh MODEL_SET=bogus" env MODEL_SET=bogus sh scripts/fetch-models.sh --dry-run
refused "fetch-models.sh --set=bogus" sh scripts/fetch-models.sh --set=bogus --dry-run
refused "serve.sh MODEL_SET=bogus" env MODEL_SET=bogus LLAMA_SERVER=/nonexistent sh scripts/serve.sh
refused "serve.sh --set bogus" env LLAMA_SERVER=/nonexistent sh scripts/serve.sh --set bogus
refused "start.sh --set=bogus" env START_RESOLVE_ONLY=1 sh start.sh --set=bogus
# 4. --set does not let a model or host flag through
for a in "-m x.gguf" "--model=x.gguf" "--host 0.0.0.0" "--mmproj x"; do
  # shellcheck disable=SC2086
  if out=$(env LLAMA_SERVER=/nonexistent sh scripts/serve.sh --set official $a 2>&1); then note bad "serve.sh --set official $a accepted"
  else case "$out" in *"not allowed here"*) note ok "serve.sh --set official $a refused" ;; *) note bad "serve.sh $a: $out" ;; esac; fi
done
# official never falls back to the uncensored default: a missing official file stops serve.sh
ms_d=$(mktemp -d)
out=$(MODELS_DIR=$ms_d LLAMA_SERVER=/bin/true PORT=18779 TOOLS= sh scripts/serve.sh --set official 2>&1) || true
rm -rf "$ms_d"
case "$out" in *"MODEL_SET=official: the general role's model LFM3-1.7B-Q4_K_M.gguf is not installed"*) note ok "serve.sh official: missing file refused, no fallback" ;; *) note bad "serve.sh official missing: $(printf %s "$out" | tail -n 1)" ;; esac
# 5. PowerShell parity (when pwsh is here): same refusal and lookup
PWSH=${PWSH:-$(command -v pwsh || echo /workspace/tools/pwsh/pwsh)}
if [ -x "$PWSH" ]; then
  out=$("$PWSH" -NoProfile -Command ". ./scripts/lib/common.ps1; try { Assert-ModelSet bogus; 'accepted' } catch { \$_.ToString() }; (Get-ModelSetPick (Get-Location).Path official coder) -join '/'; (Get-ModelSetPick (Get-Location).Path unimpeded general) -join '/'" 2>&1)
  case "$out" in *"official|unimpeded"*"lfm3/general"*"default/general"*) note ok "common.ps1 Assert-ModelSet / Get-ModelSetPick" ;; *) note bad "common.ps1: $out" ;; esac
else echo "skip PowerShell parity (no pwsh)"; fi
[ "$fails" = 0 ] && echo "test_model_sets: all passed" || { echo "test_model_sets: $fails failed"; exit 1; }
