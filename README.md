# Stray

**Menu-bar app dla macOS, która łapie to, co agenty AI (Claude Code, Codex, Cursor) zostawiają po sobie w systemie: procesy zakleszczone, osierocone i przeciekające — oraz artefakty dyskowe, które przeżyły swój projekt.**

Nie jest to kolejny monitor systemu. Activity Monitor pokaże ci, że *coś* zżera CPU.
Stray mówi ci **czyje to jest, czy to jeszcze robi cokolwiek sensownego i czy można to ubić.**

---

## 1. Problem — case study z 18 sierpnia 2026

Punkt wyjścia był banalny: wentylatory, `Idle: 0,93%`, a w Activity Monitorze `Python` na 72% CPU
z czasem procesora **4:48:35**. Bez nazwy skryptu, bez kontekstu — sam `Python`.

Śledztwo (`ps -ww`, `sample`) dało pełny obraz:

```
PID 60858  Python        ← 6 h 51 m, 95% CPU, 1 wątek
  └─ PPID 60836  zsh -c '... npx tsc --noEmit ... python3 - <<PY ...'
       └─ PPID 2061  claude.exe
```

To był **skrypt wygenerowany przez agenta w poprzedniej sesji** — heurystyka szukająca
nieużywanych importów w `app/**/*.tsx`. Zawiesiła się na tym wyrażeniu:

```python
re.sub(r"^import[^\n]*\n(?:\s+[^\n]*\n)*?(?:.*?from '[^']+'\n)", '', t, flags=re.M)
```

Zagnieżdżone leniwe kwantyfikatory → **catastrophic backtracking**. `sample 60858` pokazał stos
zakopany w silniku `sre`. Ten proces nigdy by się nie skończył. Sesja agenta czekała na jego
output przez 7 godzin.

### Przy okazji wyszło coś gorszego

Skan całego systemu ujawnił dwa **osierocone dev-serwery** (`PPID == 1`, czyli sesja, która je
uruchomiła, dawno umarła, a launchd je adoptował):

| PID | Komenda | Uruchomione | RAM | Port |
|---|---|---|---|---|
| 12672 → 12690 | `npm exec next dev -p 3111` | 13:28 (4 h 37 m) | ~654 MB | 3111 |
| 39845 → 39861 | `npm exec expo start --port 8081` | 17:06 (59 m) | ~443 MB | 8081 |

~1,1 GB RAM i dwa zajęte porty. **Żaden z nich nie był widoczny jako problem** — nie zużywały CPU,
po prostu leżały. Klasyczny osad po vibecodowaniu: każda sesja agenta startuje dev-serwer,
żadna go nie sprząta.

### Wniosek

Agenty AI generują nową klasę śmieci systemowych, której żadne istniejące narzędzie nie rozumie,
bo żadne nie wie, czym jest **sesja agenta**.

---

## 2. Kluczowa teza: zakleszczenie ma sygnaturę

To jest serce produktu. Próg „CPU > 80%" jest bezużyteczny — build Xcode też trzyma 100% i to jest
poprawne. Ale w tym samym zrzucie z Activity Monitora sygnatura była widoczna gołym okiem:

```
Python    72,0%   Threads: 1     Idle Wake-Ups: 0     ← kręci się w miejscu
iTerm2    22,5%   Threads: 9     Idle Wake-Ups: 209   ← zdrowy
Brave     18,9%   Threads: 25    Idle Wake-Ups: 265   ← zdrowy
```

> **Wysokie CPU + 1 wątek + zero wybudzeń + zero I/O dyskowego + długi czas życia
> = pętla bez postępu.**

Kompilator, bundler czy test suite mają dziesiątki wybudzeń na sekundę i nieustannie piszą na dysk.
Proces zakopany w regexie nie robi *nic* poza paleniem cykli. Ta różnica jest mierzalna, tania
w odczycie i ma bardzo wysoką precyzję — i to ona pozwala nie zasypywać użytkownika fałszywymi
alarmami przy każdym legalnym buildzie.

---

## 3. Detektory

| # | Nazwa | Sygnał | Pewność | Domyślna akcja |
|---|---|---|---|---|
| **D1** | **Spinner** | CPU > 70% przez ≥ 90 s **AND** `threadnum == 1` **AND** Δwakeups ≈ 0 **AND** Δdisk I/O == 0 | wysoka | alert + auto-`sample` + jeden klik kill |
| **D2** | **Orphan** | `PPID == 1` **AND** komenda pasuje do wzorca dev-toola **AND** wiek > 30 min | średnia | cicha lista; alert dopiero po D5 |
| **D3** | **Leak** | RSS rośnie monotonicznie w ≥ 8 z 10 próbek (okno 10 min) **AND** przyrost > 200 MB | średnia | sparkline + ostrzeżenie |
| **D4** | **Herd** | ≥ 2 żywe instancje tego samego typu serwera (`next dev`, `metro`, `vite`) z różnych sesji | wysoka | lista „który jest faktycznie używany" |
| **D5** | **Dead port** | proces w `LISTEN` **AND** 0 połączeń `ESTABLISHED` przez > 60 min | wysoka | kandydat do sprzątnięcia |
| **D6** | **Disk burn** | zapis > 2 GB/h przez proces nie-buildowy | średnia | ostrzeżenie (pętla logów) |

Wszystkie progi konfigurowalne. Detektory to czyste funkcje `(okno próbek) -> [Finding]` —
łatwe do testowania offline na nagranych sesjach.

---

---

## 3b. Drugi front: dysk

Pomiar z tej samej maszyny, 18 sierpnia 2026. Dysk: **382 / 460 GB zajęte, 44 GB wolne (90%).**

| Katalog | Rozmiar |
|---|---|
| `~/Library/Developer/Xcode/DerivedData` | 25 G |
| `~/Library/Containers/com.docker.docker` | 24 G |
| `~/Library/Developer/CoreSimulator` | 15 G |
| `~/.gradle` | 15 G |
| `~/Library/Caches` | 13 G |
| `~/.npm/_cacache` | **12 G** |
| `~/Documents/Repos` (w tym 5,8 G `node_modules` w 6 repo) | 13 G |
| `~/.cache` | 5,6 G |
| `~/.claude` (900 M) + scratchpady sesji (431 M) | **1,3 G** |

### Kluczowe rozróżnienie

Intuicja mówi „AI zapycha temp". Liczby mówią co innego: **dosłowny temp agenta to 1,3 GB — czyli
nic.** Szkody są **pośrednie**. Agent nie zapycha dysku swoimi plikami, tylko tym, co *wywołuje*:

- każde `npm install` w kolejnym prototypie → wpisy w `_cacache`, który urósł do **12 GB**
  (typowy cache to 0,5–2 GB),
- każdy build w symulatorze → nowy katalog `DerivedData` (28 katalogów, największy 9,1 GB),
- każdy porzucony prototyp → `node_modules`, którego nikt nie skasuje.

### Osierocone artefakty — dokładnie ta sama patologia co sieroty procesów

Skan `DerivedData` pod kątem „czy projekt źródłowy jeszcze istnieje" znalazł **4 martwe katalogi,
~1,7 GB**:

```
Runner-eieydxdd…  394 MB  →  /tmp/claude-501/…/scratchpad/probe/app/ios/Runner.xcworkspace
Runner-cttlbvmc…  360 MB  →  ~/Desktop/sowka-app/.claude/worktrees/szare-karty-na-biel/…
Runner-dyanstrn…  980 MB  →  ~/krzyzowki-edu/app/ios/Runner.xcworkspace
Runner-dlcefyhy…    1 MB  →  ~/sowka-app/app/ios/Runner.xcworkspace
```

Pierwsze dwa są znamienne: **agent zrobił worktree / scratchpad, zbudował go w Xcode, katalog
roboczy został potem sprzątnięty — a 754 MB `DerivedData` zostało na zawsze.** Xcode nigdy nie
kasuje danych po projekcie, którego już nie ma.

`WorkspacePath` z `info.plist` wskazujący na nieistniejącą ścieżkę to bajt w bajt ten sam sygnał
co `PPID == 1`: **artefakt przeżył swojego rodzica.**

### Detektory dyskowe

| # | Nazwa | Sygnał | Pewność | Akcja |
|---|---|---|---|---|
| **D7** | **Dead artifact** | `DerivedData/*/info.plist` → `WorkspacePath` nie istnieje | **bardzo wysoka** | bezpieczne do skasowania |
| **D8** | **Cache bloat** | `_cacache` / pnpm store / gradle caches ponad próg **AND** `atime` > 30 dni | wysoka | pokaż rozmiar + komenda czyszcząca |
| **D9** | **Zombie node_modules** | `node_modules` w katalogu bez commita od 90 dni albo bez `package.json` obok | średnia | lista z rozmiarami |

### Ograniczenia projektowe dla warstwy dyskowej

1. **Skan dysku jest drogi** — `du` po `DerivedData` to sekundy, nie milisekundy.
   Dlatego: **on-demand + raz na dobę w tle**, nigdy w pętli 3-sekundowej.
   Warstwa procesowa i dyskowa mają całkowicie różne modele próbkowania.
2. **Kasowanie jest nieodwracalne** — inaczej niż `kill`. Zawsze potwierdzenie, zawsze
   z pokazaniem *co* i *ile*, nigdy automatycznie. `DerivedData`, `node_modules` i cache npm są
   w 100% odtwarzalne, ale użytkownik i tak musi kliknąć.
3. **Nie duplikujemy `npm cache clean`** — Stray ma *wykryć i wyjaśnić*, a potem zaproponować
   właściwą komendę albo wykonać ją za zgodą. Nie piszemy własnego garbage collectora dla npm.

## 4. Anty-fałszywe-alarmy (najważniejszy moduł)

Produkt umiera w tydzień, jeśli krzyknie na legalny build. Zasady:

1. **Buildy mają długą smycz.** `xcodebuild`, `gradle`, `swift`, `cargo`, `tsc`, `webpack`, `metro`
   nigdy nie odpalają D1, jeśli mają niezerowe I/O. Wolno im palić 100% CPU godzinami.
2. **„W użyciu" bije „sierota".** Osierocony proces z aktywnymi połączeniami TCP jest **żywy** —
   pokazujemy go w liście, ale nie alarmujemy. To odróżnia Metro, do którego podpięty jest
   symulator, od Nexta, o którym wszyscy zapomnieli.
3. **Okres karencji.** Świeżo uruchomiony proces (< 60 s) jest zawsze niewinny.
4. **Whitelist per-komenda** i „nie pytaj więcej o ten proces", trwałe między restartami.
5. **Cooldown.** Jedno powiadomienie na znalezisko, nie jedno na próbkę.
6. **Nigdy nie ubijamy automatycznie.** W v1 kill jest zawsze decyzją człowieka, jeden klik.

---

## 5. Atrybucja — dlaczego to musi być demon, a nie skrypt

Sierota z definicji **straciła rodzica** — `ps` pokaże ci `PPID 1` i tyle. Nie dowiesz się z niej,
która sesja ją zostawiła.

Stray próbkuje w sposób ciągły, więc **widział ten proces, zanim osierociał** — i pamięta całą
linię przodków. Dzięki temu potrafi powiedzieć:

> „`next dev -p 3111` — zostawiony przez sesję Claude Code (PID 2061) o 13:28,
>  w katalogu `~/Documents/Repos/breath-app`."

Tego nie da się odtworzyć post factum żadnym jednorazowym `ps`. To jest techniczne uzasadnienie
istnienia aplikacji rezydentnej i główna przewaga nad skryptem w cronie.

---

## 6. Wyróżnik: diagnoza, nie alert

Wykrycie to dopiero połowa. Po złapaniu D1 aplikacja automatycznie:

1. odpala `/usr/bin/sample <pid> 2` (nie wymaga roota dla własnego UID),
2. wyciąga górne ramki stosu i tłumaczy je na ludzki język
   (`sre_*` → „silnik regex — prawdopodobny catastrophic backtracking"),
3. składa raport: PID, pełna komenda, katalog roboczy, czas życia, sesja-rodzic, stos,
4. daje przycisk **„Kopiuj raport dla agenta"**.

Zamiast „coś zżera CPU" dostajesz gotowy wsad do wklejenia agentowi, który ten kod napisał.
To przeskok z kategorii *monitor* do kategorii *narzędzie*.

---

## 7. Design UI

### Ikona w pasku (SF Symbols)

| Stan | Ikona | Znaczenie |
|---|---|---|
| Czysto | `figure.walk` (outline) | nic nie znaleziono |
| Obserwuje | outline + kropka | są kandydaci, ale poniżej progu |
| Ostrzeżenie | wypełniona + żółty badge z liczbą | znaleziska średniej pewności |
| Alarm | wypełniona + czerwony badge | D1/D5 — coś na pewno się zepsuło |

### Popover

```
┌──────────────────────────────────────────────────┐
│  Stray                                    ⚙︎  ✕  │
├──────────────────────────────────────────────────┤
│  🔴  Python · PID 60858                          │
│      Zakleszczony — 6 h 51 m, 95% CPU            │
│      1 wątek, 0 wybudzeń, 0 B I/O                │
│      ↳ claude.exe (2061) · breath-app            │
│      stos: sre_match — catastrophic backtracking │
│                    [ Raport ]  [ Ubij ]  [ ⋯ ]   │
├──────────────────────────────────────────────────┤
│  🟡  next dev :3111 · PID 12690                  │
│      Sierota — 4 h 37 m, 654 MB, 0 połączeń      │
│      ↳ osierocony przez sesję z 13:28            │
│                    [ Pokaż ]   [ Ubij ]  [ ⋯ ]   │
├──────────────────────────────────────────────────┤
│  ⚪️  expo start :8081 · PID 39861                │
│      Sierota, ale w użyciu — 1 połączenie        │
│                                        [ ⋯ ]     │
├──────────────────────────────────────────────────┤
│  Odzyskasz: 1,1 GB RAM · 2 porty                 │
│  Stray zużywa: 0,2% CPU · 24 MB                  │
└──────────────────────────────────────────────────┘
```

Ostatni wiersz jest celowy: **narzędzie do łapania żarłoków musi publicznie pokazywać własny koszt.**

### Powiadomienia

Tylko dla D1 i D5. Reszta żyje cicho w popoverze. Powiadomienie ma akcje inline:
`Ubij` / `Pokaż` / `Ignoruj ten proces`.

---

## 8. Technologia

| Warstwa | Wybór | Uzasadnienie |
|---|---|---|
| Język | **Swift 6** | natywny dostęp do `libproc`, zero runtime'u |
| UI | **SwiftUI `MenuBarExtra`** (macOS 14+) | menu-bar bez AppKit boilerplate'u |
| Próbkowanie | **`libproc`** | bez roota, bez shell-outów w gorącej pętli |
| Wykresy | **Swift Charts** | sparkline RSS w popoverze |
| Powiadomienia | `UserNotifications` | akcje inline |
| Persystencja | `UserDefaults` + JSON w `Application Support` | whitelist, progi, historia znalezisk |
| Build | **SwiftPM** (bez CocoaPods) | jeden `swift build` |
| Dystrybucja | Developer ID + notaryzacja, `.dmg` + Homebrew cask | **App Store odpada** — sandbox blokuje wgląd w cudze procesy |

### Konkretne API

```swift
proc_listpids(PROC_ALL_PIDS, 0, &pids, size)          // lista PID-ów
proc_pidinfo(pid, PROC_PIDTBSDINFO, ...)              // ppid, uid, nazwa, czas startu
proc_pidinfo(pid, PROC_PIDTASKINFO, ...)              // pti_threadnum, pti_csw, RSS
proc_pid_rusage(pid, RUSAGE_INFO_V4, ...)             // ri_user_time, ri_diskio_bytes*,
                                                      // ri_interrupt_wkups, ri_resident_size
sysctl(CTL_KERN, KERN_PROCARGS2, pid, ...)            // pełna linia poleceń + cwd
proc_pidinfo(pid, PROC_PIDLISTFDS, ...)               // deskryptory
proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, ...)    // stan gniazd: LISTEN / ESTABLISHED
kill(pid, SIGTERM)  → po 5 s → kill(pid, SIGKILL)     // sprzątanie
Process("/usr/bin/sample", [pid, "2", "-mayDie"])     // diagnoza on-demand
```

**Wszystko powyżej działa na procesach własnego UID bez `sudo` i bez uprawnień specjalnych.**
To kluczowa decyzja projektowa: zero promptów o hasło, zero helper-toola z `SMJobBless`.
Procesy agentów są zawsze user-owned, więc nic nie tracimy.

### Architektura

```
Sampler (Timer, 3 s)
   │  snapshot: [PID: ProcSample]
   ▼
ProcessTree ──────► lineage cache (pamięta rodziców sierot)
   │
   ▼
RingBuffer<ProcSample> per PID (200 próbek ≈ 10 min, cap na pamięć)
   │
   ▼
Detectors: [(Window) -> [Finding]]      ← czyste funkcje, testowalne offline
   │
   ▼
Policy: dedupe · cooldown · whitelist · karencja
   │
   ├──► MenuBarExtra + popover (SwiftUI)
   ├──► UserNotifications
   └──► Actions: kill · sample · raport do schowka
```

### Budżet wydajnościowy

Twardy wymóg: **średnio < 0,3% CPU i < 30 MB RAM.** Próbkowanie ~1000 procesów przez
`proc_pid_rusage` to kilka ms co 3 s. Aplikacja mierzy samą siebie i pokazuje wynik w popoverze —
jeśli przekroczy budżet, to jest bug klasy blocker.

### Prywatność

Zero sieci, zero telemetrii, zero analityki. Ma to twarde uzasadnienie:
**linie poleceń procesów regularnie zawierają klucze API i tokeny.** Stray je czyta, więc nie wolno
mu ich nigdzie wysyłać ani zapisywać w plain text. Raporty do schowka maskują ciągi wyglądające
na sekrety (`sk-`, `gho_`, `ghp_`, `AKIA`, `Bearer `).

---

## 9. Roadmapa

| Wersja | Zakres | Szacunek |
|---|---|---|
| **v0.1** | Sampler + drzewo procesów + **D2 (Orphan)** + lista w popoverze + kill | weekend |
| **v0.2** | **D1 (Spinner)** + auto-`sample` + tłumaczenie stosu + powiadomienia | weekend |
| **v0.3** | **D3 (Leak)** + sparkline RSS (Swift Charts) | 2–3 wieczory |
| **v0.4** | **D4/D5** — gniazda przez `proc_pidfdinfo`, detekcja „w użyciu" | 2–3 wieczory |
| **v0.5** | Whitelist, ekran ustawień, `LaunchAgent` (autostart), maskowanie sekretów | 2 wieczory |
| **v0.6** | **Warstwa dyskowa** — D7/D8/D9, osobna zakładka, skan on-demand | 3–4 wieczory |
| **v1.0** | Notaryzacja, `.dmg`, Homebrew cask, README po angielsku, atrybucja sesji dla Claude Code / Codex / Cursor | — |

**v0.1 jest samodzielnie użyteczne** — sama lista sierot z przyciskiem kill już rozwiązuje
realny problem z case study. Każda kolejna wersja dokłada jedną warstwę.

---

## 10. Poza zakresem (non-goals)

- ❌ Ogólny monitor systemu — od tego są Stats i iStat Menus.
- ❌ Throttling / renice procesów — od tego jest App Tamer.
- ❌ Linux, Windows. macOS-only, `libproc` to nie jest przenośne API.
- ❌ Automatyczne ubijanie bez zgody. Nigdy.
- ❌ Konto, chmura, telemetria, subskrypcja.

---

## 11. Otwarte pytania

- **Rozpoznawanie sesji agenta** — po nazwie binarki (`claude.exe`, `codex`, `cursor`) czy
  po zmiennych środowiskowych? Nazwy się zmieniają; env jest stabilniejszy, ale trudniej dostępny.
- **Co z procesami root-owned?** Dziś: ignorujemy (i tak nie są nasze). Czy kiedykolwiek warto
  dodać helper-tool? Prawdopodobnie nie — koszt (SMJobBless, notaryzacja helpera) przewyższa zysk.
- **Historia** — trzymać znaleziska po restarcie, żeby dało się zobaczyć „ile Stray dziś odzyskał"?
  Fajny hook retencyjny, ale to już scope creep dla v1.
- **Alternatywa/uzupełnienie:** hook w Claude Code opakowujący wywołania Bash w `timeout`
  załatwia D1 *wewnątrz jednej sesji* w ~20 liniach. Stray jest potrzebny na to, czego hook
  nie widzi: sieroty i wycieki **między sesjami i między różnymi agentami**.

---

---

## Status — v0.2, działa

Zbudowane i uruchomione 18.08.2026. **18/18 testów przechodzi**, aplikacja siedzi w pasku menu
i wykrywa realne sieroty na maszynie, na której powstała.

```bash
./scripts/bundle.sh release          # zbuduj Stray.app
open build/Stray.app                 # uruchom (ikona w pasku, bez Docka)
swift test                           # 18 testów detektorów, offline

# tryby CLI — te same dane, co poszczególne zakładki
Stray --scan        # zakładka Procesy
Stray --footprint   # zakładka Przegląd: ślad AI w systemie
Stray --disk        # zakładka Dysk: przestrzeń zajęta przez AI
```

## Języki — bez przełącznika

Angielski i polski, ale **przełącznik jest niepotrzebny**: macOS sam wybiera lokalizację
z listy preferowanych języków użytkownika. Base localization to angielski, więc każdy poza
polskojęzycznym systemem dostaje angielski automatycznie.

Nadpisanie istnieje mimo to — w menu `⋯` w nagłówku, obok „Zakończ". To jedyne miejsce
w interfejsie, gdzie ustawienia mają sens, i jedyne, którego potrzebują.

```bash
# wymuszenie języka z zewnątrz, gdyby ktoś wolał tak
defaults write app.stray.menubar stray.language -string pl
```

Oba pliki `.strings` są sprawdzane pod kątem parzystości kluczy, a testy porównują wynik
detektorów z `L(...)`, nie z dosłownym napisem — inaczej zestaw testów przestawał przechodzić
przy zmianie języka systemu (co się właśnie stało i zostało naprawione).

## Ikona

Ślad łapy. `stray` to bezpańskie zwierzę, więc nazwa i znak mówią to samo.
Pierwotna sylwetka pieszego (`figure.walk`) czytała się w pasku jak aplikacja fitness —
a wśród samych figur geometrycznych łapa jest natychmiast rozpoznawalna.
Pusta = czysto, wypełniona = są znaleziska.

## Trzy zakładki

**Przegląd** — ile AI zabiera z systemu: procesy i pamięć teraz, czas CPU dziś i w tygodniu,
lista „warto wyłączyć", podsumowanie dysku z podziałem na pewność pomiaru.

**Procesy** — znaleziska D1–D3, pokolorowane wg wielkości odzysku, z jednozdaniową radą
przy każdym wpisie.

**Dysk** — przestrzeń powiązana z AI, pogrupowana w kategorie, z gotową komendą czyszczącą
przy pozycjach bezpiecznych do usunięcia.

## Jak mierzymy ślad AI

Najtrudniejsze pytanie w tym projekcie nie brzmi „co zżera zasoby", tylko **„skąd wiadomo,
że to należy do AI".** Łatwo pokazać wielką liczbę i skłamać, doliczając do niej cały cache npm
z ostatnich pięciu lat. Dlatego każda pozycja ma poziom pewności i **liczby z różnych poziomów
nigdy nie są sumowane bez etykiety**:

| Poziom | Co to znaczy | Przykład |
|---|---|---|
| 🟢 **zmierzone** | proces agenta, jego żywe poddrzewo albo jego własny katalog | `~/.claude`, scratchpady, `claude.exe` i potomkowie |
| 🔵 **prześledzone** | zapisana linia przodków albo ścieżka katalogu roboczego agenta | `DerivedData` wskazujące na `/scratchpad/` lub `.claude/worktrees/` |
| ⚪️ **wywnioskowane** | poszlaki w projekcie — szacunek, nie pomiar | cache npm, `node_modules` w repo z `CLAUDE.md` |

Procesy, które osierociały **zanim Stray wystartował**, nie mają zapisanej linii przodków —
trafiają do osobnego worka „nieprzypisane" i nigdy nie są doliczane do śladu AI.
Zawyżona liczba byłaby gorsza niż jej brak.

### Zmierzone na maszynie źródłowej

```
ŚLAD AI — TERAZ
   Procesy AI:  18  (13 agentów + 5 potomków)
   Pamięć:      4.1 GB
   Nieprzypisane: 2 procesy, 1.5 GB  (NIE doliczane)

DYSK
   zmierzone      1.4 GB   ~/.claude 830 MB · scratchpady 459 MB · ~/.codex 72 MB
   prześledzone   753 MB   2 × DerivedData po projektach agenta, których już nie ma
   wywnioskowane  35.0 GB  cache npm 12 GB · node_modules 14.9 GB · ~/.cache 5.6 GB
   ─────────────────────────────────────────────
   bezpiecznie odzyskiwalne: 15.7 GB     (skan: 23 s)
```

### Co działa

| | |
|---|---|
| Sampler `libproc` | ✅ ~4 ms na 763 procesy |
| Pamięć linii przodków | ✅ zapisywana przy pierwszym zobaczeniu |
| **D1 Spinner** | ✅ + `sample` + tłumaczenie stosu |
| **D2 Orphan** | ✅ ze świadomością poddrzewa i gniazd |
| **D3 Leak** | ✅ trend RSS |
| Popover, kill, raport, ignorowanie | ✅ |
| Powiadomienia | ✅ tylko D1 |
| Maskowanie sekretów | ✅ liniowe, bez regexa |
| D4/D5/D6, warstwa dyskowa | ⬜ v0.4 / v0.6 |

### Przykładowe wyjście `--scan` z maszyny źródłowej

```
[ ] next dev :3111 · PID 12672
    Sierota, ale w użyciu — 1 poł., 765 MB
      · osierocony jeszcze zanim Stray wystartował — rodzica nie da się ustalić
      · żyje od 5 h 14 min, poddrzewo 3 procesów, 765 MB
      · nasłuchuje na porcie 3111, połączeń: 1

Koszt własny: 3.9 ms na próbkę (0.131% CPU przy oknie 3 s)
```

---

## Czego nauczyło pierwsze uruchomienie na żywym systemie

Trzy rzeczy, których nie dało się przewidzieć przy projektowaniu — wszystkie wyszły dopiero
przy konfrontacji z prawdziwymi procesami.

**1. Proces to nie jest jednostka obserwacji. Drzewo jest.**
Pierwszy skan raportował 56 MB tam, gdzie realnie leżało 654 MB, bo `npm exec next dev` to
w rzeczywistości łańcuch `npm → node → next-server` i cała pamięć oraz port należą do wnuka.
Groźniejsza była konsekwencja dla akcji: ubicie samego korzenia **osierociłoby dzieci jeszcze
bardziej**, niż były. Zarówno pomiar, jak i `kill` musiały przejść na poddrzewa
(`terminateTree` idzie od liści w górę).

**2. Detektor sięgający do systemu nie jest testowalny.**
`OrphanDetector` wołał `ProcScanner.socketState` bezpośrednio. Test użył zmyślonych PID-ów
12689/12690 — które akurat **istniały na maszynie** i miały aktywne połączenia. Test padł
z winy nie swojej, tylko architektury. Sonda gniazd jest teraz wstrzykiwana przez
`DetectorConfig.socketProbe`; dopiero to czyni obietnicę „czyste funkcje, testowalne offline"
prawdziwą — i dopiero to pozwoliło w ogóle napisać test przypadku „sierota w użyciu".

**3. Nie wolno zmyślać atrybucji.**
Dla procesów, które osierociały przed startem Stray, komunikat brzmiał „rodzic (PID 1) już nie
żyje" — zdanie bez sensu. Teraz mówi wprost: *pochodzenie nieznane, proces był sierotą, zanim
Stray wystartował*. Od następnego takiego procesu atrybucja będzie pełna, bo zobaczymy go za
życia rodzica. Narzędzie diagnostyczne, które zgaduje, jest gorsze od takiego, które się przyznaje.

---

## Znane odstępstwa i otwarte kwestie

- **Pamięć ponad budżet.** Założenie brzmiało < 30 MB, pomiar daje **~93 MB RSS**.
  Historia (763 procesy × 120 próbek) to tylko ~6 MB — reszta to baseline SwiftUI/AppKit.
  Cel 30 MB był nierealny dla SwiftUI; realny to ~60 MB i wymaga skrócenia historii dla procesów,
  które nigdy nie zbliżyły się do żadnego progu. **CPU natomiast trzyma się z zapasem: 0,13%
  przy budżecie 0,3%.**
- **Czy jedno połączenie znaczy „w użyciu"?** `next dev` po 5 godzinach miał 1 otwarte połączenie —
  równie dobrze zapomniana karta przeglądarki albo wiszący websocket HMR, jak realna praca.
  Obecna reguła („w użyciu bije sierota") jest celowo zachowawcza i **nie zgłasza takiego procesu**.
  Właściwe rozstrzygnięcie wymaga licznika ruchu na gnieździe, nie samego faktu połączenia.
- Rozpoznawanie sesji agenta idzie po nazwie binarki; nazwy się zmieniają.
- Tryb języka Swift 5 zamiast 6 — dług do spłacenia przy okazji v0.5.


## 12. Licencja

MIT.
