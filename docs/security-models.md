# Opt-in security and audit models (#65)

These models are here for **preservative** security of our own swarm: review our own code and any component we add, so things get more secure, never less. They read and analyze only. Nothing in this setup acts on, attacks or exploits anything.

## Picks
All of them are opt-in (`scripts/fetch-models.sh --pick <name>`), sha256- and revision-pinned in `config/models-manifest.json`, and `never_default`.

| pick | role | tier | size | status | license |
|---|---|---|---|---|---|
| `nemotron-guard` | guard | guard | 2.49 GB | tested (#63) | OpenMDW-1.1 + Gemma terms |
| `qwen3guard` | guard | guard | 2.72 GB | partial tested | Apache-2.0 |
| `foundation-sec` | audit | audit | 4.92 GB | partial tested | Foundation-Sec (restrictive flag) |
| `antares` | audit (locator) | audit | 3.68 GB F16 | partial tested, community conversion | Apache-2.0 |
| `whiterabbitneo` | pentest | **risky** | 4.68 GB | partial tested | Apache-2.0 + upstream usage restrictions |

## Rules
1. **The admin is in charge** of all security. Limits (enable, disable, guard override) can be delegated, and every use is logged.
2. **Every model is optional**, including Content-Safety and the other guards, and can be disabled live.
3. **Fail the model, not the swarm.** A broken or compromised model gets marked unhealthy and disabled alone. Everything else keeps serving.
4. **Guards are the recommended path, never a hard dependency.** When a guard is healthy, prompts to audit and risky roles and their outputs are screened. With no guard, normal roles work exactly as before.
5. **Risky roles fail closed only for themselves.** If no guard is healthy, `whiterabbitneo` refuses to start or route. An admin override is possible, and it is logged. Audit roles continue with a warning.
6. **Never default.** No security pick is ever auto-selected. Risky picks show their banner (from the manifest's `banner`) at start-up and in the cockpit.
7. **License flags.** `license_flags` marks restrictive or usage-restricted models, so commercial builds can exclude them.

## Kill switch (design, `config/security-gating.json`)
- State is kept in `state/disabled-models.json`, which is re-read live with no restart.
- Disabling a pick removes it from routing immediately, then stops its process.
- CLI: `scripts/models-ctl.sh disable|enable <pick>`. API: `POST /api/models/<pick>/disable|enable`, loopback/admin only.

## TODO (#65)
- [ ] serve.sh / serve.ps1: read `security-gating.json` and the disabled list, add health checks, and enforce per-model failure isolation.
- [ ] models-ctl.sh/.ps1 plus panel API endpoints.
- [ ] Guard pre/post screening for audit and risky routes; banner in the cockpit.
- [ ] Load-test qwen3guard, foundation-sec, antares and whiterabbitneo on the pinned llama.cpp, then flip `tested`.
- [ ] PowerShell `--pick` parity check for these picks.
