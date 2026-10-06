#!/bin/sh
# The Android branch is in serve.sh. This does not boot a phone.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'com.termux' "$ROOT/scripts/serve.sh"
grep -q 'ANDROID_ROOT' "$ROOT/scripts/serve.sh"
grep -q 'IS_ANDROID' "$ROOT/scripts/serve.sh"
grep -q 'ov_set general.load-mode mmap' "$ROOT/scripts/serve.sh"
grep -q 'RLIMIT_MEMLOCK' "$ROOT/scripts/serve.sh"
grep -q 'termux-wake-lock' "$ROOT/scripts/serve.sh"
grep -q 'TERMUX_WAKE_LOCKED' "$ROOT/scripts/serve.sh"
echo "test_android_gate: OK"
