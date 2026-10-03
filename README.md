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
| `build-linux.sh` | `GPU=off\|auto\|vulkan\|cuda\|metal` | Vulkan, CUDA | CUDA if `nvcc` is found (`PATH`, `$CUDA_HOME/bin`, `/usr/local/cuda/bin`), else Vulkan if `glslc` and the `vulkan` pkg-config module are found, else CPU only |
| `build-macos.sh` | `GPU=metal` (default) or `GPU=off` | Metal | Metal |
| `build-termux.sh` | `GPU=off\|auto\|vulkan` | Vulkan (Adreno, Mali, Xclipse) after `pkg install vulkan-headers vulkan-loader-android shaderc` | Vulkan if `glslc` and the `vulkan` pkg-config module are found |
| `build-windows.ps1` | `-Gpu off\|auto\|vulkan\|cuda` | Vulkan, CUDA | CUDA if `nvcc` is found (`PATH`, `CUDA_PATH`, `CUDA_HOME`), else Vulkan if `VULKAN_SDK` is set |

On Linux, Termux and Windows every GPU build uses `GGML_BACKEND_DL=ON`: the portable builds always do, and `NATIVE=ON` (`-Native`) builds turn it on when a GPU backend is selected. The GPU backend is then one more loadable module (`libggml-vulkan.so`, `ggml-cuda.dll`, ...) next to the CPU backend(s). At startup llama.cpp loads every module. If the GPU module finds no usable device, or its driver is missing, the CPU backend is used, so one package works with or without a GPU. On macOS, Metal is linked in (upstream default); macOS has no `GGML_CPU_ALL_VARIANTS`.

The build scripts stop when the `llama.cpp` submodule is not at the pinned commit (`git submodule update --init` fixes that); set `ALLOW_UNPINNED=1` (`-AllowUnpinned` on Windows) to build another commit on purpose. `EXTRA_CMAKE_ARGS` is split on whitespace only (no glob expansion). The Windows script uses the `Visual Studio 17 2022` generator for x64 and stops on the first failing step.

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

`scripts/fetch-models.sh` downloads the 3 default models listed in `config/models-manifest.json` (about 2.3 GB in total). Each file comes from the Hugging Face commit pinned in the manifest (`revision`), over HTTPS only (`curl --proto '=https' --proto-redir '=https'`). Its sha256 is checked on the `.part` file **before** it is moved into place; a mismatching download is kept as `<file>.bad` and the script fails. The script needs only `curl`, `awk` and `sha256sum` (or `shasum`), no Python; `scripts/check-manifests.sh` (developers, needs Python) checks that its small manifest reader sees the same entries as a JSON parser.

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
| `--language` | language (`LANGUAGE_MODE=interpret`, opt-in) | HY-MT1.5-1.8B Q4_K_M, into `models-optional/language/` | 1.13 GB | tested on x86 only; **license not valid in the EU, UK and South Korea; extra terms above 100M MAU** (see Languages) |
| `--language-small` | language (interpret) | Qwen3.5-0.8B Q4_K_M, into `models-optional/language/` | 533 MB | tested on x86 only; weak translation quality |
| `--locale ja` | general in `LANGUAGE_MODE=swap` | Qwen3.5-0.8B-Japanese-SFT-v2 Q4_K_M, into `models-optional/locale/ja/` | 529 MB | tested on x86 only; no tool calls, so not for the coder (see Languages) |

```sh
scripts/fetch-models.sh                        # the 3 defaults
scripts/fetch-models.sh --fallback             # the smaller models
scripts/fetch-models.sh --step-up --role coder # just the 4B coder
scripts/fetch-models.sh --locale ja            # Japanese model for LANGUAGE_MODE=swap
scripts/fetch-models.sh --language             # opt-in interpreter (license: not EU/UK/South Korea)
```

The router serves one `.gguf` per role directory. When you install another pick for a role, the previous file is moved to `models-inactive/<role>/` (git-ignored), only after the new file has passed its sha256 check, so a failed download never leaves a role empty. The language and locale models go to `models-optional/` (git-ignored) and replace nothing in `models/`. Nothing is deleted. Running the script again with the other pick moves the file back instead of downloading it again. A running server picks up the swap after `GET /models?reload=1`.

### Run

```sh
scripts/serve.sh          # Windows: scripts\serve.ps1
```

This starts `llama-server` in router mode on `127.0.0.1:9931` with:
- `--models-dir models` and the preset `.cache/models-preset.effective.ini`, which `serve.sh` writes from `config/models-preset.ini` (profile overlay, language settings). The models are named `general`, `coder` and `decision` after their directories.
- `--models-max 2` (1 in the low-RAM profile), so at most that many models are loaded at once and the least recently used one is unloaded.
- the API key from `.secrets/api-keys` (generated on the first run, git-ignored, directory mode 700, file mode 600), passed as the `LLAMA_API_KEY` environment variable (see Security below).
- the built-in tools (`read_file`, `file_glob_search`, `grep_search`, `exec_shell_command`, `write_file`, `edit_file`, `get_info`), the MCP servers in `config/mcp-servers.json` (skipped with a warning when `python3` is missing, since the example server is a Python script), and a tools runtime (see below).
- the server's working directory set to `WORKDIR` (default `./workspace`), so with the host runtime the tools start there rather than in this repository.

Then run the minimal agent against a project directory:

```sh
python3 scripts/agent.py --cwd ./workspace "create hello.py that prints hi, then run it"
```

### Hardware use

`serve.sh` and `serve.ps1` set these flags on the router command line. The router copies them to every model instance. All of them are stock llama.cpp options:

| Flag | Value | Why |
|---|---|---|
| `--threads` | physical cores (Linux: unique package/core pairs in `/sys/devices/system/cpu/*/topology`; macOS: `hw.physicalcpu`; Windows: `Win32_Processor.NumberOfCores`; otherwise the logical count). On Android and arm64 Linux with big.LITTLE cores: the big cores only (see below) | Generation is mostly memory-bound, and SMT siblings share one core's execution units. The box used here has no SMT (physical = logical = 8), so this split is not measured. |
| `--threads-batch` | logical CPUs (big cores only on big.LITTLE) | Prompt processing is compute-bound and can use every hardware thread. |
| `--n-gpu-layers auto` + `--fit on` | | Offloads as many layers as fit on a usable GPU and keeps the rest on the CPU. With no GPU, llama.cpp prints a warning and runs on the CPU. |
| `--load-mode` | `auto` (mmap) | `LOAD_MODE=mlock` or `mmap+mlock` pins the weights in RAM. That fails without a large enough `RLIMIT_MEMLOCK` (common on Termux and for non-root users) and takes RAM away from other apps on 4-8 GB devices, so it is opt-in. It was not benchmarked. |
| repack | on (upstream default), `REPACK=off` adds `--no-repack` | In the table below, repack made no consistent difference for Qwen3.5-2B and was faster for LFM2.5-1.2B at 8 threads (657 vs 507 t/s prompt, 45.9 vs 39.6 t/s generation), so the upstream default stays. The repacked weights are an extra buffer (about 2.6 GB for the 4B coder with AMX), so `REPACK=off` is there for tight devices. Repack on arm64 is untested. |

Override with `THREADS=`, `THREADS_BATCH=`, `GPU_LAYERS=`, `REPACK=` and `LOAD_MODE=` (`-Threads`, `-ThreadsBatch`, `-GpuLayers`, `-Repack`, `-LoadMode` on Windows). If you have several builds, choose one with `LLAMA_SERVER=build-.../bin/llama-server` (`-LlamaServer` on Windows; the default there is `build-windows-x64\bin\Release\llama-server.exe`).

**big.LITTLE (Android, arm64 Linux).** Every thread of an op waits for the slowest one, so little cores slow the big ones down. `serve.sh` reads `/sys/devices/system/cpu/cpu*/cpu_capacity` (or `cpufreq/cpuinfo_max_freq` when the kernel does not export capacities) and counts the cores that reach at least 75% of the highest value. Homogeneous CPUs keep the physical-core rule. No device names are used.

**Android baseline: Samsung Galaxy A57.** Exynos 1680 (4 nm): 1× Cortex-A720 at 2.9 GHz, 4× Cortex-A720 at 2.6 GHz, 3× Cortex-A520 at 1.95 GHz; Xclipse 550 GPU; 8 or 12 GB LPDDR5X (sources: [GSMArena](https://www.gsmarena.com/samsung_galaxy_a57_5g-14379.php), [Notebookcheck](https://www.notebookcheck.net/Samsung-Exynos-1680-Processor-Benchmarks-and-Specs.1339461.0.html), [Samsung US](https://www.samsung.com/us/smartphones/galaxy-a57-5g/)). With the 75% rule, both frequencies of the A720 cores pass (2.6/2.9 = 90%) and the A520 cores do not (1.95/2.9 = 67%), so the expected result is `--threads 5 --threads-batch 5`. That is derived from the published specs; **nothing was run on an A57**, and the real `cpu_capacity` values may differ. The Xclipse 550 would need the Vulkan build (`GPU=vulkan scripts/build-termux.sh`), which is untested.

**Profiles.** `PROFILE=auto` (default) picks `lowram` on Android/Termux or when RAM is under 6 GB, otherwise `default`. Android is always `lowram` because the OS and apps keep a large share of the A57's 8-12 GB. `lowram` sets `--models-max 1` (one model in memory at a time) and lowers the preset: coder 2 slots sharing a 16k pool, general 1×8k, decision 1×4k, language 1×4k. Override with `PROFILE=default|lowram` and `MODELS_MAX=` (`-RamProfile`, `-ModelsMax` on Windows).

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

Everything scales almost linearly up to 4 threads. From 6 to 8 threads the results are mixed: 8 threads won in most cells, but 6 threads beat 8 in two (Qwen3.5-2B generation without repack, 21.6 vs 21.0 t/s; LFM2.5-1.2B prompt without repack, 547 vs 507 t/s), both by less than the ± spread of the 8-thread runs. Generation for Qwen3.5-2B is level from 6 to 8 threads. With no clear gain from leaving cores idle, `--threads` stays at the physical core count. Concurrency, from `llama-batched-bench` (Qwen3.5-2B, `-c 16384 -kvu -t 8 -tb 8`, 512 prompt + 128 generated tokens per sequence):

| parallel | prompt t/s | generation t/s (aggregate) | total t/s |
|---|---|---|---|
| 1 | 290 | 18.1 | 72.5 |
| 2 | 336 | 25.0 | 96.2 |
| 4 | 324 | 55.9 | 165.4 |

Through `serve.sh` with the preset above, 4 concurrent coder requests produced 547 tokens in 14.3 s (38 tok/s aggregate, about 11.7 tok/s per stream). A single stream ran at about 17 tok/s. The coder instance peaked at 3.6 GB RSS with 4 slots, the decision instance at 0.92 GB.

### Tool isolation, and the host fallback

`TOOLS_RUNTIME=auto` (the default) checks for a working `podman`, then `docker`. If it finds one, it starts a container from `TOOLS_IMAGE`, mounts `WORKDIR` at `/work`, and passes `--tools-runtime <engine>-container:<id>`. The tools then only see the mounted project.

**If neither podman nor docker works (the usual case on Termux and on many laptops), the tools run on the host** with the permissions of the user running the server. The model can then read, write and run anything that account can. Paths are resolved against `WORKDIR`, but absolute paths are not confined to it. `serve.sh` prints a warning when this happens. To turn the tools off, use `TOOLS=""`. To pick a runtime yourself, set `TOOLS_RUNTIME` to `host`, `podman:<image>`, `docker:<image>`, `podman-container:<id>`, `docker-container:<id>` or `ssh:<target>`.

### Languages

The default is **native**: the coder and general models work in the user's language directly, with no extra model and no translation. Nothing changes for English. The swap and interpret modes are opt-in. Tested on x86_64 CPU only (llama.cpp b11374).

**Locale and detection.** `serve.sh` reads `LOCALE` (default `auto`): `getprop persist.sys.locale` on Android/Termux, `defaults read -g AppleLocale` on macOS, otherwise `LC_ALL` / `LC_MESSAGES` / `LANG` (`C` and `POSIX` count as English). `serve.ps1` uses `Get-Culture` (`-Locale` overrides). Only the primary code is used (`ja_JP.UTF-8` → `ja`). `agent.py` detects each prompt's language from its Unicode script and common words, and falls back to the system locale when that gives no clue (Latin letters with a non-Latin-script locale count as English; kanji-only text with a Japanese locale counts as Japanese). An English prompt gets no language handling.

**Modes** (`LANGUAGE_MODE`, `serve.ps1 -LanguageMode`):

| Mode | What happens | Extra download / RAM |
|---|---|---|
| `native` (default) | no model changes; `agent.py` asks the coder to answer in the user's language | none |
| `swap` | the `general` role is replaced by a language-native model from the `[locale.<lang>.general]` section of `config/models-preset.ini` (the coder too with `SWAP_CODER=1`, not recommended, see below) | `fetch-models.sh --locale <lang>`; the model takes the role's place |
| `interpret` | opt-in: an extra `language` model translates each non-English prompt to English for the coder and the answer back | `fetch-models.sh --language`; HY-MT1.5-1.8B, about 2.6 GB more RSS |
| `off` | no language handling; forced for any English locale | none |

> **HY-MT1.5-1.8B license:** the interpreter is under the Tencent HY Community License Agreement. It is **not licensed for use in the European Union, the United Kingdom or South Korea**, and use above **100 million monthly active users** needs additional terms from Tencent. `fetch-models.sh` downloads it only with `--language` (and prints this notice); nothing selects it by default. `--language-small` (Qwen3.5-0.8B, Apache-2.0) is the license-safe but weaker interpreter.

`serve.sh` writes the result into `.cache/models-preset.effective.ini` and `.cache/language.json`, which `agent.py` reads (`--language-mode` overrides it). In interpret mode, code spans and fenced blocks are replaced by placeholders before translation and restored byte for byte, and any paragraph whose placeholders get lost stays in English (marked) instead of risking changed code.

```sh
scripts/serve.sh                                                   # native (default), nothing extra
scripts/fetch-models.sh --locale ja && LOCALE=ja LANGUAGE_MODE=swap scripts/serve.sh
scripts/fetch-models.sh --language  && LOCALE=ja LANGUAGE_MODE=interpret scripts/serve.sh   # license above
python3 scripts/agent.py --localize docs/guide.md --to ja > docs/guide.ja.md   # needs the interpreter
```

To add a locale, add a manifest entry with `"pick": "locale-<lang>"` and `"dir": "models-optional/locale/<lang>"`, and a `[locale.<lang>.general]` section with its `model =` path and sampling.

#### Swap vs interpret for Japanese (measured)

Two agent tasks written in Japanese (create and run `hello.py`; write and test `total(xs)` in `calc.py`), 3 repetitions each per configuration in the main run (6 runs) plus an earlier run of the same harness (6 more), through `serve.sh` and `agent.py --yes`, host tool runtime, 8 threads, x86_64 CPU. "Done" means the file in the work directory gives the expected output afterwards. Peak RSS is the sum over the router and all its model instances.

| Configuration | Coder model | Done | Tool calls | Median time per task | Coder gen tok/s | Peak RSS |
|---|---|---|---|---|---|---|
| `swap`, `SWAP_CODER=1` | Qwen3.5-0.8B-Japanese-SFT-v2 | **0/12** | **0** | 5.7 s (no work done) | 26.5 | 1.7 GB |
| `swap` (general only) | Qwen3.5-2B, prompt in Japanese, "reply in Japanese" | 12/12 | 2-5 per task | 15.1 s | 18.9 | 3.4 GB |
| `interpret` | Qwen3.5-2B, prompt via HY-MT1.5-1.8B | 10/12 | 2-7 per task | 26.8 s | 17.9 | 6.1 GB |
| no language handling (control; `native` adds only the reply instruction, as in the swap row) | Qwen3.5-2B, prompt in Japanese | 12/12 | 2-8 per task | 16.9 s | 18.0 | 3.5 GB |

- **The Japanese model does not handle the coder's tool calls.** Its chat template declares tool support, but in every agent run it answered with a code block instead of calling a tool. A direct probe (2 tools, 5 seeds each) gave 0/10 tool calls for a Japanese request with `tool_choice` `auto` or `required`, and 3/10 for an English request, all malformed (template tags leaked into the arguments). So `SWAP_CODER=1` is not recommended; `serve.sh` warns when it is set.
- **Qwen3.5-2B already works in Japanese.** With the prompt in Japanese it finished every task and answered in Japanese, with or without the "reply in Japanese" instruction, so swapping only the `general` role costs the coder nothing. This is why `native` is the default.
- **Interpret was worse for Japanese**: slower (two translations per task), 2.6 GB more RAM, and less reliable. HY-MT turned 「`hello.py` を作成して」 into "create a translation for `hello.py`" in 3 of 9 inbound translations of that prompt, and the 2 failed runs followed from that. With greedy decoding the output still varied between runs. In an earlier version, which translated the whole answer in one piece, 4 of 6 answers came back in English because placeholders were lost; the paragraph-wise version above lost one paragraph in 6 answers.
- **General role, Japanese** (4 questions, one sample each, judged by hand): neither model is good. LFM2.5-1.2B (current general): 2/4 acceptable (capital with reason, 3 rainy-day ideas), 43 tok/s, 1.6 GB peak. The Japanese model, at its card's sampling (temp 1.0): 1/4 (correct capital, but invented reasons); at temp 0.3: 2/4, again with an invented "fact"; 34-39 tok/s, 1.5 GB peak. Both failed on 猫に小判 and the polite-form rewrite. Qwen3.5-2B (coder, thinking off): 1/4, 14-20 tok/s. At this size there is no clear quality gain from the swap; the gain is fluent Japanese at the same memory.
- One `interpret` run was OOM-killed: the coder ran `grep_search` over the parent of the work directory (27 GB, models included) and the router grew to 9.7 GB. `agent.py` now refuses file-tool paths outside `--cwd` (`--allow-outside` to permit); `exec_shell_command` is still not confined, use the container runtime for that.

#### Interpreter models (translation test)

8 requests (es, zh, hi, ar, ja, pt-BR, de, ru) with `code` spans, plus an English agent reply translated into each, greedy decoding, x86_64 CPU, 8 threads. "Adj chrF" is the chrF of the round trip, counted as 0 when the forward output is in the wrong language (a model that doesn't translate otherwise scores 100). "Code kept" means the backticked span appears byte-exact in the translation.

| Model (Q4_K_M unless noted) | Size | License | Adj chrF to English | Adj chrF from English | Code kept | Gen tok/s |
|---|---|---|---|---|---|---|
| **HY-MT1.5-1.8B** (system prompt) | 1.13 GB | Tencent HY Community: **not valid in the EU, UK and South Korea** | 78.8 | 80.7 | 93/95 | 23 |
| Qwen3.5-2B (current coder) | 1.28 GB | Apache-2.0 | 56.3 (left ja and de untranslated) | 79.3 | 95/95 | 18 |
| LFM2.5-1.2B (current general) | 0.73 GB | lfm1.0 | 59.8 | 70.1 (paraphrases) | 87/95 | 44 |
| Qwen3.5-0.8B (with placeholders) | 0.53 GB | Apache-2.0 | 48.9 | 64.3 | 73/95 | 36 |
| gemma-3-1b-it | 0.81 GB | Gemma | 51.6 | 40.4 | 78/95 | 36 |
| granite-4.0-h-1b | 0.90 GB | Apache-2.0 | 13.4 | 74.1 | 66/95 | 27 |
| tiny-aya-global q4_0 | 2.03 GB | CC-BY-NC-4.0 | 6.3 | 42.6 | 58/95 | 16 |
| Qwen3.5-0.8B-Japanese-SFT-v2 | 0.53 GB | Apache-2.0 | 8.4 | 0.0 | 41/95 | 36 |

HY-MT is the best interpreter we tested, but **its license excludes the EU, the UK and South Korea** (and adds terms above 100M monthly users), so `--language` must not be the default. `--language-small` (Qwen3.5-0.8B, Apache-2.0) is the license-safe fallback, at clearly lower quality. The Japanese SFT model is not a translator: it answered or wrote code instead.

**Language detection.** Asking the decision model (Laya, `/v1/systemone`) to pick the language got 3/20 right (2-6/20 with other option wordings), so it is not used. The built-in heuristic (Unicode script, then function words for Latin scripts) got 20/20 on the same items, but its word lists were written while looking at them; on 16 items written afterwards it got 14/16 (French read as Spanish once; one-word "listo" gave no answer, which falls back to the locale).

**Not tested:** Windows, macOS, Termux/Android, GPU backends, the container tool runtime with these modes, locales other than Japanese for swap, larger Japanese models.

### Security

The router passes its own command-line flags to every model instance it starts, and the instances listen on random 127.0.0.1 ports. `serve.sh` and `serve.ps1` therefore:
- pass the API key as `LLAMA_API_KEY` in the environment instead of `--api-key-file`. The instances inherit it, so they answer 401 to anything without the key (except `/health`). The router forwards the client's `Authorization` header, so requests through the router still work.
- give the tools and MCP config to the router only, through `LLAMA_ARG_*` environment variables, and the `[*]` section of the preset overrides them in the instances (`tools = get_info`, empty MCP config).
- clear every inherited `LLAMA_ARG_*` and `LLAMA_API_KEY` variable (for example `LLAMA_ARG_MCP_SERVERS_JSON`, `LLAMA_ARG_AGENT`, `LLAMA_ARG_UI_MCP_PROXY`) and set only their own.
- refuse extra arguments that would widen what the model can do (`--tools`, `--tools-runtime`, `-ag`/`--agent`, `--mcp-*`, `--ui-mcp-proxy`/`--webui-mcp-proxy`, `--api-key*`, `--models-preset`), because the router overlays extra flags on every preset.
- start `llama-server` in its own process group and forward exactly one signal on Ctrl-C or `kill`, so it shuts down cleanly.

The default tools image is pinned by digest (`python:3.12-slim@sha256:dddfd7e0…`, the multi-arch index as of 2026-10-03); set `TOOLS_IMAGE` to change it.

`scripts/agent.py` asks before running any tool that is not a read-only built-in (`read_file`, `file_glob_search`, `grep_search`, `get_info`), so write tools and all MCP tools need a confirmation unless `--yes`. It refuses to send the API key over plain `http://` to a host that is not loopback. It also refuses file-tool paths (`path`, `file_path`, ...) that resolve outside `--cwd`, unless `--allow-outside`; this keeps the model in the project but is not a sandbox, since `exec_shell_command` can reach anything the account can (use the container runtime).

## License

MIT, see `LICENSE`. llama.cpp is MIT-licensed by the ggml authors, see `NOTICE`. Each model has its own license, listed in `config/models-manifest.json`.
