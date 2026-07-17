#!/usr/bin/env bash
# Verify a debug-signed Android APK (trusted step, ubuntu runner).
#
# Usage: verify_apk.sh /path/to/App.debug.apk
#
# Android polarity is the OPPOSITE of the iOS verifier: an APK is EXPECTED to
# carry a signature - the debug keystore's - because an unsigned APK cannot
# install. We confirm it IS signed, that the signer is the Android debug key
# (never a release / identity key), record metadata, and print the digest.
#
# Checks:
#  1. archive integrity (unzip -t)
#  2. APK is validly signed AND the signer is the Android debug key (apksigner)
#  3. application id matches the manifest             [when APPLICATION_ID set]
#  4. bundle metadata recorded (app-info.json when OUTPUT_DIR is set)
#  5. SHA-256 digest printed
set -euo pipefail

APK="${1:?usage: verify_apk.sh APK_PATH}"
test -f "$APK"

fail() { echo "VERIFY FAIL: $1" >&2; exit 1; }
note() { echo "VERIFY: $1"; }

find_sdk_tool() {
    local tool="$1" sdk found
    if command -v "$tool" >/dev/null 2>&1; then command -v "$tool"; return 0; fi
    sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    [ -n "$sdk" ] || return 1
    found="$(find "$sdk/build-tools" -maxdepth 2 -name "$tool" -type f 2>/dev/null | sort -V | tail -1)"
    [ -n "$found" ] && { printf '%s\n' "$found"; return 0; }
    return 1
}

# --- 1. archive integrity ----------------------------------------------------
unzip -tqq "$APK" >/dev/null || fail "archive integrity check failed (unzip -t)"
note "1. archive integrity OK"

# --- 2. debug signature ------------------------------------------------------
APKSIGNER="$(find_sdk_tool apksigner || true)"
[ -n "$APKSIGNER" ] || fail "apksigner not found in the Android SDK"
CERTS="$("$APKSIGNER" verify --print-certs "$APK" 2>&1)" \
    || fail "apksigner reports the APK is NOT validly signed"
printf '%s\n' "$CERTS"
if printf '%s\n' "$CERTS" | grep -qi 'Android Debug'; then
    note "2. APK is debug-signed (Android debug key) OK"
else
    fail "APK signer is not the Android debug key (release / identity signer rejected)"
fi

# --- aapt badging for the remaining checks -----------------------------------
AAPT="$(find_sdk_tool aapt2 || find_sdk_tool aapt || true)"
[ -n "$AAPT" ] || fail "aapt/aapt2 not found in the Android SDK"
# Dump badging to a file; python reads it via argv (stdin carries the program).
BADGING_FILE="${OUTPUT_DIR:-/tmp}/aapt-badging.txt"
"$AAPT" dump badging "$APK" > "$BADGING_FILE" 2>/dev/null || true

# --- 3. application id match (optional) --------------------------------------
PKG="$(sed -n "s/^package: name='\([^']*\)'.*/\1/p" "$BADGING_FILE" | head -1)"
if [ -n "${APPLICATION_ID:-}" ]; then
    [ "$PKG" = "$APPLICATION_ID" ] || fail "package '$PKG' != expected application_id '$APPLICATION_ID'"
    note "3. application id matches ($PKG) OK"
else
    note "3. application id: ${PKG:-unknown} (no expected value to match)"
fi

# --- 4. record bundle metadata (same shape as the iOS path) ------------------
python3 - "$BADGING_FILE" "${OUTPUT_DIR:-}" <<'PYEOF'
import json, re, sys
data = open(sys.argv[1], encoding="utf-8", errors="replace").read()
def find(pat, default=None):
    m = re.search(pat, data)
    return m.group(1) if m else default
abis = re.findall(r"native-code: (.+)", data)
arch = re.findall(r"'([^']+)'", abis[0]) if abis else None
record = {
    "bundle_id": find(r"package: name='([^']*)'"),
    "app_name": find(r"application-label:'([^']*)'"),
    "version": find(r"versionName='([^']*)'"),
    "build": find(r"versionCode='([^']*)'"),
    "executable": None,
    "minimum_os": find(r"sdkVersion:'([^']*)'"),
    "architectures": arch,
}
print("4. bundle metadata:", json.dumps(record))
out = sys.argv[2]
if out:
    with open(out + "/app-info.json", "w") as f:
        json.dump(record, f, indent=2)
PYEOF

# --- 5. SHA-256 --------------------------------------------------------------
DIGEST="$(sha256sum "$APK" | awk '{print $1}')"
note "5. SHA-256: $DIGEST"

echo "VERIFY PASS: $APK"
echo "Signing status: debug-signed (Android debug keystore); installable via sideload."
echo "This is NOT a Play-signed / release build."
