#!/usr/bin/env python3
"""Authoritative validator for target manifests under targets/.

Every value that later reaches a shell, a path, or a workflow expression is
validated here first. The build workflow's Ubuntu plan job runs this before
any macOS runner is allocated, and the macOS job runs it again (defense in
depth) before exporting values into its environment.

Usage:
  validate_target.py TARGET.json                     # validate, print OK
  validate_target.py TARGET.json --emit-github-outputs
  validate_target.py TARGET.json --emit-env
  validate_target.py TARGET.json --extra-settings-out FILE

Exit code 0 only when the manifest is fully valid.
"""

import json
import re
import sys

RE_REPOSITORY = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
RE_REF = re.compile(r"^[A-Za-z0-9][A-Za-z0-9/._+-]{0,200}$")
RE_COMMIT = re.compile(r"^[0-9a-f]{40}$")
RE_SPDX = re.compile(r"^[A-Za-z0-9.+-]{1,64}$")
RE_XCODE = re.compile(r"^[0-9]+\.[0-9]+(\.[0-9]+)?$")
RE_SCHEME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,99}$")
RE_APP_BUNDLE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._+-]{0,99}\.app$")
RE_SETTING_KEY = re.compile(r"^[A-Z0-9_]{1,64}$")
RE_ADAPTER = re.compile(r"^adapters/[A-Za-z0-9._-]+\.sh$")
RE_RELPATH = re.compile(r"^[A-Za-z0-9 ._-]+(/[A-Za-z0-9 ._-]+)*$")
RE_RELPATH_NOSPACE = re.compile(r"^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$")

ALLOWED_RUNNERS = ("macos-15", "macos-15-intel")

# Signing must never be reintroduced through extra_build_settings. Substring
# matching intentionally over-blocks (e.g. any *CODE_SIGN* key).
BANNED_KEY_SUBSTRINGS = ("CODE_SIGN", "PROVISIONING", "SIGNING")
BANNED_KEYS = {"DEVELOPMENT_TEAM", "AD_HOC_CODE_SIGNING_ALLOWED"}

TOP_KEYS = {
    "schema_version", "source", "runner", "xcode_version", "working_directory",
    "container", "scheme", "configuration", "build_action", "timeout_minutes",
    "bootstrap", "extra_build_settings", "output", "notes",
}
SOURCE_KEYS = {"repository", "ref", "commit", "license_spdx", "license_file"}
CONTAINER_KEYS = {"type", "path"}
BOOTSTRAP_KEYS = {"kind", "adapter"}
OUTPUT_KEYS = {"expected_app_bundle"}

DEFAULT_TIMEOUT_MINUTES = 90


class Invalid(Exception):
    pass


def fail(msg):
    raise Invalid(msg)


def require_str(obj, key, where):
    v = obj.get(key)
    if not isinstance(v, str):
        fail(f"{where}.{key} must be a string")
    if "\x00" in v or "\n" in v or "\r" in v:
        fail(f"{where}.{key} contains a forbidden control character")
    return v


def check_relpath(value, name, pattern=RE_RELPATH):
    if not pattern.fullmatch(value):
        fail(f"{name} has invalid characters or format: {value!r}")
    if value.startswith("/") or value.startswith("-"):
        fail(f"{name} must be a relative path not starting with '-': {value!r}")
    for seg in value.split("/"):
        if seg in ("..", ".", ""):
            fail(f"{name} contains a forbidden path segment: {value!r}")
    return value


def check_unknown(obj, allowed, where):
    unknown = set(obj) - allowed
    if unknown:
        fail(f"{where} has unknown key(s): {sorted(unknown)} (typos are rejected, not ignored)")


def validate(manifest):
    if not isinstance(manifest, dict):
        fail("manifest root must be a JSON object")
    check_unknown(manifest, TOP_KEYS, "manifest")

    if manifest.get("schema_version") != 1:
        fail("schema_version must be 1")

    source = manifest.get("source")
    if not isinstance(source, dict):
        fail("source must be an object")
    check_unknown(source, SOURCE_KEYS, "source")
    repository = require_str(source, "repository", "source")
    if not RE_REPOSITORY.fullmatch(repository):
        fail(f"source.repository must match OWNER/REPOSITORY: {repository!r}")
    ref = require_str(source, "ref", "source")
    if not RE_REF.fullmatch(ref):
        fail(f"source.ref invalid (no leading dash, no shell metacharacters): {ref!r}")
    commit = require_str(source, "commit", "source")
    if not RE_COMMIT.fullmatch(commit):
        fail("source.commit must be exactly 40 lowercase hex characters")
    spdx = require_str(source, "license_spdx", "source")
    if not RE_SPDX.fullmatch(spdx):
        fail(f"source.license_spdx invalid: {spdx!r}")
    license_file = require_str(source, "license_file", "source")
    check_relpath(license_file, "source.license_file", RE_RELPATH_NOSPACE)

    runner = manifest.get("runner")
    if runner not in ALLOWED_RUNNERS:
        fail(f"runner must be one of {ALLOWED_RUNNERS}: {runner!r}")

    xcode_version = require_str(manifest, "xcode_version", "manifest")
    if not RE_XCODE.fullmatch(xcode_version):
        fail(f"xcode_version must look like 16.4 or 26.0.1: {xcode_version!r}")

    working_directory = manifest.get("working_directory", ".")
    if not isinstance(working_directory, str):
        fail("working_directory must be a string")
    if working_directory != ".":
        check_relpath(working_directory, "working_directory", RE_RELPATH_NOSPACE)

    container = manifest.get("container")
    if not isinstance(container, dict):
        fail("container must be an object")
    check_unknown(container, CONTAINER_KEYS, "container")
    ctype = container.get("type")
    if ctype not in ("project", "workspace"):
        fail(f"container.type must be project or workspace: {ctype!r}")
    cpath = require_str(container, "path", "container")
    check_relpath(cpath, "container.path")
    expected_suffix = ".xcodeproj" if ctype == "project" else ".xcworkspace"
    if not cpath.endswith(expected_suffix):
        fail(f"container.path must end in {expected_suffix} for type {ctype}: {cpath!r}")

    scheme = require_str(manifest, "scheme", "manifest")
    if not RE_SCHEME.fullmatch(scheme):
        fail(f"scheme invalid: {scheme!r}")

    if manifest.get("configuration") not in ("Release", "Debug"):
        fail("configuration must be Release or Debug")
    if manifest.get("build_action") not in ("archive", "build"):
        fail("build_action must be archive or build")

    timeout = manifest.get("timeout_minutes", DEFAULT_TIMEOUT_MINUTES)
    if not isinstance(timeout, int) or isinstance(timeout, bool) or not (10 <= timeout <= 180):
        fail("timeout_minutes must be an integer between 10 and 180")

    bootstrap = manifest.get("bootstrap")
    if not isinstance(bootstrap, dict):
        fail("bootstrap must be an object")
    check_unknown(bootstrap, BOOTSTRAP_KEYS, "bootstrap")
    kind = bootstrap.get("kind")
    if kind not in ("none", "swiftpm", "cocoapods", "carthage", "adapter"):
        fail(f"bootstrap.kind invalid: {kind!r}")
    adapter = bootstrap.get("adapter")
    if kind == "adapter":
        if not isinstance(adapter, str) or not RE_ADAPTER.fullmatch(adapter):
            fail("bootstrap.adapter must be a committed adapters/NAME.sh path when kind is adapter")
        check_relpath(adapter, "bootstrap.adapter", RE_RELPATH_NOSPACE)
    elif adapter is not None:
        fail("bootstrap.adapter must be null unless bootstrap.kind is adapter")

    extra = manifest.get("extra_build_settings", {})
    if not isinstance(extra, dict):
        fail("extra_build_settings must be an object")
    for key, value in extra.items():
        if not isinstance(key, str) or not RE_SETTING_KEY.fullmatch(key):
            fail(f"extra_build_settings key invalid: {key!r}")
        if key in BANNED_KEYS or any(s in key for s in BANNED_KEY_SUBSTRINGS):
            fail(f"extra_build_settings must not touch signing-related setting: {key!r}")
        if not isinstance(value, str) or len(value) > 500:
            fail(f"extra_build_settings[{key}] must be a string of at most 500 chars")
        if "\x00" in value or "\n" in value or "\r" in value:
            fail(f"extra_build_settings[{key}] contains a forbidden control character")

    output = manifest.get("output")
    if not isinstance(output, dict):
        fail("output must be an object")
    check_unknown(output, OUTPUT_KEYS, "output")
    app_bundle = require_str(output, "expected_app_bundle", "output")
    if not RE_APP_BUNDLE.fullmatch(app_bundle):
        fail(f"output.expected_app_bundle must be NAME.app with safe characters: {app_bundle!r}")

    notes = manifest.get("notes", "")
    if not isinstance(notes, str) or len(notes) > 2000:
        fail("notes must be a string of at most 2000 chars")

    return {
        "repository": repository,
        "ref": ref,
        "commit": commit,
        "license_spdx": spdx,
        "license_file": license_file,
        "runner": runner,
        "xcode_version": xcode_version,
        "working_directory": working_directory,
        "container_type": ctype,
        "container_path": cpath,
        "scheme": scheme,
        "configuration": manifest["configuration"],
        "build_action": manifest["build_action"],
        "timeout_minutes": timeout,
        "bootstrap_kind": kind,
        "adapter_path": adapter or "",
        "extra_build_settings": extra,
        "expected_app_bundle": app_bundle,
    }


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    path = argv[1]
    flags = argv[2:]

    try:
        with open(path, "r", encoding="utf-8") as f:
            manifest = json.load(f)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"INVALID: cannot read manifest {path}: {exc}", file=sys.stderr)
        return 1

    try:
        values = validate(manifest)
    except Invalid as exc:
        print(f"INVALID: {exc}", file=sys.stderr)
        return 1

    if "--emit-github-outputs" in flags:
        print(f"runner={values['runner']}")
        print(f"timeout_minutes={values['timeout_minutes']}")
        print(f"xcode_version={values['xcode_version']}")
    elif "--emit-env" in flags:
        env_map = {
            "SOURCE_REPOSITORY": values["repository"],
            "SOURCE_REF": values["ref"],
            "EXPECTED_SHA": values["commit"],
            "LICENSE_SPDX": values["license_spdx"],
            "LICENSE_FILE": values["license_file"],
            "XCODE_VERSION": values["xcode_version"],
            "WORKING_DIR": values["working_directory"],
            "CONTAINER_TYPE": values["container_type"],
            "CONTAINER_PATH": values["container_path"],
            "SCHEME": values["scheme"],
            "CONFIGURATION": values["configuration"],
            "BUILD_ACTION": values["build_action"],
            "BOOTSTRAP_KIND": values["bootstrap_kind"],
            "ADAPTER_PATH": values["adapter_path"],
            "EXPECTED_APP_BUNDLE": values["expected_app_bundle"],
        }
        for key, value in env_map.items():
            print(f"{key}={value}")
    else:
        print(f"OK: {path}")

    if "--extra-settings-out" in flags:
        idx = flags.index("--extra-settings-out")
        try:
            out_path = flags[idx + 1]
        except IndexError:
            print("INVALID: --extra-settings-out needs a file argument", file=sys.stderr)
            return 2
        with open(out_path, "w", encoding="utf-8") as f:
            for key, value in values["extra_build_settings"].items():
                f.write(f"{key}={value}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
