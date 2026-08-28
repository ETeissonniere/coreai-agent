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
    "$TITLE_MODEL_REVISION"
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

for script in "$repo_root"/scripts/*.sh; do sh -n "$script"; done
grep -F 'verify-model-assets.sh" "$model_source"' "$repo_root/scripts/package-app.sh" >/dev/null
grep -F 'verify-model-assets.sh" "$title_model_source"' "$repo_root/scripts/package-app.sh" >/dev/null

fixture="$(mktemp -d "${TMPDIR:-/tmp}/qwen-manifest-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
printf 'trusted artifact\n' > "$fixture/model.bin"
(CDPATH= cd -- "$fixture" && shasum -a 256 model.bin > SHA256SUMS)
"$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null
printf 'tampered artifact\n' > "$fixture/model.bin"
if "$repo_root/scripts/verify-model-assets.sh" "$fixture" >/dev/null 2>&1; then
    printf '%s\n' 'error: checksum verification accepted a modified artifact' >&2
    exit 1
fi

printf '%s\n' 'Supply-chain checks passed.'
