import Foundation

protocol Detector {
    var id: DetectorID { get }
    func evaluate(_ window: ProcWindow, config: DetectorConfig) -> Finding?
}

typealias SocketProbe = @Sendable (Int32) -> (listeningPorts: [Int], established: Int)

struct DetectorConfig: Sendable {
    /// Wstrzykiwane, bo inaczej detektor nie jest czystą funkcją i test trafia
    /// fikcyjnym PID-em w prawdziwy proces działający akurat na maszynie.
    /// (Dokładnie to się stało przy pierwszym uruchomieniu testów.)
    var socketProbe: SocketProbe = { ProcScanner.socketState($0) }

    // D1 — Spinner
    var spinnerCPUPercent: Double = 70
    var spinnerMinSpan: TimeInterval = 90
    var spinnerMaxWakeups: UInt64 = 20

    // D2 — Orphan
    var orphanMinAge: TimeInterval = 30 * 60

    // D3 — Leak
    var leakMinGrowthMB: Double = 200
    var leakMonotonicRatio: Double = 0.8
    var leakMinSpan: TimeInterval = 300

    /// Karencja — świeżo uruchomiony proces jest zawsze niewinny.
    var graceperiod: TimeInterval = 60

    static let `default` = DetectorConfig()
}

// MARK: - D1 Spinner

/// Wysokie CPU + jeden wątek + zero wybudzeń + zero I/O = pętla bez postępu.
///
/// Sam próg CPU jest bezużyteczny: build Xcode też trzyma 100% i to jest poprawne.
/// Rozstrzyga BRAK POSTĘPU. Kompilator i bundler nieustannie piszą na dysk i mają
/// dziesiątki wybudzeń na sekundę; proces zakopany w backtrackingu regexa nie robi nic
/// poza paleniem cykli.
struct SpinnerDetector: Detector {
    let id = DetectorID.spinner

    func evaluate(_ w: ProcWindow, config c: DetectorConfig) -> Finding? {
        guard w.age > c.graceperiod,
              w.span >= c.spinnerMinSpan,
              w.cpuPercent > c.spinnerCPUPercent,
              w.singleThreadedThroughout,
              w.deltaWakeups <= c.spinnerMaxWakeups,
              w.deltaDiskBytes == 0
        else { return nil }

        // Buildy dostają długą smycz — wolno im palić 100% CPU godzinami.
        // W praktyce i tak nie przejdą testu I/O, ale wyjątek jest jawny, nie dorozumiany.
        guard !Whitelist.isLongRunningBuild(w.meta.command) else { return nil }

        var detail = [
            L("spinner.cpu", w.cpuPercent, fmt(w.span)),
            L("spinner.thread"),
            L("spinner.idle", w.deltaWakeups),
            L("spinner.age", fmt(w.age)),
        ]
        if w.deltaContextSwitches < 50 {
            detail.append(L("spinner.csw", w.deltaContextSwitches))
        }

        return Finding(
            detector: id,
            severity: .critical,
            pid: w.meta.pid,
            title: Titles.short(for: w.meta),
            summary: L("spinner.summary", fmt(w.age), w.cpuPercent),
            detail: detail,
            attribution: Titles.attribution(for: w.meta),
            reclaimBytes: w.subtreeRSS,
            command: w.meta.command,
            startedAt: w.meta.startedAt
        )
    }
}

// MARK: - D2 Orphan

/// PPID == 1 znaczy, że powłoka, która ten proces uruchomiła, dawno umarła,
/// a launchd go adoptował.
///
/// UWAGA: samo PPID == 1 to sygnał bezwartościowy — KAŻDA aplikacja GUI ma PPID 1,
/// bo uruchamia ją launchd. Rozstrzyga dopiero to, że proces jest narzędziem
/// deweloperskim z linii poleceń, a nie aplikacją.
struct OrphanDetector: Detector {
    let id = DetectorID.orphan

    func evaluate(_ w: ProcWindow, config c: DetectorConfig) -> Finding? {
        guard w.isOrphan,
              w.age > c.orphanMinAge,
              Whitelist.isDevTool(w.meta.command),
              !Whitelist.isGUIApp(w.meta.command)
        else { return nil }

        // Gniazda należą do WNUKA (npm → node → next-server), nie do korzenia,
        // więc pytamy o całe poddrzewo.
        var ports: [Int] = []
        var established = 0
        for pid in [w.meta.pid] + w.descendants {
            let s = c.socketProbe(pid)
            ports.append(contentsOf: s.listeningPorts)
            established += s.established
        }
        ports = Array(Set(ports)).sorted()
        let sockets = (listeningPorts: ports, established: established)
        let inUse = sockets.established > 0

        var detail = [
            w.orphanedBeforeWeStarted
                ? L("orphan.parent.unknown")
                : L("orphan.parent.dead", w.meta.originalPPID),
            L("orphan.age", fmt(w.age), w.descendants.count + 1, w.subtreeRSSMB),
        ]
        if !sockets.listeningPorts.isEmpty {
            let ports = sockets.listeningPorts.map(String.init).joined(separator: ", ")
            detail.append(L("orphan.ports", ports, sockets.established))
        }

        // "W użyciu" bije "sierota". Metro z podpiętym symulatorem jest żywe —
        // pokazujemy je, ale nie alarmujemy. To odróżnia narzędzie od hałaśliwego budzika.
        return Finding(
            detector: id,
            severity: inUse ? .info : .warning,
            pid: w.meta.pid,
            title: Titles.short(for: w.meta),
            summary: inUse
                ? L("orphan.summary.inuse", sockets.established, w.subtreeRSSMB)
                : L("orphan.summary", fmt(w.age), w.subtreeRSSMB),
            detail: detail,
            attribution: Titles.attribution(for: w.meta),
            reclaimBytes: inUse ? 0 : w.subtreeRSS,
            command: w.meta.command,
            startedAt: w.meta.startedAt
        )
    }
}

// MARK: - D3 Leak

struct LeakDetector: Detector {
    let id = DetectorID.leak

    func evaluate(_ w: ProcWindow, config c: DetectorConfig) -> Finding? {
        guard w.span >= c.leakMinSpan,
              w.rssGrowthMB >= c.leakMinGrowthMB,
              w.monotonicRSSRatio >= c.leakMonotonicRatio
        else { return nil }

        return Finding(
            detector: id,
            severity: .warning,
            pid: w.meta.pid,
            title: Titles.short(for: w.meta),
            summary: L("leak.summary", w.rssGrowthMB, fmt(w.span)),
            detail: [
                L("leak.now", w.rssMB, w.rssGrowthMB),
                L("leak.monotonic", w.monotonicRSSRatio * 100),
            ],
            attribution: Titles.attribution(for: w.meta),
            reclaimBytes: 0,
            command: w.meta.command,
            startedAt: w.meta.startedAt
        )
    }
}

// MARK: - pomocnicze

private func fmt(_ t: TimeInterval) -> String {
    let s = Int(t)
    if s < 60 { return "\(s) s" }
    if s < 3600 { return "\(s / 60) min" }
    return "\(s / 3600) h \((s % 3600) / 60) min"
}

enum Titles {
    /// Zwięzła nazwa do listy: "next dev :3111" zamiast 200 znaków argv.
    static func short(for meta: ProcMeta) -> String {
        let cmd = meta.command
        for marker in ["next dev", "expo start", "vite", "metro", "webpack", "nodemon",
                       "jest", "pytest", "tsc", "rollup", "storybook"] {
            if cmd.contains(marker) {
                if let port = extractPort(cmd) { return "\(marker) :\(port)" }
                return marker
            }
        }
        return meta.name
    }

    /// Wyciąga numer portu bez regexa — świadomie, bo ten projekt powstał
    /// przez catastrophic backtracking w cudzym regexie.
    private static func extractPort(_ cmd: String) -> String? {
        let tokens = cmd.split(separator: " ").map(String.init)
        for (i, t) in tokens.enumerated() {
            if (t == "-p" || t == "--port" || t == "-port"), i + 1 < tokens.count,
               Int(tokens[i + 1]) != nil {
                return tokens[i + 1]
            }
            if t.hasPrefix("--port="), let v = t.split(separator: "=").last, Int(v) != nil {
                return String(v)
            }
        }
        return nil
    }

    static func attribution(for meta: ProcMeta) -> String? {
        if let agent = meta.agentSession {
            return L("attribution.agent", agent, meta.originalPPID)
        }
        guard !meta.originalAncestry.isEmpty else {
            // Stray wystartował już po osieroceniu — linii przodków nie ma jak odtworzyć.
            // Od następnego takiego procesu będzie, bo zobaczymy go za życia rodzica.
            return meta.originalPPID <= 1 ? L("attribution.unknown") : nil
        }
        return L("attribution.parent", meta.originalAncestry.prefix(3).joined(separator: " ← "))
    }
}
