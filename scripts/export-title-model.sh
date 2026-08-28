#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/scripts/model-sources.env"
tooling="$repo_root/.build/apple-coreai-models"
checkpoint="$repo_root/.build/checkpoints/Qwen3-0.6B"

if [ ! -d "$tooling/.git" ]; then
    git clone --no-checkout "$APPLE_COREAI_REPOSITORY" "$tooling"
    git -C "$tooling" fetch --depth 1 origin "$APPLE_COREAI_REVISION"
    git -C "$tooling" checkout --detach "$APPLE_COREAI_REVISION"
fi
test "$(git -C "$tooling" remote get-url origin)" = "$APPLE_COREAI_REPOSITORY"
test "$(git -C "$tooling" rev-parse HEAD)" = "$APPLE_COREAI_REVISION"
if [ -n "$(git -C "$tooling" status --porcelain --untracked-files=all)" ]; then
    printf 'error: cached Apple exporter worktree is dirty: %s\n' "$tooling" >&2
    exit 1
fi
uv sync --frozen --project "$tooling"

mkdir -p "$checkpoint"
HF_HOME="$repo_root/.build/huggingface" hf download "$TITLE_MODEL_REPOSITORY" \
    --revision "$TITLE_MODEL_REVISION" \
    --local-dir "$checkpoint"
uv run --frozen --project "$tooling" coreai.llm.export "$checkpoint" \
    --compression 4bit \
    --max-context-length 1024 \
    --output-dir "$repo_root/Models/TitleModel"

# Foundation Models does not currently expose tokenizer template kwargs. Bake
# enable_thinking=false into this task-specific tokenizer so a 20-token title
# budget is spent on the title rather than hidden reasoning.
template="$repo_root/Models/TitleModel/qwen3_0_6b_4bit_dynamic/tokenizer/chat_template.jinja"
perl -pi -e 's/enable_thinking is defined and enable_thinking is false/true/' "$template"
metadata="$repo_root/Models/TitleModel/qwen3_0_6b_4bit_dynamic/metadata.json"
perl -pi -e 's/"name": "qwen3_0_6b_4bit_dynamic"/"name": "title_qwen3_0_6b_4bit_dynamic"/' "$metadata"
perl -pi -e 's#"hf_model_id": "[^"]+"#"hf_model_id": "Qwen/Qwen3-0.6B"#' "$metadata"

printf '%s\n' 'Export complete. Regenerate Models/TitleModel/SHA256SUMS before packaging the new artifact.'
