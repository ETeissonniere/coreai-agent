#!/bin/sh
set -eu

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

verify_root() {
    asset_root="$1"
    manifest="$asset_root/SHA256SUMS"
    if [ ! -f "$manifest" ]; then
        printf 'error: model checksum manifest is missing: %s\n' "$manifest" >&2
        return 1
    fi
    if grep -Ev '^[0-9a-f]{64}  [^/].*$' "$manifest" | grep -q .; then
        printf 'error: malformed model checksum manifest: %s\n' "$manifest" >&2
        return 1
    fi
    if grep -E '  (\.\.?/|.*[/]\.\.?/)' "$manifest" >/dev/null; then
        printf 'error: unsafe path in model checksum manifest: %s\n' "$manifest" >&2
        return 1
    fi
    manifest_absolute="$(CDPATH= cd -- "$(dirname -- "$manifest")" && pwd)/$(basename -- "$manifest")"
    (CDPATH= cd -- "$asset_root" && shasum -a 256 -c "$manifest_absolute")
}

if [ "$#" -gt 0 ]; then
    for asset_root in "$@"; do verify_root "$asset_root"; done
else
    verify_root "$repo_root/Models/Qwen3.8-27B-CoreAI"
    verify_root "$repo_root/Models/TitleModel"
fi
