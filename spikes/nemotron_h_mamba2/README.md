# Nemotron-H Mamba-2 feasibility spike

This directory is an isolated, synthetic-weight spike for the recurrent
`NemotronHMamba2Mixer` used by NVIDIA Nemotron 3 Nano 4B. It deliberately does
not download or package the 4B checkpoint.

The architecture is pinned to NVIDIA checkpoint revision
`dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f`, and numerical results are compared
with Hugging Face Transformers 5.12.1. The checkpoint contains 21 Mamba-2
mixers, four grouped-query attention layers, and 17 standalone ReLU² MLPs.
Because this isolated Mamba-2 gate fails, the spike intentionally stops before
implementing the remaining full-model components, downloading weights, or
changing the app.

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
The full model was therefore not downloaded, compressed, or integrated.

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

## Numerical validation

All five tests pass: closed-form recurrence, dense/chunked equivalence, state
continuity into decode, PyTorch export, and Hugging Face prefill/recurrent-decode
equivalence. Core AI outputs and returned convolution/SSM state are also checked
against PyTorch after every benchmark export at `atol=rtol=2e-3`.
