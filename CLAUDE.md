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
10. Never start a build from an assumed, remembered, or silently reused
    target. Every build begins by explicitly asking the user which
    repository and ref to build (see "Target selection is always an explicit
    first step"). Committed manifests under `targets/` are immutable
    historical records of past builds — never treat one as the default for a
    new request.

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

## Target selection is always an explicit first step

Before anything else — before reading `targets/`, before probing, before
touching a runner — ask the user which app to build. Every build starts with
an explicit question, e.g.:

> "Which repository and ref should I build? Give me `OWNER/REPOSITORY` (or an
> app name to resolve) and a tag/branch/commit (or say 'latest stable release')."

Rules for this step:

- The question is mandatory on every request, even if the previous request in
  the session built something, and even if a matching manifest already exists.
  There is no "same as last time" default.
- A committed manifest under `targets/` is an **immutable historical record**
  of a build that already happened — proof of what was built, at which commit,
  under which toolchain. It is never a menu to pick from and never a default.
  Do not offer to "reuse" one; if the user names the same app again, that is a
  new request that produces its own new manifest (a new commit/ref resolves to
  its own `targets/OWNER__REPOSITORY__SHORTSHA.json`).
- Only proceed past this step once the user has explicitly named the
  repository/ref for *this* build. If they are vague ("the streaming app"),
  resolve candidates and confirm the exact repository before continuing.
- Re-running an earlier build for reproducibility is allowed, but only when the
  user explicitly asks for that specific repo+commit again — you still ask, and
  they still answer with the concrete target.

## Per-request procedure (user asks to build an iOS app)

1. **Ask which repository and ref to build** (see the section above — this is
   mandatory and comes first). Then parse the app name / repository / version
   from the user's answer and resolve the official upstream source repository
   (prefer the developer's org; never a random fork just because it has IPA
   releases). Never skip this by reusing a committed manifest.
2. Confirm license (`gh api repos/X/license` or the LICENSE file at the
   pinned tree) or explicit user authorization. No basis → stop, report.
3. Prefer the latest stable (non-draft, non-prerelease) release tag; resolve
   to a 40-char SHA (`git ls-remote` works without auth). Fall back to the
   default-branch head only when there is no stable release, and say so in
   the manifest `notes`.
4. Static probe. Read build docs, upstream CI, `.xcode-version`, dependency
   files. Only if still ambiguous: remote probe via the probe workflow.
5. Write a **new** `targets/OWNER__REPOSITORY__SHORTSHA.json` for this build
   (never edit or reuse an existing one as a default — an existing file with
   the same name means this exact commit was already built, and it stays as
   the historical record); write a narrow adapter under `adapters/` only when
   the structured bootstrap modes don't fit.
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

## Android APK builds (`platform: android`)

The repo also builds **debug-signed Android APKs** from the same kind of
licensed public source (e.g. a Kotlin/Compose Multiplatform monorepo's Android
module). This path is deliberately different from iOS, and it **scopes** — does
not break — the iOS rules above:

- **Installable by design.** Android has no "unsigned installable" concept: an
  APK must be signed to install at all. The Android path builds the **debug**
  variant with the auto-generated Android **debug keystore**, producing an
  installable `*.debug.apk`. The intro line and rules 4/5/9 (unsigned, macOS,
  `*.unsigned.ipa`, "never installable") describe the **iOS** path only. For
  Android: name the result `*.debug.apk`, call it "debug-signed; installable via
  sideload," and **never** call it Play-signed or a release build.
- **Rule 5 still holds, extended.** No Apple signing material, and for Android
  **only the auto debug keystore** — never a release/upload keystore, its
  passwords, or any signing secret in the repo or a manifest. The validator
  bans keystore/signing keys in `extra_build_settings`; keep it that way.
- **Runner (scopes rule 4).** Android builds run on **`ubuntu-latest`**, which
  the manifest's `runner` must declare. There is **no 10x multiplier** on
  ubuntu — Android builds are essentially free vs. the macOS 10x. Do not run
  Android on a macOS runner.
- **Manifest shape.** `platform: "android"`, `runner: "ubuntu-latest"`, and an
  `android` object: `gradle_tasks` (e.g. `[":app:assembleDebug"]`),
  `output_apk` (a relative glob to the built APK), optional `application_id`
  (verified) and `distribution`. The iOS-only fields (`xcode_version`,
  `container`, `scheme`, `configuration`, `build_action`, `output`) are absent.
  Rule 10 (explicit target every time; manifests are immutable records) and the
  full-SHA pin (rule 3) apply unchanged. When one commit is built for both
  platforms, suffix the android manifest name with `_android` to disambiguate.
- **Dispatch/report.** Dispatch `build-apk.yml` (same UUID run-name flow); read
  the JSON report between the `===== BEGIN/END build-manifest.json =====`
  markers. Report: source repo/ref/commit, license, runner, JDK, package
  (application id), `versionName`/`versionCode`, ABIs, `*.debug.apk` filename +
  SHA-256, "debug-signed; installable via sideload; not a release build," and
  how to fetch it.
- **TV / Fire TV honesty.** A phone/tablet Android app with no leanback
  (`LEANBACK_LAUNCHER`) / Android-TV support will install and run on a Fire TV
  device but is a **touch UI driven by a remote** — say so plainly; making it
  TV-native needs app-side changes beyond a narrow compatibility patch.

## Stop-and-report conditions

Binary-only repo; no license/authorization; unresolvable or unfetchable
commit; requested Xcode absent from the image; private dependencies or
credentials required; unavailable proprietary SDK; multiple plausible app
schemes that inspection cannot settle; the build needs source changes beyond
a narrow user-authorized compatibility patch; any identity-bearing signature
or provisioning profile in the output; simulator-only build success.

## Layout

- `.github/workflows/` — `probe-source.yml`, `build-unsigned-ipa.yml` (iOS),
  `build-apk.yml` (android, ubuntu)
- `scripts/` — validation, clone, sandbox wrapper, bootstrap, build/package/
  verify (iOS: `*_unsigned_app`/`package_ipa`/`verify_unsigned_ipa`; android:
  `build_apk`/`package_apk`/`verify_apk`), manifest writer, probe, hardening
  (see headers in each file)
- `bin/` — `build-target`, `probe-source`, `fetch-artifact` (user-local, gh)
- `targets/`, `adapters/`, `schemas/`, `tests/`
- `tests/run_tests.sh` must stay green; it enforces the security invariants
  (SHA pins, read-only permissions, dispatch-only triggers,
  persist-credentials, negative manifest fixtures).
