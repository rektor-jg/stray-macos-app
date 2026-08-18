# Dystrybucja — jak to działa

Notatka dla siebie na później, bo tę wiedzę potrzebuje się raz na pół roku
i za każdym razem od zera.

## Bramkarz i trzy różne rzeczy, które łatwo pomylić

macOS ma przy drzwiach bramkarza — **Gatekeeper**. Przed pierwszym uruchomieniem
pobranej aplikacji zadaje dwa pytania: *kto to zrobił* i *czy Apple to obejrzało*.

| Rzecz | Czym jest naprawdę | Czym NIE jest |
|---|---|---|
| **Podpis** (`codesign`) | twoja pieczęć: dowód autorstwa i tego, że plik nie został podmieniony | nie jest żadnym sprawdzeniem przez Apple |
| **Notaryzacja** (`notarytool`) | Apple skanuje binarkę automatem i wystawia potwierdzenie „czyste" | **nie jest App Review** — nie ma człowieka, nie ma oceny jakości, trwa minuty, jest darmowa |
| **Stapling** (`stapler`) | przyklejenie potwierdzenia do paczki | — |

Bez staplingu Mac użytkownika musi zapytać serwer Apple przy pierwszym uruchomieniu.
Bez internetu aplikacja się nie odpali. Stapling to załatwia raz na zawsze.

## Co widzi człowiek po drugiej stronie

| Poziom | Doświadczenie użytkownika |
|---|---|
| ad-hoc | Ustawienia → Prywatność → „Otwórz mimo to". Od macOS 15 nie ma obejścia przez Ctrl+klik |
| Developer ID bez notaryzacji | to samo ostrzeżenie — sam podpis nie wystarcza od 2019 |
| Developer ID + notaryzacja + stapling | dwuklik, zero ostrzeżeń |

## Dwa certyfikaty, które brzmią podobnie i robią co innego

```
Apple Development        → uruchamianie na WŁASNYCH urządzeniach
Developer ID Application → rozdawanie POZA App Store         ← ten jest potrzebny
```

Oba pochodzą z tego samego, już opłaconego członkostwa. Wygenerowanie drugiego
jest darmowe i zajmuje kilka minut:

> Xcode → Settings → Accounts → [konto] → Manage Certificates… → „+" → Developer ID Application

Xcode robi przy tym całą ceremonię z kluczem prywatnym i CSR-em, której inaczej
trzeba by przechodzić ręcznie w Keychain Access.

## Poświadczenia do notaryzacji — raz w życiu

Notaryzacja musi się przedstawić Apple. Hasło ląduje w Pęku kluczy, nie w repo:

```bash
# 1. appleid.apple.com → Logowanie i zabezpieczenia → Hasła dla aplikacji
# 2. jednorazowo:
xcrun notarytool store-credentials "stray-notary" \
   --apple-id "twoj@apple.id" \
   --team-id "2PT9GHW4W8" \
   --password "xxxx-xxxx-xxxx-xxxx"
```

To hasło **nie jest** hasłem do Apple ID — to osobne hasło aplikacyjne, które
można w każdej chwili unieważnić bez ruszania konta.

## Potem już tylko

```bash
./scripts/release.sh
```

Skrypt sprawdza warunki wstępne **zanim** cokolwiek zbuduje, więc jak czegoś brakuje,
powie czego i się zatrzyma. Kolejno: build → podpis z hardened runtime → `.dmg` →
notaryzacja → stapling → weryfikacja oczami Gatekeepera.

### Dlaczego hardened runtime niczego tu nie psuje

Apple wymaga hardened runtime do notaryzacji, a on domyślnie odcina aplikacji
kilka możliwości. Sprawdzone: **Stray żadnej z nich nie potrzebuje.**

- `libproc` (`proc_pidinfo`, `proc_pid_rusage`) działa bez entitlementów
- `sample` odpalamy jako **osobny proces Apple'a** — to on podpina się do celu,
  nie my, więc `com.apple.security.cs.debugger` jest zbędny
- `du` to zwykły podproces
- brak sieci, brak JIT-a, brak wczytywania cudzych bibliotek

## Test na czysto przed wypuszczeniem

Zbudowany lokalnie plik nie ma znacznika kwarantanny, więc otworzy się nawet wtedy,
gdy dla pobranego pliku by się nie otworzył. Żeby sprawdzić to naprawdę:

```bash
xattr -w com.apple.quarantine '0081;00000000;Safari;' build/Stray-0.5.0.dmg
open build/Stray-0.5.0.dmg     # ma być bez ostrzeżenia
```

## App Store — dlaczego to niemożliwe

Nie jest to kwestia chęci ani opłat. Stray żyje z odczytu `proc_pidinfo`
i `proc_pid_rusage` na **cudzych** procesach. Sandbox App Store'a odcina dokładnie to.
Aplikacja w sandboxie widziałaby wyłącznie samą siebie, czyli byłaby monitorem
samej siebie. Cała funkcja przestaje istnieć.

## Homebrew cask — dopiero po upublicznieniu repo

Cask wymaga publicznego repozytorium i stabilnego URL-a do artefaktu.
Szkic leży w `packaging/stray.rb`; po pierwszym wydaniu trzeba w nim podmienić
`sha256` na sumę z `shasum -a 256 build/Stray-X.Y.Z.dmg`.
