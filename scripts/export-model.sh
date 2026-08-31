#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
. "$repo_root/scripts/model-sources.env"
zoo_dir="${COREAI_ZOO_DIR:-$repo_root/.build/coreai-model-zoo}"
mkdir -p "$repo_root/.build"
export_worktree="$(mktemp -d "$repo_root/.build/coreai-export.XXXXXX")"
coreai_dir="$export_worktree/coreai-models"
trap 'rm -rf "$export_worktree"' EXIT HUP INT TERM
output_dir="$repo_root/Models/Qwen3.8-27B-CoreAI-128K/gpu-pipelined"
checkpoint_dir="$repo_root/.build/checkpoints/Qwen3.8-27B"
required_kib=$((80 * 1024 * 1024))
available_kib="$(df -Pk "$repo_root" | awk 'NR == 2 { print $4 }')"

"$repo_root/scripts/preflight.sh"

if [ "$available_kib" -lt "$required_kib" ]; then
    available_gib=$((available_kib / 1024 / 1024))
    printf 'error: Qwen3.8-27B export needs at least 80 GiB free; only %s GiB is available.\n' "$available_gib" >&2
    printf '%s\n' 'The existing 4K artifact is left untouched.' >&2
    exit 1
fi

if [ ! -d "$zoo_dir/.git" ]; then
    git clone --no-checkout "$COREAI_ZOO_REPOSITORY" "$zoo_dir"
    git -C "$zoo_dir" fetch --depth 1 origin "$COREAI_ZOO_REVISION"
    git -C "$zoo_dir" checkout --detach "$COREAI_ZOO_REVISION"
fi
test "$(git -C "$zoo_dir" remote get-url origin)" = "$COREAI_ZOO_REPOSITORY"
test "$(git -C "$zoo_dir" rev-parse HEAD)" = "$COREAI_ZOO_REVISION"
if [ -n "$(git -C "$zoo_dir" status --porcelain --untracked-files=all)" ]; then
    printf 'error: cached community exporter worktree is dirty: %s\n' "$zoo_dir" >&2
    exit 1
fi

base_repo="$(awk -F': *' '/^repo:/ { print $2 }' "$zoo_dir/conversion/overlay/BASE")"
base_commit="$(awk -F': *' '/^commit:/ { print $2 }' "$zoo_dir/conversion/overlay/BASE")"
test "$base_repo" = "$APPLE_COREAI_REPOSITORY"
test "$base_commit" = "$APPLE_OVERLAY_BASE_REVISION"
git clone --no-checkout "$base_repo" "$coreai_dir"
git -C "$coreai_dir" fetch --depth 1 origin "$base_commit"
git -C "$coreai_dir" checkout --detach "$base_commit"
test "$(git -C "$coreai_dir" remote get-url origin)" = "$APPLE_COREAI_REPOSITORY"
test "$(git -C "$coreai_dir" rev-parse HEAD)" = "$APPLE_OVERLAY_BASE_REVISION"
test -z "$(git -C "$coreai_dir" status --porcelain --untracked-files=all)"
uv run --no-project python "$zoo_dir/conversion/overlay/apply.py" "$coreai_dir"
overlay_tree_hash="$(
    CDPATH= cd -- "$coreai_dir"
    find . -path './.git' -prune -o -type f -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | awk '{ print $1 }'
)"
if [ "$overlay_tree_hash" != "$COREAI_OVERLAY_TREE_SHA256" ]; then
    printf 'error: applied Core AI overlay tree has unexpected SHA-256: %s\n' "$overlay_tree_hash" >&2
    exit 1
fi
uv sync --frozen --project "$coreai_dir" --python 3.11

printf '%s\n' 'Exporting Qwen3.8-27B INT4 with a 131,072-token dynamic KV bound.'
printf '%s\n' 'This downloads the pinned BF16 checkpoint and may take hours.'
mkdir -p "$checkpoint_dir"
HF_HOME="$repo_root/.build/huggingface" hf download "$QWEN_MODEL_REPOSITORY" \
    --revision "$QWEN_MODEL_REVISION" \
    --local-dir "$checkpoint_dir"
"$coreai_dir/.venv/bin/python" \
    "$zoo_dir/conversion/export_qwen3_5_decode_pipelined.py" \
    int4lin \
    --hf-id "$checkpoint_dir" \
    --max-ctx 131072 \
    --out-dir "$output_dir"

metadata="$output_dir/qwen3_8_27b_decode_int4lin/metadata.json"
perl -pi -e 's#"hf_model_id": "[^"]+"#"hf_model_id": "Qwen/Qwen3.8-27B"#' "$metadata"
printf '%s\n' 'Export complete. Create Models/Qwen3.8-27B-CoreAI-128K/SHA256SUMS before packaging.'
