#!/usr/bin/env bash
# Package Payload/ into APP-VERSION-BUILD-SHORTSHA.unsigned.ipa (trusted, macOS).
# ditto preserves symlinks and file modes; COPYFILE_DISABLE stops AppleDouble
# (._*) resource-fork files from polluting the archive.
set -euo pipefail

: "${BUILD_DIR:?}" "${OUTPUT_DIR:?}" "${EXPECTED_SHA:?}"

PAYLOAD="$BUILD_DIR/package/Payload"
test -d "$PAYLOAD"

APP_BUNDLE_NAME="$(cat "$OUTPUT_DIR/app-bundle-name.txt")"
APP_PATH="$PAYLOAD/$APP_BUNDLE_NAME"
INFO_PLIST="$APP_PATH/Info.plist"
test -f "$INFO_PLIST"

plist() {
    /usr/libexec/PlistBuddy -c "Print :$1" "$INFO_PLIST" 2>/dev/null || echo "unknown"
}

APP_NAME="$(basename "$APP_BUNDLE_NAME" .app | tr -cd 'A-Za-z0-9._-')"
VERSION="$(plist CFBundleShortVersionString | tr -cd 'A-Za-z0-9._-')"
BUILD_NUM="$(plist CFBundleVersion | tr -cd 'A-Za-z0-9._-')"
SHORT_SHA="${EXPECTED_SHA:0:7}"

IPA_FILENAME="${APP_NAME}-${VERSION}-${BUILD_NUM}-${SHORT_SHA}.unsigned.ipa"

echo "Packaging $IPA_FILENAME"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --keepParent \
    "$PAYLOAD" \
    "$OUTPUT_DIR/$IPA_FILENAME"

printf '%s\n' "$OUTPUT_DIR/$IPA_FILENAME" > "$OUTPUT_DIR/ipa-path.txt"

(
    cd "$OUTPUT_DIR"
    shasum -a 256 "$IPA_FILENAME" > SHA256SUMS
    cat SHA256SUMS
)
