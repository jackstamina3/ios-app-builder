#!/usr/bin/env bash
# Static validation suite. Must stay green; enforces the security invariants.
set -uo pipefail

cd "$(dirname "$0")/.."
FAILURES=0

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# --- 1. shell syntax ---------------------------------------------------------
for f in scripts/*.sh bin/* adapters/*.sh; do
    [ -e "$f" ] || continue
    if bash -n "$f"; then pass "bash -n $f"; else fail "bash -n $f"; fi
done
if command -v shellcheck >/dev/null 2>&1; then
    for f in scripts/*.sh bin/* adapters/*.sh; do
        [ -e "$f" ] || continue
        if shellcheck -S warning "$f" >/dev/null; then pass "shellcheck $f"; else fail "shellcheck $f"; fi
    done
else
    echo "NOTE: shellcheck not installed; skipping lint (bash -n still ran)"
fi

# --- 1b. no Bash 4+ constructs (macOS runners ship Bash 3.2) ------------------
for f in scripts/*.sh bin/* adapters/*.sh; do
    [ -e "$f" ] || continue
    if grep -nE '(mapfile|readarray|declare[[:space:]]+-A|\$\{[A-Za-z_]+\^\^|\$\{[A-Za-z_]+,,)' "$f" >/dev/null; then
        fail "$f: uses a Bash 4+ construct (breaks on macOS /bin/bash 3.2)"
    else
        pass "$f: no Bash 4+ constructs"
    fi
done

# --- 2. python syntax --------------------------------------------------------
for f in scripts/*.py; do
    if python3 -m py_compile "$f" 2>/dev/null; then pass "py_compile $f"; else fail "py_compile $f"; fi
done

# --- 3. workflow YAML parses -------------------------------------------------
for f in .github/workflows/*.yml; do
    if python3 - "$f" <<'PYEOF'
import sys
try:
    import yaml
except ImportError:
    print(f"NOTE: PyYAML unavailable; skipped parse of {sys.argv[1]}")
    sys.exit(0)
with open(sys.argv[1]) as fh:
    yaml.safe_load(fh)
PYEOF
    then pass "yaml parse $f"; else fail "yaml parse $f"; fi
done

# --- 4. workflow security invariants -----------------------------------------
for f in .github/workflows/*.yml; do
    # every uses: is a full 40-hex SHA pin
    if grep -E '^\s*uses:' "$f" | grep -vE 'uses:\s+\S+@[0-9a-f]{40}\s*(#.*)?$' >/dev/null; then
        fail "$f: unpinned uses: line"
    else
        pass "$f: all actions pinned to full SHAs"
    fi
    # only GitHub-owned actions
    if grep -E '^\s*uses:' "$f" | grep -vE 'uses:\s+actions/' >/dev/null; then
        fail "$f: non actions/* action referenced"
    else
        pass "$f: GitHub-owned actions only"
    fi
    # dispatch-only trigger
    if grep -E '^\s*(push|pull_request|pull_request_target|issue_comment|schedule|workflow_run|release):' "$f" >/dev/null; then
        fail "$f: forbidden trigger present"
    else
        pass "$f: workflow_dispatch-only trigger"
    fi
    # no write permissions
    if grep -E '^\s*[a-z-]+:\s*write' "$f" >/dev/null; then
        fail "$f: write permission found"
    else
        pass "$f: no write permissions"
    fi
    # every checkout sets persist-credentials: false
    CHECKOUTS=$(grep -cE 'uses:\s+actions/checkout@' "$f" || true)
    PERSISTS=$(grep -cE 'persist-credentials:\s*false' "$f" || true)
    if [ "$CHECKOUTS" -eq "$PERSISTS" ]; then
        pass "$f: persist-credentials: false on all $CHECKOUTS checkouts"
    else
        fail "$f: $CHECKOUTS checkouts but $PERSISTS persist-credentials: false"
    fi
    # no secrets usage
    if grep -F 'secrets.' "$f" >/dev/null; then
        fail "$f: references secrets"
    else
        pass "$f: no secrets referenced"
    fi
    # artifact retention pinned to 7 days
    if grep -E 'retention-days:\s*7' "$f" >/dev/null; then
        pass "$f: 7-day artifact retention"
    else
        fail "$f: artifact retention not set to 7"
    fi
done

# --- 4b. runs-on labels come from the fixed table, never from manifest text ----
# A manifest names a runner key; validate_target.py maps it to labels. If a
# manifest could ever reach runs-on directly it could steer a build onto an
# arbitrary self-hosted machine, so assert both halves of that contract.
if grep -E 'runs-on:\s*\$\{\{\s*fromJSON\(needs\.plan\.outputs\.runner_labels\)\s*\}\}' \
        .github/workflows/build-unsigned-ipa.yml >/dev/null; then
    pass "build-unsigned-ipa.yml: runs-on derives from the validated label table"
else
    fail "build-unsigned-ipa.yml: runs-on must use fromJSON(runner_labels)"
fi

python3 - <<'PYEOF'
import json
import subprocess
import sys

sys.path.insert(0, "scripts")
import validate_target as vt

known = set(vt.ALLOWED_RUNNERS) | set(vt.ANDROID_RUNNERS)
if known != set(vt.RUNNER_LABELS):
    print(f"FAIL: RUNNER_LABELS does not cover every allowed runner: "
          f"{known ^ set(vt.RUNNER_LABELS)}", file=sys.stderr)
    sys.exit(1)
print("PASS: every allowed runner has a label mapping")

for runner, labels in vt.RUNNER_LABELS.items():
    if not labels or not all(isinstance(l, str) and l for l in labels):
        print(f"FAIL: {runner} has a malformed label list: {labels!r}", file=sys.stderr)
        sys.exit(1)
print("PASS: every label list is a non-empty list of strings")

# The emitted output must be exactly the table's value for the manifest's key.
for path in ("targets/NuvioMedia__NuvioMobile__f9ad843.json",
             "targets/NuvioMedia__NuvioMobile__60cde30.json"):
    out = subprocess.run(
        ["python3", "scripts/validate_target.py", path, "--emit-github-outputs"],
        capture_output=True, text=True, check=True).stdout
    emitted = dict(line.split("=", 1) for line in out.strip().splitlines())
    expected = vt.RUNNER_LABELS[emitted["runner"]]
    if json.loads(emitted["runner_labels"]) != expected:
        print(f"FAIL: {path} emitted labels {emitted['runner_labels']} != {expected}",
              file=sys.stderr)
        sys.exit(1)
    print(f"PASS: {path} emits the table's labels for {emitted['runner']}")
PYEOF
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

# --- 5. manifest validator: positive fixtures + real targets ------------------
for f in tests/fixtures/valid/*.json targets/*.json; do
    [ -e "$f" ] || continue
    if python3 scripts/validate_target.py "$f" >/dev/null; then
        pass "validator accepts $f"
    else
        fail "validator rejects valid manifest $f"
    fi
done

# --- 6. manifest validator: negative fixtures MUST fail -----------------------
for f in tests/fixtures/invalid/*.json; do
    if python3 scripts/validate_target.py "$f" >/dev/null 2>&1; then
        fail "validator ACCEPTED invalid fixture $f"
    else
        pass "validator rejects $f"
    fi
done

# --- 7. optional jsonschema cross-check ---------------------------------------
python3 - <<'PYEOF'
import glob, json, sys
try:
    import jsonschema
except ImportError:
    print("NOTE: jsonschema module unavailable; schema cross-check skipped")
    sys.exit(0)
with open("schemas/target.schema.json") as f:
    schema = json.load(f)
ok = True
for path in glob.glob("tests/fixtures/valid/*.json") + glob.glob("targets/*.json"):
    with open(path) as f:
        try:
            jsonschema.validate(json.load(f), schema)
            print(f"PASS: jsonschema accepts {path}")
        except jsonschema.ValidationError as e:
            print(f"FAIL: jsonschema rejects {path}: {e.message}", file=sys.stderr)
            ok = False
sys.exit(0 if ok else 1)
PYEOF
[ $? -eq 0 ] || FAILURES=$((FAILURES + 1))

# --- 8. gitignore covers dist/ and signing material ----------------------------
for pat in 'dist/' '*.ipa' '*.apk' '*.keystore' '*.p12' '*.mobileprovision' '*.key'; do
    if grep -qxF "$pat" .gitignore; then
        pass ".gitignore covers $pat"
    else
        fail ".gitignore missing $pat"
    fi
done

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo "ALL TESTS PASSED"
else
    echo "$FAILURES TEST(S) FAILED" >&2
    exit 1
fi
