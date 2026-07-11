# Target manifests

Each committed JSON manifest here records **one build that already happened**,
named:

```
targets/OWNER__REPOSITORY__SHORT_SHA.json
```

The build workflow takes only the manifest path and a request UUID as inputs —
all build details live in the committed manifest, validated by
`scripts/validate_target.py` (see `schemas/target.schema.json` for the shape).

## These files are immutable historical records, not defaults

A manifest in this directory is a record of what was built (source repo, exact
commit, toolchain), kept so a past build is auditable and reproducible. It is
**not** a menu, a template, or a default for the next build:

- Every new build starts by explicitly asking the user which repository and ref
  to build (see `CLAUDE.md` → "Target selection is always an explicit first
  step"). Never silently reuse a file here because it matches an app name or
  because it was the last thing built.
- Don't edit an existing manifest to retarget it. A different commit is a
  different build → a new file with its own `SHORT_SHA`. The presence of a file
  with a given name simply means that exact commit was already built.
- Re-running an existing manifest verbatim is fine only when the user
  explicitly asks to rebuild that specific repo+commit again.

Rules:

- `source.commit` pins the exact 40-character commit; the workflow verifies
  the fetched tree matches before building.
- The source must have an explicit license (`license_spdx`, `license_file`)
  or the user must have stated they own/are authorized to build it — record
  that in `notes`.
- Signing-related settings cannot be smuggled in via `extra_build_settings`;
  the validator rejects them.
- Unknown keys are rejected (typos fail loudly instead of being ignored).
- `timeout_minutes` (10–180, default 90) caps the macOS job. macOS minutes
  bill at 10x on private repos — size it honestly.
