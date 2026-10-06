#!/bin/sh
# The Android branch is in serve.sh. This does not boot a phone.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
grep -q 'com.termux' "$ROOT/scripts/serve.sh"
grep -q 'ANDROID_ROOT' "$ROOT/scripts/serve.sh"
grep -q 'IS_ANDROID' "$ROOT/scripts/serve.sh"
echo "test_android_gate: OK"
