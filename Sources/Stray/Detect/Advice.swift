import Foundation

/// Rekomendacja: czy to warto wyłączyć i dlaczego.
enum Advice: Sendable {
    case killNow(String)       // czerwony — marnuje zasoby teraz
    case probablyStale(String) // pomarańczowy — prawdopodobnie zbędne
    case keep(String)          // zielony — działa i jest używane
    case protected(String)     // nie ruszamy: to twoja aktywna sesja

    var actionable: Bool {
        switch self {
        case .killNow, .probablyStale: return true
        case .keep, .protected: return false
        }
    }

    var text: String {
        switch self {
        case .killNow(let s), .probablyStale(let s), .keep(let s), .protected(let s): return s
        }
    }
}

enum Advisor {
    /// Zasada nadrzędna: nigdy nie doradzamy ubicia procesu agenta.
    /// To może być sesja, w której użytkownik właśnie pracuje — a nawet ta,
    /// która czyta tę rekomendację.
    static func advise(finding: Finding, isAgentItself: Bool) -> Advice {
        if isAgentItself {
            return .protected(L("advice.protected.agent"))
        }
        switch finding.detector {
        case .spinner:
            return .killNow(L("advice.kill.spinner"))
        case .orphan:
            if finding.severity == .info { return .keep(L("advice.keep.orphan")) }
            return .probablyStale(L("advice.stale.orphan"))
        case .leak:
            return .probablyStale(L("advice.stale.leak"))
        }
    }
}
