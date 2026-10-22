#!/bin/sh
# Creates a stable code-signing identity for MeetNouse builds, in its own keychain file
# (signing/MeetScribe-signing.keychain-db) — the login keychain is not touched.
#
# Why: macOS remembers permissions (microphone, screen audio, calendar, Documents) per code
# signature. Ad-hoc signatures change on every build, so every update re-asked for all of
# them. With a fixed certificate, permissions survive updates — for you and colleagues.
#
# Back up the signing/ folder (like a keystore): builds signed with a new certificate make
# everyone grant the permissions once more.
set -e
cd "$(dirname "$0")/.."
DIR=signing
KC="$PWD/$DIR/MeetScribe-signing.keychain-db"
NAME="MeetScribe Local Signing"
[ -f "$KC" ] && { echo "Already exists: $KC"; exit 0; }
mkdir -p "$DIR"
PW=$(openssl rand -hex 16)
printf '%s' "$PW" > "$DIR/keychain-password"
chmod 600 "$DIR/keychain-password"

TMP=$(mktemp -d)
cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -config "$TMP/cert.cnf" -extensions ext 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" -out "$TMP/id.p12" -passout "pass:$PW"

BEFORE=$(security list-keychains -d user | tr -d '"')
security create-keychain -p "$PW" "$KC"
security set-keychain-settings "$KC"          # never auto-lock
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
# Keep the user's keychain search list exactly as it was.
security list-keychains -d user -s $BEFORE
rm -rf "$TMP"
echo "Created signing identity \"$NAME\" in $KC"
