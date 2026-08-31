# Nemotron-H Mamba-2 feasibility spike

This directory contains the isolated recurrent-layer spike and a clean local
implementation of NVIDIA Nemotron 3 Nano 4B for empirical Core AI evaluation.

The architecture is pinned to NVIDIA checkpoint revision
`dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f`, and numerical results are compared
with Hugging Face Transformers 5.12.1. The checkpoint contains 21 Mamba-2
mixers, four grouped-query attention layers, and 17 standalone ReLU² MLPs.
The full-model work covers all 42 layers, strict checkpoint mapping, the four
attention KV states, 21 convolution/recurrent Mamba states, tokenizer/chat
protocols, and a one-token stateful Core AI graph. The original blanket-INT4,
ANE-oriented experiment failed. A later reference-informed GPU-pipelined INT8
implementation passes the runtime gate on this Mac; app integration still
requires the remaining quality, licensing, and end-to-end harness gates.

The spike has three implementations of the same layer:

- `sequential`: explicit token recurrence; correctness oracle and decode path.
- `dense`: loop-free parallel prefix formulation; useful for testing Core AI
  operator coverage, but quadratic in sequence length.
- `chunked`: parallel work within fixed chunks plus a recurrence between
  chunks; bounded quadratic workspace and the candidate prefill formulation.

Run it using the pinned Apple `coreai-models` UV environment:

```sh
UV_CACHE_DIR=.build/uv-cache uv run --frozen \
  --project .build/apple-coreai-models \
  env PYTHONPATH=spikes/nemotron_h_mamba2 \
  pytest -q spikes/nemotron_h_mamba2/tests

UV_CACHE_DIR=.build/uv-cache uv run --frozen \
  --project .build/apple-coreai-models \
  python spikes/nemotron_h_mamba2/benchmark.py
```

`export_coreai.py` exports and executes small prefill and decode graphs using
`coreai-torch`. It reports conversion or runtime failures without substituting
another runtime.

The full exporter expects the pinned Hugging Face checkout at
`.build/checkpoints/NVIDIA-Nemotron-3-Nano-4B-BF16`. Keep experimental output
under `.build`; do not write it into `Models/` unless it has passed the runtime
and quality gates:

```sh
UV_CACHE_DIR=.build/uv-cache uv run --frozen \
  --project .build/apple-coreai-models \
  python spikes/nemotron_h_mamba2/export_full_model.py \
  --checkpoint .build/checkpoints/NVIDIA-Nemotron-3-Nano-4B-BF16 \
  --output .build/exports/nemotron \
  --max-context 4096
```

Use `--skip-bf16` to reproduce only the selective INT8 candidate. The exporter
uses FP16 recurrent state, Apple's macOS RMSNorm and SDPA composites, two
fixed-shape recurrent states, and pre-export INT8 weight compression. Linear
body weights use clipped symmetric block-32 quantization; the untied 131K-vocab
head uses absmax symmetric block-32 quantization.

## Reference-informed GPU reproduction

The initial spike was too focused on ANE compilation and post-export INT4.
`mweinbach/NemotronCoreAI` demonstrates the relevant Core AI GPU/AOT execution
pattern, although that repository targets the unrelated 0.6B streaming ASR
FastConformer. The directly applicable reference is the Nemotron-H conversion
in `john-rocky/coreai-model-zoo`. Neither project is a runtime or source
dependency of this repository; their behavior and graph contracts were used as
references for this local reimplementation.

The working shape is a static `[1,1]` query on the MPSGraph GPU path. At one
token, Mamba-2 becomes a loop-free recurrence step. Prompt ingestion therefore
runs one token at a time with `COREAI_CHUNK_THRESHOLD=1`. The four attention
layers use a growing KV pair, while all 21 Mamba layers share two fixed-shape
state tensors: convolution `[21,1,9728,3]` and recurrence
`[21,1,96,80,128]`. The vendored Swift pipelined engine already supports these
two extra states.

An isolated copy of the published reference artifact was first canaried from
`.build/reference-models`:

| Artifact | Size | Load | TTFT | Prefill | Decode |
|---|---:|---:|---:|---:|---:|
| Published INT8 reference | 4.609 GB | 7.60 s | 1.10 s | 22.8 tok/s | 51.4 tok/s |
| Locally reproduced INT8 | 4.609 GB | 3.52 s | 0.67 s | 37.5 tok/s | 49.9 tok/s |

Both canaries emitted the same 64-token stream for the fixed smoke prompt. The
local artifact was built from the pinned NVIDIA BF16 checkpoint using only the
checked-in `nemotron_h` implementation and Apple tooling. Generated artifacts
remain under `.build` and are neither packaged nor committed.

The earlier INT4 result below remains useful negative evidence. Symmetric INT4
is smaller, but the reference evaluation reports quality loss; the only INT4
recipe that recovered its clean-token oracle used asymmetric block-16 and was
roughly 4.6 times slower than INT8. INT8 is therefore the current Fast-model
candidate despite its larger bundle.

## Findings on this Mac

Environment: macOS 27 beta, `coreai-torch` 0.4.2, `coreai-core` 1.0.0b2,
PyTorch 2.9.0. Runtime values below are medians of five warm invocations; model
load/compilation is excluded. Weights are deterministic synthetic FP32 values.
The exact-size row uses one Nano mixer (`hidden=3136`, 96 x 80 Mamba heads,
state size 128, 8 groups), not the complete 42-layer language model.

| Shape | Prefill | Implementation | Runtime | Throughput | Asset |
|---|---:|---|---:|---:|---:|
| tiny | 16 | sequential unrolled | 2.434 ms | 6,573 tok/s | 0.10 MiB |
| tiny | 16 | dense parallel | 1.498 ms | 10,681 tok/s | 0.04 MiB |
| tiny | 16 | chunked parallel | 1.716 ms | 9,323 tok/s | 0.05 MiB |
| scaled (hidden 512) | 64 | sequential unrolled | 4.599 ms | 13,915 tok/s | 4.34 MiB |
| scaled (hidden 512) | 64 | chunked parallel | 4.175 ms | 15,328 tok/s | 4.09 MiB |
| Nano exact mixer | 1 | recurrent decode | 3.323 ms | 301 tok/s | 301.48 MiB |
| Nano exact mixer | 8 | sequential unrolled | 3.786 ms | 2,113 tok/s | 301.51 MiB |
| Nano exact mixer | 8 | chunked parallel | 5.091 ms | 1,571 tok/s | 301.48 MiB |
| Nano exact mixer | 32 | sequential unrolled | 6.938 ms | 4,613 tok/s | 301.61 MiB |
| Nano exact mixer | 32 | chunked parallel | 10.643 ms | 3,007 tok/s | 301.51 MiB |

Core AI successfully compiles and executes grouped convolution, recurrent
state I/O, `cumsum`, masked exponentials, and the dense/chunked scan graphs.
`aten.unfold` is unsupported by `coreai-torch` 0.4.2; expressing the same
causal convolution as grouped `conv1d` resolves that conversion blocker.

The candidate scan does **not** pass the performance gate. Although chunking
wins slightly at a reduced hidden size, at the actual Nano mixer dimensions it
takes 34% more wall time than the statically unrolled recurrence at 8 tokens
and 53% more at 32 tokens (equivalently, 26-35% lower throughput). Its per-chunk
quadratic `[S,S,H,D,N]` broadcast also scales poorly.
The original scan gate failed. A later decode-dominated experiment proceeded
through the full pinned checkpoint, but its complete runtime gate also failed
as detailed below.

The existing Qwen canary was also attempted with the correct Xcode beta
toolchain:

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
COREAI_CHUNK_THRESHOLD=1 swift run -c release qwen-canary \
  Models/Qwen3.8-27B-CoreAI/gpu-pipelined/qwen3_8_27b_decode_int4lin \
  "Reply with exactly: Core AI is running."
```

The release build completed in 32.44 seconds, but the 18 GB model did not
finish loading or emit a token within the bounded post-build wait, so no fresh
Qwen throughput number is claimed. This does not affect the failed gate: the
candidate scan already loses to the naïve recurrence on the same exact-size
Core AI mixer graph.

## Historical failed INT4/ANE route

`nemotron_h.py` reauthors the full architecture without shipping Hugging Face,
MLX, or llama.cpp as runtime dependencies. The strict checkpoint validation saw
263 expected and 263 loaded tensors with no missing, unexpected, or mismatched
shapes. Real-weight layer comparisons produced:

- first-token Mamba output versus Transformers: max absolute error `2.45e-4`;
- Mamba prefill versus recurrent decode: output `1.4e-6`, convolution state
  `5.25e-6`, recurrent state `2.29e-5` max absolute error;
- standalone MLP versus Transformers: exact;
- grouped-query attention versus Transformers eager attention: `4.77e-7` max
  absolute error.

The exported runtime contract is one `main` function with `input_ids [1,1]`,
dynamic `position_ids`, FP16 logits, four packed attention KV states, 21 packed
convolution states, and 21 packed recurrent states. The operational context is
4096 tokens; prompt ingestion uses the existing runtime's token-wise pipeline.

The first BF16 asset was 7.948 GB. `coreai-opt` 0.2.1 cannot materialize BF16
constants as NumPy arrays and silently skipped them, so the INT4 experiment
rebuilds the same graph with FP16 constants before symmetric per-block-32
compression. That mechanically produces a 2.238 GB asset in 80.7 seconds, but
does not by itself establish quality parity with the BF16 source.

The initial FP32 recurrent-state asset failed before inference in
`ANERegionFormationPass` because ANE does not accept FP32 mutable state. Storing
the recurrent state as FP16 while retaining FP32 recurrence arithmetic produced
valid logits, but ANE compilation still failed and execution fell back:

| Metric | Boundary-FP16 candidate |
|---|---:|
| Load | 0.915 s |
| First inference / TTFT | 1.906 s |
| Warm decode | 0.829 tok/s |
| Logits | finite `[1,1,131072]`, argmax 1149 |

Real-weight recurrence drift from the FP16 state boundary was 0.53% mean
relative mixer-output error at 128 tokens and 0.98% at 512 tokens. Moving all
SSM arithmetic to FP16 increased that to 1.08% and 2.51%, respectively. Two
bounded attempts to export the all-FP16 full graph were terminated by macOS
memory pressure during `export_to_coreai`, before an asset was written.

This route's only runnable full artifact fell below one token per second and
could not serve as a **Fast** model. That conclusion applies to the historical
ANE/post-export-INT4 graph, not the GPU-pipelined selective-INT8 reproduction
above. The exact blocker was ANE compilation of FP32 regions around the SSM
graph; the GPU route avoids treating ANE compatibility as a requirement.

## Numerical validation

All 13 focused tests pass. They cover the isolated recurrence, dense/chunked
equivalence, state continuity into decode, PyTorch export, Hugging Face mixer
parity, synthetic full-checkpoint mapping, hybrid layer ordering, attention KV
continuity, pinned-input rejection, and tokenizer/chat/reasoning/tool protocol
fixtures. Core AI outputs and returned convolution/SSM state are also checked
against PyTorch after each isolated benchmark export at `atol=rtol=2e-3`.

The real-weight full-model mapping, MLP/GQA comparisons, INT4 size, runtime, and
drift figures above are recorded spike measurements rather than claims that the
entire 4B export is exercised by the checked-in test suite. The speed gate failed
before a full INT4-versus-BF16 quality evaluation or save/reload acceptance run;
those remain mandatory before any future promotion.
