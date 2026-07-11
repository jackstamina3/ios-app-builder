#!/usr/bin/env bash
# Clone the pinned public source tree into $SOURCE_DIR and hard-verify the SHA.
# - Unauthenticated HTTPS only; no credentials exist in this environment.
# - Fetch by exact commit first, fall back to the declared ref, then verify
#   HEAD equals the manifest's 40-character commit either way.
# - Git LFS runs only when the tree actually declares LFS filters, and then it
#   must succeed (no silent `|| true` path).
# - Submodules: shallow first, full retry on failure (pinned submodule commits
#   are often not shallow-fetchable); file-protocol always disabled.
set -euo pipefail

: "${SOURCE_DIR:?}" "${SOURCE_REPOSITORY:?}" "${SOURCE_REF:?}" "${EXPECTED_SHA:?}" "${OUTPUT_DIR:?}"

SOURCE_URL="https://github.com/${SOURCE_REPOSITORY}.git"

git init -q "$SOURCE_DIR"
git -C "$SOURCE_DIR" remote add origin "$SOURCE_URL"

echo "Fetching $SOURCE_REPOSITORY at $EXPECTED_SHA (ref: $SOURCE_REF)"
if ! git -C "$SOURCE_DIR" fetch --depth=1 origin "$EXPECTED_SHA" 2>/dev/null; then
    echo "Direct SHA fetch unavailable; fetching declared ref"
    git -C "$SOURCE_DIR" fetch --depth=1 origin -- "$SOURCE_REF"
fi
git -C "$SOURCE_DIR" checkout --quiet --detach FETCH_HEAD

ACTUAL_SHA="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
    echo "::error::Source SHA mismatch: expected $EXPECTED_SHA got $ACTUAL_SHA" >&2
    exit 1
fi
echo "Verified source commit: $ACTUAL_SHA"

# Git LFS: required to succeed if and only if the tree declares LFS filters.
LFS_FILES="$(git -C "$SOURCE_DIR" ls-files -- '.gitattributes' '*/.gitattributes' '*.gitattributes')"
USES_LFS=no
if [ -n "$LFS_FILES" ]; then
    while IFS= read -r attr_file; do
        if grep -q 'filter=lfs' "$SOURCE_DIR/$attr_file" 2>/dev/null; then
            USES_LFS=yes
            break
        fi
    done <<< "$LFS_FILES"
fi
if [ "$USES_LFS" = yes ]; then
    echo "Repository uses Git LFS; pulling LFS objects (must succeed)"
    git -C "$SOURCE_DIR" lfs install --local
    git -C "$SOURCE_DIR" lfs pull
else
    echo "No LFS filters declared; skipping LFS"
fi

# Submodules: initialize ONLY paths declared in .gitmodules. Some repos leave
# orphan gitlinks in the tree (a directory recorded with mode 160000) that have
# no .gitmodules entry - a blanket `--init --recursive` aborts on those with
# "No url found for submodule path". Enumerating declared paths skips them.
# Per declared path: shallow first, full fallback (pinned commits are often not
# shallow-fetchable). File-protocol always disabled.
if [ -f "$SOURCE_DIR/.gitmodules" ]; then
    mapfile -t SUBMODULE_PATHS < <(
        git -C "$SOURCE_DIR" config -f .gitmodules --get-regexp '^submodule\..*\.path$' \
            | awk '{print $2}'
    )
    if [ "${#SUBMODULE_PATHS[@]}" -eq 0 ]; then
        echo "No declared submodule paths in .gitmodules"
        : > "$OUTPUT_DIR/submodules.txt"
    else
        echo "Declared submodules: ${SUBMODULE_PATHS[*]}"
        if ! git -C "$SOURCE_DIR" -c protocol.file.allow=never \
                submodule update --init --recursive --depth=1 -- "${SUBMODULE_PATHS[@]}" 2>&1; then
            echo "Shallow submodule fetch failed; retrying without --depth"
            git -C "$SOURCE_DIR" -c protocol.file.allow=never \
                submodule update --init --recursive -- "${SUBMODULE_PATHS[@]}"
        fi
        git -C "$SOURCE_DIR" submodule status -- "${SUBMODULE_PATHS[@]}" \
            | tee "$OUTPUT_DIR/submodules.txt"
    fi
else
    echo "No submodules"
    : > "$OUTPUT_DIR/submodules.txt"
fi
