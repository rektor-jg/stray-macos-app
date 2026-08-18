import Foundation

/// Bieżący ślad AI w systemie — stan na teraz.
struct LiveFootprint: Sendable {
    var agentProcesses: Int = 0        // same binarki agentów (wszystkie rodzaje)
    var cliSessions: Int = 0           // realne sesje w terminalu — to one zostawiają sieroty
    var desktopProcesses: Int = 0      // aplikacja desktopowa i jej procesy pomocnicze
    var helperProcesses: Int = 0       // mostki, XPC, crashpad
    var descendantProcesses: Int = 0   // ich żywe poddrzewa
    var unattributed: Int = 0          // sieroty sprzed startu Stray — pochodzenia nie znamy
    var cpuPercent: Double = 0
    var rssBytes: UInt64 = 0
    var unattributedRSSBytes: UInt64 = 0

    var totalProcesses: Int { agentProcesses + descendantProcesses }
}

/// Dzienne podsumowanie. Trzymane na dysku, bo sesje agentów przychodzą i odchodzą,
/// a pytanie „ile mnie to dziś kosztowało" ma sens tylko z pamięcią dłuższą niż jedna sesja.
struct DailyFootprint: Codable, Sendable {
    var day: String
    var cpuSeconds: Double = 0
    var peakRSSBytes: UInt64 = 0
    var maxProcesses: Int = 0
    var killedProcesses: Int = 0
    var reclaimedBytes: UInt64 = 0
    var reclaimedDiskBytes: UInt64 = 0

    /// Ile sekund tego dnia Stray FAKTYCZNIE obserwował system.
    ///
    /// Bez tego pola interfejs pisał „narastająco od północy", co jest nieprawdą,
    /// jeśli aplikacja wstała o osiemnastej. Narzędzie, które twierdzi, że AI zjadło
    /// dziś 0,2 h CPU, przemilczając, że patrzyło przez dziesięć minut, wprowadza
    /// w błąd dokładnie tak samo jak zawyżona liczba.
    var observedSeconds: Double = 0

    var cpuHours: Double { cpuSeconds / 3600 }

    /// Jaka część doby jest realnie objęta pomiarem.
    var coverage: Double {
        let elapsed = Date().timeIntervalSince(Calendar.current.startOfDay(for: Date()))
        return elapsed > 0 ? min(1, observedSeconds / elapsed) : 0
    }

    init(day: String) { self.day = day }

    /// Ręczne dekodowanie, bo `reclaimedDiskBytes` doszło później,
    /// a na dysku leżą już pliki bez tego klucza.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        day = try c.decode(String.self, forKey: .day)
        cpuSeconds = try c.decodeIfPresent(Double.self, forKey: .cpuSeconds) ?? 0
        peakRSSBytes = try c.decodeIfPresent(UInt64.self, forKey: .peakRSSBytes) ?? 0
        maxProcesses = try c.decodeIfPresent(Int.self, forKey: .maxProcesses) ?? 0
        killedProcesses = try c.decodeIfPresent(Int.self, forKey: .killedProcesses) ?? 0
        reclaimedBytes = try c.decodeIfPresent(UInt64.self, forKey: .reclaimedBytes) ?? 0
        reclaimedDiskBytes = try c.decodeIfPresent(UInt64.self, forKey: .reclaimedDiskBytes) ?? 0
        observedSeconds = try c.decodeIfPresent(Double.self, forKey: .observedSeconds) ?? 0
    }
}

/// Księga śladu AI. Akumuluje przyrosty czasu CPU procesów przypisanych do agentów.
///
/// Uwaga metodologiczna: liczymy WYŁĄCZNIE procesy, których pochodzenie znamy —
/// binarki agentów i ich potomków z zapisaną linią przodków. Procesy, które osierociały
/// przed startem Stray, lądują w osobnym worku „nieprzypisane" i nigdy nie są doliczane
/// do śladu AI. Zawyżona liczba byłaby gorsza niż jej brak.
final class FootprintLedger {
    private(set) var today: DailyFootprint
    private(set) var live = LiveFootprint()
    private var history: [String: DailyFootprint]
    private var lastCPU: [Int32: UInt64] = [:]
    private var ticksSinceSave = 0
    private let url: URL

    init() {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Stray", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("footprint.json")

        let loaded = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([String: DailyFootprint].self, from: $0) } ?? [:]
        history = loaded
        let key = Self.dayKey()
        today = loaded[key] ?? DailyFootprint(day: key)
    }

    static func dayKey(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Wywoływane po każdej próbce.
    func record(windows: [ProcWindow]) {
        var snapshot = LiveFootprint()

        for w in windows {
            let isAgent = AgentSignatures.isAgent(name: w.meta.name, command: w.meta.command)
            let isDescendant = w.meta.agentEnv != nil || w.meta.agentSession != nil

            guard isAgent || isDescendant else {
                // Sierota bez znanego rodzica — osobny worek, nigdy nie doliczana do AI.
                if w.isOrphan && ProcessRules.isDevTool(w.meta.command)
                    && !ProcessRules.isGUIApp(w.meta.command) {
                    snapshot.unattributed += 1
                    snapshot.unattributedRSSBytes += w.subtreeRSS
                }
                continue
            }

            if isAgent {
                snapshot.agentProcesses += 1
                switch AgentSignatures.kind(name: w.meta.name, command: w.meta.command, tty: w.meta.tty) {
                case .cliSession: snapshot.cliSessions += 1
                case .desktopApp: snapshot.desktopProcesses += 1
                case .helper, .none: snapshot.helperProcesses += 1
                }
            } else {
                snapshot.descendantProcesses += 1
            }
            snapshot.cpuPercent += w.cpuPercent
            snapshot.rssBytes += w.latest?.rss ?? 0

            // przyrost czasu CPU od ostatniej próbki
            if let now = w.latest?.cpuNanos {
                if let before = lastCPU[w.meta.pid], now >= before {
                    today.cpuSeconds += Double(now - before) / 1_000_000_000
                }
                lastCPU[w.meta.pid] = now
            }
        }

        // sprzątanie po procesach, których już nie ma
        let alive = Set(windows.map(\.meta.pid))
        lastCPU = lastCPU.filter { alive.contains($0.key) }

        today.observedSeconds += Sampler.interval
        ticksSinceSave += 1
        if ticksSinceSave >= 20 { save(); ticksSinceSave = 0 }   // ~co minutę

        today.peakRSSBytes = max(today.peakRSSBytes, snapshot.rssBytes)
        today.maxProcesses = max(today.maxProcesses, snapshot.totalProcesses)
        live = snapshot
        rolloverIfNeeded()
    }

    func recordDiskCleanup(freed: UInt64) {
        today.reclaimedDiskBytes += freed
        save()
    }

    func recordKill(reclaimed: UInt64) {
        today.killedProcesses += 1
        today.reclaimedBytes += reclaimed
        save()
    }

    /// Ostatnie `days` dni, od najnowszego.
    func recent(days: Int = 7) -> [DailyFootprint] {
        var all = history
        all[today.day] = today
        return all.values.sorted { $0.day > $1.day }.prefix(days).map { $0 }
    }

    var weekCPUHours: Double { recent(days: 7).reduce(0) { $0 + $1.cpuHours } }
    var weekReclaimed: UInt64 { recent(days: 7).reduce(0) { $0 + $1.reclaimedBytes } }

    private func rolloverIfNeeded() {
        let key = Self.dayKey()
        guard key != today.day else { return }
        history[today.day] = today
        today = DailyFootprint(day: key)
        save()
    }

    func save() {
        var all = history
        all[today.day] = today
        // trzymamy 90 dni, żeby plik nie puchł bez końca
        let keep = all.keys.sorted().suffix(90)
        all = all.filter { keep.contains($0.key) }
        history = all.filter { $0.key != today.day }
        try? JSONEncoder().encode(all).write(to: url, options: .atomic)
    }
}
