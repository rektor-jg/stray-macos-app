import Foundation

/// Na ile pewnie potrafimy powiedzieć, że coś należy do AI.
///
/// To rozróżnienie jest tu najważniejsze. Łatwo napisać aplikację, która pokaże wielką liczbę
/// „AI zabrało ci 40 GB" — i skłamie, bo dorzuci cały cache npm z ostatnich pięciu lat.
/// Liczby z różnych poziomów pewności NIGDY nie sumują się w jedną bez etykiety.
enum Confidence: Int, Comparable, Sendable, CaseIterable {
    /// Zmierzone bezpośrednio: proces agenta, jego żywe poddrzewo, jego własne katalogi.
    case measured = 2
    /// Prześledzone: zapisaliśmy linię przodków albo ścieżka wskazuje na katalog roboczy agenta.
    case traced = 1
    /// Wywnioskowane z poszlak: projekt zawiera ślady agenta, więc jego artefakty
    /// prawdopodobnie powstały z jego udziałem. Nie jest to pomiar.
    case inferred = 0

    static func < (a: Confidence, b: Confidence) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .measured: return "zmierzone"
        case .traced:   return "prześledzone"
        case .inferred: return "wywnioskowane"
        }
    }

    var explanation: String {
        switch self {
        case .measured: return "proces agenta lub jego katalog — policzone bezpośrednio"
        case .traced:   return "zapisana linia przodków albo ścieżka katalogu roboczego agenta"
        case .inferred: return "poszlaki w projekcie (CLAUDE.md, .claude/, .cursor/) — szacunek, nie pomiar"
        }
    }
}

/// Skala natężenia. Kolor ma nieść informację, a nie dekorować:
/// czerwony znaczy „to jest dużo i prawdopodobnie da się odzyskać".
enum Heat: Int, Sendable {
    case calm = 0, notable = 1, high = 2, severe = 3

    static func forMemory(bytes: UInt64) -> Heat {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1500 { return .severe }
        if mb >= 500  { return .high }
        if mb >= 100  { return .notable }
        return .calm
    }

    static func forCPU(percent: Double) -> Heat {
        if percent >= 70 { return .severe }
        if percent >= 25 { return .high }
        if percent >= 5  { return .notable }
        return .calm
    }

    static func forDisk(bytes: UInt64) -> Heat {
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 10 { return .severe }
        if gb >= 2  { return .high }
        if gb >= 0.5 { return .notable }
        return .calm
    }
}

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
            return .protected("aktywna sesja agenta — Stray nigdy nie doradza jej ubicia")
        }
        switch finding.detector {
        case .spinner:
            return .killNow("pętla bez postępu — ten proces już nigdy nie skończy pracy")
        case .orphan:
            if finding.severity == .info {
                return .keep("ktoś jest podpięty — serwer jest w użyciu")
            }
            return .probablyStale("nikt nie jest podpięty, a rodzic dawno umarł")
        case .leak:
            return .probablyStale("pamięć rośnie monotonicznie — restart zwolni ją od razu")
        }
    }
}
