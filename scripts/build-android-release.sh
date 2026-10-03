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
# Env: ANDROID_NDK (required), REV (asset revision, default 1), JOBS (default nproc),
#      BUILD_DIR (default build-android-release), OUT (default dist/),
#      ALLOW_OTHER_NDK=1 (upstream's NDK is 29.0.14206865), ALLOW_DIRTY=1
# Output: $OUT/llama-<tag>-bin-android-arm64-cbl<REV>.tar.gz (top directory llama-<tag>/,
# with BUILDINFO and LICENSE inside), $OUT/SHA256SUMS, $OUT/BUILDINFO.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=../config/llama-pin.env
source config/llama-pin.env
die() { echo "build-android-release.sh: $*" >&2; exit 1; }

NDK_WANT=29.0.14206865
API=28                     # upstream's ANDROID_PLATFORM; Termux itself supports Android 7 (API 24),
                           # but posix_spawn and the binaries upstream ships need 28 (Android 9)
REV="${REV:-1}"; [[ "$REV" =~ ^[0-9]+$ ]] || die "REV must be a number"
JOBS="${JOBS:-$(nproc)}"
BUILD_DIR="${BUILD_DIR:-build-android-release}"
OUT="${OUT:-dist}"
[[ -n "${ANDROID_NDK:-}" && -f "${ANDROID_NDK:-}/build/cmake/android.toolchain.cmake" ]] ||
  die "set ANDROID_NDK to an Android NDK (r29 = $NDK_WANT, as upstream uses)"
NDK_REV="$(awk -F' *= *' '$1 == "Pkg.Revision" {print $2}' "$ANDROID_NDK/source.properties")"
if [[ "$NDK_REV" != "$NDK_WANT" && "${ALLOW_OTHER_NDK:-0}" != 1 ]]; then
  die "NDK $NDK_REV, upstream builds with $NDK_WANT (set ALLOW_OTHER_NDK=1 to use it anyway)"; fi
for t in cmake ninja git readelf curl sha256sum; do
  command -v "$t" >/dev/null 2>&1 || command -v "llvm-$t" >/dev/null 2>&1 || die "missing $t"; done
READELF="$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf"
[[ -x "$READELF" ]] || READELF=readelf

[[ -f llama.cpp/CMakeLists.txt ]] || git submodule update --init llama.cpp
actual="$(git -C llama.cpp rev-parse HEAD)"
[[ "$actual" == "$LLAMA_COMMIT" ]] || die "llama.cpp is at $actual, the pin is $LLAMA_TAG ($LLAMA_COMMIT): git submodule update --init"
if [[ -n "$(git -C llama.cpp status --porcelain --untracked-files=no)" && "${ALLOW_DIRTY:-0}" != 1 ]]; then
  die "llama.cpp has local changes (git -C llama.cpp status); a release must build the pinned source as is"; fi
REPO_COMMIT="$(git rev-parse HEAD)"
REPO_DIRTY="$(git status --porcelain -- scripts/build-android-release.sh | wc -l)"   # modified or not committed

export HF_UI_VERSION="$LLAMA_TAG"          # web UI assets for this build (embedded in llama-server)
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(git -C llama.cpp log -1 --format=%ct)}"
# the binaries keep upstream's debug info (NDK default -g), minus this machine's paths
PREFIX_MAP="-ffile-prefix-map=$ROOT/llama.cpp=llama.cpp -ffile-prefix-map=$ROOT/$BUILD_DIR=build -ffile-prefix-map=$ANDROID_NDK=ndk"
CFLAGS_EXTRA="-DSUBPROCESS_SPAWN_VIA_FORK=1 $PREFIX_MAP"
# \$ORIGIN: the backslash survives into the ninja command line, where the shell turns it into
# a literal $ORIGIN (without it, RUNPATH becomes garbage)
LDFLAGS_EXTRA='-Wl,-rpath,\$ORIGIN'
cmake_args=(
  -S llama.cpp -B "$BUILD_DIR" -G Ninja
  -DCMAKE_BUILD_TYPE=Release
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK/build/cmake/android.toolchain.cmake"
  -DANDROID_ABI=arm64-v8a "-DANDROID_PLATFORM=android-$API"
  # upstream release.yml, job android-arm64 (+ its global CMAKE_ARGS)
  -DCMAKE_INSTALL_RPATH='$ORIGIN' -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON
  -DGGML_BACKEND_DL=ON -DGGML_NATIVE=OFF -DGGML_CPU_ALL_VARIANTS=ON
  -DLLAMA_FATAL_WARNINGS=ON -DGGML_OPENMP=OFF -DLLAMA_BUILD_BORINGSSL=ON
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON -DGGML_RPC=ON
  -DLLAMA_BUILD_NUMBER="$LLAMA_BUILD_NUMBER"
  # ours
  -DLLAMA_SUBPROCESS=ON
  -DCMAKE_C_FLAGS="$CFLAGS_EXTRA" -DCMAKE_CXX_FLAGS="$CFLAGS_EXTRA"
  -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS_EXTRA" -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS_EXTRA"
  -DCMAKE_MODULE_LINKER_FLAGS="$LDFLAGS_EXTRA"
)
rm -rf "$BUILD_DIR"
cmake "${cmake_args[@]}"
cmake --build "$BUILD_DIR" --config Release -j "$JOBS"
BIN="$BUILD_DIR/bin"

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
api="$("$READELF" -n "$BIN/llama-server" | awk '/Android/ {a=1} a && /description data/ {print; exit}')"
grep -l -e "$ROOT" -e "$ANDROID_NDK" "$BIN/llama-server" "$BIN"/*.so >&2 && { echo "check: build paths ($ROOT, $ANDROID_NDK) left in the files above" >&2; fail=1; }
ls "$BIN"/libggml-cpu-android_armv8.0_1.so >/dev/null || fail=1
[[ "$fail" == 0 ]] || die "checks failed; not packing"
echo "build-android-release.sh: checks OK: RUNPATH \$ORIGIN, libllama-common.so imports fork/execvpe/chdir/waitpid/pipe2" >&2

# --- pack ----------------------------------------------------------------------------
NAME="llama-$LLAMA_TAG-bin-android-arm64-cbl$REV"
mkdir -p "$OUT"; OUT="$(cd "$OUT" && pwd)"
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/llama-$LLAMA_TAG"
cp -a "$BIN"/. "$STAGE/llama-$LLAMA_TAG"/
cp llama.cpp/LICENSE "$STAGE/llama-$LLAMA_TAG/LICENSE"
ui_tgz="$(find "$BUILD_DIR" -name 'dist.tar.gz' -path '*ui*' 2>/dev/null | head -1)"
{
  echo "asset:            $NAME.tar.gz"
  echo "what:             llama.cpp $LLAMA_TAG (commit $LLAMA_COMMIT) for Android arm64 / Termux, CPU only"
  echo "built by:         code-bootstraps-llama.cpp scripts/build-android-release.sh at $REPO_COMMIT$([[ "$REPO_DIRTY" != 0 ]] && echo ' (script modified)')"
  echo "                  NOT an upstream ggml-org build"
  echo "build host:       $(uname -sm), $(cmake --version | head -1), ninja $(ninja --version)"
  echo "NDK:              $NDK_REV ($(basename "$ANDROID_NDK")), $("$ANDROID_NDK/toolchains/llvm/prebuilt/linux-x86_64/bin/clang" --version | head -1)"
  echo "target:           arm64-v8a, android-$API (ELF note: ${api:-?})"
  echo "SOURCE_DATE_EPOCH: $SOURCE_DATE_EPOCH"
  echo "HF_UI_VERSION:    $HF_UI_VERSION${ui_tgz:+ (UI assets sha256 $(sha256sum "$ui_tgz" | cut -d' ' -f1))}"
  echo "cmake arguments:"
  printf '  %s\n' "${cmake_args[@]}" | sed "s|$ROOT/||g; s|$ANDROID_NDK|\$ANDROID_NDK|g"
  echo "checks:           RUNPATH \$ORIGIN on llama-server and every .so; libllama-common.so imports fork, execvpe, chdir, waitpid, pipe2"
  echo "rebuild:          git clone --recurse-submodules https://github.com/brianreborn/code-bootstraps-llama.cpp"
  echo "                  cd code-bootstraps-llama.cpp && git checkout $REPO_COMMIT && git submodule update --init llama.cpp"
  echo "                  ANDROID_NDK=/path/to/android-ndk-r29 REV=$REV scripts/build-android-release.sh"
  echo "files (sha256):"
  (cd "$STAGE/llama-$LLAMA_TAG" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | xargs sha256sum | sed 's/^/  /')
} > "$STAGE/llama-$LLAMA_TAG/BUILDINFO"
cp "$STAGE/llama-$LLAMA_TAG/BUILDINFO" "$OUT/BUILDINFO"
# deterministic archive: sorted names, fixed owner and mtime, no gzip timestamp
tar --sort=name --owner=0 --group=0 --numeric-owner --mtime="@$SOURCE_DATE_EPOCH" \
    -C "$STAGE" -cf - "llama-$LLAMA_TAG" | gzip -9n > "$OUT/$NAME.tar.gz"
(cd "$OUT" && sha256sum "$NAME.tar.gz" BUILDINFO > SHA256SUMS)
echo "build-android-release.sh: $OUT/$NAME.tar.gz ($(stat -c %s "$OUT/$NAME.tar.gz") bytes)" >&2
cat "$OUT/SHA256SUMS"
