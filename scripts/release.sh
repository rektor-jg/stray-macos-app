#!/usr/bin/env bash
# Buduje, podpisuje, notaryzuje i pakuje Stray do dystrybucji.
#
# Zakłada, że masz certyfikat "Developer ID Application" i zapisane poświadczenia
# notarytool. Jeśli nie masz — skrypt powie dokładnie, co zrobić, i się zatrzyma.
# Nic nie wysyła bez twojej wiedzy.
set -euo pipefail
cd "$(dirname "$0")/.."

PROFILE="${NOTARY_PROFILE:-stray-notary}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
APP="build/Stray.app"
DMG="build/Stray-${VERSION}.dmg"

say()  { printf "\n\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$*" >&2; exit 1; }

# ─────────────────────────────────────────────────────────────
# 0. Warunki wstępne — sprawdzane ZANIM cokolwiek zbudujemy
# ─────────────────────────────────────────────────────────────
say "Sprawdzam warunki wstępne"

IDENTITY="$(security find-identity -v -p codesigning \
    | grep "Developer ID Application" | head -1 \
    | sed -E 's/.*"(.*)"/\1/')" || true

if [ -z "${IDENTITY:-}" ]; then
    cat >&2 <<'EOF'

✗ Brak certyfikatu "Developer ID Application".

  Masz certyfikat deweloperski, ale on służy tylko do uruchamiania na własnych
  urządzeniach. Do rozdawania aplikacji potrzebny jest inny typ — z tego samego
  (już opłaconego) członkostwa.

  Najprościej przez Xcode, bo załatwia za ciebie całą ceremonię z kluczami:

    Xcode → Settings → Accounts → [twoje konto] → Manage Certificates…
          → przycisk "+" → Developer ID Application

  Potem uruchom ten skrypt ponownie.

EOF
    exit 1
fi
echo "  ✓ certyfikat: $IDENTITY"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF

✗ Brak zapisanych poświadczeń notarytool (profil: $PROFILE).

  Notaryzacja musi się przedstawić Apple. Robi się to RAZ, a hasło ląduje
  w Pęku kluczy — nie w tym repo i nie w żadnym pliku.

  1. Wejdź na appleid.apple.com → Logowanie i zabezpieczenia
     → Hasła dla aplikacji → wygeneruj nowe, nazwij je np. "stray-notary"

  2. Uruchom (podstawiając wygenerowane hasło):

     xcrun notarytool store-credentials "$PROFILE" \\
        --apple-id "TWOJ@APPLE.ID" \\
        --team-id "2PT9GHW4W8" \\
        --password "xxxx-xxxx-xxxx-xxxx"

  Potem uruchom ten skrypt ponownie.

EOF
    exit 1
fi
echo "  ✓ poświadczenia notarytool: $PROFILE"
echo "  ✓ wersja: $VERSION"

# ─────────────────────────────────────────────────────────────
# 1. Build + podpis z hardened runtime
# ─────────────────────────────────────────────────────────────
say "Buduję i podpisuję"
swift build -c release
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Stray "$APP/Contents/MacOS/Stray"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# zasoby lokalizacji wygenerowane przez SwiftPM
if [ -d ".build/release/Stray_Stray.bundle" ]; then
    cp -R ".build/release/Stray_Stray.bundle" "$APP/Contents/Resources/"
fi

# --options runtime = hardened runtime, bez tego Apple odmówi notaryzacji.
# --timestamp = znacznik czasu z serwera Apple, żeby podpis przeżył wygaśnięcie certyfikatu.
codesign --force --options runtime --timestamp \
         --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
echo "  ✓ podpisane"

# ─────────────────────────────────────────────────────────────
# 2. DMG
# ─────────────────────────────────────────────────────────────
say "Pakuję do .dmg"
rm -f "$DMG"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"     # klasyczne "przeciągnij tutaj"
hdiutil create -volname "Stray" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
echo "  ✓ $DMG"

# ─────────────────────────────────────────────────────────────
# 3. Notaryzacja — jedyny krok, który wychodzi do sieci
# ─────────────────────────────────────────────────────────────
say "Wysyłam do notaryzacji (zwykle 2–5 min)"
if ! xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait; then
    echo ""
    echo "Odrzucone. Po szczegóły:"
    echo "  xcrun notarytool log <ID-zgłoszenia> --keychain-profile $PROFILE"
    fail "notaryzacja nieudana"
fi

# ─────────────────────────────────────────────────────────────
# 4. Stapling — naklejka przyklejona do paczki
# ─────────────────────────────────────────────────────────────
say "Przyklejam potwierdzenie"
xcrun stapler staple "$DMG"

# ─────────────────────────────────────────────────────────────
# 5. Weryfikacja oczami Gatekeepera
# ─────────────────────────────────────────────────────────────
say "Sprawdzam tak, jak zrobi to Mac użytkownika"
spctl -a -vvv -t install "$DMG" 2>&1 | sed 's/^/  /'

echo ""
printf "\033[32m✓ Gotowe: %s (%s)\033[0m\n" "$DMG" "$(du -h "$DMG" | cut -f1)"
echo ""
echo "Sprawdź jeszcze na czysto, zanim wypuścisz:"
echo "  xattr -w com.apple.quarantine '0081;00000000;Safari;' $DMG"
echo "  open $DMG        # ma się otworzyć bez żadnego ostrzeżenia"
echo ""
echo "Publikacja:"
echo "  gh release create v$VERSION $DMG --title 'Stray $VERSION' --notes '…'"
