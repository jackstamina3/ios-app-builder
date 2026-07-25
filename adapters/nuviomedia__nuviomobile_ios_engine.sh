#!/usr/bin/env bash
# iOS adapter for NuvioMedia/NuvioMobile 0.3.x+ ("Nuvio Engine" era).
#
# Separate from adapters/nuviomedia__nuviomobile.sh (which serves the 0.2.x
# manifests and stays untouched so those historical builds remain reproducible).
#
# Pinned layout facts (verified at commit b1c9d084, tag 0.3.1):
#   - Same Xcode-driven KMP flow as 0.2.x: the iosApp.xcodeproj run-script phase
#     executes `./gradlew :composeApp:embedAndSignAppleFrameworkForXcode` from
#     the repo root, honouring $JAVA_HOME (Gradle 9.4.x needs JDK 17+).
#   - MPVKit remains a submodule of prebuilt binary xcframeworks (d5cf091c).
#   - NEW IN 0.3.x: when NUVIO_IOS_DISTRIBUTION=full, composeApp/build.gradle.kts
#     cinterops against an EXTERNAL, locally built XCFramework at
#     rootProject/../nuvio-engine/platform/apple/NuvioEngine.xcframework and
#     hard-fails configuration with "Build the local Nuvio Engine Apple
#     XCFramework before compiling iOS Full." if libCNuvioEngine.a is absent.
#     nuvio-engine is NOT a submodule and is not fetched by the build, so this
#     adapter clones and builds it. The check runs for BOTH ios targets
#     (iosArm64 -> ios-arm64, iosSimulatorArm64 -> ios-arm64_x86_64-simulator),
#     so both slices must exist even though only the device slice is archived.
#   - The engine is public GPL-3.0 source (NuvioMedia/nuvio-engine), pinned
#     below to a full 40-char SHA for reproducibility; its own script downloads
#     checksum-verified boost / libtorrent / OpenSSL sources and builds
#     macOS + iOS + iOS-simulator slices with CMake/Ninja, then assembles the
#     xcframework with `xcodebuild -create-xcframework`.
#   - Upstream gradle.properties requests 12-16 GB JVM heaps (dev-machine
#     sizing); GitHub's arm64 macOS runners have ~7 GB RAM, so user-level
#     gradle.properties (which override project ones) scale that down. For the
#     same reason NUVIO_BUILD_JOBS is lowered from its default of 8: eight
#     parallel C++ (libtorrent) compiles would risk OOM on this runner.
#   - Supabase/Sentry config values default to empty strings when absent;
#     no secrets are required to build.
set -euo pipefail

: "${SOURCE_DIR:?}" "${HOME:?}"

# Pinned engine source (tag v0.1.0). Full SHA, per the repo's pinning rule.
ENGINE_REPOSITORY="https://github.com/NuvioMedia/nuvio-engine.git"
ENGINE_SHA="86f0865472034e53d14963d88a5e0d48dc033df0"

# composeApp/build.gradle.kts resolves the framework as
# rootProject.file("../nuvio-engine/..."), i.e. a SIBLING of the source tree.
ENGINE_DIR="$(dirname "$SOURCE_DIR")/nuvio-engine"

# 1. Locate a JDK (>=17 for Gradle 9). The runner image ships Temurin JDKs;
#    under env -i the JAVA_HOME_* shortcuts are absent, so ask java_home.
JAVA_HOME=""
for v in 21 17; do
    if JAVA_HOME="$(/usr/libexec/java_home -v "$v" 2>/dev/null)"; then
        [ -n "$JAVA_HOME" ] && break
    fi
done
if [ -z "$JAVA_HOME" ]; then
    echo "ERROR: no JDK >=17 found via /usr/libexec/java_home" >&2
    /usr/libexec/java_home -V >&2 || true
    exit 1
fi
echo "JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version 2>&1 | head -2

# 2. Memory-fit Gradle/Kotlin for the ~7 GB runner. User-home
#    gradle.properties take precedence over the project's 12-16 GB settings.
mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx3072m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8
kotlin.daemon.jvmargs=-Xmx2048m
kotlin.native.jvmArgs=-Xmx3072m
org.gradle.workers.max=3
EOF

# 3. local.properties is a REQUIRED @InputFile of :composeApp
#    :generateRuntimeConfigs (upstream developers always have this git-ignored
#    file). Machine-local config, not app source. Backend values (Supabase /
#    Sentry / Trakt) resolve to empty strings via runtimeConfigValue's fallback,
#    which is acceptable for a reproducible unsigned build.
cat > "$SOURCE_DIR/local.properties" <<'EOF'
NUVIO_IOS_DISTRIBUTION=full
EOF

# 4. Fetch the pinned Nuvio Engine source next to the app tree and verify the
#    checkout really is the pinned commit (same discipline as clone_source.sh).
echo "Cloning nuvio-engine @ $ENGINE_SHA -> $ENGINE_DIR"
rm -rf "$ENGINE_DIR"
mkdir -p "$ENGINE_DIR"
git init -q "$ENGINE_DIR"
git -C "$ENGINE_DIR" remote add origin "$ENGINE_REPOSITORY"
if ! git -C "$ENGINE_DIR" fetch --depth=1 origin "$ENGINE_SHA" 2>/dev/null; then
    echo "Direct SHA fetch unavailable; fetching default branch"
    git -C "$ENGINE_DIR" fetch --depth=50 origin HEAD
fi
git -C "$ENGINE_DIR" checkout --quiet --detach "$ENGINE_SHA"
ENGINE_ACTUAL="$(git -C "$ENGINE_DIR" rev-parse HEAD)"
if [ "$ENGINE_ACTUAL" != "$ENGINE_SHA" ]; then
    echo "ERROR: nuvio-engine SHA mismatch: expected $ENGINE_SHA got $ENGINE_ACTUAL" >&2
    exit 1
fi
echo "Verified nuvio-engine commit: $ENGINE_ACTUAL"
head -3 "$ENGINE_DIR/LICENSE" || true

# 5. Build the Apple XCFramework (macOS + iOS + iOS-simulator slices). The
#    engine's own script downloads and checksum-verifies boost / libtorrent /
#    OpenSSL, builds each slice with CMake+Ninja, merges static libs with
#    `xcrun libtool`, then runs `xcodebuild -create-xcframework`. Long step.
echo "Building NuvioEngine.xcframework (this is the long part)"
cd "$ENGINE_DIR"
chmod +x scripts/*.sh 2>/dev/null || true
export NUVIO_BUILD_JOBS="${NUVIO_BUILD_JOBS:-3}"
echo "NUVIO_BUILD_JOBS=$NUVIO_BUILD_JOBS"
./scripts/build-apple-xcframework.sh

# 6. Verify both slices the Gradle cinterop check requires actually exist.
XCFRAMEWORK="$ENGINE_DIR/platform/apple/NuvioEngine.xcframework"
missing=0
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    if [ -f "$XCFRAMEWORK/$slice/libCNuvioEngine.a" ]; then
        echo "engine slice OK: $slice"
    else
        echo "ERROR: missing engine slice library: $slice/libCNuvioEngine.a" >&2
        missing=1
    fi
done
if [ "$missing" -ne 0 ]; then
    echo "XCFramework contents:" >&2
    ls -1 "$XCFRAMEWORK" >&2 || true
    exit 1
fi

# 7. Hand the Xcode build stage its environment (sourced by
#    scripts/build_unsigned_app.sh from $HOME/build-env).
cat > "$HOME/build-env" <<EOF
JAVA_HOME=$JAVA_HOME
NUVIO_IOS_DISTRIBUTION=full
KOTLIN_DAEMON_JVMARGS=-Xmx2048m
GRADLE_OPTS=-Xmx1024m -Dfile.encoding=UTF-8
EOF

# 8. Cheap final check: proves the JDK + pinned Gradle distribution work before
#    the expensive xcodebuild stage.
cd "$SOURCE_DIR"
export JAVA_HOME
./gradlew --version
