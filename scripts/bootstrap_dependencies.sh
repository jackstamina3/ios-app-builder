#!/usr/bin/env bash
# Structured dependency bootstrap. Runs SANDBOXED (env -i via run_sandboxed.sh)
# because every mode executes code from the untrusted source tree.
#
# Modes (manifest bootstrap.kind):
#   none      - nothing to do
#   swiftpm   - resolve package dependencies for the declared container/scheme
#   cocoapods - Bundler when a Gemfile exists (isolated GEM_HOME/BUNDLE_PATH,
#               never sudo), plain `pod install` otherwise
#   carthage  - carthage bootstrap with xcframeworks
#   adapter   - one committed, repo-specific script under adapters/
set -euo pipefail

: "${SOURCE_DIR:?}" "${BUILD_DIR:?}" "${BOOTSTRAP_KIND:?}" "${WORKING_DIR:?}"

cd "$SOURCE_DIR/$WORKING_DIR"

container_flags() {
    if [ "$CONTAINER_TYPE" = "workspace" ]; then
        printf -- '-workspace\n%s\n' "$CONTAINER_PATH"
    else
        printf -- '-project\n%s\n' "$CONTAINER_PATH"
    fi
}

case "$BOOTSTRAP_KIND" in
    none)
        echo "bootstrap: none"
        ;;
    swiftpm)
        echo "bootstrap: swiftpm (resolvePackageDependencies)"
        args=()
        while IFS= read -r line; do args+=("$line"); done < <(container_flags)
        xcodebuild "${args[@]}" \
            -scheme "$SCHEME" \
            -derivedDataPath "$BUILD_DIR/DerivedData" \
            -skipMacroValidation \
            -skipPackagePluginValidation \
            -resolvePackageDependencies
        ;;
    cocoapods)
        echo "bootstrap: cocoapods"
        if [ -f Gemfile ]; then
            bundle config set --local path "$BUNDLE_PATH"
            bundle install
            bundle exec pod install
        else
            pod install
        fi
        ;;
    carthage)
        echo "bootstrap: carthage"
        carthage bootstrap --use-xcframeworks --platform iOS
        ;;
    adapter)
        : "${ADAPTER_PATH:?adapter bootstrap requires ADAPTER_PATH}"
        ADAPTER_ABS="$BUILDER_DIR/$ADAPTER_PATH"
        if [ ! -f "$ADAPTER_ABS" ]; then
            echo "ERROR: adapter not found: $ADAPTER_PATH" >&2
            exit 1
        fi
        echo "bootstrap: adapter $ADAPTER_PATH"
        /bin/bash --noprofile --norc "$ADAPTER_ABS"
        ;;
    *)
        echo "ERROR: unknown bootstrap kind: $BOOTSTRAP_KIND" >&2
        exit 1
        ;;
esac
