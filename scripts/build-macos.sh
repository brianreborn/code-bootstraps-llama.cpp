#!/bin/sh
# macOS build: Metal on by default. Same options as build-linux.sh (GPU=off for CPU only).
set -eu
exec "$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/build-linux.sh" "$@"
