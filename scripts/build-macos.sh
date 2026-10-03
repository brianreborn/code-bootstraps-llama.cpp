#!/usr/bin/env bash
# macOS build: Metal on by default (stock llama.cpp default on Apple). UNTESTED here.
# Same options as build-linux.sh (GPU=off to build CPU only).
set -euo pipefail
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/build-linux.sh" "$@"
