import Foundation

/// Metadane procesu — zbierane raz, przy pierwszym zobaczeniu.
/// `command` pochodzi z KERN_PROCARGS2, który jest znacząco droższy niż proc_pidinfo,
/// więc nie wolno go czytać w każdej próbce.
struct ProcMeta: Sendable, Identifiable {
    let pid: Int32
    let uid: uid_t
    let name: String
    let command: String
    let startedAt: Date
    let firstSeenAt: Date

    /// PPID z chwili, gdy proces był widziany po raz PIERWSZY.
    ///
    /// To jest sedno atrybucji: gdy rodzic umrze, launchd przepisze `ppid` na 1
    /// i informacja o tym, kto ten proces uruchomił, przepada bezpowrotnie.
    /// Skoro próbkujemy w sposób ciągły, widzieliśmy ten proces jeszcze za życia rodzica.
    let originalPPID: Int32
    /// Łańcuch przodków (nazwy) z chwili pierwszego zobaczenia, od rodzica w górę.
    let originalAncestry: [String]

    var id: Int32 { pid }

    /// Czy w łańcuchu przodków był agent AI.
    var agentSession: String? {
        originalAncestry.first { AgentSignatures.isAgent($0) }
    }
}

/// Szereg czasowy — same liczby, bez Stringów. Trzymany w buforze pierścieniowym,
/// więc każdy bajt na próbkę mnoży się przez ~750 procesów × 120 próbek.
struct ProcMetrics: Sendable {
    let at: Date
    let ppid: Int32
    let threads: Int32
    let cpuNanos: UInt64        // user + system, narastająco
    let rss: UInt64
    let diskRead: UInt64        // narastająco
    let diskWritten: UInt64     // narastająco
    let wakeups: UInt64         // interrupt + idle, narastająco
    let contextSwitches: Int32  // narastająco
}

/// Okno obserwacji jednego procesu — wejście dla detektorów.
struct ProcWindow: Sendable {
    let meta: ProcMeta
    let samples: [ProcMetrics]   // rosnąco po czasie

    /// Potomkowie procesu wraz z ich RSS.
    ///
    /// Konieczne, bo `npm exec next dev` to w rzeczywistości łańcuch npm → node → next-server,
    /// w którym proces widoczny na szczycie trzyma 56 MB, a jego wnuk 531 MB.
    /// Mierzenie samego korzenia zaniża odzysk dziesięciokrotnie i — co gorsza —
    /// ubicie samego korzenia osierociłoby dzieci jeszcze bardziej.
    let descendants: [Int32]
    let subtreeRSS: UInt64

    var latest: ProcMetrics? { samples.last }
    var oldest: ProcMetrics? { samples.first }

    var span: TimeInterval {
        guard let a = oldest, let b = latest else { return 0 }
        return b.at.timeIntervalSince(a.at)
    }

    var age: TimeInterval {
        (latest?.at ?? Date()).timeIntervalSince(meta.startedAt)
    }

    /// Średnie zużycie CPU w oknie, w procentach jednego rdzenia.
    var cpuPercent: Double {
        guard let a = oldest, let b = latest, span > 0 else { return 0 }
        let dCPU = Double(b.cpuNanos &- a.cpuNanos)
        return dCPU / (span * 1_000_000_000) * 100
    }

    var deltaDiskBytes: UInt64 {
        guard let a = oldest, let b = latest else { return 0 }
        return (b.diskRead &- a.diskRead) &+ (b.diskWritten &- a.diskWritten)
    }

    var deltaWakeups: UInt64 {
        guard let a = oldest, let b = latest else { return 0 }
        return b.wakeups &- a.wakeups
    }

    var deltaContextSwitches: Int32 {
        guard let a = oldest, let b = latest else { return 0 }
        return b.contextSwitches &- a.contextSwitches
    }

    /// Czy proces przez cały czas obserwacji miał dokładnie jeden wątek.
    var singleThreadedThroughout: Bool {
        !samples.isEmpty && samples.allSatisfy { $0.threads == 1 }
    }

    var isOrphan: Bool { latest?.ppid == 1 }

    var rssMB: Double { Double(latest?.rss ?? 0) / 1_048_576 }

    /// Pamięć całego poddrzewa — tyle realnie wróci po sprzątnięciu.
    var subtreeRSSMB: Double { Double(subtreeRSS) / 1_048_576 }

    /// Czy w chwili pierwszego zobaczenia proces był już sierotą.
    /// Wtedy linii przodków nie da się odtworzyć — i trzeba to powiedzieć wprost,
    /// zamiast twierdzić, że „rodzic PID 1 nie żyje".
    var orphanedBeforeWeStarted: Bool { meta.originalPPID <= 1 }

    /// Przyrost RSS w oknie, w MB (może być ujemny).
    var rssGrowthMB: Double {
        guard let a = oldest, let b = latest else { return 0 }
        return (Double(b.rss) - Double(a.rss)) / 1_048_576
    }

    /// Ile próbek z rzędu miało RSS niemalejące — sygnał wycieku.
    var monotonicRSSRatio: Double {
        guard samples.count > 1 else { return 0 }
        var rising = 0
        for i in 1..<samples.count where samples[i].rss >= samples[i-1].rss { rising += 1 }
        return Double(rising) / Double(samples.count - 1)
    }
}

enum AgentSignatures {
    /// Binarki agentów AI, których sesje nas interesują.
    static let agents = ["claude", "claude.exe", "codex", "cursor", "aider", "copilot", "gemini"]

    static func isAgent(_ name: String) -> Bool {
        let n = name.lowercased()
        return agents.contains { n == $0 || n.hasPrefix($0) }
    }
}
