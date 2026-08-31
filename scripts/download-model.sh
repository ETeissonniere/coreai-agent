#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/scripts/model-sources.env"
repo_id="$COREAI_ARTIFACT_REPOSITORY"
destination="$repo_root/Models/Qwen3.8-27B-CoreAI"
nemotron_destination="$repo_root/Models/Nemotron-3-Nano-4B-CoreAI"

rm -rf "$destination"
mkdir -p "$destination"
HF_HOME="$repo_root/.build/huggingface" hf download "$repo_id" \
    --revision "$COREAI_ARTIFACT_REVISION" \
    --local-dir "$destination"

"$repo_root/scripts/verify-model-assets.sh" "$destination"

rm -rf "$nemotron_destination"
mkdir -p "$nemotron_destination"
HF_HOME="$repo_root/.build/huggingface" hf download "$NEMOTRON_COREAI_ARTIFACT_REPOSITORY" \
    --revision "$NEMOTRON_COREAI_ARTIFACT_REVISION" \
    --local-dir "$nemotron_destination"
"$repo_root/scripts/verify-nemotron-package-source.sh" \
    "$nemotron_destination" \
    "$NEMOTRON_COREAI_MODEL_SHA256" \
    "$NEMOTRON_MODEL_REVISION"

printf 'Model bundle downloaded to %s/gpu-pipelined/qwen3_8_27b_decode_int4lin\n' "$destination"
printf 'Fast model bundle downloaded to %s/gpu-pipelined/nemotron_3_nano_4b_decode_int8hu\n' \
    "$nemotron_destination"
