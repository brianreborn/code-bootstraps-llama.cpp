# patches/

Applied in file-name order to the pinned llama.cpp source (`config/llama-pin.env`) by
`scripts/apply-patches.sh` / `scripts/apply-patches.ps1`, which every build script runs first.
Each patch is idempotent to apply (an already-applied patch is detected and skipped) and must
apply cleanly to the pinned tag; bump the pin and refresh the patches together.

| patch | what | upstream |
|---|---|---|
| `0001-router-child-auth.patch` | router mode forwards the caller's `Authorization` / `X-Api-Key` on its own `/v1/streams/lookup` and `DELETE /v1/stream` calls to children, which inherit `LLAMA_API_KEY` and used to answer `unauthorized: Invalid API Key` | not yet |
| `0002-log-pid-prefix.patch` | opt-in `LLAMA_LOG_PID=1`: every log line starts with `[pid]`; router children get `LLAMA_LOG_TAG=<model>:<port>` so their lines read `[pid model:port]`. Off when unset; `serve.sh` / `serve.ps1` turn it on | not yet |
