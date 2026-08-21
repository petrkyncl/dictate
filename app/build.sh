#!/usr/bin/env bash
# Slozi Dictate.app a podepise ji stabilni identitou.
#
# Zadny Apple Developer Program, zadna notarizace: Gatekeeper resi jen
# aplikace s quarantine atributem, tedy stazene z internetu. Lokalne
# zbuildena app ho nema.
set -euo pipefail
cd "$(dirname "$0")"

CONFIG="${1:-release}"
APP="build/Dictate.app"
IDENTITY="Dictate Local Signing"

./make-cert.sh

echo "▸ kompiluji ($CONFIG)…"
swift build -c "$CONFIG"
BIN=$(swift build -c "$CONFIG" --show-bin-path)/Dictate

echo "▸ skládám bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Dictate"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ podepisuji…"
# Stabilni identita drzi opravneni (Accessibility, mikrofon) pres rebuildy.
# Kdyz na klic nejde (chybi partition list, ktery chce heslo ke klicence),
# radsi ad-hoc nez nepodepsana app — jen se budou opravneni resetovat.
if codesign --force --sign "$IDENTITY" --identifier cz.kyncl.dictate             --timestamp=none "$APP" 2>/dev/null; then
    echo "   podepsáno certifikátem „$IDENTITY\""
    SIGNED_STABLE=1
else
    codesign --force --sign - --identifier cz.kyncl.dictate "$APP" 2>&1 | sed 's/^/   /'
    echo "   ⚠ ad-hoc podpis — oprávnění se po každém buildu resetují"
    SIGNED_STABLE=0
fi

echo
codesign -d -r- "$APP" 2>&1 | grep '^designated' | sed 's/^/   /'
echo
echo "✓ hotovo: $(pwd)/$APP"
if [ "$SIGNED_STABLE" = "0" ]; then
    echo
    echo "Pro stabilní oprávnění spusť jednou (chce heslo ke klíčence):"
    echo "  security set-key-partition-list -S apple-tool:,apple:,codesign: \\"
    echo "    -s -l \"$IDENTITY\" ~/Library/Keychains/login.keychain-db"
    echo "  a pak znovu ./build.sh"
fi
echo
echo "Spuštění:   open $APP"
echo "Oprávnění:  System Settings → Privacy & Security → Accessibility (+ Microphone)"
