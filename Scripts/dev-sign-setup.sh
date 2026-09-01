#!/usr/bin/env bash
# One-time: create a STABLE self-signed code-signing identity for local dev, so
# the Screen Recording (TCC) grant survives rebuilds. Ad-hoc (`--sign -`) changes
# identity every build and orphans the grant — this fixes that.
#
# Idempotent: re-running reuses the existing identity.
set -euo pipefail

IDENTITY="Glance Dev"
KC="$HOME/Library/Keychains/glance-signing.keychain-db"
KC_PASS="glance"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# No -v: a self-signed cert is "untrusted" and -v (valid-only) never lists it,
# which made this guard miss and re-runs pile up duplicate identities —
# codesign then fails with "ambiguous".
if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✔ signing identity '$IDENTITY' already exists"
    exit 0
fi

echo "▶ creating keychain + self-signed code-signing cert ($IDENTITY)"
security create-keychain -p "$KC_PASS" "$KC" 2>/dev/null || true
security unlock-keychain -p "$KC_PASS" "$KC"
security set-keychain-settings "$KC"   # no auto-lock timeout

# Cert with the Code Signing EKU so codesign accepts it.
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# -legacy: Apple's security(1) can't read OpenSSL 3's default PKCS12 MAC.
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout "pass:$KC_PASS" -name "$IDENTITY"

# Import; grant codesign non-interactive access to the private key.
security import "$WORK/id.p12" -k "$KC" -P "$KC_PASS" -T /usr/bin/codesign -A
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KC_PASS" "$KC" >/dev/null

# Make the keychain visible to codesign's identity search.
EXISTING=$(security list-keychains -d user | sed 's/[" ]//g' | tr '\n' ' ')
security list-keychains -d user -s "$KC" $EXISTING

echo "✔ created '$IDENTITY'. build-app.sh will use it automatically."
