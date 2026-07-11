#!/usr/bin/env python3
"""Write build-manifest.json into $OUTPUT_DIR and copy license/lockfiles.

Trusted step: runs in the normal workflow environment AFTER the sandboxed
build, reading only environment variables the workflow validated and files
the build produced.
"""

import hashlib
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone


def env(name, default=""):
    return os.environ.get(name, default)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def git(*args, cwd=None):
    try:
        return subprocess.run(
            ["git", *args], cwd=cwd, capture_output=True, text=True, check=True
        ).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


LOCKFILE_NAMES = (
    "Podfile.lock", "Package.resolved", "Cartfile.resolved", "Gemfile.lock",
    "gradle.lockfile", "yarn.lock", "package-lock.json", "pubspec.lock",
)


def main():
    output_dir = env("OUTPUT_DIR")
    source_dir = env("SOURCE_DIR")
    builder_dir = env("BUILDER_DIR", env("GITHUB_WORKSPACE", "."))
    if not output_dir or not os.path.isdir(output_dir):
        print("OUTPUT_DIR missing", file=sys.stderr)
        return 1

    ipa_path = None
    ipa_file = os.path.join(output_dir, "ipa-path.txt")
    if os.path.isfile(ipa_file):
        with open(ipa_file) as f:
            ipa_path = f.read().strip()

    app_info = {}
    app_info_file = os.path.join(output_dir, "app-info.json")
    if os.path.isfile(app_info_file):
        with open(app_info_file) as f:
            app_info = json.load(f)

    submodules = []
    sub_file = os.path.join(output_dir, "submodules.txt")
    if os.path.isfile(sub_file):
        with open(sub_file) as f:
            submodules = [line.strip() for line in f if line.strip()]

    # Entitlement files present in source (informational: a source build does
    # not prove the user's downstream signing profile covers them).
    entitlement_files = []
    if os.path.isdir(source_dir):
        for dirpath, dirnames, filenames in os.walk(source_dir):
            dirnames[:] = [d for d in dirnames if d not in (".git", "Pods", "node_modules")]
            for fn in filenames:
                if fn.endswith(".entitlements"):
                    entitlement_files.append(
                        os.path.relpath(os.path.join(dirpath, fn), source_dir)
                    )
            if len(entitlement_files) >= 50:
                break

    manifest = {
        "unsigned": True,
        "source": {
            "repository": env("SOURCE_REPOSITORY"),
            "ref": env("SOURCE_REF"),
            "commit": env("EXPECTED_SHA"),
            "license_spdx": env("LICENSE_SPDX"),
            "license_file": env("LICENSE_FILE"),
            "submodules": submodules,
        },
        "builder": {
            "repository": env("GITHUB_REPOSITORY"),
            "commit": env("GITHUB_SHA") or git("rev-parse", "HEAD", cwd=builder_dir),
            "workflow_run_id": env("GITHUB_RUN_ID"),
            "request_id": env("REQUEST_ID"),
            "target_manifest": env("TARGET_JSON"),
        },
        "environment": {
            "runner_label_requested": None,  # recorded via runner facts below
            "runner_os": env("RUNNER_OS"),
            "runner_arch": env("RUNNER_ARCH"),
            "runner_image": env("ImageOS") or env("IMAGE_OS"),
            "xcode_version_requested": env("XCODE_VERSION"),
            "developer_dir": env("DEVELOPER_DIR"),
        },
        "build": {
            "container_type": env("CONTAINER_TYPE"),
            "container_path": env("CONTAINER_PATH"),
            "scheme": env("SCHEME"),
            "configuration": env("CONFIGURATION"),
            "build_action": env("BUILD_ACTION"),
            "bootstrap_kind": env("BOOTSTRAP_KIND"),
            "adapter_path": env("ADAPTER_PATH") or None,
            "working_directory": env("WORKING_DIR"),
        },
        "app": app_info,
        "entitlement_files_in_source": sorted(entitlement_files),
        "artifact": {},
        "built_at_utc": datetime.now(timezone.utc).isoformat(),
    }

    # Xcode/SDK facts straight from the selected toolchain.
    try:
        out = subprocess.run(
            ["xcodebuild", "-version"], capture_output=True, text=True, check=True,
            env={**os.environ},
        ).stdout.strip().splitlines()
        manifest["environment"]["xcode_version_actual"] = " ".join(out)
    except (OSError, subprocess.CalledProcessError):
        pass
    try:
        sdk = subprocess.run(
            ["xcrun", "--sdk", "iphoneos", "--show-sdk-version"],
            capture_output=True, text=True, check=True, env={**os.environ},
        ).stdout.strip()
        manifest["environment"]["iphoneos_sdk"] = sdk
    except (OSError, subprocess.CalledProcessError):
        pass

    if ipa_path and os.path.isfile(ipa_path):
        manifest["artifact"] = {
            "filename": os.path.basename(ipa_path),
            "bytes": os.path.getsize(ipa_path),
            "sha256": sha256(ipa_path),
        }

    # Copy the source license file and any lockfiles into the artifact.
    license_dir = os.path.join(output_dir, "license")
    os.makedirs(license_dir, exist_ok=True)
    license_rel = env("LICENSE_FILE")
    if license_rel:
        src = os.path.join(source_dir, license_rel)
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(license_dir, os.path.basename(license_rel)))

    locks_dir = os.path.join(output_dir, "locks")
    os.makedirs(locks_dir, exist_ok=True)
    copied = set()
    if os.path.isdir(source_dir):
        for dirpath, dirnames, filenames in os.walk(source_dir):
            dirnames[:] = [d for d in dirnames if d not in (".git", "Pods", "node_modules")]
            for fn in filenames:
                if fn in LOCKFILE_NAMES and fn not in copied:
                    shutil.copy(os.path.join(dirpath, fn), os.path.join(locks_dir, fn))
                    copied.add(fn)

    out_path = os.path.join(output_dir, "build-manifest.json")
    with open(out_path, "w") as f:
        json.dump(manifest, f, indent=2)
    print("wrote", out_path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
