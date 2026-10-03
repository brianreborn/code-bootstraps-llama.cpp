# shellcheck shell=bash
# provide_ui_assets ROOT: download the web UI archive pinned in config/llama-pin.env
# (LLAMA_UI_URL, LLAMA_UI_SHA256) into ROOT/.cache/dl, check its sha256 and unpack it into
# llama.cpp/tools/ui/dist (git-ignored there). llama.cpp's build then embeds exactly these
# files ("UI: using pre-built assets") and never downloads, so it cannot fall back to the
# "latest" UI. Needs curl, tar and sha256_of (scripts/lib/common.sh).
provide_ui_assets() {
  local dl="$1/.cache/dl" f dist="$1/llama.cpp/tools/ui/dist" got
  f="$dl/llama-ui-$LLAMA_TAG-dist.tar.gz"
  mkdir -p "$dl"
  if [[ ! -f "$f" || "$(sha256_of "$f")" != "$LLAMA_UI_SHA256" ]]; then
    echo "ui-assets: $LLAMA_UI_URL" >&2
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$f.part" "$LLAMA_UI_URL"
    got="$(sha256_of "$f.part")"
    if [[ "$got" != "$LLAMA_UI_SHA256" ]]; then
      mv -f "$f.part" "$f.bad"; echo "ui-assets: sha256 mismatch for the web UI (got $got, want $LLAMA_UI_SHA256)" >&2; return 1
    fi
    mv -f "$f.part" "$f"
  fi
  rm -rf "$dist"; mkdir -p "$dist"
  tar -xzf "$f" -C "$dist"
  [[ -f "$dist/index.html" ]] || { echo "ui-assets: $f has no index.html" >&2; return 1; }
  echo "ui-assets: web UI $LLAMA_TAG (sha256 $LLAMA_UI_SHA256) -> llama.cpp/tools/ui/dist" >&2
}
