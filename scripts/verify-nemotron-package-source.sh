#!/bin/sh
set -eu

if [ "$#" -ne 3 ]; then
    printf 'usage: %s MODEL_ROOT EXPECTED_MODEL_SHA256 EXPECTED_SOURCE_REVISION\n' "$0" >&2
    exit 2
fi

model_root="$1"
expected_model_sha256="$2"
expected_source_revision="$3"
relative_model="gpu-pipelined/nemotron_3_nano_4b_decode_int8hu"
metadata="$model_root/$relative_model/metadata.json"
model="$model_root/$relative_model/nemotron_3_nano_4b_decode_int8hu.aimodel/main.mlirb"

case "$expected_model_sha256" in
    *[!0-9a-f]*|'') printf 'error: invalid expected Nemotron model SHA-256\n' >&2; exit 1 ;;
esac
test "${#expected_model_sha256}" -eq 64
case "$expected_source_revision" in
    *[!0-9a-f]*|'') printf 'error: invalid expected Nemotron source revision\n' >&2; exit 1 ;;
esac
test "${#expected_source_revision}" -eq 40

if [ ! -f "$metadata" ]; then
    printf 'error: Nemotron package metadata is missing: %s\n' "$metadata" >&2
    exit 1
fi
if [ ! -f "$model" ]; then
    printf 'error: Nemotron Core AI model is missing: %s\n' "$model" >&2
    exit 1
fi
if [ "$(/usr/bin/plutil -extract compression raw -expect string -o - "$metadata")" != "int8-body-clipped-head-absmax-per-block-32" ]; then
    printf 'error: Nemotron package is not the expected INT8 profile\n' >&2
    exit 1
fi
if [ "$(/usr/bin/plutil -extract source.revision raw -expect string -o - "$metadata")" != "$expected_source_revision" ]; then
    printf 'error: Nemotron source revision does not match the pinned revision\n' >&2
    exit 1
fi

actual_model_sha256="$(shasum -a 256 "$model" | awk '{print $1}')"
if [ "$actual_model_sha256" != "$expected_model_sha256" ]; then
    printf 'error: Nemotron model SHA-256 mismatch\n' >&2
    exit 1
fi

"$(dirname -- "$0")/verify-model-assets.sh" "$model_root"
