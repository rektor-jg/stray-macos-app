import XCTest
@testable import Stray

/// Detektory są czystymi funkcjami (okno) -> Finding?, więc testują się bez systemu.
/// Fixture'y odtwarzają incydent z 18.08.2026, który dał początek projektowi.
final class DetectorTests: XCTestCase {

    /// Konfiguracja odcięta od systemu — żaden test nie może zależeć od tego,
    /// co akurat działa na maszynie.
    private func offline(sockets: [Int32: (listeningPorts: [Int], established: Int)] = [:])
        -> DetectorConfig {
        var c = DetectorConfig.default
        c.socketProbe = { pid in sockets[pid] ?? (listeningPorts: [], established: 0) }
        return c
    }

    // MARK: - budowanie okien

    private func window(
        name: String = "Python",
        command: String = "python3 -",
        ppid: Int32 = 1,
        ageSeconds: TimeInterval = 6 * 3600,
        spanSeconds: TimeInterval = 120,
        sampleCount: Int = 40,
        cpuPercent: Double,
        threads: Int32,
        diskGrowthPerSample: UInt64 = 0,
        wakeupsPerSample: UInt64 = 0,
        rssStartMB: Double = 50,
        rssEndMB: Double? = nil,
        descendants: [Int32] = [],
        subtreeExtraMB: Double = 0,
        agentEnv: ProcScanner.AgentEnv? = nil,
        socketHistory: [SocketSample] = []
    ) -> ProcWindow {
        let now = Date()
        let start = now.addingTimeInterval(-ageSeconds)
        let meta = ProcMeta(
            pid: 60858, uid: getuid(), name: name, command: command,
            startedAt: start, firstSeenAt: now.addingTimeInterval(-spanSeconds),
            originalPPID: ppid == 1 ? 60836 : ppid,
            originalAncestry: ["zsh", "claude.exe"],
            agentEnv: agentEnv
        )
        let step = spanSeconds / Double(max(1, sampleCount - 1))
        let cpuPerSampleNanos = UInt64(cpuPercent / 100 * step * 1_000_000_000)
        let rssEnd = rssEndMB ?? rssStartMB
        var samples: [ProcMetrics] = []
        for i in 0..<sampleCount {
            let f = Double(i) / Double(max(1, sampleCount - 1))
            samples.append(ProcMetrics(
                at: now.addingTimeInterval(-spanSeconds + step * Double(i)),
                ppid: ppid,
                threads: threads,
                cpuNanos: cpuPerSampleNanos * UInt64(i),
                rss: UInt64((rssStartMB + (rssEnd - rssStartMB) * f) * 1_048_576),
                diskRead: diskGrowthPerSample * UInt64(i),
                diskWritten: 0,
                wakeups: wakeupsPerSample * UInt64(i),
                contextSwitches: Int32(i)
            ))
        }
        return ProcWindow(meta: meta, samples: samples,
                          descendants: descendants,
                          subtreeRSS: UInt64((rssEnd + subtreeExtraMB) * 1_048_576),
                          socketHistory: socketHistory)
    }

    // MARK: - D1 Spinner

    func testSpinnerCatchesTheOriginalIncident() {
        // Python, 95% CPU, 1 wątek, 0 wybudzeń, 0 I/O, 6 h 51 min życia.
        let w = window(cpuPercent: 95, threads: 1)
        let f = SpinnerDetector().evaluate(w, config: .default)
        XCTAssertNotNil(f, "sygnatura zakleszczenia musi zostać wykryta")
        XCTAssertEqual(f?.severity, .critical)
        XCTAssertEqual(f?.detector, .spinner)
        XCTAssertEqual(f?.attribution, L("attribution.agent", "claude.exe", Int32(60836)),
                       "atrybucja niezależna od języka interfejsu")
    }

    func testSpinnerIgnoresBusyProcessThatDoesIO() {
        // Bundler/kompilator: wysokie CPU, ale pisze na dysk. To NIE jest awaria.
        let w = window(cpuPercent: 98, threads: 1, diskGrowthPerSample: 4096)
        XCTAssertNil(SpinnerDetector().evaluate(w, config: .default),
                     "proces z I/O robi postęp — nie wolno go zgłaszać")
    }

    func testSpinnerIgnoresMultithreadedLoad() {
        let w = window(cpuPercent: 400, threads: 12)
        XCTAssertNil(SpinnerDetector().evaluate(w, config: .default))
    }

    func testSpinnerIgnoresProcessWithWakeups() {
        // Zdrowy proces oddaje sterowanie — ma wybudzenia.
        let w = window(cpuPercent: 90, threads: 1, wakeupsPerSample: 50)
        XCTAssertNil(SpinnerDetector().evaluate(w, config: .default))
    }

    func testSpinnerRespectsGracePeriod() {
        let w = window(ageSeconds: 30, cpuPercent: 99, threads: 1)
        XCTAssertNil(SpinnerDetector().evaluate(w, config: .default),
                     "świeżo uruchomiony proces jest zawsze niewinny")
    }

    func testSpinnerIgnoresKnownBuildTool() {
        let w = window(name: "xcodebuild", command: "xcodebuild -scheme App build",
                       cpuPercent: 99, threads: 1)
        XCTAssertNil(SpinnerDetector().evaluate(w, config: .default),
                     "buildom wolno palić CPU godzinami")
    }

    // MARK: - D2 Orphan

    func testOrphanCatchesForgottenDevServer() {
        let w = window(name: "node", command: "npm exec next dev -p 3111 -H 0.0.0.0",
                       ppid: 1, ageSeconds: 4 * 3600 + 37 * 60,
                       cpuPercent: 0, threads: 6, rssStartMB: 531)
        let f = OrphanDetector().evaluate(w, config: offline())
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.title, "next dev :3111", "tytuł ma być czytelny, nie 200 znaków argv")
        XCTAssertEqual(f?.severity, .warning)
    }

    func testOrphanIgnoresGUIApps() {
        // KAŻDA aplikacja GUI ma PPID 1 — bez tego filtra zgłosilibyśmy cały Dock.
        let w = window(
            name: "Brave Browser",
            command: "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser",
            ppid: 1, ageSeconds: 9 * 3600, cpuPercent: 18, threads: 25)
        XCTAssertNil(OrphanDetector().evaluate(w, config: offline()),
                     "aplikacja GUI z PPID 1 to norma, nie sierota")
    }

    func testOrphanIgnoresYoungProcess() {
        let w = window(name: "node", command: "npm exec vite",
                       ppid: 1, ageSeconds: 120, cpuPercent: 1, threads: 4)
        XCTAssertNil(OrphanDetector().evaluate(w, config: offline()))
    }

    func testOrphanIgnoresNonDevTool() {
        let w = window(name: "coreaudiod", command: "/usr/sbin/coreaudiod",
                       ppid: 1, ageSeconds: 40 * 3600, cpuPercent: 2, threads: 3)
        XCTAssertNil(OrphanDetector().evaluate(w, config: offline()))
    }

    /// Regresja: pierwszy skan żywego systemu pokazał 56 MB zamiast 654 MB,
    /// bo mierzony był tylko proces `npm`, a nie jego wnuk `next-server`.
    func testOrphanReclaimCountsWholeSubtree() {
        let w = window(name: "node", command: "npm exec next dev -p 3111",
                       ppid: 1, ageSeconds: 5 * 3600,
                       cpuPercent: 0, threads: 6,
                       rssStartMB: 56, rssEndMB: 56,
                       descendants: [12689, 12690], subtreeExtraMB: 598)
        let f = OrphanDetector().evaluate(w, config: offline())
        XCTAssertNotNil(f)
        let reclaimMB = Double(f!.reclaimBytes) / 1_048_576
        XCTAssertEqual(reclaimMB, 654, accuracy: 1,
                       "odzysk musi obejmować całe poddrzewo, nie sam korzeń")
        XCTAssertTrue(f!.detail.contains { $0.contains("3") },
                      "opis musi wymieniać liczbę procesów w poddrzewie")
    }

    /// "W użyciu" bije "sierota": Metro z podpiętym symulatorem jest żywe.
    func testOrphanWithLiveConnectionsIsNotAlarming() {
        let w = window(name: "node", command: "npm exec expo start --port 8081",
                       ppid: 1, ageSeconds: 2 * 3600,
                       cpuPercent: 0, threads: 8,
                       rssStartMB: 80, descendants: [39861], subtreeExtraMB: 828)
        let cfg = offline(sockets: [39861: (listeningPorts: [8081], established: 10)])
        let f = OrphanDetector().evaluate(w, config: cfg)
        XCTAssertEqual(f?.severity, .info, "nie wolno alarmować o serwerze, z którego ktoś korzysta")
        XCTAssertEqual(f?.reclaimBytes, 0, "nic tu nie ma do odzyskania")
    }

    /// Historia gniazd bije jednorazowy odczyt: serwer, w którym przez dziesięć minut
    /// nie pojawiło się ani jedno połączenie, jest martwy niezależnie od tego,
    /// co pokazuje pojedynczy pomiar.
    func testOrphanUsesSocketHistoryNotSingleReading() {
        let now = Date()
        // Przez 10 minut zero połączeń — mimo że sonda chwilowa "widzi" jedno.
        let history = (0..<200).map {
            SocketSample(at: now.addingTimeInterval(-600 + Double($0) * 3),
                         ports: [3111], established: 0)
        }
        let w = window(name: "node", command: "npm exec next dev -p 3111",
                       ppid: 1, ageSeconds: 5 * 3600, cpuPercent: 0, threads: 6,
                       rssStartMB: 800, socketHistory: history)
        let cfg = offline(sockets: [60858: (listeningPorts: [3111], established: 1)])
        let f = OrphanDetector().evaluate(w, config: cfg)
        XCTAssertEqual(f?.severity, .warning, "brak połączeń w całym oknie = zbędny serwer")
        // Komunikat okienkowy zawiera czas obserwacji; wariant zapasowy (jeden odczyt) nie.
        XCTAssertTrue(f!.detail.contains { $0.contains(" min") },
                      "opis ma podać, jak długo obserwowaliśmy")
    }

    func testOrphanWithConnectionsInHistoryStaysInfo() {
        let now = Date()
        let history = (0..<200).map { i in
            SocketSample(at: now.addingTimeInterval(-600 + Double(i) * 3),
                         ports: [8081], established: i % 50 == 0 ? 5 : 0)
        }
        let w = window(name: "node", command: "npm exec expo start --port 8081",
                       ppid: 1, ageSeconds: 3 * 3600, cpuPercent: 0, threads: 8,
                       rssStartMB: 700, socketHistory: history)
        let f = OrphanDetector().evaluate(w, config: offline())
        XCTAssertEqual(f?.severity, .info, "połączenia w oknie = ktoś tego używa")
    }

    /// Regresja: komunikat "rodzic (PID 1) już nie żyje" był bez sensu dla procesów,
    /// które osierociały przed startem Stray.
    func testAttributionAdmitsUnknownOrigin() {
        let meta = ProcMeta(pid: 12672, uid: 501, name: "node",
                            command: "npm exec next dev -p 3111",
                            startedAt: Date(), firstSeenAt: Date(),
                            originalPPID: 1, originalAncestry: [], agentEnv: nil)
        let attribution = Titles.attribution(for: meta)
        XCTAssertEqual(attribution, L("attribution.unknown"))
    }

    // MARK: - D3 Leak

    func testLeakDetectsMonotonicGrowth() {
        let w = window(name: "node", command: "node server.js", ppid: 4242,
                       spanSeconds: 600, sampleCount: 60,
                       cpuPercent: 5, threads: 4,
                       rssStartMB: 200, rssEndMB: 700)
        let f = LeakDetector().evaluate(w, config: .default)
        XCTAssertNotNil(f)
        XCTAssertEqual(f?.severity, .warning)
    }

    func testLeakIgnoresStableMemory() {
        let w = window(name: "node", command: "node server.js", ppid: 4242,
                       spanSeconds: 600, sampleCount: 60,
                       cpuPercent: 5, threads: 4,
                       rssStartMB: 400, rssEndMB: 405)
        XCTAssertNil(LeakDetector().evaluate(w, config: .default))
    }

    // MARK: - maskowanie sekretów

    func testSecretMaskerHidesTokens() {
        let input = "node deploy.js --token=ghp_AbCdEf1234567890XyZ --url https://x.dev"
        let out = SecretMasker.mask(input)
        XCTAssertFalse(out.contains("AbCdEf1234567890XyZ"), "token nie może trafić do schowka")
        XCTAssertTrue(out.contains("https://x.dev"), "reszta polecenia ma zostać czytelna")
    }

    func testSecretMaskerIsLinearOnPathologicalInput() {
        // Ironia projektu: maskowanie sekretów nie może zawiesić się tak,
        // jak regex, który dał początek całej aplikacji.
        let evil = String(repeating: "sk-", count: 20_000)
        let started = Date()
        _ = SecretMasker.mask(evil)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.0,
                          "maskowanie musi być liniowe")
    }

    // MARK: - tytuły

    func testPortExtraction() {
        let meta = ProcMeta(pid: 1, uid: 501, name: "node",
                            command: "npm exec expo start --port 8081 --lan",
                            startedAt: Date(), firstSeenAt: Date(),
                            originalPPID: 2, originalAncestry: [], agentEnv: nil)
        XCTAssertEqual(Titles.short(for: meta), "expo start :8081")
    }
}

/// Testy bufora pierścieniowego — nazwa zobowiązuje, a pierwsza wersja
/// przesuwała całą tablicę przy każdym dopisaniu.
final class RingBufferTests: XCTestCase {

    func testKeepsChronologicalOrder() {
        var ring = RingBuffer<Int>(capacity: 4)
        for i in 1...3 { ring.append(i) }
        XCTAssertEqual(ring.values, [1, 2, 3])
    }

    func testDropsOldestWhenFull() {
        var ring = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { ring.append(i) }
        XCTAssertEqual(ring.values, [3, 4, 5], "najstarsze mają wypadać, kolejność ma zostać")
        XCTAssertEqual(ring.count, 3)
    }

    func testSurvivesManyWraps() {
        var ring = RingBuffer<Int>(capacity: 120)
        for i in 1...10_000 { ring.append(i) }
        XCTAssertEqual(ring.values.first, 9881)
        XCTAssertEqual(ring.values.last, 10_000)
        XCTAssertEqual(ring.values.count, 120)
    }

    func testEmptyBuffer() {
        let ring = RingBuffer<Int>(capacity: 5)
        XCTAssertTrue(ring.values.isEmpty)
        XCTAssertEqual(ring.count, 0)
    }
}
