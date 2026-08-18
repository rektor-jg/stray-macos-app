import Foundation

/// Bufor pierścieniowy na szereg czasowy jednego procesu.
///
/// Nazwa zobowiązuje: pierwsza wersja robiła `removeFirst`, czyli przesuwała całą
/// tablicę przy każdym dopisaniu. Przy 765 procesach × 120 próbek to ~92 tysiące
/// przesunięć elementów na każdy takt — w narzędziu, które chwali się własnym
/// zużyciem CPU. Teraz nadpisujemy w miejscu, w stałym czasie.
struct RingBuffer<T> {
    private var storage: [T?]
    private var head = 0        // gdzie trafi następny element
    private var filled = 0

    init(capacity: Int) { storage = Array(repeating: nil, count: max(1, capacity)) }

    mutating func append(_ value: T) {
        storage[head] = value
        head = (head + 1) % storage.count
        if filled < storage.count { filled += 1 }
    }

    /// Zwraca próbki w kolejności chronologicznej.
    var values: [T] {
        guard filled > 0 else { return [] }
        let start = filled == storage.count ? head : 0
        return (0..<filled).compactMap { storage[(start + $0) % storage.count] }
    }

    var count: Int { filled }

    /// Dwie ostatnie próbki bez kopiowania całej historii — dla filtra wstępnego,
    /// który przebiega przez każdy proces w każdym takcie.
    var lastTwo: (T?, T?) {
        guard filled > 0 else { return (nil, nil) }
        let last = (head - 1 + storage.count) % storage.count
        let prev = (head - 2 + storage.count) % storage.count
        return (filled > 1 ? storage[prev] : nil, storage[last])
    }
}
