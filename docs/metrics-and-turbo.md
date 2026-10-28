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

## Serve wiring (TODO, out of scope for this small PR)
- [ ] `serve.sh` / `serve.ps1`: read `config/metrics.json`, honor `--turbo` / `FAMILIA_TURBO`,
      sample the `collect.*` signals, and write `state/metrics.json`.
- [ ] Expose rolling figures to the orchestration display + scale-down negotiator.
