import SwiftUI

/// Pierwszy ekran odpowiada na jedno pytanie: ile AI zabiera mi z systemu.
///
/// Metodologia jest tu widoczna celowo. Łatwo pokazać wielką liczbę i skłamać —
/// dlatego to, co zmierzone, nigdy nie jest sumowane z tym, co wywnioskowane,
/// bez wyraźnej etykiety przy każdej pozycji.
struct OverviewView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                nowSection
                todaySection
                if !engine.actionable.isEmpty { adviceSection }
                if let report = engine.diskReport { diskSummary(report) }
                methodology
            }
            .padding(12)
        }
    }

    // MARK: - teraz

    private var nowSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("overview.now"), L("overview.now.sub"))
            HStack(spacing: 8) {
                StatTile(title: L("overview.processes"),
                         value: "\(engine.live.totalProcesses)",
                         sub: L("overview.processes.sub", engine.live.agentProcesses, engine.live.descendantProcesses))
                StatTile(title: L("overview.cpu"),
                         value: String(format: "%.0f%%", engine.live.cpuPercent),
                         sub: L("overview.cpu.sub"),
                         tint: Heat.forCPU(percent: engine.live.cpuPercent).color)
                StatTile(title: L("overview.memory"),
                         value: byteString(engine.live.rssBytes),
                         sub: L("overview.memory.sub"),
                         tint: Heat.forMemory(bytes: engine.live.rssBytes).color)
            }
            if engine.live.unattributed > 0 {
                HStack(spacing: 5) {
                    Image(systemName: "questionmark.circle").font(.caption2)
                    Text(L("overview.unattributed", engine.live.unattributed, byteString(engine.live.unattributedRSSBytes)))
                        .font(.caption2)
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - dziś

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("overview.today"), L("overview.today.sub"))
            HStack(spacing: 8) {
                StatTile(title: L("overview.cputime"),
                         value: String(format: "%.1f h", engine.today.cpuHours),
                         sub: L("overview.cputime.sub", engine.weekCPUHours))
                StatTile(title: L("overview.peak"),
                         value: byteString(engine.today.peakRSSBytes),
                         sub: L("overview.peak.sub", engine.today.maxProcesses))
                StatTile(title: L("overview.reclaimed"),
                         value: byteString(engine.today.reclaimedBytes),
                         sub: L("overview.reclaimed.sub", engine.today.killedProcesses),
                         tint: engine.today.reclaimedBytes > 0 ? .green : .primary)
            }
        }
    }

    // MARK: - co warto wyłączyć

    private var adviceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("overview.advice"), L("overview.advice.sub", engine.actionable.count))
            ForEach(Array(engine.actionable.prefix(4).enumerated()), id: \.offset) { _, pair in
                let (finding, advice) = pair
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: advice.symbol)
                        .foregroundStyle(advice.color).font(.caption)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(finding.title).font(.callout).bold()
                            Text(byteString(finding.reclaimBytes))
                                .font(.caption2)
                                .foregroundStyle(Heat.forMemory(bytes: finding.reclaimBytes).color)
                        }
                        Text(advice.text).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Button(L("advice.kill")) { engine.kill(finding) }
                        .controlSize(.small).buttonStyle(.bordered)
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 7).fill(advice.color.opacity(0.09)))
            }
        }
    }

    // MARK: - dysk

    private func diskSummary(_ report: DiskReport) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(L("overview.disk"), L("overview.disk.sub", byteString(report.grandTotal)))
            ShareBar(segments: [
                (Double(report.total(.measured)), Confidence.measured.color),
                (Double(report.total(.traced)), Confidence.traced.color),
                (Double(report.total(.inferred)), Confidence.inferred.color),
            ])
            HStack(spacing: 10) {
                ForEach(Confidence.allCases.sorted(by: >), id: \.rawValue) { conf in
                    HStack(spacing: 3) {
                        Circle().fill(conf.color).frame(width: 6, height: 6)
                        Text("\(conf.label) \(byteString(report.total(conf)))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if report.reclaimable > 0 {
                Text(L("overview.disk.reclaimable", byteString(report.reclaimable)))
                    .font(.caption).foregroundStyle(.green)
            }
        }
    }

    private var methodology: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Confidence.allCases.sorted(by: >), id: \.rawValue) { conf in
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: conf.symbol).font(.caption2).foregroundStyle(conf.color)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(conf.label).font(.caption2).bold()
                            Text(conf.explanation).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text(L("overview.method.note"))
                    .font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
            }
            .padding(.top, 4)
        } label: {
            Text(L("overview.method")).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func sectionTitle(_ title: String, _ sub: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.subheadline).bold()
            Text(sub).font(.caption2).foregroundStyle(.secondary)
            Spacer()
        }
    }
}
