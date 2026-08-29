# Nemotron model provenance and redistribution

This document is the release gate for any bundled Core AI conversion of
`nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`. It is an engineering compliance
checklist, not legal advice.

## Pinned artifact provenance

Do not export or redistribute an artifact obtained from a moving branch. Before
conversion, record the following in the conversion manifest and release notes:

- Hugging Face repository: [`nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16`](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16)
- exact immutable Hugging Face commit SHA. The feasibility spike uses
  `dfaf35de3e30f1867dd8dbc38a7fc9fb52d3914f`;
- filenames and SHA-256 digests for the BF16 weights, configuration, tokenizer,
  chat template, and any parser inputs;
- exporter version/commit, Core AI and Xcode versions, quantization recipe, and
  SHA-256 digest of the resulting `.aiengine`;
- the license text and repository file listing captured at that same revision.

At the feasibility-spike revision, `model.safetensors` is 7,947,142,640 bytes
with SHA-256
`55d4e2519456c4a9bddf596b0748d630e3b2ce6ff6f4c2b7ed3e07e2b00dad42`.
These values identify the evaluated source artifact; a release must re-verify
them rather than treating this document as a download manifest.

The model card currently says the model is ready for commercial use and that
its governing terms are the [NVIDIA Nemotron Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/).
The repository metadata label is not a substitute for retaining the governing
license text from the pinned revision.

## Redistribution obligations

An INT4 Core AI conversion should be treated as a Derivative Work. Sections 2
and 3 of the NVIDIA license permit commercial use, modification, sublicensing,
and redistribution in source or object form, subject to these conditions:

1. Give every recipient a complete, readable copy of the NVIDIA license. Ship
   it inside the app resources (for example,
   `ThirdPartyLicenses/NVIDIA-Nemotron-Open-Model-License.txt`) and expose it in
   an in-app Acknowledgments view.
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

The current [upstream file tree](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/tree/main)
does not show a `NOTICE` file, but that observation does not replace the
required check of the immutable revision used for a release.

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

- [ ] Immutable Hugging Face revision and all input/output hashes recorded.
- [ ] Conversion recipe, exporter commit, Core AI version, and Xcode version recorded.
- [ ] License text from the pinned revision included in the app and visible in Acknowledgments.
- [ ] Pinned repository checked for `NOTICE`; required notice and attribution included if present.
- [ ] Applicable source notices preserved.
- [ ] Tokenizer, template, parser, configuration, and copied-code licenses audited.
- [ ] Product copy uses NVIDIA marks descriptively and does not imply endorsement.
- [ ] App Store/EULA/DRM compatibility reviewed.
- [ ] Export-control and sanctions review completed for enabled territories.
- [ ] License, notices, manifest, checksums, and acknowledgment evidence archived with the release.

Primary sources: the [model card](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/blob/main/README.md),
[repository files](https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16/tree/main),
and [NVIDIA Nemotron Open Model License](https://www.nvidia.com/en-us/agreements/enterprise-software/nvidia-nemotron-open-model-license/).
