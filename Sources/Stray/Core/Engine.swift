import Foundation
import SwiftUI

/// Spina próbkowanie, detektory i politykę. Jedyny stan, który widzi UI.
@MainActor
final class Engine: ObservableObject {
    /// Jedna instancja na aplikację — silnik startuje przy uruchomieniu procesu,
    /// a nie przy pierwszym otwarciu okna.
    static let shared = Engine()

    @Published private(set) var findings: [Finding] = []
    @Published private(set) var selfCostMillis: Double = 0
    @Published private(set) var trackedCount: Int = 0
    @Published private(set) var lastTick: Date?
    @Published private(set) var live = LiveFootprint()
    @Published private(set) var today = DailyFootprint(day: FootprintLedger.dayKey())
    @Published private(set) var weekCPUHours: Double = 0
    @Published private(set) var diskReport: DiskReport?
    @Published private(set) var diskStage: String?
    @Published private(set) var isDeleting = false
    @Published var lastCleanup: (freed: UInt64, skipped: Int)?

    private let sampler = Sampler()
    private let ledger = FootprintLedger()
    private let policy = Policy()
    private let detectors: [Detector] = [SpinnerDetector(), OrphanDetector(), LeakDetector()]
    private var config = DetectorConfig.default
    private var timer: Timer?
    private let queue = DispatchQueue(label: "app.stray.sampler", qos: .utility)

    var criticalCount: Int { findings.filter { $0.severity == .critical }.count }
    var warningCount: Int { findings.filter { $0.severity == .warning }.count }

    var reclaimableBytes: UInt64 {
        findings.reduce(0) { $0 + $1.reclaimBytes }
    }

    /// Znaleziska pogrupowane po sesji, która je zostawiła.
    ///
    /// „2 sieroty, 818 MB" mówi, co posprzątać. „Sesja ttys000 zostawiła 2 serwery,
    /// 818 MB — nadal działa" mówi, kto śmieci. Ubicie sieroty nie powstrzyma sesji
    /// przed zostawieniem następnej, więc użytkownik musi widzieć źródło.
    struct SourceGroup: Identifiable {
        let source: SessionSource?      // nil = pochodzenie nieznane
        let findings: [Finding]
        var id: String { source?.id ?? "unknown" }
        var reclaimBytes: UInt64 { findings.reduce(0) { $0 + $1.reclaimBytes } }
    }

    var groupedBySource: [SourceGroup] {
        var buckets: [String: (SessionSource?, [Finding])] = [:]
        for f in findings {
            let key = f.source?.id ?? "unknown"
            buckets[key, default: (f.source, [])].1.append(f)
        }
        return buckets.values
            .map { SourceGroup(source: $0.0, findings: $0.1) }
            .sorted { a, b in
                // znane źródła przed nieznanymi, potem po wielkości
                if (a.source == nil) != (b.source == nil) { return a.source != nil }
                return a.reclaimBytes > b.reclaimBytes
            }
    }

    /// Rekomendacje posortowane od najbardziej wartych działania.
    var actionable: [(Finding, Advice)] {
        findings
            .map { ($0, Advisor.advise(finding: $0, isAgentItself: AgentSignatures.isAgent($0.title))) }
            .filter { $0.1.actionable }
            .sorted { $0.0.reclaimBytes > $1.0.reclaimBytes }
    }

    func start() {
        tick()
        // Skan dyskowy trwa ~20 s, więc raz na starcie w tle i dalej na żądanie.
        scanDisk()
        timer = Timer.scheduledTimer(withTimeInterval: Sampler.interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let cfg = config
        queue.async { [weak self] in
            guard let self else { return }
            let windows = self.sampler.tick()
            let raw = windows.compactMap { w in
                self.detectors.compactMap { $0.evaluate(w, config: cfg) }.first
            }
            self.ledger.record(windows: windows)
            let cost = self.sampler.selfCPUPercent
            let tracked = self.sampler.trackedCount
            let live = self.ledger.live
            let today = self.ledger.today
            let week = self.ledger.weekCPUHours
            Task { @MainActor in
                self.findings = self.policy.filter(raw)
                self.selfCostMillis = cost
                self.trackedCount = tracked
                self.live = live
                self.today = today
                self.weekCPUHours = week
                self.lastTick = Date()
                self.notifyIfNeeded()
            }
        }
    }

    private func notifyIfNeeded() {
        for finding in findings where policy.shouldNotify(finding) {
            Notifier.post(finding)
        }
    }

    // MARK: - akcje z UI

    func kill(_ finding: Finding) {
        let pid = finding.pid
        let reclaimed = finding.reclaimBytes
        let started = finding.startedAt
        queue.async { [weak self] in
            let killed = ProcessActions.terminateTree(pid: pid, expectedStart: started)
            if killed > 0 { self?.ledger.recordKill(reclaimed: reclaimed) }
            Task { @MainActor in
                if killed > 0 {
                    self?.policy.forget(pid: pid)
                    self?.findings.removeAll { $0.pid == pid }
                }
            }
        }
    }

    /// Kasowanie idzie przez DiskActions, które re-waliduje każdą pozycję tuż przed
    /// usunięciem — raport może mieć kilkanaście minut, a świat mógł się zmienić.
    func deleteDisk(_ items: [DiskItem], permanent: Bool) {
        guard !items.isEmpty, !isDeleting else { return }
        isDeleting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var freed: UInt64 = 0
            var skipped = 0
            var removed = Set<String>()
            for item in items {
                do {
                    let bytes = permanent
                        ? try DiskActions.deletePermanently(item)
                        : try DiskActions.trash(item)
                    freed += bytes
                    removed.insert(item.path)
                } catch {
                    skipped += 1
                }
            }
            Task { @MainActor in
                guard let self else { return }
                if freed > 0 { self.ledgerRecordDiskCleanup(freed) }
                self.diskReport?.items.removeAll { removed.contains($0.path) }
                self.lastCleanup = (freed, skipped)
                self.isDeleting = false
                self.today = self.currentToday()
            }
        }
    }

    private func ledgerRecordDiskCleanup(_ freed: UInt64) { ledger.recordDiskCleanup(freed: freed) }
    private func currentToday() -> DailyFootprint { ledger.today }

    func scanDisk() {
        guard diskStage == nil else { return }
        diskStage = "start"
        let onStage: @Sendable (String) -> Void = { [weak self] stage in
            Task { @MainActor in self?.diskStage = stage }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let report = DiskScanner.scan(progress: onStage)
            Task { @MainActor in
                self?.diskReport = report
                self?.diskStage = nil
            }
        }
    }

    func ignore(_ finding: Finding) {
        IgnoreList.add(finding.command)
        findings.removeAll { $0.id == finding.id }
    }

    /// Buduje raport i wkłada do schowka. Dla D1 dokłada stos z `sample`.
    func copyReport(_ finding: Finding) {
        queue.async {
            let stack = finding.detector == .spinner
                ? ProcessActions.sampleStack(pid: finding.pid)
                : nil
            let text = ProcessActions.report(for: finding, stack: stack)
            Task { @MainActor in
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            }
        }
    }
}
