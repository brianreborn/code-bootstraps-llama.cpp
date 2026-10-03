#!/usr/bin/env bash
# Download models into models/<role>/ and verify sha256 (config/models-manifest.json).
#   scripts/fetch-models.sh                    # the 3 approved defaults (general, coder, decision)
#   scripts/fetch-models.sh --fallback         # optional smaller models (weakest devices)
#   scripts/fetch-models.sh --step-up          # optional larger coder (8 GB+ devices)
#   scripts/fetch-models.sh --language         # opt-in interpreter for LANGUAGE_MODE=interpret (HY-MT1.5-1.8B:
#                                              #   license NOT valid in the EU, UK and South Korea)
#   scripts/fetch-models.sh --language-small   # smallest interpreter (Apache-2.0, weak)
#   scripts/fetch-models.sh --locale ja        # language-native general model for LANGUAGE_MODE=swap
#   scripts/fetch-models.sh --pick NAME        # any pick name from the manifest
#   scripts/fetch-models.sh --role coder ...   # limit to one role
# The interpreter and locale models are never fetched without their flag; the default
# LANGUAGE_MODE=native needs no extra model.
# The router serves ONE .gguf per models/<role>/ directory, so installing another pick
# for a role moves the previous .gguf to models-inactive/<role>/ (nothing is deleted);
# running the script again with another pick moves it back instead of re-downloading.
# Files come from the exact Hugging Face commit pinned in the manifest ("revision"),
# over HTTPS only, and are checked against the manifest sha256 BEFORE they are moved
# into place; a mismatching download is kept as <file>.bad for inspection.
# Entries with a "dir" field go there instead of models/<role> (the language slot
# lives in models-optional/ so the router only sees it when serve.sh registers it).
# Needs only curl, awk and sha256sum (or shasum); no Python.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MANIFEST="${MANIFEST:-config/models-manifest.json}"
pick="default"; role=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --fallback) pick="fallback" ;;
    --step-up)  pick="step-up" ;;
    --language) pick="language" ;;
    --language-small) pick="language-small" ;;
    --locale)   pick="locale-${2:?--locale needs a language code, e.g. ja}"; shift ;;
    --pick)     pick="${2:?--pick needs a name}"; shift ;;
    --role)     role="${2:?--role needs a name}"; shift ;;
    -h|--help)  sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "fetch-models.sh: unknown argument '$1' (see --help)" >&2; exit 2 ;;
  esac
  shift
done

# fingerprint (size + modification time in seconds, scripts/lib/common.sh) skips
# re-hashing an unchanged file on every start
# shellcheck source=lib/common.sh
. "$ROOT/scripts/lib/common.sh"
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

entries="$(awk -v match_kv="pick=$pick${role:+ role=$role}" \
  -v fields="role repo revision file sha256 tested dir notice" -f "$ROOT/scripts/lib/manifest.awk" "$MANIFEST" |
  while IFS=$'\t' read -r r repo rev file sha tested dir notice; do
    [[ "$dir" == "-" ]] && dir="models/$r"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$r" "$repo" "$rev" "$file" "$sha" "$tested" "$dir" "$notice"
  done)"
[[ -n "$entries" ]] || { echo "fetch-models.sh: no manifest entries for pick='$pick'${role:+ role='$role'}" >&2; exit 1; }

while IFS=$'\t' read -r r repo rev file sha tested dir notice; do
  [[ "$notice" == "-" ]] || echo "fetch-models.sh: LICENSE NOTICE: $notice" >&2
  inactive="models-inactive/${dir#*/}"
  mkdir -p "$dir"
  fresh=0
  [[ "$tested" == "yes" ]] || echo "fetch-models.sh: NOTE: $file is untested with this repo" >&2
  if [[ -f "$dir/$file" ]]; then
    echo "fetch-models.sh: $dir/$file exists"
  elif [[ -f "$inactive/$file" ]]; then
    echo "fetch-models.sh: restoring $inactive/$file"; mv "$inactive/$file" "$dir/"
  else
    url="https://huggingface.co/$repo/resolve/$rev/$file"
    echo "fetch-models.sh: $url -> $dir/$file"
    curl -fL --progress-bar --proto '=https' --proto-redir '=https' --retry 3 -C - -o "$dir/$file.part" "$url"
    got="$(sha256_of "$dir/$file.part")"
    if [[ "$got" != "$sha" ]]; then
      mv -f "$dir/$file.part" "$dir/$file.bad"
      echo "fetch-models.sh: sha256 mismatch for $file (got $got, want $sha); kept as $dir/$file.bad" >&2; exit 1
    fi
    mv "$dir/$file.part" "$dir/$file"; fresh=1
  fi
  stamp=".cache/verified/$sha"
  if [[ "$fresh" == 1 ]]; then :
  elif [[ "${FULL_VERIFY:-0}" != 1 && -f "$stamp" && "$(cat "$stamp")" == "$(fingerprint "$dir/$file")" ]]; then
    got="$sha"; echo "fetch-models.sh: $file unchanged since its last sha256 check (FULL_VERIFY=1 re-hashes)"
  else got="$(sha256_of "$dir/$file")"; fi
  if [[ "$got" != "$sha" ]]; then
    mv -f "$dir/$file" "$dir/$file.bad"
    echo "fetch-models.sh: sha256 mismatch for existing $dir/$file (got $got); moved to $dir/$file.bad" >&2; exit 1
  fi
  # only now (new file verified) park any other model of this role, so the router
  # sees exactly one .gguf and a failed download never leaves the role empty
  while IFS= read -r -d '' other; do
    mkdir -p "$inactive"; echo "fetch-models.sh: parking $other -> $inactive/"
    mv "$other" "$inactive/"
  done < <(find "$dir" -maxdepth 1 -name '*.gguf' ! -name "$file" ! -name '*mmproj*' -print0)
  mkdir -p .cache/verified; fingerprint "$dir/$file" > "$stamp"
  echo "fetch-models.sh: OK $r = $file"
done <<< "$entries"
echo "fetch-models.sh: done. A running server picks up swaps via GET /models?reload=1 (or restart scripts/serve.sh)."
