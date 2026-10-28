# Starter MCP pack

familia already runs **Hermes Agent** (Nous Research), which **hosts** MCP servers. This pack
gives users a short, curated set of MCP options to start from. **Everything is OFF by default**,
version/sha-pinned, live-disableable, and routed through familia's approval gate
(`config/security-gating.json`, #66): the admin is the ultimate authority, any pick can be killed
live via `state/disabled-models.json`, and a failing pick is dropped alone — never the whole swarm.

Reference file: **`config/mcp-servers.starter.json`**. It is a template, not auto-loaded — `serve.sh`
and `serve.ps1` load `config/mcp-servers.json`. To enable a pick, copy its block into
`config/mcp-servers.json` and set `enabled: true`.

## Install rule
All installs are **download-to-named-file**, never piped into a shell. Example:

```sh
curl -fsSLo install-oh-my-hermes.sh https://raw.githubusercontent.com/rlaope/oh-my-hermes/main/install.sh
sh ./install-oh-my-hermes.sh
```

No models are downloaded by this PR (disk is tight).

## The pack

### Utility (safe, phone-friendly)
| pick | what it does | repo | license | pinned |
|---|---|---|---|---|
| `filesystem` | file read/write, project-folder only | https://github.com/modelcontextprotocol/servers | MIT | `@modelcontextprotocol/server-filesystem@2.0.1` |
| `git` | local git ops, no network | https://github.com/modelcontextprotocol/servers | MIT | `mcp-server-git==2026.10.19` |
| `fetch` | fetch a URL as readable text | https://github.com/modelcontextprotocol/servers | MIT | `mcp-server-fetch==2026.10.24` |
| `time` | current time / tz conversion | https://github.com/modelcontextprotocol/servers | MIT | `mcp-server-time==2026.10.19` |
| `memory` | persistent knowledge-graph memory | https://github.com/modelcontextprotocol/servers | MIT | `@modelcontextprotocol/server-memory@2.0.0` |
| `agent-reach` | familia's own reach MCP (already shipped), promoted here | familia `config/mcp-servers.agent-reach.example.json` | see familia | n/a |

**Playwright MCP** (browser automation) is noted as a heavier **later option**, not in the starter set.

### Security / firewall slot (opt-in, gated by #66)
Start **read-only / audit**; applying anything is **admin-gated** and never default. Wired to the
`security-gating.json` kill-switch + tier model (`guard` / `audit` / `risky`).

| pick | role / tier | repo | license | status |
|---|---|---|---|---|
| `laya-guard` | guard (421M jailbreak/tool-call decision guard) | https://github.com/NandhaKishorM/laya | Apache-2.0 | doc-TODO: no pinned MCP transport yet |
| `shannon-pentest` | risky (AI pentester, CI + SARIF 2.1.0) | https://github.com/KeygraphHQ/shannon · action https://github.com/KeygraphHQ/shannon-action | AGPL-3.0 | doc-TODO: CI/Action, not an always-on MCP; staging only |
| `ligolo-ng` | risky (tunneling/pivoting, TUN) | https://github.com/nicocha30/ligolo-ng | GPL-3.0 | doc-TODO: standalone CLI, not MCP; admin-only, preservative use |

> Shannon's `url` must point at **staging/dev only, never production** — it runs real exploits.
> Shannon resolved from x.com/silvanrec/status/2115065149388120531 to **KeygraphHQ/shannon** (the
> `silvanrec` org/repo does not exist / 404).

### Community "add more" browser + value-add bundle (opt-in)
| pick | what it does | repo | license |
|---|---|---|---|
| `oh-my-hermes` | value-add Hermes coding-harness bundle | https://github.com/rlaope/oh-my-hermes | MIT |
| Hermes community registry | browse/install more MCPs & skills | https://github.com/hermesonehq/hermes-registry (site registry.hermesone.org) | not stated upstream |

## Serve wiring (TODO, out of scope for this small PR)
`serve.sh`/`serve.ps1` only read `config/mcp-servers.json` today. Wiring the starter pack through
the approval gate is more than a small change:
- [ ] Loader that merges enabled starter picks into the effective MCP config, honoring `enabled`.
- [ ] Enforce `security-gating.json` tiers/kill-switch for guard/audit/risky picks at serve time.
- [ ] Pinned install scripts (`install-<pick>.sh` / `.ps1`) for the security + community picks.
- [ ] PowerShell parity for all of the above.

## Verified vs TODO links
- **Verified 200:** modelcontextprotocol/servers, KeygraphHQ/shannon, KeygraphHQ/shannon-action,
  nicocha30/ligolo-ng, NandhaKishorM/laya, rlaope/oh-my-hermes, hermesonehq/hermes-registry.
- **404 / unresolved:** `silvanrec` (resolved to KeygraphHQ/shannon instead).

## Add-ons menu (separate from core roles)
A distinct **Add-ons** section, separate from core swarm roles, holds things that don't fit a core
role: extra MCPs, specialist/experimental models, and opt-in tools. **All off by default and
live-disableable.** This is the "add more" surface users browse; core roles are unaffected.

In `config/mcp-servers.starter.json` these live under the top-level `addons` key (reference/template,
not auto-loaded). Categories: `extra_mcps`, `specialist_models`, `tools`, `interfaces`.

### Hermes Desktop (browser-hosted) — on-demand add-on
Browser-hosted Hermes Desktop is the official **`hermes webapp`** mode of
**NousResearch/hermes-agent** (MIT, https://github.com/NousResearch/hermes-agent) — *not* a separate
repo. It serves the real Desktop renderer to a browser via the profile's gateway at
`http://127.0.0.1:9120`:

```sh
hermes config set webapp.enabled true
hermes gateway restart
hermes webapp
```

This is **not** the Web Dashboard (`hermes dashboard`). It's on-demand (off until enabled), loopback,
one-use sign-in link.

- **Verified:** the dedicated repos `NousResearch/hermes-desktop` and `nousresearch/hermes-agent-desktop`
  are **404** — browser-hosted Hermes Desktop is the `hermes webapp` feature inside
  `NousResearch/hermes-agent` (200, confirmed in `website/docs/user-guide/desktop.md`).
- **Alternative community ports** (standalone browser UI over the gateway), both MIT, both verified 200:
  - `przbadu/hermes-ui` (https://github.com/przbadu/hermes-ui) — thin Vite web UI / PWA, ~140★.
  - `icyzh/hermes-web` (https://github.com/icyzh/hermes-web) — Docker + Caddy self-host port.

## Serve-time loading
`serve.sh` / `serve.ps1` build `.cache/mcp-servers.effective.json` from `config/mcp-servers.json`
(base; wins on a name clash) plus every starter pick that has `"enabled": true` in
`config/mcp-servers.starter.json` **or** is named in `MCP_PICKS` (e.g. `MCP_PICKS=time,git`).
Doc-only picks (`command: "TODO"`) and picks with an unset placeholder (`@FAMILIA_ROOT@` needs
`FAMILIA_ROOT`) are skipped with a warning; a broken starter file falls back to the base config.
Loader: `scripts/lib/mcp_load.py`. Override the file with `MCP_STARTER=path` (empty = none).

## Installing an add-on: `scripts/install-addon.sh` / `install-addon.ps1`
```sh
sh scripts/install-addon.sh --fetch oh-my-hermes   # download to a named file + sha256 check; read it
sh scripts/install-addon.sh oh-my-hermes           # ...and run it
```
The pick needs `"_installer": {"url": "https://...", "sha256": "<64 hex>"}`. No pin, a non-https
URL, or a digest mismatch is refused (a mismatch is kept as `install-<pick>.sh.bad`, never run).
Files land in `.cache/installers/` (git-ignored).

## PowerShell parity
- `serve.ps1` builds the effective MCP config with the same `scripts\lib\mcp_load.py` + `mcp_gate.py`
  as `serve.sh` (needs a working Python 3; without one, only the base config is served and
  `MCP_PICKS` is ignored with a warning). Same env: `MCP_PICKS`, `MCP_STARTER`,
  `FAMILIA_GUARD_HEALTHY`, `MCP_ADMIN_OVERRIDE`, `SANDBOX_ALLOWED_SIGNERS`.
- `scripts\install-addon.ps1 [-Fetch] <pick>` mirrors `install-addon.sh`: pinned
  `"_installer_ps1": {"url", "sha256"}`, download to `.cache\installers\install-<pick>.ps1`
  (Get-VerifiedFile: https only, sha256, mismatch kept as `.bad`), then run; never piped into Invoke-Expression.
