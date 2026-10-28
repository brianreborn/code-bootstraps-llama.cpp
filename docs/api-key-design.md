# API key design

## Invariants

1. **One key per instance, never rotated.** An instance is a port. Its key lives at
   `${XDG_CONFIG_HOME:-~/.config}/familia/instances/<port>/api-keys`
   (Windows: `%APPDATA%\familia\instances\<port>\api-keys`). `API_KEY_FILE` overrides the path.
2. **Private.** The directory is 0700 and the file 0600 (created under `umask 077`).
3. **Atomic create, first writer wins.** The key is written to a private temp file in the same
   directory and published with `ln` (POSIX) or a no-overwrite `File.Move` (PowerShell). A loser
   of the race deletes its temp file and reads the winner's key. A key file is never rewritten.
4. **Legacy adoption.** An old `.secrets/api-keys` in the checkout is adopted (copied once) so
   existing clients keep working.
5. **One resolver.** `scripts/lib/instance-key.sh` (serve.sh, start.sh), `scripts/serve.ps1` /
   `scripts/lib/open-ui.ps1`, `scripts/lib/snap.py` and familia's `scripts/familia_auth.py`
   all compute the same path: `API_KEY_FILE`, then the instance file, then the legacy file.
6. **Probes are authenticated, and 401 is never "no server".** serve.sh's ready watcher calls
   `/v1/models` with the key after `/health`; on 401/403 it prints an ERROR ("key
   misconfiguration, not a missing server... do not start another one") and writes no ready file.
   familia's `familia_auth.py probe` returns 0 up, 3 down (refused), 4 auth rejected, 5 other;
   only 3 may start a server.

## Multi-instance bootstrap window

Two launchers for the same port can race between "probe says down" and "server listening".
Both resolve the same key file, and invariant 3 makes them agree on one key, so whichever
server wins the port, every client holds the right key. The loser fails to bind and exits;
it never writes a different key. Different ports have different keys and never interfere.

## How every caller forwards the key

| caller | how |
|---|---|
| llama-server router | `LLAMA_API_KEY` env, inherited by every child |
| router -> child (`/v1/streams/lookup`, `DELETE /v1/stream`) | `patches/0001-router-child-auth.patch` adds `Authorization: Bearer` (upstream sent none: children answered 401) |
| serve.sh ready probe | `curl -K -` (key on stdin, not argv) |
| start.sh / open-ui | key read from the instance file, passed to the browser UI |
| familia (`familia_auth.py`, start.sh --bootstrap, find_models.sh, search_x.sh) | same resolver, `Authorization: Bearer` |
| cockpit (`scripts/cockpit.py`) | same resolver; page sends Bearer, SSE uses `?key=` (EventSource cannot set headers), 127.0.0.1 only |
