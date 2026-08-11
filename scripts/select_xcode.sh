#!/usr/bin/env bash
# Select the exact Xcode requested by the manifest via DEVELOPER_DIR.
# Fails listing the installed Xcodes when the requested version is absent -
# never silently uses a different Xcode.
#
# Two layouts are supported, in this order:
#   1. GitHub-hosted runner images, which install every Xcode side by side as
#      /Applications/Xcode_<VERSION>.app.
#   2. Self-hosted Macs, where the App Store installs a single
#      /Applications/Xcode.app whose version lives in Contents/version.plist.
# Layout 2 is matched on the REAL CFBundleShortVersionString, never on the
# bundle name, and the comparison is exact: a manifest asking for 26.0.1 will
# not accept an installed 26.0. That keeps the "never silently use a different
# Xcode" invariant intact on both runner kinds.
set -euo pipefail

: "${XCODE_VERSION:?XCODE_VERSION must be set}"

# Real version of an Xcode bundle, or empty when it cannot be read.
xcode_bundle_version() {
    local plist="$1/Contents/version.plist"
    [ -f "$plist" ] || return 0
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || true
}

XCODE_APP=""

# 1. Hosted-image convention.
if [ -d "/Applications/Xcode_${XCODE_VERSION}.app/Contents/Developer" ]; then
    XCODE_APP="/Applications/Xcode_${XCODE_VERSION}.app"
fi

# 2. Self-hosted convention: scan bundles and match the declared version.
if [ -z "$XCODE_APP" ]; then
    for app in /Applications/Xcode*.app; do
        [ -d "$app/Contents/Developer" ] || continue
        if [ "$(xcode_bundle_version "$app")" = "$XCODE_VERSION" ]; then
            XCODE_APP="$app"
            break
        fi
    done
fi

if [ -z "$XCODE_APP" ]; then
    echo "::error::Requested Xcode $XCODE_VERSION not installed" >&2
    echo "Xcode installations found on this runner:" >&2
    FOUND=no
    for app in /Applications/Xcode*.app; do
        [ -d "$app/Contents/Developer" ] || continue
        FOUND=yes
        echo "  $app (version: $(xcode_bundle_version "$app"))" >&2
    done
    [ "$FOUND" = yes ] || echo "  (none)" >&2
    exit 1
fi

DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
export DEVELOPER_DIR
echo "Selected: $XCODE_APP"
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version

# Persist for later workflow steps when running inside Actions.
if [ -n "${GITHUB_ENV:-}" ]; then
    echo "DEVELOPER_DIR=$DEVELOPER_DIR" >> "$GITHUB_ENV"
fi
