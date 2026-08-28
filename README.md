# Qwen Core AI

Qwen Core AI is a vibe-coded exploration of Apple’s Core AI and Swift APIs. It bundles a local Qwen3.8 27B INT4 model inside a native macOS app and explores what basic, private agentic workflows can feel like when inference, conversations, tools, and runtime telemetry all live on the Mac.

![Qwen Core AI performing web research with live context and KV-cache telemetry](docs/images/context-and-tools.png)

> Reasoning, tool activity, retained-context composition, and KV-cache usage remain visible while the agent works.

The app includes persistent conversations and workspaces, streamed reasoning and Markdown responses, automatic skill discovery, approval-gated web search, document artifacts, context compaction, and performance statistics.

![Qwen Core AI presenting a researched response with citations](docs/images/researched-response.png)

## Requirements

- Apple Silicon Mac with substantial unified memory
- macOS 27 and Xcode 27 or newer
- Git LFS
- [UV](https://docs.astral.sh/uv/) for installing the Hugging Face CLI
- About 40 GB of free disk space for the model checkout and packaged app

The bundled assets are an approximately 19 GB Qwen3.8 27B INT4 model and a smaller Qwen3 0.6B INT4 model used to generate conversation titles.

## Build and run

Clone the repository, fetch the small title model through Git LFS, and download the pinned 27B Core AI artifact from Hugging Face:

```sh
git clone <repository-url>
cd qwen-coreai
git lfs install
git lfs pull
uv tool install huggingface-hub
make download
```

`make download` uses the `hf` command installed by `huggingface-hub` to fetch the pinned model revision.

Verify the toolchain, run the tests, and package the app:

```sh
make preflight
make test
make package
open "dist/Qwen Core AI.app"
```

The 27B model is hosted outside GitHub because its compiled payload is a single 19 GB object, above GitHub LFS's per-object limit. `make package` performs a release build and embeds both models in the application bundle. Once packaged, the app does not download or ask you to select a model.

See [COREAI.md](COREAI.md) for model provenance, reproducible export commands, and details about the local Core AI runtime adaptation.

## Experimental status

This is an exploration, not a production assistant. It targets beta Apple APIs and tooling; the pinned 27B artifact currently has a 4,096-token context window; web search requires approval before a query leaves the Mac; and the generated app is intended for local development rather than distribution—it is not signed or notarized.
