#!/usr/bin/env bash
# Download models into models/<role>/ and verify sha256 (config/models-manifest.json).
#   scripts/fetch-models.sh                    # the 3 approved defaults (general, coder, decision)
#   scripts/fetch-models.sh --fallback         # optional smaller models (weakest devices)
#   scripts/fetch-models.sh --step-up          # optional larger coder (8 GB+ devices)
#   scripts/fetch-models.sh --pick NAME        # any pick name from the manifest
#   scripts/fetch-models.sh --role coder ...   # limit to one role
# The router serves ONE .gguf per models/<role>/ directory, so installing another pick
# for a role moves the previous .gguf to models-inactive/<role>/ (nothing is deleted);
# running the script again with another pick moves it back instead of re-downloading.
# Needs curl, python3 and sha256sum (or shasum).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pick="default"; role=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fallback) pick="fallback" ;;
    --step-up)  pick="step-up" ;;
    --pick)     pick="${2:?--pick needs a name}"; shift ;;
    --role)     role="${2:?--role needs a name}"; shift ;;
    -h|--help)  sed -n '2,11p' "$0"; exit 0 ;;
    *) echo "fetch-models.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

entries="$(python3 - "$pick" "$role" <<'PY'
import json, sys
pick, role = sys.argv[1], sys.argv[2]
m = json.load(open("config/models-manifest.json"))
for c in m["candidates"]:
    if c.get("pick") == pick and (not role or c["role"] == role):
        print("\t".join([c["role"], c["repo"], c["file"], c["sha256"], "yes" if c.get("tested") else "no"]))
PY
)"
[[ -n "$entries" ]] || { echo "fetch-models.sh: no manifest entries for pick='$pick'${role:+ role='$role'}" >&2; exit 1; }

while IFS=$'\t' read -r r repo file sha tested; do
  dir="models/$r"; inactive="models-inactive/$r"
  mkdir -p "$dir"
  [[ "$tested" == "yes" ]] || echo "fetch-models.sh: NOTE: $file is untested with this repo" >&2
  # park any other model of this role so the router sees exactly one .gguf
  while IFS= read -r -d '' other; do
    mkdir -p "$inactive"; echo "fetch-models.sh: parking $other -> $inactive/"
    mv "$other" "$inactive/"
  done < <(find "$dir" -maxdepth 1 -name '*.gguf' ! -name "$file" ! -name '*mmproj*' -print0)
  if [[ -f "$dir/$file" ]]; then
    echo "fetch-models.sh: $dir/$file exists, verifying"
  elif [[ -f "$inactive/$file" ]]; then
    echo "fetch-models.sh: restoring $inactive/$file"; mv "$inactive/$file" "$dir/"
  else
    echo "fetch-models.sh: https://huggingface.co/$repo -> $dir/$file"
    curl -fL --retry 3 -C - -o "$dir/$file.part" "https://huggingface.co/$repo/resolve/main/$file"
    mv "$dir/$file.part" "$dir/$file"
  fi
  got="$(sha256_of "$dir/$file")"
  [[ "$got" == "$sha" ]] || { echo "fetch-models.sh: sha256 mismatch for $dir/$file (got $got)" >&2; exit 1; }
  echo "fetch-models.sh: OK $r = $file"
done <<< "$entries"
echo "fetch-models.sh: done. A running server picks up swaps via GET /models?reload=1 (or restart scripts/serve.sh)."
