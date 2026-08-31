# Nemotron model provenance and redistribution

This document records the provenance and redistribution controls for the Core
AI conversion of `nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16` bundled as the app's
Fast model. It is an engineering compliance checklist, not legal advice.

## Feasibility status

The original custom INT4 feasibility path did not pass its performance and
numerical-quality gates and remains rejected. It is not the artifact shipped by
the application.

The app instead bundles a separately produced **INT8 Core AI** profile at
`Models/Nemotron-3-Nano-4B-CoreAI/gpu-pipelined/` for Fast mode. Packaging is
fail-closed: it verifies the complete `SHA256SUMS` manifest, the exact source
revision recorded in model metadata, the expected INT8 compression profile,
and the compiled model digest before copying the tree into the signed app.

## Pinned artifact provenance

The packaged provenance resource records:

- Hugging Face repository: [`nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16)
- exact immutable Hugging Face commit SHA:
  `dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f`;
- SHA-256 digests for the source BF16 weights and compiled Core AI model, plus
  a complete checksum manifest for every file copied into the app;
- Core AI execution profile, operational context, quantization recipe, and
  SHA-256 digest of the resulting `.aimodel` bundle;
- the license text and repository file listing captured at that same revision.

At the feasibility-spike revision, `model.safetensors` is 7,947,142,640 bytes
with SHA-256
`55d4e2519456c4a9bddf596b0748d630e3b2ce6ff6f4c2b7ed3e07e2b00dad42`.
The bundled Core AI `main.mlirb` has SHA-256
`d4967f627d20274ba8a06e8318f9f82e289b05c1c7e7f3b63b4c597cb35d0970`.
The machine-readable record is packaged as
`ModelProvenance/Nemotron-3-Nano-4B-CoreAI.json`.

The model card currently says the model is ready for commercial use and that
its governing terms are the [NVIDIA Nemotron Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/).
The repository metadata label is not a substitute for retaining the governing
license text from the pinned revision.

At pinned revision `dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f`, the
repository's `LICENSE` object is present but empty (0 bytes), and the repository
does not contain a `NOTICE` file. The distributable license resource therefore
comes from the model card's primary governing-terms link to NVIDIA, version
December 15, 2025. These observations must be rechecked if the pinned revision
changes.

## Redistribution obligations

The INT8 Core AI conversion is treated as a Derivative Work. Sections 2
and 3 of the NVIDIA license permit commercial use, modification, sublicensing,
and redistribution in source or object form, subject to these conditions:

1. Give every recipient a complete, readable copy of the NVIDIA license. It is
   shipped as `ThirdPartyLicenses/NVIDIA-Nemotron-Open-Model-License.txt`.
2. Preserve all applicable copyright, patent, trademark, and attribution
   notices from the source form in distributed source.
3. Inspect the **pinned** upstream tree for a `NOTICE` file. If one exists,
   include its readable contents in the distribution and include the exact
   statement required by section 3(c): “Licensed by NVIDIA Corporation under
   the NVIDIA Nemotron Model License.”
4. Use NVIDIA and Nemotron names only for customary, factual identification of
   the model's origin. Do not imply NVIDIA endorsement or certification.
5. Preserve the license's warranty and liability disclaimers. Any support or
   warranty offered by this project must be solely on the distributor's behalf,
   not NVIDIA's.

The [pinned upstream file tree](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/tree/dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f)
is evidence for the feasibility spike. A future release must repeat the check
against its own immutable revision rather than relying on this result.

## Tokenizer, template, and code boundary

The model license defines the Work broadly, but do not assume it clears every
third-party file or implementation used during conversion. Audit the pinned
tokenizer, chat template, reasoning parser, configuration, and their embedded
notices individually. Keep a manifest of files copied into the app.

Hugging Face Transformers, llama.cpp, and MLX implementations may be used as
behavioral references during validation. Do not copy their implementation into
the shipped runtime without a separate license and notice review. A local,
clean Core AI reimplementation minimizes this boundary but does not remove the
obligation to audit any data or code actually copied.

## App Store and trade-compliance caveats

- Confirm with counsel that App Store terms, receipt/DRM behavior, and the app's
  EULA do not prevent recipients from receiving the required license or impose
  conflicting restrictions on the bundled derivative weights.
- Section 7 contains indemnity obligations for third-party claims arising from
  use, distribution, or outputs. Review this exposure before public or
  commercial release.
- Section 10 requires compliance with applicable export, import, sanctions,
  destination, end-user, and end-use rules, including the U.S. EAR and OFAC
  regulations. Review enabled App Store territories for every release.
- The license terminates on filing certain patent or copyright infringement
  claims concerning the Work or its outputs. Escalate relevant disputes to
  counsel.

## Release checklist

- [x] Immutable Hugging Face revision and source/output hashes recorded.
- [x] Core AI profile, compression recipe, operational context, and compilation timestamp recorded.
- [x] Complete governing license included in the app resources.
- [x] Pinned repository checked for `NOTICE`; no upstream `NOTICE` exists at this revision.
- [x] Project attribution notice included with the required NVIDIA sentence.
- [ ] Tokenizer, template, parser, configuration, and copied-code licenses re-audited for the release candidate.
- [ ] Product copy uses NVIDIA marks descriptively and does not imply endorsement.
- [ ] App Store/EULA/DRM compatibility reviewed.
- [ ] Export-control and sanctions review completed for enabled territories.
- [ ] Packaged app passes the checksum/provenance verifier and its license,
      notice, manifest, and checksums are archived with the release.

## Publishing the converted artifact

The verified conversion is published at immutable Hugging Face revision
[`edf3a07fcd5657d4c2549ace034fa864681337a1`](https://huggingface.co/ETeissonniere/Nemotron-3-Nano-4B-CoreAI/tree/edf3a07fcd5657d4c2549ace034fa864681337a1).
The app's download tooling pins this revision rather than following `main`.

The license permits commercial distribution of Derivative Works, including an
INT8 Core AI conversion, provided the redistribution conditions above are met.
If the artifact is published separately on Hugging Face, publish the entire
verified model tree together with:

- the complete `NVIDIA-Nemotron-Open-Model-License.txt`;
- the project `NOTICE` containing “Licensed by NVIDIA Corporation under the
  NVIDIA Nemotron Model License.”;
- the machine-readable provenance JSON and `SHA256SUMS`;
- a model card that identifies the NVIDIA source repository and immutable
  revision, describes the Core AI INT8 modifications, states the 4,096-token
  operational context of this conversion, and says the conversion is not
  produced, endorsed, or certified by NVIDIA.

Recommended Hugging Face model-card metadata:

```yaml
license: other
license_name: nvidia-nemotron-open-model-license
license_link: https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/
base_model: nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16
pipeline_tag: text-generation
library_name: coreai
tags:
  - coreai
  - int8
  - macos
```

Do not publish from an unpinned or unverified workspace, and do not imply that
NVIDIA supports the converted runtime.

Primary sources: the [pinned model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/blob/dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f/README.md),
[pinned repository files](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/tree/dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f),
and [NVIDIA Nemotron Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/).
