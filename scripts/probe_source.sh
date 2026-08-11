#!/usr/bin/env bash
# macOS probe of the pinned source tree. Runs SANDBOXED (env -i) because
# `xcodebuild -list` parses untrusted project files.
#
# Produces $OUTPUT_DIR/probe-report.json combining:
#   - runner/Xcode/SDK facts
#   - the static probe (file inspection only)
#   - `xcodebuild -list -json` for each discovered container (up to 10)
set -euo pipefail

: "${SOURCE_DIR:?}" "${BUILD_DIR:?}" "${OUTPUT_DIR:?}" "${BUILDER_DIR:?}"

echo "Collecting system facts"
# Assigned before export: `export VAR="$(...)"` masks the command's exit status
# from set -e (shellcheck SC2155), which would hide a probe collecting garbage.
PROBE_ARCH="$(uname -m)"
PROBE_OS_VERSION="$(sw_vers -productVersion 2>/dev/null || echo unknown)"
PROBE_XCODE="$(xcodebuild -version 2>/dev/null | tr '\n' ' ' || echo unknown)"
PROBE_SDK="$(xcrun --sdk iphoneos --show-sdk-version 2>/dev/null || echo unknown)"
PROBE_XCODES="$(ls -1d /Applications/Xcode*.app 2>/dev/null | tr '\n' ',' || true)"
export PROBE_ARCH PROBE_OS_VERSION PROBE_XCODE PROBE_SDK PROBE_XCODES

echo "Running static probe"
python3 "$BUILDER_DIR/scripts/static_probe.py" "$SOURCE_DIR" > "$BUILD_DIR/static-probe.json"

echo "Listing schemes per container (xcodebuild -list)"
mkdir -p "$BUILD_DIR/lists"
python3 - "$BUILD_DIR/static-probe.json" > "$BUILD_DIR/containers.txt" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    report = json.load(f)
for c in report.get("containers", [])[:10]:
    print(c["path"])
PYEOF

i=0
while IFS= read -r container; do
    [ -n "$container" ] || continue
    i=$((i + 1))
    out="$BUILD_DIR/lists/list-$i.json"
    if [[ "$container" == *.xcworkspace ]]; then
        flag="-workspace"
    else
        flag="-project"
    fi
    echo "  -list $container"
    if ! (cd "$SOURCE_DIR" && xcodebuild "$flag" "$container" -list -json > "$out" 2> "$out.err"); then
        echo "    (listing failed; stderr kept)"
    fi
    printf '%s\n' "$container" > "$out.container"
done < "$BUILD_DIR/containers.txt"

echo "Assembling probe-report.json"
python3 - "$BUILD_DIR" "$OUTPUT_DIR" <<'PYEOF'
import glob, json, os, sys

build_dir, output_dir = sys.argv[1], sys.argv[2]

with open(os.path.join(build_dir, "static-probe.json")) as f:
    report = json.load(f)

listings = []
for out in sorted(glob.glob(os.path.join(build_dir, "lists", "list-*.json"))):
    entry = {"container": None, "schemes": None, "error": None}
    try:
        with open(out + ".container") as f:
            entry["container"] = f.read().strip()
    except OSError:
        pass
    try:
        with open(out) as f:
            data = json.load(f)
        root = data.get("workspace") or data.get("project") or {}
        entry["schemes"] = root.get("schemes")
    except (OSError, json.JSONDecodeError):
        try:
            with open(out + ".err") as f:
                entry["error"] = f.read()[-2000:]
        except OSError:
            entry["error"] = "xcodebuild -list failed with no stderr"
    listings.append(entry)

report["probe_kind"] = "macos"
report["runner"] = {
    "arch": os.environ.get("PROBE_ARCH"),
    "os_version": os.environ.get("PROBE_OS_VERSION"),
    "xcode": os.environ.get("PROBE_XCODE"),
    "iphoneos_sdk": os.environ.get("PROBE_SDK"),
    "installed_xcodes": [x for x in (os.environ.get("PROBE_XCODES") or "").split(",") if x],
}
report["source"] = {
    "repository": os.environ.get("SOURCE_REPOSITORY"),
    "ref": os.environ.get("SOURCE_REF"),
    "commit": os.environ.get("EXPECTED_SHA"),
}
report["xcodebuild_listings"] = listings

skeleton = {
    "schema_version": 1,
    "source": {
        "repository": os.environ.get("SOURCE_REPOSITORY"),
        "ref": os.environ.get("SOURCE_REF"),
        "commit": os.environ.get("EXPECTED_SHA"),
        "license_spdx": None,
        "license_file": None,
    },
    "runner": "macos-15",
    "xcode_version": None,
    "working_directory": ".",
    "container": {"type": None, "path": None},
    "scheme": None,
    "configuration": "Release",
    "build_action": "archive",
    "bootstrap": {"kind": None, "adapter": None},
    "extra_build_settings": {},
    "output": {"expected_app_bundle": None},
}
candidates = report.get("app_scheme_candidates") or []
if len(candidates) == 1:
    c = candidates[0]
    skeleton["container"]["path"] = c["container"]
    skeleton["container"]["type"] = (
        "workspace" if c["container"].endswith(".xcworkspace") else "project"
    )
    skeleton["scheme"] = c["scheme"]
report["recommended_manifest_skeleton"] = skeleton
report["ambiguities"] = (
    [] if len(candidates) == 1
    else [f"{len(candidates)} app scheme candidates; a human/Claude must pick one"]
)

with open(os.path.join(output_dir, "probe-report.json"), "w") as f:
    json.dump(report, f, indent=2)
print("wrote", os.path.join(output_dir, "probe-report.json"))
PYEOF
