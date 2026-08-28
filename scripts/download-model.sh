#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/scripts/model-sources.env"
repo_id="$COREAI_ARTIFACT_REPOSITORY"
bundle="gpu-pipelined/qwen3_8_27b_decode_int4lin"
destination="$repo_root/Models/Qwen3.8-27B-CoreAI"

mkdir -p "$destination"
HF_HOME="$repo_root/.build/huggingface" hf download "$repo_id" \
    --revision "$COREAI_ARTIFACT_REVISION" \
    --include "$bundle/**" \
    --local-dir "$destination"

"$repo_root/scripts/verify-model-assets.sh" "$destination"

printf 'Model bundle downloaded to %s/%s\n' "$destination" "$bundle"
