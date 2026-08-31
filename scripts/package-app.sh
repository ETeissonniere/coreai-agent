#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi

# Always compile before resolving the output path. `--show-bin-path` only
# reports where SwiftPM would place products; it does not guarantee that the
# executable there reflects the current sources.
swift build -c release
binary_dir="$(swift build -c release --show-bin-path)"
app_dir="$repo_root/dist/Qwen Core AI.app"
contents="$app_dir/Contents"
model_source="$repo_root/Models/Qwen3.8-27B-CoreAI"
model_100k_source="$repo_root/Models/Qwen3.8-27B-CoreAI-100K"
model_destination="$contents/Resources/Models/Qwen3.8-27B-CoreAI"
title_model_source="$repo_root/Models/TitleModel"
title_model_destination="$contents/Resources/Models/TitleModel"
nemotron_model_source="$repo_root/Models/Nemotron-3-Nano-4B-CoreAI"
nemotron_model_destination="$contents/Resources/Models/Nemotron-3-Nano-4B-CoreAI"
. "$repo_root/scripts/model-sources.env"

if [ -f "$model_100k_source/gpu-pipelined/qwen3_8_27b_decode_int4lin/metadata.json" ]; then
    model_source="$model_100k_source"
fi
if [ ! -f "$model_source/gpu-pipelined/qwen3_8_27b_decode_int4lin/metadata.json" ]; then
    printf 'error: model is missing; run make download first.\n' >&2
    exit 1
fi
"$repo_root/scripts/verify-model-assets.sh" "$model_source"

mkdir -p "$contents/MacOS" "$contents/Resources"
cp "$binary_dir/QwenCoreAI" "$contents/MacOS/QwenCoreAI"
cp "$repo_root/Packaging/Info.plist" "$contents/Info.plist"
mkdir -p "$contents/Resources/Models"
rm -rf "$model_destination"
if ! cp -cR "$model_source" "$model_destination" 2>/dev/null; then
    cp -R "$model_source" "$model_destination"
fi
if [ ! -f "$title_model_source/qwen3_0_6b_4bit_dynamic/metadata.json" ]; then
    printf 'error: title model is missing; run make export-title-model first.\n' >&2
    exit 1
fi
"$repo_root/scripts/verify-model-assets.sh" "$title_model_source"
rm -rf "$title_model_destination"
if ! cp -cR "$title_model_source" "$title_model_destination" 2>/dev/null; then
    cp -R "$title_model_source" "$title_model_destination"
fi

"$repo_root/scripts/verify-nemotron-package-source.sh" \
    "$nemotron_model_source" \
    "$NEMOTRON_COREAI_MODEL_SHA256" \
    "$NEMOTRON_MODEL_REVISION"
rm -rf "$nemotron_model_destination"
if ! cp -cR "$nemotron_model_source" "$nemotron_model_destination" 2>/dev/null; then
    cp -R "$nemotron_model_source" "$nemotron_model_destination"
fi

for legal_directory in ThirdPartyLicenses ThirdPartyNotices ModelProvenance; do
    rm -rf "$contents/Resources/$legal_directory"
    cp -R "$repo_root/Packaging/$legal_directory" "$contents/Resources/$legal_directory"
done

# SwiftPM applies a linker signature to the executable, but assembling an app
# around that binary changes its signing context and adds resources that must be
# sealed. Sign only after the complete bundle has been assembled so taskgated
# can validate the app at launch.
codesign --force --deep --sign - "$app_dir"
codesign --verify --deep --strict --verbose=2 "$app_dir"

printf 'Packaged %s\n' "$app_dir"
