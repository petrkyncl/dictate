#!/usr/bin/env bash
# Vyrobi self-signed podepisovaci certifikat v login keychain.
#
# PROC: s ad-hoc podpisem (codesign -s -) se otisk binarky meni pri kazdem
# buildu, macOS to bere jako jinou aplikaci a SMAZE udelena opravneni
# (Accessibility, mikrofon). Se stabilni identitou opravneni prezijou rebuild.
# Zadny Apple Developer Program ($99/rok) na to neni potreba.
set -euo pipefail
NAME="Dictate Local Signing"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "✓ certifikát „$NAME\" už existuje"; exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/ext.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3
[dn]
CN = Dictate Local Signing
[v3]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" -config "$tmp/ext.cnf" 2>/dev/null
# macOS neumi precist PKCS12 s vychozimi algoritmy OpenSSL 3 —
# musi se vynutit starsi sada, jinak import spadne na "MAC verification failed".
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
  -name "$NAME" -out "$tmp/id.p12" -passout pass:dictate \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 2>/dev/null

security import "$tmp/id.p12" -k ~/Library/Keychains/login.keychain-db \
  -P dictate -T /usr/bin/codesign -A >/dev/null

echo "✓ certifikát „$NAME\" vytvořen"
echo
echo "ZBÝVÁ JEDEN KROK, KTERÝ MUSÍŠ SPUSTIT SÁM (chce heslo ke klíčence):"
echo
echo "  security set-key-partition-list -S apple-tool:,apple:,codesign: \\"
echo "    -s -l \"$NAME\" ~/Library/Keychains/login.keychain-db"
echo
echo "Bez něj macOS nepustí codesign ke klíči (errSecInternalComponent)"
echo "a build použije ad-hoc podpis — appka pojede, ale po každém rebuildu"
echo "budeš znovu udělovat oprávnění."
