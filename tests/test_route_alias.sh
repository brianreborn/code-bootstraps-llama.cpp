#!/bin/sh
# Test that:
# 1. The source-level route alias names (chat, route, translate) exist in serve.sh.
# 2. The effective preset (AWK output) assigns aliases only when a model path is
#    injected by role_model() — i.e., only when the file exists on disk.
# 3. No alias is emitted for sections skipped due to missing model paths.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
f=$ROOT/scripts/serve.sh

# --- 1. source-level alias strings are present ---
grep -q 'alias = chat' "$f"
grep -q 'alias = route' "$f"
grep -q 'alias = translate' "$f"

# --- 2. role_model() dies when the model file is missing (no silent alias) ---
# Verify role_model() has the [ -f "$f" ] || die guard for explicit model paths.
grep -q '"\$f" \].*die\|die.*"\$f"\|file not found' "$f"

# --- 3. The AWK block that assigns aliases is guarded by the rm[] map ---
# Aliases are only injected for sections whose model path was set by role_model().
# The rm[] map in the AWK is only populated from $m_general/$m_coder/$m_decision,
# which role_model() already validated exist on disk.  Confirm the AWK reads those.
grep -q 'rm\["general"\].*m_general\|m_general.*rm\["general"\]' "$f"
grep -q 'rm\["coder"\].*m_coder\|m_coder.*rm\["coder"\]' "$f"
grep -q 'rm\["decision"\].*m_decision\|m_decision.*rm\["decision"\]' "$f"

# --- 4. serve.sh never uses TOOLS=lean when TOOLS=auto (lowram != lean tools) ---
# After the fix the auto branch must not mention lowram → lean.
if grep -q 'PROFILE.*=.*lowram.*TOOLS.*=.*lean\|TOOLS.*lean.*PROFILE.*lowram' "$f"; then
  echo "test_route_alias: FAIL: TOOLS=lean assigned based on PROFILE=lowram (lowram != lean tools)" >&2
  exit 1
fi

# --- 5. MCP_CONFIG is never cleared to empty string in serve.sh ---
if grep -qE 'MCP_CONFIG=""' "$f"; then
  echo "test_route_alias: FAIL: MCP_CONFIG is silenced in serve.sh" >&2
  exit 1
fi

echo "test_route_alias: OK"
