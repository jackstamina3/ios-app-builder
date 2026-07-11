#!/usr/bin/env bash
# Build the device app with code signing disabled. Runs SANDBOXED (env -i).
#
# - All xcodebuild arguments are a Bash array; nothing is string-evaluated.
# - No -sdk flag: -destination "generic/platform=iOS" selects the device
#   platform per-target, while macro/plugin targets still build for macOS.
# - Mandatory no-sign settings are appended AFTER manifest extra settings so
#   they always win; the validator additionally refuses signing keys there.
# - Never retries or switches scheme/config/Xcode on failure - a human (or
#   Claude) must change the committed manifest deliberately.
set -euo pipefail

: "${SOURCE_DIR:?}" "${BUILD_DIR:?}" "${OUTPUT_DIR:?}" "${WORKING_DIR:?}"
: "${CONTAINER_TYPE:?}" "${CONTAINER_PATH:?}" "${SCHEME:?}" "${CONFIGURATION:?}" "${BUILD_ACTION:?}"

cd "$SOURCE_DIR/$WORKING_DIR"

# Adapters may hand environment to the build (e.g. JAVA_HOME for Gradle-driven
# Xcode phases) by writing KEY=VALUE lines to $HOME/build-env. Both stages run
# sandboxed with the same fresh $HOME, so this is the only channel between
# them - values never leave the sandbox.
if [ -f "$HOME/build-env" ]; then
    echo "Importing adapter build-env:"
    while IFS= read -r line; do
        case "$line" in
            [A-Za-z_]*=*)
                echo "  $line"
                export "${line?}"
                ;;
        esac
    done < "$HOME/build-env"
fi

if [ ! -e "$CONTAINER_PATH" ]; then
    echo "ERROR: declared container does not exist after bootstrap: $CONTAINER_PATH" >&2
    exit 1
fi

if [ "$CONTAINER_TYPE" = "workspace" ]; then
    cflags=(-workspace "$CONTAINER_PATH")
else
    cflags=(-project "$CONTAINER_PATH")
fi

# The declared scheme must exist and be visible to command-line Xcode.
xcodebuild "${cflags[@]}" -list -json > "$BUILD_DIR/xcodebuild-list.json"
python3 - "$BUILD_DIR/xcodebuild-list.json" "$SCHEME" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
root = data.get("workspace") or data.get("project") or {}
schemes = root.get("schemes") or []
if sys.argv[2] not in schemes:
    print(f"ERROR: scheme {sys.argv[2]!r} not found. Available schemes: {schemes}", file=sys.stderr)
    sys.exit(1)
print(f"Scheme OK: {sys.argv[2]}")
PYEOF

args=(
    "${cflags[@]}"
    -scheme "$SCHEME"
    -configuration "$CONFIGURATION"
    -destination "generic/platform=iOS"
    -derivedDataPath "$BUILD_DIR/DerivedData"
    -resultBundlePath "$BUILD_DIR/Build.xcresult"
    -skipMacroValidation
    -skipPackagePluginValidation
    -showBuildTimingSummary
)

if [ "$BUILD_ACTION" = "archive" ]; then
    args+=(-archivePath "$BUILD_DIR/App.xcarchive" clean archive)
else
    args+=(clean build)
fi

# Validated extra build settings from the manifest (may be empty).
if [ -f "$EXTRA_SETTINGS_FILE" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && args+=("$line")
    done < "$EXTRA_SETTINGS_FILE"
fi

# Mandatory no-sign settings - appended last so they always win.
args+=(
    CODE_SIGNING_ALLOWED=NO
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGN_IDENTITY=
    EXPANDED_CODE_SIGN_IDENTITY=
    DEVELOPMENT_TEAM=
    PROVISIONING_PROFILE=
    PROVISIONING_PROFILE_SPECIFIER=
    COMPILER_INDEX_STORE_ENABLE=NO
)

echo "xcodebuild argument vector:"
printf '  %q\n' "${args[@]}"

set -o pipefail
xcodebuild "${args[@]}" 2>&1 | tee "$OUTPUT_DIR/xcodebuild.log"

# Locate the built app bundle.
if [ "$BUILD_ACTION" = "archive" ]; then
    products_dir="$BUILD_DIR/App.xcarchive/Products/Applications"
else
    products_dir="$BUILD_DIR/DerivedData/Build/Products/${CONFIGURATION}-iphoneos"
fi

apps=()
while IFS= read -r -d '' app; do apps+=("$app"); done \
    < <(find "$products_dir" -maxdepth 1 -name '*.app' -print0 2>/dev/null)

selected=""
if [ "${#apps[@]}" -eq 1 ]; then
    selected="${apps[0]}"
elif [ "${#apps[@]}" -gt 1 ] && [ -n "$EXPECTED_APP_BUNDLE" ]; then
    for app in "${apps[@]}"; do
        if [ "$(basename "$app")" = "$EXPECTED_APP_BUNDLE" ]; then
            selected="$app"
            break
        fi
    done
fi

if [ -z "$selected" ]; then
    echo "ERROR: expected exactly one app bundle (or output.expected_app_bundle to disambiguate)." >&2
    echo "Found in $products_dir:" >&2
    printf '  %s\n' "${apps[@]:-none}" >&2
    exit 1
fi
if [ -n "$EXPECTED_APP_BUNDLE" ] && [ "$(basename "$selected")" != "$EXPECTED_APP_BUNDLE" ]; then
    echo "ERROR: built app $(basename "$selected") does not match expected_app_bundle $EXPECTED_APP_BUNDLE" >&2
    exit 1
fi

echo "Built app bundle: $selected"
mkdir -p "$BUILD_DIR/package/Payload"
cp -R "$selected" "$BUILD_DIR/package/Payload/"
printf '%s\n' "$(basename "$selected")" > "$OUTPUT_DIR/app-bundle-name.txt"
