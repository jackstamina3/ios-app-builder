#!/usr/bin/env bash
# Run a builder script under env -i with a fixed allowlist environment.
#
# Everything that executes untrusted source code (dependency bootstrap,
# xcodebuild and its run-script phases, the probe's xcodebuild -list) goes
# through this wrapper. GITHUB_TOKEN, GH_TOKEN, ACTIONS_RUNTIME_TOKEN,
# ACTIONS_RESULTS_URL and every other Actions variable are NOT in the
# allowlist and therefore never visible to the source tree.
#
# HOME points at an empty per-run directory, so dependency managers
# (CocoaPods trunk, Gradle, Kotlin/Native konan, SwiftPM caches) stay isolated
# from the runner image's real HOME. GEM_HOME/BUNDLE_PATH keep Ruby installs
# out of the system gem directory (no sudo, ever).
set -euo pipefail

: "${SAFE_HOME:?}" "${SOURCE_DIR:?}" "${BUILD_DIR:?}" "${OUTPUT_DIR:?}" "${BUILDER_DIR:?}"
: "${RUNNER_TEMP:?}" "${DEVELOPER_DIR:?}"

SCRIPT="$1"
if [ ! -f "$BUILDER_DIR/$SCRIPT" ]; then
    echo "::error::sandboxed script not found: $SCRIPT" >&2
    exit 1
fi

mkdir -p "$SAFE_HOME" "$RUNNER_TEMP/tmp" "$SAFE_HOME/gems" "$SAFE_HOME/bundle"

exec env -i \
    PATH="$PATH" \
    HOME="$SAFE_HOME" \
    TMPDIR="$RUNNER_TEMP/tmp" \
    USER="runner" \
    LOGNAME="runner" \
    SHELL="/bin/bash" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    CI="1" \
    DEVELOPER_DIR="$DEVELOPER_DIR" \
    BUILDER_DIR="$BUILDER_DIR" \
    SOURCE_DIR="$SOURCE_DIR" \
    BUILD_DIR="$BUILD_DIR" \
    OUTPUT_DIR="$OUTPUT_DIR" \
    SOURCE_REPOSITORY="${SOURCE_REPOSITORY:-}" \
    SOURCE_REF="${SOURCE_REF:-}" \
    EXPECTED_SHA="${EXPECTED_SHA:-}" \
    WORKING_DIR="${WORKING_DIR:-.}" \
    CONTAINER_TYPE="${CONTAINER_TYPE:-}" \
    CONTAINER_PATH="${CONTAINER_PATH:-}" \
    SCHEME="${SCHEME:-}" \
    CONFIGURATION="${CONFIGURATION:-}" \
    BUILD_ACTION="${BUILD_ACTION:-}" \
    BOOTSTRAP_KIND="${BOOTSTRAP_KIND:-none}" \
    ADAPTER_PATH="${ADAPTER_PATH:-}" \
    EXTRA_SETTINGS_FILE="${EXTRA_SETTINGS_FILE:-/dev/null}" \
    EXPECTED_APP_BUNDLE="${EXPECTED_APP_BUNDLE:-}" \
    GEM_HOME="$SAFE_HOME/gems" \
    BUNDLE_PATH="$SAFE_HOME/bundle" \
    /bin/bash --noprofile --norc "$BUILDER_DIR/$SCRIPT"
