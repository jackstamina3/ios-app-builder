# Target manifests

Every buildable app is described by one committed JSON manifest here, named:

```
targets/OWNER__REPOSITORY__SHORT_SHA.json
```

The build workflow takes only the manifest path and a request UUID as inputs —
all build details live in the committed manifest, validated by
`scripts/validate_target.py` (see `schemas/target.schema.json` for the shape).

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
