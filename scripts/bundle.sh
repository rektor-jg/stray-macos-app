#!/usr/bin/env bash
# Składa .app z binarki SwiftPM. MenuBarExtra potrzebuje pełnego bundla
# (Info.plist z LSUIElement), inaczej nie ma tożsamości aplikacji ani ikony w pasku.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
swift build -c "$CONFIG"

BIN=".build/$CONFIG/Stray"
APP="build/Stray.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Stray"
cp App/Info.plist "$APP/Contents/Info.plist"

# Podpis STABILNĄ tożsamością, jeśli jest dostępna.
#
# Podpis ad-hoc wylicza tożsamość z sumy kontrolnej binarki, więc zmienia się przy
# KAŻDYM buildzie — a macOS wiąże zgody (powiadomienia, dostęp do Dokumentów i Biurka)
# właśnie z tożsamością. Efekt: przy każdym uruchomieniu aplikacja pyta o wszystko
# od nowa. Certyfikat deweloperski daje tożsamość niezmienną między buildami,
# więc zgoda wydana raz zostaje na stałe.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | grep -E "Developer ID Application|Apple Development" | head -1 \
    | sed -E 's/.*"(.*)"/\1/')"

if [ -n "${IDENTITY:-}" ]; then
    codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null \
        && echo "podpisane: $IDENTITY" \
        || codesign --force --sign - "$APP" 2>/dev/null
else
    echo "brak certyfikatu — podpis ad-hoc (system będzie pytał o zgody po każdym buildzie)"
    codesign --force --sign - "$APP" 2>/dev/null || true
fi

echo "gotowe: $APP"
echo "uruchom:  open $APP"
echo "skan CLI: $APP/Contents/MacOS/Stray --scan"
