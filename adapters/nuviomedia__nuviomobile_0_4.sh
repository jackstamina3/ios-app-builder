#!/usr/bin/env bash
# Adapter for NuvioMedia/NuvioMobile 0.4.x (Kotlin/Compose Multiplatform).
#
# Split from adapters/nuviomedia__nuviomobile.sh (the 0.2.x adapter, which stays
# untouched so the committed 0.2.x manifests keep reproducing). Everything that
# adapter did still applies; step 3.6 is the new part.
#
# Pinned layout facts (verified at commit f9ad843b, tag 0.4.4):
#   - iosApp/iosApp.xcodeproj run-script phase executes
#     `./gradlew :composeApp:embedAndSignAppleFrameworkForXcode` from the repo
#     root, using $JAVA_HOME when set (Gradle 9.4.1 needs JDK 17+).
#   - MPVKit is a git submodule consumed as a local Swift package of prebuilt
#     binary xcframeworks - nothing native is compiled from C sources here.
#     Its pin is unchanged from the 0.2.x builds (d5cf091c).
#   - NUVIO_IOS_DISTRIBUTION selects the iosFull/iosAppStore source set;
#     the official sideload releases are the "full" distribution.
#   - Upstream gradle.properties requests 12-16 GB JVM heaps (dev-machine
#     sizing); user-level gradle.properties (which override project ones)
#     scale that down to fit a 7 GB GitHub arm64 runner. The same ceiling is
#     applied on self-hosted Macs: it builds fine and leaves the machine usable.
#   - Supabase/Sentry/Simkl config values default to empty strings when absent;
#     no secrets are required to build.
#   - The tree carries three ORPHAN gitlinks with no .gitmodules entry
#     (libass-android, vendor/TorrServer, vendor/quickjs-kt). clone_source.sh
#     only initializes declared submodule paths, so they stay empty - correct,
#     because none is referenced by the iOS build: quickjs-kt resolves from
#     Maven (io.github.dokar3:quickjs-kt), libass-android and TorrServer are
#     Android-only and unreferenced by any Gradle script.
#   - The 0.2.24 duplicate-key bug in values-it/strings.xml is fixed upstream;
#     0 duplicates exist at this commit across every locale. Step 3.5 is a
#     verified no-op here and is kept only because it is self-detecting.
#   - The 0.2.x version-lag pattern is GONE at this commit: Version.xcconfig
#     reads MARKETING_VERSION=0.4.4 / CURRENT_PROJECT_VERSION=108, matching the
#     git tag. Nothing to patch or caveat.
set -euo pipefail

: "${SOURCE_DIR:?}" "${HOME:?}"

# 1. Locate a JDK (>=17 for Gradle 9). GitHub runner images ship Temurin JDKs;
#    under env -i the JAVA_HOME_* shortcuts are absent, so ask java_home. On a
#    self-hosted Mac a JDK must be installed (e.g. Temurin 21) - the error
#    below says so rather than failing obscurely later inside Gradle.
JAVA_HOME=""
for v in 21 17; do
    if JAVA_HOME="$(/usr/libexec/java_home -v "$v" 2>/dev/null)"; then
        [ -n "$JAVA_HOME" ] && break
    fi
done
if [ -z "$JAVA_HOME" ]; then
    echo "ERROR: no JDK >=17 found via /usr/libexec/java_home" >&2
    echo "Gradle 9.4.1 requires JDK 17 or newer. Install one, e.g.:" >&2
    echo "  brew install --cask temurin@21" >&2
    /usr/libexec/java_home -V >&2 || true
    exit 1
fi
echo "JAVA_HOME=$JAVA_HOME"
"$JAVA_HOME/bin/java" -version 2>&1 | head -2

# 2. Memory-fit Gradle/Kotlin. User-home gradle.properties take precedence over
#    the project's 12-16 GB settings.
mkdir -p "$HOME/.gradle"
cat > "$HOME/.gradle/gradle.properties" <<'EOF'
org.gradle.jvmargs=-Xmx3072m -XX:MaxMetaspaceSize=1024m -Dfile.encoding=UTF-8
kotlin.daemon.jvmargs=-Xmx2048m
kotlin.native.jvmArgs=-Xmx3072m
org.gradle.workers.max=3
EOF

# 3. The composeApp :generateRuntimeConfigs Gradle task declares
#    local.properties as a REQUIRED @InputFile, so Gradle fails validation when
#    it is absent (upstream developers always have this git-ignored file). It
#    is a machine-local config file, not app source; create a minimal one. The
#    backend values (Supabase/Sentry/Simkl) resolve to empty strings via
#    runtimeConfigValue's fallback, which is acceptable for a reproducible
#    unsigned build. NUVIO_IOS_DISTRIBUTION selects the official sideload flavor.
cat > "$SOURCE_DIR/local.properties" <<'EOF'
NUVIO_IOS_DISTRIBUTION=full
EOF

# 3.5. Self-detecting duplicate-resource-key guard, inherited from the 0.2.x
#      adapter. For every <string name="..."> keep the first occurrence and drop
#      later ones. Verified to find nothing at this commit; kept because the bug
#      class (a translation update pasting a block twice) recurred once already
#      and Gradle's error for it is famously unhelpful.
STRINGS_IT="$SOURCE_DIR/composeApp/src/commonMain/composeResources/values-it/strings.xml"
if [ -f "$STRINGS_IT" ]; then
    python3 - "$STRINGS_IT" <<'PYEOF'
import re
import sys

path = sys.argv[1]
key_re = re.compile(r'<string\s+name="([^"]+)"')

with open(path, encoding='utf-8') as f:
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

if not removed:
    print(f"No duplicate string keys found in {path}; nothing to patch", file=sys.stderr)
    sys.exit(0)

with open(path, 'w', encoding='utf-8') as f:
    f.writelines(out)
print(f"Patched {path}: removed {len(removed)} duplicate key(s): {removed}")
PYEOF
fi

# 3.6. NEW AT 0.3.1+: the iOS "full" distribution cinterops against Nuvio
#      Engine, a separate GPL-3.0 C++20/libtorrent repository. composeApp's
#      build script resolves it OUTSIDE the checkout, as a sibling directory:
#
#        rootProject.file("../nuvio-engine/platform/apple/NuvioEngine.xcframework")
#
#      and hard-fails configuration when the slice's static library is missing:
#        check(... "ios-arm64/libCNuvioEngine.a" .isFile) { "Build the local
#        Nuvio Engine Apple XCFramework before compiling iOS Full." }
#
#      It is not a submodule and not in the tree, so it must be staged here.
#      We consume the upstream project's OWN release artifact rather than
#      rebuilding it, because building it from source means compiling OpenSSL
#      3.5.7 + Boost 1.86 + libtorrent 2.0.12 across three slices.
#
#      Provenance, verified before pinning:
#        - source repo NuvioMedia/nuvio-engine, GPL-3.0, tag v0.1.1
#          (8e98cded89caa11178eb8180d180559f73444d50), whose tree is IDENTICAL
#          to that repo's main HEAD 772f8c05 - the API has not moved since.
#        - the artifact's headers (nuvio_engine.h, export.h) are byte-identical
#          to that pinned source, so the binary's public API provably
#          corresponds to readable GPL source.
#        - all 22 nuvio_engine_* symbols used by P2pStreamingEngine.ios.kt are
#          declared in that header.
#      The download is pinned by SHA-256 and the build fails closed on mismatch.
ENGINE_VERSION="0.1.1"
ENGINE_SHA256="24905c0484b2e5c886c2685ce03e5f5585c3dc6096c65c59948b35be56ae4dc0"
ENGINE_URL="https://github.com/NuvioMedia/nuvio-engine/releases/download/v${ENGINE_VERSION}/nuvio-engine-apple-${ENGINE_VERSION}.zip"

ENGINE_PARENT="$(cd "$SOURCE_DIR/.." && pwd)"
ENGINE_ROOT="$ENGINE_PARENT/nuvio-engine"
ENGINE_APPLE_DIR="$ENGINE_ROOT/platform/apple"
ENGINE_STAGE="$ENGINE_ROOT/.stage"

echo "Staging Nuvio Engine $ENGINE_VERSION XCFramework at $ENGINE_APPLE_DIR"
rm -rf "$ENGINE_ROOT"
mkdir -p "$ENGINE_APPLE_DIR" "$ENGINE_STAGE"

ENGINE_ZIP="$ENGINE_STAGE/nuvio-engine-apple-${ENGINE_VERSION}.zip"
curl --fail --location --silent --show-error --retry 3 --retry-delay 5 \
    --output "$ENGINE_ZIP" "$ENGINE_URL"

ACTUAL_SHA="$(shasum -a 256 "$ENGINE_ZIP" | cut -d' ' -f1)"
if [ "$ACTUAL_SHA" != "$ENGINE_SHA256" ]; then
    echo "ERROR: Nuvio Engine artifact SHA-256 mismatch" >&2
    echo "  expected: $ENGINE_SHA256" >&2
    echo "  actual:   $ACTUAL_SHA" >&2
    exit 1
fi
echo "Nuvio Engine artifact SHA-256 verified: $ACTUAL_SHA"

unzip -q "$ENGINE_ZIP" -d "$ENGINE_STAGE"
UNPACKED="$ENGINE_STAGE/nuvio-engine-apple-${ENGINE_VERSION}/NuvioEngine.xcframework"
if [ ! -d "$UNPACKED" ]; then
    echo "ERROR: NuvioEngine.xcframework not found in the artifact" >&2
    find "$ENGINE_STAGE" -maxdepth 3 >&2
    exit 1
fi
mv "$UNPACKED" "$ENGINE_APPLE_DIR/NuvioEngine.xcframework"

# Keep the GPL license sidecars next to the binary they cover.
mkdir -p "$ENGINE_APPLE_DIR/licenses"
find "$ENGINE_STAGE/nuvio-engine-apple-${ENGINE_VERSION}" -maxdepth 1 -type f \
    \( -name '*LICENSE*' -o -name '*COPYING*' -o -name 'THIRD_PARTY_NOTICES.md' \) \
    -exec cp {} "$ENGINE_APPLE_DIR/licenses/" \;

# Assert exactly what composeApp/build.gradle.kts checks for, so a bad artifact
# fails here with a clear message instead of inside Gradle configuration.
for slice in ios-arm64 ios-arm64_x86_64-simulator; do
    LIB="$ENGINE_APPLE_DIR/NuvioEngine.xcframework/$slice/libCNuvioEngine.a"
    if [ ! -f "$LIB" ]; then
        echo "ERROR: missing engine slice library: $LIB" >&2
        exit 1
    fi
    echo "  verified slice $slice: $(shasum -a 256 "$LIB" | cut -d' ' -f1)"
done
rm -rf "$ENGINE_STAGE"

# 4. Hand the Xcode build stage its environment (sourced by
#    scripts/build_unsigned_app.sh from $HOME/build-env).
cat > "$HOME/build-env" <<EOF
JAVA_HOME=$JAVA_HOME
NUVIO_IOS_DISTRIBUTION=full
KOTLIN_DAEMON_JVMARGS=-Xmx2048m
GRADLE_OPTS=-Xmx1024m -Dfile.encoding=UTF-8
EOF

# 5. Cheap early verification: downloads the pinned Gradle distribution and
#    proves the JDK works before the expensive xcodebuild stage.
cd "$SOURCE_DIR"
export JAVA_HOME
./gradlew --version
