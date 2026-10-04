#!/usr/bin/env bash
# Verify publishing behavior without touching the real bundle or signing keys.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="$(mktemp -d)"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/Scripts" "$FIXTURE/bin" "$FIXTURE/product" "$FIXTURE/build/Glance.app"
cp "$ROOT/Scripts/build-app.sh" "$FIXTURE/Scripts/"
printf 'previous app\n' > "$FIXTURE/build/Glance.app/previous"
printf 'new executable\n' > "$FIXTURE/product/Glance"
export GLANCE_TEST_PRODUCT="$FIXTURE/product"
export GLANCE_SIGNING_KEYCHAIN="$FIXTURE/signing.keychain-db"

cat > "$FIXTURE/bin/swift" <<'MOCK'
#!/usr/bin/env bash
if [[ " $* " == *" --show-bin-path "* ]]; then echo "$GLANCE_TEST_PRODUCT"; fi
MOCK
cat > "$FIXTURE/bin/security" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GLANCE_TEST_PRODUCT/security-args"
if [[ "$1" == find-identity ]]; then echo '  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Glance Dev"'; fi
MOCK
cat > "$FIXTURE/bin/codesign" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$GLANCE_TEST_PRODUCT/codesign-args"
if [[ "$1" == --verify ]]; then exit "${GLANCE_TEST_VERIFY_FAILURE:-0}"; fi
exit "${GLANCE_TEST_SIGN_FAILURE:-0}"
MOCK
chmod +x "$FIXTURE/bin/"*
export PATH="$FIXTURE/bin:$PATH"

if GLANCE_TEST_SIGN_FAILURE=1 bash "$FIXTURE/Scripts/build-app.sh" debug > "$FIXTURE/log" 2>&1; then
    echo 'FAIL: signing failure was reported as success'; exit 1
fi
if [[ ! -f "$FIXTURE/build/Glance.app/previous" ]]; then
    echo 'FAIL: signing failure replaced the previous app'; exit 1
fi

if GLANCE_TEST_VERIFY_FAILURE=1 bash "$FIXTURE/Scripts/build-app.sh" debug > "$FIXTURE/log" 2>&1; then
    echo 'FAIL: invalid signature was reported as success'; exit 1
fi
if [[ ! -f "$FIXTURE/build/Glance.app/previous" ]]; then
    echo 'FAIL: invalid signature replaced the previous app'; exit 1
fi

bash "$FIXTURE/Scripts/build-app.sh" debug > "$FIXTURE/log" 2>&1
if ! grep -Fq -- "$GLANCE_SIGNING_KEYCHAIN" "$GLANCE_TEST_PRODUCT/security-args"; then
    echo 'FAIL: build ignored the configured signing keychain'; exit 1
fi
if ! grep -Fq -- '0123456789ABCDEF0123456789ABCDEF01234567' "$GLANCE_TEST_PRODUCT/codesign-args"; then
    echo 'FAIL: build selected an ambiguous certificate name instead of its fingerprint'; exit 1
fi
if [[ -f "$FIXTURE/build/Glance.app/previous" ]] ||
   ! cmp -s "$FIXTURE/product/Glance" "$FIXTURE/build/Glance.app/Contents/MacOS/Glance"; then
    echo 'FAIL: successful signing did not publish the new app'; exit 1
fi
echo 'PASS: signing failures preserve the previous app; verified builds replace it'
