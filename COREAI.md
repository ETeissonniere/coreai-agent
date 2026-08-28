# Qwen3.8 and Core AI status

This project targets macOS 27 and Xcode 27. It uses Apple's
`CoreAILanguageModel` adapter so an exported Core AI language bundle can back
the Foundation Models `LanguageModelSession` API.

## Why Apple's stock exporter does not recognize Qwen3.8

Apple's `coreai-models` registry currently implements Qwen2.5, Qwen3, Qwen3
MoE, and Qwen3-VL, but not the `qwen3_5` architecture used by Qwen3.8.
Qwen3.8 is not just a new set of weights for Qwen3: its 64-layer decoder
interleaves three Gated DeltaNet recurrent layers with one gated full-attention
layer. It also has convolution/recurrent state, a different head layout,
partial mRoPE, an optional vision tower, and an MTP draft head. The registry's
`--experimental` flag can select an already-authored architecture; it cannot
invent those graph and state semantics.

This is fixable outside Apple. A Core AI port must author the missing PyTorch
graph using Core AI-compatible operations, map all checkpoint weights, expose
the recurrent and KV states, lower the exported program with `coreai-torch`,
and then prove numerical agreement against the Hugging Face BF16 implementation.
The main engineering constraint is that Gated DeltaNet's `while_loop` does not
lower to Apple's GPU delegate, so the working port uses a loop-free, pipelined
single-token decoder with fixed-shape recurrent states.

## Artifact used by this project

The default download is the community text-only INT4 Core AI bundle from
`mlboydaisuke/Qwen3.8-27B-CoreAI`, derived from official checkpoint revision
`1d4bf0f2ff6012fd82039f2fa52739d0dd7c60c0`. It is approximately 18.8 GB and
uses the community `qwen3_5` authoring overlay on Apple's Core AI tooling.
The converted artifact is fetched at immutable Hugging Face revision
`aaccef94c3bd9dee953cbb5fbd0fd824829c7e4f`; the download and package steps
verify the committed SHA-256 manifest before accepting its model and tokenizer files.

The publisher reports 15/16 teacher-forced tokens matching the BF16 oracle,
with the sole mismatch below its confidence threshold, and 22.2 decode
tokens/second on an M4 Max 128 GB. Those are upstream measurements, not
measurements from this Mac. Run the bundled benchmark before treating them as
local performance claims.

The INT4 artifact is preferred here over the 28 GB INT8 version because this is
a 48 GB M4 Pro. The model remains Mac-only. The vision and speculative-decoding
bundles are intentionally excluded from the first download.

`make package` embeds this complete model bundle beneath the app's
`Contents/Resources/Models` directory. The resulting `.app` is self-contained;
it does not download or locate model weights after installation.
There is intentionally no model picker: launch verifies and loads the bundled
asset automatically, then enables the composer when Core AI reports it ready.

The text graph is decode-only with sequence length 1. The app sets
`COREAI_CHUNK_THRESHOLD=1` before loading it; without this, a generic dynamic
prefill attempts to bind the whole prompt and Core AI rejects the shape.

## Commands

```sh
make preflight
make download
make build
make test
make benchmark MODEL="$PWD/Models/Qwen3.8-27B-CoreAI/gpu-pipelined/qwen3_8_27b_decode_int4lin"
```

`make export` reproduces the conversion from the official BF16 checkpoint using
the community graph-authoring overlay and exports INT4 with a true 100,000-token
dynamic-shape bound. It requires at least 80 GiB of free working space and is
separate from `make download`. The packager prefers that artifact when present
and otherwise keeps the verified 4,096-token bundle; it never relabels the old
graph as 100K.

At 100K, the 16 full-attention layers use about 6.1 GiB of FP16 KV state in
addition to the approximately 18 GiB weights. The vendored runtime caps dynamic
cache growth at the bundle limit so exponential growth stops at 100,000 rather
than overshooting to 131,072 slots (about 8 GiB).

`make export-title-model` uses Apple's official exporter to build the bundled
Qwen3-0.6B title generator as macOS INT4 block-32 with a 1,024-token context.
It adds about 331 MiB. INT3 is not an Apple macOS linear-quantization preset;
INT2 is an experimental compression choice with a substantial quality risk, so
the app does not silently ship either for generated titles.

Download and export inputs are pinned in `scripts/model-sources.env`. Existing
Git worktrees are accepted only when their origin URL and exact commit match
those pins and contain no tracked or untracked modifications. The community
overlay is applied only to a disposable clean Apple worktree. Both model
checkpoints are downloaded at pinned Hugging Face revisions before export.
The complete post-overlay source tree is checked against a committed SHA-256
before any exporter dependencies or model weights are loaded.
Python environments are created from the upstream `uv.lock` with
`uv sync --frozen`; dependency resolution is never refreshed implicitly.
After deliberately exporting a replacement artifact, regenerate and review its
`SHA256SUMS` file before packaging. Run `make test-supply-chain` for a fast,
offline validation of the pins, shell scripts, and checksum rejection path.

## Sources

- Apple Core AI: https://developer.apple.com/core-ai/
- Apple Core AI models and Swift runtime: https://github.com/apple/coreai-models
- Apple Core AI PyTorch tooling: https://apple.github.io/coreai-torch/
- Official Qwen checkpoint: https://huggingface.co/Qwen/Qwen3.8-27B
- Port and gates: https://github.com/john-rocky/coreai-model-zoo/tree/main/models/qwen3.8-27b
- Core AI artifact: https://huggingface.co/mlboydaisuke/Qwen3.8-27B-CoreAI

## Runtime patch ownership

`Vendor/coreai-models` is a local copy of Apple's BSD-licensed Core AI models
Swift runtime. The required Qwen3.8 hybrid-state behavior is reproduced in that
local source, so the shipped app has no package dependency on a community
runtime fork. The original BSD license is preserved in the vendor directory.
Return to Apple's unmodified package as soon as upstream supports the same
recurrent-state and S=1 pipeline contract.
