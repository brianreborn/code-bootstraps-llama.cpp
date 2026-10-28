# Metrics, telemetry, and the turbo button

## Default: metrics ON
Orchestration metrics are **enabled by default** (`config/metrics.json`). They feed:
- the orchestration displays (razor-sharp, lightning-fast status), and
- **distributed scale-down negotiation** — nodes split work from rolling + initial performance
  figures (t/s, latency, RAM/VRAM, health), updated as models, engines, or microcode change.

Everything is **local-only**; nothing leaves the swarm (`privacy.local_only`, `no_external_upload`).
State lives in `state/metrics.json`.

## Turbo button: one switch for max performance
To squeeze out maximum performance, flip the **turbo button** — it disables *all* metrics
collection (and therefore scale-down negotiation, which depends on metrics):

- `config/metrics.json` → `turbo_button.turbo: true`, **or**
- env `FAMILIA_TURBO=1`, **or**
- `serve.sh --turbo` (TODO flag — see below).

`turbo: true` overrides `enabled`. When turbo is on, displays show "metrics off (turbo)".

## Fields
| key | meaning |
|---|---|
| `enabled` | master on/off (default true) |
| `turbo_button.turbo` | kill-switch for all collection; overrides `enabled` |
| `collect.*` | which signals to sample; `rolling_window_samples` sizes the rolling window |
| `scale_down_negotiation.requires_metrics_enabled` | negotiation needs metrics; off under turbo |
| `privacy.local_only` / `no_external_upload` | telemetry never leaves the swarm |

## Serve wiring
`scripts/lib/metrics.py` is the one gate both launchers use:
- `serve.sh` / `serve.ps1` print `metrics on` or `metrics off (<reason>)` at start.
- **On:** llama-server gets `--metrics` (`LLAMA_ARG_ENDPOINT_METRICS=1`) and a loopback-only
  sampler writes `initial` + a `rolling` window (`collect.rolling_window_samples`) of t/s,
  latency, RAM and health to `state/metrics.json` (git-ignored) every 5 s; it stops with serve.
- **Off (turbo / `enabled:false`):** no `/metrics` endpoint and no sampler process, nothing written.
- Turbo: `serve.sh --turbo`, `serve.ps1 -Turbo`, `FAMILIA_TURBO=1`, or `turbo_button.turbo: true`.
  Passing `--metrics` yourself is refused; the config decides. A broken metrics.json = default (on).
- `python3 scripts/lib/metrics.py status` prints the effective state (exit 0 on, 3 off).
- [ ] Follow-up: feed the rolling figures to the orchestration display + scale-down negotiator.
