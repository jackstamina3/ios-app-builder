#!/usr/bin/env bash
# Adapter for NuvioMedia/NuvioMobile (Kotlin/Compose Multiplatform).
# Pinned layout facts (verified at commit 4e17faa5, tag 0.2.21):
#   - iosApp/iosApp.xcodeproj run-script phase executes
#     `./gradlew :composeApp:embedAndSignAppleFrameworkForXcode` from the repo
#     root, using $JAVA_HOME when set (Gradle 9.4.x needs JDK 17+).
#   - MPVKit is a git submodule consumed as a local Swift package of prebuilt
#     binary xcframeworks - nothing native is compiled from C sources here.
#   - NUVIO_IOS_DISTRIBUTION selects the iosFull/iosAppStore source set;
#     the official sideload releases are the "full" distribution.
#   - Upstream gradle.properties requests 12-16 GB JVM heaps (dev-machine
#     sizing); GitHub's arm64 macOS runners have ~7 GB RAM, so user-level
#     gradle.properties (which override project ones) scale that down.
#   - Supabase/Sentry config values default to empty strings when absent;
#     no secrets are required to build.
set -euo pipefail

: "${SOURCE_DIR:?}" "${HOME:?}"

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

# 2. Memory-fit Gradle/Kotlin for the 7 GB runner. User-home gradle.properties
#    take precedence over the project's 12-16 GB settings.
mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx3072m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8
kotlin.daemon.jvmargs=-Xmx2048m
kotlin.native.jvmArgs=-Xmx3072m
org.gradle.workers.max=3
EOF

# 3. Hand the Xcode build stage its environment (sourced by
#    scripts/build_unsigned_app.sh from $HOME/build-env).
cat > "$HOME/build-env" <<EOF
JAVA_HOME=$JAVA_HOME
NUVIO_IOS_DISTRIBUTION=full
KOTLIN_DAEMON_JVMARGS=-Xmx2048m
GRADLE_OPTS=-Xmx1024m -Dfile.encoding=UTF-8
EOF

# 4. Cheap early verification: downloads the pinned Gradle distribution and
#    proves the JDK works before the expensive xcodebuild stage.
cd "$SOURCE_DIR"
export JAVA_HOME
./gradlew --version
