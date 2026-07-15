#!/usr/bin/env bash
# Adapter for NuvioMedia/NuvioMobile (Kotlin/Compose Multiplatform).
# Pinned layout facts (verified at commit 4e17faa5, tag 0.2.21; re-verified
# at commit 5230f2b9, tag 0.2.24):
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
#   - KNOWN UPSTREAM BUG at 0.2.24 (5230f2b9): a translation update pasted a
#     whole block of "personal media server" strings into
#     composeApp/src/commonMain/composeResources/values-it/strings.xml a
#     second time, reusing 6 existing key names (addons_appstore_*,
#     settings_content_discovery_addons_description_appstore) with different
#     text. Compose Multiplatform's strict resource-key validation
#     (:composeApp:convertXmlValueResourcesForCommonMain) rejects the file
#     outright, and Gradle reports only the first duplicate it hits per run -
#     the second dispatch of this build hit a *different* one of the 6 after
#     the first was patched, confirming there wasn't just one. Already fixed
#     on upstream's cmp-rewrite branch tip (409a2e9b), which deletes the
#     entire second block. Step 3.5 below does the same thing generically:
#     for every <string name="..."> in that file, keep the first occurrence
#     and drop later ones, whichever keys they are. Verified byte-identical
#     to upstream's actual fixed file for this exact commit. Source-authorized
#     per this session's build request.
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

# 3. The composeApp :generateRuntimeConfigs Gradle task declares
#    local.properties as a REQUIRED @InputFile, so Gradle fails validation when
#    it is absent (upstream developers always have this git-ignored file). It
#    is a machine-local config file, not app source; create a minimal one. The
#    backend values (Supabase/Sentry) resolve to empty strings via
#    runtimeConfigValue's fallback, which is acceptable for a reproducible
#    unsigned build. NUVIO_IOS_DISTRIBUTION selects the official sideload flavor.
cat > "$SOURCE_DIR/local.properties" <<'EOF'
NUVIO_IOS_DISTRIBUTION=full
EOF

# 3.5. Compatibility patch for the known 0.2.24 duplicate-key bug (see header
#      comment). Scoped to one file; for every <string name="..."> keeps the
#      first occurrence and drops later ones. Verified against this exact
#      pinned commit to produce output byte-identical to upstream's own fix.
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
