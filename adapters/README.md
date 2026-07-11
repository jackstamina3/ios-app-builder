# Adapters

An adapter is a **committed, repo-specific bootstrap script** for source
projects whose dependency generation goes beyond the structured modes
(`none`, `swiftpm`, `cocoapods`, `carthage`) — Tuist, XcodeGen, React Native,
Flutter, Kotlin Multiplatform / Gradle, Bazel, custom scripts.

One adapter serves exactly one source repository and one pinned source layout.
Do not write "generic" adapters.

Adapters run **sandboxed** (`env -i` via `scripts/run_sandboxed.sh`): fresh
empty `$HOME`, no `GITHUB_TOKEN`, no Actions variables. Available environment:
`SOURCE_DIR`, `BUILD_DIR`, `OUTPUT_DIR`, `BUILDER_DIR`, `WORKING_DIR`,
`DEVELOPER_DIR`, `GEM_HOME`, `BUNDLE_PATH`, plus the manifest's container /
scheme / configuration values. The working directory on entry is
`$SOURCE_DIR/$WORKING_DIR`.

Rules (enforced by review, checked in tests where possible):

- start with `set -euo pipefail`
- no secrets, no `sudo`, no `curl | sh`, no unpinned tool downloads
- verify a checksum for anything you do download
- leave the generated `.xcodeproj`/`.xcworkspace` exactly where the target
  manifest's `container.path` declares it
- referenced from a manifest as `"bootstrap": {"kind": "adapter", "adapter": "adapters/NAME.sh"}`

To pass environment to the later xcodebuild stage (e.g. `JAVA_HOME` for a
Gradle-driven Xcode run-script phase), write `KEY=VALUE` lines to
`$HOME/build-env`; `scripts/build_unsigned_app.sh` exports them before
invoking xcodebuild. Both stages share the same sandbox `$HOME`.
