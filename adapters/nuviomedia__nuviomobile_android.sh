#!/usr/bin/env bash
# Android adapter for NuvioMedia/NuvioMobile (Kotlin/Compose Multiplatform).
# Separate from the iOS adapter because JDK discovery differs (Linux runner,
# no macOS /usr/libexec/java_home) and the Gradle target is the Android app
# module, not the Xcode-driven framework phase.
#
# Runs SANDBOXED (env -i). run_sandboxed.sh forwards the workflow's selected
# JAVA_HOME and the runner's ANDROID_HOME into the sandbox; this adapter
# re-exports them to the build stage via $HOME/build-env and prepares:
#   - local.properties (required by :composeApp:generateRuntimeConfigs, same as
#     iOS) with the sideload "full" distribution and the SDK location.
#   - a memory-fit ~/.gradle/gradle.properties (upstream asks 12-16 GB; GitHub
#     ubuntu runners have ~16 GB, and the Android build has no Kotlin/Native
#     heap, so modest heaps are safe and avoid OOM).
# Target output: :androidApp:assembleFullDebug -> a debug-keystore-signed,
# sideloadable APK (com.nuviodebug.com). No release/upload keystore is used.
set -euo pipefail

: "${SOURCE_DIR:?}" "${HOME:?}" "${WORKING_DIR:=.}"

ROOT="$SOURCE_DIR/$WORKING_DIR"

# 1. JDK: forwarded from the workflow's "Select JDK for Gradle" step.
if [ -z "${JAVA_HOME:-}" ] || [ ! -x "$JAVA_HOME/bin/java" ]; then
    echo "ERROR: JAVA_HOME not usable inside the sandbox: '${JAVA_HOME:-}'" >&2
    exit 1
fi
echo "JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version 2>&1 | head -2

# 2. Android SDK: forwarded from the runner environment.
ANDROID_SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [ -z "$ANDROID_SDK" ] || [ ! -d "$ANDROID_SDK" ]; then
    echo "ERROR: Android SDK not found (ANDROID_HOME/ANDROID_SDK_ROOT): '${ANDROID_SDK}'" >&2
    exit 1
fi
echo "ANDROID_SDK=$ANDROID_SDK"

# 3. Memory-fit Gradle/Kotlin. User-home gradle.properties override the
#    project's 12-16 GB dev-machine settings.
mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx5g -XX:MaxMetaspaceSize=1536m -Dfile.encoding=UTF-8
kotlin.daemon.jvmargs=-Xmx3g
org.gradle.workers.max=3
EOF

# 4. local.properties: :composeApp:generateRuntimeConfigs declares it a
#    REQUIRED @InputFile (upstream developers always have this git-ignored
#    file). Provide the SDK location and select the official sideload flavor.
#    Backend values (Supabase/Sentry/Trakt) default to empty; no secrets needed.
cat > "$ROOT/local.properties" <<EOF
sdk.dir=$ANDROID_SDK
NUVIO_ANDROID_DISTRIBUTION=full
EOF

# 5. Compatibility patch (generic, self-detecting): Compose Multiplatform's
#    strict resource-key validation rejects any duplicated <string name="...">.
#    An upstream translation update once duplicated keys in
#    composeApp/src/commonMain/composeResources/values-it/strings.xml; keep the
#    first occurrence of every key and drop later ones. No-op when there are no
#    duplicates (the fixed releases).
STRINGS_IT="$ROOT/composeApp/src/commonMain/composeResources/values-it/strings.xml"
if [ -f "$STRINGS_IT" ]; then
    python3 - "$STRINGS_IT" <<'PYEOF'
import re
import sys

path = sys.argv[1]
key_re = re.compile(r'<string\s+name="([^"]+)"')
with open(path, encoding="utf-8") as f:
    lines = f.readlines()
seen = set()
out = []
removed = []
for line in lines:
    m = key_re.search(line)
    if m:
        key = m.group(1)
        if key in seen:
            removed.append(key)
            continue
        seen.add(key)
    out.append(line)
if removed:
    with open(path, "w", encoding="utf-8") as f:
        f.writelines(out)
    print(f"Patched {path}: removed {len(removed)} duplicate key(s): {removed}")
else:
    print(f"No duplicate string keys in {path}; nothing to patch")
PYEOF
fi

# 6. Hand the build stage its environment (sourced by scripts/build_apk.sh
#    from $HOME/build-env).
cat > "$HOME/build-env" <<EOF
JAVA_HOME=$JAVA_HOME
ANDROID_HOME=$ANDROID_SDK
ANDROID_SDK_ROOT=$ANDROID_SDK
NUVIO_ANDROID_DISTRIBUTION=full
GRADLE_OPTS=-Dorg.gradle.daemon=false -Dfile.encoding=UTF-8
EOF

# 7. Cheap early check: prove the JDK + Gradle wrapper work before the build.
cd "$ROOT"
chmod +x ./gradlew 2>/dev/null || true
export JAVA_HOME ANDROID_HOME="$ANDROID_SDK" ANDROID_SDK_ROOT="$ANDROID_SDK"
./gradlew --version
