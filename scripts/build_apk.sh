#!/usr/bin/env bash
# Build an Android APK with Gradle. Runs SANDBOXED (env -i via run_sandboxed.sh)
# because it executes the untrusted source tree's Gradle build.
#
# The output is whatever the declared gradle_tasks produce. For the debug
# variant that is a debug-keystore-signed, installable APK - the intended,
# documented Android output, distinct from the iOS "unsigned / never
# installable" model. Adapters hand JAVA_HOME / ANDROID_HOME / GRADLE_OPTS to
# this stage by writing KEY=VALUE lines into $HOME/build-env (the same channel
# the iOS build stage uses).
set -euo pipefail

: "${SOURCE_DIR:?}" "${OUTPUT_DIR:?}" "${WORKING_DIR:?}"
: "${GRADLE_TASKS:?}" "${OUTPUT_APK:?}"

cd "$SOURCE_DIR/$WORKING_DIR"

# Import adapter-provided environment (JAVA_HOME, ANDROID_HOME, GRADLE_OPTS...).
# Both stages run sandboxed with the same fresh $HOME, so this is the only
# channel between them; values never leave the sandbox.
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

# Gradle needs a JDK; the Android Gradle plugin needs the SDK.
: "${JAVA_HOME:?JAVA_HOME must be provided (via adapter build-env) for the Gradle build}"
if [ -z "${ANDROID_HOME:-}" ] && [ -z "${ANDROID_SDK_ROOT:-}" ]; then
    echo "ERROR: neither ANDROID_HOME nor ANDROID_SDK_ROOT is set" >&2
    exit 1
fi
"$JAVA_HOME/bin/java" -version 2>&1 | head -2

# Split the validated, space-separated task list into an array (each task name
# is validated by the manifest validator and contains no spaces).
tasks=()
read -r -a tasks <<< "$GRADLE_TASKS"
if [ "${#tasks[@]}" -eq 0 ]; then
    echo "ERROR: no gradle tasks to run" >&2
    exit 1
fi

# Translate validated extra_build_settings into -P Gradle properties.
prop_args=()
if [ -f "${EXTRA_SETTINGS_FILE:-/dev/null}" ]; then
    while IFS= read -r line; do
        [ -n "$line" ] && prop_args+=("-P$line")
    done < "${EXTRA_SETTINGS_FILE:-/dev/null}"
fi

chmod +x ./gradlew 2>/dev/null || true

echo "Gradle tasks: ${tasks[*]}"
set -o pipefail
./gradlew --no-daemon --console=plain --stacktrace \
    "${tasks[@]}" "${prop_args[@]}" 2>&1 | tee "$OUTPUT_DIR/gradle.log"

# Locate the built APK via the declared glob (fixed directory + filename
# pattern). The validator guarantees OUTPUT_APK is a safe relative path.
apk_dir="$(dirname "$OUTPUT_APK")"
apk_pat="$(basename "$OUTPUT_APK")"
matches=()
while IFS= read -r -d '' f; do matches+=("$f"); done \
    < <(find "$apk_dir" -maxdepth 1 -name "$apk_pat" -type f -print0 2>/dev/null)

if [ "${#matches[@]}" -eq 0 ]; then
    echo "ERROR: no APK matched $OUTPUT_APK after the build" >&2
    exit 1
fi
if [ "${#matches[@]}" -gt 1 ]; then
    echo "ERROR: multiple APKs matched $OUTPUT_APK (narrow the glob):" >&2
    printf '  %s\n' "${matches[@]}" >&2
    exit 1
fi

apk="${matches[0]}"
apk_abs="$(cd "$(dirname "$apk")" && pwd)/$(basename "$apk")"
echo "Built APK: $apk_abs"
printf '%s\n' "$apk_abs" > "$OUTPUT_DIR/apk-src-path.txt"
