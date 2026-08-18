import SwiftUI

struct ProcessesView: View {
    @ObservedObject var engine: Engine

    var body: some View {
        if engine.findings.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.green)
                Text(L("proc.clean")).font(.callout)
                Text(L("proc.clean.sub", engine.trackedCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    ForEach(engine.groupedBySource) { group in
                        Section {
                            ForEach(group.findings) { finding in
                                FindingRow(finding: finding, engine: engine)
                                Divider()
                            }
                        } header: {
                            SourceHeader(group: group)
                        }
                    }
                }
            }
        }
    }
}

/// Nagłówek grupy: kto zostawił te procesy i czy nadal działa.
struct SourceHeader: View {
    let group: Engine.SourceGroup

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: group.source == nil ? "questionmark.circle" : "terminal")
                .font(.caption2)
                .foregroundStyle(group.source?.alive == true ? .orange : .secondary)
            if let s = group.source {
                Text(s.label).font(.caption).bold()
                Text(s.alive ? L("source.alive") : L("source.dead"))
                    .font(.caption2)
                    .foregroundStyle(s.alive ? .orange : .secondary)
            } else {
                Text(L("source.unknown")).font(.caption).bold()
            }
            Spacer()
            Text(L("source.summary", group.findings.count, byteString(group.reclaimBytes)))
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }
}

struct FindingRow: View {
    let finding: Finding
    @ObservedObject var engine: Engine
    @State private var expanded = false
    @State private var copied = false

    private var advice: Advice {
        Advisor.advise(finding: finding, isAgentItself: AgentSignatures.isAgent(finding.title))
    }
    private var heat: Heat { Heat.forMemory(bytes: finding.reclaimBytes) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: advice.symbol)
                    .foregroundStyle(advice.color).font(.caption).padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(finding.title).font(.system(.body, design: .rounded)).bold()
                        Text("PID \(finding.pid)").font(.caption2).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if finding.reclaimBytes > 0 {
                            Text(byteString(finding.reclaimBytes))
                                .font(.caption).bold().foregroundStyle(heat.color)
                        }
                    }
                    Text(finding.summary).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text(advice.short)
                            .font(.caption2).bold().foregroundStyle(advice.color)
                        if let attribution = finding.attribution {
                            Text("· " + attribution)
                                .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                }
            }

            if expanded {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(finding.detail, id: \.self) { line in
                        Text("· " + line).font(.caption2).foregroundStyle(.secondary)
                    }
                    // Maskowane także na ekranie, nie tylko w raporcie: pole jest
                    // zaznaczalne i trafia na każdy zrzut ekranu oraz udostępniony pulpit.
                    Text(SecretMasker.mask(finding.command))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.tertiary).lineLimit(3).textSelection(.enabled)
                }
                .padding(.leading, 20)
            }

            HStack(spacing: 8) {
                Button(copied ? L("proc.copied") : L("proc.report")) {
                    engine.copyReport(finding); copied = true
                }
                .disabled(copied)
                Button(L("proc.kill")) { engine.kill(finding) }
                    .disabled(!advice.actionable && advice.short == L("advice.protected"))
                Button(expanded ? L("proc.less") : L("proc.more")) { expanded.toggle() }
                Spacer()
                Menu { Button(L("proc.ignore")) { engine.ignore(finding) } }
                    label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 24)
            }
            .buttonStyle(.bordered).controlSize(.small).padding(.leading, 20)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
}

func byteString(_ bytes: UInt64) -> String {
    let mb = Double(bytes) / 1_048_576
    if mb >= 1024 { return String(format: "%.1f GB", mb / 1024) }
    if mb >= 1 { return String(format: "%.0f MB", mb) }
    return String(format: "%.0f KB", Double(bytes) / 1024)
}
