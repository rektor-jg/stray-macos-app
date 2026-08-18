import Foundation

/// Bufor pierścieniowy na szereg czasowy jednego procesu.
struct RingBuffer<T> {
    private var storage: [T] = []
    private let capacity: Int

    init(capacity: Int) { self.capacity = capacity; storage.reserveCapacity(capacity) }

    mutating func append(_ value: T) {
        storage.append(value)
        if storage.count > capacity { storage.removeFirst(storage.count - capacity) }
    }

    var values: [T] { storage }
    var count: Int { storage.count }
}

/// Pętla próbkowania. Utrzymuje metadane, historię i — najważniejsze —
/// pamięć o przodkach procesów, zanim te osierocieją.
final class Sampler {
    /// 120 próbek × 3 s = 10 minut historii. Wystarcza na detekcję wycieku (D3),
    /// a przy ~750 czytelnych procesach kosztuje kilka MB.
    static let historyDepth = 120
    static let interval: TimeInterval = 3.0

    private var metas: [Int32: ProcMeta] = [:]
    private var history: [Int32: RingBuffer<ProcMetrics>] = [:]
    private let ownUID = getuid()

    /// Koszt własny — narzędzie do łapania żarłoków musi publicznie pokazywać swój rachunek.
    private(set) var lastScanMillis: Double = 0
    private(set) var trackedCount: Int = 0

    /// Jedna próbka całego systemu. Zwraca okna gotowe dla detektorów.
    @discardableResult
    func tick(now: Date = Date()) -> [ProcWindow] {
        let started = Date()
        let pids = ProcScanner.listPIDs()
        var alive = Set<Int32>()

        for pid in pids {
            guard let (metrics, uid, name, ppid, startedAt) = ProcScanner.sample(pid, at: now)
            else { continue }
            // Tylko własny UID — procesów roota i tak nie moglibyśmy ubić.
            guard uid == ownUID else { continue }
            alive.insert(pid)

            if metas[pid] == nil {
                // Pierwsze zobaczenie: TERAZ jest jedyny moment, gdy rodzic jeszcze żyje
                // i da się zapisać linię przodków.
                let ancestry = buildAncestry(startingFrom: ppid)
                // Jeden sysctl daje i argumenty, i znaczniki środowiskowe.
                let info = ProcScanner.processInfo(pid)
                metas[pid] = ProcMeta(
                    pid: pid,
                    uid: uid,
                    name: name,
                    command: info.command ?? name,
                    startedAt: startedAt,
                    firstSeenAt: now,
                    originalPPID: ppid,
                    originalAncestry: ancestry,
                    agentEnv: info.agent
                )
                history[pid] = RingBuffer(capacity: Self.historyDepth)
            }
            history[pid]?.append(metrics)
        }

        // sprzątanie po procesach, które zniknęły
        for pid in metas.keys where !alive.contains(pid) {
            metas.removeValue(forKey: pid)
            history.removeValue(forKey: pid)
        }

        lastScanMillis = Date().timeIntervalSince(started) * 1000
        trackedCount = metas.count

        // Mapa dzieci z bieżącej próbki — potrzebna, bo metryki poddrzewa
        // trzeba liczyć na aktualnym kształcie drzewa, nie na zapamiętanym.
        var children: [Int32: [Int32]] = [:]
        var rssByPID: [Int32: UInt64] = [:]
        for (pid, ring) in history {
            guard let last = ring.values.last else { continue }
            children[last.ppid, default: []].append(pid)
            rssByPID[pid] = last.rss
        }

        return metas.compactMap { pid, meta in
            guard let samples = history[pid]?.values, !samples.isEmpty else { return nil }
            let kids = descendants(of: pid, children: children)
            let subtreeRSS = ([pid] + kids).reduce(UInt64(0)) { $0 + (rssByPID[$1] ?? 0) }
            return ProcWindow(meta: meta, samples: samples,
                              descendants: kids, subtreeRSS: subtreeRSS)
        }
    }

    /// Wszyscy potomkowie, wszerz. Limit głębokości chroni przed cyklem
    /// w wypadku niespójnej próbki (proces zniknął w trakcie skanu).
    private func descendants(of pid: Int32, children: [Int32: [Int32]],
                             maxDepth: Int = 12) -> [Int32] {
        var result: [Int32] = []
        var frontier = children[pid] ?? []
        var depth = 0
        while !frontier.isEmpty && depth < maxDepth {
            result.append(contentsOf: frontier)
            frontier = frontier.flatMap { children[$0] ?? [] }
            depth += 1
        }
        return result
    }

    /// Idzie w górę drzewa PPID i zbiera nazwy przodków.
    /// Wołane tylko raz na proces, bo tylko wtedy ma sens — potem rodzic może już nie żyć.
    private func buildAncestry(startingFrom ppid: Int32, maxDepth: Int = 8) -> [String] {
        var chain: [String] = []
        var current = ppid
        var depth = 0
        while current > 1 && depth < maxDepth {
            if let cached = metas[current] {
                chain.append(cached.name)
                current = cached.originalPPID
            } else if let (_, _, name, parentPPID, _) = ProcScanner.sample(current, at: Date()) {
                chain.append(name)
                current = parentPPID
            } else {
                break
            }
            depth += 1
        }
        return chain
    }
}
