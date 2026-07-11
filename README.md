# ios-app-builder

Reproducible **unsigned** iOS IPA builds from authorized public source, on
GitHub-hosted macOS runners, with code signing disabled end to end.

The product of this repository is always `*.unsigned.ipa`: no signature, no
embedded provisioning profile, **not installable as-is**. Signing is your own
separate downstream step, with your own credentials, which never touch this
repository.

## Ask for a build in one line

In a Claude Code session on this repo, just say what you want:

> Build me an unsigned IPA of `OWNER/REPO` at the latest release

(or give an app name to resolve). Claude confirms the exact repository and ref
with you first, then runs the whole loop — find the official source, check the
license, pin the commit, probe, write a new target manifest (plus an adapter if
the project needs one), dispatch the build, watch it to green, and hand you the
IPA filename, its SHA-256, and the `gh run download` command to pull it locally.
You never edit manifests or workflows by hand.

**Boundaries:** it builds open-source apps that ship their source with a license
(not closed-source App Store apps — there is no source to build), and the output
is always unsigned and needs your own signing step before it will install.
Committed manifests under `targets/` are immutable records of past builds, never
defaults — every build starts by asking which repo/ref you want.

## What it does

1. You (or Claude Code) pin a public, explicitly-licensed iOS source repo to
   an exact commit in a committed target manifest (`targets/*.json`).
2. `build-unsigned-ipa.yml` validates everything on a cheap Ubuntu job, then
   builds on a macOS runner: pinned clone → sandboxed dependency bootstrap →
   `xcodebuild` with signing disabled → signature-material removal →
   `Payload/` packaging → 10-point verification → artifact upload
   (7-day retention).
3. You download `unsigned-ipa-<UUID>` and verify it locally.

## Quick start

```bash
# once, locally (admin gh required):
bash scripts/harden_repo.sh

# probe a source repo (free, static):
bin/probe-source OWNER/REPO v1.2.3

# after committing a target manifest:
bin/build-target targets/OWNER__REPO__abc1234.json
```

## Cost warning

macOS runners bill at a **10x minute multiplier** on private repositories.
One full build can consume hundreds of billed minutes; the Free plan includes
2,000/month. Prefer the free static probe, size `timeout_minutes` honestly,
and expect a $0 spending limit to simply fail runs once the quota is spent.

## Security model

- `workflow_dispatch` only; no push/PR/fork/comment triggers.
- Workflow token is `contents: read`; no secrets exist in the repository.
- Only GitHub-owned actions, pinned to full commit SHAs;
  `persist-credentials: false` on every checkout.
- Inputs are regex-validated on Ubuntu before any macOS runner is allocated;
  build details come only from committed, schema-validated manifests
  (signing settings cannot be overridden; unknown keys rejected).
- Untrusted source code runs under `env -i` with a fresh `$HOME` and never
  sees `GITHUB_TOKEN` or Actions variables.
- Build from source only: explicit license required; App Store binaries,
  DRM-protected IPAs, and binary-only projects are out of scope.

`CLAUDE.md` contains the full operating procedure; `tests/run_tests.sh`
enforces the invariants.
