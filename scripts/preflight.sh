#!/bin/sh
set -eu

required_xcode_major=27
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode-beta.app/Contents/Developer ]; then
    export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
fi
xcode_version="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
xcode_major="${xcode_version%%.*}"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"

printf 'macOS: %s\n' "$(sw_vers -productVersion)"
printf 'Xcode: %s\n' "$xcode_version"
printf 'macOS SDK: %s\n' "$sdk_version"
printf 'Architecture: %s\n' "$(uname -m)"

if [ "$xcode_major" -lt "$required_xcode_major" ]; then
    printf 'error: Core AI requires Xcode 27 or newer; found Xcode %s.\n' "$xcode_version" >&2
    exit 1
fi

if xcrun --find coreai-build >/dev/null 2>&1; then
    printf 'Core AI compiler is available.\n'
else
    printf 'warning: Core AI runtime SDK is present, but coreai-build is unavailable; AOT compilation is disabled.\n' >&2
fi
