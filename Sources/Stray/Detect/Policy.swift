import Foundation

/// Deduplikacja, cooldown i lista ignorowanych.
/// Jedno powiadomienie na znalezisko, nie jedno na próbkę.
final class Policy {
    private var lastNotified: [String: Date] = [:]
    private let cooldown: TimeInterval

    init(cooldown: TimeInterval = 30 * 60) { self.cooldown = cooldown }

    /// Filtruje surowe znaleziska przez listę ignorowanych.
    func filter(_ findings: [Finding]) -> [Finding] {
        findings
            .filter { !Whitelist.isUserIgnored($0.command) }
            .sorted { ($0.severity, $0.reclaimBytes) > ($1.severity, $1.reclaimBytes) }
    }

    /// Czy o tym znalezisku wolno powiadomić użytkownika systemowym powiadomieniem.
    func shouldNotify(_ finding: Finding, now: Date = Date()) -> Bool {
        guard finding.severity == .critical else { return false }
        if let last = lastNotified[finding.id], now.timeIntervalSince(last) < cooldown {
            return false
        }
        lastNotified[finding.id] = now
        return true
    }

    func forget(pid: Int32) {
        for key in lastNotified.keys where key.hasSuffix(":\(pid)") {
            lastNotified.removeValue(forKey: key)
        }
    }
}

private func > (a: (Severity, UInt64), b: (Severity, UInt64)) -> Bool {
    a.0 != b.0 ? a.0 > b.0 : a.1 > b.1
}
