# ios-app-builder — operating procedure for Claude Code

This private repository builds **unsigned** iOS IPAs from licensed public
source on GitHub-hosted macOS runners. The output is never signed and never
installable as-is; signing is the user's separate downstream step. Name every
result `*.unsigned.ipa` and never describe it as signed.

## Non-negotiable rules

1. Build only from public source with an explicit license permitting the use,
   or code the user explicitly states they own / are authorized to build.
   A public repo without a license is NOT permission — stop and report.
2. Never search for, download, decrypt, crack, patch, or repackage App Store
   binaries, DRM-protected IPAs, or binary-only apps. A release-asset `.ipa`
   is not source; if a project is binary-only there is nothing to build.
3. Pin sources to a full 40-char commit SHA in a committed target manifest.
4. GitHub-hosted macOS runners only (`macos-15`, `macos-15-intel`).
5. No Apple certificates, profiles, Apple IDs, or signing secrets anywhere in
   this repository. Never use `-allowProvisioningUpdates`.
6. Workflows stay `workflow_dispatch`-only, `contents: read`-only, with
   GitHub-owned actions pinned to full SHAs and `persist-credentials: false`.
7. Never pass workflow inputs into shell unvalidated; the Ubuntu plan jobs
   validate everything before macOS allocation. Never accept a free-form
   shell command as an input.
8. No shared dependency caches. Isolation beats speed here.
9. Never claim an unsigned IPA is installable, and never return an old
   artifact after a failed build or relabel a simulator/signed artifact.

## Cost — read before dispatching anything

macOS runners bill at a **10x minute multiplier** on private repos
(Free plan: 2,000 included min/month ≈ 200 macOS minutes). A worst-case
probe + build ≈ 1,200 billed minutes. Therefore:

- Always run the **free static probe first**: `bin/probe-source OWNER/REPO REF`
  (locally) or `scripts/static_probe.py` on a shallow clone. Dispatch the
  remote macOS probe only when static inspection can't settle container,
  scheme, or toolchain questions.
- State expected/spent runner minutes when proposing or retrying builds.
- Retries are manual and deliberate: inspect logs, change the manifest or
  adapter for a log-supported reason, use a fresh request UUID.

## Per-request procedure (user asks to build an iOS app)

1. Parse app name / repository / version. Resolve the official upstream
   source repository (prefer the developer's org; never a random fork just
   because it has IPA releases).
2. Confirm license (`gh api repos/X/license` or the LICENSE file at the
   pinned tree) or explicit user authorization. No basis → stop, report.
3. Prefer the latest stable (non-draft, non-prerelease) release tag; resolve
   to a 40-char SHA (`git ls-remote` works without auth). Fall back to the
   default-branch head only when there is no stable release, and say so in
   the manifest `notes`.
4. Static probe. Read build docs, upstream CI, `.xcode-version`, dependency
   files. Only if still ambiguous: remote probe via the probe workflow.
5. Write `targets/OWNER__REPOSITORY__SHORTSHA.json`; write a narrow adapter
   under `adapters/` only when the structured bootstrap modes don't fit.
6. `python3 scripts/validate_target.py targets/...json` must pass. Run
   `tests/run_tests.sh` if you touched scripts/workflows.
7. Commit and push (workflows build what's on the branch, not local state).
8. Dispatch and babysit (see drive modes). On failure: diagnose from
   `xcodebuild.log` / diagnostics artifact; change manifest/adapter only with
   a log-supported reason; new UUID; re-dispatch.
9. Report: source repo, ref, commit, license, runner, Xcode version, bundle
   ID, app version/build, IPA filename + SHA-256, "unsigned; no embedded
   provisioning profile", and how to fetch the artifact.

## Drive modes

**Local session (gh available):** `bin/build-target targets/X.json` does the
whole loop — validate, dispatch (with `return_run_details: true`), watch,
download, checksum, local verify, print final path + SHA-256.

**Remote Claude session (GitHub MCP tools, no gh):** dispatch with the
actions run-trigger tool (workflow file + ref + inputs), locate the run by
the request UUID in its run-name, follow it via run/job-log tools. Both
workflows print their JSON report (`probe-report.json` /
`build-manifest.json` + `SHA256SUMS`) into the job log between
`===== BEGIN/END ... =====` markers — read results there. Artifacts cannot be
downloaded from the remote session: give the user
`bin/fetch-artifact RUN_ID REQUEST_ID` (or the equivalent
`gh run download`) for the final IPA.

## Selection rules

- Xcode: use the version the source declares (`.xcode-version`, docs), else
  what upstream CI uses, else a compatible installed version — document the
  choice in `notes`. Never silently take the runner default. The value must
  match `/Applications/Xcode_<VALUE>.app` on the runner image
  (three-component versions like `26.0.1` are valid).
- Runner: `macos-15` (arm64) unless an Intel-only dependency forces
  `macos-15-intel` — document why.

## Stop-and-report conditions

Binary-only repo; no license/authorization; unresolvable or unfetchable
commit; requested Xcode absent from the image; private dependencies or
credentials required; unavailable proprietary SDK; multiple plausible app
schemes that inspection cannot settle; the build needs source changes beyond
a narrow user-authorized compatibility patch; any identity-bearing signature
or provisioning profile in the output; simulator-only build success.

## Layout

- `.github/workflows/` — `probe-source.yml`, `build-unsigned-ipa.yml`
- `scripts/` — validation, clone, sandbox wrapper, bootstrap, build, package,
  verify, probe, hardening (see headers in each file)
- `bin/` — `build-target`, `probe-source`, `fetch-artifact` (user-local, gh)
- `targets/`, `adapters/`, `schemas/`, `tests/`
- `tests/run_tests.sh` must stay green; it enforces the security invariants
  (SHA pins, read-only permissions, dispatch-only triggers,
  persist-credentials, negative manifest fixtures).
