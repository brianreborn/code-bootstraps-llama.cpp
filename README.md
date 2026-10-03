# code-bootstraps-llama.cpp

A minimal, reproducible package of a pinned [llama.cpp](https://github.com/ggml-org/llama.cpp) plus a hand-picked set of models and configuration. llama.cpp is included as a git submodule pinned to a specific upstream release, so every checkout builds the same code. The models and settings are small enough to stand up a CPU-only coding agent on a 4-8 GB machine (Linux, Android/Termux, Windows).

## Pinned llama.cpp

| | |
|---|---|
| Tag | `b11374` |
| Commit | `b92761a515ea31e852e7fbc1fad5f874b46f3718` |
| Commit date | 2026-10-03 08:59 UTC |
| Build number | `11374` (passed as `-DLLAMA_BUILD_NUMBER`; the web UI is pinned with `HF_UI_VERSION=b11374`) |

The pin is also recorded in `config/llama-pin.env`, which the build scripts read.

## Getting started

```sh
git clone --recursive https://github.com/brianreborn/code-bootstraps-llama.cpp
cd code-bootstraps-llama.cpp
```

If you already cloned without `--recursive`, run `git submodule update --init --recursive`.

### Build

| Host | Command | Output |
|---|---|---|
| Linux (x86_64, aarch64) | `scripts/build-linux.sh` | `build-linux-<arch>/bin/` |
| Android, Termux (arm64) | `pkg install clang cmake git openssl`, then `scripts/build-termux.sh` | `build-termux-<arch>/bin/` |
| macOS (Apple silicon / Intel) | `scripts/build-macos.sh` (same options as `build-linux.sh`) | `build-macos-<arch>/bin/` |
| Windows (x64, VS 2022 or Build Tools) | `powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1` | `build-windows-x64\bin\Release\` |

Parallelism is bounded: `-j "$(nproc)"` on Linux (override with `JOBS=`), `-j 4` by default on Termux (phones throttle and run out of RAM with more), and the processor count on Windows. Ninja is used when it is installed.

The builds are **portable** by default: `-DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON`. All CPU variants (SSE4.2 up to AVX-512/AMX on x86, armv8.0 up to SME on arm64) are built as `libggml-cpu-*` libraries next to the binaries, and the best one for the running CPU is loaded at startup. That way the same build can be copied to another machine. Use `NATIVE=ON scripts/build-linux.sh` (or `-Native` on Windows) for a build tuned to one machine only.

Notes:
- Termux: upstream turns `LLAMA_SUBPROCESS` off on Android. Router mode (one child process per model), `exec_shell_command` and stdio MCP servers all need it, so `build-termux.sh` sets `-DLLAMA_SUBPROCESS=ON`. This combination is **untested**. If the child processes do not work there, run a single model with `llama-server -m models/coder/*.gguf` instead of the router, or set `TOOLS=""`. Tests and examples are skipped there.
- Windows: Visual Studio is a multi-config generator, so the build type is chosen at build time: `cmake --build build-windows-x64 --config Release`.

#### GPU backends (opt-in)

GPU support uses only stock llama.cpp backends and is off by default, except Metal on macOS:

| Script | Option | Backends | `auto` picks |
|---|---|---|---|
| `build-linux.sh` | `GPU=off\|auto\|vulkan\|cuda\|metal` | Vulkan, CUDA | CUDA if `nvcc` is on `PATH`, else Vulkan if `glslc` and the `vulkan` pkg-config module are found, else CPU only |
| `build-macos.sh` | `GPU=metal` (default) or `GPU=off` | Metal | Metal |
| `build-termux.sh` | `GPU=off\|auto\|vulkan` | Vulkan (Adreno, Mali) after `pkg install vulkan-headers vulkan-loader-android shaderc` | Vulkan if `glslc` and the `vulkan` pkg-config module are found |
| `build-windows.ps1` | `-Gpu off\|auto\|vulkan\|cuda` | Vulkan, CUDA | CUDA if `nvcc` is on `PATH`, else Vulkan if `VULKAN_SDK` is set |

Because the portable builds use `GGML_BACKEND_DL=ON`, the GPU backend is built as one more loadable module (`libggml-vulkan.so`, `ggml-cuda.dll`, ...) next to the CPU variants. At startup llama.cpp loads every module. If the GPU module finds no usable device, or its driver is missing, the CPU backend is used. One package therefore works with or without a GPU.

**The GPU paths are untested on real GPUs.** The box this repo was prepared on has no GPU. Tested there: `GPU=auto` with the Vulkan toolchain installed (Mesa, Vulkan 1.4.309, no `nvcc`) picked Vulkan and built `libggml-vulkan.so` with 0 warnings. At runtime it reported `ggml_vulkan: No devices found` and ran on the CPU (`llama-bench -ngl 99`: LFM2.5-1.2B, 564 t/s pp64, 42.8 t/s tg16). Not tested: CUDA, Metal, Vulkan on a real GPU (desktop, Adreno or Mali), and Windows.

Manual equivalent (Linux):

```sh
HF_UI_VERSION=b11374 cmake -S llama.cpp -B build-linux-x86_64 -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_NUMBER=11374 -DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON
cmake --build build-linux-x86_64 --config Release -j "$(nproc)"
```

### Models

Model weights are **not** stored in git. Each role has its own directory under `models/` (git-ignored), with exactly one `.gguf` in it:

```
models/general/   generic chat model
models/coder/     coding agent model (tool calling)
models/decision/  decision model for POST /v1/systemone
```

`scripts/fetch-models.sh` downloads the 3 default models listed in `config/models-manifest.json` (about 2.3 GB in total) and checks their sha256 hashes:

| Role | Model | File (Hugging Face repo) | Size | sha256 | License | Context |
|---|---|---|---|---|---|---|
| general | LFM2.5-1.2B-Instruct Q4_K_M | `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` ([LiquidAI/LFM2.5-1.2B-Instruct-GGUF](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF)) | 731 MB | `b1b3de11…b19b4f5` | `lfm1.0` (LiquidAI custom, see note) | 128k (preset: 8k per slot) |
| coder | Qwen3.5-2B Q4_K_M | `Qwen3.5-2B-Q4_K_M.gguf` ([unsloth/Qwen3.5-2B-GGUF](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF)) | 1.28 GB | `aaf42c8b…e914699223` | Apache-2.0 | 256k (preset: 16k per slot) |
| decision | Laya Q8_0 | `Laya-Q8_0.gguf` ([ggml-org/Laya-GGUF](https://huggingface.co/ggml-org/Laya-GGUF)) | 449 MB | `c06528c5…ed0bb066d2` | Apache-2.0 | 8k (preset: 4k per prompt) |

The full hashes are in the manifest. **License note:** the LFM2.5 models use LiquidAI's own `lfm1.0` license, not an OSI license. Read it on the model page before you use or redistribute them, especially for commercial use. The Qwen3.5 models and the decision models are Apache-2.0.

Optional entries, fetched only on request:

| Flag | Role | Model | Size | Status |
|---|---|---|---|---|
| `--fallback` | general | LFM2.5-350M Q4_K_M | 229 MB | untested |
| `--fallback` | coder | Qwen3.5-0.8B Q4_K_M | 533 MB | untested, tool-calling reliability not verified |
| `--fallback` | decision | Julia-1 Q8_0 | 168 MB | tested once: 2/3 sanity routes right, probabilities not calibrated (no `decision.temperature.*` keys) |
| `--step-up` | coder | Qwen3.5-4B Q4_K_M | 2.74 GB | tested once, for 8 GB+ devices: 8.6-12 tok/s, 5.8 GB peak RSS at 16k context on x86 (includes the repacked weights, see Hardware use) |

```sh
scripts/fetch-models.sh                        # the 3 defaults
scripts/fetch-models.sh --fallback             # the smaller models
scripts/fetch-models.sh --step-up --role coder # just the 4B coder
```

The router serves one `.gguf` per role directory. When you install another pick for a role, the previous file is moved to `models-inactive/<role>/` (git-ignored). Nothing is deleted. Running the script again with the other pick moves the file back instead of downloading it again. A running server picks up the swap after `GET /models?reload=1`.

### Run

```sh
scripts/serve.sh          # Windows: scripts\serve.ps1
```

This starts `llama-server` in router mode on `127.0.0.1:9931` with:
- `--models-dir models` and `--models-preset config/models-preset.ini`. The models are named `general`, `coder` and `decision` after their directories.
- `--models-max 2`, so at most two models are loaded at once and the least recently used one is unloaded.
- `--api-key-file .secrets/api-keys`, which is generated on the first run and git-ignored.
- the built-in tools (`read_file`, `file_glob_search`, `grep_search`, `exec_shell_command`, `write_file`, `edit_file`, `get_info`), the MCP servers in `config/mcp-servers.json`, and a tools runtime (see below).

Then run the minimal agent against a project directory:

```sh
python3 scripts/agent.py --cwd ./workspace "create hello.py that prints hi, then run it"
```

### Hardware use

`serve.sh` and `serve.ps1` set these flags on the router command line. The router copies them to every model instance. All of them are stock llama.cpp options:

| Flag | Value | Why |
|---|---|---|
| `--threads` | physical cores (Linux: unique package/core pairs in `/sys/devices/system/cpu/*/topology`; macOS: `hw.physicalcpu`; Windows: `Win32_Processor.NumberOfCores`; otherwise the logical count) | Generation is mostly memory-bound, and SMT siblings share one core's execution units. The box used here has no SMT (physical = logical = 8), so this split is not measured. |
| `--threads-batch` | logical CPUs | Prompt processing is compute-bound and can use every hardware thread. |
| `--n-gpu-layers auto` + `--fit on` | | Offloads as many layers as fit on a usable GPU and keeps the rest on the CPU. With no GPU, llama.cpp prints a warning and runs on the CPU. |
| `--load-mode` | `auto` (mmap) | `LOAD_MODE=mlock` or `mmap+mlock` pins the weights in RAM. That fails without a large enough `RLIMIT_MEMLOCK` (common on Termux and for non-root users) and takes RAM away from other apps on 4-8 GB devices, so it is opt-in. It was not benchmarked. |
| repack | on (upstream default), `REPACK=off` adds `--no-repack` | In the table below, repack made no consistent difference for Qwen3.5-2B and was faster for LFM2.5-1.2B at 8 threads (657 vs 507 t/s prompt, 45.9 vs 39.6 t/s generation), so the upstream default stays. The repacked weights are an extra buffer (about 2.6 GB for the 4B coder with AMX), so `REPACK=off` is there for tight devices. Repack on arm64 is untested. |

Override with `THREADS=`, `THREADS_BATCH=`, `GPU_LAYERS=`, `REPACK=` and `LOAD_MODE=` (`-Threads`, `-ThreadsBatch`, `-GpuLayers`, `-Repack`, `-LoadMode` on Windows). If you have several builds, choose one with `LLAMA_SERVER=build-.../bin/llama-server`.

**Concurrency.** `config/models-preset.ini` turns on `cont-batching` and `kv-unified`. Each model gets several slots that share one KV pool, and each slot is capped by `kv-unified-per-slot`:

| Model | parallel | ctx-size (pool) | per slot |
|---|---|---|---|
| coder | 4 | 32768 | 16384 |
| general | 2 | 16384 | 8192 |
| decision | 2 | 8192 | 4096 |

Several agent sessions can therefore use the coder at once, and continuous batching interleaves their tokens. The pool only fills as far as the requests use it.

**Measurements** (x86_64 cloud VM: 8 vCPU Xeon, 1 thread per core, AVX-512 + AMX, 15 GB RAM shared with other work, so expect noise; portable b11374 build; `llama-bench -r 2`, t/s):

| Model | repack | test | t=1 | t=2 | t=4 | t=6 | t=8 |
|---|---|---|---|---|---|---|---|
| Qwen3.5-2B Q4_K_M | off | pp512 | 59.3 | 115.0 | 209.7 | 255.9 | 342.9 ± 43.5 |
| Qwen3.5-2B Q4_K_M | off | tg128 | 4.31 | 8.36 | 15.42 | 21.58 | 21.02 ± 3.69 |
| Qwen3.5-2B Q4_K_M | on | pp512 | 58.7 | 114.3 | 204.2 | 299.5 | 309.5 ± 19.0 |
| Qwen3.5-2B Q4_K_M | on | tg128 | 4.72 | 8.94 | 15.37 | 16.91 | 21.28 ± 2.64 |
| LFM2.5-1.2B Q4_K_M | off | pp512 | 101.0 | 206.6 | 404.9 | 546.7 | 507.3 ± 31.6 |
| LFM2.5-1.2B Q4_K_M | off | tg128 | 7.11 | 13.88 | 27.70 | 38.59 | 39.56 |
| LFM2.5-1.2B Q4_K_M | on | pp512 | 101.5 | 208.6 | 391.9 | 506.1 | 656.6 ± 59.9 |
| LFM2.5-1.2B Q4_K_M | on | tg128 | 8.92 | 17.09 | 29.98 | 39.71 | 45.88 ± 3.75 |

Throughput keeps rising up to all 8 physical cores, which is why `--threads` is the physical core count. Concurrency, from `llama-batched-bench` (Qwen3.5-2B, `-c 16384 -kvu -t 8 -tb 8`, 512 prompt + 128 generated tokens per sequence):

| parallel | prompt t/s | generation t/s (aggregate) | total t/s |
|---|---|---|---|
| 1 | 290 | 18.1 | 72.5 |
| 2 | 336 | 25.0 | 96.2 |
| 4 | 324 | 55.9 | 165.4 |

Through `serve.sh` with the preset above, 4 concurrent coder requests produced 547 tokens in 14.3 s (38 tok/s aggregate, about 11.7 tok/s per stream). A single stream ran at about 17 tok/s. The coder instance peaked at 3.6 GB RSS with 4 slots, the decision instance at 0.92 GB.

### Tool isolation, and the host fallback

`TOOLS_RUNTIME=auto` (the default) checks for a working `podman`, then `docker`. If it finds one, it starts a container from `TOOLS_IMAGE`, mounts `WORKDIR` at `/work`, and passes `--tools-runtime <engine>-container:<id>`. The tools then only see the mounted project.

**If neither podman nor docker works (the usual case on Termux and on many laptops), the tools run on the host** with the permissions of the user running the server. The model can then read, write and run anything that account can. Paths are resolved against `WORKDIR`, but absolute paths are not confined to it. `serve.sh` prints a warning when this happens. To turn the tools off, use `TOOLS=""`. To pick a runtime yourself, set `TOOLS_RUNTIME` to `host`, `podman:<image>`, `docker:<image>`, `podman-container:<id>`, `docker-container:<id>` or `ssh:<target>`.

The router passes its own command-line flags to every model instance it starts. Those instances listen on random 127.0.0.1 ports without the API key. So `serve.sh` gives the tools and MCP config to the router only, through `LLAMA_ARG_*` environment variables, and the `[*]` section of the preset overrides them in the instances (`tools = get_info`, empty MCP config).

## License

MIT, see `LICENSE`. llama.cpp is MIT-licensed by the ggml authors, see `NOTICE`. Each model has its own license, listed in `config/models-manifest.json`.
