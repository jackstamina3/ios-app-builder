#!/usr/bin/env bash
# Select the exact Xcode requested by the manifest via DEVELOPER_DIR.
# Fails listing the installed Xcodes when the requested version is absent -
# never silently uses a different Xcode.
set -euo pipefail

: "${XCODE_VERSION:?XCODE_VERSION must be set}"

XCODE_APP="/Applications/Xcode_${XCODE_VERSION}.app"
DEVELOPER_DIR="$XCODE_APP/Contents/Developer"

if [ ! -d "$DEVELOPER_DIR" ]; then
    echo "::error::Requested Xcode $XCODE_VERSION not installed at $XCODE_APP" >&2
    echo "Installed Xcode versions on this runner:" >&2
    ls -1d /Applications/Xcode*.app >&2 || true
    exit 1
fi

export DEVELOPER_DIR
echo "Selected: $XCODE_APP"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

# Persist for later workflow steps when running inside Actions.
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi
