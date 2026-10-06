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
git clone https://github.com/brianreborn/code-bootstraps-llama.cpp
cd code-bootstraps-llama.cpp
```

That is enough for the launchers below, which use release binaries. Without git, use GitHub's **Code > Download ZIP** and unpack it (see "Downloaded ZIP" below). To build llama.cpp yourself you also need the submodule (about 540 MB): clone with `--recursive`, or run `git submodule update --init --recursive` later; `start.sh` does that itself when it has to build.

### Quick start (click-and-go)

| System | Start with |
|---|---|
| Linux, Android (Termux) | `./start.sh` |
| macOS | double-click `start.command` (or `./start.sh`) |
| Windows | double-click `start.bat` |

The launcher downloads the official llama.cpp release binary pinned in `config/llama-release.json` and the 3 default models, checking every file's sha256. On Linux that same command also asks once, through sudo, for the right to lock model memory. On Windows, `start.bat` asks once through the administrator prompt. The server starts either way. The next launch does not ask again. `RAISE=1` asks again, and `RAISE=0` never asks. Sign in again before locking can succeed. Termux and macOS skip this step. If no release binary fits the machine, it builds from source when `cmake` is installed. It then starts `scripts/serve.sh` (`scripts\serve.ps1` on Windows) and opens the built-in web UI at **`http://127.0.0.1:9931/?model=chat`**, with chat selected (the general model; coder is a handoff) (another port if 9931 is taken: the launcher prints the URL it uses). Files the agent creates go to `workspace/`. Stop with Ctrl-C or by closing the terminal window; both stop the server and its model processes (tested on Linux by closing a pty: no `llama-server` was left; untested on macOS and Windows). The browser tab and URL are only opened once `serve.sh` / `serve.ps1` reports that its own server listens on the port and answers (it writes `.cache/serve.ready`, see Security; removed when the server stops, on Windows also when the console window is closed, and every launcher start removes an old one), so a failed start, or another program on the port, never opens the page. Without internet access the launcher says so; run it again later and a partial download resumes.

**API key.** The server only answers with the API key, which `serve.sh` generates on the first start and keeps in **`.secrets/api-keys`** (one key per line; the directory is mode 700 and git-ignored). The launcher prints the key when the server is ready. The first time you open the page, the UI says **"Server Connection Error / Access denied"**: that is expected, nothing is broken. Click the **Enter API Key** button, paste the key and press Enter. The b11374 UI has no way to receive the key through the URL (it reads only `model`, `q` and `load` from it), and a key in a URL would end up in the browser history anyway. The browser keeps it for later visits. `COPY_KEY=1` (`-CopyKey` on Windows) also copies it to the clipboard; that is off by default because clipboard managers keep a history.

The UI's agent uses the server's tools. In the test here it asked before `write_file` and `exec_shell_command` ("Allow once" / "Deny"); whether it asks for every tool, and its "always allow" choices, were not checked.

Prerequisites:

| System | Needs | Notes |
|---|---|---|
| Linux x86_64 / arm64 | `git` (or the ZIP), `/bin/sh`, `curl`, `tar`, `awk`, `sha256sum` (or `shasum` or `cksum`) | The release binary needs glibc 2.34+, `libgomp1`, `libssl3`, zlib and libzstd (Ubuntu 22.04+, Debian 12+); otherwise the launcher builds (needs `git`, `cmake`, a C++ compiler). Linux is the fully supported platform. |
| macOS | `git` (asks to install the Command Line Tools the first time) or the ZIP; `curl`, `tar`, `shasum` are built in | Untested. See "Downloaded ZIP" for Gatekeeper. |
| Windows 10 1803+ / 11 | `git` or the ZIP; PowerShell 5.1 and `curl.exe` are built in | Tested once (Windows 10, PowerShell 5.1, 2-core CPU without AVX, 2026-10-03; the fixes from that run are in, not yet re-tested). See "Downloaded ZIP" for SmartScreen. Group Policy that enforces `AllSigned` blocks the scripts. |
| Android (Termux) | `pkg install git python` (`curl`, `tar`, `awk` are in Termux already) | Ran on a Galaxy A57 (SM-A576U, Android 16, Termux). See "Android (Termux)" below. |
| Any, optional | `python3` (Termux: `pkg install python`; Windows: `python` or `py -3` from python.org) | Only for `scripts/agent.py` and the example MCP server (skipped without it). On Windows `python3` is often only the Microsoft Store placeholder; `serve.ps1` tries `python3`, `python` and `py -3` and uses the first that runs. |
| Disk | about 3 GB free | 2.4 GB of models, 17.6 MB for the Linux CPU release binary (GPU variants are larger), plus room for the `.part` files while downloading. |
| RAM | about 3.5 GB free for `PROFILE=lowram`, 5-6 GB for `default` | Measured on x86_64: lowram peaked at 3.1 GB (router + coder, repack on); in `default` the coder alone reached 3.6 GB with 4 slots, and a second model stays loaded (general 1.6 GB, decision 0.9 GB). |

**Downloaded ZIP.** Browsers mark downloaded files, and both desktop systems then warn about unsigned scripts:
- macOS: double-clicking `start.command` from a downloaded ZIP is blocked by Gatekeeper. Either remove the mark once in Terminal, `xattr -dr com.apple.quarantine ~/Downloads/code-bootstraps-llama.cpp-main` (your folder), or Control-click `start.command` > Open > Open (macOS 14 and older); on macOS 15 and later open System Settings > Privacy & Security and click "Open Anyway" after the first attempt. Running `sh start.sh` in Terminal avoids the prompt. `start.command` runs `start.sh` through `/bin/sh`, so a lost execute bit does not matter.
- Windows: before unpacking, right-click the ZIP > Properties > tick **Unblock** > OK (or `Unblock-File .\code-bootstraps-llama.cpp-main.zip` in PowerShell). Otherwise SmartScreen shows "Windows protected your PC" for `start.bat`: click "More info" > "Run anyway". The launcher runs its `.ps1` files with `-ExecutionPolicy Bypass` and unblocks the llama.cpp files it downloads.
- A `git clone` does not set these marks. The llama.cpp binaries the launchers download with `curl` are not marked either. None of these prompts were tested here.

No Python is needed otherwise. Settings: `PORT`, `VARIANT=auto|cpu|vulkan|cuda-12|cuda-13`, `NO_BROWSER=1`, `BUILD=1`, `COPY_KEY=1`, `RAISE=0|1` (Windows: `-Port`, `-Variant`, `-NoBrowser`, `-Build`, `-CopyKey`; `RAISE` is an environment variable there too), plus everything `serve.sh` reads. On Linux, `VARIANT=auto` fetches `cuda-12` when `nvidia-smi -L` works, otherwise `vulkan` when `/dev/dri/renderD128` exists, otherwise `cpu`. A CPU-only binary with a GPU present prints a warning; `--fit` does not invent a GPU backend. macOS stays on the `cpu` asset (Metal is built into it). Android stays on `cpu`.

One-line install:

```sh
curl -fsSL https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.sh | sh
```

```powershell
irm https://raw.githubusercontent.com/brianreborn/code-bootstraps-llama.cpp/main/install.ps1 | iex
```

The default directory is `~/code-bootstraps-llama.cpp` (`PREFIX` elsewhere; on Termux, `PREFIX` is the Termux usr tree, so the installer uses `INSTALL_PREFIX` or the home default and does not unpack over it). A second run downloads the archive again and unpacks only when its digest changes. `INSTALL_SHA256` or `EXPECTED_SHA256`, when set, refuses a different archive. `INSTALL_NO_START=1` stops before `start.sh`.

`python3 scripts/panel.py` serves a form on `127.0.0.1:9932` and writes `.cache/panel.env`. An environment variable set in the shell still wins, and so does a Windows parameter (`-Port`, `-RamProfile`, ...). `start.sh`, `serve.sh`, `start.ps1`, and `serve.ps1` read that file. The page also shows memory, whether a GPU device is present, and whether the server answers (the port in `.cache/serve.ready` when the launcher moved off 9931). Restart `start.sh` or `start.bat` after saving.

`sh scripts/configure.sh` asks those settings in the terminal (`powershell -ExecutionPolicy Bypass -File scripts\configure.ps1` on Windows): profile, models max, variant, tools, GPU layers, port, threads, context, reasoning, host, load mode, locale, language mode, and the other variables `start.sh` and `serve.sh` already read. Press Enter to keep a default; that key is left out of `.cache/panel.env`. A typed value is written only when it differs from the launcher default, as the same `: "${KEY:=value}"` line the form uses, so a variable already set in the environment still wins. An unknown value is refused and the file is left unchanged. `LANGUAGE_MODE=auto` is a legal answer; `serve.sh` maps it to `native`.

Launcher sentences follow `config/messages/<lang>` when that language is primary (`ja` is shipped; anything else stays English). Paths, model names, flags, hashes, JSON, tool names, and the line `serve.sh: listening on` stay as written. `python3 scripts/agent.py --localize FILE --to ja` translates sentences in that file the same way: code, paths, flags, URLs, and hashes are not rewritten. The banner shows the chosen profile (`lowram`, `moderate` or `default`, picked from the RAM that is free); see "Light tuning" to change it, the context sizes or `MODELS_MAX`. Windows: `start.bat -RamProfile lowram`.

On Linux x86_64, from a fresh clone, the first start took 35-80 s in tests here (17.6 MB binary plus 2.4 GB of models; mostly download time, so it depends on the link) and a restart takes about 2 s. If the download fails (no internet), the launcher says so and stops; it builds from source only when no release binary fits the machine or the binary does not run there. **Untested:** the launchers on macOS, Windows and Termux, the Gatekeeper and SmartScreen prompts, and this repository's Android build on a phone (it was only cross-built and inspected). The Windows scripts were only parsed and partly run with PowerShell 7 on Linux.

Limits of the web UI path:
- It does not use `/v1/systemone` routing, so the decision model is not used, and it lists the decision model even though that model cannot chat.
- It has no interpreter mode (`LANGUAGE_MODE=interpret` is for `scripts/agent.py`). The coder answers in the user's language as far as it can.
- Its agent runs up to 10 tool turns, then asks whether to continue. Unlike `scripts/agent.py` it has no repeat guard (see "Run"). In router mode the UI ignores `--ui-config` defaults (it returns before applying them when `/props` has no generation settings, b11374), so this repo cannot preset a system message for it. You can set one yourself under Settings, for example: "When the task is done, stop calling tools and reply with a one-line summary."
- Closing the browser tab does not stop the server.
- After a page reload the UI cannot resume an answer that is still streaming. An upstream limit (b11374, `tools/server/server-models.cpp` lines 2274-2280): the router forwards the UI's stream lookup (`/v1/streams/lookup`) to the model's child process without the API key, so the child refuses it and logs `unauthorized: Invalid API Key`. That log line is harmless: nothing is sent anywhere else and nothing leaks.

### Android (Termux)

CPU only. On a Galaxy A57 (SM-A576U, Android 16, 7430 MB RAM, 4 KB pages) the `android-b11374-1` binary ran: `llama-cli` on the default general model generated at 28 t/s, and `serve.sh` chose `moderate`, `--threads 5` from the big cores, loaded decision as a child process, and answered `chat` (`Hello! How can I help you today`, 8 tokens, cold). `start.sh` itself, the wake lock, and Vulkan were not run. In Termux (F-Droid or the GitHub termux-app build; NewTermux also works but uses the same public test key as GitHub builds):

```sh
pkg install git python
git clone https://github.com/brianreborn/code-bootstraps-llama.cpp ~/cbl
cd ~/cbl && ./start.sh
```

- **Clone with git, not the ZIP**, and keep the folder in `$HOME` (`/data/data/com.termux/files/home`), not on `/sdcard`: shared storage is mounted noexec (the binaries cannot run there) and slow to read models from. About 3 GB free are needed (4-5 GB more for a source build).
- `start.sh` downloads **this repository's own build** of llama.cpp b11374 for Android arm64 (release [`android-b11374-1`](https://github.com/brianreborn/code-bootstraps-llama.cpp/releases/tag/android-b11374-1), sha256 pinned in `config/llama-release.json`), not upstream's Android asset: upstream builds it with `LLAMA_SUBPROCESS=OFF`, so router mode (one child process per model), every server tool and stdio MCP fail (`subprocess is not enabled on this build`), and its binaries have no RUNPATH, so `llama-server` cannot find its own libraries. Ours uses upstream's release flags plus subprocess support (fork+exec, `SUBPROCESS_SPAWN_VIA_FORK=1`) and `RUNPATH $ORIGIN`; `scripts/build-android-release.sh` rebuilds it, and the `BUILDINFO` file in the archive lists the NDK, flags, source commit and every file's sha256. Its inputs are pinned: the llama.cpp commit, the web UI archive (sha256 in `config/llama-pin.env`, never "latest"), the BoringSSL commit and NDK r29 (download URL and Google's sha1; the script can fetch and check it itself). With cmake 3.31.6 and ninja 1.12.1 two machines produced bit-identical binaries; other cmake/ninja versions may change them. The archive itself is deterministic (sorted, fixed owners, modes and mtime). If that download is not possible, `start.sh` builds on the phone instead (`pkg install git clang cmake ninja`; 30-90 min, `JOBS=2` if clang gets killed).
- `start.sh` takes a Termux wake lock (`termux-wake-lock`, released when the server stops; `WAKE_LOCK=0` skips it) and opens the UI with `termux-open-url`. Android gets the `moderate` profile with 6.9 GB of RAM or more (Galaxy A57: general, coder and decision all loaded), `lowram` below that (note9).
- When Termux is in the background, Android may run it on the slow cores only, or stop it. Keep Termux visible (split screen), or view the UI from a PC through an SSH tunnel: in Termux `pkg install openssh`, set a password with `passwd`, run `sshd` (port 8022), then on the PC `ssh -p 8022 -L 9931:127.0.0.1:9931 <phone-ip>` and open `http://127.0.0.1:9931/?model=chat` there.
- Android 12 and later (for example a Galaxy A57 on Android 16) kill "phantom" child processes, which the router and its model processes are. In Developer options turn on **Disable child process restrictions** and reboot. On Samsung phones also turn **Auto Blocker** off (Settings > Security and privacy) to install a Termux APK from GitHub or use USB debugging, and set Termux's battery use to **Unrestricted**. Android 10 (for example a Galaxy Note 9) has neither restriction.
- GPU: none. Vulkan 1.1 drivers (Android 10 and older, Mali-G72 for example) cannot run llama.cpp's Vulkan backend, which needs 1.2. A Samsung Xclipse GPU (RDNA) is the only Android GPU worth an experiment, with `GPU=vulkan scripts/build-termux.sh` (untested).

### Release binaries (no build)

`scripts/fetch-llama.sh` downloads the official llama.cpp **b11374** release binary for this machine instead of building: Linux x64/arm64 (CPU, Vulkan, CUDA 12/13 on x64), macOS arm64 (Metal) and x64, Windows x64/arm64. For Android arm64 (Termux) it uses this repository's own build of the same commit (see "Android (Termux)"; the asset has its own `base_url` in the manifest). Each archive's sha256 is pinned in `config/llama-release.json` (copied from the digest GitHub reports for the release asset) and checked before unpacking into `bin/llama-b11374-<platform>-<variant>/` (git-ignored). The web UI is embedded in `llama-server`. If the binary cannot run (for example a Linux without glibc 2.34, `libgomp1` or `libssl3`), the script removes it and exits 3: build instead.

```sh
scripts/fetch-llama.sh                    # CPU build for this machine (prints the llama-server path)
scripts/fetch-llama.sh --variant vulkan   # or cuda-12 / cuda-13 where listed
```

`scripts/serve.sh` uses your own build when there is one, else the binary `fetch-llama.sh` verified last; set `LLAMA_SERVER` to choose. Tested on Linux x86_64 only (CPU and Vulkan archives unpack and run `--version`; the CPU one served the full stack).

### Build

| Host | Command | Output |
|---|---|---|
| Linux (x86_64, aarch64) | `scripts/build-linux.sh` | `build-linux-<arch>/bin/` |
| Android, Termux (arm64) | `pkg install git clang cmake ninja` (plus `python` for the agent and the example MCP server), then `scripts/build-termux.sh` (builds `llama-server` only) | `build-termux-<arch>/bin/` |
| Android release asset (maintainers, on Linux x86_64) | `ANDROID_NDK=/path/to/android-ndk-r29 scripts/build-android-release.sh` | `dist/llama-b11374-bin-android-arm64-cbl<REV>.tar.gz`, `SHA256SUMS`, `BUILDINFO` |
| macOS (Apple silicon / Intel) | `scripts/build-macos.sh` (same options as `build-linux.sh`) | `build-macos-<arch>/bin/` |
| Windows (x64, VS 2022 or Build Tools) | `powershell -ExecutionPolicy Bypass -File scripts\build-windows.ps1` | `build-windows-x64\bin\Release\` |

Parallelism is bounded: `-j "$(nproc)"` on Linux (override with `JOBS=`), `-j 4` by default on Termux (phones throttle and run out of RAM with more), and the processor count on Windows. Ninja is used when it is installed.

The builds are **portable** by default: `-DGGML_NATIVE=OFF -DGGML_BACKEND_DL=ON -DGGML_CPU_ALL_VARIANTS=ON`. All CPU variants (SSE4.2 up to AVX-512/AMX on x86, armv8.0 up to SME on arm64) are built as `libggml-cpu-*` libraries next to the binaries, and the best one for the running CPU is loaded at startup. That way the same build can be copied to another machine. Use `NATIVE=ON scripts/build-linux.sh` (or `-Native` on Windows) for a build tuned to one machine only.

Notes:
- Termux: upstream turns `LLAMA_SUBPROCESS` off on Android. Router mode (one child process per model), `exec_shell_command` and stdio MCP servers all need it, so `build-termux.sh` (and `build-android-release.sh`) set `-DLLAMA_SUBPROCESS=ON` with `-DSUBPROCESS_SPAWN_VIA_FORK=1`: the vendored `subprocess.h` otherwise calls `posix_spawn_file_actions_addchdir_np`, which Android's libc only has from API 34 (Android 14), and the build fails. They also link with `-Wl,-rpath,$ORIGIN`, because CMake's Android platform ignores `CMAKE_INSTALL_RPATH` and Android's linker does not look next to the executable. Cross-built with NDK r29 at API 28 here: `libllama-common.so` imports `fork`, `execvpe`, `chdir`, `waitpid` and `pipe2`, and every binary has `RUNPATH [$ORIGIN]`. Whether the child processes work on a phone is **untested**. If they do not, run a single model with `llama-server -m models/coder/*.gguf` instead of the router, or set `TOOLS=""`. Tests and examples are skipped there.
- Windows: Visual Studio is a multi-config generator, so the build type is chosen at build time: `cmake --build build-windows-x64 --config Release`.

#### GPU backends (opt-in)

GPU support uses only stock llama.cpp backends and is off by default, except Metal on macOS:

| Script | Option | Backends | `auto` picks |
|---|---|---|---|
| `build-linux.sh` | `GPU=off\|auto\|vulkan\|cuda\|metal` | Vulkan, CUDA | CUDA if `nvcc` is found (`PATH`, `$CUDA_HOME/bin`, `/usr/local/cuda/bin`), else Vulkan if `glslc` and the `vulkan` pkg-config module are found, else CPU only |
| `build-macos.sh` | `GPU=metal` (default) or `GPU=off` | Metal | Metal |
| `build-termux.sh` | `GPU=off\|auto\|vulkan` | Vulkan after `pkg install vulkan-headers vulkan-loader-android shaderc`; needs a Vulkan 1.2 driver (not Mali-G72 or other Android 10 era GPUs), Samsung Xclipse is the one worth trying (untested) | Vulkan if `glslc` and the `vulkan` pkg-config module are found |
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

Model weights are **not** stored in git. Each role has its own directory under `models/` (git-ignored):

```
models/general/   generic chat model
models/coder/     coding agent model (tool calling)
models/decision/  decision model for POST /v1/systemone
```

`scripts/fetch-models.sh` downloads the 3 default models listed in `config/models-manifest.json` (about 2.3 GB in total). Each file comes from the Hugging Face commit pinned in the manifest (`revision`), over HTTPS only (`curl --proto '=https' --proto-redir '=https'`). Its sha256 is checked on the `.part` file **before** it is moved into place; a mismatching download is kept as `<file>.bad` and the script fails. After a file has been checked once, later runs skip re-hashing it while its size, modification time, change time (ctime) and inode are unchanged (stamp in `.cache/verified/<sha256>`; on Windows size, last-write, creation and change times and the NTFS file index). A file rewritten in place or swapped for another one with the same size and modification time is therefore re-hashed. `FULL_VERIFY=1` (also `$env:FULL_VERIFY=1` on Windows) re-hashes everything, e.g. on a file system whose ctime or inode numbers are not reliable. The script needs only `curl`, `awk` and `sha256sum` (or `shasum`), no Python; `scripts/check-manifests.sh` (developers, needs Python) checks that its small manifest reader sees the same entries as a JSON parser.

| Role | Model | File (Hugging Face repo) | Size | sha256 | License | Context |
|---|---|---|---|---|---|---|
| general | LFM2.5-1.2B-Instruct Q4_K_M | `LFM2.5-1.2B-Instruct-Q4_K_M.gguf` ([LiquidAI/LFM2.5-1.2B-Instruct-GGUF](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct-GGUF)) | 731 MB | `b1b3de11…b19b4f5` | `lfm1.0` (LiquidAI custom, see note) | 128k (preset: 8k per slot) |
| coder | Qwen3.5-2B Q4_K_M | `Qwen3.5-2B-Q4_K_M.gguf` ([unsloth/Qwen3.5-2B-GGUF](https://huggingface.co/unsloth/Qwen3.5-2B-GGUF)) | 1.28 GB | `aaf42c8b…e914699223` | Apache-2.0 | 256k (preset: 16k per slot) |
| decision | Laya Q8_0 | `Laya-Q8_0.gguf` ([ggml-org/Laya-GGUF](https://huggingface.co/ggml-org/Laya-GGUF)) | 449 MB | `c06528c5…ed0bb066d2` | Apache-2.0 | 8k (preset: 4k per prompt) |

The full hashes are in the manifest. **License note:** the LFM2.5 models use LiquidAI's LFM Open License v1.0 (`lfm1.0`), not an OSI license: commercial use is licensed only for organisations below US$10 million annual revenue ([license](https://huggingface.co/LiquidAI/LFM2.5-1.2B-Instruct/blob/main/LICENSE)). `fetch-models` prints this notice when it downloads or restores an LFM file. Read the license before you use or redistribute them. The Qwen3.5 models and the decision models are Apache-2.0.

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
| `--pick agenthorse` | coder | AgentHorse-4B Q4_K_M, `mradermacher/AgentHorse-4B-GGUF` | 2.71 GB | untested. Parks the previous coder file. `lowram` loads this file alone. `moderate` and `default` keep Laya loaded and can load the general model with it. License is not stated on the card. Tool calling was not run. Not the default. |
| `--pick jev` | not a router role | Qwen3-0.6B Q8_0 into `models-optional/jev/` | 639 MB | untested. Small brain named by [Meanblock/JEV-CPU](https://huggingface.co/Meanblock/JEV-CPU) (MIT code, commit `759fa60603a0e312cda38824e63e58f18445c14a`). That repo ships no weights. The 4B brain is too big here, so this is the smaller file. `serve.sh` does not start the JEV scorer and does not replace Laya. |

```sh
scripts/fetch-models.sh                        # the 3 defaults
scripts/fetch-models.sh --fallback             # the smaller models
scripts/fetch-models.sh --step-up --role coder # just the 4B coder
scripts/fetch-models.sh --locale ja            # Japanese model for LANGUAGE_MODE=swap
scripts/fetch-models.sh --language             # opt-in interpreter (license: not EU/UK/South Korea)
scripts/fetch-models.sh --pick agenthorse      # optional untested coder, Q4_K_M; parks the previous coder
scripts/fetch-models.sh --pick jev             # optional Qwen3-0.6B for JEV-CPU; does not replace Laya
scripts/fetch-models.sh --ask                  # ask which one extra to add; empty or unknown downloads nothing
```

`scripts/fetch-models.sh --ask` (Windows: `scripts\fetch-models.ps1 -Ask`) reads one name from stdin. It does not open a terminal. The list is only manifest rows that already have a sha256, except the default general and coder files, so AgentHorse and JEV are offered only because their hashes are already in the manifest. There is no default extra. An empty line, or a name that is not one listed row (`pick/file`, or a pick or file name that matches a single row), downloads nothing. The chosen file uses the same download and sha256 check as the other picks; a mismatch is kept as `*.bad` and is not the live file. Rows with an empty sha256 are not offered and are not fetched. The default general and coder files are not replaced, moved, or downloaded again as a side effect.

**Which file each role serves.** `serve.sh` / `serve.ps1` pin every role to exactly one file in the preset they write (`model = <absolute path>` in `[general]`, `[coder]`, `[decision]`): the first file of that role in `config/models-manifest.json` (manifest order: default, then fallback, then step-up) that is present in `models/<role>/`, checked against its manifest sha256 (re-hashed only when its size, modification time, ctime or inode changed; `FULL_VERIFY=1` always). The router gets no `--models-dir`, so any other `.gguf` in `models/` (an mmproj or mtp file, a stray download, a `.part`) is never listed, loaded or attached; `serve` mentions such files once. To serve a file of your own for a role, set `model = path/to/file.gguf` in that role's section of `config/models-preset.ini` (or a copy named by `MODELS_PRESET`); relative paths are relative to the repository, a manifest file is sha256-checked and any other file gets a warning. The interpreter for `LANGUAGE_MODE=interpret` is chosen the same way (manifest `language` entries in `models-optional/language/`), and the swap model by its `[locale.<lang>.<role>]` section. Models from the Hugging Face cache are kept out too, see Security.

When you install another pick for a role, the previous file is moved to `models-inactive/<role>/` (git-ignored), only after the new file has passed its sha256 check, so a failed download never leaves a role empty. `--ask` is the exception: it leaves the default general and coder files where they are. The language and locale models go to `models-optional/` (git-ignored) and replace nothing in `models/`. Nothing is deleted. Running the script again with the other pick moves the file back instead of downloading it again. Restart the server to serve the newly installed file.

### Run

```sh
scripts/serve.sh          # Windows: scripts\serve.ps1
```

This starts `llama-server` in router mode on `127.0.0.1:9931` with:

`HOST` defaults to `127.0.0.1`. `HOST=0.0.0.0` or `HOST=::` also accepts other machines on this port. A LAN address such as `HOST=192.168.1.20` is bound together with `127.0.0.1`, so the Web UI and agent on this machine keep working. The API key is still plain HTTP. `scripts/agent.py` will not send that key to an `http://` URL that is not loopback.
- the preset `.cache/models-preset.effective.ini`, which `serve.sh` writes from `config/models-preset.ini` (profile overlay, language settings, and each role's pinned model file, see Models). The models are named `general`, `coder` and `decision` after their preset sections.
- `--models-max 3` on the default and moderate profiles (two general/coder slots, plus the decision model) and `--models-max 2` on lowram (general and coder; decision is not pinned). The least recently used model is unloaded when a slot is needed.
- the API key from `.secrets/api-keys` (generated on the first run, git-ignored, directory mode 700, file mode 600), passed as the `LLAMA_API_KEY` environment variable (see Security below).
- the built-in tools (`read_file`, `file_glob_search`, `grep_search`, `exec_shell_command`, `write_file`, `edit_file`, `get_info`), the MCP servers in `config/mcp-servers.json` (skipped with a note when Python 3 is missing, since the example server is a Python script), and a tools runtime (see below). `TOOLS=lean` keeps only `read_file`, `write_file`, `edit_file` and `exec_shell_command` and turns the example MCP server off; the `lowram` profile does this by default. See "Prompt size" below for why. `TOOLS=full`, a comma-separated list, or `TOOLS=""` (no built-in tools) are the other choices.
- the tools directory set to `WORKDIR` (default `./workspace`). With a container, only that directory is mounted, at `/work`, and the server starts with its cwd at `/` so the container can see `/work`. With the host runtime the server starts in `WORKDIR`.

Extra arguments to `serve.sh` (and `start.sh`) go to `llama-server`, and the router copies them into **every** role, e.g. `--ctx-size 8192` sets 8k for general, coder and decision alike (so per-role sizes belong in the preset). Flags that would pick or download a model or point at model files are refused, see Security. On Windows the same goes for `start.bat` / `serve.ps1`; their own settings are `-Name value` parameters, and `--name` spellings of those (`--tools`, `--port`, ...) are refused because PowerShell would bind them to the script's parameter. `serve.ps1` also reads the same environment variables as `serve.sh` (`PORT`, `PROFILE`, `MODELS_MAX`, `TOOLS`, `LOCALE`, `LANGUAGE_MODE`, ...); a parameter on the command line wins.

**Profile.** `PROFILE=auto` (the default) picks the most conservative profile that fits, see "Light tuning" below. On a slow CPU (2 cores or fewer, or x86 without AVX2: such a CPU reads prompts at 1-3 tokens/s, so a full-tools first answer takes many minutes; about 18 min on a 2-core Athlon II in the Windows test) it picks `lowram` and prints a note; another `PROFILE` keeps those settings and warns.

Then run the minimal agent against a project directory:

```sh
python3 scripts/agent.py --cwd ./workspace "create hello.py that prints hi, then run it"   # Windows: python (or py -3) instead of python3
```

`--tools lean` (or a list) offers the model fewer of the server's tools, which shortens every prompt. **Repeat guard:** Qwen3.5-2B sometimes calls the same tool with the same arguments again and again after the task is done (seen on a laptop as `python3 hello.py` repeated until the step limit, and reproduced here in 1 of 25 runs). `agent.py` runs an identical call (same tool, same arguments) only once until a file changes: `write_file`, `edit_file` and MCP tools start a new round, so run, edit, run, edit, run works; shell commands do not, because repeating a command is the loop seen in practice. A skipped call gets a short note instead ("no file was written or edited since; look at its earlier result"). If the model repeats again, its next step gets `tool_choice: none` and a request for a one-line summary. The last allowed step (`--max-steps`, default 12) always works that way, so a stuck run still prints a summary. That summary exits 1. `/remote on` then sends one terse brief to the attached login. `tool_choice: none` keeps the tool definitions in the prompt, so the cached prompt prefix is still used. Measured here on the hello task (`--max-steps 8`): without the guard, 1 of 25 runs repeated `python3 hello.py` until the limit, and sampling changes (Qwen's non-thinking settings with `presence_penalty` 2.0, or `presence_penalty` 1.5 alone) made no clear difference over 5 runs each, so the preset keeps its values. With the guard, all 22 runs ended with a summary after 3-5 tool calls, except one that kept repeating and was ended by the forced last step (that run was before the forced answer after a second repeat was added; a mock server test covers that path). 13 of the 22 runs had one repeat skipped. With the current per-round rule and the forced answer after a second repeat, 12 more runs (6 with the full tool list, 6 with `--tools lean`, 3 threads) all ended with a summary after 3-5 tool calls in 24-58 s; 7 had one repeat skipped and 1 had two. Calls to a tool that was not offered (`--tools`) are refused, and a tool runs without asking only when the server lists it as a built-in (`type: server`) without the write permission; `python3 tests/test_agent.py` checks this and the guard against a fake server.

`python3 scripts/agent.py "/remote"` prints the attached login. A login is an `https://` URL plus a model name, or a local client: `grok`, `agy`, `claude`, `codex`, or `exec <bin>`. The first local call starts a session (`grok` and `claude` take `--session-id`; `agy -p` and `codex exec` start without one). A later call resumes it (`--resume`, `agy --conversation`, `codex exec resume`). Image, audio, video, and pdf files go across as paths. An HTTP brief is at most 1600 characters and the reply is capped at 384 tokens. Auto handoff stays off until `/remote on`.

### Light tuning

The banner prints the profile it chose and why. Change it, or one of a few settings, with environment variables. They work the same in `start.sh`, `serve.sh`, `start.bat` and `serve.ps1`: on Windows run `set NAME=value` in the same window first, or use `start.bat -RamProfile moderate -ModelsMax 2`.

| Setting | Values (default) | What it does | Example |
|---|---|---|---|
| `PROFILE` | `auto` \| `lowram` \| `moderate` \| `default` | auto: `lowram` under 6.9 GB of RAM, on a slow CPU, or with under 2 GB free; `moderate` on Android or with under 6.5 GB free; else `default` | `PROFILE=moderate ./start.sh` |
| `MODELS_MAX` | 1-8 (default 2 on every profile) | how many of general/coder stay loaded; the decision model stays loaded on top (not in lowram) | `MODELS_MAX=2 ./start.sh` |
| `CTX` | tokens (profile) | context pool of the coder and the general model | `CTX=8192 ./start.sh` |
| `CODER_CTX`, `GENERAL_CTX` | tokens (profile) | the same for one role (wins over `CTX`); one session may use the whole pool | `CODER_CTX=32768 ./start.sh` |
| `PARALLEL` | 1-16 (lowram/moderate 2, default 4) | coder sessions at once, sharing the coder's pool | `PARALLEL=1 ./start.sh` |
| `THREADS` | number (auto: big/physical cores) | generation threads | `THREADS=4 ./start.sh` |
| `TOOLS` | `auto` \| `full` \| `lean` \| list \| `""` | tools offered to the model; lean = 4 tools, half the prompt (auto: lean in lowram) | `TOOLS=lean ./start.sh` |

`REASONING` is off when empty or `off`: the preset is unchanged, and `scripts/agent.py` does not send `chat_template_kwargs.enable_thinking`. `REASONING=on` or `auto` overlays `general` and `coder` only in the effective preset written at serve start, so the router picks it up on the next start. `on` also sets `enable_thinking` on that one agent request, with no restart. Language and decision stay off. Thinking tokens are printed on stderr as they arrive, prefixed `[think]`.

Less RAM: `PROFILE=lowram` or `MODELS_MAX=1`. Out-of-memory or the phone kills Termux: go one profile down. Long files: `CODER_CTX=32768` (more RAM). Model choice and role pinning are not tunable here (see Models and Security).

### Hardware use

`serve.sh` and `serve.ps1` set these flags on the router command line. The router copies them to every model instance. All of them are stock llama.cpp options:

| Flag | Value | Why |
|---|---|---|
| `--threads` | physical cores (Linux: unique package/core pairs in `/sys/devices/system/cpu/*/topology`; macOS: performance cores, `hw.perflevel0.physicalcpu`, else `hw.physicalcpu`; Windows: `Win32_Processor.NumberOfCores`; otherwise the logical count). On Android and arm64 Linux with big.LITTLE cores: the big cores only (see below) | Generation is mostly memory-bound, and SMT siblings share one core's execution units. The box used here has no SMT (physical = logical = 8), so this split is not measured. |
| `--threads-batch` | logical CPUs (big cores only on big.LITTLE) | Prompt processing is compute-bound and can use every hardware thread. |
| `--n-gpu-layers auto` + `--fit on` | | Offloads as many layers as fit on a usable GPU and keeps the rest on the CPU. With no GPU, llama.cpp prints a warning and runs on the CPU. |
| `--load-mode` | `auto` (mmap) | `LOAD_MODE=mlock` or `mmap+mlock` pins the weights in RAM. That fails without a large enough `RLIMIT_MEMLOCK` (common on Termux and for non-root users) and takes RAM away from other apps on 4-8 GB devices, so it is opt-in. It was not benchmarked. |
| repack | on (upstream default), `REPACK=off` adds `--no-repack` | In the table below, repack made no consistent difference for Qwen3.5-2B and was faster for LFM2.5-1.2B at 8 threads (657 vs 507 t/s prompt, 45.9 vs 39.6 t/s generation), so the upstream default stays. The repacked weights are an extra buffer (about 2.6 GB for the 4B coder with AMX), so `REPACK=off` is there for tight devices. Repack on arm64 is untested. |

Override with `THREADS=`, `THREADS_BATCH=`, `GPU_LAYERS=`, `REPACK=` and `LOAD_MODE=` (`-Threads`, `-ThreadsBatch`, `-GpuLayers`, `-Repack`, `-LoadMode` on Windows). If you have several builds, choose one with `LLAMA_SERVER=build-.../bin/llama-server` (`-LlamaServer` on Windows; the default there is `build-windows-x64\bin\Release\llama-server.exe`).

**big.LITTLE (Android, arm64 Linux).** Every thread of an op waits for the slowest one, so little cores slow the big ones down. `serve.sh` reads `/sys/devices/system/cpu/cpu*/cpu_capacity` (or `cpufreq/cpuinfo_max_freq` when the kernel does not export capacities) and counts the cores that reach at least 75% of the highest value. If fewer than 2 cores pass (a single prime core on a 3-cluster SoC such as 1+3+4), every core outside the slowest cluster is used; if that is still 1, all physical cores are. Homogeneous CPUs keep the physical-core rule. On macOS, `--threads` counts only the performance cores (`sysctl hw.perflevel0.physicalcpu`, untested), and `fetch-llama.sh` picks the arm64 build on Apple silicon even in a Terminal running under Rosetta. `sh tests/test_cpu.sh` covers the A57 (1+4+3), a 1+3+4 and a 4+4 layout with synthetic sysfs data. No device names are used.

**Android baseline: Samsung Galaxy A57.** Exynos 1680 (4 nm): 1× Cortex-A720 at 2.9 GHz, 4× Cortex-A720 at 2.6 GHz, 3× Cortex-A520 at 1.95 GHz; Xclipse 550 GPU; 8 or 12 GB LPDDR5X (sources: [GSMArena](https://www.gsmarena.com/samsung_galaxy_a57_5g-14379.php), [Notebookcheck](https://www.notebookcheck.net/Samsung-Exynos-1680-Processor-Benchmarks-and-Specs.1339461.0.html), [Samsung US](https://www.samsung.com/us/smartphones/galaxy-a57-5g/)). With the 75% rule, both frequencies of the A720 cores pass (2.6/2.9 = 90%) and the A520 cores do not (1.95/2.9 = 67%), so the expected result is `--threads 5 --threads-batch 5`. On SM-A576U the kernel reported `cpu_capacity` 358, 358, 358, 914, 914, 914, 914, 1024 and `serve.sh` used `--threads 5 --threads-batch 5`. The Xclipse 550 would need the Vulkan build (`GPU=vulkan scripts/build-termux.sh`), which is untested.

**Profiles.** `lowram` sets `--models-max 2` so general and coder can both stay loaded, and lowers the preset: coder 2 slots sharing a 16k pool, general 1×8k, decision 1×4k, language 1×4k. Decision is not pinned on lowram. `moderate` keeps general and coder loaded together (`MODELS_MAX=2`) with coder 2 slots sharing a 24k pool (16k per session), general 1×8k, decision 1×4k. `default` uses the preset as written (coder 4×16k in a 32k pool, general 2×8k). In `moderate` and `default` the decision model (Laya, ~0.9 GB) is loaded at startup and stays loaded: `--models-max` is `MODELS_MAX` + 1, so only general and coder take turns (b11374 has no per-model pin, so with more roles than slots the least recently used one, possibly decision, is unloaded and reloads on its next request).

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

### Prompt size on slow CPUs

Every tool definition is part of every prompt. With the Qwen3.5 chat template (counted with `/apply-template` and `/tokenize`):

| Tools offered | Tool section of the prompt (tokens) |
|---|---|
| 7 built-ins + 2 example MCP tools (default) | 1732 |
| 7 built-ins, MCP off | 1608 |
| `lean`: `read_file`, `write_file`, `edit_file`, `exec_shell_command` | 843 |
| `write_file`, `exec_shell_command` | 444 |

The template's fixed tool instructions take about 220 tokens. The largest definitions are `file_glob_search` (about 340 tokens) and `grep_search` (about 330); `get_info` and each example MCP tool take 30-50. Within one conversation, llama-server reuses the cached prefix, so only new tokens are processed. A new conversation with the same system prompt reuses the tool section too (18 new tokens in a test here). With a different system prompt, prompt processing restarts from the last context checkpoint, about 510 tokens before the end of the shared prefix (Qwen3.5 is a hybrid model, so its cache can only roll back to checkpoints). The first request after a start pays for the whole prompt. On an i5-7200U laptop throttled to 400 MHz, that first step took 615 s with the default tools. `TOOLS=lean` roughly halves it (estimate from the token counts; not measured on that laptop). The tool descriptions are built into llama-server and cannot be shortened by configuration.

### Tool isolation, and the host fallback

General and coder are loaded with `load-mode = mmap+mlock`, so their weights stay in RAM. Decision and the interpreter stay plain `mmap`, so they can be paged. If the lock is refused, llama-server warns and still loads the model. `scripts/agent.py`, `scripts/panel.py`, and the example MCP server lock their own process the same way and warn if the account is not allowed to. `start.sh` and `start.bat` run `scripts/raise.sh` or `scripts/raise.ps1` once and, after it succeeds, record `.cache/raise.stamp` so the next launch does not ask while this login still has the old limit. `RAISE=1` runs it again. `RAISE=0` skips it. `INSTALL_RAISE=1` together with `INSTALL_NO_START=1` runs only that step. Sign in again afterwards. It does not stay privileged. `scripts/raise.sh --chroot` is the only setuid install, and the normal launch does not pass `--chroot`: `/usr/local/libexec/code-bootstraps-llama/chroot-drop` becomes the invoking user before it runs the command. `scripts/recover.py` watches the router and loads general or coder again when that child dies with a non-zero status. A clean stop is left alone. Three deaths of the same model inside two minutes stop the retries.

`TOOLS_RUNTIME=auto` (the default) checks for a working `podman`, then `docker`. If it finds one, it starts a container from `TOOLS_IMAGE`, mounts `WORKDIR` at `/work`, and passes `--tools-runtime <engine>-container:<id>`. Before the server starts, `serve.sh` checks from cwd `/` that `podman exec -w /work` can see `/` and `/work`. If that check fails, the server does not start and does not fall back to the host. `serve.sh` writes `.cache/tools.json`. `scripts/agent.py` sends `x-tool-cwd` from that file when `--cwd` is omitted, so an empty `CWD` is not the same as "no directory". A relative `--cwd` is joined under `/work`. A host path outside the mount is refused. To edit this repository, start with `WORKDIR="$PWD" scripts/serve.sh` and restart after changing it. The tools only see the mounted directory. `TOOLS=full` and `TOOLS=auto` use the same container; `auto` becomes `lean` only on the `lowram` profile.

**If neither podman nor docker works (the usual case on Termux and on many laptops), the tools run on the host** with the permissions of the user running the server. The model can then read, write and run anything that account can. Paths are resolved against `WORKDIR`, but absolute paths are not confined to it. `serve.sh` prints a short note when this happens (`TOOLS=lean` offers fewer tools). To turn the tools off, use `TOOLS="" MCP_CONFIG=""`. To pick a runtime yourself, set `TOOLS_RUNTIME` to `host`, `podman:<image>`, `docker:<image>`, `podman-container:<id>`, `docker-container:<id>` or `ssh:<target>`.

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

**Not tested:** Windows, macOS, locale swap on Termux, GPU backends, the container tool runtime with these modes, locales other than Japanese for swap, larger Japanese models.

### Security

The router passes its own command-line flags to every model instance it starts, and the instances listen on random 127.0.0.1 ports. `serve.sh` and `serve.ps1` therefore:
- pass the API key as `LLAMA_API_KEY` in the environment instead of `--api-key-file`. The instances inherit it, so they answer 401 to anything without the key (except `/health`). The router forwards the client's `Authorization` header, so requests through the router still work.
- give the tools and MCP config to the router only, through `LLAMA_ARG_*` environment variables, and the `[*]` section of the preset overrides them in the instances (`tools = get_info`, empty MCP config).
- clear every inherited `LLAMA_ARG_*` and `LLAMA_API_KEY` variable (for example `LLAMA_ARG_MCP_SERVERS_JSON`, `LLAMA_ARG_AGENT`, `LLAMA_ARG_UI_MCP_PROXY`), plus `LLAMA_APP_CMD`, `LLAMA_SERVER_ROUTER_PORT`, `LLAMA_SERVER_CHILD_MODE`, `LLAMA_SERVER_SLOTS_DEBUG`, `LLAMA_TRACE`, `HF_ENDPOINT` and `MODEL_ENDPOINT`, and set only their own.
- refuse extra arguments that would widen what the model can do (`--tools`, `--tools-runtime`, `-ag`/`--agent`, `--mcp-*`, `--ui-mcp-proxy`/`--webui-mcp-proxy`, `--api-key`, `--api-key-file`, `--rpc`), because the router overlays extra flags on every preset, flags that would break the ready check (`--host`, `--port`, `--reuse-port`: use `HOST=` / `PORT=`, `-BindHost` / `-Port` on Windows; `--log-file`, `--log-disable`, `-lv`/`--verbosity`/`--log-verbosity`: `serve` reads the server's log, `.cache/server.log`), and arguments that pick, download or attach a model or point at model or file locations: `-m`/`--model`, `-mu`/`--model-url`, `-dr`/`--docker-repo`, `-hf`/`-hfr`/`--hf-repo`, `-hff`/`--hf-file`, the draft variants (`-hfd`, `-hfrd`, `--hf-repo-draft`, `-md`, `--model-draft`, `--spec-draft-model`, `--spec-draft-hf`), `--models-dir`, `--models-preset`, `--lora*`, `--control-vector*`, `-mm`/`--mmproj`, `-mmu`/`--mmproj-url`, `-a`/`--alias`, `--path`, `--media-path` and the built-in model presets (`--fim-*`, `--gpt-oss-*`, `--vision-*`, `--embd-*-default`). Matching ignores case and treats `_` as `-` (`--API_KEY`, `--Hf_Repo`, `--model=x`). Other flags are allowed and apply to every role (see Run); `serve` says so when it gets any.
- pin every role to one file in the preset and pass no `--models-dir` (see Models), and point `LLAMA_CACHE` at a new, empty directory on every start (`.cache/llama-cache.<pid>.<random>`, deleted when `serve` stops; older ones from a crashed start and a legacy `.cache/llama-cache` are deleted first, a symlink or junction only as the link): the router always adds the GGUFs of the Hugging Face cache (`~/.cache/huggingface/hub`, `%USERPROFILE%\.cache\huggingface\hub`, or `HF_HUB_CACHE` / `HF_HOME`) to its model list, with no flag to turn that off, and `LLAMA_CACHE` takes precedence over all of those (`common/hf-cache.cpp`). Without this, a model downloaded earlier with `llama-server -hf` showed up in the web UI's model list (Windows test), and (round-5 review) a Hugging Face-layout model placed in a reused `.cache/llama-cache` was listed and loaded with `--hf-repo`, without a sha256 check. `serve` also sets `LLAMA_ARG_OFFLINE=1` and `MODEL_ENDPOINT=https://offline.invalid/` (a name that never resolves), so the router cannot download a model at run time either: a model requested through `POST /models` or the UI's model picker that is not in the preset is not fetched (tested: without offline mode, `bartowski/SmolLM2-135M-Instruct-GGUF:Q2_K` was downloaded into the cache; with it, the router's own check of the request still queried Hugging Face and wrote the repository's `refs/main`, because that check ignores offline mode in b11374; with the endpoint as well, nothing). `tests/test_serve_ready.sh` and the model-selection matrix cover a populated, stale and symlinked cache. **`GET /models?reload=1` is not supported:** a reload makes the router scan `LLAMA_CACHE` again, so a Hugging Face-layout model written into the per-start directory while the server runs would then be listed (`[cache]`) and could be loaded without a sha256 check (found on Windows; it needs write access to `.cache\` as your user and the API key). Restart `serve` instead of reloading.
- start `llama-server` in its own process group and forward exactly one signal on Ctrl-C or `kill`, so it shuts down cleanly. A `serve.sh` started in the background by a non-interactive shell (`./scripts/serve.sh &` in a script) ignores SIGINT, as all background jobs there do; stop it with `kill -TERM <pid>`. Once its own server answers, `serve.sh` prints `serve.sh: listening on http://HOST:PORT` and writes `.cache/serve.ready` (`<port> <pid>`). "Its own" is required on every platform as: the server it started (still running) wrote its own `listening on http://HOST:PORT` line to `.cache/server.log` (always passed as `--log-file`; the old log is deleted before the start), and `/health` answers. Where sockets are visible, the process listening on the port must also be that server: `ss -ltnp` shows its pid (Linux), else `lsof -a -p <pid> -iTCP:<port> -sTCP:LISTEN` (macOS); `serve.ps1` checks that the `Get-NetTCPConnection` owner is the `llama-server.exe` it started (compared by volume and file index, so a `subst` drive or junction path matches). On Android 10 and later apps cannot see sockets at all (SELinux denies `/proc/net/tcp*` and sock_diag, so `ss`, `lsof` and reading `/proc/net` show nothing), so there the log line is what tells its own server from another program on the port: the round-5 review showed that "pid alive + `/health`" alone was fooled by a decoy on the port while a slow `llama-server` was still starting (it then failed to bind); `tests/test_serve_ready.sh` reproduces that. If another program answers on the port, `serve.sh` says so and no ready file is written. The launchers' UI helper waits for that file and does not send the API key anywhere to find out. `start.sh` takes a port as busy unless `curl telnet://127.0.0.1:<port>` gets "connection refused".

The default tools image is pinned by digest (`python:3.12-slim@sha256:dddfd7e0…`, the multi-arch index as of 2026-10-03); set `TOOLS_IMAGE` to change it.

`scripts/agent.py` asks before running any tool that is not a read-only built-in (`type` `server` with `permissions.write` false in the server's `/tools` list, e.g. `read_file`, `file_glob_search`, `grep_search`, `get_info`), so write tools and all MCP tools need a confirmation unless `--yes`; with stdin closed the answer is no. It decides this from the server's full tool list, not from the `--tools` subset, and it rejects a call to a tool it did not offer. It refuses to send the API key over plain `http://` to a host that is not loopback. It also refuses file-tool paths (`path`, `file_path`, ...) that resolve outside `--cwd`, unless `--allow-outside`; this keeps the model in the project but is not a sandbox, since `exec_shell_command` can reach anything the account can (use the container runtime).

## License

MIT, see `LICENSE`. llama.cpp is MIT-licensed by the ggml authors, see `NOTICE`. Each model has its own license, listed in `config/models-manifest.json`.
