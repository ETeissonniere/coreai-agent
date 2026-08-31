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
    if awk '{ sub(/^[0-9a-f]{64}  /, ""); print }' "$manifest" | sort | uniq -d | grep -q .; then
        printf 'error: duplicate path in model checksum manifest: %s\n' "$manifest" >&2
        return 1
    fi
    if find "$asset_root" -type l ! -path "$asset_root/.cache/*" -print -quit | grep -q .; then
        printf 'error: symbolic links are not allowed in model assets: %s\n' "$asset_root" >&2
        return 1
    fi
    manifest_paths="$(awk '{ sub(/^[0-9a-f]{64}  /, ""); print }' "$manifest" | LC_ALL=C sort)"
    asset_paths="$(
        CDPATH= cd -- "$asset_root"
        find . -type f \
            ! -name SHA256SUMS \
            ! -name .DS_Store \
            ! -path './.cache/*' \
            -print | sed 's#^\./##' | LC_ALL=C sort
    )"
    if [ "$manifest_paths" != "$asset_paths" ]; then
        printf 'error: checksum manifest does not exactly cover model assets: %s\n' "$manifest" >&2
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
