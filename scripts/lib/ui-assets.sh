# shellcheck shell=sh
# provide_ui_assets ROOT: download the web UI archive pinned in config/llama-pin.env.

provide_ui_assets() {
  ua_dl="$1/.cache/dl"
  ua_dist="$1/llama.cpp/tools/ui/dist"
  ua_f="$ua_dl/llama-ui-$LLAMA_TAG-dist.tar.gz"
  mkdir -p "$ua_dl"
  if [ ! -f "$ua_f" ] || [ "$(sha256_of "$ua_f")" != "$LLAMA_UI_SHA256" ]; then
    echo "ui-assets: $LLAMA_UI_URL" >&2
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 -o "$ua_f.part" "$LLAMA_UI_URL"
    ua_got="$(sha256_of "$ua_f.part")"
    if [ "$ua_got" != "$LLAMA_UI_SHA256" ]; then
      mv -f "$ua_f.part" "$ua_f.bad"
      echo "ui-assets: sha256 mismatch for the web UI (got $ua_got, want $LLAMA_UI_SHA256)" >&2
      return 1
    fi
    mv -f "$ua_f.part" "$ua_f"
  fi
  rm -rf "$ua_dist"
  mkdir -p "$ua_dist"
  tar -xzf "$ua_f" -C "$ua_dist"
  [ -f "$ua_dist/index.html" ] || { echo "ui-assets: $ua_f has no index.html" >&2; return 1; }
  echo "ui-assets: web UI $LLAMA_TAG (sha256 $LLAMA_UI_SHA256) -> llama.cpp/tools/ui/dist" >&2
}
