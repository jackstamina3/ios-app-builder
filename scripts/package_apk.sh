#!/usr/bin/env bash
# Rename + checksum the Gradle-built APK as APP-VERSION-BUILD-SHORTSHA.debug.apk
# (trusted step, runs on the ubuntu runner in the normal environment).
#
# Gradle already emits a complete, debug-signed zip, so there is no repackaging
# - only metadata extraction (aapt badging), a stable rename, and SHA256SUMS.
set -euo pipefail

: "${OUTPUT_DIR:?}" "${EXPECTED_SHA:?}"

APK_SRC="$(cat "$OUTPUT_DIR/apk-src-path.txt")"
test -f "$APK_SRC"

# Locate an aapt/aapt2 in the SDK build-tools (not always on PATH). Pick the
# highest available build-tools version.
find_sdk_tool() {
    local tool="$1" sdk found
    if command -v "$tool" >/dev/null 2>&1; then command -v "$tool"; return 0; fi
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    [ -n "$sdk" ] || return 1
    found="$(find "$sdk/build-tools" -maxdepth 2 -name "$tool" -type f 2>/dev/null | sort -V | tail -1)"
    [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
    return 1
}

AAPT="$(find_sdk_tool aapt2 || find_sdk_tool aapt || true)"
[ -n "$AAPT" ] || { echo "ERROR: could not locate aapt/aapt2 in the Android SDK" >&2; exit 1; }

# Dump badging to a file; python reads it via argv (stdin carries the program).
BADGING_FILE="$OUTPUT_DIR/aapt-badging.txt"
"$AAPT" dump badging "$APK_SRC" > "$BADGING_FILE" 2>/dev/null || true

# Extract label / versionName / versionCode (tab-separated, sanitized).
FIELDS="$(python3 - "$BADGING_FILE" <<'PYEOF'
import re, sys
data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def find(pat, default=""):
    m = re.search(pat, data)
    return m.group(1) if m else default
pkg = find(r"package: name='([^']*)'")
label = find(r"application-label:'([^']*)'") or (pkg.split(".")[-1] if pkg else "app")
version = find(r"versionName='([^']*)'") or "unknown"
build = find(r"versionCode='([^']*)'") or "unknown"
clean = lambda s: re.sub(r"[^A-Za-z0-9._-]", "", s) or "app"
print("%s\t%s\t%s" % (clean(label), clean(version), clean(build)))
PYEOF
)"
APP="$(printf '%s' "$FIELDS" | cut -f1)"
VERSION="$(printf '%s' "$FIELDS" | cut -f2)"
BUILD_NUM="$(printf '%s' "$FIELDS" | cut -f3)"
SHORT_SHA="${EXPECTED_SHA:0:7}"

APK_FILENAME="${APP}-${VERSION}-${BUILD_NUM}-${SHORT_SHA}.debug.apk"

echo "Packaging $APK_FILENAME"
cp "$APK_SRC" "$OUTPUT_DIR/$APK_FILENAME"
printf '%s\n' "$OUTPUT_DIR/$APK_FILENAME" > "$OUTPUT_DIR/apk-path.txt"

(
    cd "$OUTPUT_DIR"
    sha256sum "$APK_FILENAME" > SHA256SUMS
    cat SHA256SUMS
)
