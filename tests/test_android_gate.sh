#!/bin/sh
# The Android branch is in serve.sh. This does not boot a phone.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'com.termux' "$ROOT/scripts/serve.sh"
grep -q 'ANDROID_ROOT' "$ROOT/scripts/serve.sh"
grep -q 'IS_ANDROID' "$ROOT/scripts/serve.sh"
# mmap is the cross-platform default (no mlock). LOAD_MODE can still pin.
grep -q 'ov_set general.load-mode "$LOAD_MODE"' "$ROOT/scripts/serve.sh"
grep -q 'load-mode = mmap' "$ROOT/config/models-preset.ini"
grep -q 'termux-wake-lock' "$ROOT/scripts/serve.sh"
grep -q 'TERMUX_WAKE_LOCKED' "$ROOT/scripts/serve.sh"
echo "test_android_gate: OK"
