import Foundation
import SwiftUI

/// Spina próbkowanie, detektory i politykę. Jedyny stan, który widzi UI.
@MainActor
final class Engine: ObservableObject {
    @Published private(set) var findings: [Finding] = []
    @Published private(set) var selfCostMillis: Double = 0
    @Published private(set) var trackedCount: Int = 0
    @Published private(set) var lastTick: Date?

    private let sampler = Sampler()
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

    func start() {
        tick()
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
            let cost = self.sampler.lastScanMillis
            let tracked = self.sampler.trackedCount
            Task { @MainActor in
                self.findings = self.policy.filter(raw)
                self.selfCostMillis = cost
                self.trackedCount = tracked
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
        queue.async { [weak self] in
            let killed = ProcessActions.terminateTree(pid: pid)
            Task { @MainActor in
                if killed > 0 {
                    self?.policy.forget(pid: pid)
                    self?.findings.removeAll { $0.pid == pid }
                }
            }
        }
    }

    func ignore(_ finding: Finding) {
        Whitelist.ignore(finding.command)
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
