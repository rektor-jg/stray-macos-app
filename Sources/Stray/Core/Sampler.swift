import Foundation



/// Pętla próbkowania. Utrzymuje metadane, historię i — najważniejsze —
/// pamięć o przodkach procesów, zanim te osierocieją.
final class Sampler {
    /// 120 próbek × 3 s = 10 minut historii. Wystarcza na detekcję wycieku (D3),
    /// a przy ~750 czytelnych procesach kosztuje kilka MB.
    static let historyDepth = 120
    static let interval: TimeInterval = 3.0

    private var metas: [Int32: ProcMeta] = [:]
    private var history: [Int32: RingBuffer<ProcMetrics>] = [:]
    /// Historia stanu gniazd — tylko dla kandydatów, bo odczyt deskryptorów
    /// jest znacznie droższy niż zwykła próbka i nie ma sensu robić go dla 765 procesów.
    private var sockets: [Int32: RingBuffer<SocketSample>] = [:]
    private let ownUID = getuid()

    /// Koszt własny — narzędzie do łapania żarłoków musi publicznie pokazywać swój rachunek.
    ///
    /// Mediana, nie ostatni odczyt. Pojedyncze takty skaczą (pierwszy kosztuje ~29 ms,
    /// bo czyta linię poleceń i środowisko wszystkich 780 procesów; każdy nowy proces
    /// dokłada jeden `sysctl`), więc raportowanie ostatniej próbki dawało odczyty
    /// od 3,9 do 13,2 ms dla tego samego stanu ustalonego.
    private(set) var lastScanMillis: Double = 0
    private var recentCosts = RingBuffer<Double>(capacity: 20)

    /// Rzeczywisty koszt procesora, mierzony tak samo jak dla każdego innego procesu:
    /// przez `proc_pid_rusage` na samym sobie.
    ///
    /// Poprzednia wersja mierzyła stoperem czas ZEGAROWY skanu i podawała go jako
    /// zużycie CPU. To dwie różne rzeczy: takt trwa 7–10 ms zegarowo, ale procesora
    /// zużywa 1 ms — reszta to czekanie na syscalle i wywłaszczenia. Aplikacja
    /// zawyżała własny rachunek dziesięciokrotnie i sprowokowała pogoń
    /// za nieistniejącą regresją wydajności.
    private var lastSelfCPU: UInt64 = 0
    private var lastSelfCPUAt: Date?
    private var selfCPUSamples = RingBuffer<Double>(capacity: 20)

    /// Udział jednego rdzenia, w procentach — liczba, którą wolno pokazać użytkownikowi.
    var selfCPUPercent: Double {
        let values = selfCPUSamples.values.sorted()
        guard !values.isEmpty else { return 0 }
        return values[values.count / 2]
    }
    /// Koszt pierwszego taktu — jednorazowy, więc trzymany osobno i nigdy
    /// niewliczany do mediany. Wrzucony do wspólnego worka zawyżał ją dwukrotnie.
    private(set) var coldStartMillis: Double = 0

    /// Mediana kosztu ostatnich taktów — liczba, którą wolno pokazać użytkownikowi.
    var medianScanMillis: Double {
        let sorted = recentCosts.values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[sorted.count / 2]
    }
    private(set) var trackedCount: Int = 0

    /// Jedna próbka całego systemu. Zwraca okna gotowe dla detektorów.
    @discardableResult
    func tick(now: Date = Date()) -> [ProcWindow] {
        let started = Date()
        let pids = ProcScanner.listPIDs()
        var alive = Set<Int32>()

        for pid in pids {
            guard let (metrics, uid, name, ppid, startedAt) = ProcScanner.sample(pid, at: now)
            else { continue }
            // Tylko własny UID — procesów roota i tak nie moglibyśmy ubić.
            guard uid == ownUID else { continue }
            alive.insert(pid)

            if metas[pid] == nil {
                // Pierwsze zobaczenie: TERAZ jest jedyny moment, gdy rodzic jeszcze żyje
                // i da się zapisać linię przodków.
                let ancestry = buildAncestry(startingFrom: ppid)
                // Jeden sysctl daje i argumenty, i znaczniki środowiskowe.
                let info = ProcScanner.processInfo(pid)
                metas[pid] = ProcMeta(
                    pid: pid,
                    uid: uid,
                    name: name,
                    command: info.command ?? name,
                    startedAt: startedAt,
                    firstSeenAt: now,
                    originalPPID: ppid,
                    originalAncestry: ancestry,
                    agentEnv: info.agent
                )
                history[pid] = RingBuffer(capacity: Self.historyDepth)
            }
            history[pid]?.append(metrics)
        }

        // sprzątanie po procesach, które zniknęły
        for pid in metas.keys where !alive.contains(pid) {
            metas.removeValue(forKey: pid)
            history.removeValue(forKey: pid)
        }

        lastScanMillis = Date().timeIntervalSince(started) * 1000
        measureSelf(at: Date())
        if coldStartMillis == 0 {
            // Pierwszy takt czyta linię poleceń i środowisko KAŻDEGO procesu — ~30 ms.
            // Późniejsze robią to tylko dla nowych, więc mieszanie ich to błąd pomiaru.
            coldStartMillis = lastScanMillis
        } else {
            recentCosts.append(lastScanMillis)
        }
        trackedCount = metas.count

        // Gniazda: wyłącznie osierocone narzędzia deweloperskie. Na maszynie źródłowej
        // to dwa procesy z 765, więc koszt jest pomijalny, a zysk duży —
        // JEDEN odczyt w chwili kliknięcia nie odróżnia serwera używanego
        // od takiego, w którym wisi zapomniany websocket.
        // Mapa dzieci budowana RAZ. Poprzednia wersja wołała childMap() wewnątrz pętli,
        // czyli przebudowywała ją dla każdego kandydata osobno — koszt własny skoczył
        // z 4,0 do 7,1 ms na próbkę.
        let kids = childMap()
        for (pid, meta) in metas {
            let isOrphanDevTool = history[pid]?.values.last?.ppid == 1
                && ProcessRules.isDevTool(meta.command)
                && !ProcessRules.isGUIApp(meta.command)
            guard isOrphanDevTool else { sockets.removeValue(forKey: pid); continue }
            var sub = ProcScanner.socketState(pid)
            for child in descendants(of: pid, children: kids) {
                let s = ProcScanner.socketState(child)
                sub.listeningPorts.append(contentsOf: s.listeningPorts)
                sub.established += s.established
            }
            if sockets[pid] == nil { sockets[pid] = RingBuffer(capacity: Self.historyDepth) }
            sockets[pid]?.append(SocketSample(at: now,
                                              ports: Array(Set(sub.listeningPorts)).sorted(),
                                              established: sub.established))
        }

        // Mapa dzieci z bieżącej próbki — potrzebna, bo metryki poddrzewa
        // trzeba liczyć na aktualnym kształcie drzewa, nie na zapamiętanym.
        var children: [Int32: [Int32]] = [:]
        var rssByPID: [Int32: UInt64] = [:]
        for (pid, ring) in history {
            guard let last = ring.values.last else { continue }
            children[last.ppid, default: []].append(pid)
            rssByPID[pid] = last.rss
        }

        return metas.compactMap { pid, meta in
            guard let ring = history[pid], ring.count > 0 else { return nil }
            // Pełne okno budujemy TYLKO dla kandydatów.
            //
            // Wcześniej powstawało dla wszystkich 789 procesów co takt: kopia do 120 próbek
            // plus przejście poddrzewa, czyli ~95 tysięcy kopii struktur na takt —
            // w przytłaczającej większości dla bezczynnych demonów systemowych,
            // które nie mają szansy wywołać żadnego detektora.
            guard isCandidate(meta: meta, ring: ring) else { return nil }
            let samples = ring.values
            let kids = descendants(of: pid, children: children)
            let subtreeRSS = ([pid] + kids).reduce(UInt64(0)) { $0 + (rssByPID[$1] ?? 0) }
            return ProcWindow(meta: meta, samples: samples,
                              descendants: kids, subtreeRSS: subtreeRSS,
                              socketHistory: sockets[pid]?.values ?? [])
        }
    }

    /// Tani filtr wstępny, liczony z DWÓCH ostatnich próbek — bez kopiowania historii.
    ///
    /// Musi przepuścić wszystko, co może zainteresować którykolwiek detektor albo księgę.
    /// Kryteria są celowo hojne: pomyłka w tę stronę kosztuje kilka mikrosekund,
    /// pomyłka w drugą oznacza przeoczone znalezisko.
    private func isCandidate(meta: ProcMeta, ring: RingBuffer<ProcMetrics>) -> Bool {
        // wszystko, co należy do AI — potrzebne księdze śladu
        if meta.agentEnv != nil { return true }
        if AgentSignatures.isAgent(name: meta.name, command: meta.command) { return true }
        if meta.agentSession != nil { return true }

        let samples = ring.lastTwo
        guard let latest = samples.1 else { return false }

        // sierota będąca narzędziem deweloperskim — D2
        if latest.ppid == 1 && ProcessRules.isDevTool(meta.command)
            && !ProcessRules.isGUIApp(meta.command) { return true }

        // cokolwiek dużego w pamięci — D3 łapie wycieki liczone w setkach MB
        if latest.rss > 100 * 1_048_576 { return true }

        // cokolwiek, co realnie pali procesor — D1
        if let previous = samples.0 {
            let elapsed = latest.at.timeIntervalSince(previous.at)
            if elapsed > 0, latest.cpuNanos >= previous.cpuNanos {
                let percent = Double(latest.cpuNanos - previous.cpuNanos) / (elapsed * 1e9) * 100
                if percent > 15 { return true }
            }
        }
        return false
    }

    /// Ten sam pomiar, którym mierzymy cudze procesy — zastosowany do siebie.
    private func measureSelf(at now: Date) {
        guard let (metrics, _, _, _, _) = ProcScanner.sample(getpid(), at: now) else { return }
        defer { lastSelfCPU = metrics.cpuNanos; lastSelfCPUAt = now }
        guard let before = lastSelfCPUAt, lastSelfCPU > 0 else { return }
        let elapsed = now.timeIntervalSince(before)
        guard elapsed > 0, metrics.cpuNanos >= lastSelfCPU else { return }
        let cpuSeconds = Double(metrics.cpuNanos - lastSelfCPU) / 1_000_000_000
        selfCPUSamples.append(cpuSeconds / elapsed * 100)
    }

    private func childMap() -> [Int32: [Int32]] {
        var children: [Int32: [Int32]] = [:]
        for (pid, ring) in history {
            guard let last = ring.values.last else { continue }
            children[last.ppid, default: []].append(pid)
        }
        return children
    }

    /// Wszyscy potomkowie, wszerz. Limit głębokości chroni przed cyklem
    /// w wypadku niespójnej próbki (proces zniknął w trakcie skanu).
    private func descendants(of pid: Int32, children: [Int32: [Int32]],
                             maxDepth: Int = 12) -> [Int32] {
        var result: [Int32] = []
        var frontier = children[pid] ?? []
        var depth = 0
        while !frontier.isEmpty && depth < maxDepth {
            result.append(contentsOf: frontier)
            frontier = frontier.flatMap { children[$0] ?? [] }
            depth += 1
        }
        return result
    }

    /// Idzie w górę drzewa PPID i zbiera nazwy przodków.
    /// Wołane tylko raz na proces, bo tylko wtedy ma sens — potem rodzic może już nie żyć.
    private func buildAncestry(startingFrom ppid: Int32, maxDepth: Int = 8) -> [String] {
        var chain: [String] = []
        var current = ppid
        var depth = 0
        while current > 1 && depth < maxDepth {
            if let cached = metas[current] {
                chain.append(cached.name)
                current = cached.originalPPID
            } else if let (_, _, name, parentPPID, _) = ProcScanner.sample(current, at: Date()) {
                chain.append(name)
                current = parentPPID
            } else {
                break
            }
            depth += 1
        }
        return chain
    }
}
