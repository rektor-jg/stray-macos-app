import Foundation

/// Tryb `--scan`: jednorazowy przebieg wypisany na stdout.
///
/// Istnieje po to, żeby dało się testować detektory na żywym systemie bez GUI —
/// i żeby dowieść, że działają, zanim powstanie choćby jeden widok.
enum CLI {
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
        print(String(format: "Koszt własny: %.1f ms na próbkę (%.3f%% CPU przy oknie %.0f s)",
                     sampler.lastScanMillis,
                     sampler.lastScanMillis / (Sampler.interval * 1000) * 100,
                     Sampler.interval))
    }
}
