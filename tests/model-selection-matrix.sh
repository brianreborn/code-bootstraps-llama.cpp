#!/usr/bin/env bash
# Model-selection audit: runs every launcher (start.sh, start.command, Termux, start.ps1/serve.ps1
# under pwsh, serve.sh) with stubs in throw-away sandboxes and asks the real llama-server router
# which model and parameters each role gets (tests/model_selection_matrix.py), re-verifies the
# manifest against the Hugging Face API (check-hf-manifest.py, needs network; skip with NO_HF=1),
# records the role names agent.py requests (agent_routing_check.py) and renders the report.
#   tests/model-selection-matrix.sh [WORKDIR] [--smoke]   -> WORKDIR/results.json, WORKDIR/model-selection-audit.md
# Regression test: exits non-zero when any launcher/profile/locale combination picks a model other
# than the three pinned defaults (or the documented language/swap model), see WORKDIR/assertions.txt.
# PWSH=/path/to/pwsh selects PowerShell 7 when it is not on PATH.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="/tmp/model-selection-matrix"
[[ $# -gt 0 && "$1" != -* ]] && work="$1"
python3 "$here/model_selection_matrix.py" "$@"
if [[ "${NO_HF:-0}" != 1 ]]; then
  python3 "$here/check-hf-manifest.py" > "$work/hf-check.txt" || echo "check-hf-manifest: MISMATCH or API error, see $work/hf-check.txt" >&2
fi
python3 "$here/agent_routing_check.py" > "$work/agent_routing.jsonl"
python3 "$here/model_selection_report.py" "$work" "${REPORT:-$work/model-selection-audit.md}"
