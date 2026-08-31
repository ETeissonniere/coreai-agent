# Qwen3.8 native MTP research

This branch records the speculative-decoding investigation separately from the
non-MTP extended-context integration. It does not change the app's shipped
models or package speculative model payloads.

## What the checkpoint contains

Qwen3.8-27B includes a trained one-layer, DeepSeek-V3-style multi-token
prediction head under `mtp.*`. It is not a generic second language model. The
head consumes the last token and a target hidden-state row, applies normalized
embedding/hidden projections and one decoder layer, and uses the target
vocabulary head to produce the next draft token. Later drafts recurrently use
the MTP head's own hidden output.

The implementation conventions were selected empirically:

- concatenate embedding before target hidden state;
- feed the MTP block's post-norm hidden to the next draft step;
- seed drafting from the target's post-final-norm hidden output;
- replay committed context into persistent MTP KV state.

Committed-context replay is essential. Earlier fresh-KV probes reached only
about 0.69 first-token acceptance, while replay reached about 0.98 on the code
probe used during authoring.

## Why native MTP is not automatically faster

The MTP head proposes tokens cheaply, but the full target still verifies every
round. Qwen3.8 is a Gated DeltaNet hybrid: 48 of its 64 target layers carry
cumulative convolution/recurrent state that cannot be rolled back by merely
moving a token index. A lossless speculative host therefore has to:

1. snapshot target recurrent state;
2. execute a static multi-token verification window;
3. restore state after a partial rejection;
4. re-anchor committed tokens into target state;
5. replay committed rows into the MTP state.

The current verifier uses a static `S=9` query while drafting at most `K=6`.
That leaves unused lanes and computes rejected tokens. Some MTP/replay calls
also absorb command-buffer synchronization, and the target plus drafter put
additional pressure on a 48 GB unified-memory system.

## Measured baseline

Hardware: Apple M4 Pro, 14 CPU cores, 48 GB unified memory. Models use a
131,072-token context bound. The speculative workload used a 131-token natural
code prompt, generated 256 tokens, and reports the warm mean of trials two and
three. Peak RSS includes mapped model pages.

| Configuration | Stored assets | Peak RSS | Prefill tok/s | Decode tok/s | Accepted drafts/round | Tokens/target forward |
|---|---:|---:|---:|---:|---:|---:|
| Qwen INT4 autoregressive | 17.54 GiB | 31.52 GiB | 10.12 | 9.99 | n/a | 1.00 |
| Qwen INT4 target + INT4 MTP | 24.10 GiB | 33.64 GiB | 41.81 | 9.55 | 2.325 | 2.783 |
| Qwen INT4 target + INT8 MTP | 25.68 GiB | 29.35 GiB | 41.68 | 7.53 | 2.368 | 2.813 |

The INT8 drafter improved acceptance by only 0.043 drafts per round, roughly
1.8%, while reducing decode throughput by about 21% relative to the INT4
drafter. Quantization error is therefore not the dominant acceptance limiter on
this workload. INT4 is the current MTP baseline.

The INT4 MTP path is 4.4% slower than the 128K autoregressive graph despite
reducing target-forward count. Its useful-work ratio is not yet high enough to
pay for drafting, static verification, restore/re-anchor, replay, and host/runtime
synchronization.

## Optimization objective

Primary metric: warm decode tokens/second. Acceptance is a diagnostic, not the
objective. A candidate wins only if it improves aggregate decode throughput.

Required gates:

- output is byte-identical to the target's greedy autoregressive output;
- the benchmark reports three warm, fixed-prompt replicates as one aggregate;
- prefill speed and peak RSS are recorded but cannot silently disappear;
- peak memory remains safe on a 48 GB machine;
- Core AI, Hugging Face, temporary, and experiment caches remain on the Extra
  SSD.

## Evo experiment dimensions

Run benchmarks serially because Core AI inference saturates the shared GPU and
memory-bandwidth path. Recommended Evo width is one with a per-branch budget of
five.

1. Sweep fixed draft depth `K=1...6` using the INT4 MTP head.
2. Export and compare verifier windows `S=K+1`; avoid paying for `S=9` at every
   smaller draft depth.
3. Compare committed-row replay modes and replay batch sizes.
4. Compare fixed and adaptive-K policies across code, prose, tool/RAG, and
   long-context continuations.
5. Reduce avoidable command-buffer synchronization around draft, replay,
   restore, and re-anchor operations.
6. Re-evaluate INT8 only on workloads where it produces a material acceptance
   gain; do not optimize acceptance in isolation.

The first focused experiment should compare `K=2...6` with matching verifier
windows and batched replay enabled. This directly tests whether unused verifier
lanes are the largest recoverable cost before changing the lossless state
discipline.

## SSD-local research assets

The generated experimental bundles remain outside Git under
`Models/Qwen3.8-27B-CoreAI-Spec-128K`. The authoring and benchmark checkout is
`.build/qwen-mtp-coreai`; the community exporter/host checkout is
`.build/coreai-model-zoo`. The Core AI runtime cache is redirected to
`.build/coreai-runtime-cache` on the Extra SSD.
