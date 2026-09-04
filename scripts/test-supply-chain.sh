#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/scripts/model-sources.env"

for revision in \
    "$QWEN_MODEL_REVISION" \
    "$COREAI_ARTIFACT_REVISION" \
    "$COREAI_ZOO_REVISION" \
    "$APPLE_COREAI_REVISION" \
    "$APPLE_OVERLAY_BASE_REVISION" \
    "$TITLE_MODEL_REVISION" \
    "$NEMOTRON_MODEL_REVISION" \
    "$NEMOTRON_COREAI_ARTIFACT_REVISION"
do
    case "$revision" in
        *[!0-9a-f]*|'') printf 'invalid pinned revision: %s\n' "$revision" >&2; exit 1 ;;
    esac
    test "${#revision}" -eq 40
done
case "$COREAI_OVERLAY_TREE_SHA256" in
    *[!0-9a-f]*|'') printf 'invalid overlay tree hash: %s\n' "$COREAI_OVERLAY_TREE_SHA256" >&2; exit 1 ;;
esac
test "${#COREAI_OVERLAY_TREE_SHA256}" -eq 64
for digest in "$NEMOTRON_SOURCE_MODEL_SHA256" "$NEMOTRON_COREAI_MODEL_SHA256"; do
    case "$digest" in
        *[!0-9a-f]*|'') printf 'invalid Nemotron SHA-256: %s\n' "$digest" >&2; exit 1 ;;
    esac
    test "${#digest}" -eq 64
done

for script in "$repo_root"/scripts/*.sh; do sh -n "$script"; done
if [ -f "$repo_root/.build/coreai-model-zoo/conversion/export_qwen3_5_decode_pipelined.py" ]; then
    patch -s --dry-run \
        "$repo_root/.build/coreai-model-zoo/conversion/export_qwen3_5_decode_pipelined.py" \
        "$repo_root/scripts/patches/qwen3_8_multifunction_prefill.patch"
fi

fixture="$(mktemp -d "${TMPDIR:-/tmp}/coreai-agent-manifest-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
printf 'trusted artifact\n' > "$fixture/model.bin"
(CDPATH= cd -- "$fixture" && shasum -a 256 model.bin > SHA256SUMS)
"$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null
# Hugging Face `hf download --local-dir` writes this sidecar; it is not a
# model asset and is omitted from SHA256SUMS.
printf '* filter=lfs diff=lfs merge=lfs -text\n' > "$fixture/.gitattributes"
"$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null
printf 'unlisted artifact\n' > "$fixture/extra.bin"
if "$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null 2>&1; then
    printf '%s\n' 'error: checksum verification accepted an unlisted artifact' >&2
    exit 1
fi
rm "$fixture/extra.bin"
ln -s model.bin "$fixture/model-link.bin"
if "$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null 2>&1; then
    printf '%s\n' 'error: checksum verification accepted a symbolic link' >&2
    exit 1
fi
rm "$fixture/model-link.bin"
printf 'tampered artifact\n' > "$fixture/model.bin"
if "$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null 2>&1; then
    printf '%s\n' 'error: checksum verification accepted a modified artifact' >&2
    exit 1
fi

nemotron_fixture="$fixture/nemotron"
nemotron_relative="gpu-pipelined/nemotron_3_nano_4b_decode_int8hu"
nemotron_aimodel="$nemotron_fixture/$nemotron_relative/nemotron_3_nano_4b_decode_int8hu.aimodel"
mkdir -p "$nemotron_aimodel"
printf 'fixture model\n' > "$nemotron_aimodel/main.mlirb"
printf '%s\n' "{\"compression\":\"int8-body-clipped-head-absmax-per-block-32\",\"source\":{\"revision\":\"$NEMOTRON_MODEL_REVISION\"}}" \
    > "$nemotron_fixture/$nemotron_relative/metadata.json"
(CDPATH= cd -- "$nemotron_fixture" && shasum -a 256 \
    "$nemotron_relative/metadata.json" \
    "$nemotron_relative/nemotron_3_nano_4b_decode_int8hu.aimodel/main.mlirb" \
    > SHA256SUMS)
fixture_model_sha256="$(shasum -a 256 "$nemotron_aimodel/main.mlirb" | awk '{print $1}')"
"$repo_root/scripts/verify-nemotron-package-source.sh" \
    "$nemotron_fixture" "$fixture_model_sha256" "$NEMOTRON_MODEL_REVISION" >/dev/null
printf 'tampered model\n' > "$nemotron_aimodel/main.mlirb"
if "$repo_root/scripts/verify-nemotron-package-source.sh" \
    "$nemotron_fixture" "$fixture_model_sha256" "$NEMOTRON_MODEL_REVISION" >/dev/null 2>&1; then
    printf '%s\n' 'error: Nemotron verifier accepted a modified model' >&2
    exit 1
fi
printf 'fixture model\n' > "$nemotron_aimodel/main.mlirb"
if "$repo_root/scripts/verify-nemotron-package-source.sh" \
    "$nemotron_fixture" "$fixture_model_sha256" "0000000000000000000000000000000000000000" >/dev/null 2>&1; then
    printf '%s\n' 'error: Nemotron verifier accepted the wrong source revision' >&2
    exit 1
fi

printf '%s\n' 'Supply-chain checks passed.'
