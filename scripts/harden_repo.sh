#!/usr/bin/env bash
# One-time repository hardening. RUN THIS LOCALLY with an admin-authenticated
# gh CLI - remote Claude sessions cannot change repository settings.
#
#   bash scripts/harden_repo.sh
#
# Applies, then verifies:
#   - Actions enabled, restricted to GitHub-owned actions only
#   - full-length SHA pinning required at the repository-settings level
#   - default workflow token read-only; workflows cannot approve PRs
#   - artifact/log retention 7 days
#   - no external repo may consume this repo's actions/workflows
#   - issues and wiki disabled
# Newer API fields (sha_pinning_required, artifact-and-log-retention endpoint)
# degrade gracefully on older GitHub API versions: you get a warning, and the
# committed workflows remain safe regardless (read-only permissions and
# SHA-pinned actions are in the files themselves).
set -euo pipefail

command -v gh >/dev/null || { echo "ERROR: gh not installed" >&2; exit 1; }
command -v jq >/dev/null || { echo "ERROR: jq not installed" >&2; exit 1; }
gh auth status --hostname github.com >/dev/null

cd "$(dirname "$0")/.."
REPO_NWO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
BASE="repos/$REPO_NWO"
echo "Hardening $REPO_NWO"

# The builder is designed to run private. Public is allowed (free macOS
# minutes) but has real trade-offs, so warn loudly and continue rather than
# refuse - the Actions-hardening settings below apply to public repos too.
VISIBILITY="$(gh repo view --json visibility --jq .visibility | tr '[:upper:]' '[:lower:]')"
if [ "$VISIBILITY" != "private" ]; then
    echo "WARNING: repository is $VISIBILITY, not private." >&2
    echo "  Public repos get free macOS minutes, but their workflow artifacts" >&2
    echo "  (the unsigned IPAs), build logs, and repo contents are visible to" >&2
    echo "  anyone during the retention window. To switch to private (which" >&2
    echo "  re-imposes the 10x macOS billing multiplier):" >&2
    echo "    gh repo edit $REPO_NWO --visibility private" >&2
    echo "  Continuing with the settings that apply to a $VISIBILITY repo..." >&2
fi

step() { echo ""; echo "== $1"; }

step "Disable issues and wiki"
gh repo edit "$REPO_NWO" --enable-issues=false --enable-wiki=false

step "Enable Actions, allow selected actions, require SHA pinning"
if ! jq -n '{enabled: true, allowed_actions: "selected", sha_pinning_required: true}' |
    gh api --method PUT "$BASE/actions/permissions" --input -; then
    echo "WARNING: sha_pinning_required not accepted; retrying without it" >&2
    jq -n '{enabled: true, allowed_actions: "selected"}' |
        gh api --method PUT "$BASE/actions/permissions" --input -
fi

step "Allow GitHub-owned actions only"
jq -n '{github_owned_allowed: true, verified_allowed: false, patterns_allowed: []}' |
    gh api --method PUT "$BASE/actions/permissions/selected-actions" --input -

step "Default workflow token read-only; no PR approvals"
jq -n '{default_workflow_permissions: "read", can_approve_pull_request_reviews: false}' |
    gh api --method PUT "$BASE/actions/permissions/workflow" --input -

step "Artifact and log retention: 7 days"
if ! jq -n '{days: 7}' |
    gh api --method PUT "$BASE/actions/permissions/artifact-and-log-retention" --input -; then
    echo "WARNING: retention endpoint unavailable; per-artifact retention-days: 7 in the workflows still applies" >&2
fi

step "No external access to this repo's actions/workflows"
if ! jq -n '{access_level: "none"}' |
    gh api --method PUT "$BASE/actions/permissions/access" --input -; then
    echo "WARNING: access endpoint failed (this setting only exists for private repos)" >&2
fi

step "Verification"
gh repo view "$REPO_NWO" --json nameWithOwner,visibility,url,hasIssuesEnabled,hasWikiEnabled
echo "-- actions/permissions:"
gh api "$BASE/actions/permissions"
echo "-- actions/permissions/workflow:"
gh api "$BASE/actions/permissions/workflow"
echo "-- actions/permissions/artifact-and-log-retention:"
gh api "$BASE/actions/permissions/artifact-and-log-retention" || true
echo "-- secrets (should be an empty list):"
gh api "$BASE/actions/secrets" --jq '{total_count}'
echo ""
echo "Hardening complete."
