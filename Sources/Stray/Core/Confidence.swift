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
        case .measured: return L("confidence.measured")
        case .traced:   return L("confidence.traced")
        case .inferred: return L("confidence.inferred")
        }
    }

    var explanation: String {
        switch self {
        case .measured: return L("confidence.measured.why")
        case .traced:   return L("confidence.traced.why")
        case .inferred: return L("confidence.inferred.why")
        }
    }
}
