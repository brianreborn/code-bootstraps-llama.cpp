#!/bin/sh
# start.sh is prebuilt-first: existing build > sha-checked release > source build (only when no
# release fits, exit 3) ; BUILD=1 forces the source build. Stubs fetch-llama.sh and build-*.sh.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0; bad() { echo "FAIL: $*" >&2; fail=1; }
mk() {
  rm -rf "$T/r"; mkdir -p "$T/r"; cp -R "$ROOT/start.sh" "$ROOT/scripts" "$ROOT/lib" "$T/r/"
  mkdir -p "$T/r/llama.cpp" "$T/r/.git"; : > "$T/r/llama.cpp/CMakeLists.txt"
  cat > "$T/r/scripts/fetch-llama.sh" <<S
#!/bin/sh
[ "\${STUB_RC:-0}" = 0 ] || exit "\$STUB_RC"
mkdir -p "$T/r/bin/rel"; printf '#!/bin/sh\n' > "$T/r/bin/rel/llama-server"; chmod +x "$T/r/bin/rel/llama-server"; echo "$T/r/bin/rel/llama-server"
S
  for b in build-linux.sh build-macos.sh build-termux.sh; do
    cat > "$T/r/scripts/$b" <<S
#!/bin/sh
d="$T/r/\${BUILD_DIR:-build-$(uname -s | tr A-Z a-z)-x}"; mkdir -p "\$d/bin"; printf '#!/bin/sh\n' > "\$d/bin/llama-server"; chmod +x "\$d/bin/llama-server"; touch "$T/built"
S
  done
  chmod +x "$T/r/scripts/"*.sh; rm -f "$T/built"
}
mkdir -p "$T/fakebin"; printf '#!/bin/sh\nexit 0\n' > "$T/fakebin/cmake"; chmod +x "$T/fakebin/cmake"
run() { (cd "$T/r" && env PATH="$T/fakebin:$PATH" RAISE=0 START_RESOLVE_ONLY=1 "$@" sh start.sh 2>/dev/null); }
mk; out=$(run STUB_RC=0); case "$out" in */bin/rel/llama-server) ;; *) bad "default did not pick the prebuilt ($out)";; esac
[ ! -e "$T/built" ] || bad "default built from source although a prebuilt fits"
mk; out=$(run STUB_RC=3); [ -e "$T/built" ] || bad "no prebuilt (rc 3) did not fall back to source"
case "$out" in */build-*/bin/llama-server) ;; *) bad "fallback path wrong ($out)";; esac
mk; out=$(run BUILD=1 STUB_RC=0); [ -e "$T/built" ] || bad "BUILD=1 did not build"
mk; mkdir -p "$T/r/build-old/bin"; printf '#!/bin/sh\n' > "$T/r/build-old/bin/llama-server"; chmod +x "$T/r/build-old/bin/llama-server"
out=$(run STUB_RC=0); case "$out" in */build-old/bin/llama-server) ;; *) bad "existing build not reused ($out)";; esac
[ ! -e "$T/built" ] || bad "existing build was rebuilt"
mk; if run STUB_RC=1 >/dev/null; then bad "download failure should stop, not build"; fi
[ ! -e "$T/built" ] || bad "download failure triggered a rebuild"
grep -q 'if (-not \$Build -and -not \$server)' "$ROOT/scripts/start.ps1" || bad "start.ps1 is not prebuilt-first"
[ "$fail" = 0 ] && echo "ok: prebuilt-first (default prebuilt, rc3 -> source, BUILD=1, reuse, no rebuild on network error)"
exit $fail
