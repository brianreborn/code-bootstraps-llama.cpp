#!/bin/sh
# The Linux preset keeps the on-disk role names and publishes the route words.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
f=$ROOT/scripts/serve.sh
grep -q 'alias = chat' "$f"
grep -q 'alias = route' "$f"
grep -q 'alias = translate' "$f"
echo "test_route_alias: OK"
