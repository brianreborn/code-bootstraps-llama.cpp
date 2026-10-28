# shellcheck shell=sh
# MODEL_SET: which of the two default sets the launchers use (config/model-sets.json).
#   unimpeded (default) = least-restricted variants that pass our checks (LFM3-1.7B-Uncensored)
#   official            = each vendor's own GGUF (or ggml-org's conversion)
# Sourced by serve.sh and fetch-models.sh; needs ROOT and scripts/lib/manifest.awk.
MODEL_SET=${MODEL_SET:-unimpeded}
MODEL_SETS_FILE=${MODEL_SETS_FILE:-$ROOT/config/model-sets.json}
model_set_check() {
  case "$MODEL_SET" in
    official|unimpeded) ;;
    *) echo "${MS_TAG:-model-set}: unknown MODEL_SET / --set '$MODEL_SET' (official|unimpeded)" >&2; exit 2 ;;
  esac
}
# model_set_pick ROLE: "pick<TAB>from-role" of this set's entry for ROLE; nothing for a role the
# set does not name (or names only as pending).
model_set_pick() {
  awk -v match_kv="set=$MODEL_SET role=$1" -v fields="pick from" -f "$ROOT/scripts/lib/manifest.awk" "$MODEL_SETS_FILE" |
    awk -F '\t' -v r="$1" 'NR == 1 { if ($2 == "-") $2 = r; print $1 "\t" $2 }' OFS='\t'
}
