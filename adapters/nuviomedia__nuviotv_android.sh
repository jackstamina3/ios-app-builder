#!/usr/bin/env bash
# Android adapter for NuvioMedia/NuvioTV (Android-TV app; single-repo Gradle
# project, :app module). Runs SANDBOXED (env -i). run_sandboxed.sh forwards the
# workflow's selected JAVA_HOME and the runner's ANDROID_HOME into the sandbox;
# this adapter re-exports them to the build stage via $HOME/build-env and
# prepares the build so it produces an installable, debug-signed APK with no
# release keystore and no NDK toolchain:
#
#   - CI_USE_DEBUG_SIGNING=true -> the release build variant signs with the auto
#     Android **debug** keystore (app/build.gradle.kts: useDebugReleaseSigning).
#     We build :app:assembleFullRelease because the `debug` buildType is wired
#     to an absent release keystore (../nuviotv.jks) and cannot be used.
#   - DOVI_NATIVE_ENABLED=false in local.properties -> the only native/CMake
#     compile (dovi_bridge, NDK 29) is skipped; ffmpeg/torrserver/libdovi are
#     prebuilt & committed, so no NDK install or submodule is needed.
#   - local.properties also supplies sdk.dir; backend values default to empty.
#
# Result: a debug-keystore-signed, sideloadable *.debug.apk (Android-TV /
# leanback). No release/upload keystore or signing secret is ever used.
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
#    project's larger dev-machine settings.
mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx5g -XX:MaxMetaspaceSize=1536m -Dfile.encoding=UTF-8
kotlin.daemon.jvmargs=-Xmx3g
org.gradle.workers.max=3
EOF

# 4. local.properties: SDK location, keep the DOVI native/CMake path OFF (so no
#    NDK is required), and leave backend keys empty (they default to empty).
cat > "$ROOT/local.properties" <<EOF
sdk.dir=$ANDROID_SDK
DOVI_NATIVE_ENABLED=false
EOF

# 5. Hand the build stage its environment (sourced by scripts/build_apk.sh from
#    $HOME/build-env). CI_USE_DEBUG_SIGNING makes the release variant use the
#    auto debug keystore.
cat > "$HOME/build-env" <<EOF
JAVA_HOME=$JAVA_HOME
ANDROID_HOME=$ANDROID_SDK
ANDROID_SDK_ROOT=$ANDROID_SDK
CI_USE_DEBUG_SIGNING=true
GRADLE_OPTS=-Dorg.gradle.daemon=false -Dfile.encoding=UTF-8
EOF

# 6. Cheap early check: prove the JDK + Gradle wrapper work before the build.
cd "$ROOT"
chmod +x ./gradlew 2>/dev/null || true
export JAVA_HOME ANDROID_HOME="$ANDROID_SDK" ANDROID_SDK_ROOT="$ANDROID_SDK"
./gradlew --version
