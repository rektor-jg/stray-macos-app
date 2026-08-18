import Foundation

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
        case .spinner: return "Zakleszczony"
        case .orphan:  return "Sierota"
        case .leak:    return "Wyciek pamięci"
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

    /// Klucz do deduplikacji i cooldownu. Musi przeżyć kolejne próbki tego samego problemu.
    var id: String { "\(detector.rawValue):\(pid)" }
}
