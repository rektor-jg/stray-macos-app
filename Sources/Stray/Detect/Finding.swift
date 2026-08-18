import Foundation

/// Sesja agenta jako źródło znalezisk.
struct SessionSource: Sendable, Hashable, Identifiable {
    let vendor: String        // "claude", "codex", …
    let sessionID: String?    // stabilny identyfikator, jeśli znany
    let pid: Int32?           // PID sesji, jeśli znany
    let alive: Bool           // czy ta sesja nadal działa
    let tty: String?          // terminal sesji — najczytelniejszy adres dla człowieka

    var id: String { sessionID ?? pid.map { "\(vendor)-\($0)" } ?? vendor }

    /// „claude · ttys000 · PID 2061" — tak użytkownik znajdzie tę kartę w terminalu.
    var label: String {
        var parts = [vendor]
        if let tty { parts.append(tty) }
        if let pid { parts.append("PID \(pid)") }
        return parts.joined(separator: " · ")
    }
}

enum Severity: Int, Comparable, Sendable {
    case info = 0      // widoczne w liście, nie alarmuje
    case warning = 1   // żółty badge
    case critical = 2  // czerwony badge + powiadomienie

    static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
}

enum DetectorID: String, Sendable {
    case spinner = "D1"
    case orphan  = "D2"
    case leak    = "D3"

    var label: String {
        switch self {
        case .spinner: return L("detector.spinner")
        case .orphan:  return L("detector.orphan")
        case .leak:    return L("detector.leak")
        }
    }
}

struct Finding: Sendable, Identifiable {
    let detector: DetectorID
    let severity: Severity
    let pid: Int32
    let title: String        // np. "next dev :3111"
    let summary: String      // jedna linia: co jest nie tak
    let detail: [String]     // wiersze dowodowe
    let attribution: String? // która sesja to zostawiła
    let reclaimBytes: UInt64 // ile pamięci wróci po ubiciu
    let command: String
    let startedAt: Date

    /// Sesja agenta, która ten proces zostawiła — klucz do grupowania w UI.
    /// `nil`, gdy pochodzenia nie znamy. Ubicie sieroty nie sprawia, że sesja
    /// przestanie produkować kolejne; użytkownik musi widzieć, KTO śmieci.
    let source: SessionSource?

    /// Klucz do deduplikacji i cooldownu. Musi przeżyć kolejne próbki tego samego problemu.
    var id: String { "\(detector.rawValue):\(pid)" }
}
