#!/usr/bin/env bash
# One-time setup: create a stable self-signed code-signing identity for LOCAL dev builds.
#
# Why: `bundle.sh` builds an unsigned app, so macOS falls back to an ad-hoc signature whose
# code identity (cdhash) changes on every rebuild. macOS TCC keys Accessibility and Automation
# grants on that identity, so every rebuild invalidates them — you'd re-grant (and re-approve
# Automation prompts) constantly. Signing each dev build with ONE persistent self-signed cert
# gives it a stable designated requirement, so a grant you give once keeps working across
# rebuilds. (The shipped release is Developer-ID signed by release.sh and already stable — this
# is purely a dev-ergonomics helper and is never used for distribution.)
#
# Run once:  bash Scripts/dev-cert.sh
# Then just `bash Scripts/bundle.sh` as usual — it signs with this identity automatically.
set -euo pipefail

IDENTITY="Agent Isle Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$IDENTITY"; then
  echo "▸ Identity '$IDENTITY' already exists — nothing to do."
  exit 0
fi

echo "▸ Creating self-signed code-signing identity '$IDENTITY'…"
DIR="$(mktemp -d)"
trap 'rm -rf "$DIR"' EXIT

# Config-file form works on both macOS LibreSSL and OpenSSL (unlike the newer -addext flag).
cat > "$DIR/openssl.cnf" <<'CNF'
[req]
distinguished_name = dn
x509_extensions    = v3
prompt             = no
[dn]
CN = Agent Isle Dev
[v3]
basicConstraints   = critical,CA:false
keyUsage           = critical,digitalSignature
extendedKeyUsage   = critical,codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$DIR/key.pem" -out "$DIR/cert.pem" -config "$DIR/openssl.cnf" >/dev/null 2>&1

# OpenSSL 3.x defaults to a PKCS12 MAC that macOS's Security framework can't verify; its
# `-legacy` flag restores a compatible one. LibreSSL (the system openssl) has no `-legacy`
# flag and already writes a compatible MAC, so only pass it when supported.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -out "$DIR/identity.p12" \
  -inkey "$DIR/key.pem" -in "$DIR/cert.pem" -passout pass:agentisle >/dev/null 2>&1

# Import the key+cert and grant codesign access so signing doesn't prompt each time.
security import "$DIR/identity.p12" -k "$KEYCHAIN" -P agentisle -T /usr/bin/codesign >/dev/null

echo "✓ Created '$IDENTITY' in your login keychain."
echo "  Next: run 'bash Scripts/bundle.sh' — dev builds now sign with a stable identity."
echo "  The first codesign/launch may ask to allow keychain access — click Always Allow."
echo "  Grant Accessibility/Automation to 'Agent Isle (dev)' once; it will now persist across rebuilds."
