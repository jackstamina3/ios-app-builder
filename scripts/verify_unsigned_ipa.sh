#!/usr/bin/env bash
# Verify an unsigned IPA. Fails unless every applicable check passes.
#
# Usage: verify_unsigned_ipa.sh /path/to/App.unsigned.ipa
#
# Runs fully on macOS (CI build job and local Macs). On other platforms the
# Mach-O and codesign checks are skipped WITH AN EXPLICIT WARNING - a Linux
# pass is a structural check, not a full verification.
#
# Checks:
#  1. archive integrity (unzip -t)
#  2. exactly one top-level Payload/ directory
#  3. exactly one main .app bundle
#  4. main executable (and nested Mach-Os) built for platform IOS, not
#     IOSSIMULATOR                                    [macOS only]
#  5. no _CodeSignature, embedded.mobileprovision, CodeResources, or SC_Info
#  6. no Mach-O carries an identity-bearing signature: unsigned or ad-hoc
#     with no Authority and no TeamIdentifier         [macOS only]
#  7. build log records no signing identity           [when log available]
#  8. Info.plist is readable
#  9. bundle metadata recorded (app-info.json when OUTPUT_DIR is set)
# 10. SHA-256 digest printed
set -euo pipefail

IPA="${1:?usage: verify_unsigned_ipa.sh IPA_PATH}"
test -f "$IPA"

IS_MACOS=no
[ "$(uname -s)" = "Darwin" ] && IS_MACOS=yes

fail() { echo "VERIFY FAIL: $1" >&2; exit 1; }
note() { echo "VERIFY: $1"; }

# --- 1. archive integrity -------------------------------------------------
unzip -tqq "$IPA" >/dev/null || fail "archive integrity check failed (unzip -t)"
note "1. archive integrity OK"

LISTING="$(unzip -Z1 "$IPA")"

# --- 2. single top-level Payload -------------------------------------------
TOPLEVEL="$(printf '%s\n' "$LISTING" | cut -d/ -f1 | sort -u)"
[ "$TOPLEVEL" = "Payload" ] || fail "unexpected top-level entries: $(printf '%s' "$TOPLEVEL" | tr '\n' ' ')"
note "2. single top-level Payload/ OK"

# --- 3. exactly one main app ------------------------------------------------
APPS="$(printf '%s\n' "$LISTING" | grep -oE '^Payload/[^/]+\.app/' | sort -u)"
APP_COUNT="$(printf '%s\n' "$APPS" | grep -c . || true)"
[ "$APP_COUNT" -eq 1 ] || fail "expected exactly one Payload/*.app, found $APP_COUNT"
APP_REL="${APPS%/}"
note "3. single app bundle OK ($APP_REL)"

# --- 5. no signing material in the listing ---------------------------------
if printf '%s\n' "$LISTING" | grep -E '(_CodeSignature/|/embedded\.mobileprovision$|/SC_Info/|/CodeResources$)' >/dev/null; then
    printf '%s\n' "$LISTING" | grep -E '(_CodeSignature/|/embedded\.mobileprovision$|/SC_Info/|/CodeResources$)' >&2
    fail "signing material remains in the archive"
fi
note "5. no signing material in archive OK"

# --- extract for content checks ---------------------------------------------
EXTRACT_DIR="$(mktemp -d)"
trap 'rm -rf "$EXTRACT_DIR"' EXIT
unzip -qq "$IPA" -d "$EXTRACT_DIR"
APP_DIR="$EXTRACT_DIR/$APP_REL"
INFO_PLIST="$APP_DIR/Info.plist"

# --- 8. Info.plist readable (python plistlib handles binary plists) --------
EXECUTABLE="$(python3 - "$INFO_PLIST" <<'PYEOF'
import plistlib, sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
print(info.get("CFBundleExecutable", ""))
PYEOF
)"
[ -n "$EXECUTABLE" ] || fail "Info.plist unreadable or missing CFBundleExecutable"
MAIN_EXE="$APP_DIR/$EXECUTABLE"
test -f "$MAIN_EXE" || fail "declared executable missing: $EXECUTABLE"
note "8. Info.plist readable OK (executable: $EXECUTABLE)"

is_macho() {
    local magic
    magic="$(xxd -p -l 4 "$1" 2>/dev/null || true)"
    case "$magic" in
        feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
        *) return 1 ;;
    esac
}

collect_machos() {
    while IFS= read -r -d '' f; do
        is_macho "$f" && printf '%s\0' "$f"
    done < <(find "$APP_DIR" -type f -print0)
}

check_platform() {
    # Require platform IOS; reject IOSSIMULATOR. vtool preferred, otool fallback
    # (platform 2 = iOS, 7 = iOS simulator; LC_VERSION_MIN_IPHONEOS accepted
    # for very old deployment targets).
    local exe="$1" out
    if command -v vtool >/dev/null 2>&1; then
        out="$(vtool -show-build "$exe" 2>/dev/null || true)"
        printf '%s' "$out" | grep -qE 'platform[[:space:]]+IOSSIMULATOR' && return 1
        printf '%s' "$out" | grep -qE 'platform[[:space:]]+IOS([[:space:]]|$)' && return 0
    fi
    if command -v otool >/dev/null 2>&1; then
        out="$(otool -l "$exe" 2>/dev/null || true)"
        printf '%s' "$out" | grep -qE '^[[:space:]]*platform[[:space:]]+7([[:space:]]|$)' && return 1
        printf '%s' "$out" | grep -qE '^[[:space:]]*platform[[:space:]]+2([[:space:]]|$)' && return 0
        printf '%s' "$out" | grep -q 'LC_VERSION_MIN_IPHONEOS' && return 0
    fi
    return 2
}

# --- 4. device platform ------------------------------------------------------
if [ "$IS_MACOS" = yes ]; then
    if check_platform "$MAIN_EXE"; then
        note "4. main executable is a device (platform IOS) binary OK"
    else
        rc=$?
        [ "$rc" -eq 1 ] && fail "main executable is a SIMULATOR binary"
        fail "could not determine platform of main executable"
    fi
    while IFS= read -r -d '' mo; do
        case "$mo" in
            *.framework/*|*.appex/*|*.dylib)
                if ! check_platform "$mo"; then
                    rc=$?
                    [ "$rc" -eq 1 ] && fail "nested simulator binary: ${mo#"$APP_DIR"/}"
                fi
                ;;
        esac
    done < <(collect_machos)
else
    echo "VERIFY WARNING: 4. platform check SKIPPED (requires macOS otool/vtool)" >&2
fi

# --- 6. no identity-bearing signatures ---------------------------------------
if [ "$IS_MACOS" = yes ] && command -v codesign >/dev/null 2>&1; then
    while IFS= read -r -d '' mo; do
        info="$(codesign -dvv -- "$mo" 2>&1 || true)"
        case "$info" in
            *"not signed at all"*) continue ;;
        esac
        if printf '%s' "$info" | grep -q -e '^Authority=' -e 'TeamIdentifier=[A-Z0-9]'; then
            printf '%s\n' "$info" >&2
            fail "identity-bearing signature on ${mo#"$APP_DIR"/}"
        fi
    done < <(collect_machos)
    note "6. all Mach-Os unsigned or ad-hoc (no Authority/TeamIdentifier) OK"
else
    echo "VERIFY WARNING: 6. codesign check SKIPPED (requires macOS)" >&2
fi

# --- 7. build log used no signing identity -----------------------------------
BUILD_LOG="${OUTPUT_DIR:-}/xcodebuild.log"
if [ -n "${OUTPUT_DIR:-}" ] && [ -f "$BUILD_LOG" ]; then
    if grep -E 'Signing Identity:[[:space:]]+"' "$BUILD_LOG" >/dev/null; then
        fail "build log records a signing identity"
    fi
    if grep -E 'Provisioning Profile:[[:space:]]+"' "$BUILD_LOG" >/dev/null; then
        fail "build log records a provisioning profile"
    fi
    note "7. build log records no signing identity OK"
else
    echo "VERIFY WARNING: 7. build-log check SKIPPED (no xcodebuild.log available)" >&2
fi

# --- 9. record bundle metadata ------------------------------------------------
ARCHS=""
if command -v lipo >/dev/null 2>&1; then
    ARCHS="$(lipo -archs "$MAIN_EXE" 2>/dev/null || true)"
fi
python3 - "$INFO_PLIST" "$ARCHS" "${OUTPUT_DIR:-}" <<'PYEOF'
import json, plistlib, sys
with open(sys.argv[1], "rb") as f:
    info = plistlib.load(f)
record = {
    "bundle_id": info.get("CFBundleIdentifier"),
    "app_name": info.get("CFBundleDisplayName") or info.get("CFBundleName"),
    "version": info.get("CFBundleShortVersionString"),
    "build": info.get("CFBundleVersion"),
    "executable": info.get("CFBundleExecutable"),
    "minimum_os": info.get("MinimumOSVersion"),
    "architectures": sys.argv[2].split() if sys.argv[2] else None,
}
print("9. bundle metadata:", json.dumps(record))
if sys.argv[3]:
    with open(sys.argv[3] + "/app-info.json", "w") as f:
        json.dump(record, f, indent=2)
PYEOF

# --- 10. SHA-256 ---------------------------------------------------------------
if command -v shasum >/dev/null 2>&1; then
    DIGEST="$(shasum -a 256 "$IPA" | awk '{print $1}')"
else
    DIGEST="$(sha256sum "$IPA" | awk '{print $1}')"
fi
note "10. SHA-256: $DIGEST"

echo "VERIFY PASS: $IPA"
echo "Signing status: unsigned (no identity, no embedded provisioning profile)."
echo "This IPA is NOT installable as-is; it requires a valid downstream signing step."
