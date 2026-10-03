#!/usr/bin/env bash
# Maintainer script (not run by users): cross-build the pinned llama.cpp for Android arm64
# (Termux) with the Android NDK on a Linux x86_64 machine, and pack the release asset that
# config/llama-release.json pins for platform android-arm64.
# Why not upstream's android-arm64 asset: it is built with LLAMA_SUBPROCESS=OFF (router mode,
# the server tools and stdio MCP all fail: "subprocess is not enabled on this build") and
# has no RUNPATH (llama-server cannot find its own libraries without LD_LIBRARY_PATH).
# This build uses upstream's release flags (.github/workflows/release.yml, job android-arm64)
# plus:
#   -DLLAMA_SUBPROCESS=ON
#   -DSUBPROCESS_SPAWN_VIA_FORK=1   subprocess.h: fork+chdir+exec instead of
#                                   posix_spawn_file_actions_addchdir_np (bionic API 34+)
#   -Wl,-rpath,$ORIGIN              CMake's Android platform ignores CMAKE_INSTALL_RPATH
#   -ffile-prefix-map               no build-machine paths in the binaries
#
#   ANDROID_NDK=/path/to/android-ndk-r29 scripts/build-android-release.sh
#   scripts/build-android-release.sh     (downloads NDK r29 from Google into .cache/ndk, sha1-checked)
# Pinned inputs: llama.cpp (submodule commit), the web UI archive and the BoringSSL commit
# (config/llama-pin.env), NDK r29 (URL + sha1 below). The same inputs gave bit-identical
# binaries on two machines with cmake 3.31.6 and ninja 1.12.1 (other versions may differ).
# Env: ANDROID_NDK (default: download), REV (asset revision, default 1), JOBS (default nproc),
#      BUILD_DIR (default build-android-release), OUT (default dist/),
#      ALLOW_OTHER_NDK=1 (upstream's NDK is 29.0.14206865), ALLOW_DIRTY=1
# Output: $OUT/llama-<tag>-bin-android-arm64-cbl<REV>.tar.gz (top directory llama-<tag>/,
# with BUILDINFO and LICENSE inside), $OUT/SHA256SUMS, $OUT/BUILDINFO.
set -euo pipefail
umask 022   # file modes in the archive do not depend on the caller's umask
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../config/llama-pin.env
source config/llama-pin.env
# shellcheck source=lib/common.sh
. scripts/lib/common.sh
# shellcheck source=lib/ui-assets.sh
. scripts/lib/ui-assets.sh
die() { echo "build-android-release.sh: $*" >&2; exit 1; }
NDK_URL=https://dl.google.com/android/repository/android-ndk-r29-linux.zip
NDK_SHA1=87e2bb7e9be5d6a1c6cdf5ec40dd4e0c6d07c30b   # Google's repository2-3.xml, ndk;29.0.14206865
NDK_BYTES=783549481

NDK_WANT=29.0.14206865
API=28                     # upstream's ANDROID_PLATFORM; Termux itself supports Android 7 (API 24),
                           # but posix_spawn and the binaries upstream ships need 28 (Android 9)
REV="${REV:-1}"; [[ "$REV" =~ ^[0-9]+$ ]] || die "REV must be a number"
JOBS="${JOBS:-$(nproc)}"
BUILD_DIR="${BUILD_DIR:-build-android-release}"
case "$BUILD_DIR" in /*) BUILD_ABS="$BUILD_DIR" ;; *) BUILD_ABS="$ROOT/$BUILD_DIR" ;; esac
OUT="${OUT:-dist}"
NDK_SRC="ANDROID_NDK as given (its zip not checked here)"
if [[ -z "${ANDROID_NDK:-}" ]]; then
  nd="$ROOT/.cache/ndk"; zip="$nd/android-ndk-r29-linux.zip"; mkdir -p "$nd"
  if [[ ! -f "$nd/android-ndk-r29/source.properties" ]]; then
    command -v unzip >/dev/null 2>&1 || die "missing unzip (to unpack the NDK)"
    if [[ ! -f "$zip" || "$(sha1sum "$zip" | cut -d' ' -f1)" != "$NDK_SHA1" ]]; then
      echo "build-android-release.sh: $NDK_URL (${NDK_BYTES} bytes)" >&2
      curl -fL --proto '=https' --proto-redir '=https' --retry 3 -C - -o "$zip.part" "$NDK_URL"
      [[ "$(sha1sum "$zip.part" | cut -d' ' -f1)" == "$NDK_SHA1" ]] || die "sha1 mismatch for $zip.part (want $NDK_SHA1)"
      mv -f "$zip.part" "$zip"
    fi
    rm -rf "$nd/android-ndk-r29"; unzip -q "$zip" -d "$nd"
  fi
  ANDROID_NDK="$nd/android-ndk-r29"; NDK_SRC="$NDK_URL (sha1 $NDK_SHA1, checked)"
fi
[[ -f "$ANDROID_NDK/build/cmake/android.toolchain.cmake" ]] ||
  die "ANDROID_NDK=$ANDROID_NDK is not an Android NDK (r29 = $NDK_WANT, as upstream uses)"
NDK_REV="$(awk -F' *= *' '$1 == "Pkg.Revision" {print $2}' "$ANDROID_NDK/source.properties")"
if [[ "$NDK_REV" != "$NDK_WANT" && "${ALLOW_OTHER_NDK:-0}" != 1 ]]; then
  die "NDK $NDK_REV, upstream builds with $NDK_WANT (set ALLOW_OTHER_NDK=1 to use it anyway)"; fi
for t in cmake ninja git readelf curl sha256sum sha1sum tar gzip; do
  command -v "$t" >/dev/null 2>&1 || command -v "llvm-$t" >/dev/null 2>&1 || die "missing $t"; done
READELF="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
[[ -x "$READELF" ]] || READELF=readelf

[[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init llama.cpp
actual="$(git -C llama.cpp rev-parse HEAD)"
[[ "$actual" == "$LLAMA_COMMIT" ]] || die "llama.cpp is at $actual, the pin is $LLAMA_TAG ($LLAMA_COMMIT): git submodule update --init"
if [[ -n "$(git -C llama.cpp status --porcelain --untracked-files=no)" && "${ALLOW_DIRTY:-0}" != 1 ]]; then
  die "llama.cpp has local changes (git -C llama.cpp status); a release must build the pinned source as is"; fi
REPO_COMMIT="$(git rev-parse HEAD)"
# the build inputs this script controls: modified or not committed = noted in BUILDINFO
REPO_DIRTY="$(git status --porcelain -- scripts/build-android-release.sh scripts/lib/ui-assets.sh config/llama-pin.env | wc -l)"

export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C llama.cpp log -1 --format=%ct)}"
# web UI: the pinned archive in llama.cpp/tools/ui/dist (removed again on exit); the build's own
# download is off (LLAMA_USE_PREBUILT_UI=OFF), so it cannot fetch another version
STAGE=""
trap 'rm -rf "$ROOT/llama.cpp/tools/ui/dist"; if [[ -n "$STAGE" ]]; then rm -rf "$STAGE"; fi' EXIT
provide_ui_assets "$ROOT" || die "web UI assets"
# the binaries keep upstream's debug info (NDK default -g), minus this machine's paths
PREFIX_MAP="-ffile-prefix-map=$ROOT/llama.cpp=llama.cpp -ffile-prefix-map=$BUILD_ABS=build -ffile-prefix-map=$ANDROID_NDK=ndk"
CFLAGS_EXTRA="-DSUBPROCESS_SPAWN_VIA_FORK=1 $PREFIX_MAP"
# \$ORIGIN: the backslash survives into the ninja command line, where the shell turns it into
# a literal $ORIGIN (without it, RUNPATH becomes garbage)
LDFLAGS_EXTRA='-Wl,-rpath,\$ORIGIN'
cmake_args=(
  -S llama.cpp -B "$BUILD_ABS" -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI=arm64-v8a "-DANDROID_PLATFORM=android-$API"
  # upstream release.yml, job android-arm64 (+ its global CMAKE_ARGS)
  -DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  -DGGML_BACKEND_DL=ON -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON
  -DLLAMA_FATAL_WARNINGS=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_BORINGSSL=ON
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DGGML_RPC=ON
  -DLLAMA_BUILD_NUMBER="$LLAMA_BUILD_NUMBER"
  # ours: pinned inputs
  -DLLAMA_USE_PREBUILT_UI=OFF -DBORINGSSL_VERSION="$BORINGSSL_COMMIT"
  -DLLAMA_SUBPROCESS=ON
  -DCMAKE_C_FLAGS="$CFLAGS_EXTRA" -DCMAKE_CXX_FLAGS="$CFLAGS_EXTRA"
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_EXTRA" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS_EXTRA"
  -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS_EXTRA"
)
rm -rf "$BUILD_ABS"
cmake "${cmake_args[@]}"
bssl="$(git -C "$BUILD_ABS/_deps/boringssl-src" rev-parse HEAD 2>/dev/null || true)"
[[ "$bssl" == "$BORINGSSL_COMMIT" ]] || die "BoringSSL is at '$bssl', the pin is $BORINGSSL_COMMIT"
cmake --build "$BUILD_ABS" --config Release -j "$JOBS" 2>&1 | tee "$BUILD_ABS/build-output.log"
[[ "${PIPESTATUS[0]}" == 0 ]] || die "build failed"
grep -q "UI: using pre-built assets from $ROOT/llama.cpp/tools/ui/dist" "$BUILD_ABS/build-output.log" ||
  die "the build did not embed the pinned web UI (see $BUILD_ABS/build-output.log)"
! grep -q "UI: downloading" "$BUILD_ABS/build-output.log" || die "the build downloaded a web UI by itself"
BIN="$BUILD_ABS/bin"

# --- checks: the reasons this build exists -------------------------------------------
fail=0
for f in "$BIN"/llama-server "$BIN"/*.so; do
  rp="$("$READELF" -d "$f" | sed -n 's/.*(RUNPATH).*\[\(.*\)\]/\1/p')"
  [[ "$rp" == '$ORIGIN' ]] || { echo "check: $f RUNPATH='$rp', want \$ORIGIN" >&2; fail=1; }
done
syms="$("$READELF" --dyn-syms -W "$BIN/libllama-common.so" | awk '$7 == "UND" {sub(/@.*/, "", $8); print $8}')"
for s in fork execvpe chdir waitpid pipe2; do
  grep -qx "$s" <<< "$syms" || { echo "check: libllama-common.so does not import $s (subprocess off?)" >&2; fail=1; }; done
grep -qx posix_spawn_file_actions_addchdir_np <<< "$syms" && { echo "check: libllama-common.so imports posix_spawn_file_actions_addchdir_np (API 34)" >&2; fail=1; }
# .note.android.ident: 4-byte little-endian API level, then the NDK release ("r29")
api="$("$READELF" -n "$BIN/llama-server" | awk '/NT_ANDROID_TYPE_IDENT/ {a=1; next} a && /description data:/ {print $6 $5 $4 $3; exit}')"
[[ "$api" =~ ^[0-9a-f]{8}$ ]] && api=$((16#$api))
[[ "$api" == "$API" ]] || { echo "check: llama-server is for API '${api}', want $API" >&2; fail=1; }
grep -l -e "$ROOT" -e "$ANDROID_NDK" "$BIN/llama-server" "$BIN"/*.so >&2 && { echo "check: build paths ($ROOT, $ANDROID_NDK) left in the files above" >&2; fail=1; }
ls "$BIN"/libggml-cpu-android_armv8.0_1.so >/dev/null || fail=1
[[ "$fail" == 0 ]] || die "checks failed; not packing"
echo "build-android-release.sh: checks OK: RUNPATH \$ORIGIN, libllama-common.so imports fork/execvpe/chdir/waitpid/pipe2" >&2

# --- pack ----------------------------------------------------------------------------
NAME="llama-$LLAMA_TAG-bin-android-arm64-cbl$REV"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
STAGE="$(mktemp -d)"
mkdir "$STAGE/llama-$LLAMA_TAG"
cp -a "$BIN"/. "$STAGE/llama-$LLAMA_TAG"/
cp llama.cpp/LICENSE "$STAGE/llama-$LLAMA_TAG/LICENSE"
{
  echo "asset:            $NAME.tar.gz"
  echo "what:             llama.cpp $LLAMA_TAG (commit $LLAMA_COMMIT) for Android arm64 / Termux, CPU only"
  echo "built by:         code-bootstraps-llama.cpp scripts/build-android-release.sh at $REPO_COMMIT$([[ "$REPO_DIRTY" != 0 ]] && echo ' (script modified)')"
  echo "                  NOT an upstream ggml-org build"
  echo "build host:       $(uname -sm), $(cmake --version | head -1), ninja $(ninja --version)"
  echo "NDK:              $NDK_REV ($(basename "$ANDROID_NDK")), $("$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version | head -1)"
  echo "NDK source:       $NDK_SRC; pinned: $NDK_URL, sha1 $NDK_SHA1"
  echo "target:           arm64-v8a, Android API $api (Android 9+), CPU only (GGML_CPU_ALL_VARIANTS: the best armv8/armv9 variant is loaded at run time)"
  echo "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
  echo "web UI:           $LLAMA_UI_URL (sha256 $LLAMA_UI_SHA256, checked; embedded from llama.cpp/tools/ui/dist)"
  echo "BoringSSL:        $BORINGSSL_COMMIT (tag 0.20260929.0 named by llama.cpp $LLAMA_TAG)"
  echo "reproducible with: the same NDK, cmake 3.31.6 and ninja 1.12.1 gave bit-identical binaries on two machines"
  echo "cmake arguments:"
  printf '  %s\n' "${cmake_args[@]}" | sed "s|$ANDROID_NDK|\$ANDROID_NDK|g; s|$BUILD_ABS|<build>|g; s|$ROOT|<repo>|g"
  echo "checks:           RUNPATH \$ORIGIN on llama-server and every .so; libllama-common.so imports fork, execvpe, chdir, waitpid, pipe2"
  echo "rebuild:          git clone --recurse-submodules https://github.com/brianreborn/code-bootstraps-llama.cpp"
  echo "                  cd code-bootstraps-llama.cpp && git checkout $REPO_COMMIT && git submodule update --init llama.cpp"
  echo "                  ANDROID_NDK=/path/to/android-ndk-r29 REV=$REV scripts/build-android-release.sh"
  echo "files (sha256; this BUILDINFO itself is not listed):"
  (cd "$STAGE/llama-$LLAMA_TAG" && find . -type f ! -name BUILDINFO | LC_ALL=C sort | sed 's|^\./||' | xargs sha256sum | sed 's/^/  /')
} > "$STAGE/llama-$LLAMA_TAG/BUILDINFO"
cp "$STAGE/llama-$LLAMA_TAG/BUILDINFO" "$OUT/BUILDINFO"
# deterministic archive: sorted names, fixed owner and mtime, no gzip timestamp
tar --sort=name --format=gnu --owner=0 --group=0 --numeric-owner --mode='u+rwX,go+rX,go-w' --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$STAGE" -cf - "llama-$LLAMA_TAG" | gzip -9n > "$OUT/$NAME.tar.gz"
(cd "$OUT" && sha256sum "$NAME.tar.gz" BUILDINFO > SHA256SUMS)
echo "build-android-release.sh: $OUT/$NAME.tar.gz ($(stat -c %s "$OUT/$NAME.tar.gz") bytes)" >&2
cat "$OUT/SHA256SUMS"
