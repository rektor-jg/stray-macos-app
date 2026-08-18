# Case study — 18 sierpnia 2026

Surowy materiał źródłowy: dokładnie te komendy i outputy, które doprowadziły do powstania Stray.
Zachowane w oryginale, żeby dało się z tego złożyć post / artykuł bez zgadywania szczegółów.

---

## Objaw

Wentylatory na full. Activity Monitor → `Python`, 72% CPU, CPU Time **4:48:35**, PID 60858.
Nazwa procesu to samo `Python` — zero informacji o tym, co to właściwie robi.

Stan systemu w tym momencie:

```
System:  66,02%
User:    33,05%
Idle:     0,93%      ← maszyna praktycznie stoi
Threads: 4.743
Processes: 1.071
```

Co ciekawe, w tym samym zrzucie widać już całą sygnaturę zakleszczenia:

| Proces | %CPU | Threads | Idle Wake-Ups |
|---|---|---|---|
| **Python** | **72,0** | **1** | **0** |
| iTerm2 | 22,5 | 9 | 209 |
| Brave Browser | 18,9 | 25 | 265 |
| backboardd | 10,4 | 9 | 65 |

Zdrowe procesy mają wybudzenia. Zakleszczony nie ma żadnych.

## Identyfikacja

```console
$ ps -p 60858 -o pid,ppid,user,%cpu,%mem,etime,command
  PID  PPID USER       %CPU %MEM  ELAPSED COMMAND
60858 60836 jakubgora  95,1  0,0 06:50:54 /Applications/Xcode.app/.../Python3.framework/.../Python -
```

Linia poleceń ucięta — skrypt szedł przez stdin (`python3 - <<PY`). Trzeba było iść do rodzica:

```console
$ ps -ww -p 60836 -o pid,ppid,command
60836  2061  /bin/zsh -c ... cd /Users/jakubgora/Documents/Repos/breath-app/apps/mobile
              && npx tsc --noEmit -p . | head && echo "typecheck OK"
              && grep -rn 'PODGLĄD\|localhost:8099' app/ lib/
              && python3 - <<PY   [heurystyka nieużywanych importów]
```

`PPID 2061` = `claude.exe`. Czyli: **skrypt wygenerowany przez agenta w poprzedniej sesji.**

## Przyczyna

```python
ciało = re.sub(
    r"^import[^\n]*\n(?:\s+[^\n]*\n)*?(?:.*?from '[^']+'\n)",
    '', t, flags=re.M
)
```

Zagnieżdżone leniwe kwantyfikatory — `(?:...)*?` opakowujące `.*?` — dają wykładniczą liczbę
możliwych podziałów wejścia. Na dłuższym pliku `.tsx` to się nie kończy. **Catastrophic backtracking.**

Potwierdzenie stosem:

```console
$ sample 60858 2 -mayDie
Call graph:
    1628 Thread_1575695   DispatchQueue_1: com.apple.main-thread
      ...
        1628 PyRun_SimpleFileExFlags
          ...
            1628 _PyEval_EvalFrameDefault
              ...
                 249 ??? (in Python3) + 0x18f3f4     ← silnik sre, głęboka rekurencja
                 125 ??? (in Python3) + 0x193090
                  26 ??? (in Python3) + 0x192c7c
```

Launch Time: **11:11:39**. Wykryte: **18:02**. Sześć godzin i pięćdziesiąt jeden minut.

## Skutek uboczny

Sesja `claude.exe` (PID 2061) czekała na output tego skryptu przez cały ten czas.
Jedna zawieszka zablokowała agenta *i* maszynę.

## Sprzątanie

```console
$ kill 60858
```

Po ubiciu: `Idle` skoczyło z **0,93% → 56,62%**.

Uwaga: `systemstats --daemon` (PID 340) pokazywał w `ps` 96% CPU i wyglądał na drugiego winowajcę —
ale to była zdekayowana średnia. Po ubiciu Pythona spadł do 0,1% sam z siebie.
Prawdopodobnie mielił statystyki właśnie tego zapętlonego procesu. **Lekcja: `ps %cpu` to średnia,
nie pomiar chwilowy — do decyzji trzeba `top -l`.**

---

## Drugie znalezisko — to ciekawsze

Przy okazji skanu całego systemu:

```console
$ ps -eo pid,ppid,user,%cpu,rss,etime,comm | grep -E 'node|npm|next|expo'
12690  12689  jakubgora  0,0  531MB  04:37:37  next-server
12689  12672  jakubgora  0,0   67MB  04:37:38  node
12672      1  jakubgora  0,0   56MB  04:37:38  npm        ← PPID 1
39861  39845  jakubgora  0,1  366MB  00:58:46  node
39845      1  jakubgora  0,0   77MB  00:58:47  npm        ← PPID 1
```

```console
$ ps -ww -p 12672 -o lstart,command
wt. 18 sie 13:28:06 2026   npm exec next dev -p 3111 -H 0.0.0.0

$ ps -ww -p 39845 -o lstart,command
wt. 18 sie 17:06:57 2026   npm exec expo start --port 8081 --lan --dev-client

$ lsof -nP -iTCP -sTCP:LISTEN | grep node
node  12690  jakubgora  13u  IPv4  TCP *:3111 (LISTEN)
node  39861  jakubgora  32u  IPv6  TCP *:8081 (LISTEN)
```

**`PPID == 1`** oznacza, że powłoka, która je uruchomiła, dawno umarła, a launchd je adoptował.
To są dev-serwery po sesjach agenta, których nikt nigdy nie zamknął.
~1,1 GB RAM i dwa zajęte porty — **niewidoczne w żadnym rankingu CPU, bo nie robią nic.**

I od razu widać najtrudniejszy problem produktowy: **Expo z 17:06 prawdopodobnie był w użyciu**
(symulator z Expo Go podpięty), a Next z 13:28 nie. Z samego `PPID == 1` tego nie odróżnisz —
trzeba sprawdzić, czy ktoś jest podpięty do portu.

---

## Trzy wnioski, na których stoi projekt

1. **Sam próg CPU jest bezużyteczny.** Build Xcode też trzyma 100% i to jest w porządku.
   Rozstrzyga *brak postępu*: 1 wątek + 0 wybudzeń + 0 I/O.
2. **Najgorsze śmieci nie zużywają CPU.** Osierocone dev-serwery po prostu leżą i trzymają RAM
   oraz porty. Activity Monitor nigdy ci ich nie pokaże, bo sortujesz po CPU.
3. **Sierota traci rodzica, ale demon pamięta.** `ps` post factum pokaże `PPID 1` i nic więcej.
   Aplikacja rezydentna widziała ten proces, *zanim* osierociał — i dlatego może powiedzieć,
   która sesja go zostawiła. To jest uzasadnienie istnienia aplikacji zamiast skryptu.

---

## Aneks — warstwa dyskowa (ten sam dzień)

Hipoteza wyjściowa: „agenty zapychają temp". Pomiar ją obalił i podmienił na ciekawszą.

```console
$ df -h /System/Volumes/Data
/dev/disk3s1  460Gi  382Gi  44Gi  90%      ← 90% zajęte
```

```console
$ du -sh ~/.claude /private/tmp/claude-501
900M  ~/.claude          (818M to projects/ — transkrypty sesji)
431M  /private/tmp/claude-501   (15 katalogów scratchpad)
```

**Dosłowny temp agenta: 1,3 GB.** Czyli nic. A teraz reszta:

```console
$ du -sh ~/Library/Developer/Xcode/DerivedData   25G
$ du -sh ~/Library/Containers/com.docker.docker  24G
$ du -sh ~/Library/Developer/CoreSimulator       15G
$ du -sh ~/.gradle                               15G
$ du -sh ~/Library/Caches                        13G
$ du -sh ~/.npm/_cacache                         12G     ← typowy cache to 0,5–2 GB
$ du -sh ~/Documents/Repos                       13G     (5,8G to node_modules w 6 repo)
$ du -sh ~/.cache                                5,6G
```

Wniosek: **agent nie zapycha dysku swoimi plikami, tylko tym, co wywołuje.**
Każde `npm install` w kolejnym prototypie, każdy build w symulatorze, każdy porzucony projekt.

### Znalezisko: osierocone DerivedData

`info.plist` każdego katalogu `DerivedData` zawiera `WorkspacePath`. Sprawdzenie, czy ta ścieżka
jeszcze istnieje, dało 4 martwe katalogi (~1,7 GB) z 28:

```
Runner-eieydxdd…  394 MB → /tmp/claude-501/…/scratchpad/probe/app/ios/Runner.xcworkspace
Runner-cttlbvmc…  360 MB → ~/Desktop/sowka-app/.claude/worktrees/szare-karty-na-biel/…
Runner-dyanstrn…  980 MB → ~/krzyzowki-edu/app/ios/Runner.xcworkspace
Runner-dlcefyhy…    1 MB → ~/sowka-app/app/ios/Runner.xcworkspace
```

Dwa pierwsze wskazują na **scratchpad sesji agenta** i na **git worktree utworzony przez agenta**.
Oba katalogi robocze zostały posprzątane. `DerivedData` — nie. Xcode nie ma żadnego mechanizmu,
który by to zauważył.

Komenda, która to znajduje:

```bash
for d in ~/Library/Developer/Xcode/DerivedData/*/; do
  src=$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null)
  [ -n "$src" ] && [ ! -e "$src" ] && echo "$(du -sh "$d" | cut -f1)  $src"
done
```

### Dlaczego to jest ta sama historia

`PPID == 1` i „`WorkspacePath` nie istnieje" to ten sam sygnał w dwóch różnych warstwach systemu:
**artefakt przeżył swojego rodzica i nikt się do tego nie przyznaje.**
Proces po sesji, która umarła. Katalog build po projekcie, którego już nie ma.

Żadne istniejące narzędzie nie łączy tych kropek, bo żadne nie ma pojęcia o istnieniu sesji agenta.
