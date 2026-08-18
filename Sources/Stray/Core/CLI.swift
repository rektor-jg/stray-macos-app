import Foundation

/// Tryb `--scan`: jednorazowy przebieg wypisany na stdout.
///
/// Istnieje po to, żeby dało się testować detektory na żywym systemie bez GUI —
/// i żeby dowieść, że działają, zanim powstanie choćby jeden widok.
enum CLI {

    /// Tryb `--clean`: WYŁĄCZNIE próba na sucho. Kasowanie żyje w GUI, bo tam jest
    /// ekran potwierdzenia — narzędzie, które kasuje gigabajty jednym flagiem
    /// w terminalu, prędzej czy później zrobi to komuś przez pomyłkę.
    static func cleanDryRun() {
        let report = DiskScanner.scan { stage in
            FileHandle.standardError.write("\r  \(stage)…            ".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\r".data(using: .utf8)!)

        print(L("cli.dryrun.title") + "\n")
        var total: UInt64 = 0
        for item in report.items where item.safeToDelete {
            let deletable = DiskActions.deletableBytes(item)
            let blocked = item.bytes > deletable ? item.bytes - deletable : 0
            total += deletable
            print("  × \(pad(item.displayName, 38)) \(byteString(deletable))")
            if blocked > 0 {
                print("      \(byteString(blocked)) pominięte: \(L("disk.confirm.scratchpad"))")
            }
            if let err = validationError(item) {
                print("      ! \(err)")
            }
        }
        print("\n  " + L("disk.confirm.total", byteString(total)))

        let protected = report.items.filter { !$0.safeToDelete }
        if !protected.isEmpty {
            print("\n" + L("cli.dryrun.protected") + "\n")
            for item in protected {
                print("  · \(pad(item.displayName, 38)) \(byteString(item.bytes))")
                print("      \(item.note)")
            }
        }
    }

    private static func validationError(_ item: DiskItem) -> String? {
        do { try DiskActions.validate(item); return nil }
        catch { return error.localizedDescription }
    }


    /// Tryb `--footprint`: te same liczby, które pokazuje ekran Przegląd.
    static func footprint(seconds: Int = 12) {
        let sampler = Sampler()
        let ledger = FootprintLedger()
        let ticks = max(2, seconds / Int(Sampler.interval))
        for i in 0..<ticks {
            ledger.record(windows: sampler.tick())
            FileHandle.standardError.write("\rpróbka \(i + 1)/\(ticks)   ".data(using: .utf8)!)
            if i < ticks - 1 { Thread.sleep(forTimeInterval: Sampler.interval) }
        }
        FileHandle.standardError.write("\r".data(using: .utf8)!)

        let live = ledger.live
        print("ŚLAD AI W SYSTEMIE\n")
        print("── TERAZ")
        print("   Procesy AI:      \(live.totalProcesses)  (\(live.agentProcesses) agentów + \(live.descendantProcesses) potomków)")
        print(String(format: "   CPU:             %.0f%%", live.cpuPercent))
        print("   Pamięć:          \(byteString(live.rssBytes))")
        if live.unattributed > 0 {
            print("   Nieprzypisane:   \(live.unattributed) procesów, \(byteString(live.unattributedRSSBytes))")
            print("                    (osierocone przed startem — NIE doliczane do AI)")
        }
        print("")
        print("── DZIŚ (\(ledger.today.day))")
        print(String(format: "   Czas CPU:        %.2f h", ledger.today.cpuHours))
        print("   Szczyt pamięci:  \(byteString(ledger.today.peakRSSBytes))")
        print("   Odzyskane:       \(byteString(ledger.today.reclaimedBytes)) w \(ledger.today.killedProcesses) sprzątnięciach")
        print(String(format: "\n── TYDZIEŃ\n   Czas CPU:        %.2f h", ledger.weekCPUHours))
        // celowo bez save(): tryb CLI tylko podgląda, a zapis należy do działającej aplikacji
    }


    /// Tryb `--disk`: skan przestrzeni zajętej przez AI, z podziałem na poziomy pewności.
    static func disk() {
        let report = DiskScanner.scan { stage in
            FileHandle.standardError.write("\r  skanuję: \(stage)…            ".data(using: .utf8)!)
        }
        FileHandle.standardError.write("\r".data(using: .utf8)!)

        print("PRZESTRZEŃ ZAJĘTA PRZEZ AI\n")
        for conf in [Confidence.measured, .traced, .inferred] {
            let items = report.items.filter { $0.confidence == conf }
            guard !items.isEmpty else { continue }
            print("── \(conf.label.uppercased()) — \(byteString(report.total(conf)))")
            print("   \(conf.explanation)")
            for item in items.prefix(8) {
                let mark = item.safeToDelete ? "×" : " "
                print("   \(mark) \(pad(item.displayName, 34)) \(byteString(item.bytes))")
                print("       \(item.note)")
            }
            print("")
        }
        print("── PODSUMOWANIE")
        for (cat, bytes) in report.byCategory() {
            print("   \(pad(cat.label, 20)) \(byteString(bytes))")
        }
        print("")
        print("   Razem widziane:     \(byteString(report.grandTotal))")
        print("   Bezpieczne do usunięcia (×): \(byteString(report.reclaimable))")
        print(String(format: "   Skan trwał %.1f s", report.durationSeconds))
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? String(s.prefix(n)) : s + String(repeating: " ", count: n - s.count)
    }

    static func scan(seconds: Int = 12) {
        let sampler = Sampler()
        let detectors: [Detector] = [SpinnerDetector(), OrphanDetector(), LeakDetector()]
        // Detektory potrzebują okna czasowego, nie pojedynczej próbki — zbieramy kilka.
        var windows: [ProcWindow] = []
        let ticks = max(2, seconds / Int(Sampler.interval))
        for i in 0..<ticks {
            windows = sampler.tick()
            FileHandle.standardError.write(
                "\rpróbka \(i + 1)/\(ticks)  (\(String(format: "%.1f", sampler.lastScanMillis)) ms, \(sampler.trackedCount) procesów)   "
                    .data(using: .utf8)!)
            if i < ticks - 1 { Thread.sleep(forTimeInterval: Sampler.interval) }
        }
        FileHandle.standardError.write("\n\n".data(using: .utf8)!)

        // W trybie CLI świadomie luzujemy próg czasowy D1/D3: nie zbierzemy 90 s historii
        // w 12-sekundowym przebiegu. Sygnatura (1 wątek, 0 wybudzeń, 0 I/O) zostaje bez zmian.
        var cfg = DetectorConfig.default
        cfg.spinnerMinSpan = Double(seconds) - Sampler.interval - 1
        cfg.leakMinSpan = cfg.spinnerMinSpan

        let findings = windows
            .compactMap { w in detectors.compactMap { $0.evaluate(w, config: cfg) }.first }
            .sorted { $0.severity > $1.severity }

        guard !findings.isEmpty else {
            print("Czysto — nic nie znaleziono wśród \(sampler.trackedCount) procesów.")
            return
        }

        for f in findings {
            let mark = f.severity == .critical ? "[!]" : (f.severity == .warning ? "[?]" : "[ ]")
            print("\(mark) \(f.title) · PID \(f.pid)")
            print("    \(f.summary)")
            for d in f.detail { print("      · \(d)") }
            if let a = f.attribution { print("      ↳ \(a)") }
            print("      $ \(SecretMasker.mask(String(f.command.prefix(100))))")
            print("")
        }
        let mb = Double(findings.reduce(0) { $0 + $1.reclaimBytes }) / 1_048_576
        print(String(format: "Razem: %d znalezisk, do odzyskania %.0f MB", findings.count, mb))
        // CPU zmierzone przez rusage na samym sobie; czas zegarowy podany osobno,
        // bo to inna wielkość i mylenie ich było błędem poprzedniej wersji.
        print(String(format: "Koszt własny: %.3f%% CPU (zmierzone), takt %.1f ms zegarowo, zimny start %.0f ms",
                     sampler.selfCPUPercent, sampler.medianScanMillis, sampler.coldStartMillis))
    }
}
