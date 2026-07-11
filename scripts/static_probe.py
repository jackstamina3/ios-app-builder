#!/usr/bin/env python3
"""Static probe of a checked-out iOS source tree. Pure file inspection - runs
anywhere (Linux sandbox, macOS runner, local machine) and never executes
anything from the source tree.

Usage: static_probe.py SOURCE_DIR

Prints a JSON report to stdout: Xcode containers, shared schemes, dependency
managers, project generators, toolchain hints.
"""

import json
import os
import sys

EXCLUDED_DIRS = {"Pods", "node_modules", ".git", ".build", "DerivedData", "Carthage"}

INDICATOR_FILES = [
    ".xcode-version", "mise.toml", ".mise.toml", "Podfile", "Podfile.lock",
    "Cartfile", "Cartfile.resolved", "Package.swift", "Package.resolved",
    "project.yml", "Project.swift", "Tuist.swift", "Gemfile", "Gemfile.lock",
    "package.json", "pubspec.yaml", "gradlew", "settings.gradle",
    "settings.gradle.kts", "build.gradle", "build.gradle.kts",
    "gradle.properties", "WORKSPACE", "MODULE.bazel", ".java-version",
]

GENERATOR_HINTS = {
    "project.yml": "xcodegen",
    "Project.swift": "tuist",
    "Tuist.swift": "tuist",
    "pubspec.yaml": "flutter",
    "package.json": "node (react-native/expo possible)",
    "gradlew": "gradle (kotlin multiplatform possible)",
    "WORKSPACE": "bazel",
    "MODULE.bazel": "bazel",
}


def walk_containers(root):
    containers = []
    for dirpath, dirnames, _filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS]
        keep = []
        for d in list(dirnames):
            rel = os.path.relpath(os.path.join(dirpath, d), root)
            if d.endswith((".xcodeproj", ".xcworkspace")):
                containers.append(rel)
                # do not descend into container bundles except to find
                # xcshareddata (handled separately below)
            else:
                keep.append(d)
        dirnames[:] = keep
    return sorted(containers)


def shared_schemes(root, container_rel):
    schemes_dir = os.path.join(root, container_rel, "xcshareddata", "xcschemes")
    if not os.path.isdir(schemes_dir):
        return []
    return sorted(
        f[: -len(".xcscheme")] for f in os.listdir(schemes_dir) if f.endswith(".xcscheme")
    )


def read_small(root, rel, limit=4096):
    path = os.path.join(root, rel)
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as f:
            return f.read(limit).strip()
    except OSError:
        return None


def main():
    if len(sys.argv) != 2 or not os.path.isdir(sys.argv[1]):
        print(__doc__, file=sys.stderr)
        return 2
    root = os.path.abspath(sys.argv[1])

    containers = walk_containers(root)
    container_info = []
    for c in containers:
        kind = "workspace" if c.endswith(".xcworkspace") else "project"
        # A project's embedded workspace dir is noise; skip Foo.xcodeproj/project.xcworkspace
        if "/project.xcworkspace" in c or c.endswith("project.xcworkspace"):
            continue
        container_info.append({
            "path": c,
            "type": kind,
            "shared_schemes": shared_schemes(root, c),
        })

    present = {}
    for rel in INDICATOR_FILES:
        matches = []
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if d not in EXCLUDED_DIRS
                           and not d.endswith((".xcodeproj", ".xcworkspace"))]
            if rel in filenames:
                matches.append(os.path.relpath(os.path.join(dirpath, rel), root))
            # cap the walk cost on huge trees
            if len(matches) >= 10:
                break
        if matches:
            present[rel] = sorted(matches)

    generators = sorted({
        hint for name, hint in GENERATOR_HINTS.items() if name in present
    })

    ci_workflows = []
    wf_dir = os.path.join(root, ".github", "workflows")
    if os.path.isdir(wf_dir):
        ci_workflows = sorted(
            f for f in os.listdir(wf_dir) if f.endswith((".yml", ".yaml"))
        )

    xcode_version_hint = read_small(root, ".xcode-version")

    app_scheme_candidates = []
    for info in container_info:
        for s in info["shared_schemes"]:
            lowered = s.lower()
            if not any(t in lowered for t in ("test", "uitest", "benchmark")):
                app_scheme_candidates.append({"container": info["path"], "scheme": s})

    report = {
        "probe_kind": "static",
        "containers": container_info,
        "app_scheme_candidates": app_scheme_candidates,
        "dependency_indicators": present,
        "project_generators": generators,
        "upstream_ci_workflows": ci_workflows,
        "xcode_version_hint": xcode_version_hint,
        "notes": [
            "static probe: no source code was executed",
            "workspaces inside .xcodeproj bundles are omitted",
        ],
    }
    json.dump(report, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    sys.exit(main())
