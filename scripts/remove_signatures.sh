#!/usr/bin/env bash
# Remove signing material from the packaged app tree (trusted step, macOS).
#
# Policy: the arm64 linker ALWAYS writes an ad-hoc LC_CODE_SIGNATURE even with
# signing disabled. Ad-hoc signatures carry no identity and are replaced by
# any downstream re-sign, so they are left in place (stripping Mach-O
# signatures is where corruption bugs live). What must not remain is
# IDENTITY-bearing material:
#   - _CodeSignature directories and stray CodeResources files
#   - embedded.mobileprovision provisioning profiles
#   - SC_Info directories (never legitimate in a source build)
#   - any Mach-O signature that names an Authority or a team
set -euo pipefail

: "${BUILD_DIR:?}"
PAYLOAD="$BUILD_DIR/package/Payload"
test -d "$PAYLOAD"

echo "Removing signature directories and provisioning profiles"
find "$PAYLOAD" -depth -type d -name '_CodeSignature' -exec rm -rf {} +
find "$PAYLOAD" -depth -type d -name 'SC_Info' -exec rm -rf {} +
find "$PAYLOAD" -type f -name 'embedded.mobileprovision' -delete
find "$PAYLOAD" -type f -name 'CodeResources' -delete
find "$PAYLOAD" -type l -name 'CodeResources' -delete

is_macho() {
    local magic
    magic="$(xxd -p -l 4 "$1" 2>/dev/null || true)"
    case "$magic" in
        feedface|cefaedfe|feedfacf|cffaedfe|cafebabe|bebafeca|cafebabf|bfbafeca) return 0 ;;
        *) return 1 ;;
    esac
}

echo "Stripping identity-bearing Mach-O signatures (deepest first)"
stripped=0
while IFS= read -r -d '' f; do
    is_macho "$f" || continue
    info="$(codesign -dvv -- "$f" 2>&1 || true)"
    case "$info" in
        *"not signed at all"*) continue ;;
    esac
    if printf '%s' "$info" | grep -q -e '^Authority=' -e 'TeamIdentifier=[A-Z0-9]'; then
        echo "  removing identity-bearing signature: ${f#"$PAYLOAD"/}"
        codesign --remove-signature -- "$f"
        stripped=$((stripped + 1))
    fi
done < <(find "$PAYLOAD" -depth -type f -print0)

echo "Done. Identity-bearing signatures removed: $stripped (ad-hoc linker signatures are kept by policy)"
