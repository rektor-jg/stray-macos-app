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
cp Resources/Info.plist "$APP/Contents/Info.plist"

# podpis ad-hoc — wystarcza lokalnie; Developer ID i notaryzacja dopiero w v1.0
codesign --force --sign - "$APP" 2>/dev/null || echo "uwaga: codesign pominięty"

echo "gotowe: $APP"
echo "uruchom:  open $APP"
echo "skan CLI: $APP/Contents/MacOS/Stray --scan"
