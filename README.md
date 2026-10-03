# code-bootstraps-llama.cpp

A minimal, reproducible package of a pinned [llama.cpp](https://github.com/ggml-org/llama.cpp) plus a hand-picked set of models and configuration. llama.cpp is included as a git submodule pinned to a specific upstream commit, so every checkout builds the same code; models and settings are curated and kept small so the whole thing is easy to stand up on a new machine.

## Getting started

```sh
git clone --recursive https://github.com/brianreborn/code-bootstraps-llama.cpp
cd code-bootstraps-llama.cpp
cmake -S llama.cpp -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
```

If you already cloned without `--recursive`, run `git submodule update --init --recursive`.

## Models

Model weights are **not** stored in git. They are downloaded separately (see the model list and config once added) into `models/`, which is ignored.
